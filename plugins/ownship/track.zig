//! Ownship track history and the short-range geodesy the overlay needs.
//!
//! Pure computation: no host imports, no allocation, no state outside the
//! `Track` the caller owns. Runs natively, so
//! `zig test plugins/ownship/track.zig` covers the parts of the plugin that
//! can be wrong arithmetically rather than wrong at the ABI.
//!
//! Coordinates are degrees, latitude first, except where a function says
//! `LonLat` — the overlay wire format is `[lon, lat]` and converting once, at
//! the copy, keeps the ordering flip in a single place.

const std = @import("std");

/// Mean Earth radius (IUGG R1). One value for both directions: this file
/// treats the Earth as a sphere, which at chartplotter distances costs less
/// than the projection the chart is drawn in already does.
pub const earth_radius_m: f64 = 6_371_008.8;

/// One international nautical mile.
pub const nm_m: f64 = 1852.0;

/// Points a `Track` keeps before the oldest is dropped.
pub const max_points: usize = 600;

const deg_to_rad: f64 = std.math.pi / 180.0;
const rad_to_deg: f64 = 180.0 / std.math.pi;

/// Smallest cos(latitude) used as a divisor. Above ~89.999° the east/west
/// metres-per-degree blows up and a destination longitude stops meaning
/// anything; clamping keeps the result finite instead of infinite.
const min_cos_lat: f64 = 1.0e-5;

/// Destination point from `lat_deg`/`lon_deg` along a true bearing
/// (degrees clockwise from north) for `dist_m` metres.
///
/// APPROXIMATION. Mean-latitude sailing: the travelled distance is split into
/// north and east components and each is divided by the metres-per-degree at
/// the midpoint latitude, i.e. the sphere is treated as locally flat. The
/// error against the great-circle solution grows as (d/R)^2 — well under a
/// metre at 1 nm, metres at 100 nm, and unusable for ocean crossings or
/// across a pole. Everything this plugin draws (a 1 nm heading line, a
/// 6-minute vector) is inside that window by orders of magnitude.
///
/// Taking the cosine at the midpoint rather than at the start costs one extra
/// cosine and makes this exactly the inverse of `distanceMeters`.
pub fn destination(lat_deg: f64, lon_deg: f64, bearing_deg: f64, dist_m: f64) [2]f64 {
    const b = bearing_deg * deg_to_rad;
    const north_m = dist_m * @cos(b);
    const east_m = dist_m * @sin(b);
    const dlat = (north_m / earth_radius_m) * rad_to_deg;
    const lat2 = lat_deg + dlat;
    const cos_lat = @max(@abs(@cos((lat_deg + lat2) * 0.5 * deg_to_rad)), min_cos_lat);
    const dlon = (east_m / (earth_radius_m * cos_lat)) * rad_to_deg;
    return .{ clampLat(lat2), wrapLon(lon_deg + dlon) };
}

/// Distance in metres between two positions, the inverse of `destination` and
/// with the same error behaviour. Longitude differences are wrapped, so a pair
/// straddling the antimeridian measures the short way.
pub fn distanceMeters(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const dlat = (lat2 - lat1) * deg_to_rad;
    const dlon = wrapLon(lon2 - lon1) * deg_to_rad;
    const cos_lat = @cos((lat1 + lat2) * 0.5 * deg_to_rad);
    const north_m = dlat * earth_radius_m;
    const east_m = dlon * cos_lat * earth_radius_m;
    return @sqrt(north_m * north_m + east_m * east_m);
}

/// Longitude folded into [-180, 180).
pub fn wrapLon(lon_deg: f64) f64 {
    if (!std.math.isFinite(lon_deg)) return 0;
    var v = @mod(lon_deg + 180.0, 360.0);
    if (v < 0) v += 360.0;
    return v - 180.0;
}

fn clampLat(lat_deg: f64) f64 {
    return std.math.clamp(lat_deg, -90.0, 90.0);
}

/// One kept position. `t_ms` is whatever clock the caller feeds `consider` —
/// the plugin uses monotonic milliseconds, the tests use plain integers.
pub const Point = struct {
    t_ms: i64,
    lat: f64,
    lon: f64,
};

