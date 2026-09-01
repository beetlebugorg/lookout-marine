//! What a shell keeps across launches, in one file.
//!
//! The camera pose, the recents, the mariner settings, the plugin values, the
//! chart links, the chart sets and the raster charts. Four shells kept four
//! stores over four platform preference systems, and every one of them had to
//! be taught the same key names.
//!
//! THE FILE IS JSON: one object of groups, each an object of keys. A value
//! keeps the type it was written with, so a number is a JSON number, a flag is
//! true or false and a list is an array of strings. What a value MEANS is
//! still the accessor's business, and every accessor coerces: a number read as
//! text is its shortest form, and text read as a number is parsed.
//!
//! WRITES COALESCE. A pose saved every three seconds must not fsync a file
//! every three seconds, so a write marks the store dirty and the file is
//! written at the next flush, at close, or once `tick` finds the oldest
//! unwritten change older than `coalesce_ms`. The engine's frame loop ticks
//! it, so a store written once at startup still lands.
//!
//! ONE LOCK over the file. Windows documents the interleave two writers
//! produce: both read the file, both write it, and the second write loses the
//! first one's group.
//!
//! A FILE THAT WILL NOT PARSE is set aside as `<name>.broken` before an empty
//! store replaces it. The next write overwrites the live file either way. The
//! copy keeps a mariner's library recoverable.

const std = @import("std");

const Lock = @import("lock.zig").Lock;
const clock = @import("clock.zig");

/// The groups a shell writes. The names are the file's, so a shell that names
/// its own group here is naming it for every shell.
pub const group_view = "view";
pub const group_recents = "recents";
pub const group_raster = "raster";
pub const group_mariner = "mariner.v1";
pub const group_plugins = "plugins.v1";
pub const group_chartlinks = "chartlinks";
pub const group_chartsets = "chartsets";

/// The file, under the directory a shell hands over.
pub const file_name = "settings.json";

/// How long an unwritten change may wait. The engine writes a pose every three
/// seconds while the mariner is moving, and one file write a second is plenty.
pub const coalesce_ms: i64 = 1000;

/// What a value was written as. A scalar is held as the text it stands for and
/// the kind says how it is written and read back, so a number comes back a
/// number rather than a quoted string. A list holds its items.
const Kind = enum { text, number, flag, list };

const Entry = struct {
    key: [:0]u8,
    value: [:0]u8,
    kind: Kind = .text,
    /// The items of a `.list`, and empty for every other kind.
    items: [][:0]u8 = &.{},

    fn free(self: Entry, gpa: std.mem.Allocator) void {
        gpa.free(self.key);
        gpa.free(self.value);
        for (self.items) |item| gpa.free(item);
        gpa.free(self.items);
    }
};

const Group = struct {
    name: [:0]u8,
    entries: std.ArrayList(Entry) = .empty,
};

