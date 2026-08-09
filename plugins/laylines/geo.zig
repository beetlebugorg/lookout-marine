//! Layline geometry: the bearings a boat sails for a true wind direction, one
//! pair for the beat and one for the run.
//!
//! ANGLES. Degrees, true, clockwise from north. `twd` is the direction the wind
//! blows FROM, the same convention as `environment.wind.directionTrue`. The
//! sailing angle is measured off that from-direction, upwind and downwind
//! alike, so 45 gives a pair either side of the eye of the wind and 170 gives a
//! pair ten degrees either side of dead downwind.
//!
//! The great-circle leg the plugin draws along these bearings is
//! `lk.Point.destination`, which every plugin shares. This file holds only what
//! is about laylines.

const std = @import("std");

pub const nautical_mile_m: f64 = 1852.0;

/// How long a layline is drawn. One mile is about as far ahead as a tack is
/// worth planning in the harbour scale this prototype renders.
pub const layline_length_m: f64 = nautical_mile_m;

/// Fold a bearing into [0, 360).
pub fn normalizeDeg(deg: f64) f64 {
    if (!std.math.isFinite(deg)) return 0;
    const r = @mod(deg, 360.0);
    return if (r < 0) r + 360.0 else r;
}

/// The port layline: the course sailed on PORT TACK, wind over the port side,
/// which is `angle_deg` clockwise of the wind's from-direction.
///
/// The tack names the line, not the side of the wind it falls on. A boat
/// close-hauled on port tack in a northerly (TWD 0) is heading 045; that is
/// the port layline, even though it lies to the east of the wind. The same
/// arithmetic carries downwind: the wind is still over the port side at 170.
pub fn portBearingDeg(twd_deg: f64, angle_deg: f64) f64 {
    return normalizeDeg(twd_deg + angle_deg);
}

/// The starboard layline: the course on STARBOARD TACK, wind over the
/// starboard side, `angle_deg` anticlockwise of the wind's from-direction.
pub fn stbdBearingDeg(twd_deg: f64, angle_deg: f64) f64 {
    return normalizeDeg(twd_deg - angle_deg);
}

// ---------------------------------------------------------------------------

test "normalizeDeg folds into [0,360)" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f64, 315), normalizeDeg(-45), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0), normalizeDeg(720), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 359.9), normalizeDeg(359.9), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 10), normalizeDeg(370), 1e-12);
    try t.expectEqual(@as(f64, 0), normalizeDeg(std.math.nan(f64)));
}

test "the upwind bearings straddle the wind by the close-hauled angle" {
    const t = std.testing;
    // Port tack is the line clockwise of the wind: in a northerly, 045.
    try t.expectApproxEqAbs(@as(f64, 45), portBearingDeg(0, 45), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 315), stbdBearingDeg(0, 45), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 55), portBearingDeg(10, 45), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 325), stbdBearingDeg(10, 45), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 35), portBearingDeg(350, 45), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 305), stbdBearingDeg(350, 45), 1e-12);
    // A tighter boat points closer to the wind on both tacks.
    try t.expectApproxEqAbs(@as(f64, 30), portBearingDeg(0, 30), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 330), stbdBearingDeg(0, 30), 1e-12);
}

test "the downwind bearings fall either side of dead downwind" {
    const t = std.testing;
    // In a northerly the boat runs south, and 170 puts the two gybes ten
    // degrees either side of 180.
    try t.expectApproxEqAbs(@as(f64, 170), portBearingDeg(0, 170), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 190), stbdBearingDeg(0, 170), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 180), portBearingDeg(10, 170), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 200), stbdBearingDeg(10, 170), 1e-12);
    // A boat that has to gybe through a wide angle to keep the kite flying.
    try t.expectApproxEqAbs(@as(f64, 140), portBearingDeg(0, 140), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 220), stbdBearingDeg(0, 140), 1e-12);
    // Dead downwind is the degenerate case: one line, drawn twice.
    try t.expectApproxEqAbs(portBearingDeg(0, 180), stbdBearingDeg(0, 180), 1e-12);
}

test "the two bearings are twice the angle apart, whatever the wind" {
    const t = std.testing;
    for ([_]f64{ 25, 45, 60, 120, 170 }) |angle| {
        for ([_]f64{ 0, 10, 90, 210, 350, 359.9 }) |twd| {
            const spread = normalizeDeg(portBearingDeg(twd, angle) - stbdBearingDeg(twd, angle));
            try t.expectApproxEqAbs(2 * angle, spread, 1e-9);
        }
    }
}

test "a wind out of range gives the same bearings as its folded form" {
    const t = std.testing;
    try t.expectApproxEqAbs(portBearingDeg(10, 45), portBearingDeg(370, 45), 1e-12);
    try t.expectApproxEqAbs(stbdBearingDeg(10, 45), stbdBearingDeg(-350, 45), 1e-12);
    // A wind direction that is not a number folds to due north rather than
    // carrying a NaN into the overlay, where it would fail the whole batch.
    // The library refuses a non-finite reading before this, so nothing off a
    // real instrument reaches here; the fold is the second line of defence.
    try t.expectEqual(@as(f64, 0), portBearingDeg(std.math.nan(f64), 45));
    try t.expectEqual(@as(f64, 0), stbdBearingDeg(std.math.nan(f64), 45));
}
