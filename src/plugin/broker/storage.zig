//! What a plugin keeps between runs: its key-value store, on disk under the
//! platform's data root, and the files the host has granted it.

const std = @import("std");
const builtin = @import("builtin");

const broker = @import("../broker.zig");
const caps = @import("caps.zig");
const registry_json = @import("registry_json.zig");
const testing = @import("testing.zig");

const Kind = caps.Kind;
const Plugin = broker.Plugin;
const Caps = caps.Caps;
const writeJsonString = registry_json.writeJsonString;
const io = std.Io.Threaded.global_single_threaded.io();

/// A key, a value, the keys one plugin may hold and the bytes they may total.
pub const storage_max_key = 128;
pub const storage_max_value = 64 * 1024;
pub const storage_max_keys = 256;
pub const storage_max_total = 1024 * 1024;

/// Open files one plugin may hold, and the most one `file_read` returns.
pub const files_per_plugin = 8;
pub const file_read_max = 1024 * 1024;

const KvEntry = struct { key: []u8, value: []u8 };

/// One plugin's key-value store, in memory and in `<dir>/<id>.json`.
///
/// The file holds base64 values because a value is BYTES: a plugin may store a
/// packed struct or a compressed blob, and JSON has no way to say so. Keys stay
/// literal, which is why they are limited to printable ASCII.
pub const KvStore = struct {
    plugin: u32,
    id: []const u8,
    entries: std.ArrayList(KvEntry) = .empty,
    /// Key and value bytes held, against `storage_max_total`.
    bytes: usize = 0,
    loaded: bool = false,

    pub fn deinit(self: *KvStore, alloc: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            alloc.free(e.key);
            alloc.free(e.value);
        }
        self.entries.deinit(alloc);
        self.* = undefined;
    }

    pub fn get(self: *const KvStore, key: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn put(self: *KvStore, alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        for (self.entries.items, 0..) |*e, i| {
            if (!std.mem.eql(u8, e.key, key)) continue;
            // An empty value is a delete. It saves a `storage_del` import for
            // the one thing a plugin needs it for: forgetting a preference.
            if (value.len == 0) {
                self.bytes -= e.key.len + e.value.len;
                alloc.free(e.key);
                alloc.free(e.value);
                _ = self.entries.orderedRemove(i);
                return;
            }
            if (self.bytes - e.value.len + value.len > storage_max_total) return error.StorageFull;
            const owned = try alloc.dupe(u8, value);
            self.bytes = self.bytes - e.value.len + value.len;
            alloc.free(e.value);
            e.value = owned;
            return;
        }
        if (value.len == 0) return;
        if (self.entries.items.len >= storage_max_keys) return error.TooManyKeys;
        if (self.bytes + key.len + value.len > storage_max_total) return error.StorageFull;
        const k = try alloc.dupe(u8, key);
        errdefer alloc.free(k);
        const v = try alloc.dupe(u8, value);
        errdefer alloc.free(v);
        try self.entries.append(alloc, .{ .key = k, .value = v });
        self.bytes += key.len + value.len;
    }

    fn fileName(self: *const KvStore, buf: []u8) []const u8 {
        // A manifest id is reverse-DNS, but nothing checks that, so anything
        // that could leave the directory becomes an underscore.
        const n = @min(self.id.len, buf.len - 5);
        for (self.id[0..n], 0..) |c, i| buf[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => c,
            else => '_',
        };
        @memcpy(buf[n .. n + 5], ".json");
        return buf[0 .. n + 5];
    }

    pub fn load(self: *KvStore, alloc: std.mem.Allocator, dir: []const u8) !void {
        if (self.loaded) return;
        self.loaded = true;
        var name_buf: [192]u8 = undefined;
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, self.fileName(&name_buf) });
        defer alloc.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(storage_max_total * 2)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer alloc.free(text);

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.BadStorageFile;
        const list = parsed.value.object.get("kv") orelse return;
        if (list != .array) return error.BadStorageFile;
        const dec = std.base64.standard.Decoder;
        for (list.array.items) |item| {
            if (item != .object) continue;
            const key = switch (item.object.get("k") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const b64 = switch (item.object.get("b64") orelse continue) {
                .string => |s| s,
                else => continue,
            };
            const size = dec.calcSizeForSlice(b64) catch continue;
            if (size == 0 or size > storage_max_value) continue;
            const value = try alloc.alloc(u8, size);
            defer alloc.free(value);
            dec.decode(value, b64) catch continue;
            self.put(alloc, key, value) catch continue;
        }
    }

    pub fn save(self: *KvStore, alloc: std.mem.Allocator, dir: []const u8) !void {
        var name_buf: [192]u8 = undefined;
        const name = self.fileName(&name_buf);
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir) catch {};

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, "{\"v\":1,\"kv\":[");
        const enc = std.base64.standard.Encoder;
        var b64: [4 * ((storage_max_value + 2) / 3) + 4]u8 = undefined;
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"k\":");
            try writeJsonString(&out, alloc, e.key);
            try out.appendSlice(alloc, ",\"b64\":\"");
            try out.appendSlice(alloc, enc.encode(&b64, e.value));
            try out.appendSlice(alloc, "\"}");
        }
        try out.appendSlice(alloc, "]}");

        // Written beside the real file and renamed over it, so a power cut
        // during a save loses the change rather than the whole store.
        const tmp = try std.fmt.allocPrint(alloc, "{s}/{s}.tmp", .{ dir, name });
        defer alloc.free(tmp);
        const final = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        defer alloc.free(final);
        try cwd.writeFile(io, .{ .sub_path = tmp, .data = out.items });
        try cwd.rename(tmp, cwd, final, io);
    }
};

