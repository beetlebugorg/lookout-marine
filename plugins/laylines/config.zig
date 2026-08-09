//! The two angles the mariner has over this plugin, declared as the one group
//! the settings window shows.
//!
//! The declaration is the whole schema. `lk.settingsJson` renders the
//! manifest's `settings` block from it, and the test at the bottom checks that
//! the manifest this plugin ships says the same thing, so a range cannot drift
//! from the code that clamps against it.
//!
//! UNITS. Degrees off the true wind, which is the unit a polar is written in
//! and the unit the bearings are computed in. Angles are the exception to SI on
//! the boundary, so nothing is converted here.
//!
//! Nothing here calls a host import, so the same file compiles into the wasm
//! module and its tests run natively:
//!
//!   zig test --dep lk2 -Mroot=plugins/laylines/config.zig -Mlk2=plugins/common/lk2.zig

const std = @import("std");
const lk = @import("lk2");

pub const Angles = struct {
    pub const group = "Laylines";
    pub const tab: lk.Tab = .display;

    /// 25 is the closest a foiling boat holds; 60 is a heavy cruiser under a
    /// furled headsail in a steep sea, tacking through 120. Outside that the
    /// line is not a beat and the mariner is better served by a bearing.
    upwind_deg: lk.Num = .{
        .label = "Upwind angle",
        .desc = "How close to the true wind the boat holds on the beat. Half the angle you tack through.",
        .unit = "deg",
        .min = 25,
        .max = 60,
        .default = 45,
    },
    /// 120 is a fast boat that has to reach up to keep the kite pulling; 180 is
    /// a poled-out headsail dead before it, which is what a cruiser does.
    downwind_deg: lk.Num = .{
        .label = "Downwind angle",
        .desc = "How deep the boat runs, measured off the true wind the same way. At 180 the two lines lie on top of each other.",
        .unit = "deg",
        .min = 120,
        .max = 180,
        .default = 170,
    },
};

/// The groups, in the order the settings window shows them.
pub const groups = .{Angles};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "the manifest ships the schema this file declares" {
    try lk.expectManifest(@embedFile("manifest.json"), groups);
}

test "the declared defaults are the angles the plugin draws" {
    // Nothing has read a config, so the library holds the declared defaults.
    const s = lk.settings(Angles);
    try t.expectEqual(@as(f64, 45), s.upwind_deg);
    try t.expectEqual(@as(f64, 170), s.downwind_deg);
}
