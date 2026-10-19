//! Removing prepared and downloaded charts: rename first, delete behind.
//!
//! A 7,224-chart library is 36,000 files, measured at 3.7 seconds of disk
//! work. The rename is one atomic step per directory, so the charts are gone
//! from where a scan looks before the call returns. The delete runs on a
//! thread of its own.
//!
//! A bin is a directory named with bake.trash_prefix. A process that dies
//! during the delete leaves one behind, and `sweep` removes it at the next
//! launch.

const std = @import("std");
const bake = @import("shell/bake.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

var serial: std.atomic.Value(u32) = .init(0);

/// Make a new bin under `root` and return its path. The name has the time and
/// a per-process count in it, so two removals in one process do not collide.
/// The caller frees the path.
pub fn makeBin(alloc: std.mem.Allocator, root: []const u8, now_ms: i64) ![]u8 {
    const n = serial.fetchAdd(1, .monotonic);
    const name = try std.fmt.allocPrint(alloc, "{s}{x}-{d}", .{ bake.trash_prefix, now_ms, n });
    defer alloc.free(name);
    const path = try std.fs.path.join(alloc, &.{ root, name });
    errdefer alloc.free(path);
    try std.Io.Dir.cwd().createDirPath(io(), path);
    return path;
}

/// Move `target` into `bin` as entry number `i`. The number keeps a source
/// cell and its prepared chart apart, since both have the cell's name.
/// Returns false when the rename fails, as it does across volumes.
pub fn move(bin: []const u8, i: usize, target: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const into = std.fmt.bufPrint(&buf, "{s}/{d}-{s}", .{ bin, i, std.fs.path.basename(target) }) catch return false;
    const cwd = std.Io.Dir.cwd();
    cwd.rename(target, cwd, into, io()) catch return false;
    return true;
}

/// True when `path` is a directory.
pub fn isDir(path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io(), path, .{}) catch return false;
    d.close(io());
    return true;
}

/// The directories directly inside `dir`, by name. The caller frees each name
/// and the slice.
pub fn childDirs(alloc: std.mem.Allocator, dir: []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| alloc.free(n);
        out.deinit(alloc);
    }
    var d = std.Io.Dir.cwd().openDir(io(), dir, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
    defer d.close(io());
    var it = d.iterate();
    while (try it.next(io())) |e| {
        if (e.kind != .directory) continue;
        const name = try alloc.dupe(u8, e.name);
        out.append(alloc, name) catch |err| {
            alloc.free(name);
            return err;
        };
    }
    return out.toOwnedSlice(alloc);
}

/// Delete every bin directly under `root`. Returns how many went. Blocks while
/// it deletes.
pub fn sweep(alloc: std.mem.Allocator, root: []const u8) usize {
    const names = childDirs(alloc, root) catch return 0;
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    var d = std.Io.Dir.cwd().openDir(io(), root, .{}) catch return 0;
    defer d.close(io());
    var n: usize = 0;
    for (names) |name| {
        if (!bake.isTrash(name)) continue;
        d.deleteTree(io(), name) catch continue;
        n += 1;
    }
    return n;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn testRoot(tmp: *testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "the sweep removes the bins a crash left and keeps the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer testing.allocator.free(root);

    try tmp.dir.createDirPath(io(), ".removing-1f-0/0-US5AA001");
    try tmp.dir.writeFile(io(), .{ .sub_path = ".removing-1f-0/0-US5AA001/US5AA001.pmtiles", .data = "x" });
    try tmp.dir.createDirPath(io(), "NOAA/US5AA002");
    try tmp.dir.writeFile(io(), .{ .sub_path = ".removing-note", .data = "a file" });

    try testing.expectEqual(@as(usize, 1), sweep(testing.allocator, root));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io(), ".removing-1f-0", .{}));
    try tmp.dir.access(io(), "NOAA/US5AA002", .{});
    try tmp.dir.access(io(), ".removing-note", .{});
    // A second sweep finds none.
    try testing.expectEqual(@as(usize, 0), sweep(testing.allocator, root));
}

test "a target moved into a bin keeps its name behind its number" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer testing.allocator.free(root);

    try tmp.dir.createDirPath(io(), "src/US5AA001");
    const bin = try makeBin(testing.allocator, root, 7);
    defer testing.allocator.free(bin);
    try testing.expect(bake.isTrash(std.fs.path.basename(bin)));

    const target = try std.fs.path.join(testing.allocator, &.{ root, "src/US5AA001" });
    defer testing.allocator.free(target);
    try testing.expect(move(bin, 3, target));
    try testing.expect(!isDir(target));
    const moved = try std.fmt.allocPrint(testing.allocator, "{s}/3-US5AA001", .{bin});
    defer testing.allocator.free(moved);
    try testing.expect(isDir(moved));
}
