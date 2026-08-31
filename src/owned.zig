//! A result the core hands over whole: one arena, borrowed pointers inside it,
//! and one call to free it.
//!
//! The core opens an arena, fills the C structs in it, and returns a pointer.
//! The shell reads the rows through those pointers and frees the arena in one
//! call. The result is a copy, so the engine goes on changing while a shell
//! reads one. It is built under the api lock and may be read from any thread.
//!
//! Every string is NUL-terminated.

const std = @import("std");

/// One result's arena, and the rows it hands out. `T` is the public row type;
/// the rows are pointers so that a row can also be the handle its own
/// collections hang off.
pub fn Owned(comptime T: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        rows: []const *const T = &.{},

        pub fn init(gpa: std.mem.Allocator) !*Self {
            const self = try gpa.create(Self);
            self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
            return self;
        }

        pub fn alloc(self: *Self) std.mem.Allocator {
            return self.arena.allocator();
        }

        pub fn free(self: *Self) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self);
        }
    };
}

/// Copy `s` into the arena, NUL-terminated.
pub fn str(alloc: std.mem.Allocator, s: []const u8) ![*:0]const u8 {
    return (try alloc.dupeZ(u8, s)).ptr;
}

/// Copy each of `items` into the arena.
pub fn strs(alloc: std.mem.Allocator, items: anytype) ![]const [*:0]const u8 {
    const out = try alloc.alloc([*:0]const u8, items.len);
    for (items, out) |s, *dst| dst.* = try str(alloc, s);
    return out;
}

/// The public prefix of each record, as the array of pointers a shell walks.
/// `field` is the record's first field, so the pointer is the record's own
/// address and the accessors cast it back.
pub fn published(
    comptime Rec: type,
    comptime field: []const u8,
    alloc: std.mem.Allocator,
    recs: []Rec,
) ![]const *const @FieldType(Rec, field) {
    const out = try alloc.alloc(*const @FieldType(Rec, field), recs.len);
    for (recs, out) |*rec, *dst| dst.* = &@field(rec, field);
    return out;
}

const t = std.testing;

test "a string is copied and terminated" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = try str(arena.allocator(), "org.beetlebug.ais");
    try t.expectEqualStrings("org.beetlebug.ais", std.mem.span(s));
}

test "an empty string is still terminated" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const s = try str(arena.allocator(), "");
    try t.expectEqual(@as(u8, 0), s[0]);
}

test "a result frees its arena and itself" {
    const Row = extern struct { id: [*:0]const u8 };
    const Rec = extern struct { row: Row, extra: usize };
    const r = try Owned(Row).init(t.allocator);
    const recs = try r.alloc().alloc(Rec, 2);
    recs[0] = .{ .row = .{ .id = try str(r.alloc(), "one") }, .extra = 0 };
    recs[1] = .{ .row = .{ .id = try str(r.alloc(), "two") }, .extra = 0 };
    r.rows = try published(Rec, "row", r.alloc(), recs);
    try t.expectEqualStrings("two", std.mem.span(r.rows[1].id));
    r.free();
}

test "a published pointer casts back to its record" {
    const Row = extern struct { id: [*:0]const u8 };
    const Rec = extern struct { row: Row, extra: usize };
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const recs = try a.alloc(Rec, 1);
    recs[0] = .{ .row = .{ .id = try str(a, "one") }, .extra = 42 };
    const rows = try published(Rec, "row", a, recs);
    const back: *const Rec = @ptrCast(@alignCast(rows[0]));
    try t.expectEqual(@as(usize, 42), back.extra);
}
