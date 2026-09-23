//! Collecting an answer that arrives in pieces.
//!
//! A shell may hand back a body a piece at a time, so that a download the size
//! of a NOAA district never sits in memory whole (include/lookout-library.h,
//! lookout_http_respond_chunk). Most of what the app fetches is a style, a
//! TileJSON, a sprite sheet or a catalog: small, and read whole. Those go
//! through here, which holds a buffer per request and hands the caller the
//! finished body.
//!
//! A request is opened with `begin` when it is issued. A piece for an id with
//! no open request is dropped: the request was cancelled or finished, and a
//! piece still queued on a fetch thread arrived after it.
//!
//! Pieces for one request arrive on one thread in order. Two requests may be
//! in flight on two threads, so the list has a lock.

const std = @import("std");
const lock = @import("lock.zig");
const Lock = lock.Lock;

pub const Gather = struct {
    const Entry = struct {
        id: u64,
        buf: std.ArrayList(u8) = .empty,
        /// Set when a piece could not be kept, or the body ran past the cap.
        /// The finished answer then reports a transport failure.
        broken: bool = false,
    };

    alloc: std.mem.Allocator,
    /// The most a gathered body may reach. A document past it is not the one
    /// we asked for.
    cap: usize,
    mu: Lock = .{},
    open: std.ArrayList(Entry) = .empty,

    pub fn init(alloc: std.mem.Allocator, cap: usize) Gather {
        return .{ .alloc = alloc, .cap = cap };
    }

    pub fn deinit(self: *Gather) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.open.items) |*e| e.buf.deinit(self.alloc);
        self.open.deinit(self.alloc);
    }

    /// What a finished request came to. `bytes` is owned by the caller, who
    /// frees it with the same allocator.
    pub const Whole = struct {
        bytes: []u8,
        status: c_int,
    };

    /// Open a request, before its fetch is started. False when the list
    /// could not grow, and every piece for `id` is then dropped.
    pub fn begin(self: *Gather, id: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        self.open.append(self.alloc, .{ .id = id }) catch return false;
        return true;
    }

    /// Take one piece. Returns the finished body on the last piece, and null
    /// while more is coming.
    ///
    /// A shell holding the whole body calls this once with `done` set, and
    /// nothing is buffered: the body is copied straight out.
    ///
    /// A piece for an id with no open request is dropped. Its last piece
    /// returns an empty body with status 0, as a transport failure does.
    pub fn take(self: *Gather, id: u64, bytes: []const u8, status: c_int, done: bool) ?Whole {
        self.mu.lock();
        defer self.mu.unlock();

        var at: ?usize = null;
        for (self.open.items, 0..) |e, i| {
            if (e.id == id) at = i;
        }
        const i = at orelse return if (done) .{ .bytes = &.{}, .status = 0 } else null;

        if (done and self.open.items[i].buf.items.len == 0 and !self.open.items[i].broken) {
            // One piece and the whole answer, the common case.
            _ = self.open.swapRemove(i);
            if (bytes.len == 0 or bytes.len > self.cap) {
                return .{ .bytes = &.{}, .status = if (bytes.len > self.cap) 0 else status };
            }
            const own = self.alloc.dupe(u8, bytes) catch
                return .{ .bytes = &.{}, .status = 0 };
            return .{ .bytes = own, .status = status };
        }

        const e = &self.open.items[i];
        if (!e.broken) {
            if (e.buf.items.len + bytes.len > self.cap) {
                e.broken = true;
            } else {
                e.buf.appendSlice(self.alloc, bytes) catch {
                    e.broken = true;
                };
            }
        }
        if (!done) return null;

        var taken = self.open.swapRemove(i);
        if (taken.broken) {
            taken.buf.deinit(self.alloc);
            return .{ .bytes = &.{}, .status = 0 };
        }
        const body = taken.buf.toOwnedSlice(self.alloc) catch {
            taken.buf.deinit(self.alloc);
            return .{ .bytes = &.{}, .status = 0 };
        };
        return .{ .bytes = body, .status = status };
    }

    /// Close a request that will not be finished. Its later pieces are
    /// dropped.
    pub fn drop(self: *Gather, id: u64) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.open.items, 0..) |*e, i| {
            if (e.id != id) continue;
            e.buf.deinit(self.alloc);
            _ = self.open.swapRemove(i);
            return;
        }
    }

    pub fn clear(self: *Gather) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.open.items) |*e| e.buf.deinit(self.alloc);
        self.open.clearRetainingCapacity();
    }
};

