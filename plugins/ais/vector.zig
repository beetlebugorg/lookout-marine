//! The two lines an AIS target flies.
//!
//!   heading line   from the target along its reported heading. Solid.
//!   speed vector   along course over ground. Dashed. Length is speed times
//!                  vector time.
//!
//! Own ship uses the same vector time, so the two vectors cross where the
//! vessels are at the same moment. S-52 names the symbols (SY(AISVES01),
//! SY(VECGND21)) but defines no geometry for them; see PROTOTYPE-CONCERNS.md,
//! "What S-52 says".
//!
//! The great-circle leg comes from `lk.Point`, which is where the library keeps
//! it for every plugin. This file is the lengths and the two rules about when
//! there is no line to draw.

const std = @import("std");
const lk = @import("lk2");

/// How far ahead a speed vector reaches, in seconds. The settings default, and
/// what own ship uses.
pub const vector_seconds: f64 = 6 * 60;

/// Below this a course over ground is noise. 0.2 m/s is about 0.4 kn. Ownship
/// uses the same gate.
pub const min_sog_mps: f64 = 0.2;

/// The heading line's length. About 50 pt at zoom 15. A fixed screen length is
/// not expressible: an overlay polyline is anchored in lon/lat. See
/// PROTOTYPE-CONCERNS.md.
pub const heading_line_m: f64 = lk.nm_m / 10.0;

/// Line weight, screen points. S-52's ordinary chart line is 0.6 mm, which is
/// 1.7 pt. Both target lines take it; solid against dashed already separates
/// them.
pub const line_width_pt: f64 = 1.7;

/// How long a speed vector is, in metres: `vector_seconds` of `sog_mps`.
/// Zero when the target is under `min_sog_mps`, which tells the caller to draw
/// no vector.
pub fn vectorLengthM(sog_mps: f64) f64 {
    return vectorLengthFor(sog_mps, vector_seconds);
}

/// The same, for a vector time the mariner chose. Own ship's vector uses the
/// default; a mariner who wants to see further ahead moves both.
pub fn vectorLengthFor(sog_mps: f64, seconds: f64) f64 {
    if (!std.math.isFinite(sog_mps) or sog_mps <= min_sog_mps) return 0;
    if (!std.math.isFinite(seconds) or seconds <= 0) return 0;
    return sog_mps * seconds;
}

/// One target line: the target and the far end. Null when there is no angle or
/// no length — a target that reports no heading flies no heading line, and one
/// under the speed gate flies no vector.
pub fn ray(from: lk.Point, bearing_deg: ?f64, length_m: f64) ?[2]lk.Point {
    const brg = bearing_deg orelse return null;
    if (!std.math.isFinite(brg) or !(length_m > 0)) return null;
    if (!from.valid()) return null;
    const end = from.destination(brg, length_m);
    // A NaN or an off-globe pair makes the host drop the whole batch, symbols
    // of other targets included.
    if (!end.valid()) return null;
    return .{ from, end };
}

// ---- tests -----------------------------------------------------------------

const t = std.testing;
const annapolis = lk.Point{ .lat = 38.9763, .lon = -76.4767 };

test "a speed vector is six minutes of the target's speed" {
    // 10 knots is 5.144 m/s, so six minutes is 1 nm exactly.
    const ten_kn: f64 = 10.0 * lk.nm_m / 3600.0;
    try t.expectApproxEqRel(lk.nm_m, vectorLengthM(ten_kn), 1e-12);

    // Length is linear in speed: 5 kn is half a mile, 20 kn is two.
    try t.expectApproxEqRel(lk.nm_m * 0.5, vectorLengthM(ten_kn * 0.5), 1e-12);
    try t.expectApproxEqRel(lk.nm_m * 2.0, vectorLengthM(ten_kn * 2.0), 1e-12);

    // The same six minutes own ship uses.
    try t.expectEqual(@as(f64, 360), vector_seconds);
    try t.expectApproxEqRel(@as(f64, 1852.0), vectorLengthM(5.144444444), 1e-6);
}

