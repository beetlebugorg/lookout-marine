//! NMEA 0183 over TCP, from one or MORE sources.
//!
//! Every connection the mariner keeps is a row of the `connections` setting:
//! an address, a port, a name and an on switch. Each row gets its own socket,
//! its own sentence reassembly, its own AIS assembler and its own reconnect
//! clock, so a masthead transponder and a plotter bridging the instruments can
//! feed the same chart at once. A row switched off closes its socket and does
//! not reconnect until it is switched back on.
//!
//! Everything published lands in ONE source: the store sees the plugin, not
//! the row. Two rows carrying the same sentence therefore overwrite each other
//! in publish order, which is a real thing to fix later and not this pass.
//!
//! A closed connection is retried every 2 s, forever; a line that fails its
//! checksum or a message type the parser does not decode is counted and
//! dropped without a log line, because a real stream carries both
//! continuously.
//!
//! All the parsing lives in parser.zig, the mapping in paths.zig and the
//! settings in config.zig, all three natively testable. This file is the
//! wiring: sockets, timers, counters and the two host calls.
//!
//! STATE. Everything that outlives one event is a global — the scratch
//! allocator is reset the moment an event handler returns, so the line
//! buffers, the AIS assemblers and the counters cannot live there.
//!
//! TIMESTAMPS. Published values are stamped with the host's wall clock, not
//! with the UTC a sentence carries. The store measures staleness against the
//! host clock, and a replayed log (or a receiver whose date is wrong) would
//! otherwise arrive already stale.

const lk = @import("lk");
const parser = @import("parser.zig");
const paths = @import("paths.zig");
const cfg = @import("config.zig");

comptime {
    lk.registerPlugin(@This());
}

/// Delay before a dropped connection is retried.
const reconnect_ms: i64 = 2_000;
/// How often the status is refreshed, and the window each message rate is
/// averaged over. The settings window polls faster than this, so a rate is at
/// most one tick stale.
const status_ms: i64 = 2_000;
/// Failed connects in a row before a connection reads as unreachable rather
/// than reconnecting. Three tries is six seconds of silence.
const unreachable_after: u32 = 3;

/// What one connection is doing, in the words the mariner reads.
const State = enum {
    connected,
    reconnecting,
    /// Dialled and dialled and nothing answered. `unreachable` is a keyword,
    /// so the state is named for what happened, not for what the mariner
    /// reads.
    no_answer,
    paused,
    /// The row has no address, or a port nothing can dial.
    no_address,

    fn text(self: State) []const u8 {
        return switch (self) {
            .connected => "connected",
            .reconnecting => "reconnecting",
            .no_answer => "unreachable",
            .paused => "paused",
            .no_address => "no_address",
        };
    }
};

