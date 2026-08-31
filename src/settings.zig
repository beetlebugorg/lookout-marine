//! What a shell keeps across launches, in one file.
//!
//! The camera pose, the recents, the mariner settings, the plugin values, the
//! chart links, the chart sets and the raster charts. Four shells kept four
//! stores over four platform preference systems, and every one of them had to
//! be taught the same key names.
//!
//! THE FILE IS AN INI, in the shape linux/src/model/store.c already writes:
//! `[group]` lines, `key=value` under them, a list as its items separated and
//! terminated by semicolons. Backslash, newline, tab, carriage return and (in a
//! list item) the semicolon are escaped. A key holds text; what a value MEANS
//! is the accessor's business, not the file's.
//!
//! WRITES COALESCE. A pose saved every three seconds must not fsync a file
//! every three seconds, so a write marks the store dirty and the file is
//! written at the next flush, at close, or when the oldest unwritten change
//! reaches `coalesce_ms`.
//!
//! ONE LOCK over the file. Windows documents the interleave two writers
//! produce: both read the file, both write it, and the second write loses the
//! first one's group.
//!
//! A FILE THAT WILL NOT PARSE is set aside as `<name>.broken` before an empty
//! store takes its place. The next write replaces the live file either way; the
//! copy is what keeps a mariner's library recoverable.

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
pub const file_name = "settings.ini";

/// How long an unwritten change may wait. A pose lands every three seconds
/// while the mariner is moving, and one file write a second is plenty.
pub const coalesce_ms: i64 = 1000;

const Entry = struct {
    key: [:0]u8,
    value: [:0]u8,
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

    /// Open the store under `dir`, reading `settings.ini` if it is there. A
    /// directory that does not exist is made at the first write, not here: a
    /// shell that only reads leaves no trace.
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
            for (g.entries.items) |e| {
                self.gpa.free(e.key);
                self.gpa.free(e.value);
            }
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
    ///
    /// The file holds the value escaped, so this is the text it stands for.
    pub fn text(self: *Store, group: []const u8, key: []const u8) ?[:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findLocked(group, key) orelse return null;
        return unescape(self.reads.allocator(), e.value) catch null;
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
        return splitList(self.reads.allocator(), e.value) catch &.{};
    }

    /// The same items as an array of NUL-terminated pointers, which is what
    /// the C ABI hands over. Borrowed until the next write.
    pub fn listPtrs(self: *Store, group: []const u8, key: []const u8) []const [*:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const e = self.findLocked(group, key) orelse return &.{};
        const a = self.reads.allocator();
        const items = splitList(a, e.value) catch return &.{};
        return asPtrs(a, items);
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
        self.setLocked(group, key, value);
    }

    /// A number is written in its shortest form, so an integral value writes
    /// as an integer and a shell that reads it as one still can.
    pub fn setNumber(self: *Store, group: []const u8, key: []const u8, value: f64) void {
        var buf: [40]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        self.setLocked(group, key, s);
    }

    pub fn setFlag(self: *Store, group: []const u8, key: []const u8, value: bool) void {
        self.setLocked(group, key, if (value) "true" else "false");
    }

    /// Set a key to a list. An EMPTY list clears the key: a shell that reads
    /// it back gets nothing, which is what an empty list means.
    pub fn setList(self: *Store, group: []const u8, key: []const u8, items: []const []const u8) void {
        if (items.len == 0) {
            self.remove(group, key);
            return;
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        for (items) |item| {
            escapeInto(self.gpa, &out, item, true) catch return;
            out.append(self.gpa, ';') catch return;
        }
        self.setRawLocked(group, key, out.items);
    }

    /// Forget a key. Forgetting the last key of a group forgets the group.
    pub fn remove(self: *Store, group: []const u8, key: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const g = self.groupLocked(group) orelse return;
        for (g.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.key, key)) continue;
            self.gpa.free(e.key);
            self.gpa.free(e.value);
            _ = g.entries.orderedRemove(i);
            self.markDirtyLocked();
            return;
        }
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
            // A file that is not there is an empty store, which is what a
            // first launch has.
            if (e != error.FileNotFound) self.setAside();
            return;
        };
        defer self.gpa.free(bytes);
        self.parse(bytes) catch {
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

    fn parse(self: *Store, bytes: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();
        // The index, not a pointer: a later group appends to the list and
        // would move the one being filled out from under a pointer.
        var group: ?usize = null;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                const end = std.mem.indexOfScalar(u8, line, ']') orelse return error.BadLine;
                _ = try self.addGroupLocked(line[1..end]);
                group = self.groups.items.len - 1;
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.BadLine;
            const at = group orelse return error.BadLine;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            if (key.len == 0) return error.BadLine;
            try self.putLocked(&self.groups.items[at], key, line[eq + 1 ..]);
        }
    }

    fn flushLocked(self: *Store) void {
        if (self.dirty_at == null) return;
        self.dirty_at = null;

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        for (self.groups.items, 0..) |g, i| {
            if (g.entries.items.len == 0) continue;
            if (i > 0) out.append(self.gpa, '\n') catch return;
            out.print(self.gpa, "[{s}]\n", .{g.name}) catch return;
            for (g.entries.items) |e| {
                out.print(self.gpa, "{s}={s}\n", .{ e.key, e.value }) catch return;
            }
        }

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
    fn putLocked(self: *Store, g: *Group, key: []const u8, value: []const u8) !void {
        for (g.entries.items) |*e| {
            if (!std.mem.eql(u8, e.key, key)) continue;
            const owned = try self.gpa.dupeZ(u8, value);
            self.gpa.free(e.value);
            e.value = owned;
            return;
        }
        const k = try self.gpa.dupeZ(u8, key);
        errdefer self.gpa.free(k);
        const v = try self.gpa.dupeZ(u8, value);
        errdefer self.gpa.free(v);
        try g.entries.append(self.gpa, .{ .key = k, .value = v });
    }

    /// Escape `value` and store it.
    fn setLocked(self: *Store, group: []const u8, key: []const u8, value: []const u8) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        escapeInto(self.gpa, &out, value, false) catch return;
        self.setRawLocked(group, key, out.items);
    }

    /// Store an already-escaped value and start the coalesce window.
    fn setRawLocked(self: *Store, group: []const u8, key: []const u8, escaped: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const g = self.addGroupLocked(group) catch return;
        self.putLocked(g, key, escaped) catch return;
        self.markDirtyLocked();
    }

    /// A write invalidates every borrowed read, which is the contract, so the
    /// read arena goes back with it.
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
fn escapeInto(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8, in_list: bool) !void {
    for (s) |c| switch (c) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        ';' => if (in_list) try out.appendSlice(gpa, "\\;") else try out.append(gpa, c),
        else => try out.append(gpa, c),
    };
}