/// One store, open on one file.
pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The file, absolute.
    path: [:0]u8,
    mu: Lock = .{},
    groups: std.ArrayList(Group) = .empty,

    /// Everything a read hands out lives here, and it is reset by the next
    /// write. That is the borrow contract the header states.
    reads: std.heap.ArenaAllocator,

    /// When the oldest unwritten change was made. Null when nothing is
    /// waiting.
    dirty_at: ?i64 = null,
    /// Set when a write to the file failed, so `flush` says so once rather
    /// than on every change.
    said_write_failed: bool = false,

    /// Open the store under `dir`, reading `settings.ini` if it is there. The
    /// directory is made at the first write, so a shell that only reads leaves
    /// no trace.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !*Store {
        const self = try gpa.create(Store);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .path = undefined,
            .reads = std.heap.ArenaAllocator.init(gpa),
        };
        self.path = try std.fs.path.joinZ(gpa, &.{ dir, file_name });
        errdefer gpa.free(self.path);
        self.load();
        return self;
    }

    /// Write anything waiting, then close.
    pub fn close(self: *Store) void {
        self.flush();
        self.mu.lock();
        self.clearGroups();
        self.groups.deinit(self.gpa);
        self.mu.unlock();
        self.reads.deinit();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    fn clearGroups(self: *Store) void {
        for (self.groups.items) |*g| {
            for (g.entries.items) |e| e.free(self.gpa);
            g.entries.deinit(self.gpa);
            self.gpa.free(g.name);
        }
        self.groups.clearRetainingCapacity();
    }

    // ---- reading ---------------------------------------------------------

    /// True when the key is set.
    pub fn has(self: *Store, group: []const u8, key: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.findLocked(group, key) != null;
    }

    /// The value as text, or null when the key is not set. Borrowed until the
    /// next write.
    pub fn text(self: *Store, group: []const u8, key: []const u8) ?[:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findLocked(group, key) orelse return null;
        return e.value;
    }

    /// The value as a number, or `fallback` when the key is not set or does
    /// not parse as one.
    pub fn number(self: *Store, group: []const u8, key: []const u8, fallback: f64) f64 {
        const v = self.text(group, key) orelse return fallback;
        return std.fmt.parseFloat(f64, v) catch fallback;
    }

    /// The value as a flag. "true" and "1" are true, "false" and "0" false,
    /// anything else `fallback`.
    pub fn flag(self: *Store, group: []const u8, key: []const u8, fallback: bool) bool {
        const v = self.text(group, key) orelse return fallback;
        if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
        if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
        return fallback;
    }

    /// The value as a list. Empty when the key is not set. Borrowed until the
    /// next write.
    pub fn list(self: *Store, group: []const u8, key: []const u8) []const [:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findLocked(group, key) orelse return &.{};
        return e.items;
    }

    /// The same items as an array of NUL-terminated pointers, the shape the C
    /// ABI hands over. Borrowed until the next write.
    pub fn listPtrs(self: *Store, group: []const u8, key: []const u8) []const [*:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findLocked(group, key) orelse return &.{};
        return asPtrs(self.reads.allocator(), e.items);
    }

    /// The keys of a group, as pointers. Borrowed until the next write.
    pub fn keyPtrs(self: *Store, group: []const u8) []const [*:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const g = self.groupLocked(group) orelse return &.{};
        const a = self.reads.allocator();
        const out = a.alloc([*:0]const u8, g.entries.items.len) catch return &.{};
        for (g.entries.items, out) |e, *dst| dst.* = e.key.ptr;
        return out;
    }

    /// The keys set under a group, in the order they were written. Borrowed
    /// until the next write.
    pub fn keys(self: *Store, group: []const u8) []const [:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const g = self.groupLocked(group) orelse return &.{};
        const a = self.reads.allocator();
        const out = a.alloc([:0]const u8, g.entries.items.len) catch return &.{};
        for (g.entries.items, out) |e, *dst| dst.* = e.key;
        return out;
    }

    // ---- writing ---------------------------------------------------------

    /// Set a key to text. The store is written at the next flush, at close, or
    /// once the oldest unwritten change reaches `coalesce_ms`.
    pub fn setText(self: *Store, group: []const u8, key: []const u8, value: []const u8) void {
        self.setLocked(group, key, value, .text);
    }

    /// A number is written in its shortest form, so an integral value writes
    /// as an integer and a shell that reads it as one still can.
    pub fn setNumber(self: *Store, group: []const u8, key: []const u8, value: f64) void {
        var buf: [40]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        self.setLocked(group, key, s, .number);
    }

    pub fn setFlag(self: *Store, group: []const u8, key: []const u8, value: bool) void {
        self.setLocked(group, key, if (value) "true" else "false", .flag);
    }

    /// Set a key to a list. An EMPTY list clears the key, so a read of it
    /// comes back empty.
    pub fn setList(self: *Store, group: []const u8, key: []const u8, items: []const []const u8) void {
        if (items.len == 0) {
            self.remove(group, key);
            return;
        }
        self.mu.lock();
        defer self.mu.unlock();
        const owned = self.gpa.alloc([:0]u8, items.len) catch return;
        var made: usize = 0;
        errdefer {
            for (owned[0..made]) |o| self.gpa.free(o);
            self.gpa.free(owned);
        }
        for (items, owned) |src, *dst| {
            dst.* = self.gpa.dupeZ(u8, src) catch {
                for (owned[0..made]) |o| self.gpa.free(o);
                self.gpa.free(owned);
                return;
            };
            made += 1;
        }
        const g = self.addGroupLocked(group) catch {
            for (owned) |o| self.gpa.free(o);
            self.gpa.free(owned);
            return;
        };
        self.putListLocked(g, key, owned) catch {
            for (owned) |o| self.gpa.free(o);
            self.gpa.free(owned);
            return;
        };
        self.markDirtyLocked();
    }

    /// Forget a key. Forgetting the last key of a group forgets the group.
    pub fn remove(self: *Store, group: []const u8, key: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const g = self.groupLocked(group) orelse return;
        for (g.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.key, key)) continue;
            e.free(self.gpa);
            _ = g.entries.orderedRemove(i);
            self.markDirtyLocked();
            return;
        }
    }

    /// Write the file if the oldest unwritten change has waited long enough.
    /// A store written once and never again would otherwise sit dirty for the
    /// life of the process, so something has to ask.
    pub fn tick(self: *Store) void {
        self.mu.lock();
        defer self.mu.unlock();
        const since = self.dirty_at orelse return;
        if (clock.wallMs() - since < coalesce_ms) return;
        self.flushLocked();
    }

    /// Write the file now, whatever the coalesce window says. Does nothing
    /// when there is nothing waiting.
    pub fn flush(self: *Store) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.flushLocked();
    }

    // ---- the file --------------------------------------------------------

    fn load(self: *Store) void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.gpa, .limited(8 << 20)) catch |e| {
            // A file that is not there is an empty store, the state of a
            // first launch.
            if (e != error.FileNotFound) self.setAside();
            return;
        };
        defer self.gpa.free(bytes);
        self.parseJson(bytes) catch {
            self.mu.lock();
            self.clearGroups();
            self.mu.unlock();
            self.setAside();
        };
    }

    /// Keep a file that will not parse, under `<name>.broken`, so a mariner's
    /// library and settings are recoverable after the damage.
    fn setAside(self: *Store) void {
        const broken = std.fmt.allocPrintSentinel(self.gpa, "{s}.broken", .{self.path}, 0) catch return;
        defer self.gpa.free(broken);
        const cwd = std.Io.Dir.cwd();
        cwd.rename(self.path, cwd, broken, self.io) catch return;
    }

    /// One object of groups, each an object of keys.
    fn parseJson(self: *Store, bytes: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, bytes, .{});
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.BadRoot,
        };

        self.mu.lock();
        defer self.mu.unlock();

        var groups = root.iterator();
        while (groups.next()) |entry| {
            const members = switch (entry.value_ptr.*) {
                .object => |o| o,
                // A group that is not an object is not a group.
                else => continue,
            };
            _ = try self.addGroupLocked(entry.key_ptr.*);
            // A later group appends to the list, which moves the one being
            // filled out, so a pointer to it goes stale.
            const at = self.groups.items.len - 1;
            var keys_it = members.iterator();
            while (keys_it.next()) |kv| {
                try self.putJsonLocked(&self.groups.items[at], kv.key_ptr.*, kv.value_ptr.*);
            }
        }
    }

    /// One JSON value as the text the accessors read, with the kind it keeps.
    fn putJsonLocked(self: *Store, g: *Group, key: []const u8, value: std.json.Value) !void {
        var buf: [40]u8 = undefined;
        switch (value) {
            .string => |v| try self.putLocked(g, key, v, .text),
            .bool => |v| try self.putLocked(g, key, if (v) "true" else "false", .flag),
            .integer => |v| try self.putLocked(g, key, try std.fmt.bufPrint(&buf, "{d}", .{v}), .number),
            .float => |v| try self.putLocked(g, key, try std.fmt.bufPrint(&buf, "{d}", .{v}), .number),
            .number_string => |v| try self.putLocked(g, key, v, .number),
            .array => |items| {
                var owned: std.ArrayList([:0]u8) = .empty;
                errdefer {
                    for (owned.items) |o| self.gpa.free(o);
                    owned.deinit(self.gpa);
                }
                for (items.items) |item| {
                    // A list is a list of strings. Anything else in one is not
                    // an item this store ever wrote.
                    const text_item = switch (item) {
                        .string => |v| v,
                        else => continue,
                    };
                    try owned.append(self.gpa, try self.gpa.dupeZ(u8, text_item));
                }
                // An empty array is a key with no items, which is how an unset
                // key reads anyway.
                if (owned.items.len == 0) {
                    owned.deinit(self.gpa);
                    return;
                }
                try self.putListLocked(g, key, try owned.toOwnedSlice(self.gpa));
            },
            // A null is a key nobody set, and this store nests no objects.
            .null, .object => {},
        }
    }

    fn flushLocked(self: *Store) void {
        if (self.dirty_at == null) return;
        self.dirty_at = null;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        self.writeJson(&out) catch return;

        const dir = std.fs.path.dirname(self.path) orelse return;
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        // Write beside the file and rename over it, so a crash mid-write
        // leaves the mariner the settings they had rather than half of them.
        const tmp = std.fmt.allocPrintSentinel(self.gpa, "{s}.new", .{self.path}, 0) catch return;
        defer self.gpa.free(tmp);
        writeThenRename(self.io, tmp, self.path, out.items) catch {
            if (!self.said_write_failed) self.said_write_failed = true;
            return;
        };
        self.said_write_failed = false;
    }

    fn writeThenRename(io: std.Io, tmp: [:0]const u8, path: [:0]const u8, bytes: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes });
        try cwd.rename(tmp, cwd, path, io);
    }

    // ---- the groups ------------------------------------------------------

    fn groupLocked(self: *Store, name: []const u8) ?*Group {
        for (self.groups.items) |*g| {
            if (std.mem.eql(u8, g.name, name)) return g;
        }
        return null;
    }

    /// The group, made if it is not there. The pointer is good until the next
    /// call that adds one, so a caller holding it across lines holds an index.
    fn addGroupLocked(self: *Store, name: []const u8) !*Group {
        if (self.groupLocked(name)) |g| return g;
        const owned = try self.gpa.dupeZ(u8, name);
        errdefer self.gpa.free(owned);
        try self.groups.append(self.gpa, .{ .name = owned });
        return &self.groups.items[self.groups.items.len - 1];
    }

    fn findLocked(self: *Store, group: []const u8, key: []const u8) ?*Entry {
        const g = self.groupLocked(group) orelse return null;
        for (g.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }

    /// Store one already-escaped value.
    fn putLocked(self: *Store, g: *Group, key: []const u8, value: []const u8, kind: Kind) !void {
        const owned = try self.gpa.dupeZ(u8, value);
        errdefer self.gpa.free(owned);
        try self.replaceLocked(g, key, owned, kind, &.{});
    }

    /// Store an already-owned list under `key`.
    fn putListLocked(self: *Store, g: *Group, key: []const u8, items: [][:0]u8) !void {
        const empty = try self.gpa.dupeZ(u8, "");
        errdefer self.gpa.free(empty);
        try self.replaceLocked(g, key, empty, .list, items);
    }

    /// Put an owned value and its items in place, freeing whatever was there.
    fn replaceLocked(self: *Store, g: *Group, key: []const u8, value: [:0]u8, kind: Kind, items: [][:0]u8) !void {
        for (g.entries.items) |*e| {
            if (!std.mem.eql(u8, e.key, key)) continue;
            self.gpa.free(e.value);
            for (e.items) |item| self.gpa.free(item);
            self.gpa.free(e.items);
            e.value = value;
            e.kind = kind;
            e.items = items;
            return;
        }
        const k = try self.gpa.dupeZ(u8, key);
        errdefer self.gpa.free(k);
        try g.entries.append(self.gpa, .{ .key = k, .value = value, .kind = kind, .items = items });
    }

    /// Store a scalar and start the coalesce window.
    fn setLocked(self: *Store, group: []const u8, key: []const u8, value: []const u8, kind: Kind) void {
        self.mu.lock();
        defer self.mu.unlock();
        const g = self.addGroupLocked(group) catch return;
        self.putLocked(g, key, value, kind) catch return;
        self.markDirtyLocked();
    }

    /// The file: one object of groups, each an object of keys. Indented, so a
    /// mariner reporting a problem can read the file they are asked for.
    fn writeJson(self: *Store, out: *std.ArrayList(u8)) !void {
        const a = self.gpa;
        try out.appendSlice(a, "{\n");
        var first_group = true;
        for (self.groups.items) |g| {
            if (g.entries.items.len == 0) continue;
            if (!first_group) try out.appendSlice(a, ",\n");
            first_group = false;
            try out.appendSlice(a, "  ");
            try jsonString(a, out, g.name);
            try out.appendSlice(a, ": {\n");
            for (g.entries.items, 0..) |e, i| {
                if (i > 0) try out.appendSlice(a, ",\n");
                try out.appendSlice(a, "    ");
                try jsonString(a, out, e.key);
                try out.appendSlice(a, ": ");
                try self.writeValue(out, e);
            }
            try out.appendSlice(a, "\n  }");
        }
        try out.appendSlice(a, "\n}\n");
    }

    fn writeValue(self: *Store, out: *std.ArrayList(u8), e: Entry) !void {
        const a = self.gpa;
        switch (e.kind) {
            .flag => try out.appendSlice(a, if (std.mem.eql(u8, e.value, "true")) "true" else "false"),
            .number => {
                // A value that is not finite has no JSON number, so it goes
                // over as the text it is and reads back on the fallback.
                const n = std.fmt.parseFloat(f64, e.value) catch {
                    try jsonString(a, out, e.value);
                    return;
                };
                if (!std.math.isFinite(n)) {
                    try jsonString(a, out, e.value);
                    return;
                }
                try out.appendSlice(a, e.value);
            },
            .list => {
                try out.appendSlice(a, "[");
                for (e.items, 0..) |item, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try jsonString(a, out, item);
                }
                try out.appendSlice(a, "]");
            },
            .text => try jsonString(a, out, e.value),
        }
    }

    /// A write invalidates every borrowed read, so the read arena goes back
    /// with it.
    fn markDirtyLocked(self: *Store) void {
        _ = self.reads.reset(.retain_capacity);
        const now = clock.wallMs();
        if (self.dirty_at) |since| {
            if (now - since >= coalesce_ms) self.flushLocked();
            return;
        }
        self.dirty_at = now;
    }
};

