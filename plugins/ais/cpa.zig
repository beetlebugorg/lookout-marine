//! Closest point of approach between two vessels.
//!
//! Pure computation: no host imports, no allocation, no state. Runs natively,
//! so `zig test plugins/ais/cpa.zig` covers the arithmetic the collision alarm
//! rests on without a wasm runtime in the way.
//!
//! THE PLANE. Both positions are converted to metres on a flat east/north
//! plane: `m_per_deg_lat` metres per degree of latitude, the same scaled by
//! the cosine of the mean latitude for longitude. This is the plane
//! `tools/nmea_gen.zig` builds its scene on, so the generator's designed CPA
//! and the one computed here are the same number rather than two
//! approximations that happen to agree. Over the few kilometres an AIS target
//! is worth watching at, the error against a geodesic is well under a metre;
//! the model breaks down at ocean ranges and near the poles, neither of which
//! a CPA alarm is about.
//!
//! THE MOTION. Both vessels are taken to hold course and speed. Relative
//! position and relative velocity give a quadratic in time whose minimum is
//! the closest approach; that is the standard solution and it is what a
//! mariner means by CPA. A vessel that turns invalidates it, which is why the
//! plugin recomputes on every AIS report rather than trusting one answer.
//!
//! UNITS. Degrees for positions and courses, metres per second for speed,
//! metres and seconds out.

const std = @import("std");

/// Metres per degree of latitude. WGS-84's value near 39° N, and the constant
/// the synthetic log generator lays its scene out with.
pub const m_per_deg_lat: f64 = 111132.0;

/// Below this relative speed the two are holding station on each other: the
/// approach has no minimum worth naming and `tcpa_s` comes back null. 0.1 mm/s
/// moves 6 cm over the ten-minute alarm horizon.
pub const min_rel_speed_mps: f64 = 1.0e-4;

/// Floor on cos(latitude) so a position at the pole cannot divide by zero.
const min_cos_lat: f64 = 1.0e-6;

const deg_to_rad: f64 = std.math.pi / 180.0;

/// Where a vessel is and how it is moving. `sog_mps`/`cog_deg` default to a
/// vessel stopped and pointing north, which is what an AIS target that has
/// reported a position but no motion should be treated as.
pub const State = struct {
    lat: f64,
    lon: f64,
    /// Speed over ground, metres per second.
    sog_mps: f64 = 0,
    /// Course over ground, degrees true, clockwise from north.
    cog_deg: f64 = 0,
};

pub const Solution = struct {
    /// Distance at the closest approach, metres.
    cpa_m: f64,
    /// Seconds from now to that approach. NEGATIVE MEANS IT ALREADY HAPPENED:
    /// the pair is opening, and `cpa_m` is the distance they passed at, not a
    /// distance they will reach. Null when there is no relative motion to
    /// extrapolate.
    tcpa_s: ?f64,
    /// How far apart they are right now, metres.
    range_m: f64,

    /// The collision gate: closer than `cpa_limit_m` at an approach that is
    /// still ahead and inside `tcpa_limit_s`. A pair already past its closest
    /// approach never passes, however close it came.
    pub fn dangerous(self: Solution, cpa_limit_m: f64, tcpa_limit_s: f64) bool {
        const t = self.tcpa_s orelse return false;
        return self.cpa_m < cpa_limit_m and t > 0 and t < tcpa_limit_s;
    }
};

/// Closest approach of `other` to `own`.
///
/// A non-finite input yields an infinite CPA and a null TCPA — no answer, and
/// one that cannot pass the danger gate — rather than a NaN that compares
/// false against every threshold and quietly disarms the alarm.
pub fn solve(own: State, other: State) Solution {
    if (!finite(own) or !finite(other)) {
        const inf = std.math.inf(f64);
        return .{ .cpa_m = inf, .tcpa_s = null, .range_m = inf };
    }

    const cos_lat = @max(@abs(@cos((own.lat + other.lat) * 0.5 * deg_to_rad)), min_cos_lat);
    const rx = wrapLon(other.lon - own.lon) * m_per_deg_lat * cos_lat;
    const ry = (other.lat - own.lat) * m_per_deg_lat;
    const range = @sqrt(rx * rx + ry * ry);

    const ov = velocity(own);
    const tv = velocity(other);
    const vx = tv[0] - ov[0];
    const vy = tv[1] - ov[1];
    const v2 = vx * vx + vy * vy;
    if (v2 <= min_rel_speed_mps * min_rel_speed_mps) {
        return .{ .cpa_m = range, .tcpa_s = null, .range_m = range };
    }

    const t = -(rx * vx + ry * vy) / v2;
    const cx = rx + vx * t;
    const cy = ry + vy * t;
    return .{ .cpa_m = @sqrt(cx * cx + cy * cy), .tcpa_s = t, .range_m = range };
}

