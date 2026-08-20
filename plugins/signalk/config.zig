//! The Signal K servers the mariner keeps: the settings list, declared once.
//!
//! One boat can reach more than one server: the boat's own server on the
//! network, and a second one on a laptop that holds the instruments it
//! bridges. Each is a row here, and the library gives each connection its own
//! socket, its own reconnect clock and its own line in the settings window.
//!
//! The declaration is the whole schema. `lk.settingsJson` renders the
//! manifest's `settings` block from it, and the test at the bottom checks that
//! the manifest this plugin ships says the same thing — so a column cannot
//! drift from the code that reads it.
//!
//! This file reaches nothing that talks to the host, so `zig test config.zig`
//! runs natively while the same file compiles into the wasm module.

const std = @import("std");
const lk = @import("lk2");
const transport = @import("transport.zig");

/// Longest own-ship identity a hello can name. An MRN with a UUID is 65 bytes.
/// A longer one is not kept, so own ship reads as unnamed instead of matching
/// a truncated identity against nothing.
pub const max_identity = 128;

/// What one server's stream needs between events: the bytes of a document that
/// arrived in pieces, and what this server calls own ship.
pub const Stream = struct {
    doc: [transport.max_doc]u8 = undefined,
    framer: transport.Framer = .{ .buf = &.{} },
    /// From the server's hello. Deltas under this context are own ship and not
    /// an AIS target.
    self_id: lk.Str(max_identity) = .{},
};

pub const Connections = lk.connections(.{
    .key = "servers",
    .group = "Signal K servers",
    .footer = "A Signal K server sends the whole boat as one stream of updates on port 8375. " ++
        "Give its address, and everything switched on here feeds the same chart.",
    .empty = "No servers yet.",
    .add_label = "Add Server",
    // A server announces its WEBSOCKET, on port 3000, and not the plain stream
    // on 8375. A discovered row therefore arrives with the websocket switched
    // on, or it would dial the web page.
    //
    // `_signalk-http._tcp` is the same server announced a second time, and
    // this plugin does not speak HTTP, so it is left alone.
    .discover = &.{.{ .service = "_signalk-ws._tcp", .set = "{\"websocket\":true}" }},
    .columns = .{
        .name = .{
            .label = "Name",
            .desc = "What you call this server. Leave it empty to show the address.",
            .optional = true,
        },
        .host = .{
            .label = "Address",
            .desc = "The name or IP address of the Signal K server.",
            .default = "",
        },
        .port = .{
            .label = "Port",
            .desc = "Most Signal K servers stream on port 8375. Port 3000 is the web page, not the stream.",
            .min = 1,
            .max = 65535,
            .default = transport.default_tcp_port,
        },
        .enabled = .{
            .label = "On",
            .desc = "Off closes the stream and stops reconnecting.",
            .default = true,
        },
    },
    .Extra = struct {
        websocket: lk.Flag = .{
            .label = "WebSocket",
            .desc = "Read the WebSocket stream instead of the plain one. " ++
                "The reference server serves it on port 3000.",
            .default = false,
        },
    },
    .State = Stream,
    .rate_noun = "deltas",
    .status_empty = "no servers",
    .refused_detail = "websocket refused; the server is not on this boat's network",
});

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "the manifest ships the schema this file declares" {
    try lk.expectManifest(@embedFile("manifest.json"), .{Connections.lk_list});
}

test "a connection starts at the column defaults the schema names" {
    const conn = Connections.Connection{};
    try t.expectEqual(@as(u16, 0), conn.port);
    try t.expect(conn.enabled);
    // The transport column defaults off: a row a shell wrote badly must not
    // silently change transport.
    try t.expect(!conn.cols.websocket);
    try t.expectEqual(@as(usize, 0), conn.state.self_id.len);
}
