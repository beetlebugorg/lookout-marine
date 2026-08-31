//! When the next frame is, and what to advance before it.
//!
//! The verdict is one of three: render now, wait this long, or stop. A shell
//! drives its display link off it and keeps no numbers of its own.
//!
//! This file is the decision. What it decides about lives in root.zig, which
//! calls in with what it knows.

const std = @import("std");

pub const Verdict = enum(c_int) {
    render = 0,
    /// Nothing to draw yet, and something is coming.
    wait = 1,
    /// Nothing is moving. Stop the loop.
    idle = 2,
};

/// The longest gap a tick may advance by. An app that was in the background
/// for a minute must not advance a fling by a minute.
pub const dt_cap: f64 = 0.05;

/// Quiet ticks before a shell stops. Not zero: a build that finishes just
/// after a still frame would otherwise never be drawn.
pub const quiet_ticks: u32 = 2;

/// The poll rate once a shell has stopped. The AIS store coalesces to 2 Hz;
/// this is twice that.
pub const poll_ms: c_int = 250;

pub const Inputs = struct {
    /// Easing a zoom or coasting a fling.
    animating: bool,
    needs_redraw: bool,
    /// A background tessellation is filling in.
    building: bool,
    /// A plugin layer is up, so traffic can arrive with no input behind it.
    plugins_active: bool,
    /// How many ticks in a row have wanted nothing.
    quiet: u32,
};

pub const Step = struct {
    verdict: Verdict,
    wait_ms: c_int = 0,
    /// The new count of quiet ticks, which the caller keeps for the next one.
    quiet: u32 = 0,
};

/// The gap since the last tick, capped. A `last_ms` of zero is the first tick
/// back, which advances nothing.
pub fn delta(last_ms: i64, now_ms: i64) f64 {
    if (last_ms == 0 or now_ms <= last_ms) return 0;
    const dt = @as(f64, @floatFromInt(now_ms - last_ms)) / 1000.0;
    return @min(dt, dt_cap);
}

pub fn decide(in: Inputs) Step {
    if (in.animating or in.needs_redraw) return .{ .verdict = .render, .quiet = 0 };
    // Keep ticking so a build appears the moment it lands, rather than at the
    // mariner's next gesture.
    if (in.building) return .{ .verdict = .wait, .quiet = 0 };

    const quiet = in.quiet + 1;
    if (quiet <= quiet_ticks) return .{ .verdict = .wait, .quiet = quiet };
    // Plugin traffic has no gesture behind it. Without the slow poll, AIS
    // froze until the mariner touched the trackpad.
    if (in.plugins_active) return .{ .verdict = .wait, .wait_ms = poll_ms, .quiet = quiet };
    return .{ .verdict = .idle, .quiet = quiet };
}

// ---- tests ---------------------------------------------------------------------

const t = std.testing;

/// The still case, which each test moves one field of.
const still = Inputs{
    .animating = false,
    .needs_redraw = false,
    .building = false,
    .plugins_active = false,
    .quiet = 0,
};

test "the gap is capped, and the first tick back advances nothing" {
    try t.expectEqual(@as(f64, 0), delta(0, 1000));
    try t.expectEqual(@as(f64, 0.016), delta(1000, 1016));
    try t.expectEqual(dt_cap, delta(1000, 61000));
    // A clock that went backwards is not a negative gap.
    try t.expectEqual(@as(f64, 0), delta(2000, 1000));
}

test "anything moving is a frame, and resets the count" {
    var in = still;
    in.quiet = 7;
    in.animating = true;
    try t.expectEqual(Verdict.render, decide(in).verdict);
    try t.expectEqual(@as(u32, 0), decide(in).quiet);

    in.animating = false;
    in.needs_redraw = true;
    try t.expectEqual(Verdict.render, decide(in).verdict);
}

test "a build filling in keeps the loop ticking" {
    var in = still;
    in.quiet = 7;
    in.building = true;
    const step = decide(in);
    try t.expectEqual(Verdict.wait, step.verdict);
    try t.expectEqual(@as(c_int, 0), step.wait_ms);
    try t.expectEqual(@as(u32, 0), step.quiet);
}

test "a couple of quiet ticks pass before the loop stops" {
    var in = still;
    for (0..quiet_ticks) |_| {
        const step = decide(in);
        try t.expectEqual(Verdict.wait, step.verdict);
        try t.expectEqual(@as(c_int, 0), step.wait_ms);
        in.quiet = step.quiet;
    }
    try t.expectEqual(Verdict.idle, decide(in).verdict);
}

test "with plugins up the loop slows down instead of stopping" {
    var in = still;
    in.plugins_active = true;
    in.quiet = quiet_ticks + 1;
    const step = decide(in);
    try t.expectEqual(Verdict.wait, step.verdict);
    try t.expectEqual(poll_ms, step.wait_ms);

    // The count keeps growing and the answer does not change.
    in.quiet = step.quiet;
    try t.expectEqual(poll_ms, decide(in).wait_ms);

    // A plugin that wants a frame gets one no matter how high the count is.
    in.quiet = 400;
    in.needs_redraw = true;
    try t.expectEqual(Verdict.render, decide(in).verdict);
}

test "the verdict values are the ones the header states" {
    try t.expectEqual(@as(c_int, 0), @intFromEnum(Verdict.render));
    try t.expectEqual(@as(c_int, 1), @intFromEnum(Verdict.wait));
    try t.expectEqual(@as(c_int, 2), @intFromEnum(Verdict.idle));
}