/// The last `max_points` positions, oldest first, as a ring.
///
/// Fixed storage: a plugin has no heap worth the name, and a track that
/// cannot grow cannot leak. Overwriting the oldest point is the whole policy —
/// the mariner sees where the boat has been recently, not since the epoch.
pub const Track = struct {
    buf: [max_points]Point = undefined,
    /// Index of the oldest point. Meaningless while `len` is 0.
    start: usize = 0,
    len: usize = 0,

    pub fn count(self: *const Track) usize {
        return self.len;
    }

    pub fn clear(self: *Track) void {
        self.start = 0;
        self.len = 0;
    }

    /// The `i`th point, 0 = oldest. Asserts `i < count()`.
    pub fn at(self: *const Track, i: usize) Point {
        std.debug.assert(i < self.len);
        return self.buf[(self.start + i) % max_points];
    }

    /// The most recently kept point, or null on an empty track.
    pub fn newest(self: *const Track) ?Point {
        if (self.len == 0) return null;
        return self.at(self.len - 1);
    }

    /// Keep this position if it is at least `min_interval_ms` newer AND at
    /// least `min_dist_m` away from the last kept point; the first point is
    /// always kept. Returns true when the track changed.
    ///
    /// BOTH gates, not either: time alone would record 600 points of a boat
    /// sitting at anchor, and distance alone would record every jitter of a
    /// fix that updates at 10 Hz. A `t_ms` that goes backwards fails the time
    /// gate and is dropped, which is the safe answer for a clock that jumped.
    pub fn consider(self: *Track, t_ms: i64, lat: f64, lon: f64, min_interval_ms: i64, min_dist_m: f64) bool {
        if (!std.math.isFinite(lat) or !std.math.isFinite(lon)) return false;
        if (self.newest()) |last| {
            if (t_ms - last.t_ms < min_interval_ms) return false;
            if (distanceMeters(last.lat, last.lon, lat, lon) < min_dist_m) return false;
        }
        self.push(.{ .t_ms = t_ms, .lat = lat, .lon = lon });
        return true;
    }

    fn push(self: *Track, p: Point) void {
        const at_idx = (self.start + self.len) % max_points;
        self.buf[at_idx] = p;
        if (self.len == max_points) {
            self.start = (self.start + 1) % max_points;
        } else {
            self.len += 1;
        }
    }

    /// Copy the track into `out` as `[lon, lat]` pairs, oldest first, and
    /// return how many were written. Writes at most `out.len` points, keeping
    /// the NEWEST ones when `out` is shorter than the track.
    pub fn copyLonLat(self: *const Track, out: [][2]f64) usize {
        const n = @min(out.len, self.len);
        const skip = self.len - n;
        for (0..n) |i| {
            const p = self.at(skip + i);
            out[i] = .{ p.lon, p.lat };
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const t = std.testing;

// Annapolis harbour, the prototype's test ground.
const ann_lat: f64 = 38.9763;
const ann_lon: f64 = -76.4767;

test "1 nm north of Annapolis is about one minute of latitude" {
    const d = destination(ann_lat, ann_lon, 0, nm_m);
    try t.expectApproxEqAbs(@as(f64, 0.016_67), d[0] - ann_lat, 1e-4);
    try t.expectApproxEqAbs(ann_lon, d[1], 1e-12);
}

test "1 nm east moves longitude by a minute divided by cos(lat)" {
    const d = destination(ann_lat, ann_lon, 90, nm_m);
    const expect_dlon = 0.016_655 / @cos(ann_lat * deg_to_rad);
    try t.expectApproxEqAbs(expect_dlon, d[1] - ann_lon, 1e-4);
    try t.expectApproxEqAbs(ann_lat, d[0], 1e-12);
}

// Both directions project longitude at the midpoint latitude, so the
// round-trip is exact to floating point rather than to the approximation.
const roundtrip_tol: f64 = 1e-9;

test "destination and distance round-trip on every quadrant" {
    for ([_]f64{ 0, 45, 90, 135, 180, 225, 270, 315, 359 }) |brg| {
        for ([_]f64{ 10, 500, nm_m, 6 * nm_m }) |dist| {
            const d = destination(ann_lat, ann_lon, brg, dist);
            const back = distanceMeters(ann_lat, ann_lon, d[0], d[1]);
            try t.expectApproxEqRel(dist, back, roundtrip_tol);
        }
    }
}

test "a 6 minute vector at 5 knots is half a nautical mile" {
    const sog_mps: f64 = 5.0 * nm_m / 3600.0;
    const d = destination(ann_lat, ann_lon, 45, sog_mps * 360.0);
    try t.expectApproxEqRel(0.5 * nm_m, distanceMeters(ann_lat, ann_lon, d[0], d[1]), roundtrip_tol);
}

test "longitude wraps across the antimeridian" {
    const d = destination(0, 179.99, 90, 10 * nm_m);
    try t.expect(d[1] < 0); // crossed into the western hemisphere
    try t.expectApproxEqRel(10 * nm_m, distanceMeters(0, 179.99, d[0], d[1]), roundtrip_tol);
    try t.expectApproxEqAbs(@as(f64, -179.0), wrapLon(181.0), 1e-12);
    try t.expectApproxEqAbs(@as(f64, 179.0), wrapLon(-181.0), 1e-12);
}

test "a huge distance stays finite and clamps at the pole" {
    const d = destination(89.9, 0, 0, 1000 * nm_m);
    try t.expectEqual(@as(f64, 90.0), d[0]);
    try t.expect(std.math.isFinite(d[1]));
}

test "the first point is always kept" {
    var tr = Track{};
    try t.expect(tr.consider(0, ann_lat, ann_lon, 1000, 2.0));
    try t.expectEqual(@as(usize, 1), tr.count());
    try t.expectEqual(ann_lat, tr.newest().?.lat);
}

test "both the time gate and the distance gate must pass" {
    var tr = Track{};
    _ = tr.consider(0, ann_lat, ann_lon, 1000, 2.0);

    // 10 m away but only 999 ms later: too soon.
    const near_in_time = destination(ann_lat, ann_lon, 0, 10);
    try t.expect(!tr.consider(999, near_in_time[0], near_in_time[1], 1000, 2.0));

    // 5 s later but 1.5 m away: a boat at anchor swinging on its chain.
    const close = destination(ann_lat, ann_lon, 90, 1.5);
    try t.expect(!tr.consider(5_000, close[0], close[1], 1000, 2.0));

    // Far enough and long enough.
    const away = destination(ann_lat, ann_lon, 90, 2.5);
    try t.expect(tr.consider(6_000, away[0], away[1], 1000, 2.0));
    try t.expectEqual(@as(usize, 2), tr.count());

    // The gates measure from the last KEPT point, not from the last offer:
    // 2.5 m was accepted, so another 1.5 m from there is still too close.
    const nudge = destination(away[0], away[1], 90, 1.5);
    try t.expect(!tr.consider(7_000, nudge[0], nudge[1], 1000, 2.0));
    try t.expectEqual(@as(usize, 2), tr.count());
}

test "a clock that jumps backwards drops the point" {
    var tr = Track{};
    _ = tr.consider(10_000, ann_lat, ann_lon, 1000, 2.0);
    const away = destination(ann_lat, ann_lon, 0, 100);
    try t.expect(!tr.consider(9_000, away[0], away[1], 1000, 2.0));
    try t.expectEqual(@as(usize, 1), tr.count());
}

test "a non-finite position is refused" {
    var tr = Track{};
    try t.expect(!tr.consider(0, std.math.nan(f64), ann_lon, 1000, 2.0));
    try t.expect(!tr.consider(0, ann_lat, std.math.inf(f64), 1000, 2.0));
    try t.expectEqual(@as(usize, 0), tr.count());
}

test "the ring wraps and keeps the newest max_points" {
    var tr = Track{};
    // 900 points, each 10 m north of the last and 1 s later.
    var lat = ann_lat;
    for (0..900) |i| {
        const p = destination(lat, ann_lon, 0, 10);
        lat = p[0];
        try t.expect(tr.consider(@as(i64, @intCast(i)) * 1000, p[0], p[1], 1000, 2.0));
    }
    try t.expectEqual(max_points, tr.count());
    // Oldest surviving point is offer 300 (0-based), newest is offer 899.
    try t.expectEqual(@as(i64, 300_000), tr.at(0).t_ms);
    try t.expectEqual(@as(i64, 899_000), tr.newest().?.t_ms);
    // Monotonic in time, oldest first, with no seam at the wrap.
    for (1..tr.count()) |i| try t.expect(tr.at(i).t_ms > tr.at(i - 1).t_ms);
}

test "copyLonLat writes lon first, oldest first" {
    var tr = Track{};
    _ = tr.consider(0, 38.0, -76.0, 1000, 2.0);
    _ = tr.consider(1000, 38.1, -76.1, 1000, 2.0);
    _ = tr.consider(2000, 38.2, -76.2, 1000, 2.0);
    var out: [max_points][2]f64 = undefined;
    const n = tr.copyLonLat(&out);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(f64, -76.0), out[0][0]);
    try t.expectEqual(@as(f64, 38.0), out[0][1]);
    try t.expectEqual(@as(f64, -76.2), out[2][0]);
    try t.expectEqual(@as(f64, 38.2), out[2][1]);
}

test "copyLonLat into a short buffer keeps the newest points" {
    var tr = Track{};
    for (0..10) |i| {
        const lat = 38.0 + @as(f64, @floatFromInt(i)) * 0.001;
        _ = tr.consider(@as(i64, @intCast(i)) * 1000, lat, -76.0, 1000, 2.0);
    }
    var out: [4][2]f64 = undefined;
    const n = tr.copyLonLat(&out);
    try t.expectEqual(@as(usize, 4), n);
    try t.expectApproxEqAbs(@as(f64, 38.006), out[0][1], 1e-9);
    try t.expectApproxEqAbs(@as(f64, 38.009), out[3][1], 1e-9);
}

test "clear empties the track without disturbing the ring" {
    var tr = Track{};
    for (0..5) |i| {
        _ = tr.consider(@as(i64, @intCast(i)) * 1000, 38.0 + @as(f64, @floatFromInt(i)) * 0.001, -76.0, 1000, 2.0);
    }
    tr.clear();
    try t.expectEqual(@as(usize, 0), tr.count());
    try t.expect(tr.newest() == null);
    try t.expect(tr.consider(0, ann_lat, ann_lon, 1000, 2.0));
    try t.expectEqual(@as(usize, 1), tr.count());
}