/// One row of the setting, and the socket that serves it.
const Conn = struct {
    row: cfg.Row = .{},
    /// False while this slot holds no row.
    used: bool = false,
    /// Set while the row was seen in the config being applied.
    seen: bool = false,
    /// Where the row sits in the mariner's list, so the status items come back
    /// in the order the settings window shows.
    order: usize = 0,

    /// The live connection, or -1 while there is none.
    sock: i64 = -1,
    /// The pending one-shot reconnect timer, or -1 when none is armed.
    retry_timer: i64 = -1,
    /// Connect attempts since the last time this row carried data.
    failures: u32 = 0,
    state: State = .reconnecting,

    /// One sentence at most: the standard's limit is 82 bytes, and a longer
    /// line is dropped by the feeder rather than truncated into two plausible
    /// halves.
    line_buf: [128]u8 = undefined,
    feeder: parser.Feeder = .{ .buf = &.{} },
    assembler: parser.Assembler = .{},

    /// `feeder.stats.lines` at the last status tick: the message rate is the
    /// delta between ticks.
    last_lines: u64 = 0,
    rate: u64 = 0,

    /// The feeder points into this struct, so it is bound here rather than at
    /// declaration: a global initialiser cannot take the address of a field of
    /// the object being initialised.
    fn bind(self: *Conn) void {
        self.feeder = .{ .buf = &self.line_buf };
    }

    fn label(self: *const Conn) []const u8 {
        return if (self.row.name.len > 0) self.row.name.text() else self.row.host.text();
    }

    fn closeSocket(self: *Conn) void {
        if (self.sock >= 0) lk.tcpClose(self.sock);
        self.sock = -1;
        if (self.retry_timer >= 0) lk.timerCancel(self.retry_timer);
        self.retry_timer = -1;
        self.rate = 0;
    }

    /// Ask for a connection. The result arrives later as `.tcp_connected` or
    /// `.tcp_closed`; only an outright refusal is visible here, and it is
    /// retried on the same clock as a dropped connection.
    fn open(self: *Conn) void {
        if (!self.row.enabled) {
            self.state = .paused;
            return;
        }
        if (!self.row.usable()) {
            self.state = .no_address;
            return;
        }
        self.sock = lk.tcpConnect(self.row.host.text(), self.row.port);
        if (self.sock < 0) {
            self.sock = -1;
            self.noteFailure();
            self.scheduleRetry();
        }
    }

    fn scheduleRetry(self: *Conn) void {
        if (self.retry_timer >= 0) return;
        if (!self.row.enabled or !self.row.usable()) return;
        const id = lk.timerSet(reconnect_ms, false);
        if (id >= 0) self.retry_timer = id;
    }

    fn noteFailure(self: *Conn) void {
        if (self.failures < unreachable_after) self.failures += 1;
        self.state = if (self.failures >= unreachable_after) .no_answer else .reconnecting;
    }

    /// What to add after the state, or nothing. The shell writes the state
    /// itself, so a detail that only repeats it — "paused, switched off" —
    /// is left empty.
    fn detail(self: *const Conn, out: *lk.Buf) void {
        switch (self.state) {
            .connected => out.print("{d} msg/s", .{self.rate}),
            .no_answer => out.raw("check the address"),
            .reconnecting, .paused, .no_address => {},
        }
    }
};

var conns: [cfg.max_conns]Conn = @splat(.{});
var status_timer: i64 = -1;
/// Updates and targets the host ACCEPTED, not calls made. Counted for the
/// whole plugin: the store has one source whatever the row.
var published: u64 = 0;
var upserted: u64 = 0;
/// Lines that parsed to nothing usable: a sentence type this parser does not
/// decode, or an AIS payload that would not decode.
var undecoded: u64 = 0;

pub fn start(s: lk.Start) !void {
    for (&conns) |*c| c.bind();

    // The list is the mariner's. When it is empty — a first run, or a host
    // that never wrote one — the address the host was started with becomes
    // row one, so a plugin started with LOOKOUT_NMEA still connects.
    var rows = cfg.fromValue(s.config);
    if (rows.len == 0) rows = cfg.seed(s.config);
    reconcile(rows);

    status_timer = lk.timerSet(status_ms, true);
    postStatus();
}

pub fn onEvent(e: lk.Event) !void {
    switch (e) {
        .config_changed => |payload| {
            reconcile(cfg.fromJson(lk.scratch(), payload));
            postStatus();
        },
        .tcp_connected => |id| {
            const c = bySocket(id) orelse return;
            c.state = .connected;
            c.failures = 0;
            // A partial line and a half-assembled AIS message from the last
            // connection have nothing to do with this one.
            c.feeder.len = 0;
            c.feeder.ready = false;
            c.feeder.dropping = false;
            c.assembler = .{};
            c.last_lines = c.feeder.stats.lines;
            c.rate = 0;
            postStatus();
        },
        .tcp_data => |d| {
            const c = bySocket(d.conn) orelse return;
            consume(c, d.bytes);
        },
        .tcp_closed => |id| {
            const c = bySocket(id) orelse return;
            c.sock = -1;
            // The close of a row the mariner just switched off is not a
            // failure, and must not read as one for the moment before the
            // status settles.
            if (c.row.enabled and c.row.usable()) {
                c.noteFailure();
                c.scheduleRetry();
            }
            postStatus();
        },
        .timer => |id| {
            if (id == status_timer) {
                postStatus();
                return;
            }
            for (&conns) |*c| {
                if (!c.used or c.retry_timer != id) continue;
                c.retry_timer = -1;
                c.open();
                return;
            }
        },
        .shutdown => {
            for (&conns) |*c| {
                if (!c.used) continue;
                c.closeSocket();
                c.used = false;
            }
            if (status_timer >= 0) lk.timerCancel(status_timer);
            lk.status("stopped", "disconnected", .{});
        },
        else => {},
    }
}