// ---- the ini's escapes ---------------------------------------------------------

/// Escape into `out`. A list item also escapes the separator, so a path with a
/// semicolon in it is one item and not two.
/// One JSON string. A local copy, like the four other writers in this repo:
/// this module is rooted on its own so its tests can run without the engine.
fn jsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            try out.appendSlice(alloc, "\\u00");
            try out.append(alloc, hex[(c >> 4) & 0xf]);
            try out.append(alloc, hex[c & 0xf]);
        } else try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

/// A slice of slices as a slice of pointers. A `[:0]const u8` is a slice of
/// its own, so a cast would hand C an array of the wrong stride.
fn asPtrs(a: std.mem.Allocator, items: []const [:0]const u8) []const [*:0]const u8 {
    const out = a.alloc([*:0]const u8, items.len) catch return &.{};
    for (items, out) |s, *dst| dst.* = s.ptr;
    return out;
}

// ---- tests ---------------------------------------------------------------------

const t = std.testing;

/// A store in a temp directory of its own.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),

    fn init() !Fixture {
        const tmp = std.testing.tmpDir(.{});
        const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        return .{ .tmp = tmp, .dir = dir };
    }

    fn deinit(self: *Fixture) void {
        t.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn open(self: *Fixture) !*Store {
        return Store.open(t.allocator, self.io, self.dir);
    }

    /// The file as it stands on disk.
    fn read(self: *Fixture) ![]u8 {
        return self.tmp.dir.readFileAlloc(self.io, file_name, t.allocator, .limited(1 << 20));
    }

    fn write(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(self.io, .{ .sub_path = name, .data = bytes });
    }
};