/// `<data root>/lookout/plugins`, the platform's own place for data that must
/// survive. Deliberately NOT the cache root `lookout_set_cache_dir` names: a
/// cache is purgeable and a mariner's saved plugin state is not.
pub fn defaultStorageDir(alloc: std.mem.Allocator) ?[]u8 {
    if (comptime builtin.os.tag == .windows) {
        const appdata = std.c.getenv("APPDATA") orelse return null;
        const s = std.mem.span(appdata);
        if (s.len == 0) return null;
        return std.fmt.allocPrint(alloc, "{s}\\lookout\\plugins", .{s}) catch null;
    }
    if (std.c.getenv("XDG_DATA_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return std.fmt.allocPrint(alloc, "{s}/lookout/plugins", .{s}) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    if (home.len == 0) return null;
    return switch (builtin.os.tag) {
        .macos, .ios => std.fmt.allocPrint(alloc, "{s}/Library/Application Support/lookout/plugins", .{home}) catch null,
        else => std.fmt.allocPrint(alloc, "{s}/.local/share/lookout/plugins", .{home}) catch null,
    };
}

/// A storage key is printable ASCII with no quote and no backslash. It goes
/// into a JSON file as itself, and a key that could break that shape is a key
/// nobody could read back.
pub fn printableKey(key: []const u8) bool {
    for (key) |c| {
        if (c < 0x20 or c > 0x7e or c == '"' or c == '\\') return false;
    }
    return true;
}

/// One granted file. There is no `file_open` import: every one of these was
/// handed over by the host on a mariner's behalf.
pub const FileHandle = struct {
    id: i64,
    plugin: u32,
    file: std.Io.File,
    write: bool,
    /// Bytes written so far, so `file_write` appends without a seek.
    written: u64 = 0,
};

pub fn baseName(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[cut + 1 ..];
}

const t = std.testing;
const Fixture = testing.Fixture;
const nextEvent = testing.nextEvent;
const removeScratch = testing.removeScratch;
const scratchDir = testing.scratchDir;
const test_body = testing.test_body;

test "a plugin's storage round-trips, caps what it holds and survives a restart" {
    const a = t.allocator;
    const dir = try scratchDir(a, "storage");
    defer a.free(dir);
    defer removeScratch(dir);

    var value: [64]u8 = undefined;
    {
        const fx = try Fixture.init(a);
        defer fx.deinit(a);
        const b = &fx.br;
        b.setStorageDir(dir);
        var p = Plugin{ .broker = b, .index = 0, .id = "org.beetlebug.grib", .source = 1, .caps = Caps.initEmpty() };
        try b.registerPlugin(&p);

        // Absent is -1, not zero: a key that was never written and a key
        // written empty must not read the same.
        try t.expectEqual(@as(i32, -1), b.storageGet(0, "last_run", &value));
        try t.expectEqual(@as(i32, 0), b.storagePut(0, "last_run", "1754400000123"));

        // The two-call pattern: ask with nothing, learn the size, ask again.
        try t.expectEqual(@as(i32, 13), b.storageGet(0, "last_run", &[_]u8{}));
        try t.expectEqual(@as(i32, 13), b.storageGet(0, "last_run", &value));
        try t.expectEqualStrings("1754400000123", value[0..13]);

        // Bytes, not text: a value with a zero and a quote in it comes back
        // exactly as it went in.
        try t.expectEqual(@as(i32, 0), b.storagePut(0, "blob", "a\x00b\"c\\d"));
        try t.expectEqual(@as(i32, 7), b.storageGet(0, "blob", &value));
        try t.expectEqualStrings("a\x00b\"c\\d", value[0..7]);

        // An empty value is a delete.
        try t.expectEqual(@as(i32, 0), b.storagePut(0, "blob", ""));
        try t.expectEqual(@as(i32, -1), b.storageGet(0, "blob", &value));

        // The caps. A key too long, a value too long, and a key that would
        // break the JSON file it lands in.
        var long_key: [storage_max_key + 1]u8 = @splat('k');
        try t.expectEqual(@as(i32, -1), b.storagePut(0, &long_key, "x"));
        const big = try a.alloc(u8, storage_max_value + 1);
        defer a.free(big);
        @memset(big, 'v');
        try t.expectEqual(@as(i32, -1), b.storagePut(0, "big", big));
        try t.expectEqual(@as(i32, 0), b.storagePut(0, "big", big[0..storage_max_value]));
        try t.expectEqual(@as(i32, -1), b.storagePut(0, "new\nline", "x"));

        // The total. A megabyte of 64 KiB values is sixteen of them, less the
        // keys and what is already stored, and the one that would go over is
        // refused rather than evicting anything.
        var key_buf: [16]u8 = undefined;
        var filled: usize = 1;
        while (filled < 64) : (filled += 1) {
            const key = try std.fmt.bufPrint(&key_buf, "fill{d}", .{filled});
            if (b.storagePut(0, key, big[0..storage_max_value]) != 0) break;
        }
        try t.expect(filled < 64);
        b.mu.lock();
        const held = b.kv.items[0].bytes;
        b.mu.unlock();
        try t.expect(held <= storage_max_total);
        try t.expect(held + storage_max_value > storage_max_total);
    }

    // A new broker, the same directory: what the plugin stored is still there.
    {
        const fx = try Fixture.init(a);
        defer fx.deinit(a);
        const b = &fx.br;
        b.setStorageDir(dir);
        var p = Plugin{ .broker = b, .index = 0, .id = "org.beetlebug.grib", .source = 1, .caps = Caps.initEmpty() };
        try b.registerPlugin(&p);
        try t.expectEqual(@as(i32, 13), b.storageGet(0, "last_run", &value));
        try t.expectEqualStrings("1754400000123", value[0..13]);
        // And the key that was deleted is still deleted.
        try t.expectEqual(@as(i32, -1), b.storageGet(0, "blob", &value));
    }

    // Another plugin's store is another file: one plugin cannot read or
    // overwrite what another saved.
    {
        const fx = try Fixture.init(a);
        defer fx.deinit(a);
        const b = &fx.br;
        b.setStorageDir(dir);
        var other = Plugin{ .broker = b, .index = 0, .id = "org.beetlebug.other", .source = 1, .caps = Caps.initEmpty() };
        try b.registerPlugin(&other);
        try t.expectEqual(@as(i32, -1), b.storageGet(0, "last_run", &value));
    }
}

// -- files ---------------------------------------------------------------------------

test "a granted file reads at an offset, a granted write file appends, and a close ends it" {
    const a = t.allocator;
    const dir = try scratchDir(a, "files");
    defer a.free(dir);
    defer removeScratch(dir);

    const src = try std.fmt.allocPrint(a, "{s}/gfs.grib2", .{dir});
    defer a.free(src);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = test_body });

    const fx = try Fixture.init(a);
    defer fx.deinit(a);
    const b = &fx.br;

    const handle = try b.grantFile(0, src, false);
    try t.expect(handle > 0);
    // The grant arrives as an event, so a plugin learns about a file the same
    // way it learns about everything else.
    const opened = try nextEvent(b, 0, 1_000);
    defer b.freeEvent(opened);
    try t.expectEqual(Kind.file_opened, opened.kind);
    try t.expectEqual(@as(u64, @bitCast(handle)), opened.handle);
    try t.expectEqualStrings("{\"name\":\"gfs.grib2\",\"size\":36,\"mode\":\"read\"}", opened.payload);

    var buf: [16]u8 = undefined;
    try t.expectEqual(@as(i32, 10), b.fileRead(0, handle, 10, buf[0..10]));
    try t.expectEqualStrings("abcdefghij", buf[0..10]);
    // A read past the end is zero bytes, not an error: that is how a plugin
    // chunking a GRIB knows it is done.
    try t.expectEqual(@as(i32, 0), b.fileRead(0, handle, test_body.len, &buf));
    // Another plugin's handle, and a negative offset.
    try t.expectEqual(@as(i32, -1), b.fileRead(1, handle, 0, &buf));
    try t.expectEqual(@as(i32, -1), b.fileRead(0, handle, -1, &buf));

    const out = try std.fmt.allocPrint(a, "{s}/out.kap", .{dir});
    defer a.free(out);
    const wh = try b.grantFile(0, out, true);
    const wopened = try nextEvent(b, 0, 1_000);
    defer b.freeEvent(wopened);
    try t.expectEqualStrings("{\"name\":\"out.kap\",\"size\":0,\"mode\":\"write\"}", wopened.payload);
    try t.expectEqual(@as(i32, 5), b.fileWrite(0, wh, "hello"));
    try t.expectEqual(@as(i32, 6), b.fileWrite(0, wh, " there"));
    // A read handle is not a write handle.
    try t.expectEqual(@as(i32, -1), b.fileWrite(0, handle, "no"));
    b.fileClose(0, wh);
    try t.expectEqual(@as(i32, -1), b.fileWrite(0, wh, "gone"));

    var written: [32]u8 = undefined;
    const got = try std.Io.Dir.cwd().readFile(io, out, &written);
    try t.expectEqualStrings("hello there", got);

    // A plugin holds eight files at most.
    var opened_count: usize = 1;
    while (opened_count < 32) : (opened_count += 1) {
        _ = b.grantFile(0, src, false) catch break;
    }
    try t.expectEqual(files_per_plugin, opened_count);
}
