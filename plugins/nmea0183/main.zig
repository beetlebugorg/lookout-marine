//! NMEA 0183 over TCP, from one or MORE gateways.
//!
//! NMEA 0183 is the instrument network's own wire format: one line per value,
//! terminated by a checksum. A WiFi gateway on the boat repeats what the
//! network carries over TCP. This plugin reads the lines, decodes the sentences
//! it knows, and publishes them.
//!
//! Every gateway the mariner keeps is a row of the `connections` setting. The
//! library owns the connections end to end: the socket, the reconnect clock,
//! the pause switch and each row's line in the settings window. This file is
//! the protocol and nothing else: reassembly, the parse, and what each sentence
//! means.
//!
//! EACH CONNECTION PUBLISHES AS ITSELF. The store keeps one source per row, so
//! two gateways carrying position are arbitrated by its election in the
//! mariner's list order: the top row holds own ship while its fixes are fresh,
//! and the one below it takes over when they go stale.
//!
//! A line that fails its checksum, a sentence type the parser does not decode
//! and an AIS payload that will not decode are dropped without a log line,
//! because a real stream carries all three continuously.
//!
//! The parsing is in parser.zig, the mapping in paths.zig and the settings in
//! config.zig, all three natively testable.
//!
//! TIMESTAMPS. Published values are stamped with the host's wall clock, not
//! with the UTC a sentence carries. The store measures staleness against the
//! host clock, and a replayed log (or a receiver whose date is wrong) would
//! otherwise arrive already stale.

const std = @import("std");
const lk = @import("lk2");
const parser = @import("parser.zig");
const paths = @import("paths.zig");
const cfg = @import("config.zig");

comptime {
    lk.plugin(@This());
}

pub const Connections = cfg.Connections;
const Connection = Connections.Connection;

/// One read's worth of raw lines for the bus, TAG blocks included. A TCP read
/// is at most 8 KiB and the tag adds ~10 bytes to lines of ~40, so this never
/// overflows in practice; a line that would is dropped whole.
var bus_buf: [16 * 1024]u8 = undefined;

/// True after the host refused a bus publish — the grant is off — so the
/// refusal is logged once, not per read. GRANTS_CHANGED flips it back.
var bus_denied = false;

/// A partial sentence and a half-assembled AIS message from the last connection
/// have nothing to do with this one, so the stream starts over here.
pub fn onOpen(conn: *Connection) void {
    const s = &conn.state;
    s.feeder = parser.Feeder.init(&s.line);
    s.assembler = .{};
    // A reconnect re-probes the bus once: the sticky flag cannot tell a
    // revoked grant from a transient refusal, and one retry per connect
    // costs one log line at worst.
    bus_denied = false;
}

pub fn onData(conn: *Connection, bytes: []const u8) void {
    const s = &conn.state;
    if (s.feeder.buf.len == 0) s.feeder = parser.Feeder.init(&s.line);
    // The TAG block depends only on the row, so it is built once per read —
    // and not at all while the grant is off.
    var tag_buf: [24]u8 = undefined;
    const tag = if (bus_denied) "" else rowTag(&tag_buf, conn.place());
    var bus_len: usize = 0;
    var it = s.feeder.feed(bytes);
    while (it.next()) |line| {
        // The feeder returns complete, checksum-verified lines only, so this
        // is the connection's message rate.
        conn.count(1);
        if (tag.len > 0) appendRaw(&bus_len, tag, line);
        // A sentence type this parser does not decode — GSV, GSA, a
        // proprietary line — or one whose fields are unreadable.
        const sentence = parser.parse(line) catch continue;
        switch (sentence) {
            .vdm => |v| upsertTarget(conn, v),
            else => publish(conn, sentence),
        }
    }
    // The whole read as ONE bus frame: a fraction of the event pressure of
    // per-line frames, and a multipart AIS group's fragments stay adjacent.
    if (bus_len > 0) {
        if (lk.busPublish("nmea0183", bus_buf[0..bus_len]) < 0) bus_denied = true;
    }
}

/// Only GRANTS_CHANGED matters here: it says whether the raw lines may go on
/// the bus at all, arriving once after start and again on every change.
pub fn onEvent(e: lk.raw.Event) !void {
    switch (e) {
        .grants_changed => |payload| bus_denied = !lk.raw.granted(payload, "bus.publish"),
        else => {},
    }
}

