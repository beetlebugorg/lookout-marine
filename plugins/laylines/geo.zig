//! Layline geometry: the two close-hauled bearings for a true wind direction,
//! and where a line of a given length along one of them ends.
//!
//! EARTH MODEL. A sphere of radius 6 371 008.8 m (the IUGG mean radius), not
//! the WGS84 ellipsoid the chart is drawn on. The endpoint is the great-circle
//! destination, exact on that sphere; the whole error is sphere-vs-ellipsoid,
//! which over a 1 nm line is under 4 m — a tenth of the line's own width at
//! harbour zoom, and far below the wind instrument's error. Anything longer
//! than a few miles, or any distance the mariner is asked to trust as a number,
//! wants a real geodesic instead.
//!
//! ANGLES. Degrees, true, clockwise from north. `twd` is the direction the wind
//! blows FROM, the same convention as `environment.wind.directionTrue`.

const std = @import("std");

/// IUGG mean earth radius.
pub const earth_radius_m: f64 = 6371008.8;

pub const nautical_mile_m: f64 = 1852.0;

/// How long a layline is drawn. One mile is about as far ahead as a tack is
/// worth planning in the harbour scale this prototype renders.
pub const layline_length_m: f64 = nautical_mile_m;

/// The angle a boat can hold off the true wind. A single number for every hull
/// is a simplification: real close-hauled angles run 35-50 degrees with the
/// boat, the sails and the sea state. 45 is what the brief freezes.
pub const close_hauled_deg: f64 = 45.0;

pub const Point = struct { lat: f64, lon: f64 };

/// The two endpoints of one boat's laylines.
pub const Pair = struct { port: Point, stbd: Point };

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

/// The bearing of the port-side layline: 45 degrees anticlockwise of the wind's
/// from-direction.
pub fn portBearingDeg(twd_deg: f64) f64 {
    return normalizeDeg(twd_deg - close_hauled_deg);
}

/// The bearing of the starboard-side layline: 45 degrees clockwise of the
/// wind's from-direction.
pub fn stbdBearingDeg(twd_deg: f64) f64 {
    return normalizeDeg(twd_deg + close_hauled_deg);
}

/// True when a fix can be the origin of a layline: both parts finite and on
/// the globe. A NaN or an off-globe pair reaching the overlay is a batch the
/// host drops whole, taking the good line with the bad one.
pub fn validPosition(lat: f64, lon: f64) bool {
    return std.math.isFinite(lat) and std.math.isFinite(lon) and
        @abs(lat) <= 90.0 and @abs(lon) <= 180.0;
}

/// True when a wind direction can be drawn from. Any finite angle will do —
/// `normalizeDeg` folds it — but a NaN has no bearing at all.
pub fn validDirection(deg: f64) bool {
    return std.math.isFinite(deg);
}

/// Great-circle destination from `from`, `distance_m` along `bearing_deg`.
pub fn destinationPoint(from: Point, bearing_deg: f64, distance_m: f64) Point {
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

/// Both layline endpoints for a boat at `from` in a true wind from `twd_deg`.
pub fn endpoints(from: Point, twd_deg: f64, length_m: f64) Pair {
    return .{
        .port = destinationPoint(from, portBearingDeg(twd_deg), length_m),
        .stbd = destinationPoint(from, stbdBearingDeg(twd_deg), length_m),
    };
}

/// Great-circle distance in metres. Used to check the endpoints; the plugin
/// itself never measures.
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

// ---------------------------------------------------------------------------

const annapolis = Point{ .lat = 38.9763, .lon = -76.4767 };

test "normalizeDeg folds into [0,360)" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f64, 315), normalizeDeg(-45), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0), normalizeDeg(720), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 359.9), normalizeDeg(359.9), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 10), normalizeDeg(370), 1e-12);
    try t.expectEqual(@as(f64, 0), normalizeDeg(std.math.nan(f64)));
}

test "wrapLon folds into [-180,180)" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f64, -179), wrapLon(181), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 179), wrapLon(-181), 1e-12);
    try t.expectApproxEqAbs(@as(f64, -76.4767), wrapLon(-76.4767), 1e-12);
}

test "a fix has to be finite and on the globe" {
    const t = std.testing;
    try t.expect(validPosition(38.9763, -76.4767));
    try t.expect(validPosition(-90, 180));
    try t.expect(!validPosition(90.1, 0));
    try t.expect(!validPosition(0, -180.5));
    try t.expect(!validPosition(std.math.nan(f64), 0));
    try t.expect(!validPosition(0, std.math.inf(f64)));
    try t.expect(validDirection(-720));
    try t.expect(!validDirection(std.math.nan(f64)));
}