test "a store keeps what it was told, across a close and an open" {
    var f = try Fixture.init();
    defer f.deinit();

    {
        const s = try f.open();
        defer s.close();
        s.setNumber(group_view, "lon", -76.4767);
        s.setNumber(group_view, "lat", 38.9763);
        s.setNumber(group_view, "zoom", 15);
        s.setFlag(group_raster, "chart_hidden", true);
        s.setText(group_chartlinks, "active", "https://h/style.json");
        s.setList(group_recents, "paths", &.{ "/a/one", "/b/two" });
    }

    const s = try f.open();
    defer s.close();
    try t.expectEqual(@as(f64, -76.4767), s.number(group_view, "lon", 0));
    try t.expectEqual(@as(f64, 38.9763), s.number(group_view, "lat", 0));
    // An integral number writes as an integer, so a shell reading it as one
    // still can.
    try t.expectEqual(@as(f64, 15), s.number(group_view, "zoom", 0));
    try t.expect(s.flag(group_raster, "chart_hidden", false));
    try t.expectEqualStrings("https://h/style.json", s.text(group_chartlinks, "active").?);
    const paths = s.list(group_recents, "paths");
    try t.expectEqual(@as(usize, 2), paths.len);
    try t.expectEqualStrings("/a/one", paths[0]);
    try t.expectEqualStrings("/b/two", paths[1]);
}

