//! The mariner's own marks on the water: a rock they were told about, a crab
//! pot, an anchorage to come back to. Not a route and not a waypoint in a
//! navigation sense: that is a bigger feature and this is not it.
//!
//! The rules this file carries:
//!
//!   1. THE DROP NEVER WAITS FOR TYPING. `add` places a marker and names it in
//!      the same call, so a shell can drop one with a single tap on a moving
//!      boat and never hold a dialog open over the chart.
//!   2. Every marker is born named. "Mark 1", "Mark 2", counting up from the
//!      highest number IN USE, so two marks are never called the same thing
//!      and a mariner who never renames one still has something to say on the
//!      radio.
//!   3. They survive a restart, and they belong to the boat rather than to the
//!      chart that happened to be open, so the file lives beside the mariner's
//!      other per-user state and not beside a cell.
//!
//! No wall clock is read here: the caller injects `now_ms`, so the host and
//! the tests see the same behaviour.
//!
//! LOCKING. None. Every entry point into this store runs under the C ABI's
//! own lock (see capi.zig), which is the same lock the render thread holds
//! while it draws, so the list is never read and written at once.

const std = @import("std");
const builtin = @import("builtin");

/// The longest name a marker carries, in characters. A name, not a note: it
/// has to fit beside the mark on the chart and be readable over the radio.
pub const max_name_chars = 32;

/// A cap on the file, so a corrupt or hostile markers.json cannot be read into
/// memory unbounded.
const max_file_bytes = 1 << 20;

/// A cap on how many marks one boat carries. Well past any real use; it is
/// here so a runaway shell cannot grow the file without limit.
pub const max_markers = 4096;

