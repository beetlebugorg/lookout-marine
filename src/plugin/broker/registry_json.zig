//! The JSON the host writes and the JSON it reads back out of a plugin's
//! payloads: the STORE_CHANGED and AIS_CHANGED envelopes, the string escaping
//! every other envelope goes through, and the readers that turn one parsed
//! node into a number, a flag or the text the vessel store parses.

const std = @import("std");

const vstore = @import("../store.zig");
const ais_store = @import("../aisstore.zig");

/// `{"values":[{"path":..,"value":..,"ts":..,"age_ms":..}]}`.
///
/// A path with no value left — its only source was cleared, or the plugin that
/// owned it was disabled — is emitted as `{"path":..,"value":null}` with no
/// timestamp. A null value IS the removal; there is no separate "del" list, and
/// a timestamp on a value that no longer exists would be a lie.
pub fn writeStoreChanged(out: *std.ArrayList(u8), alloc: std.mem.Allocator, changes: []const vstore.Change, now: i64) !void {
    try out.appendSlice(alloc, "{\"values\":[");
    var first = true;
    var vbuf: [vstore.max_value_json]u8 = undefined;
    for (changes) |ch| {
        if (!first) try out.append(alloc, ',');
        first = false;
        try out.appendSlice(alloc, "{\"path\":");
        try writeJsonString(out, alloc, ch.path);
        const r = ch.reading orelse {
            try out.appendSlice(alloc, ",\"value\":null}");
            continue;
        };
        const text = r.value.toJson(&vbuf) catch "null";
        try out.print(alloc, ",\"value\":{s},\"ts\":{d},\"age_ms\":{d}}}", .{ text, r.ts_ms, now - r.ts_ms });
    }
    try out.appendSlice(alloc, "]}");
}

/// `{"targets":[{"mmsi":..,...,"age_ms":..}]}` — the full snapshot, absent
/// fields omitted rather than sent as null, so a plugin can tell "never heard"
/// from "heard as zero".
pub fn writeAisChanged(out: *std.ArrayList(u8), alloc: std.mem.Allocator, targets: []const ais_store.Target, now: i64) !void {
    try out.appendSlice(alloc, "{\"targets\":[");
    for (targets, 0..) |tg, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.print(alloc, "{{\"mmsi\":{d}", .{tg.mmsi});
        if (tg.lat) |v| try out.print(alloc, ",\"lat\":{d}", .{v});
        if (tg.lon) |v| try out.print(alloc, ",\"lon\":{d}", .{v});
        if (tg.sog) |v| try out.print(alloc, ",\"sog\":{d}", .{v});
        if (tg.cog) |v| try out.print(alloc, ",\"cog\":{d}", .{v});
        if (tg.heading) |v| try out.print(alloc, ",\"heading\":{d}", .{v});
        if (tg.name()) |n| {
            try out.appendSlice(alloc, ",\"name\":");
            try writeJsonString(out, alloc, n);
        }
        if (tg.aton) {
            try out.appendSlice(alloc, ",\"aton\":true");
            if (tg.aton_type) |v| try out.print(alloc, ",\"aton_type\":{d}", .{v});
            if (tg.virtual_aton) try out.appendSlice(alloc, ",\"virtual\":true");
            if (tg.off_position) |v| try out.print(alloc, ",\"off_position\":{s}", .{if (v) "true" else "false"});
        }
        try out.print(alloc, ",\"ts\":{d},\"age_ms\":{d}}}", .{ tg.ts_ms, now - tg.ts_ms });
    }
    try out.appendSlice(alloc, "]}");
}

/// The same escaping, into a fixed writer. Overflow is dropped: every caller
/// here is building a one-line envelope into a stack buffer.
pub fn writeJsonStringTo(w: *std.Io.Writer, s: []const u8) void {
    w.writeByte('"') catch return;
    for (s) |c| switch (c) {
        '"' => w.writeAll("\\\"") catch return,
        '\\' => w.writeAll("\\\\") catch return,
        '\n' => w.writeAll("\\n") catch return,
        '\r' => w.writeAll("\\r") catch return,
        '\t' => w.writeAll("\\t") catch return,
        0...8, 11, 12, 14...31 => w.print("\\u{x:0>4}", .{c}) catch return,
        else => w.writeByte(c) catch return,
    };
    w.writeByte('"') catch return;
}

