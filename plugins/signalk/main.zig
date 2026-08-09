//! Signal K over TCP or a websocket, from one or MORE servers.
//!
//! Signal K is the open marine data standard. A server on the boat collects
//! every instrument it can reach and streams the values as deltas: small
//! JSON documents that name a path and a value. This plugin opens the stream,
//! maps the paths it knows onto the host's own, and publishes them.
//!
//! Every server the mariner keeps is a row of the `servers` setting. The
//! library owns the connections end to end: the socket, the reconnect clock,
//! the pause switch and each row's line in the settings window. This file is
//! the protocol and nothing else: what to send when a stream opens, and what
//! each document means.
//!
//! EACH SERVER PUBLISHES AS ITSELF. The store keeps one source per row, so two
//! servers carrying the same path are arbitrated by its election in the
//! mariner's list order: the top row holds a path while its values are fresh,
//! and the one below it takes over when they go stale.
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
const Connection = Connections.Connection;

/// Longest websocket URL built for a connection: the scheme, an address of up
/// to 253 bytes, a port and the spec's path.
var url_buf: [320]u8 = undefined;

/// What the mapping threw away, counted for the whole plugin. The count is a
/// diagnostic, so one number over every server is what a reader wants.
var counts: delta.Counts = .{};

/// Where a connection is dialled. The two transports differ here and nowhere
/// else.
pub fn endpoint(conn: *Connection) lk.Endpoint {
    if (!conn.cols.websocket) return .{ .tcp = .{ .host = conn.host.text(), .port = conn.port } };
    const url = transport.wsUrl(&url_buf, conn.host.text(), conn.port) orelse
        return .{ .refused = "the address is too long for a websocket URL" };
    return .{ .ws = url };
}

/// A TCP stream starts with NO subscription — Signal K 1.8.2 fixes the initial
/// policy at `none` — so a client that sends nothing receives nothing after
/// the hello. The stream really starts here.
pub fn onOpen(conn: *Connection) void {
    const s = &conn.state;
    // A partial document and an identity from the last connection have nothing
    // to do with this one.
    s.framer = transport.Framer.init(kind(conn), &s.doc);
    s.self_id.set("");
    // A websocket message is already one document, so the CR LF the TCP
    // framing needs would be two bytes of noise inside it.
    _ = conn.send(if (conn.cols.websocket) transport.subscribe_body else transport.subscribe_all);
}

pub fn onData(conn: *Connection, bytes: []const u8) void {
    const s = &conn.state;
    if (s.framer.buf.len == 0) s.framer = transport.Framer.init(kind(conn), &s.doc);
    var it = s.framer.feed(bytes);
    while (it.next()) |doc| {
        conn.count(1);
        switch (delta.parse(lk.scratch(), doc, s.self_id.text(), &counts)) {
            // A hello with no `self`, or one too long to keep, leaves the
            // identity empty. An empty identity matches no context, so own
            // ship stays unpublished and the connection's line says so.
            .hello => |id| if (id.len > 0 and id.len <= cfg.max_identity) s.self_id.set(id),
            .own => |ups| publishOwn(conn, ups),
            .target => |target| upsert(conn, target),
            .ignored => {},
        }
    }
}

/// A hello may leave `self` out. Deltas then carry a concrete vessel URN that
/// nothing can match against own ship, and only the AIS targets get through.
pub fn connectionNote(conn: *Connection) []const u8 {
    return if (conn.rate > 0 and conn.state.self_id.len == 0) "own ship not named" else "";
}

fn kind(conn: *Connection) transport.Kind {
    return if (conn.cols.websocket) .ws else .tcp;
}

fn publishOwn(conn: *Connection, ups: delta.Updates) void {
    var p = lk.Publish.from(conn);
    for (ups.slice()) |u| switch (u.value) {
        .number => |v| p.number(u.path.text(), v),
        .position => |g| p.position(u.path.text(), .{ .lat = g.lat, .lon = g.lon }),
        // The server holds the path and has no value for it.
        .none => p.clear(u.path.text()),
    };
    _ = p.send();
}

fn upsert(conn: *Connection, target: delta.TargetFields) void {
    var u = lk.Upsert.from(conn);
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