pub const Marker = struct {
    /// Stable for the marker's life and never reused within a run. What a
    /// shell holds while it renames one.
    id: u64,
    lon: f64,
    lat: f64,
    /// Owned by the store, NUL-terminated so a C shell can borrow it whole.
    /// Never empty.
    name: [:0]u8,
    /// When it was dropped, Unix epoch milliseconds.
    dropped_ms: i64,
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(Marker) = .empty,
    next_id: u64 = 1,
    /// Where load and save go. Null keeps the store in memory only, which is
    /// what a test and a platform with no per-user directory get.
    path: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator) Store {
        return .{ .alloc = alloc };
    }

    /// Adopt a file and read whatever is in it. A file that will not parse is
    /// ignored rather than fatal: a mariner losing their marks is bad, and
    /// refusing to open the chart over it is worse.
    pub fn open(alloc: std.mem.Allocator, path: []const u8) Store {
        var s = Store{ .alloc = alloc };
        s.path = alloc.dupe(u8, path) catch null;
        s.load();
        return s;
    }

    pub fn deinit(self: *Store) void {
        for (self.list.items) |m| self.alloc.free(m.name);
        self.list.deinit(self.alloc);
        if (self.path) |p| self.alloc.free(p);
        self.* = undefined;
    }

    pub fn items(self: *const Store) []const Marker {
        return self.list.items;
    }

    pub fn find(self: *const Store, id: u64) ?*const Marker {
        for (self.list.items) |*m| if (m.id == id) return m;
        return null;
    }

    /// Drop a marker, named at once (rule 1). Returns its id, or 0 when the
    /// store is full or out of memory. A shell shows the marker it got back
    /// and has nothing to undo when it got none.
    pub fn add(self: *Store, lon: f64, lat: f64, now_ms: i64) u64 {
        if (self.list.items.len >= max_markers) return 0;
        var buf: [16]u8 = undefined;
        const name = self.alloc.dupeZ(u8, self.nextName(&buf)) catch return 0;
        errdefer self.alloc.free(name);
        const id = self.next_id;
        self.list.append(self.alloc, .{
            .id = id,
            .lon = lon,
            .lat = lat,
            .name = name,
            .dropped_ms = now_ms,
        }) catch {
            self.alloc.free(name);
            return 0;
        };
        self.next_id += 1;
        self.save();
        return id;
    }

    /// Rename one marker. An empty or whitespace-only name keeps the old one:
    /// a field the mariner cleared and left is not a request for a nameless
    /// mark. True when the id exists, whatever the name did.
    pub fn rename(self: *Store, id: u64, name: []const u8) bool {
        for (self.list.items) |*m| {
            if (m.id != id) continue;
            const want = clipName(std.mem.trim(u8, name, " \t\r\n"));
            if (want.len == 0) return true;
            const owned = self.alloc.dupeZ(u8, want) catch return true;
            self.alloc.free(m.name);
            m.name = owned;
            self.save();
            return true;
        }
        return false;
    }

    pub fn remove(self: *Store, id: u64) bool {
        for (self.list.items, 0..) |m, i| {
            if (m.id != id) continue;
            self.alloc.free(m.name);
            _ = self.list.orderedRemove(i);
            self.save();
            return true;
        }
        return false;
    }

    /// The next "Mark N": one past the highest number any name in use carries,
    /// so a rename to "Mark 7" pushes the next drop to "Mark 8" rather than
    /// handing out a name already on the chart (rule 2). Written into `buf`,
    /// which needs 16 bytes.
    pub fn nextName(self: *const Store, buf: []u8) []const u8 {
        var high: u64 = 0;
        for (self.list.items) |m| {
            const n = markNumber(m.name) orelse continue;
            if (n > high) high = n;
        }
        return std.fmt.bufPrint(buf, "Mark {d}", .{high + 1}) catch "Mark";
    }

    // ---- persistence ---------------------------------------------------------

    /// Read the file, replacing whatever is held. Best effort throughout: an
    /// unreadable or malformed file leaves an empty store.
    pub fn load(self: *Store) void {
        const path = self.path orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(max_file_bytes)) catch return;
        defer self.alloc.free(text);
        self.parse(text);
    }

    fn parse(self: *Store, text: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, text, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const arr = parsed.value.object.get("markers") orelse return;
        if (arr != .array) return;

        for (self.list.items) |m| self.alloc.free(m.name);
        self.list.clearRetainingCapacity();
        self.next_id = 1;

        for (arr.array.items) |it| {
            if (self.list.items.len >= max_markers) break;
            if (it != .object) continue;
            const o = it.object;
            const lon = jnum(o.get("lon")) orelse continue;
            const lat = jnum(o.get("lat")) orelse continue;
            if (!std.math.isFinite(lon) or !std.math.isFinite(lat)) continue;
            const id: u64 = @intFromFloat(@max(0, jnum(o.get("id")) orelse 0));
            const raw = if (o.get("name")) |n| (if (n == .string) n.string else "") else "";
            var buf: [16]u8 = undefined;
            const want = clipName(std.mem.trim(u8, raw, " \t\r\n"));
            const name = self.alloc.dupeZ(u8, if (want.len > 0) want else self.nextName(&buf)) catch continue;
            self.list.append(self.alloc, .{
                .id = if (id > 0) id else self.next_id,
                .lon = lon,
                .lat = lat,
                .name = name,
                .dropped_ms = @intFromFloat(jnum(o.get("dropped_ms")) orelse 0),
            }) catch {
                self.alloc.free(name);
                continue;
            };
            const used = self.list.items[self.list.items.len - 1].id;
            if (used >= self.next_id) self.next_id = used + 1;
        }
    }

    /// Write the file. Through a temporary and a rename, so a machine that
    /// loses power mid-write keeps the marks it had rather than a half file.
    pub fn save(self: *Store) void {
        const path = self.path orelse return;
        var text = std.ArrayList(u8).empty;
        defer text.deinit(self.alloc);
        self.write(&text) catch return;

        const io = std.Io.Threaded.global_single_threaded.io();
        const dir = std.fs.path.dirname(path) orelse ".";
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const tmp = std.fmt.allocPrint(self.alloc, "{s}.tmp", .{path}) catch return;
        defer self.alloc.free(tmp);
        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(io, .{ .sub_path = tmp, .data = text.items }) catch return;
        cwd.rename(tmp, cwd, path, io) catch {
            cwd.deleteFile(io, tmp) catch {};
        };
    }

    fn write(self: *const Store, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(self.alloc, "{\"markers\":[");
        for (self.list.items, 0..) |m, i| {
            if (i > 0) try out.append(self.alloc, ',');
            try out.print(self.alloc, "{{\"id\":{d},\"lon\":{d},\"lat\":{d},\"dropped_ms\":{d},\"name\":", .{
                m.id, m.lon, m.lat, m.dropped_ms,
            });
            try jsonString(self.alloc, out, m.name);
            try out.append(self.alloc, '}');
        }
        try out.appendSlice(self.alloc, "]}\n");
    }
};

