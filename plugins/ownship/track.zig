//! Ownship track history: the positions the boat has been at, thinned.
//!
//! Pure computation over `lk.Point`: no host imports, no allocation, no state
//! outside the `Track` the caller owns. Nothing here reaches the host, so
//! `zig build test` runs these tests natively while the same file compiles into
//! the wasm module. The geodesy is `lk.Point`'s; this file holds none of its
//! own.

const std = @import("std");
const lk = @import("lk2");

/// Positions a `Track` keeps before the oldest is dropped.
pub const max_points: usize = 600;

/// One kept position. `t_ms` is whatever clock the caller feeds `consider` —
/// the plugin uses the monotonic time the fix was taken, the tests use plain
/// integers.
pub const Fix = struct {
    t_ms: i64,
    at: lk.Point,
};

/// The last `max_points` positions, oldest first, as a ring.
///
/// Fixed storage: a plugin has no heap worth the name, and a track that cannot
/// grow cannot leak. Overwriting the oldest point is the whole policy — the
/// mariner sees where the boat has been recently, not since the epoch.
pub const Track = struct {
    buf: [max_points]Fix = undefined,
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

    /// The `i`th fix, 0 = oldest. Asserts `i < count()`.
    pub fn nth(self: *const Track, i: usize) Fix {
        std.debug.assert(i < self.len);
        return self.buf[(self.start + i) % max_points];
    }

    /// The most recently kept fix, or null on an empty track.
    pub fn newest(self: *const Track) ?Fix {
        if (self.len == 0) return null;
        return self.nth(self.len - 1);
    }

    /// A move faster than this is a teleport, not a leg: a replayed log
    /// looping back to its start, or a GPS reacquiring somewhere else. 60 m/s
    /// is about 117 kn, above any boat this chart serves. Joining the old
    /// trail to the new fix would draw a line across water the boat never
    /// crossed, so the track restarts at the new fix instead.
    pub const teleport_mps: f64 = 60.0;

    /// Keep this position if it is at least `min_interval_ms` newer AND at
    /// least `min_dist_m` away from the last kept fix; the first fix is always
    /// kept. Returns true when the track changed.
    ///
    /// BOTH gates, not either: time alone would record 600 points of a boat
    /// sitting at anchor, and distance alone would record every jitter of a fix
    /// that updates at 10 Hz. A `t_ms` that goes backwards fails the time gate
    /// and is dropped, which is the safe answer for a clock that jumped and is
    /// what drops a fix the draw timer offers a second time.
    pub fn consider(self: *Track, t_ms: i64, at: lk.Point, min_interval_ms: i64, min_dist_m: f64) bool {
        if (!at.valid()) return false;
        if (self.newest()) |last| {
            const dt_ms = t_ms - last.t_ms;
            if (dt_ms < min_interval_ms) return false;
            const dist = last.at.distanceTo(at);
            if (dist < min_dist_m) return false;
            const dt_s = @as(f64, @floatFromInt(dt_ms)) / 1000.0;
            if (dist > teleport_mps * dt_s) self.clear();
        }
        self.push(.{ .t_ms = t_ms, .at = at });
        return true;
    }

    fn push(self: *Track, f: Fix) void {
        const at_idx = (self.start + self.len) % max_points;
        self.buf[at_idx] = f;
        if (self.len == max_points) {
            self.start = (self.start + 1) % max_points;
        } else {
            self.len += 1;
        }
    }

    /// Copy the track into `out`, oldest first, and return how many were
    /// written. Writes at most `out.len` points, keeping the NEWEST ones when
    /// `out` is shorter than the track.
    pub fn copy(self: *const Track, out: []lk.Point) usize {
        const n = @min(out.len, self.len);
        const skip = self.len - n;
        for (0..n) |i| out[i] = self.nth(skip + i).at;
        return n;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const t = std.testing;

// Annapolis harbour, the prototype's test ground.
const annapolis = lk.Point{ .lat = 38.9763, .lon = -76.4767 };

test "the first fix is always kept" {
    var tr = Track{};
    try t.expect(tr.consider(0, annapolis, 1000, 2.0));
    try t.expectEqual(@as(usize, 1), tr.count());
    try t.expectEqual(annapolis.lat, tr.newest().?.at.lat);
}

test "both the time gate and the distance gate must pass" {
    var tr = Track{};
    _ = tr.consider(0, annapolis, 1000, 2.0);

    // 10 m away but only 999 ms later: too soon.
    try t.expect(!tr.consider(999, annapolis.destination(0, 10), 1000, 2.0));

    // 5 s later but 1.5 m away: a boat at anchor swinging on its chain.
    try t.expect(!tr.consider(5_000, annapolis.destination(90, 1.5), 1000, 2.0));

    // Far enough and long enough.
    const away = annapolis.destination(90, 2.5);
    try t.expect(tr.consider(6_000, away, 1000, 2.0));
    try t.expectEqual(@as(usize, 2), tr.count());

    // The gates measure from the last KEPT fix, not from the last offer: 2.5 m
    // was accepted, so another 1.5 m from there is still too close.
    try t.expect(!tr.consider(7_000, away.destination(90, 1.5), 1000, 2.0));
    try t.expectEqual(@as(usize, 2), tr.count());
}

test "the distance gate measures the same on every bearing" {
    // The gate is 2 m and the geodesy under it is lk.Point's. This checks the
    // two agree at the scale a track is thinned at, in every direction.
    for ([_]f64{ 0, 45, 90, 135, 180, 225, 270, 315 }) |brg| {
        var tr = Track{};
        _ = tr.consider(0, annapolis, 1000, 2.0);
        try t.expect(!tr.consider(2_000, annapolis.destination(brg, 1.9), 1000, 2.0));
        try t.expect(tr.consider(3_000, annapolis.destination(brg, 2.1), 1000, 2.0));
    }
}

test "the same fix offered twice is kept once" {
    // The draw timer offers whatever position it holds, stamped with the time
    // the fix was taken, so a GPS slower than the timer repeats one fix.
    var tr = Track{};
    try t.expect(tr.consider(10_000, annapolis, 1000, 2.0));
    try t.expect(!tr.consider(10_000, annapolis, 1000, 2.0));
    try t.expectEqual(@as(usize, 1), tr.count());
}

test "a clock that jumps backwards drops the fix" {
    var tr = Track{};
    _ = tr.consider(10_000, annapolis, 1000, 2.0);
    try t.expect(!tr.consider(9_000, annapolis.destination(0, 100), 1000, 2.0));
    try t.expectEqual(@as(usize, 1), tr.count());
}

test "a teleport restarts the track at the new fix" {
    var tr = Track{};
    _ = tr.consider(0, annapolis, 1000, 2.0);
    _ = tr.consider(1_000, annapolis.destination(0, 10), 1000, 2.0);
    try t.expectEqual(@as(usize, 2), tr.count());

    // 3 km in one second: the replay looped, or the GPS came back somewhere
    // else. The old trail goes; the new fix starts a fresh one.
    const far = annapolis.destination(90, 3_000);
    try t.expect(tr.consider(2_000, far, 1000, 2.0));
    try t.expectEqual(@as(usize, 1), tr.count());
    try t.expectEqual(far.lat, tr.newest().?.at.lat);
}

test "a fast boat is a leg and a slow reappearance is a leg" {
    var tr = Track{};
    _ = tr.consider(0, annapolis, 1000, 2.0);

    // 50 m in one second is 97 kn: implausible on the hook, real on a foiler.
    try t.expect(tr.consider(1_000, annapolis.destination(0, 50), 1000, 2.0));
    try t.expectEqual(@as(usize, 2), tr.count());

    // 1 km after a 30 minute silence is 0.5 m/s made good: kept, joined.
    const on = annapolis.destination(0, 50).destination(0, 1_000);
    try t.expect(tr.consider(1_801_000, on, 1000, 2.0));
    try t.expectEqual(@as(usize, 3), tr.count());
}

test "a position off the earth is refused" {
    var tr = Track{};
    try t.expect(!tr.consider(0, .{ .lat = 91, .lon = -76.4767 }, 1000, 2.0));
    try t.expect(!tr.consider(0, .{ .lat = 38.9763, .lon = std.math.nan(f64) }, 1000, 2.0));
    try t.expectEqual(@as(usize, 0), tr.count());
}

test "the ring wraps and keeps the newest max_points" {
    var tr = Track{};
    // 900 fixes, each 10 m north of the last and 1 s later.
    var at = annapolis;
    for (0..900) |i| {
        at = at.destination(0, 10);
        try t.expect(tr.consider(@as(i64, @intCast(i)) * 1000, at, 1000, 2.0));
    }
    try t.expectEqual(max_points, tr.count());
    // Oldest surviving fix is offer 300 (0-based), newest is offer 899.
    try t.expectEqual(@as(i64, 300_000), tr.nth(0).t_ms);
    try t.expectEqual(@as(i64, 899_000), tr.newest().?.t_ms);
    // Monotonic in time, oldest first, with no seam at the wrap.
    for (1..tr.count()) |i| try t.expect(tr.nth(i).t_ms > tr.nth(i - 1).t_ms);
}

test "copy writes oldest first" {
    // An hour between fixes: 14 km legs at walking speed, no teleport.
    var tr = Track{};
    _ = tr.consider(0, .{ .lat = 38.0, .lon = -76.0 }, 1000, 2.0);
    _ = tr.consider(3_600_000, .{ .lat = 38.1, .lon = -76.1 }, 1000, 2.0);
    _ = tr.consider(7_200_000, .{ .lat = 38.2, .lon = -76.2 }, 1000, 2.0);
    var out: [max_points]lk.Point = undefined;
    const n = tr.copy(&out);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(f64, 38.0), out[0].lat);
    try t.expectEqual(@as(f64, -76.0), out[0].lon);
    try t.expectEqual(@as(f64, 38.2), out[2].lat);
    try t.expectEqual(@as(f64, -76.2), out[2].lon);
}

test "copy into a short buffer keeps the newest points" {
    // Ten seconds between fixes: 111 m legs at 11 m/s, no teleport.
    var tr = Track{};
    for (0..10) |i| {
        const lat = 38.0 + @as(f64, @floatFromInt(i)) * 0.001;
        _ = tr.consider(@as(i64, @intCast(i)) * 10_000, .{ .lat = lat, .lon = -76.0 }, 1000, 2.0);
    }
    var out: [4]lk.Point = undefined;
    const n = tr.copy(&out);
    try t.expectEqual(@as(usize, 4), n);
    try t.expectApproxEqAbs(@as(f64, 38.006), out[0].lat, 1e-9);
    try t.expectApproxEqAbs(@as(f64, 38.009), out[3].lat, 1e-9);
}

test "clear empties the track without disturbing the ring" {
    var tr = Track{};
    for (0..5) |i| {
        const lat = 38.0 + @as(f64, @floatFromInt(i)) * 0.001;
        _ = tr.consider(@as(i64, @intCast(i)) * 1000, .{ .lat = lat, .lon = -76.0 }, 1000, 2.0);
    }
    tr.clear();
    try t.expectEqual(@as(usize, 0), tr.count());
    try t.expect(tr.newest() == null);
    try t.expect(tr.consider(0, annapolis, 1000, 2.0));
    try t.expectEqual(@as(usize, 1), tr.count());
}
