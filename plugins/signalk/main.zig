//! Signal K over TCP or a websocket, from one or MORE servers.
//!
//! Signal K is the open marine data standard. A server on the boat collects
//! every instrument it can reach and streams the readings as deltas: small
//! JSON documents that name a path and a value. This plugin opens the stream,
//! maps the paths it knows onto the host's own, and publishes them.
//!
//! Every server the mariner keeps is a row of the `servers` setting. The
//! library owns the rows end to end — the socket, the reconnect clock, the
//! pause switch and each row's line in the settings window — so this file is
//! the protocol and nothing else: what to send when a stream opens, and what
//! each document means.
//!
//! Everything published lands in ONE source: the store sees the plugin, not
//! the row. This plugin is a source of its own beside `nmea0183`, so a Signal K
//! server and a NMEA gateway carrying the same path are arbitrated by the
//! store's election rather than by whichever arrived last.
//!
//! A document that is not JSON, a path outside the vocabulary and a vessel
//! with no MMSI are counted and dropped without a log line, because a real
//! stream carries all three continuously.
//!
//! TIMESTAMPS. Published values are stamped with the host's wall clock, not
//! with the ISO-8601 time a delta carries. The store measures staleness
//! against the host clock, and a server replaying a log would otherwise
//! publish values that are already stale.

const lk = @import("lk2");
const delta = @import("delta.zig");
const transport = @import("transport.zig");
const cfg = @import("config.zig");

comptime {
    lk.plugin(@This());
}

pub const Connections = cfg.Connections;
const Row = Connections.Row;

/// Longest websocket URL built for a row: the scheme, an address of up to 253
/// bytes, a port and the spec's path.
var url_buf: [320]u8 = undefined;

/// What the mapping threw away, counted for the whole plugin: the store has
/// one source whatever the row.
var counts: delta.Counts = .{};

/// Where a row is dialled. The two transports differ here and nowhere else.
pub fn endpoint(row: *Row) lk.Endpoint {
    if (!row.cols.websocket) return .{ .tcp = .{ .host = row.host.text(), .port = row.port } };
    const url = transport.wsUrl(&url_buf, row.host.text(), row.port) orelse
        return .{ .refused = "the address is too long for a websocket URL" };
    return .{ .ws = url };
}

/// A TCP stream starts with NO subscription — Signal K 1.8.2 fixes the initial
/// policy at `none` — so a client that sends nothing receives nothing after
/// the hello. The stream really starts here.
pub fn onOpen(row: *Row) void {
    const s = &row.state;
    // A partial document and an identity from the last connection have nothing
    // to do with this one.
    s.framer = transport.Framer.init(kind(row), &s.doc);
    s.self_id.set("");
    // A websocket message is already one document, so the CR LF the TCP
    // framing needs would be two bytes of noise inside it.
    _ = row.send(if (row.cols.websocket) transport.subscribe_body else transport.subscribe_all);
}

pub fn onData(row: *Row, bytes: []const u8) void {
    const s = &row.state;
    if (s.framer.buf.len == 0) s.framer = transport.Framer.init(kind(row), &s.doc);
    var it = s.framer.feed(bytes);
    while (it.next()) |doc| {
        row.count(1);
        switch (delta.parse(lk.scratch(), doc, s.self_id.text(), &counts)) {
            // A hello with no `self`, or one too long to keep, leaves the
            // identity empty. An empty identity matches no context, so own
            // ship stays unpublished and the row's line says so.
            .hello => |id| if (id.len > 0 and id.len <= cfg.max_identity) s.self_id.set(id),
            .own => |ups| publishOwn(ups),
            .target => |target| upsert(target),
            .ignored => {},
        }
    }
}

/// A hello may leave `self` out. Deltas then carry a concrete vessel URN that
/// nothing can match against own ship, and only the AIS targets get through.
pub fn rowNote(row: *Row) []const u8 {
    return if (row.rate > 0 and row.state.self_id.len == 0) "own ship not named" else "";
}

fn kind(row: *Row) transport.Kind {
    return if (row.cols.websocket) .ws else .tcp;
}

fn publishOwn(ups: delta.Updates) void {
    var p = lk.Publish.begin();
    for (ups.slice()) |u| switch (u.value) {
        .number => |v| p.number(u.path.text(), v),
        .position => |g| p.position(u.path.text(), .{ .lat = g.lat, .lon = g.lon }),
        // The server holds the path and has no reading for it.
        .none => p.clear(u.path.text()),
    };
    _ = p.send();
}

fn upsert(target: delta.TargetFields) void {
    var u = lk.Upsert.begin();
    var t = lk.Target{
        .mmsi = target.mmsi,
        .at = if (target.lat != null and target.lon != null)
            lk.Point{ .lat = target.lat.?, .lon = target.lon.? }
        else
            null,
        .sog_mps = target.sog,
        .cog_deg = target.cog,
        .heading_deg = target.heading,
    };
    if (target.name) |n| t.name_str.set(n);
    u.target(t);
    _ = u.send();
}
