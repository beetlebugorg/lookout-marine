//! The five settings the mariner has over this plugin, read out of the config
//! JSON the host sends at start and again on every change.
//!
//! The only import is `std`, so `zig test config.zig` runs natively while the
//! same file compiles into the wasm module.
//!
//! UNITS. The schema is written in the units a mariner reads — metres, minutes,
//! knots — because those are what the pane shows. Everything here converts once
//! and the rest of the plugin works in seconds and metres per second.
//!
//! A missing key keeps the default, and a number outside its range is clamped.
//! The host does both already; doing it again costs nothing and means a plugin
//! driven by anything else still cannot be given a gate of zero metres.

const std = @import("std");

const knot_mps = 1852.0 / 3600.0;

/// The schema's ranges, repeated here so the clamp and the manifest cannot
/// drift apart unnoticed: the test at the bottom reads the manifest and
/// compares.
pub const cpa_limit_m_range = [2]f64{ 93, 9260 };
pub const tcpa_limit_min_range = [2]f64{ 1, 60 };
pub const vector_min_range = [2]f64{ 1, 24 };
pub const min_sog_kn_range = [2]f64{ 0, 5 };

pub const Settings = struct {
    /// The danger gate's closest-approach limit, metres. Half a nautical mile
    /// by default.
    cpa_limit_m: f64 = 926,
    /// The danger gate's time limit, seconds. Ten minutes by default.
    tcpa_limit_s: f64 = 600,
    /// False silences the alarm AND the danger colour.
    cpa_alarm: bool = true,
    /// How far ahead a target's speed vector reaches, seconds.
    vector_seconds: f64 = 6 * 60,
    /// Targets slower than this are not drawn at all. Zero shows everything.
    min_sog_mps: f64 = 0,

    /// True when a vessel this slow is to be left off the chart. An aid to
    /// navigation never moves and is never hidden by this.
    pub fn hidden(self: Settings, sog_mps: ?f64, aton: bool) bool {
        if (aton or self.min_sog_mps <= 0) return false;
        return (sog_mps orelse 0) < self.min_sog_mps;
    }
};

/// Settings out of a parsed config object. Anything unreadable keeps its
/// default: a plugin that stops drawing because one field arrived as a string
/// is worse than one that ignores the field.
pub fn fromValue(v: std.json.Value) Settings {
    var s = Settings{};
    if (v != .object) return s;
    const o = v.object;
    s.cpa_limit_m = clamped(o.get("cpa_limit"), s.cpa_limit_m, cpa_limit_m_range);
    s.tcpa_limit_s = clamped(o.get("tcpa_limit"), s.tcpa_limit_s / 60.0, tcpa_limit_min_range) * 60.0;
    s.vector_seconds = clamped(o.get("vector_min"), s.vector_seconds / 60.0, vector_min_range) * 60.0;
    s.min_sog_mps = clamped(o.get("min_sog"), s.min_sog_mps / knot_mps, min_sog_kn_range) * knot_mps;
    s.cpa_alarm = switch (o.get("cpa_alarm") orelse std.json.Value{ .null = {} }) {
        .bool => |b| b,
        else => s.cpa_alarm,
    };
    return s;
}

/// Settings out of config JSON. `alloc` is scratch: nothing in the result
/// points into it.
pub fn fromJson(alloc: std.mem.Allocator, text: []const u8) Settings {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, text, .{}) catch
        return .{};
    return fromValue(root);
}

fn clamped(v: ?std.json.Value, fallback: f64, range: [2]f64) f64 {
    const raw = number(v) orelse return fallback;
    return std.math.clamp(raw, range[0], range[1]);
}

