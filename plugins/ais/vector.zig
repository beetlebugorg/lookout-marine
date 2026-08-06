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
//! EARTH MODEL. A sphere of radius 6 371 008.8 m, the IUGG mean. Over the
//! kilometre or two these lines span, sphere against ellipsoid is centimetres.

const std = @import("std");

/// IUGG mean earth radius.
pub const earth_radius_m: f64 = 6371008.8;

pub const nautical_mile_m: f64 = 1852.0;

/// How far ahead a speed vector reaches, in seconds. Own ship uses the same
/// number.
pub const vector_seconds: f64 = 6 * 60;

/// Below this a course over ground is noise. 0.2 m/s is about 0.4 kn. Ownship
/// uses the same gate.
pub const min_sog_mps: f64 = 0.2;

/// The heading line's length. About 50 pt at zoom 15. A fixed screen length is
/// not expressible: an overlay polyline is anchored in lon/lat. See
/// PROTOTYPE-CONCERNS.md.
pub const heading_line_m: f64 = nautical_mile_m / 10.0;

/// Line weight, screen points. S-52's ordinary chart line is 0.6 mm, which is
/// 1.7 pt. Both target lines take it; solid against dashed already separates
/// them.
pub const line_width_pt: f64 = 1.7;

pub const Point = struct { lat: f64, lon: f64 };

/// Fold a bearing into [0, 360).
pub fn normalizeDeg(deg: f64) f64 {
    if (!std.math.isFinite(deg)) return 0;
    const r = @mod(deg, 360.0);
    return if (r < 0) r + 360.0 else r;
}

/// Fold a longitude into [-180, 180).
pub fn wrapLon(deg: f64) f64 {
    if (!std.math.isFinite(deg)) return 0;
    return @mod(deg + 180.0, 360.0) - 180.0;
}

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

/// Great-circle destination from `from`, `distance_m` along `bearing_deg`.
pub fn destination(from: Point, bearing_deg: f64, distance_m: f64) Point {
    const lat1 = std.math.degreesToRadians(from.lat);
    const lon1 = std.math.degreesToRadians(from.lon);
    const brg = std.math.degreesToRadians(normalizeDeg(bearing_deg));
    const d = distance_m / earth_radius_m;

    const sin_lat1 = @sin(lat1);
    const cos_lat1 = @cos(lat1);
    const sin_d = @sin(d);
    const cos_d = @cos(d);

    const sin_lat2 = std.math.clamp(sin_lat1 * cos_d + cos_lat1 * sin_d * @cos(brg), -1.0, 1.0);
    const lat2 = std.math.asin(sin_lat2);
    const y = @sin(brg) * sin_d * cos_lat1;
    const x = cos_d - sin_lat1 * sin_lat2;
    const lon2 = lon1 + std.math.atan2(y, x);

    return .{
        .lat = std.math.radiansToDegrees(lat2),
        .lon = wrapLon(std.math.radiansToDegrees(lon2)),
    };
}

/// Great-circle distance in metres. The plugin never measures; the tests do.
pub fn distanceM(a: Point, b: Point) f64 {
    const lat1 = std.math.degreesToRadians(a.lat);
    const lat2 = std.math.degreesToRadians(b.lat);
    const dlat = lat2 - lat1;
    const dlon = std.math.degreesToRadians(wrapLon(b.lon - a.lon));
    const s1 = @sin(dlat / 2);
    const s2 = @sin(dlon / 2);
    const h = s1 * s1 + @cos(lat1) * @cos(lat2) * s2 * s2;
    return 2 * earth_radius_m * std.math.asin(@sqrt(std.math.clamp(h, 0.0, 1.0)));
}

/// Initial great-circle bearing from `a` to `b`, degrees true.
pub fn initialBearingDeg(a: Point, b: Point) f64 {
    const lat1 = std.math.degreesToRadians(a.lat);
    const lat2 = std.math.degreesToRadians(b.lat);
    const dlon = std.math.degreesToRadians(wrapLon(b.lon - a.lon));
    const y = @sin(dlon) * @cos(lat2);
    const x = @cos(lat1) * @sin(lat2) - @sin(lat1) * @cos(lat2) * @cos(dlon);
    return normalizeDeg(std.math.radiansToDegrees(std.math.atan2(y, x)));
}

/// True when a target's position can be drawn from. A NaN or an off-globe pair
/// makes the host drop the whole batch, symbols of other targets included.
pub fn validPosition(lat: f64, lon: f64) bool {
    return std.math.isFinite(lat) and std.math.isFinite(lon) and
        @abs(lat) <= 90.0 and @abs(lon) <= 180.0;
}

