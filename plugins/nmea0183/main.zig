//! NMEA 0183 over TCP.
//!
//! Connects to `{"host","port"}` from the start config, reassembles sentences
//! out of the byte chunks TCP delivers, and turns them into vessel publishes
//! and AIS upserts. A closed connection is retried every 2 s, forever; a line
//! that fails its checksum or a message type the parser does not decode is
//! counted and dropped without a log line, because a real stream carries both
//! continuously.
//!
//! All the parsing lives in parser.zig and all the mapping in paths.zig, both
//! natively testable. This file is the wiring: sockets, timers, counters and
//! the two host calls.
//!
//! STATE. Everything that outlives one event is a global — the scratch
//! allocator is reset the moment an event handler returns, so the line buffer,
//! the AIS assembler and the counters cannot live there.
//!
//! TIMESTAMPS. Published values are stamped with the host's wall clock, not
//! with the UTC a sentence carries. The store measures staleness against the
//! host clock, and a replayed log (or a receiver whose date is wrong) would
//! otherwise arrive already stale.

const lk = @import("lk");
const parser = @import("parser.zig");
const paths = @import("paths.zig");

comptime {
    lk.registerPlugin(@This());
}

const default_host = "127.0.0.1";
const default_port: u16 = 10110;
/// Delay before a dropped connection is retried.
const reconnect_ms: i64 = 2_000;
/// How often the status line is refreshed, and the window the message rate is
/// averaged over.
const status_ms: i64 = 5_000;

var host_buf: [255]u8 = undefined;
var host_len: usize = 0;
var port: u16 = default_port;

/// The live connection, or -1 while there is none.
var conn: i64 = -1;
var connected: bool = false;
/// The pending one-shot reconnect timer, or -1 when none is armed.
var reconnect_timer: i64 = -1;
var status_timer: i64 = -1;

/// One sentence at most: the standard's limit is 82 bytes, and a longer line
/// is dropped by the feeder rather than truncated into two plausible halves.
var line_buf: [128]u8 = undefined;
var feeder = parser.Feeder{ .buf = &line_buf };
var assembler: parser.Assembler = .{};

/// `Feeder.stats.lines` at the last status tick, and the monotonic time it was
/// sampled at: the message rate is the delta between ticks.
var last_lines: u64 = 0;
var last_sample_ms: i64 = 0;
/// Updates and targets the host ACCEPTED, not calls made.
var published: u64 = 0;
var upserted: u64 = 0;
/// Lines that parsed to nothing usable: a sentence type this parser does not
/// decode, or an AIS payload that would not decode.
var undecoded: u64 = 0;

pub fn start(s: lk.Start) !void {
    const h = lk.cfgStr(s.config, "host", default_host);
    const src = if (h.len == 0 or h.len > host_buf.len) default_host else h;
    host_len = src.len;
    @memcpy(host_buf[0..host_len], src);

    const p = lk.cfgInt(s.config, "port", default_port);
    port = if (p > 0 and p <= 65535) @intCast(p) else default_port;

    status_timer = lk.timerSet(status_ms, true);
    last_sample_ms = lk.monoMs();
    lk.status("degraded", "connecting to {s}:{d}", .{ hostName(), port });
    openConn();
}

pub fn onEvent(e: lk.Event) !void {
    switch (e) {
        .tcp_connected => |id| {
            if (id != conn) return;
            connected = true;
            // A partial line and a half-assembled AIS message from the last
            // connection have nothing to do with this one.
            feeder.len = 0;
            feeder.ready = false;
            feeder.dropping = false;
            assembler = .{};
            last_lines = feeder.stats.lines;
            last_sample_ms = lk.monoMs();
            lk.status("running", "connected, 0 msg/s", .{});
        },
        .tcp_data => |d| {
            if (d.conn == conn) consume(d.bytes);
        },
        .tcp_closed => |id| {
            if (id != conn) return;
            conn = -1;
            connected = false;
            scheduleReconnect();
            lk.status("degraded", "reconnecting", .{});
        },
        .timer => |id| {
            if (id == status_timer) {
                postStatus();
            } else if (id == reconnect_timer) {
                reconnect_timer = -1;
                openConn();
            }
        },
        .shutdown => {
            if (conn >= 0) lk.tcpClose(conn);
            conn = -1;
            connected = false;
            if (status_timer >= 0) lk.timerCancel(status_timer);
            if (reconnect_timer >= 0) lk.timerCancel(reconnect_timer);
            lk.status("stopped", "disconnected", .{});
        },
        else => {},
    }
}

fn hostName() []const u8 {
    return host_buf[0..host_len];
}

/// Ask for a connection. The result arrives later as `.tcp_connected` or
/// `.tcp_closed`; only an outright refusal is visible here, and it is retried
/// on the same 2 s clock as a dropped connection.
fn openConn() void {
    conn = lk.tcpConnect(hostName(), port);
    if (conn < 0) {
        conn = -1;
        scheduleReconnect();
        lk.status("degraded", "reconnecting", .{});
    }
}

fn scheduleReconnect() void {
    if (reconnect_timer >= 0) return;
    const id = lk.timerSet(reconnect_ms, false);
    if (id >= 0) reconnect_timer = id;
}

fn consume(chunk: []const u8) void {
    var it = feeder.feed(chunk);
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
            .vdm => |v| handleVdm(v),
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

fn handleVdm(v: parser.Vdm) void {
    const msg = assembler.push(v) orelse return;
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

fn postStatus() void {
    const now = lk.monoMs();
    const dt = now - last_sample_ms;
    const lines = feeder.stats.lines;
    const delta = lines - last_lines;
    last_lines = lines;
    last_sample_ms = now;

    if (!connected) {
        lk.status("degraded", "reconnecting", .{});
        return;
    }
    const ms: u64 = if (dt > 0) @intCast(dt) else 0;
    const rate = if (ms > 0) (delta * 1000 + ms / 2) / ms else 0;
    lk.status("running", "connected, {d} msg/s", .{rate});
    // The counters behind the status line, at a level a shell can filter out.
    lk.logf(.debug, "lines {d}, published {d}, targets {d}, undecoded {d}, bad checksum {d}, no checksum {d}, oversize {d}, fragments dropped {d}", .{
        lines,
        published,
        upserted,
        undecoded,
        feeder.stats.bad_checksum,
        feeder.stats.no_checksum,
        feeder.stats.oversize,
        assembler.dropped,
    });
}
