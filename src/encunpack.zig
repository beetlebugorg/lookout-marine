//! Unpacking an ENC exchange set zip into a directory, so the directory is
//! an ordinary ENC_ROOT. It has no service and opens no socket. The NOAA
//! download calls it once a transfer is on disk.

const std = @import("std");
const noaa = @import("noaa.zig");

/// Unpack the exchange set in the zip at `zip_path` into `dest`.
///
/// Leaving NOAA's zips in place gave the shell a directory of 829 archives,
/// and it bakes a folder of cells or a single archive, so it refused the
/// pick. Extracting turns the directory into an ordinary ENC_ROOT, and a
/// district bundle unpacks the same way a cell does.
///
/// Each cell directory in the archive is deleted first. An update or a
/// repair unpacks over the installed edition, and std.zip does not
/// overwrite files, so the old cell stayed and a reissue's update files
/// were written beside a base they do not apply to.
///
/// An entry in the directory of a cell named in `skip` is left out of
/// both the delete and the extract.
pub fn unpack(alloc: std.mem.Allocator, zip_path: []const u8, dest: []const u8, skip: []const []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, dest, .{});
    defer dir.close(io);
    var f = try std.Io.Dir.cwd().openFile(io, zip_path, .{});
    defer f.close(io);
    var reader_buf: [4096]u8 = undefined;
    var fr = f.reader(io, &reader_buf);

    try clearCellDirs(alloc, &fr, dir, skip);

    // Entry by entry. std.zip.extract stops at the first file already on
    // disk, every cell's exchange set holds its own ENC_ROOT/CATALOG.031,
    // and they all unpack into the one directory. From the second cell on
    // that entry collided and the rest of the archive went unread, so 828
    // of 829 cells counted as failures. The cell directories were deleted
    // above, so the only collisions left are files every exchange set
    // shares.
    var iter = try std.zip.Iterator.init(&fr);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        if (skip.len != 0) {
            const path = try entryName(&fr, entry, &name_buf) orelse continue;
            if (inSkippedCell(path, skip)) continue;
        }
        entry.extract(&fr, .{ .allow_backslashes = true }, &name_buf, dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
}

/// Delete every cell directory under `dir` that this archive holds a cell
/// file for.
fn clearCellDirs(alloc: std.mem.Allocator, fr: *std.Io.File.Reader, dir: std.Io.Dir, skip: []const []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var cells: std.ArrayList([]u8) = .empty;
    defer {
        for (cells.items) |c| alloc.free(c);
        cells.deinit(alloc);
    }

    var iter = try std.zip.Iterator.init(fr);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        const path = try entryName(fr, entry, &name_buf) orelse continue;
        const cell = cellDirOf(path) orelse continue;
        if (inSkippedCell(path, skip)) continue;
        var seen = false;
        for (cells.items) |c| {
            if (std.mem.eql(u8, c, cell)) seen = true;
        }
        if (seen) continue;
        try cells.append(alloc, try alloc.dupe(u8, cell));
    }
    for (cells.items) |c| try dir.deleteTree(io, c);
}

/// The cell directory that holds an exchange set entry, or null when the
/// entry is not a cell file.
///
/// A cell file is `<NAME>.<nnn>`, the base at 000 and each update after it, in
/// a directory named for the cell: `ENC_ROOT/US5MD1MC/US5MD1MC.000`. The shared
/// `ENC_ROOT/CATALOG.031` and anything else that is not in a directory of its
/// own name is left alone.
fn cellDirOf(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    const file = path[slash + 1 ..];
    const parent = path[0..slash];
    const dir_name = parent[(if (std.mem.lastIndexOfScalar(u8, parent, '/')) |i| i + 1 else 0)..];
    if (file.len < 5 or file[file.len - 4] != '.') return null;
    for (file[file.len - 3 ..]) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }
    const stem = file[0 .. file.len - 4];
    if (dir_name.len == 0 or !std.mem.eql(u8, stem, dir_name)) return null;
    return parent;
}

/// The name of a zip entry, with forward slashes. Null when it does not fit
/// `buf`.
fn entryName(fr: *std.Io.File.Reader, entry: std.zip.Iterator.Entry, buf: []u8) !?[]u8 {
    if (entry.filename_len > buf.len) return null;
    const path = buf[0..entry.filename_len];
    try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    try fr.interface.readSliceAll(path);
    std.mem.replaceScalar(u8, path, '\\', '/');
    return path;
}

/// True when `path` is in the directory of a cell named in `skip`.
fn inSkippedCell(path: []const u8, skip: []const []const u8) bool {
    if (skip.len == 0) return false;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    const parent = path[0..slash];
    const cell = parent[(if (std.mem.lastIndexOfScalar(u8, parent, '/')) |i| i + 1 else 0)..];
    return noaa.isHeld(skip, cell);
}

/// Create a directory and every parent it needs.
pub fn makeDir(path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, path);
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

/// One file in a zip a test builds.
pub const TestEntry = struct { name: []const u8, data: []const u8 };