/// The row's NMEA 4.10 TAG block (`\s:lk2*hh\`). The tag is what lets a
/// consumer merging several gateways tell the streams apart — a multipart
/// AIS message reassembles only within one stream — and it survives verbatim
/// into anything downstream that re-serves the sentences.
fn rowTag(buf: []u8, place: u32) []const u8 {
    var body_buf: [16]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "s:lk{d}", .{place}) catch return "";
    var sum: u8 = 0;
    for (body) |c| sum ^= c;
    return std.fmt.bufPrint(buf, "\\{s}*{X:0>2}\\", .{ body, sum }) catch "";
}

/// One tagged line onto the pending bus frame. Appends are per-line atomic:
/// a line that does not fit is dropped whole, never torn.
fn appendRaw(len: *usize, tag: []const u8, line: []const u8) void {
    const needed = tag.len + line.len + 2;
    if (len.* + needed > bus_buf.len) return;
    @memcpy(bus_buf[len.*..][0..tag.len], tag);
    @memcpy(bus_buf[len.* + tag.len ..][0..line.len], line);
    bus_buf[len.* + needed - 2] = '\r';
    bus_buf[len.* + needed - 1] = '\n';
    len.* += needed;
}

fn publish(conn: *Connection, sentence: parser.Sentence) void {
    const ups = paths.fromSentence(sentence);
    if (ups.slice().len == 0) return;
    var p = lk.Publish.from(conn);
    for (ups.slice()) |u| switch (u.value) {
        .number => |v| p.number(u.path.text(), v),
        .position => |g| p.position(u.path.text(), .{ .lat = g.lat, .lon = g.lon }),
    };
    _ = p.send();
}

/// One AIVDM sentence, which is a fragment of an AIS message. The assembler
/// answers only when the last fragment lands.
fn upsertTarget(conn: *Connection, v: parser.Vdm) void {
    const msg = conn.state.assembler.push(v) orelse return;
    // AIVDO is this receiver's own transmission. Own ship comes from the
    // position sentences; upserting it as an AIS target would draw the boat
    // twice.
    if (msg.own) return;
    var text: [parser.text_scratch_bytes]u8 = undefined;
    const decoded = parser.decode(msg.payload, msg.fill, &text) catch return;
    const f = paths.fromAis(decoded) orelse return;

    var u = lk.Upsert.from(conn);
    var target = lk.Target{
        .mmsi = f.mmsi,
        .at = if (f.lat != null and f.lon != null)
            lk.Point{ .lat = f.lat.?, .lon = f.lon.? }
        else
            null,
        .sog_mps = f.sog_mps,
        .cog_deg = f.cog,
        .heading_deg = f.heading,
        .aton = f.aton,
        .aton_type = f.aton_type,
        .virtual_aton = f.virtual_aton,
        .off_position = f.off_position,
    };
    if (f.name) |n| target.name_str.set(n);
    u.target(target);
    _ = u.send();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = @import("std").testing;

test "a raw line is tagged with its source row and appended whole or not at all" {
    var len: usize = 0;
    var t1: [24]u8 = undefined;
    var t2: [24]u8 = undefined;
    appendRaw(&len, rowTag(&t1, 1), "!AIVDM,1,1,,A,13HOI:0P0000VOHLCnHQKwvL05Ip,0*23");
    appendRaw(&len, rowTag(&t2, 2), "$GPRMC,092750.000,A,5321.6802,N,00630.3372,W,0.02,31.66,280511,,,A*43");
    // XOR of "s:lk1" is 0x7F; the tag reads back exactly as NMEA 4.10 writes it.
    try t.expect(std.mem.startsWith(u8, bus_buf[0..len], "\\s:lk1*7F\\!AIVDM,"));
    try t.expect(std.mem.indexOf(u8, bus_buf[0..len], "\r\n\\s:lk2*7C\\$GPRMC,") != null);
    try t.expect(std.mem.endsWith(u8, bus_buf[0..len], "*43\r\n"));

    // A line past the buffer is dropped whole, never torn.
    var full: usize = bus_buf.len - 4;
    appendRaw(&full, rowTag(&t1, 1), "$GPRMC,092750.000,A*68");
    try t.expectEqual(bus_buf.len - 4, full);
}
