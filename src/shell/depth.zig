//! The depth settings, derived from the boat.
//!
//! The first-run depth step has two questions: the draft, and the clearance
//! the mariner wants under the keel. The four numbers the engine shades water
//! with follow from them. Exported through lookout-shell.h.
//!
//! Every depth crosses the boundary in metres. The unit on screen selects the
//! ladder and the clearances, and sets what the step displays.

const std = @import("std");

/// The international foot, exactly.
pub const metres_per_foot = 0.3048;

/// The contours an S-57 survey draws, in each unit. The safety contour is the
/// first of these at or past the safety depth, because the chart shades on a
/// contour the survey has.
pub const ladder_metres = [_]f64{ 2, 5, 10, 20, 30, 50, 75, 100 };
pub const ladder_feet = [_]f64{ 6, 12, 18, 30, 60, 90, 120, 180, 240, 300 };

/// The clearances offered, round in both units.
pub const clearances_metres = [4]f64{ 0.3, 0.6, 1, 1.5 };
pub const clearances_feet = [4]f64{ 1, 2, 3, 5 };

/// The starting boat, a small keelboat, in the unit on screen. The stored
/// safety depth is no help as a start: it begins at the engine's 10 m, and a
/// draft read back out of that is 9.7 m.
const Boat = struct { draft: f64, clearance: f64 };
const start_metres = Boat{ .draft = 1.7, .clearance = 0.6 };
const start_feet = Boat{ .draft = 5.5, .clearance = 2.0 };

/// The plan, laid out as lookout_depth_plan in lookout-shell.h.
pub const Plan = extern struct {
    draft_m: f64,
    clearance_m: f64,
    draft_rounded_m: f64,
    safety_depth_m: f64,
    shallow_contour_m: f64,
    safety_contour_m: f64,
    deep_contour_m: f64,
    draft: f64,
    clearance: f64,
    safety_depth: f64,
    safety_contour: f64,
    deep_contour: f64,
    clearances: [4]f64,
    metres_per_unit: f64,
    /// One press of the draft stepper, and the deepest draft the step accepts,
    /// in the unit on screen.
    draft_step: f64,
    draft_max: f64,
};

/// One press of the draft stepper: half a foot, or a tenth of a metre.
const step_feet = 0.5;
const step_metres = 0.1;
/// The deepest draft the step accepts. A ship past it is shaded on the last
/// rung of the ladder anyway.
const max_feet = 100.0;
const max_metres = 30.0;

pub fn ladder(feet: bool) []const f64 {
    return if (feet) &ladder_feet else &ladder_metres;
}

/// The first rung at or past `depth`, or the last rung. A ship deeper than the
/// deepest contour is shaded on that contour.
fn rung(feet: bool, depth: f64) f64 {
    const l = ladder(feet);
    for (l) |r| if (r >= depth) return r;
    return l[l.len - 1];
}

/// The offered clearance nearest `want`. A tie picks the smaller one.
fn nearestClearance(feet: bool, want: f64) f64 {
    const all = if (feet) clearances_feet else clearances_metres;
    var best = all[0];
    for (all[1..]) |c| {
        if (@abs(c - want) < @abs(best - want)) best = c;
    }
    return best;
}

/// A value in the unit on screen, cleaned of the error a trip through metres
/// leaves. 5.5 ft is 1.6764 m, and back is 5.4999999 ft.
fn clean(v: f64) f64 {
    return @round(v * 1e6) / 1e6;
}