test "an unset key answers with the fallback" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    try t.expect(!s.has(group_view, "lon"));
    try t.expectEqual(@as(f64, 42), s.number(group_view, "lon", 42));
    try t.expect(s.flag(group_view, "follow", true));
    try t.expect(s.text(group_view, "lon") == null);
    try t.expectEqual(@as(usize, 0), s.list(group_recents, "paths").len);
    try t.expectEqual(@as(usize, 0), s.keys(group_plugins).len);
}

test "the file is JSON, a group to an object" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    s.setNumber(group_view, "zoom", 15);
    s.setText(group_chartlinks, "active", "https://h/style.json");
    s.flush();

    const text = try f.read();
    defer t.allocator.free(text);
    try t.expectEqualStrings(
        \\{
        \\  "view": {
        \\    "zoom": 15
        \\  },
        \\  "chartlinks": {
        \\    "active": "https://h/style.json"
        \\  }
        \\}
        \\
    , text);
}

test "a value keeps the type it was written with" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    s.setNumber(group_view, "zoom", 15.5);
    s.setFlag(group_raster, "chart_hidden", true);
    s.setText(group_mariner, "date_view", "20260901");
    s.setList(group_recents, "paths", &.{ "/a", "/b" });
    s.flush();

    const text = try f.read();
    defer t.allocator.free(text);
    // A number is a number and a flag is a flag, so the file reads as what it
    // holds rather than as strings of it.
    try t.expect(std.mem.indexOf(u8, text, "\"zoom\": 15.5") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"chart_hidden\": true") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"paths\": [\"/a\", \"/b\"]") != null);
    // A date is text the mariner typed, and stays text.
    try t.expect(std.mem.indexOf(u8, text, "\"date_view\": \"20260901\"") != null);
}