/// `.{ east, north }` metres per second.
fn velocity(s: State) [2]f64 {
    const c = s.cog_deg * deg_to_rad;
    return .{ s.sog_mps * @sin(c), s.sog_mps * @cos(c) };
}

fn finite(s: State) bool {
    return std.math.isFinite(s.lat) and std.math.isFinite(s.lon) and
        std.math.isFinite(s.sog_mps) and std.math.isFinite(s.cog_deg);
}

/// A longitude difference folded into (-180, 180], so a pair either side of
/// the antimeridian measures the short way round.
fn wrapLon(dlon_deg: f64) f64 {
    var v = @mod(dlon_deg + 180.0, 360.0);
    if (v < 0) v += 360.0;
    return v - 180.0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Annapolis harbour, where the synthetic log is set.
const base_lat: f64 = 38.9763;
const base_lon: f64 = -76.4767;

const knot_mps: f64 = 1852.0 / 3600.0;

/// A position `east_m`/`north_m` from the base, on the same plane `solve`
/// works in. The longitude scale uses the base latitude while `solve` uses the
/// mean of the pair; over the couple of kilometres these tests place targets
/// at, the two differ by centimetres.
fn at(east_m: f64, north_m: f64, sog_mps: f64, cog_deg: f64) State {
    const cos_lat = @cos(base_lat * deg_to_rad);
    return .{
        .lat = base_lat + north_m / m_per_deg_lat,
        .lon = base_lon + east_m / (m_per_deg_lat * cos_lat),
        .sog_mps = sog_mps,
        .cog_deg = cog_deg,
    };
}

test "head-on closing: the approach is ahead and it is close" {
    // Own ship makes north at 5 m/s; the target is 2000 m ahead making south
    // at 5 m/s, 50 m off to starboard. They close at 10 m/s.
    const own = at(0, 0, 5, 0);
    const other = at(50, 2000, 5, 180);
    const s = solve(own, other);

    try testing.expectApproxEqAbs(@as(f64, 200), s.tcpa_s.?, 0.1);
    try testing.expectApproxEqAbs(@as(f64, 50), s.cpa_m, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 2000.6), s.range_m, 1.0);
    try testing.expect(s.dangerous(926, 600));
}

test "crossing at right angles" {
    // Own ship north at 5 m/s from the origin; the target 1000 m to the east
    // running west at 5 m/s. Relative velocity is (-5, -5) m/s, so the
    // closest approach is at 100 s and 500 m short of the crossing on both
    // axes: 500*sqrt(2).
    const own = at(0, 0, 5, 0);
    const other = at(1000, 0, 5, 270);
    const s = solve(own, other);

    try testing.expectApproxEqAbs(@as(f64, 100), s.tcpa_s.?, 0.1);
    try testing.expectApproxEqAbs(500.0 * @sqrt(2.0), s.cpa_m, 1.0);
    try testing.expect(s.dangerous(926, 600));
}

test "diverging: the closest approach is in the past" {
    // The target has crossed ahead and is drawing away: 200 m in front of own
    // ship, running north with it and faster.
    const own = at(0, 0, 5, 0);
    const other = at(50, 200, 8, 0);
    const s = solve(own, other);

    try testing.expect(s.tcpa_s.? < 0);
    // Never an alarm, however small the CPA of the passage it already made.
    try testing.expect(!s.dangerous(926, 600));
}

test "parallel at the same velocity: no closest approach to name" {
    const own = at(0, 0, 5, 45);
    const other = at(500, 0, 5, 45);
    const s = solve(own, other);

    try testing.expect(s.tcpa_s == null);
    try testing.expectApproxEqAbs(@as(f64, 500), s.cpa_m, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 500), s.range_m, 0.5);
    // A pair holding station is not an alarm even at half a cable.
    try testing.expect(!s.dangerous(926, 600));
}

