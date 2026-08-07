//! Layline geometry: the two close-hauled bearings for a true wind direction.
//!
//! ANGLES. Degrees, true, clockwise from north. `twd` is the direction the wind
//! blows FROM, the same convention as `environment.wind.directionTrue`.
//!
//! The great-circle leg the plugin draws along these bearings is
//! `lk.Point.destination`, which every plugin shares. This file holds only what
//! is about laylines.

const std = @import("std");

pub const nautical_mile_m: f64 = 1852.0;

/// How long a layline is drawn. One mile is about as far ahead as a tack is
/// worth planning in the harbour scale this prototype renders.
pub const layline_length_m: f64 = nautical_mile_m;

/// The angle a boat can hold off the true wind. A single number for every hull
/// is a simplification: real close-hauled angles run 35-50 degrees with the
/// boat, the sails and the sea state. 45 is what the brief freezes.
pub const close_hauled_deg: f64 = 45.0;

/// Fold a bearing into [0, 360).
pub fn normalizeDeg(deg: f64) f64 {
    if (!std.math.isFinite(deg)) return 0;
    const r = @mod(deg, 360.0);
    return if (r < 0) r + 360.0 else r;
}

/// The port layline: the close-hauled course sailed on PORT TACK, wind over
/// the port side, which is 45 degrees clockwise of the wind's from-direction.
///
/// The tack names the line, not the side of the wind it falls on. A boat
/// close-hauled on port tack in a northerly (TWD 0) is heading 045; that is
/// the port layline, even though it lies to the east of the wind.
pub fn portBearingDeg(twd_deg: f64) f64 {
    return normalizeDeg(twd_deg + close_hauled_deg);
}

/// The starboard layline: the close-hauled course on STARBOARD TACK, wind over
/// the starboard side, 45 degrees anticlockwise of the wind's from-direction.
pub fn stbdBearingDeg(twd_deg: f64) f64 {
    return normalizeDeg(twd_deg - close_hauled_deg);
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

test "layline bearings straddle the wind by the close-hauled angle" {
    const t = std.testing;
    // Port tack is the line clockwise of the wind: in a northerly, 045.
    try t.expectApproxEqAbs(@as(f64, 45), portBearingDeg(0), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 315), stbdBearingDeg(0), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 55), portBearingDeg(10), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 325), stbdBearingDeg(10), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 35), portBearingDeg(350), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 305), stbdBearingDeg(350), 1e-12);
}

test "the two bearings are 90 degrees apart, whatever the wind" {
    const t = std.testing;
    for ([_]f64{ 0, 10, 90, 210, 350, 359.9 }) |twd| {
        const spread = normalizeDeg(portBearingDeg(twd) - stbdBearingDeg(twd));
        try t.expectApproxEqAbs(@as(f64, 90), spread, 1e-9);
    }
}

test "a wind out of range gives the same bearings as its folded form" {
    const t = std.testing;
    try t.expectApproxEqAbs(portBearingDeg(10), portBearingDeg(370), 1e-12);
    try t.expectApproxEqAbs(stbdBearingDeg(10), stbdBearingDeg(-350), 1e-12);
    // A wind direction that is not a number folds to due north rather than
    // carrying a NaN into the overlay, where it would fail the whole batch.
    // The library refuses a non-finite reading before this, so nothing off a
    // real instrument reaches here; the fold is the second line of defence.
    try t.expectEqual(@as(f64, 0), portBearingDeg(std.math.nan(f64)));
    try t.expectEqual(@as(f64, 0), stbdBearingDeg(std.math.nan(f64)));
}