/// The number in "Mark 7", or null for any other name. Trailing text disqualifies
/// it: "Mark 7 buoy" is a name the mariner typed, not a generated one.
fn markNumber(name: []const u8) ?u64 {
    const prefix = "Mark ";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const digits = name[prefix.len..];
    if (digits.len == 0 or digits.len > 19) return null;
    for (digits) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

/// The first `max_name_chars` characters, cut on a UTF-8 boundary so a clipped
/// name is still text.
pub fn clipName(name: []const u8) []const u8 {
    var chars: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        const len = std.unicode.utf8ByteSequenceLength(name[i]) catch 1;
        if (i + len > name.len) break;
        if (chars == max_name_chars) return name[0..i];
        chars += 1;
        i += len;
    }
    return name[0..i];
}

fn jnum(v: ?std.json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// One JSON string literal, escaped. Control bytes go out as \u00xx. Public
/// because the core writes marker names into the overlay batch it posts, and
/// one escaper for both is one behaviour to get right.
pub fn jsonString(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
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

/// The per-user directory the marks live in: beside the plugin install root,
/// because both are the mariner's own state and neither belongs to a chart.
/// Null on a platform that names no place in the environment.
pub fn supportDirAlloc(alloc: std.mem.Allocator) ?[]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const appdata = std.mem.span(std.c.getenv("APPDATA") orelse return null);
            if (appdata.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}\\Lookout Marine", .{appdata}) catch null;
        },
        .macos, .ios => {
            const home = std.mem.span(std.c.getenv("HOME") orelse return null);
            if (home.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}/Library/Application Support/Lookout Marine", .{home}) catch null;
        },
        .linux => {
            if (std.c.getenv("XDG_DATA_HOME")) |x| {
                const s = std.mem.span(x);
                if (s.len > 0) return std.fmt.allocPrint(alloc, "{s}/lookout-marine", .{s}) catch null;
            }
            const home = std.mem.span(std.c.getenv("HOME") orelse return null);
            if (home.len == 0) return null;
            return std.fmt.allocPrint(alloc, "{s}/.local/share/lookout-marine", .{home}) catch null;
        },
        else => return null,
    }
}

/// `<support dir>/markers.json`, or null where there is no such directory.
pub fn defaultPathAlloc(alloc: std.mem.Allocator) ?[]u8 {
    const dir = supportDirAlloc(alloc) orelse return null;
    defer alloc.free(dir);
    return std.fmt.allocPrint(alloc, "{s}/markers.json", .{dir}) catch null;
}

// -- tests ---------------------------------------------------------------------

const t = std.testing;

/// markers.json inside a test temp directory, as the store takes it.
fn tmpPath(tmp: *t.TmpDir) ![]u8 {
    return std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/markers.json", .{tmp.sub_path});
}

test "a drop is named at once, counting up" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    const a = s.add(-76.4767, 38.9763, 1_000);
    const b = s.add(-76.4700, 38.9800, 2_000);
    try t.expect(a != 0 and b != 0 and a != b);
    try t.expectEqualStrings("Mark 1", s.find(a).?.name);
    try t.expectEqualStrings("Mark 2", s.find(b).?.name);
    try t.expectEqual(@as(i64, 1_000), s.find(a).?.dropped_ms);
}

test "the numbering never hands out a name already in use" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    _ = s.add(-76.4, 38.9, 0); // Mark 1
    const b = s.add(-76.4, 38.9, 0); // Mark 2
    // A rename up the range: the next drop clears it rather than colliding.
    try t.expect(s.rename(b, "Mark 7"));
    const c = s.add(-76.4, 38.9, 0);
    try t.expectEqualStrings("Mark 8", s.find(c).?.name);

    // Removing the highest frees the number again, and nothing in use repeats.
    try t.expect(s.remove(c));
    const d = s.add(-76.4, 38.9, 0);
    try t.expectEqualStrings("Mark 8", s.find(d).?.name);

    var seen = std.StringHashMap(void).init(t.allocator);
    defer seen.deinit();
    for (s.items()) |m| {
        try t.expect(!seen.contains(m.name));
        try seen.put(m.name, {});
    }

    // A mariner's own name is not a generated one, so it never moves the count.
    const e = s.add(-76.4, 38.9, 0); // Mark 9
    try t.expect(s.rename(e, "Mark 40 crab pot"));
    const f = s.add(-76.4, 38.9, 0);
    try t.expectEqualStrings("Mark 9", s.find(f).?.name);
}