const testing = std.testing;

test "one piece with the whole body needs no buffer" {
    var g = Gather.init(testing.allocator, 1024);
    defer g.deinit();
    try testing.expect(g.begin(1));
    const w = g.take(1, "hello", 200, true).?;
    defer testing.allocator.free(w.bytes);
    try testing.expectEqualStrings("hello", w.bytes);
    try testing.expectEqual(@as(c_int, 200), w.status);
    try testing.expectEqual(@as(usize, 0), g.open.items.len);
}

test "pieces join in the order they arrive" {
    var g = Gather.init(testing.allocator, 1024);
    defer g.deinit();
    try testing.expect(g.begin(7));
    try testing.expect(g.take(7, "one ", 200, false) == null);
    try testing.expect(g.take(7, "two ", 200, false) == null);
    const w = g.take(7, "three", 200, true).?;
    defer testing.allocator.free(w.bytes);
    try testing.expectEqualStrings("one two three", w.bytes);
    try testing.expectEqual(@as(usize, 0), g.open.items.len);
}

test "two requests gather side by side" {
    var g = Gather.init(testing.allocator, 1024);
    defer g.deinit();
    try testing.expect(g.begin(1));
    try testing.expect(g.begin(2));
    _ = g.take(1, "a", 200, false);
    _ = g.take(2, "x", 200, false);
    _ = g.take(1, "b", 200, false);
    const one = g.take(1, "c", 200, true).?;
    defer testing.allocator.free(one.bytes);
    const two = g.take(2, "y", 200, true).?;
    defer testing.allocator.free(two.bytes);
    try testing.expectEqualStrings("abc", one.bytes);
    try testing.expectEqualStrings("xy", two.bytes);
}

test "a body past the cap comes back as a transport failure" {
    var g = Gather.init(testing.allocator, 4);
    defer g.deinit();
    try testing.expect(g.begin(3));
    _ = g.take(3, "abc", 200, false);
    const w = g.take(3, "defgh", 200, true).?;
    try testing.expectEqual(@as(usize, 0), w.bytes.len);
    try testing.expectEqual(@as(c_int, 0), w.status);
    try testing.expectEqual(@as(usize, 0), g.open.items.len);
}

test "a request dropped mid-body leaves nothing behind" {
    var g = Gather.init(testing.allocator, 1024);
    defer g.deinit();
    try testing.expect(g.begin(5));
    _ = g.take(5, "half", 200, false);
    try testing.expectEqual(@as(usize, 1), g.open.items.len);
    g.drop(5);
    try testing.expectEqual(@as(usize, 0), g.open.items.len);
    // A piece still queued when the request was dropped opens no entry.
    try testing.expect(g.take(5, "rest", 200, false) == null);
    try testing.expectEqual(@as(usize, 0), g.open.items.len);
}

test "a piece for an id with no open request leaves the gather empty" {
    var g = Gather.init(testing.allocator, 1024);
    defer g.deinit();
    try testing.expect(g.take(11, "stray", 200, false) == null);
    try testing.expectEqual(@as(usize, 0), g.open.items.len);
    const w = g.take(11, "end", 200, true).?;
    try testing.expectEqual(@as(usize, 0), w.bytes.len);
    try testing.expectEqual(@as(c_int, 0), w.status);
    try testing.expectEqual(@as(usize, 0), g.open.items.len);
}

test "an empty answer says so without a body" {
    var g = Gather.init(testing.allocator, 1024);
    defer g.deinit();
    try testing.expect(g.begin(9));
    const w = g.take(9, "", 404, true).?;
    try testing.expectEqual(@as(usize, 0), w.bytes.len);
    try testing.expectEqual(@as(c_int, 404), w.status);
}
