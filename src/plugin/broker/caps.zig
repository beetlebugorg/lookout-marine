//! The vocabulary the manifest and the event wire are written in: the event
//! kinds a plugin receives, the levels its log lines go out at, and the
//! capabilities a grant is made of.
//!
//! Nothing here reaches the broker, so it is the one part of the plugin host
//! that a reader can take in whole.

const std = @import("std");

// ---- event kinds (PROTOTYPE.md) --------------------------------------------

pub const Kind = struct {
    pub const config_changed: u32 = 1;
    pub const view_changed: u32 = 2;
    pub const timer: u32 = 3;
    pub const tcp_connected: u32 = 4;
    pub const tcp_data: u32 = 5;
    pub const tcp_closed: u32 = 6;
    pub const udp_data: u32 = 7;
    pub const http_response: u32 = 8;
    pub const file_opened: u32 = 9;
    pub const store_changed: u32 = 10;
    pub const ais_changed: u32 = 11;
    pub const ws_open: u32 = 12;
    pub const ws_data: u32 = 13;
    pub const ws_closed: u32 = 14;
    pub const table_open: u32 = 15;
    pub const table_closed: u32 = 16;
    pub const grants_changed: u32 = 17;
    pub const bus_data: u32 = 18;
    pub const shutdown: u32 = 99;
};

// ---- log levels ------------------------------------------------------------

pub const level_debug: u32 = 0;
pub const level_info: u32 = 1;
pub const level_warn: u32 = 2;
pub const level_err: u32 = 3;

/// Where plugin log lines, grant refusals and alerts go. `plugin` is the
/// manifest id, or "host" for the host's own lines. The default prints to
/// stderr; the harness and the tests install their own.
pub const LogFn = *const fn (ctx: ?*anyopaque, level: u32, plugin: []const u8, msg: []const u8) void;

fn levelName(level: u32) []const u8 {
    return switch (level) {
        0 => "debug",
        1 => "info",
        2 => "warn",
        else => "error",
    };
}

pub fn defaultLog(ctx: ?*anyopaque, level: u32, plugin: []const u8, msg: []const u8) void {
    _ = ctx;
    std.debug.print("plugin {s} [{s}] {s}\n", .{ plugin, levelName(level), msg });
}

// ---- capabilities ----------------------------------------------------------

/// The manifest's capability vocabulary. A plugin is granted a subset.
pub const Cap = enum {
    net_tcp_client,
    net_udp,
    net_http,
    net_ws,
    vessel_publish,
    ais_publish,
    vessel_read,
    ais_read,
    view_read,
    overlay_draw,
    alerts_raise,
    bus_publish,
    bus_read,
    storage,
    files,

    pub fn name(self: Cap) []const u8 {
        return switch (self) {
            .net_tcp_client => "net.tcp-client",
            .net_udp => "net.udp",
            .net_http => "net.http",
            .net_ws => "net.ws",
            .vessel_publish => "vessel.publish",
            .ais_publish => "ais.publish",
            .vessel_read => "vessel.read",
            .ais_read => "ais.read",
            .view_read => "view.read",
            .overlay_draw => "overlay.draw",
            .alerts_raise => "alerts.raise",
            .bus_publish => "bus.publish",
            .bus_read => "bus.read",
            .storage => "storage",
            .files => "files",
        };
    }

    /// What a capability's manifest entry carries beyond its own name.
    ///
    /// Every grant that reaches OUTWARD carries the reach: the addresses a
    /// plugin may dial, or the ports it may listen on. A manifest that asks
    /// for one of these as a bare name is refused, because "may reach any
    /// server on the internet" is not a sentence a mariner can consent to,
    /// and an empty list is the same grant written shorter.
    pub const Carries = enum {
        /// Nothing: the grant is the whole permission.
        nothing,
        /// Addresses, each a hostname or the `local` token.
        addresses,
        /// Port numbers.
        ports,
        /// Bus topic names. The host validates only their shape, never their
        /// meaning, so a new topic needs no host change.
        topics,
    };

    pub fn carries(self: Cap) Carries {
        return switch (self) {
            .net_tcp_client, .net_http, .net_ws => .addresses,
            .net_udp => .ports,
            .bus_publish, .bus_read => .topics,
            else => .nothing,
        };
    }

    pub fn fromName(text: []const u8) ?Cap {
        inline for (comptime std.enums.values(Cap)) |c| {
            if (std.mem.eql(u8, text, c.name())) return c;
        }
        return null;
    }
};

pub const Caps = std.EnumSet(Cap);

/// True when the topic list contains this topic, matched exactly.
pub fn topicListed(topics: []const []const u8, topic: []const u8) bool {
    for (topics) |entry| if (std.mem.eql(u8, entry, topic)) return true;
    return false;
}

const t = std.testing;

test "capability names round-trip" {
    for (std.enums.values(Cap)) |c| {
        try t.expectEqual(c, Cap.fromName(c.name()).?);
    }
    try t.expect(Cap.fromName("net.mqtt") == null);
    // Every grant that reaches outward carries its reach, and nothing else
    // carries anything.
    try t.expectEqual(Cap.Carries.addresses, Cap.net_http.carries());
    try t.expectEqual(Cap.Carries.addresses, Cap.net_ws.carries());
    try t.expectEqual(Cap.Carries.addresses, Cap.net_tcp_client.carries());
    try t.expectEqual(Cap.Carries.ports, Cap.net_udp.carries());
    try t.expectEqual(Cap.Carries.nothing, Cap.storage.carries());
    try t.expectEqual(Cap.Carries.nothing, Cap.overlay_draw.carries());
}
