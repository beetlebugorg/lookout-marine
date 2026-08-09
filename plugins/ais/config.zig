//! The five settings the mariner has over this plugin, declared as the two
//! groups the settings window shows.
//!
//! The declaration is the whole schema. `lk.settingsJson` renders the
//! manifest's `settings` block from it, and the test at the bottom checks that
//! the manifest this plugin ships says the same thing — so a range cannot drift
//! from the code that clamps against it.
//!
//! UNITS. The groups are written in the units a mariner reads — metres,
//! minutes, knots — because those are what the pane shows. `Tuned` converts
//! once, and the rest of the plugin works in seconds and metres per second.
//!
//! Nothing here calls a host import, so the same file compiles into the wasm
//! module and its tests run natively:
//!
//!   zig test --dep lk2 -Mroot=plugins/ais/config.zig -Mlk2=plugins/common/lk2.zig

const std = @import("std");
const lk = @import("lk2");

const knot_mps: f64 = 1852.0 / 3600.0;

pub const Alarms = struct {
    pub const group = "Collision alarm";
    pub const tab: lk.Tab = .alarms;

    cpa_limit: lk.Num = .{
        .label = "Closest approach (CPA)",
        .desc = "Alarm when a vessel will pass closer than this.",
        .unit = "m",
        .min = 93,
        .max = 9260,
        .default = 926,
    },
    tcpa_limit: lk.Num = .{
        .label = "Time to closest approach (TCPA)",
        .desc = "Alarm only when that pass is this soon or sooner.",
        .unit = "min",
        .min = 1,
        .max = 60,
        .default = 10,
    },
    cpa_alarm: lk.Flag = .{
        .label = "Collision alarm",
        .desc = "Sound the alarm and colour the vessel red. Off silences both.",
        .default = true,
    },
};

pub const Vessels = struct {
    pub const group = "AIS targets";
    pub const tab: lk.Tab = .vessels;

    vector_min: lk.Num = .{
        .label = "Course vectors",
        .desc = "How far ahead of each vessel its course line is drawn.",
        .unit = "min",
        .min = 1,
        .max = 24,
        .default = 6,
    },
    min_sog: lk.Num = .{
        .label = "Hide targets under",
        .desc = "Leave out vessels slower than this. Zero shows every one, moored ships included.",
        .unit = "kn",
        .min = 0,
        .max = 5,
        .default = 0,
    },
};

/// Both groups, in the order the settings window shows them.
pub const groups = .{ Alarms, Vessels };

/// The settings in SI, and the one rule that reads more than one of them.
pub const Tuned = struct {
    /// The danger gate's closest-approach limit, metres.
    cpa_limit_m: f64 = 926,
    /// The danger gate's time limit, seconds.
    tcpa_limit_s: f64 = 600,
    /// False silences the alarm AND the danger colour.
    cpa_alarm: bool = true,
    /// How far ahead a target's speed vector reaches, seconds.
    vector_seconds: f64 = 6 * 60,
    /// Targets slower than this are not drawn at all. Zero shows everything.
    min_sog_mps: f64 = 0,

    /// What the mariner has set now. The library holds the values and clamps
    /// each one into its declared range before it lands here.
    pub fn now() Tuned {
        const alarms = lk.settings(Alarms);
        const vessels = lk.settings(Vessels);
        return .{
            .cpa_limit_m = alarms.cpa_limit,
            .tcpa_limit_s = alarms.tcpa_limit * 60.0,
            .cpa_alarm = alarms.cpa_alarm,
            .vector_seconds = vessels.vector_min * 60.0,
            .min_sog_mps = vessels.min_sog * knot_mps,
        };
    }

    /// True when a vessel this slow is to be left off the chart. An aid to
    /// navigation never moves and is never hidden by this.
    pub fn hidden(self: Tuned, sog_mps: ?f64, aton: bool) bool {
        if (aton or self.min_sog_mps <= 0) return false;
        return (sog_mps orelse 0) < self.min_sog_mps;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

test "the manifest ships the schema this file declares" {
    try lk.expectManifest(@embedFile("manifest.json"), groups);
}

test "the manifest ships the table targets.zig declares" {
    try lk.expectTables(@embedFile("manifest.json"), .{@import("targets.zig").Targets});
}

test "the declared defaults convert to the SI numbers the plugin works in" {
    // Nothing has read a config, so the library holds every default the groups
    // above name: ten minutes is 600 s, six minutes is 360 s.
    const s = Tuned.now();
    try t.expectEqual(@as(f64, 926), s.cpa_limit_m);
    try t.expectEqual(@as(f64, 600), s.tcpa_limit_s);
    try t.expect(s.cpa_alarm);
    try t.expectEqual(@as(f64, 360), s.vector_seconds);
    try t.expectEqual(@as(f64, 0), s.min_sog_mps);
    // The struct's own defaults are those same numbers.
    try t.expectEqual(Tuned{}, s);
}

test "the slow-target gate hides vessels and never an aid to navigation" {
    const off = Tuned{};
    try t.expect(!off.hidden(0, false));
    try t.expect(!off.hidden(null, false));

    const on = Tuned{ .min_sog_mps = knot_mps }; // 1 kn = 0.514 m/s
    try t.expect(on.hidden(0.4, false));
    try t.expect(!on.hidden(0.6, false));
    // A target that has never reported a speed reads as stopped.
    try t.expect(on.hidden(null, false));
    // An aid to navigation is not a vessel: it is drawn however slow it is.
    try t.expect(!on.hidden(0, true));
    try t.expect(!on.hidden(null, true));
}
