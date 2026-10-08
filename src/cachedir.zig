//! Where the app keeps files it can produce again.
//!
//! This is a leaf module. root.zig, noaajob.zig and the host's setter all need
//! the same root, and they import from different branches of the graph.
//! Holding the root in any one of them creates an import cycle.
//!
//! Every file under this root can be built or fetched again, and the OS may
//! purge it at any time. Mariner data belongs elsewhere.

const std = @import("std");
const builtin = @import("builtin");

/// A host-set root, for a platform that has no cache path in the environment.
/// Android must set it. The app there has no HOME and no XDG_CACHE_HOME, so
/// this is the only route to a writable cache. Owned here. Set it before
/// opening.
var root: ?[]u8 = null;

/// Adopt `path` as the cache root, replacing any previous one.
pub fn setRoot(path: []const u8) void {
    const a = std.heap.c_allocator;
    const dup = a.dupe(u8, path) catch return;
    if (root) |old| a.free(old);
    root = dup;
}

/// The root itself: the host's if it gave one, else XDG_CACHE_HOME, else the
/// platform default under HOME. Owned by `alloc`, null when none resolves.
pub fn rootPath(alloc: std.mem.Allocator) ?[]u8 {
    if (root) |r| return alloc.dupe(u8, r) catch null;
    if (std.c.getenv("XDG_CACHE_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return alloc.dupe(u8, s) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    if (home.len == 0) return null;
    return switch (builtin.os.tag) {
        .macos, .ios => std.fmt.allocPrint(alloc, "{s}/Library/Caches", .{home}) catch null,
        else => std.fmt.allocPrint(alloc, "{s}/.cache", .{home}) catch null,
    };
}

/// `<root>/lookout/v<version>`, for files the engine builds. Keyed by the
/// engine version, so a catalogue or engine change invalidates it. This does
/// not create the directory. Owned by `alloc`.
pub fn versionedPath(alloc: std.mem.Allocator, ver: []const u8) ?[]u8 {
    const r = rootPath(alloc) orelse return null;
    defer alloc.free(r);
    return std.fmt.allocPrint(alloc, "{s}/lookout/v{s}", .{ r, ver }) catch null;
}

/// `<root>/lookout/fetched`, for files the core downloads: NOAA's product
/// catalog.
///
/// The path omits the engine version. An engine upgrade does not invalidate a
/// file NOAA published, and a mariner who upgrades at the dock keeps the
/// catalog they need at sea.
///
/// Creates the directory. Owned by `alloc`. Null when no root resolves.
pub fn fetchedDir(alloc: std.mem.Allocator) ?[]u8 {
    const r = rootPath(alloc) orelse return null;
    defer alloc.free(r);
    const dir = std.fmt.allocPrint(alloc, "{s}/lookout/fetched", .{r}) catch return null;
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().createDirPath(io, dir) catch {
        alloc.free(dir);
        return null;
    };
    return dir;
}