fn bySocket(id: i64) ?*Conn {
    for (&conns) |*c| {
        if (c.used and c.sock == id) return c;
    }
    return null;
}

fn byId(id: []const u8) ?*Conn {
    for (&conns) |*c| {
        if (c.used and c.row.id.eql(id)) return c;
    }
    return null;
}

fn freeSlot() ?*Conn {
    for (&conns) |*c| {
        if (!c.used) return c;
    }
    return null;
}

/// Take the mariner's list and make the sockets match it.
///
/// A row is matched to its slot by ID, so editing one row never disturbs
/// another's connection: only an address change, a pause or a delete closes a
/// socket. A row whose address is unchanged and whose socket is up is left
/// exactly as it is.
fn reconcile(rows: cfg.Rows) void {
    for (&conns) |*c| c.seen = false;

    for (rows.slice(), 0..) |row, order| {
        const c = byId(row.id.text()) orelse freeSlot() orelse continue;
        const fresh = !c.used;
        const moved = fresh or
            !c.row.host.eql(row.host.text()) or
            c.row.port != row.port;
        const was_enabled = !fresh and c.row.enabled;

        c.used = true;
        c.seen = true;
        c.order = order;
        c.row = row;

        if (!row.enabled) {
            c.closeSocket();
            c.state = .paused;
            c.failures = 0;
        } else if (!row.usable()) {
            c.closeSocket();
            c.state = .no_address;
        } else if (moved or !was_enabled) {
            // A new address, or a row just switched back on: start over,
            // including the failure count behind "unreachable".
            c.closeSocket();
            c.failures = 0;
            c.state = .reconnecting;
            c.open();
        } else if (c.sock < 0 and c.retry_timer < 0) {
            c.open();
        }
    }

    // A row the mariner deleted takes its socket with it.
    for (&conns) |*c| {
        if (!c.used or c.seen) continue;
        c.closeSocket();
        c.used = false;
        c.row = .{};
    }
}

fn consume(c: *Conn, chunk: []const u8) void {
    var it = c.feeder.feed(chunk);
    while (it.next()) |line| {
        const s = parser.parse(line) catch {
            // A sentence type this parser does not decode, or one whose
            // fields are unreadable. A real stream carries both continuously
            // — GSV, GSA, proprietary lines — so this is counted, not logged.
            // Checksum failures never reach here: the feeder rejects them and
            // keeps its own count.
            undecoded += 1;
            continue;
        };
        switch (s) {
            .vdm => |v| handleVdm(c, v),
            else => handleSentence(s),
        }
    }
}

fn handleSentence(s: parser.Sentence) void {
    const ups = paths.fromSentence(s);
    const items = ups.slice();
    if (items.len == 0) return;
    const ts = lk.nowMs();
    var buf: [320]u8 = undefined;
    var p = lk.Publish.init(&buf);
    for (items) |u| switch (u.value) {
        .number => |v| p.number(u.path.text(), v, ts),
        .position => |g| p.position(u.path.text(), g.lat, g.lon, ts),
    };
    const rc = p.send();
    if (rc > 0) published += @intCast(rc);
}