test "both stopped: relative motion of exactly zero does not divide by zero" {
    const s = solve(at(0, 0, 0, 0), at(300, 400, 0, 0));

    try testing.expect(s.tcpa_s == null);
    try testing.expectApproxEqAbs(@as(f64, 500), s.cpa_m, 0.5);
    try testing.expect(std.math.isFinite(s.cpa_m));
}

test "the generator's target A: a 300 m CPA that starts beyond the gate" {
    // tools/nmea_gen.zig lays target A on a 300° course at 8 kn and places it
    // so that 655 s along — PAST the end of its 600 second log — it is 300 m
    // from own ship, which is making 5 kn on 075°, with the relative velocity
    // square to that offset. Reconstructing the construction here checks this
    // solver against the geometry the synthetic log is built from, and pins
    // the property the whole replay turns on: at the first fix the approach is
    // close enough but too far off in TIME, so the alarm does not fire until
    // the TCPA has fallen under the gate.
    const own_sog = 5.0 * knot_mps;
    const own_cog = 75.0;
    const tgt_sog = 8.0 * knot_mps;
    const tgt_cog = 300.0;

    const ov = velocity(.{ .lat = base_lat, .lon = base_lon, .sog_mps = own_sog, .cog_deg = own_cog });
    const tv = velocity(.{ .lat = base_lat, .lon = base_lon, .sog_mps = tgt_sog, .cog_deg = tgt_cog });
    const rel = [2]f64{ tv[0] - ov[0], tv[1] - ov[1] };
    const rel_len = @sqrt(rel[0] * rel[0] + rel[1] * rel[1]);
    // 300 m square to the relative track, wound back along it.
    const offset = [2]f64{ -rel[1] * 300.0 / rel_len, rel[0] * 300.0 / rel_len };

    const own = at(0, 0, own_sog, own_cog);
    const far = solve(own, at(
        offset[0] - rel[0] * 655.0,
        offset[1] - rel[1] * 655.0,
        tgt_sog,
        tgt_cog,
    ));
    try testing.expectApproxEqAbs(@as(f64, 655), far.tcpa_s.?, 1.0);
    try testing.expectApproxEqAbs(@as(f64, 300), far.cpa_m, 1.0);
    try testing.expect(far.range_m > 4000);
    // Close enough, but not yet soon enough.
    try testing.expect(far.cpa_m < 926);
    try testing.expect(!far.dangerous(926, 600));

    // The same encounter a minute and a half later is the alarm.
    const near = solve(own, at(
        offset[0] - rel[0] * 560.0,
        offset[1] - rel[1] * 560.0,
        tgt_sog,
        tgt_cog,
    ));
    try testing.expectApproxEqAbs(@as(f64, 560), near.tcpa_s.?, 1.0);
    try testing.expect(near.dangerous(926, 600));
}

test "the gate: outside either limit is no alarm" {
    // Closing, but the approach is 20 minutes off.
    const slow = solve(at(0, 0, 1, 0), at(0, 2000, 1, 180));
    try testing.expect(slow.tcpa_s.? > 600);
    try testing.expect(!slow.dangerous(926, 600));

    // Soon, but it passes a mile off.
    const wide = solve(at(0, 0, 5, 0), at(1900, 2000, 5, 180));
    try testing.expect(wide.tcpa_s.? < 600 and wide.tcpa_s.? > 0);
    try testing.expect(wide.cpa_m > 926);
    try testing.expect(!wide.dangerous(926, 600));
}

test "a non-finite input yields no answer rather than a NaN" {
    const s = solve(.{ .lat = base_lat, .lon = base_lon }, .{ .lat = std.math.nan(f64), .lon = base_lon });
    try testing.expect(s.tcpa_s == null);
    try testing.expect(!s.dangerous(926, 600));
    try testing.expect(!std.math.isNan(s.cpa_m));
}

test "a pair either side of the antimeridian measures the short way" {
    const own = State{ .lat = 0.0, .lon = 179.999, .sog_mps = 0, .cog_deg = 0 };
    const other = State{ .lat = 0.0, .lon = -179.999, .sog_mps = 0, .cog_deg = 0 };
    const s = solve(own, other);
    // 0.002° of longitude at the equator, not 359.998°.
    try testing.expectApproxEqAbs(0.002 * m_per_deg_lat, s.range_m, 1.0);
}