/// One target line as the overlay wants it: two `[lon, lat]` points, the
/// target and the far end. Null when there is no angle or no length.
pub fn ray(from: Point, bearing_deg: ?f64, length_m: f64) ?[2][2]f64 {
    const brg = bearing_deg orelse return null;
    if (!std.math.isFinite(brg) or !(length_m > 0)) return null;
    if (!validPosition(from.lat, from.lon)) return null;
    const end = destination(from, brg, length_m);
    if (!validPosition(end.lat, end.lon)) return null;
    return .{ .{ from.lon, from.lat }, .{ end.lon, end.lat } };
}

// ---- tests -----------------------------------------------------------------

const t = std.testing;
const annapolis = Point{ .lat = 38.9763, .lon = -76.4767 };

test "a speed vector is six minutes of the target's speed" {
    // 10 knots is 5.144 m/s, so six minutes is 1 nm exactly.
    const ten_kn: f64 = 10.0 * nautical_mile_m / 3600.0;
    try t.expectApproxEqRel(nautical_mile_m, vectorLengthM(ten_kn), 1e-12);

    // Length is linear in speed: 5 kn is half a mile, 20 kn is two.
    try t.expectApproxEqRel(nautical_mile_m * 0.5, vectorLengthM(ten_kn * 0.5), 1e-12);
    try t.expectApproxEqRel(nautical_mile_m * 2.0, vectorLengthM(ten_kn * 2.0), 1e-12);

    // The same six minutes own ship uses.
    try t.expectEqual(@as(f64, 360), vector_seconds);
    try t.expectApproxEqRel(@as(f64, 1852.0), vectorLengthM(5.144444444), 1e-6);
}

test "a chosen vector time scales the length and nothing else" {
    const ten_kn = 10.0 * nautical_mile_m / 3600.0;
    // Twelve minutes of 10 kn is two miles; one minute is a sixth of one.
    try t.expectApproxEqRel(nautical_mile_m * 2.0, vectorLengthFor(ten_kn, 12 * 60), 1e-12);
    try t.expectApproxEqRel(nautical_mile_m / 6.0, vectorLengthFor(ten_kn, 60), 1e-12);
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
    try t.expectEqual(annapolis.lon, r[0][0]);
    try t.expectEqual(annapolis.lat, r[0][1]);
    const end = Point{ .lat = r[1][1], .lon = r[1][0] };
    try t.expectApproxEqAbs(heading_line_m, distanceM(annapolis, end), 0.01);
    try t.expectApproxEqAbs(@as(f64, 90), initialBearingDeg(annapolis, end), 1e-6);
    // Due east: longitude grows, latitude holds to a fraction of a metre.
    try t.expect(r[1][0] > annapolis.lon);
    try t.expectApproxEqAbs(annapolis.lat, r[1][1], 1e-6);

    // Every cardinal, at a 10 kn six-minute vector.
    const ten_kn: f64 = 10.0 * nautical_mile_m / 3600.0;
    for ([_]f64{ 0, 45, 90, 135, 180, 225, 270, 315, 359 }) |brg| {
        const v = ray(annapolis, brg, vectorLengthM(ten_kn)) orelse return error.TestExpectedRay;
        const p = Point{ .lat = v[1][1], .lon = v[1][0] };
        try t.expectApproxEqAbs(nautical_mile_m, distanceM(annapolis, p), 0.01);
        try t.expectApproxEqAbs(brg, initialBearingDeg(annapolis, p), 1e-6);
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
    const ten_kn: f64 = 10.0 * nautical_mile_m / 3600.0;
    try t.expectApproxEqRel(@as(f64, 0.1), heading_line_m / vectorLengthM(ten_kn), 1e-12);
    // Even a 2 kn target's vector is longer than its heading line.
    try t.expect(vectorLengthM(ten_kn * 0.2) > heading_line_m);
}

test "bearings and longitudes fold" {
    try t.expectApproxEqAbs(@as(f64, 315), normalizeDeg(-45), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 10), normalizeDeg(370), 1e-12);
    try t.expectEqual(@as(f64, 0), normalizeDeg(std.math.nan(f64)));
    try t.expectApproxEqAbs(@as(f64, -179), wrapLon(181), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 179), wrapLon(-181), 1e-12);

    // A ray across the antimeridian keeps a longitude the overlay accepts.
    const edge = Point{ .lat = 0, .lon = 179.99 };
    const r = ray(edge, 90, 5000) orelse return error.TestExpectedRay;
    try t.expect(r[1][0] >= -180 and r[1][0] < 180);
    try t.expect(r[1][0] < 0); // it wrapped
}
