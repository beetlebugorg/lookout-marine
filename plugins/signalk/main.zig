//! Signal K over TCP, from one or MORE servers.
//!
//! Signal K is the open marine data standard. A server on the boat collects
//! every instrument it can reach and streams the readings as deltas: small
//! JSON documents that name a path and a value. This plugin opens the stream,
//! maps the paths it knows onto the host's own, and publishes them.
//!
//! Every server the mariner keeps is a row of the `servers` setting: an
//! address, a port, a name and an on switch. Each row gets its own socket, its
//! own document framer and its own reconnect clock, so the boat's server and a
//! second one on a laptop can feed the same chart at once. A row switched off
//! closes its socket and does not reconnect until it is switched back on.
//!
//! Everything published lands in ONE source: the store sees the plugin, not
//! the row. This plugin is a source of its own beside `nmea0183`, so a Signal K
//! server and a NMEA gateway carrying the same path are arbitrated by the
//! store's election rather than by whichever arrived last.
//!
//! A closed connection is retried every 2 s, forever. A document that is not
//! JSON, a path outside the vocabulary and a vessel with no MMSI are counted
//! and dropped without a log line, because a real stream carries all three
//! continuously.
//!
//! The transport is in transport.zig, the mapping in delta.zig and the
//! settings in config.zig, all three natively testable. This file is the
//! wiring: sockets, timers, counters and the two host calls.
//!
//! STATE. Everything that outlives one event is a global. The scratch
//! allocator is reset the moment an event handler returns, so the document
//! buffers, the server identities and the counters cannot live there.
//!
//! TIMESTAMPS. Published values are stamped with the host's wall clock, not
//! with the ISO-8601 time a delta carries. The store measures staleness
//! against the host clock, and a server replaying a log would otherwise
//! publish values that are already stale.

const lk = @import("lk");
const delta = @import("delta.zig");
const transport = @import("transport.zig");
const cfg = @import("config.zig");

comptime {
    lk.registerPlugin(@This());
}

/// Delay before a dropped connection is retried.
const reconnect_ms: i64 = 2_000;
/// How often the status is refreshed, and the window each delta rate is
/// averaged over. The settings window polls faster than this, so a rate is at
/// most one tick stale.
const status_ms: i64 = 2_000;
/// Failed connects in a row before a connection reads as unreachable rather
/// than reconnecting. Three tries is six seconds of silence.
const unreachable_after: u32 = 3;
/// Longest own-ship identity a hello can name. An MRN with a UUID is 65 bytes.
/// A longer one is not kept, so own ship reads as unnamed instead of matching
/// a truncated identity against nothing.
const max_identity = 128;

/// Longest websocket URL built for a row: the scheme, an address of up to 253
/// bytes, a port and the spec's path.
const max_url = 320;

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
    /// The row asks for a transport the host cannot carry.
    no_transport,

    fn text(self: State) []const u8 {
        return switch (self) {
            .connected => "connected",
            .reconnecting => "reconnecting",
            .no_answer => "unreachable",
            .paused => "paused",
            .no_address => "no_address",
            .no_transport => "no_transport",
        };
    }
};