test "a rename holds, and an empty field keeps the old name" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    const id = s.add(-76.4, 38.9, 0);
    try t.expect(s.rename(id, "  Crab pot  "));
    try t.expectEqualStrings("Crab pot", s.find(id).?.name);
    try t.expect(s.rename(id, "   "));
    try t.expectEqualStrings("Crab pot", s.find(id).?.name);
    try t.expect(s.rename(id, ""));
    try t.expectEqualStrings("Crab pot", s.find(id).?.name);
    try t.expect(!s.rename(id + 999, "nobody"));
}

test "a name is cut to 32 characters on a character boundary" {
    try t.expectEqual(@as(usize, 32), clipName("a" ** 40).len);
    try t.expectEqualStrings("a" ** 32, clipName("a" ** 40));
    // Thirty-three three-byte characters clip to thirty-two whole ones.
    const wide = "\u{00e5}" ** 33;
    try t.expectEqual(@as(usize, 64), clipName(wide).len);
    try t.expect(std.unicode.utf8ValidateSlice(clipName(wide)));

    var s = Store.init(t.allocator);
    defer s.deinit();
    const id = s.add(-76.4, 38.9, 0);
    try t.expect(s.rename(id, "b" ** 100));
    try t.expectEqual(@as(usize, 32), s.find(id).?.name.len);
}

test "markers survive a restart, with their names and their ids" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer t.allocator.free(path);

    var kept_id: u64 = 0;
    {
        var s = Store.open(t.allocator, path);
        defer s.deinit();
        _ = s.add(-76.4767, 38.9763, 1_700_000_000_000);
        kept_id = s.add(-76.4700, 38.9800, 1_700_000_001_000);
        try t.expect(s.rename(kept_id, "Crab pot"));
    }
    {
        var s = Store.open(t.allocator, path);
        defer s.deinit();
        try t.expectEqual(@as(usize, 2), s.items().len);
        try t.expectEqualStrings("Mark 1", s.items()[0].name);
        try t.expectEqualStrings("Crab pot", s.items()[1].name);
        try t.expectApproxEqAbs(@as(f64, -76.4700), s.find(kept_id).?.lon, 1e-9);
        try t.expectApproxEqAbs(@as(f64, 38.9800), s.find(kept_id).?.lat, 1e-9);
        try t.expectEqual(@as(i64, 1_700_000_001_000), s.find(kept_id).?.dropped_ms);
        // An id is never reused across a restart either.
        const fresh = s.add(-76.5, 38.9, 0);
        try t.expect(fresh > kept_id);
        try t.expectEqualStrings("Mark 2", s.find(fresh).?.name);
    }
    {
        // And the removal is written through too.
        var s = Store.open(t.allocator, path);
        defer s.deinit();
        try t.expect(s.remove(kept_id));
    }
    {
        var s = Store.open(t.allocator, path);
        defer s.deinit();
        try t.expectEqual(@as(usize, 2), s.items().len);
        try t.expect(s.find(kept_id) == null);
    }
}

test "a corrupt file leaves an empty store instead of failing the open" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "markers.json", .data = "{\"markers\":[{\"lon\":" });
    const path = try tmpPath(&tmp);
    defer t.allocator.free(path);

    var s = Store.open(t.allocator, path);
    defer s.deinit();
    try t.expectEqual(@as(usize, 0), s.items().len);
    try t.expect(s.add(-76.4, 38.9, 0) != 0); // and it still takes a drop
}

test "a name with quotes and newlines round trips" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpPath(&tmp);
    defer t.allocator.free(path);
    {
        var s = Store.open(t.allocator, path);
        defer s.deinit();
        const id = s.add(-76.4, 38.9, 0);
        try t.expect(s.rename(id, "the \"rock\"\tSam named"));
    }
    var s = Store.open(t.allocator, path);
    defer s.deinit();
    try t.expectEqualStrings("the \"rock\"\tSam named", s.items()[0].name);
}
