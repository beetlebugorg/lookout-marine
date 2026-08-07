//! NMEA 0183 over TCP, from one or MORE gateways.
//!
//! NMEA 0183 is the instrument network's own wire format: one line per reading,
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
//! Everything published lands in ONE source: the store sees the plugin, not the
//! connection. Two connections carrying the same sentence therefore overwrite
//! each other in publish order, which is a real thing to fix later and not this
//! pass.
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

const lk = @import("lk2");
const parser = @import("parser.zig");
const paths = @import("paths.zig");
const cfg = @import("config.zig");

comptime {
    lk.plugin(@This());
}

pub const Connections = cfg.Connections;
const Connection = Connections.Connection;

/// A partial sentence and a half-assembled AIS message from the last connection
/// have nothing to do with this one, so the stream starts over here.
pub fn onOpen(conn: *Connection) void {
    const s = &conn.state;
    s.feeder = parser.Feeder.init(&s.line);
    s.assembler = .{};
}

pub fn onData(conn: *Connection, bytes: []const u8) void {
    const s = &conn.state;
    if (s.feeder.buf.len == 0) s.feeder = parser.Feeder.init(&s.line);
    var it = s.feeder.feed(bytes);
    while (it.next()) |line| {
        // The feeder returns complete, checksum-verified lines only, so this
        // is the connection's message rate.
        conn.count(1);
        // A sentence type this parser does not decode — GSV, GSA, a
        // proprietary line — or one whose fields are unreadable.
        const sentence = parser.parse(line) catch continue;
        switch (sentence) {
            .vdm => |v| upsertTarget(s, v),
            else => publish(sentence),
        }
    }
}

fn publish(sentence: parser.Sentence) void {
    const ups = paths.fromSentence(sentence);
    if (ups.slice().len == 0) return;
    var p = lk.Publish.begin();
    for (ups.slice()) |u| switch (u.value) {
        .number => |v| p.number(u.path.text(), v),
        .position => |g| p.position(u.path.text(), .{ .lat = g.lat, .lon = g.lon }),
    };
    _ = p.send();
}

/// One AIVDM sentence, which is a fragment of an AIS message. The assembler
/// answers only when the last fragment lands.
fn upsertTarget(s: *cfg.Stream, v: parser.Vdm) void {
    const msg = s.assembler.push(v) orelse return;
    // AIVDO is this receiver's own transmission. Own ship comes from the
    // position sentences; upserting it as an AIS target would draw the boat
    // twice.
    if (msg.own) return;
    var text: [parser.text_scratch_bytes]u8 = undefined;
    const decoded = parser.decode(msg.payload, msg.fill, &text) catch return;
    const f = paths.fromAis(decoded) orelse return;

    var u = lk.Upsert.begin();
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
