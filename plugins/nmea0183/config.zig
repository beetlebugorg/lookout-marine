//! The gateways the mariner keeps: the settings list, declared once.
//!
//! One boat can have several NMEA sources: a masthead AIS transponder on one
//! address, a plotter bridging the instruments on another. Each is a row here,
//! and the library gives each connection its own socket, its own reconnect
//! clock and its own line in the settings window.
//!
//! The declaration is the whole schema. `lk.settingsJson` renders the
//! manifest's `settings` block from it, and the test at the bottom checks that
//! the manifest this plugin ships says the same thing — so a column cannot
//! drift from the code that reads it.
//!
//! This file reaches nothing that talks to the host, so it runs natively under
//! the test step while the same file compiles into the wasm module.

const std = @import("std");
const lk = @import("lk2");
const parser = @import("parser.zig");

/// The port most WiFi gateways serve NMEA 0183 on.
pub const default_port: u16 = 10110;

/// One sentence at most: the standard's limit is 82 bytes, and a longer line is
/// dropped by the feeder rather than truncated into two plausible halves.
pub const max_line = 128;

/// What one gateway's stream needs between events: the bytes of a sentence that
/// arrived in pieces, and the fragments of a multi-part AIS message.
pub const Stream = struct {
    line: [max_line]u8 = undefined,
    /// Bound to `line` when the connection opens. A slice cannot point at a
    /// field of the object being initialised, so it starts empty.
    feeder: parser.Feeder = .{ .buf = &.{} },
    assembler: parser.Assembler = .{},
};

pub const Connections = lk.connections(.{
    .key = "connections",
    .group = "Connections",
    .footer = "Give the address of your instrument network's gateway. Most WiFi gateways serve " ++
        "NMEA 0183 on port 10110. Everything switched on here feeds the same chart.",
    .empty = "No connections yet.",
    .add_label = "Add Connection",
    .columns = .{
        .name = .{
            .label = "Name",
            .desc = "What you call this source. Leave it empty to show the address.",
            .optional = true,
        },
        .host = .{
            .label = "Address",
            .desc = "The name or IP address of the instrument network's gateway.",
            .default = "",
        },
        .port = .{
            .label = "Port",
            .desc = "Most WiFi gateways serve NMEA 0183 on port 10110.",
            .min = 1,
            .max = 65535,
            .default = default_port,
        },
        .enabled = .{
            .label = "On",
            .desc = "Off closes the connection and stops reconnecting.",
            .default = true,
        },
    },
    .State = Stream,
    .reconnect_ms = 2_000,
    .rate_noun = "msg",
    .status_empty = "no connections",
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
    // The feeder is bound when the connection opens, and the assembler holds
    // no fragment until one arrives.
    try t.expectEqual(@as(usize, 0), conn.state.feeder.buf.len);
    try t.expectEqual(@as(u64, 0), conn.state.feeder.stats.lines);
}
