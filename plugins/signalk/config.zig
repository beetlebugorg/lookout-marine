//! The Signal K servers the mariner keeps, read out of the config JSON the
//! host sends at start and again on every change.
//!
//! One boat can reach more than one server: the boat's own server on the
//! network, and a second one on a laptop that holds the instruments it bridges.
//! Each is a row here, and each row is one stream in main.zig.
//!
//! The only import is `std` and the sibling transport file, so `zig test
//! config.zig` runs natively while the same file compiles into the wasm
//! module.
//!
//! A row the host sent is already policed — every column present, numbers
//! clamped, text capped. Reading it again costs nothing and means a plugin
//! driven by anything else still cannot be given a port of zero.

const std = @import("std");
const transport = @import("transport.zig");

/// Most servers one boat may keep. Matches the host's list cap.
pub const max_servers = 8;
pub const max_id = 32;
pub const max_name = 48;
pub const max_host = 128;
pub const default_port: u16 = transport.default_tcp_port;
pub const port_range = [2]i64{ 1, 65535 };

/// A short string kept by value: a plugin has no allocator that outlives an
/// event, so everything that lives between events is a fixed buffer.
pub fn Text(comptime n: usize) type {
    return struct {
        const Self = @This();
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *Self, s: []const u8) void {
            const k = @min(s.len, n);
            @memcpy(self.buf[0..k], s[0..k]);
            self.len = k;
        }

        pub fn text(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn eql(self: *const Self, s: []const u8) bool {
            return std.mem.eql(u8, self.text(), s);
        }
    };
}

/// One server as the mariner set it up.
pub const Row = struct {
    /// The shell's id for this row. It is what a status item points at, so it
    /// must survive an edit: the shell never changes it once the row exists.
    id: Text(max_id) = .{},
    /// What the mariner calls it. May be empty.
    name: Text(max_name) = .{},
    host: Text(max_host) = .{},
    port: u16 = default_port,
    /// False means PAUSED: the stream closes and nothing reconnects it.
    enabled: bool = true,
    /// Which stream to open. There is no column for this yet, so every row is
    /// TCP. See CONCERNS.
    kind: transport.Kind = .tcp,

    /// A row with no address cannot be dialled. The row is disabled and says
    /// so; the plugin keeps running for every other row. The transport is a
    /// separate question and main.zig answers it with a line of its own.
    pub fn usable(self: *const Row) bool {
        return self.host.len > 0 and self.port > 0;
    }
};

pub const Rows = struct {
    items: [max_servers]Row = @splat(.{}),
    len: usize = 0,

    pub fn slice(self: *const Rows) []const Row {
        return self.items[0..self.len];
    }

    fn push(self: *Rows, row: Row) void {
        if (self.len >= max_servers) return;
        self.items[self.len] = row;
        self.len += 1;
    }
};

/// The rows out of a parsed config object. Anything unreadable in a row keeps
/// that column's default; a row with no id at all is skipped, because a row
/// nobody can name cannot be reported on.
pub fn fromValue(v: std.json.Value) Rows {
    var rows = Rows{};
    if (v != .object) return rows;
    const list = switch (v.object.get("servers") orelse return rows) {
        .array => |a| a.items,
        else => return rows,
    };
    for (list) |item| {
        const o = switch (item) {
            .object => |x| x,
            else => continue,
        };
        var r = Row{};
        r.id.set(str(o.get("id")) orelse continue);
        if (r.id.len == 0) continue;
        r.name.set(str(o.get("name")) orelse "");
        r.host.set(str(o.get("host")) orelse "");
        const p = int(o.get("port")) orelse default_port;
        r.port = if (p >= port_range[0] and p <= port_range[1]) @intCast(p) else 0;
        r.kind = switch (o.get("websocket") orelse std.json.Value{ .bool = false }) {
            .bool => |b| if (b) transport.Kind.ws else transport.Kind.tcp,
            else => transport.Kind.tcp,
        };
        r.enabled = switch (o.get("enabled") orelse std.json.Value{ .bool = true }) {
            .bool => |b| b,
            else => true,
        };
        rows.push(r);
    }
    return rows;
}

/// The rows out of config JSON. `alloc` is scratch: nothing in the result
/// points into it.
pub fn fromJson(alloc: std.mem.Allocator, text: []const u8) Rows {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}) catch
        return .{};
    return fromValue(root);
}

