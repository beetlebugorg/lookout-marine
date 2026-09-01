//! One bake, running on a thread of its own.
//!
//! tile57 does the work in three phases: the cells, then the sheets, then the
//! lift out of an archive. What is here is the thread, the phase split, the
//! cancel and the counters a shell polls.
//!
//! THE SHELL POLLS. No callback crosses back out. A bake worker is not an
//! attached JVM thread and must not become one to move a progress bar, and a
//! callback into Swift or C++ from a tile57 worker would need the same care for
//! the same reason. A poll is one atomic read.
//!
//! `src/shell/bake.zig` decides the ORDER and the output paths. This runs what
//! it decided.

const std = @import("std");

const cc = @import("c.zig").c;
const rules = @import("shell/bake.zig");
const sleepMs = @import("lock.zig").sleepMs;

pub const Job = struct {
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,

    cancelled: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(true),
    ok: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(u32) = .init(0),
    baked: std.atomic.Value(u32) = .init(0),

    /// Where the phase now running starts in the job. tile57 counts from zero
    /// each phase; the mariner is watching one job.
    phase_offset: u32 = 0,
    total: u32 = 0,

    /// The folder, or the archive when `archive` is set.
    source: [:0]u8,
    /// Kind-contiguous: the cells, then the sheets, then the lifts.
    ins: [][:0]u8,
    outs: [][:0]u8,
    cells: usize,
    sheets: usize,
    lifts: usize,
    archive: bool,

    /// Take the paths and start the thread. The job owns every string from
    /// here. Null when the thread cannot be spawned, and the strings are freed.
    pub fn start(
        gpa: std.mem.Allocator,
        source: [:0]u8,
        ins: [][:0]u8,
        outs: [][:0]u8,
        cells: usize,
        sheets: usize,
        lifts: usize,
        archive: bool,
    ) ?*Job {
        const self = gpa.create(Job) catch {
            freeAll(gpa, source, ins, outs);
            return null;
        };
        self.* = .{
            .gpa = gpa,
            .source = source,
            .ins = ins,
            .outs = outs,
            .cells = cells,
            .sheets = sheets,
            .lifts = lifts,
            .archive = archive,
            .total = @intCast(ins.len),
        };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.free();
            return null;
        };
        return self;
    }

    /// Stop at the next chart boundary. tile57 checks between charts, so a
    /// cancel lands within about one cell's bake time.
    pub fn cancel(self: *Job) void {
        self.cancelled.store(true, .release);
    }

    pub fn isRunning(self: *const Job) bool {
        return self.running.load(.acquire);
    }

    /// How far along, for a progress bar. Read from any thread.
    pub fn poll(self: *const Job) Progress {
        return .{
            .done = self.done.load(.acquire),
            .total = self.total,
            .baked = self.baked.load(.acquire),
            .ok = @intFromBool(self.ok.load(.acquire)),
            .running = @intFromBool(self.running.load(.acquire)),
        };
    }

    /// Join the worker and free the job. Cancel first, or this blocks for about
    /// one chart's bake time.
    pub fn free(self: *Job) void {
        if (self.thread) |th| th.join();
        const gpa = self.gpa;
        freeAll(gpa, self.source, self.ins, self.outs);
        gpa.destroy(self);
    }

    fn freeAll(gpa: std.mem.Allocator, source: [:0]u8, ins: [][:0]u8, outs: [][:0]u8) void {
        for (ins) |s| gpa.free(s);
        for (outs) |s| gpa.free(s);
        gpa.free(ins);
        gpa.free(outs);
        gpa.free(source);
    }

    fn run(self: *Job) void {
        const cpus: u32 = @intCast(std.Thread.getCpuCount() catch 4);
        const workers = rules.workers(cpus);

        const ins_c = self.gpa.alloc([*c]const u8, self.ins.len) catch {
            self.running.store(false, .release);
            return;
        };
        defer self.gpa.free(ins_c);
        const outs_c = self.gpa.alloc([*c]const u8, self.outs.len) catch {
            self.running.store(false, .release);
            return;
        };
        defer self.gpa.free(outs_c);
        for (self.ins, ins_c) |s, *dst| dst.* = s.ptr;
        for (self.outs, outs_c) |s, *dst| dst.* = s.ptr;

        var st: cc.tile57_status = cc.TILE57_OK;
        var err: cc.tile57_error = undefined;
        var total: u32 = 0;

        // A cell is parsed and portrayed from the survey; a sheet is decoded
        // and warped from a picture; imagery that is already a chart is only
        // lifted out of the archive. Three calls, one count.
        if (self.cells > 0 and !self.cancelled.load(.acquire)) {
            self.phase_offset = 0;
            var n: u32 = 0;
            st = if (self.archive)
                cc.tile57_bake_zip_charts(self.source.ptr, ins_c.ptr, outs_c.ptr, self.cells, workers, progress, null, self, &n, &err)
            else
                cc.tile57_bake_files(ins_c.ptr, outs_c.ptr, self.cells, workers, progress, null, self, &n, &err);
            total += n;
        }
        if (st == cc.TILE57_OK and self.sheets > 0 and !self.cancelled.load(.acquire)) {
            self.phase_offset = @intCast(self.cells);
            const off = self.cells;
            var n: u32 = 0;
            st = if (self.archive)
                cc.tile57_bake_zip_rasters(self.source.ptr, ins_c.ptr + off, outs_c.ptr + off, self.sheets, workers, progress, null, self, &n, &err)
            else
                cc.tile57_bake_rasters(ins_c.ptr + off, outs_c.ptr + off, self.sheets, workers, progress, null, self, &n, &err);
            total += n;
        }
        // A lift only comes out of an archive. Loose files are already where
        // the engine can read them.
        if (st == cc.TILE57_OK and self.archive and self.lifts > 0 and !self.cancelled.load(.acquire)) {
            self.phase_offset = @intCast(self.cells + self.sheets);
            const off = self.cells + self.sheets;
            var n: u32 = 0;
            st = cc.tile57_zip_extract(self.source.ptr, ins_c.ptr + off, outs_c.ptr + off, self.lifts, progress, self, &n, &err);
            total += n;
        }

        self.baked.store(total, .release);
        // A cancelled bake is not a failure: whatever landed is a usable
        // library.
        self.ok.store(st == cc.TILE57_OK, .release);
        self.running.store(false, .release);
    }

    /// tile57's per-chart callback, on its worker threads. False stops the run.
    fn progress(ctx: ?*anyopaque, done: u32, total: u32) callconv(.c) bool {
        _ = total;
        const self: *Job = @ptrCast(@alignCast(ctx orelse return false));
        self.done.store(self.phase_offset + done, .release);
        return !self.cancelled.load(.acquire);
    }
};

