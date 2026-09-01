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

// ---- the rules ----------------------------------------------------------------

pub const lookout_prepare = rules.Prepare;

/// One file to prepare. See lookout-library.h.
pub const lookout_bake_item = extern struct {
    path: [*:0]const u8,
    name: [*:0]const u8,
    band: c_int,
    work: lookout_prepare,
};

fn ruleItem(i: lookout_bake_item) rules.Item {
    return .{
        .path = std.mem.span(i.path),
        .name = std.mem.span(i.name),
        .band = @intCast(@max(0, @min(255, i.band))),
        .work = i.work,
    };
}

/// Sort the items into the order a bake runs them in, in place.
export fn lookout_bake_order(items: ?[*]lookout_bake_item, n: usize) void {
    const list = (items orelse return)[0..n];
    std.mem.sort(lookout_bake_item, list, {}, struct {
        fn lt(_: void, a: lookout_bake_item, b: lookout_bake_item) bool {
            return rules.before(ruleItem(a), ruleItem(b));
        }
    }.lt);
}

/// Copy `s` and its NUL into the caller's buffer. Returns the length, or 0
/// when the buffer is absent or too small.
fn copyOut(out: ?[*]u8, cap: usize, s: []const u8) usize {
    const dst = out orelse return 0;
    if (cap == 0) return 0;
    if (s.len + 1 > cap) {
        dst[0] = 0;
        return 0;
    }
    @memcpy(dst[0..s.len], s);
    dst[s.len] = 0;
    return s.len;
}

/// Where one prepared chart is written under `out_dir`. See lookout-library.h.
export fn lookout_bake_output_path(
    out_dir: ?[*:0]const u8,
    source: ?[*:0]const u8,
    item: ?*const lookout_bake_item,
    out: ?[*]u8,
    cap: usize,
) usize {
    const it = item orelse return 0;
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const p = rules.outputPath(
        fba.allocator(),
        if (out_dir) |d| std.mem.span(d) else "",
        if (source) |s| std.mem.span(s) else "",
        ruleItem(it.*),
    ) catch return 0;
    return copyOut(out, cap, p);
}

/// The directory name a source is prepared into. See lookout-library.h.
export fn lookout_bake_prepared_name(source: ?[*:0]const u8, out: ?[*]u8, cap: usize) usize {
    const s = source orelse return 0;
    return copyOut(out, cap, rules.preparedName(std.mem.span(s)));
}

/// True when `path` is under the directory this app prepares into.
export fn lookout_bake_is_derived(root: ?[*:0]const u8, path: ?[*:0]const u8) c_int {
    const r = if (root) |x| std.mem.span(x) else "";
    const p = if (path) |x| std.mem.span(x) else "";
    return @intFromBool(rules.isDerived(r, p));
}

/// The prefix a directory being deleted is renamed to. Static storage.
export fn lookout_bake_trash_prefix() [*:0]const u8 {
    return rules.trash_prefix;
}

/// True when a directory name is one a removal left behind.
export fn lookout_bake_is_trash(name: ?[*:0]const u8) c_int {
    const n = name orelse return 0;
    return @intFromBool(rules.isTrash(std.mem.span(n)));
}