/// The four settings for a boat, and what the step displays.
///
/// A draft of zero or less, or one that is not finite, stands for the
/// starting boat.
pub fn plan(draft_m: f64, clearance_m: f64, feet: bool) Plan {
    const mpu: f64 = if (feet) metres_per_foot else 1;
    const seeded = !(draft_m > 0) or !std.math.isFinite(draft_m);

    const start = if (feet) start_feet else start_metres;
    const step: f64 = if (feet) step_feet else step_metres;
    const most: f64 = if (feet) max_feet else max_metres;
    const draft = if (seeded) start.draft else std.math.clamp(clean(draft_m / mpu), step, most);
    const clearance = if (seeded)
        start.clearance
    else
        nearestClearance(feet, if (std.math.isFinite(clearance_m)) clearance_m / mpu else 0);

    // Draft plus clearance, rounded up to a whole foot or metre. A chart names
    // its depths in whole numbers, and the fraction belongs to the keel rather
    // than to the water.
    const safety_depth = @ceil(clean(draft + clearance));
    const safety_contour = rung(feet, safety_depth);
    // The step does not ask for the deep contour. Twice the safety contour, up
    // the same ladder, so it displays round.
    const deep_contour = rung(feet, safety_contour * 2);

    return .{
        .draft_m = draft * mpu,
        .clearance_m = clearance * mpu,
        .draft_rounded_m = @round(draft * 2) / 2 * mpu,
        .safety_depth_m = safety_depth * mpu,
        // The shallow contour follows the safety depth, which makes the first
        // shade the water the boat cannot cross.
        .shallow_contour_m = safety_depth * mpu,
        .safety_contour_m = safety_contour * mpu,
        .deep_contour_m = deep_contour * mpu,
        .draft = draft,
        .clearance = clearance,
        .safety_depth = safety_depth,
        .safety_contour = safety_contour,
        .deep_contour = deep_contour,
        .clearances = if (feet) clearances_feet else clearances_metres,
        .metres_per_unit = mpu,
        .draft_step = step,
        .draft_max = most,
    };
}

// ---- tests ------------------------------------------------------------------

const t = std.testing;

/// A plan for a boat measured in the unit on screen.
fn inUnit(draft: f64, clearance: f64, feet: bool) Plan {
    const mpu: f64 = if (feet) metres_per_foot else 1;
    return plan(draft * mpu, clearance * mpu, feet);
}

test "the draft stays between one step and the most the step accepts" {
    try t.expectEqual(@as(f64, 100), inUnit(140, 2, true).draft);
    try t.expectEqual(@as(f64, 30), inUnit(40, 1, false).draft);
    try t.expectEqual(@as(f64, 0.5), inUnit(0.2, 2, true).draft);
    try t.expectEqual(@as(f64, 0.1), inUnit(0.05, 1, false).draft);
    try t.expectEqual(@as(f64, 0.5), inUnit(5, 2, true).draft_step);
    try t.expectEqual(@as(f64, 30), inUnit(5, 1, false).draft_max);
}

test "the safety depth rounds up to a whole unit" {
    try t.expectEqual(@as(f64, 3), inUnit(1.7, 0.6, false).safety_depth);
    try t.expectEqual(@as(f64, 8), inUnit(5.5, 2.0, true).safety_depth);
    // Already whole: the depth stays, in either unit.
    try t.expectEqual(@as(f64, 5), inUnit(4.0, 1.0, false).safety_depth);
    try t.expectEqual(@as(f64, 6), inUnit(4.0, 2.0, true).safety_depth);
    // A hair over still rounds up.
    try t.expectEqual(@as(f64, 6), inUnit(5.01, 0.3, false).safety_depth);
}

test "the safety contour is the first rung at or past the safety depth" {
    try t.expectEqual(@as(f64, 6), rung(true, 5));
    try t.expectEqual(@as(f64, 6), rung(true, 6));
    try t.expectEqual(@as(f64, 12), rung(true, 7));
    try t.expectEqual(@as(f64, 30), rung(true, 19));
    try t.expectEqual(@as(f64, 2), rung(false, 2));
    try t.expectEqual(@as(f64, 5), rung(false, 3));
    try t.expectEqual(@as(f64, 10), rung(false, 10));
    try t.expectEqual(@as(f64, 20), rung(false, 11));
    // Past the last rung, the last rung stands.
    try t.expectEqual(@as(f64, 300), rung(true, 400));
    try t.expectEqual(@as(f64, 100), rung(false, 500));
}

test "the deep contour is always deeper than the safety contour" {
    for (ladder_metres[0 .. ladder_metres.len - 1]) |r| {
        try t.expect(rung(false, r * 2) > r);
    }
    for (ladder_feet[0 .. ladder_feet.len - 1]) |r| {
        try t.expect(rung(true, r * 2) > r);
    }
}

