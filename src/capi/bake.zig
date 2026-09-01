//! The bake's C ABI (see include/lookout-library.h).
//!
//! No chart handle: a bake runs before the charts it makes are opened.

const std = @import("std");

const capi = @import("../capi.zig");
const bakejob = @import("../bakejob.zig");
const rules = @import("../shell/bake.zig");

const gpa = capi.gpa;

pub const lookout_bake = bakejob.Job;
pub const lookout_bake_progress = bakejob.Progress;

/// Copy a NUL-terminated array the caller owns.
fn take(items: ?[*]const [*:0]const u8, n: usize) ?[][:0]u8 {
    const src = items orelse return null;
    const out = gpa.alloc([:0]u8, n) catch return null;
    var got: usize = 0;
    errdefer {
        for (out[0..got]) |s| gpa.free(s);
        gpa.free(out);
    }
    while (got < n) : (got += 1) {
        out[got] = gpa.dupeZ(u8, std.mem.span(src[got])) catch {
            for (out[0..got]) |s| gpa.free(s);
            gpa.free(out);
            return null;
        };
    }
    return out;
}

/// Start a bake. See lookout-library.h.
export fn lookout_bake_start(
    source: ?[*:0]const u8,
    ins: ?[*]const [*:0]const u8,
    outs: ?[*]const [*:0]const u8,
    cells: usize,
    sheets: usize,
    lifts: usize,
    archive: c_int,
) ?*lookout_bake {
    const n = cells + sheets + lifts;
    if (n == 0) return null;
    const src = gpa.dupeZ(u8, if (source) |s| std.mem.span(s) else "") catch return null;
    const in_z = take(ins, n) orelse {
        gpa.free(src);
        return null;
    };
    const out_z = take(outs, n) orelse {
        for (in_z) |s| gpa.free(s);
        gpa.free(in_z);
        gpa.free(src);
        return null;
    };
    return bakejob.Job.start(gpa, src, in_z, out_z, cells, sheets, lifts, archive != 0);
}

/// Stop at the next chart boundary.
export fn lookout_bake_cancel(b: ?*lookout_bake) void {
    if (b) |x| x.cancel();
}

/// How far along. Safe from any thread while the bake runs.
export fn lookout_bake_poll(b: ?*const lookout_bake, out: ?*lookout_bake_progress) void {
    const dst = out orelse return;
    const x = b orelse {
        dst.* = .{ .done = 0, .total = 0, .baked = 0, .ok = 0, .running = 0 };
        return;
    };
    dst.* = x.poll();
}

/// Join the worker and free the bake. Cancel first, or this blocks for about
/// one chart's bake time.
export fn lookout_bake_free(b: ?*lookout_bake) void {
    if (b) |x| x.free();
}

/// How many workers a bake on this machine runs. See lookout-library.h.
export fn lookout_bake_workers(cores: u32) u32 {
    return rules.workers(cores);
}