/// A zip of stored entries, in the layout of an exchange set, for tests.
/// Owned by `alloc`.
pub fn testZip(alloc: std.mem.Allocator, entries: []const TestEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const offsets = try alloc.alloc(u32, entries.len);
    defer alloc.free(offsets);
    const put16 = struct {
        fn f(a: std.mem.Allocator, o: *std.ArrayList(u8), v: u16) !void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v, .little);
            try o.appendSlice(a, &b);
        }
    }.f;
    const put32 = struct {
        fn f(a: std.mem.Allocator, o: *std.ArrayList(u8), v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try o.appendSlice(a, &b);
        }
    }.f;
    for (entries, 0..) |e, i| {
        offsets[i] = @intCast(out.items.len);
        const crc = std.hash.Crc32.hash(e.data);
        try put32(alloc, &out, 0x04034b50);
        try put16(alloc, &out, 20); // version needed
        try put16(alloc, &out, 0); // flags
        try put16(alloc, &out, 0); // stored
        try put16(alloc, &out, 0); // time
        try put16(alloc, &out, 0x21); // date
        try put32(alloc, &out, crc);
        try put32(alloc, &out, @intCast(e.data.len));
        try put32(alloc, &out, @intCast(e.data.len));
        try put16(alloc, &out, @intCast(e.name.len));
        try put16(alloc, &out, 0);
        try out.appendSlice(alloc, e.name);
        try out.appendSlice(alloc, e.data);
    }
    const cd_start: u32 = @intCast(out.items.len);
    for (entries, 0..) |e, i| {
        try put32(alloc, &out, 0x02014b50);
        try put16(alloc, &out, 20); // made by
        try put16(alloc, &out, 20); // needed
        try put16(alloc, &out, 0);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, 0x21);
        try put32(alloc, &out, std.hash.Crc32.hash(e.data));
        try put32(alloc, &out, @intCast(e.data.len));
        try put32(alloc, &out, @intCast(e.data.len));
        try put16(alloc, &out, @intCast(e.name.len));
        try put16(alloc, &out, 0); // extra
        try put16(alloc, &out, 0); // comment
        try put16(alloc, &out, 0); // disk
        try put16(alloc, &out, 0); // internal attributes
        try put32(alloc, &out, 0); // external attributes
        try put32(alloc, &out, offsets[i]);
        try out.appendSlice(alloc, e.name);
    }
    const cd_size: u32 = @as(u32, @intCast(out.items.len)) - cd_start;
    try put32(alloc, &out, 0x06054b50);
    try put16(alloc, &out, 0);
    try put16(alloc, &out, 0);
    try put16(alloc, &out, @intCast(entries.len));
    try put16(alloc, &out, @intCast(entries.len));
    try put32(alloc, &out, cd_size);
    try put32(alloc, &out, cd_start);
    try put16(alloc, &out, 0);
    return out.toOwnedSlice(alloc);
}

fn exists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "a cell directory is named for the cell it holds" {
    try testing.expectEqualStrings("ENC_ROOT/US5MD1MC", cellDirOf("ENC_ROOT/US5MD1MC/US5MD1MC.000").?);
    try testing.expectEqualStrings("05CGD_ENCs/ENC_ROOT/US5MD1MC", cellDirOf("05CGD_ENCs/ENC_ROOT/US5MD1MC/US5MD1MC.012").?);
    try testing.expect(cellDirOf("ENC_ROOT/CATALOG.031") == null);
    try testing.expect(cellDirOf("ENC_ROOT/US5MD1MC/US5MD1MC.TXT") == null);
    try testing.expect(cellDirOf("ENC_ROOT/US5MD1MC/README.000") == null);
    try testing.expect(cellDirOf("US5MD1MC.000") == null);
}

test "a reissued cell replaces the edition already unpacked" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dest = "/tmp/lookout-noaa-reissue";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    try makeDir(dest);

    const first = try testZip(alloc, &.{
        .{ .name = "ENC_ROOT/CATALOG.031", .data = "catalog 27" },
        .{ .name = "ENC_ROOT/US5MD1MC/US5MD1MC.000", .data = "edition 27" },
        .{ .name = "ENC_ROOT/US5MD1MC/US5MD1MC.001", .data = "update 27.1" },
        .{ .name = "ENC_ROOT/US5MD1MD/US5MD1MD.000", .data = "neighbour" },
    });
    defer alloc.free(first);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest ++ "/a.zip", .data = first });
    try unpack(alloc, dest ++ "/a.zip", dest, &.{});

    // The reissue has a new base and no update files.
    const second = try testZip(alloc, &.{
        .{ .name = "ENC_ROOT/CATALOG.031", .data = "catalog 28" },
        .{ .name = "ENC_ROOT/US5MD1MC/US5MD1MC.000", .data = "edition 28" },
    });
    defer alloc.free(second);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest ++ "/b.zip", .data = second });
    try unpack(alloc, dest ++ "/b.zip", dest, &.{});

    const base = try std.Io.Dir.cwd().readFileAlloc(io, dest ++ "/ENC_ROOT/US5MD1MC/US5MD1MC.000", alloc, .limited(1 << 20));
    defer alloc.free(base);
    try testing.expectEqualStrings("edition 28", base);
    // The old edition's update file is deleted with it.
    try testing.expect(!exists(dest ++ "/ENC_ROOT/US5MD1MC/US5MD1MC.001"));
    // A cell missing from the reissue is untouched.
    try testing.expect(exists(dest ++ "/ENC_ROOT/US5MD1MD/US5MD1MD.000"));
}