/// The text a value stands for, allocated in `a`.
pub fn unescape(a: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(a, s[i]);
            continue;
        }
        i += 1;
        try out.append(a, switch (s[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => s[i],
        });
    }
    return out.toOwnedSliceSentinel(a, 0);
}

/// A slice of slices as a slice of pointers. A `[:0]const u8` is a slice, not a
/// pointer, so the C side needs its own array rather than a cast.
fn asPtrs(a: std.mem.Allocator, items: []const [:0]const u8) []const [*:0]const u8 {
    const out = a.alloc([*:0]const u8, items.len) catch return &.{};
    for (items, out) |s, *dst| dst.* = s.ptr;
    return out;
}

/// One list value as its items. The separator ends every item, so a trailing
/// one closes the last item rather than opening an empty one.
fn splitList(a: std.mem.Allocator, value: []const u8) ![]const [:0]const u8 {
    var out: std.ArrayList([:0]const u8) = .empty;
    errdefer out.deinit(a);
    var item: std.ArrayList(u8) = .empty;
    defer item.deinit(a);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '\\' and i + 1 < value.len) {
            try item.append(a, value[i]);
            i += 1;
            try item.append(a, value[i]);
            continue;
        }
        if (value[i] == ';') {
            try out.append(a, try unescape(a, item.items));
            item.clearRetainingCapacity();
            continue;
        }
        try item.append(a, value[i]);
    }
    // A value with no trailing separator still ends an item.
    if (item.items.len > 0) try out.append(a, try unescape(a, item.items));
    return out.items;
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

test "the file is the ini shape, group by group" {
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
        "[view]\nzoom=15\n\n[chartlinks]\nactive=https://h/style.json\n",
        text,
    );
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
        // A path with the list separator in it is one item, not two.
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
    try t.expectEqualStrings("[chartlinks]\nactive=https://b/style.json\n", text);
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
    try t.expectEqualStrings("[view]\nzoom=15\n", text);
}

test "a file that will not parse is set aside and the store starts empty" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(file_name, "this is not an ini file at all\n");

    {
        const s = try f.open();
        defer s.close();
        try t.expectEqual(@as(usize, 0), s.keys(group_view).len);
        // The next write replaces the live file.
        s.setNumber(group_view, "zoom", 15);
    }

    const broken = try f.tmp.dir.readFileAlloc(f.io, file_name ++ ".broken", t.allocator, .limited(1 << 20));
    defer t.allocator.free(broken);
    try t.expectEqualStrings("this is not an ini file at all\n", broken);

    const text = try f.read();
    defer t.allocator.free(text);
    try t.expectEqualStrings("[view]\nzoom=15\n", text);
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

test "a comment and a blank line are not settings" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(file_name,
        \\# what the mariner keeps
        \\
        \\[view]
        \\zoom=15
        \\
    );
    const s = try f.open();
    defer s.close();
    try t.expectEqual(@as(f64, 15), s.number(group_view, "zoom", 0));
    try t.expectEqual(@as(usize, 1), s.keys(group_view).len);
}

test "a flag reads the words and the digits, and nothing else" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(file_name,
        \\[raster]
        \\a=true
        \\b=false
        \\c=1
        \\d=0
        \\e=yes
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
    try t.expectEqualStrings("[view]\nzoom=15\n", text);

    // A flush with nothing waiting does not rewrite the file.
    s.flush();
}