pub fn writeJsonString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        0...8, 11, 12, 14...31 => try out.print(alloc, "\\u{x:0>4}", .{c}),
        else => try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

pub fn jsonNum(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else null,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn jsonBool(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// A navaid type code. Out of the 0..31 the wire format defines it reads as
/// unknown, so a bad value loses the type rather than the whole target.
pub fn atonType(v: ?std.json.Value) ?u8 {
    const n = jsonInt(v) orelse return null;
    return if (n >= 0 and n <= 31) @intCast(n) else null;
}

pub fn jsonInt(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else null,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Re-emit a parsed JSON node as text. Only the shapes a published value may
/// take are written; anything else becomes null, which the store rejects.
pub fn writeJsonValue(out: *std.ArrayList(u8), alloc: std.mem.Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try out.appendSlice(alloc, "null"),
        .integer => |i| try out.print(alloc, "{d}", .{i}),
        .float => |f| {
            if (!std.math.isFinite(f)) return error.NotFinite;
            try out.print(alloc, "{d}", .{f});
        },
        .number_string => |s| try out.appendSlice(alloc, s),
        .object => |o| {
            const lat = jsonNum(o.get("lat")) orelse return error.Unsupported;
            const lon = jsonNum(o.get("lon")) orelse return error.Unsupported;
            try out.print(alloc, "{{\"lat\":{d},\"lon\":{d}}}", .{ lat, lon });
        },
        else => return error.Unsupported,
    }
}

const t = std.testing;

test "STORE_CHANGED carries values, and a cleared path as a bare null" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const changes = [_]vstore.Change{
        .{ .path = "navigation.position", .reading = .{
            .value = .{ .position = .{ .lat = 38.9763, .lon = -76.4767 } },
            .ts_ms = 1_000,
            .age_ms = 120,
            .source = 1,
            .stale = false,
        } },
        .{ .path = "environment.depth.belowTransducer", .reading = null },
    };
    try writeStoreChanged(&out, a, &changes, 1_120);
    try t.expectEqualStrings(
        "{\"values\":[" ++
            "{\"path\":\"navigation.position\",\"value\":{\"lat\":38.9763,\"lon\":-76.4767},\"ts\":1000,\"age_ms\":120}," ++
            "{\"path\":\"environment.depth.belowTransducer\",\"value\":null}]}",
        out.items,
    );
}

test "AIS_CHANGED omits fields never heard and always carries age" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    var named = ais_store.Target{ .mmsi = 899000404, .lat = 38.98, .lon = -76.47, .sog = 2.6, .ts_ms = 1_000 };
    @memcpy(named.name_buf[0..15], "TANGERINE OTTER");
    named.name_len = 15;
    const targets = [_]ais_store.Target{ named, .{ .mmsi = 7, .ts_ms = 500 } };
    try writeAisChanged(&out, a, &targets, 2_000);
    try t.expectEqualStrings(
        "{\"targets\":[" ++
            "{\"mmsi\":899000404,\"lat\":38.98,\"lon\":-76.47,\"sog\":2.6,\"name\":\"TANGERINE OTTER\",\"ts\":1000,\"age_ms\":1000}," ++
            "{\"mmsi\":7,\"ts\":500,\"age_ms\":1500}]}",
        out.items,
    );
}

test "a JSON string is escaped, not pasted" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeJsonString(&out, a, "a\"b\\c\nd\x01");
    try t.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", out.items);
}

test "a published value re-emits as the text the store parses" {
    const a = t.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"lat\":38.9,\"lon\":-76.4}", .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try writeJsonValue(&out, a, parsed.value);
    try t.expectEqualStrings("{\"lat\":38.9,\"lon\":-76.4}", out.items);

    out.clearRetainingCapacity();
    try writeJsonValue(&out, a, .{ .float = 2.9 });
    try t.expectEqualStrings("2.9", out.items);
    out.clearRetainingCapacity();
    try writeJsonValue(&out, a, .{ .null = {} });
    try t.expectEqualStrings("null", out.items);
    try t.expectError(error.Unsupported, writeJsonValue(&out, a, .{ .string = "TANGERINE OTTER" }));
}