fn number(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| if (std.math.isFinite(f)) f else null,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

fn parse(text: []const u8) Settings {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    return fromJson(arena.allocator(), text);
}

test "an empty config is the defaults, in SI" {
    const s = parse("{}");
    try t.expectEqual(@as(f64, 926), s.cpa_limit_m);
    try t.expectEqual(@as(f64, 600), s.tcpa_limit_s);
    try t.expect(s.cpa_alarm);
    try t.expectEqual(@as(f64, 360), s.vector_seconds);
    try t.expectEqual(@as(f64, 0), s.min_sog_mps);
}

test "every field converts out of the unit the pane shows" {
    const s = parse(
        \\{"cpa_limit":500,"tcpa_limit":4,"cpa_alarm":false,"vector_min":12,"min_sog":2}
    );
    try t.expectEqual(@as(f64, 500), s.cpa_limit_m);
    try t.expectEqual(@as(f64, 240), s.tcpa_limit_s);
    try t.expect(!s.cpa_alarm);
    try t.expectEqual(@as(f64, 720), s.vector_seconds);
    try t.expectApproxEqAbs(@as(f64, 1.02889), s.min_sog_mps, 1e-5);
}

test "a value out of range is clamped and a bad one keeps the default" {
    const low = parse("{\"cpa_limit\":0,\"tcpa_limit\":0,\"vector_min\":0,\"min_sog\":-5}");
    try t.expectEqual(@as(f64, 93), low.cpa_limit_m);
    try t.expectEqual(@as(f64, 60), low.tcpa_limit_s);
    try t.expectEqual(@as(f64, 60), low.vector_seconds);
    try t.expectEqual(@as(f64, 0), low.min_sog_mps);

    const high = parse("{\"cpa_limit\":99999,\"tcpa_limit\":600,\"vector_min\":99,\"min_sog\":50}");
    try t.expectEqual(@as(f64, 9260), high.cpa_limit_m);
    try t.expectEqual(@as(f64, 3600), high.tcpa_limit_s);
    try t.expectEqual(@as(f64, 1440), high.vector_seconds);
    try t.expectApproxEqAbs(@as(f64, 2.5722), high.min_sog_mps, 1e-4);

    // Wrong types, and JSON that is not an object at all.
    const junk = parse("{\"cpa_limit\":\"far\",\"cpa_alarm\":\"off\",\"min_sog\":null}");
    try t.expectEqual(@as(f64, 926), junk.cpa_limit_m);
    try t.expect(junk.cpa_alarm);
    try t.expectEqual(@as(f64, 0), junk.min_sog_mps);
    try t.expectEqual(@as(f64, 926), parse("[]").cpa_limit_m);
    try t.expectEqual(@as(f64, 926), parse("not json").cpa_limit_m);
}

test "the slow-target gate hides vessels and never an aid to navigation" {
    const off = Settings{};
    try t.expect(!off.hidden(0, false));
    try t.expect(!off.hidden(null, false));

    const on = parse("{\"min_sog\":1}"); // 1 kn = 0.514 m/s
    try t.expect(on.hidden(0.4, false));
    try t.expect(!on.hidden(0.6, false));
    // A target that has never reported a speed reads as stopped.
    try t.expect(on.hidden(null, false));
    // An aid to navigation is not a vessel: it is drawn however slow it is.
    try t.expect(!on.hidden(0, true));
    try t.expect(!on.hidden(null, true));
}

test "the schema in manifest.json is the one this file reads" {
    const manifest = @embedFile("manifest.json");
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), manifest, .{});

    // Schema v2: the settings are groups, each naming the settings section it
    // belongs in. Flatten them in declaration order — the keys and the ranges
    // are what this file reads, whatever the shell does with the grouping.
    const groups = root.object.get("settings").?.object.get("groups").?.array.items;
    var flat: std.ArrayList(std.json.Value) = .empty;
    defer flat.deinit(t.allocator);
    for (groups) |g| {
        // Every group names its section and its heading, and every field
        // explains itself: the shell shows all three to the mariner.
        try t.expect(g.object.get("tab").?.string.len > 0);
        try t.expect(g.object.get("label").?.string.len > 0);
        for (g.object.get("fields").?.array.items) |f| {
            try t.expect(f.object.get("desc").?.string.len > 0);
            try flat.append(t.allocator, f);
        }
    }
    const fields = flat.items;
    try t.expectEqual(@as(usize, 5), fields.len);

    const want = [_]struct { key: []const u8, kind: []const u8, unit: []const u8, range: ?[2]f64 }{
        .{ .key = "cpa_limit", .kind = "number", .unit = "m", .range = cpa_limit_m_range },
        .{ .key = "tcpa_limit", .kind = "number", .unit = "min", .range = tcpa_limit_min_range },
        .{ .key = "cpa_alarm", .kind = "toggle", .unit = "", .range = null },
        .{ .key = "vector_min", .kind = "number", .unit = "min", .range = vector_min_range },
        .{ .key = "min_sog", .kind = "number", .unit = "kn", .range = min_sog_kn_range },
    };
    for (fields, want) |got, w| {
        const o = got.object;
        try t.expectEqualStrings(w.key, o.get("key").?.string);
        try t.expectEqualStrings(w.kind, o.get("kind").?.string);
        if (w.range) |r| {
            try t.expectEqual(@as(i64, @intFromFloat(r[0])), o.get("min").?.integer);
            try t.expectEqual(@as(i64, @intFromFloat(r[1])), o.get("max").?.integer);
            try t.expectEqualStrings(w.unit, o.get("unit").?.string);
        }
    }

    // The defaults the manifest ships are the defaults this file falls back
    // to, so a plugin started with no config and one started with the whole
    // schema behave the same.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(t.allocator);
    try text.append(t.allocator, '{');
    for (fields, 0..) |f, i| {
        if (i > 0) try text.append(t.allocator, ',');
        try text.print(t.allocator, "\"{s}\":", .{f.object.get("key").?.string});
        switch (f.object.get("default").?) {
            .integer => |v| try text.print(t.allocator, "{d}", .{v}),
            .bool => |v| try text.print(t.allocator, "{s}", .{if (v) "true" else "false"}),
            else => unreachable,
        }
    }
    try text.append(t.allocator, '}');

    const from_manifest = parse(text.items);
    const defaults = Settings{};
    try t.expectEqual(defaults.cpa_limit_m, from_manifest.cpa_limit_m);
    try t.expectEqual(defaults.tcpa_limit_s, from_manifest.tcpa_limit_s);
    try t.expectEqual(defaults.cpa_alarm, from_manifest.cpa_alarm);
    try t.expectEqual(defaults.vector_seconds, from_manifest.vector_seconds);
    try t.expectEqual(defaults.min_sog_mps, from_manifest.min_sog_mps);
}