/// One row of the setting, and the stream that serves it.
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

    doc_buf: [transport.max_doc]u8 = undefined,
    framer: transport.Framer = .{ .buf = &.{} },

    /// What this server calls own ship, from its hello. Deltas under this
    /// context are own ship and not an AIS target.
    self_id: cfg.Text(max_identity) = .{},

    /// `framer.stats.docs` at the last status tick: the delta rate is the
    /// difference between ticks.
    last_docs: u64 = 0,
    rate: u64 = 0,

    /// The framer points into this struct, so it is bound here rather than at
    /// declaration: a global initialiser cannot take the address of a field of
    /// the object being initialised.
    fn bind(self: *Conn) void {
        self.framer = transport.Framer.init(self.row.kind, &self.doc_buf);
    }

    fn label(self: *const Conn) []const u8 {
        return if (self.row.name.len > 0) self.row.name.text() else self.row.host.text();
    }

    fn closeSocket(self: *Conn) void {
        if (self.sock >= 0) switch (self.row.kind) {
            .tcp => lk.tcpClose(self.sock),
            .ws => lk.wsClose(self.sock),
        };
        self.sock = -1;
        if (self.retry_timer >= 0) lk.timerCancel(self.retry_timer);
        self.retry_timer = -1;
        self.rate = 0;
    }

    /// Ask for a connection. The result arrives later — `.tcp_connected` or
    /// `.ws_open`, and `.tcp_closed` or `.ws_closed` — so only an outright
    /// refusal is visible here, and it is retried on the same clock as a
    /// dropped connection.
    fn open(self: *Conn) void {
        if (!self.row.enabled) {
            self.state = .paused;
            return;
        }
        if (!self.row.usable()) {
            self.state = .no_address;
            return;
        }
        // The two transports differ here and nowhere else: the framer, the
        // subscription, the mapping and the status are the same after this.
        self.sock = switch (self.row.kind) {
            .tcp => lk.tcpConnect(self.row.host.text(), self.row.port),
            .ws => blk: {
                var url_buf: [max_url]u8 = undefined;
                const url = transport.wsUrl(&url_buf, self.row.host.text(), self.row.port) orelse
                    break :blk @as(i64, -1);
                break :blk lk.wsConnect(url, &.{});
            },
        };
        if (self.sock < 0) {
            self.sock = -1;
            // A REFUSED ws_connect is not a failed connect: a connect that
            // fails comes back later as `.ws_closed`. -1 means the host would
            // not make the call at all, and the only reason it does that is
            // the grant — the manifest covers this boat's own network, and a
            // server out on the internet is not on it. Retrying that is a
            // refusal every two seconds for ever, so the row stops and says
            // what is wrong.
            if (self.row.kind == .ws) {
                self.state = .no_transport;
                return;
            }
            self.noteFailure();
            self.scheduleRetry();
        }
    }

    /// Everything a stream opening does, whichever transport carried it. The
    /// server writes its hello unasked and its deltas only after a
    /// subscription, so the stream really starts at the send.
    fn opened(self: *Conn) void {
        self.state = .connected;
        self.failures = 0;
        // A partial document and an identity from the last connection have
        // nothing to do with this one.
        self.framer.reset();
        self.self_id.set("");
        self.last_docs = self.framer.stats.docs;
        self.rate = 0;
        switch (self.row.kind) {
            .tcp => _ = lk.tcpSend(self.sock, transport.subscribe_all),
            // A websocket message is already one document, so the CR LF the
            // TCP framing needs would be two bytes of noise inside it.
            .ws => _ = lk.wsSend(self.sock, transport.subscribe_body),
        }
    }

    /// Everything a stream ending does, whichever transport carried it.
    fn ended(self: *Conn) void {
        self.sock = -1;
        // The close of a row the mariner just switched off is not a failure,
        // and must not read as one for the moment before the status settles.
        if (self.row.enabled and self.row.usable()) {
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
    /// itself, so a detail that only repeats it — "paused, switched off" — is
    /// left empty.
    fn detail(self: *const Conn, out: *lk.Buf) void {
        switch (self.state) {
            // A hello may leave `self` out. Deltas then carry a concrete
            // vessel URN that nothing can match against own ship, and only
            // the AIS targets get through. Say so once deltas are arriving.
            .connected => if (self.rate > 0 and self.self_id.len == 0)
                out.print("{d} deltas/s, own ship not named", .{self.rate})
            else
                out.print("{d} deltas/s", .{self.rate}),
            .no_answer => out.raw("check the address"),
            .no_transport => out.raw("websocket refused; the server is not on this boat's network"),
            .reconnecting, .paused, .no_address => {},
        }
    }
};

var conns: [cfg.max_servers]Conn = @splat(.{});
var status_timer: i64 = -1;
/// Updates and targets the host ACCEPTED, not calls made. Counted for the
/// whole plugin: the store has one source whatever the row.
var published: u64 = 0;
var upserted: u64 = 0;
/// What the mapping threw away, for the same reason.
var counts: delta.Counts = .{};

pub fn start(s: lk.Start) !void {
    for (&conns) |*c| c.bind();
    // The list is the mariner's and it starts empty. Nothing seeds a Signal K
    // address, so a first run has no servers and says so.
    reconcile(cfg.fromValue(s.config));
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
            c.opened();
            postStatus();
        },
        .tcp_data => |d| {
            const c = bySocket(d.conn) orelse return;
            consume(c, d.bytes);
        },
        .tcp_closed => |id| {
            const c = bySocket(id) orelse return;
            c.ended();
            postStatus();
        },
        // The websocket side of the same three. The host reassembles a
        // message's frames and answers the pings, so one payload here is one
        // whole document and the framer passes it straight through.
        .ws_open => |w| {
            const c = bySocket(w.conn) orelse return;
            c.opened();
            postStatus();
        },
        .ws_data => |w| {
            const c = bySocket(w.conn) orelse return;
            consume(c, w.text);
        },
        .ws_closed => |w| {
            const c = bySocket(w.conn) orelse return;
            c.ended();
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

/// Take the mariner's list and make the streams match it.
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
            c.row.port != row.port or
            c.row.kind != row.kind;
        const was_enabled = !fresh and c.row.enabled;

        c.used = true;
        c.seen = true;
        c.order = order;
        c.row = row;
        c.framer.kind = row.kind;

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

    // A row the mariner deleted takes its stream with it.
    for (&conns) |*c| {
        if (!c.used or c.seen) continue;
        c.closeSocket();
        c.used = false;
        c.row = .{};
        c.self_id.set("");
    }
}

fn consume(c: *Conn, chunk: []const u8) void {
    var it = c.framer.feed(chunk);
    while (it.next()) |doc| {
        switch (delta.parse(lk.scratch(), doc, c.self_id.text(), &counts)) {
            // A hello with no `self`, or one too long to keep, leaves the
            // identity empty. An empty identity matches no context, so own
            // ship stays unpublished and the status line says so.
            .hello => |id| if (id.len > 0 and id.len <= max_identity) c.self_id.set(id),
            .own => |ups| publishOwn(ups),
            .target => |t| upsertTarget(t),
            .ignored => {},
        }
    }
}

fn publishOwn(ups: delta.Updates) void {
    const ts = lk.nowMs();
    var buf: [768]u8 = undefined;
    var p = lk.Publish.init(&buf);
    for (ups.slice()) |u| switch (u.value) {
        .number => |v| p.number(u.path.text(), v, ts),
        .position => |g| p.position(u.path.text(), g.lat, g.lon, ts),
        // The server holds the path and has no reading for it. The host takes
        // the same meaning from a null.
        .none => p.clear(u.path.text(), ts),
    };
    const rc = p.send();
    if (rc > 0) published += @intCast(rc);
}

fn upsertTarget(t: delta.TargetFields) void {
    var buf: [320]u8 = undefined;
    var u = lk.AisUpsert.init(&buf);
    u.target(.{
        .mmsi = t.mmsi,
        .lat = t.lat,
        .lon = t.lon,
        .sog = t.sog,
        .cog = t.cog,
        .heading = t.heading,
        .name = t.name,
        .ts_ms = lk.nowMs(),
    });
    const rc = u.send();
    if (rc > 0) upserted += @intCast(rc);
}

/// The plugin's line for the chrome, and one item per server for the settings
/// window. The item ids are the row ids the shell assigned, which is how each
/// row's line finds its way back to the right row.
fn postStatus() void {
    var slots: [cfg.max_servers]*Conn = undefined;
    var n: usize = 0;
    for (&conns) |*c| {
        if (!c.used) continue;
        slots[n] = c;
        n += 1;
    }
    // In the mariner's order, not the slot order. A `for (1..n)` would be a
    // REVERSED range when there are no servers at all, which is undefined with
    // safety off — this loop has to be a while.
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
    b.str(if (live > 0) "running" else "degraded");
    b.raw(",\"detail\":");
    var detail: [120]u8 = undefined;
    var dw = lk.Buf.init(&detail);
    if (n == 0) {
        dw.raw("no servers");
    } else if (live > 0) {
        dw.print("{d} of {d} connected, {d} deltas/s", .{ live, n, total_rate });
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

/// The delta rate of one connection over the last status window, and the
/// counters behind it at a level a shell can filter out.
fn sampleRate(c: *Conn) void {
    const docs = c.framer.stats.docs;
    const diff = docs - c.last_docs;
    c.last_docs = docs;
    if (c.state != .connected) {
        c.rate = 0;
        return;
    }
    c.rate = (diff * 1000 + status_ms / 2) / @as(u64, @intCast(status_ms));
    lk.logf(.debug, "{s}: deltas {d}, rate {d}, oversize {d}, unmapped paths {d}, no mmsi {d}, unreadable {d}, published {d}, targets {d}", .{
        c.label(),
        docs,
        c.rate,
        c.framer.stats.oversize,
        counts.unmapped,
        counts.no_mmsi,
        counts.unreadable,
        published,
        upserted,
    });
}
