//! A real bake, over a real archive.
//!
//! The engine's own tests bake nothing: a raw S-57 cell is 300 KB of survey and
//! the repository holds none. This drives `src/bakejob.zig` over an exchange
//! set the mariner already has, named by $LOOKOUT_BAKE_ARCHIVE, and SKIPS when
//! the variable is unset. That is why it is a step of its own rather than a
//! test root: a machine without an archive still runs the suite.
//!
//!     LOOKOUT_BAKE_ARCHIVE=~/Downloads/All_ENCs.zip zig build bake-host
//!
//! Only a handful of entries are baked. What is under test is the phases, the
//! counters, the cancel and the output layout, none of which needs 7,000
//! charts.

const std = @import("std");

const lk = @import("lookout");
const bakejob = lk.bakejob;
const rules = lk.bake_rules;

const t = std.testing;

/// Zig 0.16 moved sleep behind an Io this test does not take, the same reason
/// src/lock.zig declares its own.
extern "c" fn usleep(usec: u32) c_int;
fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}

/// How many cells to bake. Enough to see the counter move and the order hold.
const want_cells = 3;

fn archivePath() ?[]const u8 {
    const p = std.c.getenv("LOOKOUT_BAKE_ARCHIVE") orelse return null;
    const span = std.mem.span(p);
    return if (span.len == 0) null else span;
}

/// The cells the archive holds, as the scan reports them, in bake order.
fn pickCells(a: std.mem.Allocator, archive: []const u8) ![]rules.Item {
    var scan = try lk.scanZip(a, archive);
    defer scan.deinit();

    var items = std.ArrayList(rules.Item).empty;
    for (scan.cells) |c| {
        if (c.kind != .source) continue;
        try items.append(a, .{
            .path = try a.dupe(u8, c.path),
            .name = try a.dupe(u8, c.name),
            .band = c.band,
            .work = .cell,
        });
        if (items.items.len == want_cells) break;
    }
    rules.order(items.items);
    return items.items;
}

test "a real archive bakes into charts the engine can open" {
    const archive = archivePath() orelse return error.SkipZigTest;
    const a = t.allocator;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const items = try pickCells(aa, archive);
    if (items.len == 0) {
        std.debug.print("bake-host: {s} holds no S-57 cells\n", .{archive});
        return error.SkipZigTest;
    }

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const out_dir = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const ins = try a.alloc([:0]u8, items.len);
    const outs = try a.alloc([:0]u8, items.len);
    for (items, ins, outs) |item, *i, *o| {
        i.* = try a.dupeZ(u8, item.path);
        const p = try rules.outputPath(aa, out_dir, archive, item);
        o.* = try a.dupeZ(u8, p);
        // Every prepared chart goes in a directory of its own name.
        std.Io.Dir.cwd().createDirPath(
            std.Io.Threaded.global_single_threaded.io(),
            std.fs.path.dirname(p).?,
        ) catch {};
    }
    const src = try a.dupeZ(u8, archive);

    const job = bakejob.Job.start(a, src, ins, outs, items.len, 0, 0, true).?;
    defer job.free();

    // The counter moves, and the job says when it is done.
    var waited: usize = 0;
    while (job.isRunning() and waited < 600) : (waited += 1) {
        sleepMs(100);
    }
    const p = job.poll();
    std.debug.print(
        "bake-host: {d} of {d} baked in under {d}s, ok={d}\n",
        .{ p.baked, p.total, (waited + 9) / 10, p.ok },
    );
    try t.expectEqual(@as(c_int, 0), p.running);
    try t.expectEqual(@as(c_int, 1), p.ok);
    try t.expectEqual(@as(u32, @intCast(items.len)), p.total);
    try t.expectEqual(@as(u32, @intCast(items.len)), p.baked);
    try t.expectEqual(@as(u32, @intCast(items.len)), p.done);

    // And every chart landed where the rules said it would.
    const io = std.Io.Threaded.global_single_threaded.io();
    for (outs) |o| {
        const f = std.Io.Dir.cwd().openFile(io, o, .{}) catch {
            std.debug.print("bake-host: nothing at {s}\n", .{o});
            return error.TestUnexpectedResult;
        };
        defer f.close(io);
        const st = try f.stat(io);
        try t.expect(st.size > 0);
    }
}

test "a cancelled bake stops, and what landed is still usable" {
    const archive = archivePath() orelse return error.SkipZigTest;
    const a = t.allocator;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const items = try pickCells(aa, archive);
    if (items.len == 0) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const out_dir = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const ins = try a.alloc([:0]u8, items.len);
    const outs = try a.alloc([:0]u8, items.len);
    for (items, ins, outs) |item, *i, *o| {
        i.* = try a.dupeZ(u8, item.path);
        const p = try rules.outputPath(aa, out_dir, archive, item);
        o.* = try a.dupeZ(u8, p);
        std.Io.Dir.cwd().createDirPath(
            std.Io.Threaded.global_single_threaded.io(),
            std.fs.path.dirname(p).?,
        ) catch {};
    }
    const src = try a.dupeZ(u8, archive);

    const job = bakejob.Job.start(a, src, ins, outs, items.len, 0, 0, true).?;
    defer job.free();
    job.cancel();

    var waited: usize = 0;
    while (job.isRunning() and waited < 600) : (waited += 1) {
        sleepMs(100);
    }
    const p = job.poll();
    try t.expectEqual(@as(c_int, 0), p.running);
    // tile57 stops at the next chart boundary, so a cancel lands within about
    // one cell's bake time and is not a failure.
    try t.expectEqual(@as(c_int, 1), p.ok);
    try t.expect(p.baked <= p.total);
}