test "the whole chain for a keelboat and a ship" {
    const keelboat = inUnit(1.7, 0.6, false);
    try t.expectEqual(@as(f64, 3), keelboat.safety_depth);
    try t.expectEqual(@as(f64, 5), keelboat.safety_contour);
    try t.expectEqual(@as(f64, 10), keelboat.deep_contour);

    const ship = inUnit(38, 5, true);
    try t.expectEqual(@as(f64, 43), ship.safety_depth);
    try t.expectEqual(@as(f64, 60), ship.safety_contour);
    try t.expectEqual(@as(f64, 120), ship.deep_contour);

    const eleven = inUnit(11, 1.5, false);
    try t.expectEqual(@as(f64, 13), eleven.safety_depth);
    try t.expectEqual(@as(f64, 20), eleven.safety_contour);
    try t.expectEqual(@as(f64, 50), eleven.deep_contour);

    const thirty = inUnit(30, 1.5, false);
    try t.expectEqual(@as(f64, 50), thirty.safety_contour);
    try t.expectEqual(@as(f64, 100), thirty.deep_contour);
}

test "the engine is given metres" {
    const p = inUnit(5.5, 2, true);
    try t.expectApproxEqAbs(@as(f64, 8 * 0.3048), p.safety_depth_m, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 12 * 0.3048), p.safety_contour_m, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 30 * 0.3048), p.deep_contour_m, 1e-12);
    try t.expectEqual(@as(f64, 0.3048), p.metres_per_unit);
    try t.expectEqual(@as(f64, 1), inUnit(1.7, 0.6, false).metres_per_unit);
}

test "the shallow contour follows the safety depth" {
    const p = inUnit(1.7, 0.6, false);
    try t.expectEqual(p.safety_depth_m, p.shallow_contour_m);
    const f = inUnit(5.5, 2, true);
    try t.expectEqual(f.safety_depth_m, f.shallow_contour_m);
}

test "no draft is the starting keelboat" {
    const m = plan(0, 0, false);
    try t.expectEqual(@as(f64, 1.7), m.draft);
    try t.expectEqual(@as(f64, 0.6), m.clearance);
    try t.expectEqual(@as(f64, 3), m.safety_depth);
    const f = plan(std.math.nan(f64), 0, true);
    try t.expectEqual(@as(f64, 5.5), f.draft);
    try t.expectEqual(@as(f64, 2), f.clearance);
    try t.expectEqual(@as(f64, 8), f.safety_depth);
    try t.expectEqual(@as(f64, 12), f.safety_contour);
    try t.expectEqual(@as(f64, 30), f.deep_contour);
}

test "the clearance snaps to one the unit offers" {
    // 0.6 m is about 2 ft, and 2 ft is one of the choices.
    try t.expectEqual(@as(f64, 2), plan(1, 0.6, true).clearance);
    // 3 ft is about 0.9 m, and the nearest metric choice is 1.
    try t.expectEqual(@as(f64, 1), plan(1, 3 * metres_per_foot, false).clearance);
    // Beyond either end, the end choice is used.
    try t.expectEqual(@as(f64, 5), plan(1, 99, true).clearance);
    try t.expectEqual(@as(f64, 0.3), plan(1, 0, false).clearance);
    try t.expectEqual(@as(f64, 5), plan(1, 99, true).clearances[3]);
}

test "a change of unit rounds the draft to half a unit" {
    // 1.7 m is 5.577 ft, to the nearest half.
    const f = plan(1.7, 0.6, true);
    try t.expectApproxEqAbs(@as(f64, 5.5 * metres_per_foot), f.draft_rounded_m, 1e-12);
    try t.expectEqual(@as(f64, 2), f.clearance);
    // 5.5 ft is 1.676 m, to the nearest half.
    const m = plan(f.draft_rounded_m, f.clearance_m, false);
    try t.expectEqual(@as(f64, 1.5), m.draft_rounded_m);
    try t.expectEqual(@as(f64, 0.6), m.clearance);
}

test "a draft in feet survives the trip through metres" {
    const p = inUnit(5.5, 2, true);
    try t.expectEqual(@as(f64, 5.5), p.draft);
    try t.expectEqual(@as(f64, 2), p.clearance);
}

test "the ladders climb" {
    for ([_][]const f64{ &ladder_metres, &ladder_feet }) |l| {
        try t.expect(l[0] > 0);
        for (l[0 .. l.len - 1], l[1..]) |a, b| try t.expect(a < b);
    }
}