test "a chosen vector time scales the length and nothing else" {
    const ten_kn = 10.0 * lk.nm_m / 3600.0;
    // Twelve minutes of 10 kn is two miles; one minute is a sixth of one.
    try t.expectApproxEqRel(lk.nm_m * 2.0, vectorLengthFor(ten_kn, 12 * 60), 1e-12);
    try t.expectApproxEqRel(lk.nm_m / 6.0, vectorLengthFor(ten_kn, 60), 1e-12);
    try t.expectEqual(vectorLengthM(ten_kn), vectorLengthFor(ten_kn, vector_seconds));
    // The slow gate still applies, and a vector time of nothing draws nothing.
    try t.expectEqual(@as(f64, 0), vectorLengthFor(0.1, 12 * 60));
    try t.expectEqual(@as(f64, 0), vectorLengthFor(ten_kn, 0));
    try t.expectEqual(@as(f64, 0), vectorLengthFor(ten_kn, -60));
}

test "a target too slow to have a course flies no vector" {
    try t.expectEqual(@as(f64, 0), vectorLengthM(0));
    try t.expectEqual(@as(f64, 0), vectorLengthM(0.1));
    try t.expectEqual(@as(f64, 0), vectorLengthM(min_sog_mps)); // the gate is exclusive
    try t.expect(vectorLengthM(min_sog_mps + 0.01) > 0);
    try t.expectEqual(@as(f64, 0), vectorLengthM(std.math.nan(f64)));
    try t.expectEqual(@as(f64, 0), vectorLengthM(-3));
}

test "a ray ends where it was sent, at the length it was given" {
    const r = ray(annapolis, 90, heading_line_m) orelse return error.TestExpectedRay;
    try t.expectEqual(annapolis.lat, r[0].lat);
    try t.expectEqual(annapolis.lon, r[0].lon);
    try t.expectApproxEqAbs(heading_line_m, annapolis.distanceTo(r[1]), 0.01);
    try t.expectApproxEqAbs(@as(f64, 90), annapolis.bearingTo(r[1]), 1e-6);
    // Due east: longitude grows, latitude holds to a fraction of a metre.
    try t.expect(r[1].lon > annapolis.lon);
    try t.expectApproxEqAbs(annapolis.lat, r[1].lat, 1e-6);

    // Every cardinal, at a 10 kn six-minute vector.
    const ten_kn: f64 = 10.0 * lk.nm_m / 3600.0;
    for ([_]f64{ 0, 45, 90, 135, 180, 225, 270, 315, 359 }) |brg| {
        const v = ray(annapolis, brg, vectorLengthM(ten_kn)) orelse return error.TestExpectedRay;
        try t.expectApproxEqAbs(lk.nm_m, annapolis.distanceTo(v[1]), 0.01);
        try t.expectApproxEqAbs(brg, annapolis.bearingTo(v[1]), 1e-6);
    }
}

test "a ray refuses what it cannot draw" {
    try t.expect(ray(annapolis, null, heading_line_m) == null); // no heading reported
    try t.expect(ray(annapolis, 90, 0) == null); // stopped: no vector
    try t.expect(ray(annapolis, 90, -5) == null);
    try t.expect(ray(annapolis, std.math.nan(f64), heading_line_m) == null);
    try t.expect(ray(.{ .lat = std.math.nan(f64), .lon = 0 }, 90, 100) == null);
    try t.expect(ray(.{ .lat = 91, .lon = 0 }, 90, 100) == null);
}

test "the heading line is short beside the vector it sits next to" {
    // For a 10 kn target the heading line is a tenth of the speed vector.
    const ten_kn: f64 = 10.0 * lk.nm_m / 3600.0;
    try t.expectApproxEqRel(@as(f64, 0.1), heading_line_m / vectorLengthM(ten_kn), 1e-12);
    // Even a 2 kn target's vector is longer than its heading line.
    try t.expect(vectorLengthM(ten_kn * 0.2) > heading_line_m);
}

test "a ray across the antimeridian keeps a longitude the overlay accepts" {
    const edge = lk.Point{ .lat = 0, .lon = 179.99 };
    const r = ray(edge, 90, 5000) orelse return error.TestExpectedRay;
    try t.expect(r[1].lon >= -180 and r[1].lon < 180);
    try t.expect(r[1].lon < 0); // it wrapped
}
