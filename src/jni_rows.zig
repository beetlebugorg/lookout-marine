//! The flat string rows the Android JNI hands to Java, written from the core's
//! own structs. The JNI file itself imports jni.h, which only the NDK sysroot
//! holds, so the row shapes live here where a host test reaches them.
//!
//! `out` is any writer with `str(?[*:0]const u8)` and `print(fmt, args)`.

const std = @import("std");

const chartsets = @import("chartsets.zig");
const library = @import("library.zig");

pub const Set = chartsets.Set;
pub const File = library.File;

/// Strings per set in `setRow`.
pub const set_fields = 13;

/// One set: path, title, producer, on, scanned, charts, pictures, unprepared,
/// bytes, bandLo, bandHi, managed, heldBack. The last two are at the end, so
/// the first eleven keep their indices.
pub fn setRow(out: anytype, set: *const Set) void {
    out.str(set.path);
    out.str(set.title);
    out.str(set.producer);
    out.print("{d}", .{set.on});
    out.print("{d}", .{set.scanned});
    out.print("{d}", .{set.charts});
    out.print("{d}", .{set.pictures});
    out.print("{d}", .{set.unprepared});
    out.print("{d}", .{set.bytes});
    out.print("{d}", .{set.band_lo});
    out.print("{d}", .{set.band_hi});
    out.print("{d}", .{set.managed});
    out.print("{d}", .{set.held_back});
}

/// Strings per file in `fileRow`.
pub const file_fields = 12;

/// One file: path, name, kind, band, bandName, bytes, scale, located, w, s,
/// e, n.
pub fn fileRow(out: anytype, f: *const File) void {
    out.str(f.path);
    out.str(f.name);
    out.print("{d}", .{@intFromEnum(f.kind)});
    out.print("{d}", .{f.band});
    out.str(f.band_name);
    out.print("{d}", .{f.bytes});
    out.print("{d}", .{f.scale});
    out.print("{d}", .{f.located});
    out.print("{d}", .{f.west});
    out.print("{d}", .{f.south});
    out.print("{d}", .{f.east});
    out.print("{d}", .{f.north});
}

const t = std.testing;

/// Collects the rows as a test reads them.
const Rows = struct {
    list: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Rows) void {
        for (self.list.items) |s| t.allocator.free(s);
        self.list.deinit(t.allocator);
    }

    fn str(self: *Rows, s: ?[*:0]const u8) void {
        const src = if (s) |p| std.mem.span(p) else "";
        const copy = t.allocator.dupe(u8, src) catch return;
        self.list.append(t.allocator, copy) catch t.allocator.free(copy);
    }

    fn print(self: *Rows, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(t.allocator, fmt, args) catch return;
        self.list.append(t.allocator, s) catch t.allocator.free(s);
    }
};

fn expectRow(want: []const []const u8, got: *const Rows) !void {
    try t.expectEqual(want.len, got.list.items.len);
    for (want, got.list.items) |w, g| try t.expectEqualStrings(w, g);
}

test "a set row reads every field from the core's struct" {
    const set: Set = .{
        .path = "/charts/NOAA",
        .title = "NOAA",
        .producer = "US",
        .on = 1,
        .managed = 2,
        .scanned = 3,
        .charts = 4,
        .pictures = 5,
        .unprepared = 6,
        .bytes = 7,
        .band_lo = 8,
        .band_hi = 9,
        .held_back = 10,
    };
    var rows: Rows = .{};
    defer rows.deinit();
    setRow(&rows, &set);
    try expectRow(&.{
        "/charts/NOAA", "NOAA", "US", "1", "3", "4", "5", "6", "7", "8", "9", "2", "10",
    }, &rows);
    try t.expectEqual(@as(usize, set_fields), rows.list.items.len);
}

test "a file row reads every field from the core's struct" {
    const f: File = .{
        .path = "/charts/US5MD1MC.000",
        .name = "US5MD1MC",
        .kind = .update,
        .band = 5,
        .band_name = "Harbor",
        .bytes = 11,
        .scale = 12,
        .located = 1,
        .west = -13,
        .south = 14,
        .east = -15,
        .north = 16,
        .edition = 17,
        .update = 18,
    };
    var rows: Rows = .{};
    defer rows.deinit();
    fileRow(&rows, &f);
    try expectRow(&.{
        "/charts/US5MD1MC.000", "US5MD1MC", "2", "5", "Harbor", "11", "12", "1", "-13", "14", "-15", "16",
    }, &rows);
    try t.expectEqual(@as(usize, file_fields), rows.list.items.len);
}
