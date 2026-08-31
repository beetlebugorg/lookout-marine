//! The frame loop's C ABI (see include/lookout-shell.h).
//!
//! lookout_tick_anim, lookout_animating and lookout_needs_redraw stay for the
//! shells that have not adopted this.

const std = @import("std");

const capi = @import("../capi.zig");
const frame = @import("../shell/frame.zig");

const lookout = capi.lookout;
const locked = capi.locked;

pub const lookout_frame_verdict = frame.Verdict;

/// What a shell should do next. See lookout-shell.h.
pub const lookout_frame = extern struct {
    verdict: lookout_frame_verdict,
    wait_ms: c_int,
    /// 1 while a background tessellation is filling in, for the loader pill.
    building: c_int,
};

/// One tick. See lookout-shell.h.
export fn lookout_frame_next(h: ?*lookout, out: ?*lookout_frame) void {
    const dst = out orelse return;
    dst.* = .{ .verdict = .idle, .wait_ms = 0, .building = 0 };
    const l = locked(h);
    defer l.apiUnlock();
    const step = l.frameStep();
    dst.* = .{
        .verdict = step.verdict,
        .wait_ms = step.wait_ms,
        .building = @intFromBool(l.isBuilding()),
    };
}

/// Start the loop again after a change the shell made itself.
export fn lookout_frame_kick(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.frameKick();
}
