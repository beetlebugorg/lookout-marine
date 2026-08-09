//! The one setting the mariner has over this plugin, declared as the group the
//! settings window shows.
//!
//! The declaration is the whole schema. `lk.settingsJson` renders the
//! manifest's `settings` block from it, and the test at the bottom checks that
//! the manifest this plugin ships says the same thing, so a range cannot drift
//! from the code that clamps against it.
//!
//! UNITS. The group is written in minutes, which is what the pane shows and how
//! a mariner thinks about how far ahead to look. `Tuned` converts once, and the
//! rest of the plugin works in seconds.
//!
//! Nothing here calls a host import, so the same file compiles into the wasm
//! module and its tests run natively:
//!
//!   zig test --dep lk2 -Mroot=plugins/ownship/config.zig -Mlk2=plugins/common/lk2.zig

const std = @import("std");
const lk = @import("lk2");

pub const Vector = struct {
    pub const group = "Own ship";
    pub const tab: lk.Tab = .vessels;

    /// The same range the AIS plugin gives a target's vector: the question is
    /// the same one asked about own ship, and two different ranges for it in
    /// one settings window would be a puzzle rather than a choice.
    vector_min: lk.Num = .{
        .label = "Course vector",
        .desc = "How far ahead of the boat its course line reaches, at the speed it is making now.",
        .unit = "min",
        .min = 1,
        .max = 24,
        .default = 6,
    },
};

/// The groups, in the order the settings window shows them.
pub const groups = .{Vector};

/// The settings in SI.
pub const Tuned = struct {
    /// How far ahead the course vector reaches, seconds.
    vector_seconds: f64 = 6 * 60,

    /// What the mariner has set now. The library holds the values and clamps
    /// each one into its declared range before it lands here.
    pub fn now() Tuned {
        const v = lk.settings(Vector);
        return .{ .vector_seconds = v.vector_min * 60.0 };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "the manifest ships the schema this file declares" {
    try lk.expectManifest(@embedFile("manifest.json"), groups);
}

test "the declared default converts to the SI number the plugin works in" {
    // Nothing has read a config, so the library holds the declared default:
    // six minutes is 360 s.
    const s = Tuned.now();
    try t.expectEqual(@as(f64, 360), s.vector_seconds);
    try t.expectEqual(Tuned{}, s);
}