test "1 nm at 090 from Annapolis lands where the flat-earth check says" {
    const t = std.testing;
    const p = destinationPoint(annapolis, 90, nautical_mile_m);

    // Flat approximation for the same leg: dlon = d / (R cos lat).
    const dlon_deg = std.math.radiansToDegrees(nautical_mile_m /
        (earth_radius_m * @cos(std.math.degreesToRadians(annapolis.lat))));
    try t.expectApproxEqAbs(annapolis.lon + dlon_deg, p.lon, 1e-6);
    try t.expectApproxEqAbs(@as(f64, -76.4552757), p.lon, 1e-7);

    // Due east is the vertex of its great circle, so the latitude falls off by
    // a fraction of a metre rather than holding exactly.
    try t.expectApproxEqAbs(annapolis.lat, p.lat, 1e-5);
    try t.expect(p.lat < annapolis.lat);

    try t.expectApproxEqAbs(nautical_mile_m, distanceM(annapolis, p), 0.01);
    try t.expectApproxEqAbs(@as(f64, 90), initialBearingDeg(annapolis, p), 1e-6);
}

test "the cardinal legs are one mile long and point where they were sent" {
    const t = std.testing;
    for ([_]f64{ 0, 45, 90, 135, 180, 225, 270, 315, 359 }) |brg| {
        const p = destinationPoint(annapolis, brg, nautical_mile_m);
        try t.expectApproxEqAbs(nautical_mile_m, distanceM(annapolis, p), 0.01);
        try t.expectApproxEqAbs(brg, initialBearingDeg(annapolis, p), 1e-6);
    }

    // Due north: the latitude change is the arc over the radius, exactly.
    const north = destinationPoint(annapolis, 0, nautical_mile_m);
    const dlat_deg = std.math.radiansToDegrees(nautical_mile_m / earth_radius_m);
    try t.expectApproxEqAbs(annapolis.lat + dlat_deg, north.lat, 1e-9);
    try t.expectApproxEqAbs(annapolis.lon, north.lon, 1e-12);
}

test "a bearing out of range is the same leg as its folded form" {
    const t = std.testing;
    const a = destinationPoint(annapolis, -270, nautical_mile_m);
    const b = destinationPoint(annapolis, 90, nautical_mile_m);
    try t.expectApproxEqAbs(b.lat, a.lat, 1e-12);
    try t.expectApproxEqAbs(b.lon, a.lon, 1e-12);
}

test "layline bearings straddle the wind by the close-hauled angle" {
    const t = std.testing;
    try t.expectApproxEqAbs(@as(f64, 315), portBearingDeg(0), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 45), stbdBearingDeg(0), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 325), portBearingDeg(10), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 55), stbdBearingDeg(10), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 305), portBearingDeg(350), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 35), stbdBearingDeg(350), 1e-12);
}

test "the pair is symmetric about the wind and 90 degrees apart" {
    const t = std.testing;
    const pair = endpoints(annapolis, 210, layline_length_m);

    try t.expectApproxEqAbs(layline_length_m, distanceM(annapolis, pair.port), 0.01);
    try t.expectApproxEqAbs(layline_length_m, distanceM(annapolis, pair.stbd), 0.01);
    try t.expectApproxEqAbs(@as(f64, 165), initialBearingDeg(annapolis, pair.port), 1e-6);
    try t.expectApproxEqAbs(@as(f64, 255), initialBearingDeg(annapolis, pair.stbd), 1e-6);

    // Two 1 nm legs 90 degrees apart: the chord is 1 nm * sqrt(2), give or take
    // the sphere's own curvature over a mile.
    const chord = nautical_mile_m * @sqrt(2.0);
    try t.expectApproxEqAbs(chord, distanceM(pair.port, pair.stbd), 1.0);
}

test "a wind from the north puts the endpoints either side of the meridian" {
    const t = std.testing;
    const pair = endpoints(annapolis, 0, layline_length_m);
    try t.expect(pair.port.lon < annapolis.lon);
    try t.expect(pair.stbd.lon > annapolis.lon);
    try t.expect(pair.port.lat > annapolis.lat);
    try t.expectApproxEqAbs(pair.port.lat, pair.stbd.lat, 1e-12);
    try t.expectApproxEqAbs(annapolis.lon - pair.port.lon, pair.stbd.lon - annapolis.lon, 1e-12);
}