fn handleVdm(c: *Conn, v: parser.Vdm) void {
    const msg = c.assembler.push(v) orelse return;
    // AIVDO is this receiver's own transmission. Own ship comes from the
    // position sentences; upserting it as an AIS target would draw the boat
    // twice.
    if (msg.own) return;
    var text: [parser.text_scratch_bytes]u8 = undefined;
    const decoded = parser.decode(msg.payload, msg.fill, &text) catch {
        undecoded += 1;
        return;
    };
    const t = paths.fromAis(decoded) orelse return;
    var buf: [256]u8 = undefined;
    var u = lk.AisUpsert.init(&buf);
    u.target(.{
        .mmsi = t.mmsi,
        .lat = t.lat,
        .lon = t.lon,
        .sog = t.sog_mps,
        .cog = t.cog,
        .heading = t.heading,
        .name = t.name,
        .aton = t.aton,
        .aton_type = t.aton_type,
        .virtual_aton = t.virtual_aton,
        .off_position = t.off_position,
        .ts_ms = lk.nowMs(),
    });
    const rc = u.send();
    if (rc > 0) upserted += @intCast(rc);
}

/// The plugin's line for the chrome, and one item per connection for the
/// settings window. The item ids are the row ids the shell assigned, which is
/// how each row's line finds its way back to the right row.
fn postStatus() void {
    var slots: [cfg.max_conns]*Conn = undefined;
    var n: usize = 0;
    for (&conns) |*c| {
        if (!c.used) continue;
        slots[n] = c;
        n += 1;
    }
    // In the mariner's order, not the slot order. A `for (1..n)` would be a
    // REVERSED range when there are no connections at all, which is undefined
    // with safety off — this loop has to be a while.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0 and slots[j - 1].order > slots[j].order) : (j -= 1) {
            const tmp = slots[j - 1];
            slots[j - 1] = slots[j];
            slots[j] = tmp;
        }
    }

    var live: usize = 0;
    var total_rate: u64 = 0;
    for (slots[0..n]) |c| {
        sampleRate(c);
        if (c.state == .connected) {
            live += 1;
            total_rate += c.rate;
        }
    }

    var buf: [720]u8 = undefined;
    var b = lk.Buf.init(&buf);
    b.raw("{\"state\":");
    b.str(if (live > 0) "running" else if (n == 0) "degraded" else "degraded");
    b.raw(",\"detail\":");
    var detail: [120]u8 = undefined;
    var dw = lk.Buf.init(&detail);
    if (n == 0) {
        dw.raw("no connections");
    } else if (live > 0) {
        dw.print("{d} of {d} connected, {d} msg/s", .{ live, n, total_rate });
    } else {
        dw.print("0 of {d} connected", .{n});
    }
    b.str(dw.bytes());

    // One item per row. The shell shows these beside the rows; the chrome
    // shows only the line above.
    b.raw(",\"items\":[");
    for (slots[0..n], 0..) |c, k| {
        if (k > 0) b.raw(",");
        b.raw("{\"id\":");
        b.str(c.row.id.text());
        b.raw(",\"state\":");
        b.str(c.state.text());
        b.raw(",\"detail\":");
        var d: [64]u8 = undefined;
        var dbuf = lk.Buf.init(&d);
        c.detail(&dbuf);
        b.str(dbuf.bytes());
        b.raw("}");
    }
    b.raw("]}");
    if (b.overflowed) {
        // Too many rows to describe at once: the line still goes out, so the
        // chrome never falls silent.
        lk.status(if (live > 0) "running" else "degraded", "{d} of {d} connected", .{ live, n });
        return;
    }
    lk.statusJson(b.bytes());
}

/// The message rate of one connection over the last status window, and the
/// counters behind it at a level a shell can filter out.
fn sampleRate(c: *Conn) void {
    const lines = c.feeder.stats.lines;
    const delta = lines - c.last_lines;
    c.last_lines = lines;
    if (c.state != .connected) {
        c.rate = 0;
        return;
    }
    c.rate = (delta * 1000 + status_ms / 2) / @as(u64, @intCast(status_ms));
    lk.logf(.debug, "{s}: lines {d}, rate {d}, bad checksum {d}, no checksum {d}, oversize {d}, fragments dropped {d}", .{
        c.label(),
        lines,
        c.rate,
        c.feeder.stats.bad_checksum,
        c.feeder.stats.no_checksum,
        c.feeder.stats.oversize,
        c.assembler.dropped,
    });
}