test "a value with a newline or a separator in it comes back whole" {
    var f = try Fixture.init();
    defer f.deinit();

    {
        const s = try f.open();
        defer s.close();
        s.setText(group_plugins, "org.example", "{\"note\":\"line\nbreak\"}");
        // And a value that holds a BACKSLASH, which the escape must not eat.
        s.setText(group_plugins, "org.other", "C:\\charts\\enc");
        // A path holding the list separator stays one item.
        s.setList(group_chartsets, "paths", &.{ "/a;b/charts", "/c\td" });
    }

    const s = try f.open();
    defer s.close();
    try t.expectEqualStrings("{\"note\":\"line\nbreak\"}", s.text(group_plugins, "org.example").?);
    try t.expectEqualStrings("C:\\charts\\enc", s.text(group_plugins, "org.other").?);
    const paths = s.list(group_chartsets, "paths");
    try t.expectEqual(@as(usize, 2), paths.len);
    try t.expectEqualStrings("/a;b/charts", paths[0]);
    try t.expectEqualStrings("/c\td", paths[1]);
}

test "an empty list clears the key, which is what an empty list means" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    s.setList(group_chartsets, "paths", &.{"/a"});
    try t.expect(s.has(group_chartsets, "paths"));
    s.setList(group_chartsets, "paths", &.{});
    try t.expect(!s.has(group_chartsets, "paths"));
    try t.expectEqual(@as(usize, 0), s.list(group_chartsets, "paths").len);
}

test "the keys of a group come back in the order they were written" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    s.setText(group_plugins, "org.beetlebug.ais", "{}");
    s.setText(group_plugins, "org.beetlebug.nmea0183", "{}");
    s.setText(group_plugins, "org.beetlebug.ownship", "{}");
    const ids = s.keys(group_plugins);
    try t.expectEqual(@as(usize, 3), ids.len);
    try t.expectEqualStrings("org.beetlebug.ais", ids[0]);
    try t.expectEqualStrings("org.beetlebug.nmea0183", ids[1]);
    try t.expectEqualStrings("org.beetlebug.ownship", ids[2]);
}

test "setting a key twice replaces it rather than writing it twice" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    s.setText(group_chartlinks, "active", "https://a/style.json");
    s.setText(group_chartlinks, "active", "https://b/style.json");
    s.flush();

    const text = try f.read();
    defer t.allocator.free(text);
    try t.expectEqualStrings(
        \\{
        \\  "chartlinks": {
        \\    "active": "https://b/style.json"
        \\  }
        \\}
        \\
    , text);
}