/// How far a bake has got. A snapshot: every field is read in one call.
pub const Progress = extern struct {
    done: u32,
    total: u32,
    /// How many charts landed. Less than `done` when one refused.
    baked: u32,
    /// 1 when every phase returned TILE57_OK. A cancel leaves this 1.
    ok: c_int,
    /// 1 while the worker is still going.
    running: c_int,
};

// ---- tests ---------------------------------------------------------------------

const t = std.testing;

/// A job over `n` paths with no phase counts, so no tile57 call runs. What is
/// under test is the thread, the counters and the free.
fn emptyJob(n: usize) !*Job {
    const gpa = t.allocator;
    const ins = try gpa.alloc([:0]u8, n);
    const outs = try gpa.alloc([:0]u8, n);
    for (ins, outs, 0..) |*i, *o, k| {
        i.* = try std.fmt.allocPrintSentinel(gpa, "/in/{d}", .{k}, 0);
        o.* = try std.fmt.allocPrintSentinel(gpa, "/out/{d}", .{k}, 0);
    }
    const src = try gpa.dupeZ(u8, "/source");
    return Job.start(gpa, src, ins, outs, 0, 0, 0, false).?;
}

/// Wait for the worker to finish.
fn settle(job: *Job) void {
    for (0..2000) |_| {
        if (!job.isRunning()) return;
        sleepMs(1);
    }
}

test "a job runs on its own thread and reports when it is done" {
    const job = try emptyJob(3);
    defer job.free();
    settle(job);

    const p = job.poll();
    try t.expectEqual(@as(u32, 3), p.total);
    try t.expectEqual(@as(c_int, 0), p.running);
    // No phase to run, so nothing was baked and nothing failed.
    try t.expectEqual(@as(u32, 0), p.baked);
    try t.expectEqual(@as(c_int, 1), p.ok);
}

test "a cancel is seen, and a cancelled bake is not a failure" {
    const job = try emptyJob(2);
    defer job.free();
    job.cancel();
    settle(job);
    try t.expect(job.cancelled.load(.acquire));
    // Whatever landed before the cancel is a usable library.
    try t.expectEqual(@as(c_int, 1), job.poll().ok);
}

test "a poll is one read, and is the same from any thread" {
    const job = try emptyJob(1);
    defer job.free();
    // Reading while the worker may still be going is what a progress bar does.
    const a = job.poll();
    settle(job);
    const b = job.poll();
    try t.expectEqual(a.total, b.total);
    try t.expectEqual(@as(c_int, 0), b.running);
}

test "a job with no paths never starts" {
    const gpa = t.allocator;
    const src = try gpa.dupeZ(u8, "/source");
    const ins = try gpa.alloc([:0]u8, 0);
    const outs = try gpa.alloc([:0]u8, 0);
    const job = Job.start(gpa, src, ins, outs, 0, 0, 0, false).?;
    defer job.free();
    settle(job);
    try t.expectEqual(@as(u32, 0), job.poll().total);
}
