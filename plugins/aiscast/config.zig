//! The AIS relays the mariner keeps: the settings list, declared once.
//! One row dials one relay; the default row reaches ais.openwaters.io
//! and most boats never add another.
//!
//! The declaration is the whole schema. `lk.settingsJson` renders the
//! manifest's `settings` block from it, and the test at the bottom checks that
//! the manifest this plugin ships says the same thing — so a column cannot
//! drift from the code that reads it.

const std = @import("std");
const lk = @import("lk2");

/// What one relay's stream needs between events: which box the open
/// subscription covers, and the resubscribe clock.
pub const Stream = struct {
    /// The view the current subscription was built from, and the padded,
    /// area-capped box actually sent — hysteresis measures the centre against
    /// the box and the zoom against the view. Null until the first subscribe
    /// frame goes out on this socket.
    sub_view: ?lk.ViewBox = null,
    sub_box: ?lk.ViewBox = null,
    /// When the last subscribe frame went out, monotonic. Guards the relay's
    /// subscription rate limit.
    last_sub_ms: i64 = 0,
    /// True once a register frame went out on THIS socket — at most one per
    /// socket lifetime, and the key reply is trusted only where the register
    /// was sent. The whole struct resets when the connection restarts, so no
    /// register state outlives its socket.
    registered: bool = false,
    /// True when the relay's welcome frame said this socket may publish. The
    /// welcome is the first frame on every accepted socket and comes again
    /// after an in-band register, so this is the relay's word, not a guess
    /// from having dialled with a key.
    keyed: bool = false,
    /// The subscribed-area cap the welcome advertised, square degrees with
    /// the safety margin applied; null until a welcome has arrived, when the
    /// anonymous tier's cap is assumed.
    area_cap: ?f64 = null,
    /// True once the relay acknowledged a publish on this socket, which is
    /// when the row's note may honestly say "sharing".
    acked: bool = false,
};

pub const Connections = lk.connections(.{
    .key = "servers",
    .group = "Internet AIS",
    .footer = "Send and receive AIS over the internet via the AISCast protocol.",
    .empty = "No servers yet.",
    .add_label = "Add Server",
    .columns = .{
        .name = .{
            .label = "Name",
            .desc = "What you call this server. Leave it empty to show the address.",
            .default = "Open Waters AIS",
        },
        .host = .{
            .label = "Address",
            .desc = "The AIS relay to connect to.",
            .default = "ais.openwaters.io",
        },
        .port = .{
            .label = "Port",
            .desc = "The relay streams over TLS on port 443.",
            .min = 1,
            .max = 65535,
            .default = 443,
        },
        .enabled = .{
            .label = "On",
            .desc = "Off closes the stream and stops reconnecting.",
            .default = true,
        },
    },
    .Extra = struct {
        share: lk.Flag = .{
            .label = "Share AIS",
            .desc = "Send everything heard by the AIS receiver on a connected " ++
                "NMEA network back to the relay, this boat's own transponder " ++
                "reports included, so others see it too. Feeding earns higher limits.",
            .default = true,
        },
        token: lk.Text = .{
            .label = "Token",
            .desc = "An access token from the relay. " ++
                "Leave it empty to use an identity minted automatically.",
            .optional = true,
        },
    },
    .State = Stream,
    .rate_noun = "msgs",
    .status_empty = "no servers",
    .refused_detail = "outside this plugin's grant; it may only stream from ais.openwaters.io",
    // A box over open water legitimately carries nothing for minutes; the
    // default 30 s would cycle the connection against the relay's connect
    // rate limit.
    .idle_ms = 120_000,
    // The relay refuses more than 20 connects a minute from one address; the
    // default 2 s retry would exceed that on a flapping link.
    .reconnect_ms = 5_000,
});

pub const groups = .{Connections.lk_list};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "the manifest ships the schema this file declares" {
    try lk.expectManifest(@embedFile("manifest.json"), groups);
}

test "a connection starts at the column defaults the schema names" {
    const conn = Connections.Connection{};
    try t.expectEqual(@as(u16, 0), conn.port);
    try t.expect(conn.enabled);
    try t.expect(conn.state.sub_view == null);
}