test "removing the last key of a group leaves the group out of the file" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    s.setNumber(group_view, "zoom", 15);
    s.setText(group_chartlinks, "active", "https://h/style.json");
    s.remove(group_chartlinks, "active");
    s.flush();

    const text = try f.read();
    defer t.allocator.free(text);
    try t.expectEqualStrings(
        \\{
        \\  "view": {
        \\    "zoom": 15
        \\  }
        \\}
        \\
    , text);
}

test "a file that will not parse is set aside and the store starts empty" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(file_name, "this is not a settings file at all\n");

    {
        const s = try f.open();
        defer s.close();
        try t.expectEqual(@as(usize, 0), s.keys(group_view).len);
        // The next write replaces the live file.
        s.setNumber(group_view, "zoom", 15);
    }

    const broken = try f.tmp.dir.readFileAlloc(f.io, file_name ++ ".broken", t.allocator, .limited(1 << 20));
    defer t.allocator.free(broken);
    try t.expectEqualStrings("this is not a settings file at all\n", broken);

    const text = try f.read();
    defer t.allocator.free(text);
    try t.expectEqualStrings(
        \\{
        \\  "view": {
        \\    "zoom": 15
        \\  }
        \\}
        \\
    , text);
}

test "a store with nothing written leaves no file" {
    var f = try Fixture.init();
    defer f.deinit();
    {
        const s = try f.open();
        defer s.close();
        _ = s.number(group_view, "zoom", 15);
    }
    try t.expectError(error.FileNotFound, f.read());
}

test "a flag reads the words and the digits, and nothing else" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(file_name,
        \\{"raster": {
        \\  "a": true, "b": false,
        \\  "c": 1, "d": 0,
        \\  "e": "yes"
        \\}}
        \\
    );
    const s = try f.open();
    defer s.close();
    try t.expect(s.flag(group_raster, "a", false));
    try t.expect(!s.flag(group_raster, "b", true));
    try t.expect(s.flag(group_raster, "c", false));
    try t.expect(!s.flag(group_raster, "d", true));
    // A word the file has no meaning for leaves the caller's default alone.
    try t.expect(s.flag(group_raster, "e", true));
    try t.expect(!s.flag(group_raster, "e", false));
}

test "the pointer forms the C ABI hands over say the same thing" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    s.setList(group_recents, "paths", &.{ "/a/one", "/b;two" });
    s.setText(group_plugins, "org.beetlebug.ais", "{}");
    s.setText(group_plugins, "org.beetlebug.ownship", "{}");

    // A slice is not a pointer, so the C side gets its own array rather than
    // a cast of the slices.
    const paths = s.listPtrs(group_recents, "paths");
    try t.expectEqual(@as(usize, 2), paths.len);
    try t.expectEqualStrings("/a/one", std.mem.span(paths[0]));
    try t.expectEqualStrings("/b;two", std.mem.span(paths[1]));

    const ids = s.keyPtrs(group_plugins);
    try t.expectEqual(@as(usize, 2), ids.len);
    try t.expectEqualStrings("org.beetlebug.ais", std.mem.span(ids[0]));
    try t.expectEqualStrings("org.beetlebug.ownship", std.mem.span(ids[1]));

    try t.expectEqual(@as(usize, 0), s.listPtrs(group_recents, "nonesuch").len);
    try t.expectEqual(@as(usize, 0), s.keyPtrs("nonesuch").len);
}

test "a write coalesces, and the file lands at the flush" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    s.setNumber(group_view, "zoom", 15);
    // Nothing on disk yet: the write is waiting.
    try t.expectError(error.FileNotFound, f.read());

    s.flush();
    const text = try f.read();
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"zoom\": 15") != null);

    // A flush with nothing waiting does not rewrite the file.
    s.flush();
}

test "a store written once still reaches the disk" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();

    s.setNumber(group_view, "zoom", 15);
    // Nothing else is written, so without a tick the change waits forever.
    try t.expectError(error.FileNotFound, f.read());
    s.tick();
    // The window has not passed yet.
    try t.expectError(error.FileNotFound, f.read());

    // Once it has, the tick lands it.
    s.mu.lock();
    s.dirty_at = clock.wallMs() - coalesce_ms - 1;
    s.mu.unlock();
    s.tick();
    const text = try f.read();
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"zoom\": 15") != null);

    // And a tick with nothing waiting does nothing.
    s.tick();
}