fn str(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn int(v: ?std.json.Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

fn parse(text: []const u8) Rows {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    return fromJson(arena.allocator(), text);
}

test "rows carry their id, name, address and pause state" {
    const rows = parse(
        \\{"servers":[
        \\ {"id":"s1","name":"Boat server","host":"10.0.0.9","port":8375,"enabled":true},
        \\ {"id":"s2","name":"","host":"nav.local","port":3000,"enabled":false}]}
    );
    try t.expectEqual(@as(usize, 2), rows.len);
    const a = rows.slice()[0];
    try t.expect(a.id.eql("s1"));
    try t.expect(a.name.eql("Boat server"));
    try t.expect(a.host.eql("10.0.0.9"));
    try t.expectEqual(@as(u16, 8375), a.port);
    try t.expect(a.enabled);
    try t.expect(a.usable());

    const b = rows.slice()[1];
    try t.expect(b.id.eql("s2"));
    try t.expectEqual(@as(usize, 0), b.name.len);
    try t.expectEqual(@as(u16, 3000), b.port);
    try t.expect(!b.enabled);
    // Paused is not broken: the row is still usable, it is just not dialled.
    try t.expect(b.usable());
}

test "a row that cannot be dialled is kept and marked, not dropped" {
    const rows = parse(
        \\{"servers":[
        \\ {"id":"s1","host":"","port":8375},
        \\ {"id":"s2","host":"h","port":0},
        \\ {"id":"s3","host":"h","port":70000},
        \\ {"host":"no-id.local","port":8375}]}
    );
    // The first three are kept and unusable; the one with no id is skipped,
    // because nothing could report on it.
    try t.expectEqual(@as(usize, 3), rows.len);
    for (rows.slice()) |r| try t.expect(!r.usable());
}

test "missing columns take their defaults, and an absent list is no rows" {
    const rows = parse("{\"servers\":[{\"id\":\"s1\",\"host\":\"h\"}]}");
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqual(default_port, rows.slice()[0].port);
    try t.expect(rows.slice()[0].enabled);
    try t.expectEqual(transport.Kind.tcp, rows.slice()[0].kind);

    try t.expectEqual(@as(usize, 0), parse("{}").len);
    try t.expectEqual(@as(usize, 0), parse("{\"servers\":{}}").len);
    try t.expectEqual(@as(usize, 0), parse("not json").len);
    // The nmea0183 plugin's key is not this plugin's key.
    try t.expectEqual(@as(usize, 0), parse("{\"connections\":[{\"id\":\"c1\",\"host\":\"h\"}]}").len);
}

test "the websocket column picks the transport, and TCP is what a row without it gets" {
    const on = parse("{\"servers\":[{\"id\":\"s1\",\"host\":\"h\",\"websocket\":true}]}");
    try t.expectEqual(transport.Kind.ws, on.slice()[0].kind);

    // Absent, and a value of the wrong type, both mean the plain stream: a row
    // a shell wrote badly must not silently change transport.
    const off = parse("{\"servers\":[{\"id\":\"s1\",\"host\":\"h\"}," ++
        "{\"id\":\"s2\",\"host\":\"h\",\"websocket\":\"yes\"}]}");
    try t.expectEqual(transport.Kind.tcp, off.slice()[0].kind);
    try t.expectEqual(transport.Kind.tcp, off.slice()[1].kind);
}

test "more rows than the plugin can hold are dropped, not wrapped" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(t.allocator);
    try text.appendSlice(t.allocator, "{\"servers\":[");
    for (0..max_servers + 4) |i| {
        if (i > 0) try text.append(t.allocator, ',');
        try text.print(t.allocator, "{{\"id\":\"s{d}\",\"host\":\"h{d}\"}}", .{ i, i });
    }
    try text.appendSlice(t.allocator, "]}");
    try t.expectEqual(max_servers, parse(text.items).len);
}

test "the list schema in manifest.json is the one this file reads" {
    const manifest = @embedFile("manifest.json");
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), manifest, .{});

    const groups = root.object.get("settings").?.object.get("groups").?.array.items;
    try t.expectEqual(@as(usize, 1), groups.len);
    const list = groups[0].object.get("list").?.object;
    try t.expectEqualStrings("servers", list.get("key").?.string);
    // Both source plugins file their list under the same tab, so the mariner
    // sees one Connections page with a section each.
    try t.expectEqualStrings("connections", groups[0].object.get("tab").?.string);

    // The columns this file reads, with the kinds it assumes.
    const want = [_]struct { key: []const u8, kind: []const u8 }{
        .{ .key = "name", .kind = "text" },
        .{ .key = "host", .kind = "text" },
        .{ .key = "port", .kind = "number" },
        .{ .key = "websocket", .kind = "toggle" },
        .{ .key = "enabled", .kind = "toggle" },
    };
    const items = list.get("item_fields").?.array.items;
    try t.expectEqual(want.len, items.len);
    for (items, want) |got, w| {
        try t.expectEqualStrings(w.key, got.object.get("key").?.string);
        try t.expectEqualStrings(w.kind, got.object.get("kind").?.string);
        // Every column explains itself, and the port's range is this file's.
        try t.expect(got.object.get("label").?.string.len > 0);
        if (std.mem.eql(u8, w.key, "port")) {
            try t.expectEqual(port_range[0], got.object.get("min").?.integer);
            try t.expectEqual(port_range[1], got.object.get("max").?.integer);
            try t.expectEqual(@as(i64, default_port), got.object.get("default").?.integer);
        }
    }
}
