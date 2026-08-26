//! Settings declared as a Zig struct, and the manifest schema generated from
//! it.
//!
//! A plugin declares one group as a struct whose fields carry their own
//! metadata as their default values:
//!
//!   pub const Settings = struct {
//!       pub const group = "Downwind line";
//!       pub const tab: lk.Tab = .display;
//!
//!       length_nm: lk.Num = .{
//!           .label = "Line length",
//!           .desc = "How far downwind the line reaches.",
//!           .unit = "nm", .min = 0.1, .max = 10, .default = 1,
//!       },
//!   };
//!
//! `Values(Settings)` is the plain struct the plugin reads — `f64` for a `Num`,
//! `bool` for a `Flag` — and `settingsJson` is the `"settings"` object the
//! manifest must carry. One declaration feeds both, so a range cannot drift
//! between the manifest and the code that clamps against it.
//!
//! This file imports only `std`: no host imports, no wasm builtins. That is
//! what lets `zig test schema.zig` run natively and lets a plugin's own test
//! embed its manifest.json and check it against the struct.

const std = @import("std");

/// Where a group asks to be shown. The core owns these names; an unknown one
/// is not expressible, which is the point of the enum.
pub const Tab = enum {
    display,
    depths,
    text,
    charts,
    vessels,
    alarms,
    connections,
    advanced,
};

/// A number the mariner sets. `unit` is shown beside the control; the value
/// crosses the API in that unit and is clamped into the range before it
/// arrives.
pub const Num = struct {
    label: []const u8,
    desc: []const u8 = "",
    unit: []const u8 = "",
    min: f64,
    max: f64,
    default: f64,
};

/// An on/off switch.
pub const Flag = struct {
    label: []const u8,
    desc: []const u8 = "",
    default: bool,
};

/// A line of text. Legal only as a column of a connection row: a scalar
/// setting crosses the API as a number and the host keeps no scalar string.
pub const Text = struct {
    label: []const u8,
    desc: []const u8 = "",
    default: []const u8 = "",
    /// The mariner may leave it empty. An optional column declares no default.
    optional: bool = false,
};

/// Longest text value the host keeps.
pub const max_text_bytes = 256;

/// A short string kept by value. A plugin has no allocator that outlives an
/// event, so everything held between events is a fixed buffer.
pub fn Str(comptime n: usize) type {
    return struct {
        const Self = @This();
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *Self, s: []const u8) void {
            const k = @min(s.len, n);
            @memcpy(self.buf[0..k], s[0..k]);
            self.len = k;
        }

        /// Add to the end, up to the capacity. What does not fit is dropped:
        /// a fixed buffer that grows is not a fixed buffer.
        pub fn append(self: *Self, s: []const u8) void {
            const k = @min(s.len, n - self.len);
            @memcpy(self.buf[self.len..][0..k], s[0..k]);
            self.len += k;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn full(self: *const Self) bool {
            return self.len == n;
        }

        pub fn text(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn eql(self: *const Self, s: []const u8) bool {
            return std.mem.eql(u8, self.text(), s);
        }
    };
}

/// Most fields one plugin may declare, counting every group and every column.
pub const max_fields = 16;

/// Most rows one list holds.
pub const max_rows = 8;

// ---------------------------------------------------------------------------
// Reading a group
// ---------------------------------------------------------------------------

/// The group's heading, or "" when it declares none.
pub fn groupLabel(comptime G: type) []const u8 {
    return if (@hasDecl(G, "group")) G.group else "";
}

/// The tab the group asks for.
pub fn groupTab(comptime G: type) Tab {
    return if (@hasDecl(G, "tab")) G.tab else .advanced;
}

/// The metadata a field carries as its default value. A field with no default
/// has no metadata and cannot be rendered.
pub fn spec(comptime f: std.builtin.Type.StructField) f.type {
    return f.defaultValue() orelse @compileError(
        "settings field '" ++ f.name ++ "' needs a default holding its label and range: " ++
            "`" ++ f.name ++ ": lk.Num = .{ .label = \"…\", .min = 0, .max = 1, .default = 0 }`",
    );
}

/// The value type one settings field holds.
fn ValueType(comptime f: std.builtin.Type.StructField) type {
    return switch (f.type) {
        Num => f64,
        Flag => bool,
        Text => @compileError(
            "settings field '" ++ f.name ++ "' is text, which is legal only as a column of a " ++
                "connection row: the host keeps no scalar string",
        ),
        else => @compileError("settings field '" ++ f.name ++ "' must be lk.Num or lk.Flag"),
    };
}

/// The plain struct a plugin reads: the same field names, carrying values
/// rather than metadata.
pub fn Values(comptime G: type) type {
    const in = @typeInfo(G).@"struct".fields;
    comptime var names: [in.len][:0]const u8 = undefined;
    comptime var types: [in.len]type = undefined;
    comptime var attrs: [in.len]std.builtin.Type.StructField.Attributes = undefined;
    inline for (in, 0..) |f, i| {
        const T = ValueType(f);
        const default: T = spec(f).default;
        names[i] = f.name;
        types[i] = T;
        attrs[i] = .{ .default_value_ptr = &default };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

/// Every value at the default its declaration names.
pub fn defaults(comptime G: type) Values(G) {
    return .{};
}

/// Read one group's values out of the config object the host sends. A key the
/// object does not carry keeps the value already in `out`, so a partial object
/// is a partial update rather than a reset to defaults.
pub fn read(comptime G: type, out: *Values(G), config: std.json.Value) void {
    if (config != .object) return;
    inline for (@typeInfo(G).@"struct".fields) |f| {
        if (config.object.get(f.name)) |v| switch (f.type) {
            Num => {
                const d = comptime spec(f);
                if (number(v)) |n| @field(out, f.name) = std.math.clamp(n, d.min, d.max);
            },
            Flag => if (v == .bool) {
                @field(out, f.name) = v.bool;
            },
            else => {},
        };
    }
}

fn number(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// A list of rows
// ---------------------------------------------------------------------------

/// A repeating group: the connection rows a mariner adds. `Columns` is a
/// struct shaped like a settings group, holding the columns beyond the four
/// every list carries.
pub const ListSpec = struct {
    /// The config key the row array arrives under.
    key: []const u8,
    group: []const u8,
    tab: Tab = .connections,
    footer: []const u8 = "",
    empty: []const u8 = "",
    add_label: []const u8 = "",
    /// Which toggle column is the row's own switch.
    switch_key: []const u8 = "enabled",
    /// What a shell browses the boat's network for, so a server that is
    /// already running can be added without anyone typing its address.
    discover: []const Discover = &.{},
};

/// One DNS-SD service a shell offers as a row ready to add.
pub const Discover = struct {
    /// The service type, for example "_signalk-ws._tcp".
    service: []const u8,
    /// The columns a discovered row takes beyond its name, address and port,
    /// as a JSON object. A service announces where it answers and nothing
    /// else, and the address alone is not always enough to dial it: a Signal K
    /// server announces its websocket, which this plugin reads only when the
    /// row says so.
    set: []const u8 = "",
};

/// The four columns every connection list carries, in the order a shell draws
/// them. A caller overrides the wording and the port's range; the keys and the
/// kinds are fixed, because the library dials the row itself.
pub const RowColumns = struct {
    name: Text = .{
        .label = "Name",
        .desc = "What you call this source. Leave it empty to show the address.",
        .optional = true,
    },
    host: Text = .{
        .label = "Address",
        .desc = "The name or IP address to connect to.",
        .default = "",
    },
    port: Num = .{
        .label = "Port",
        .desc = "The port to connect to.",
        .min = 1,
        .max = 65535,
        .default = 10110,
    },
    enabled: Flag = .{
        .label = "On",
        .desc = "Off closes the connection and stops reconnecting.",
        .default = true,
    },
};

// ---------------------------------------------------------------------------
// Generating the manifest's settings object
// ---------------------------------------------------------------------------

/// The `"settings"` value a manifest must carry for `spec_list`.
///
/// `spec_list` is a tuple whose entries are settings-group types and
/// `.{ ListSpec, Columns, ExtraColumns }` triples for a list. The result is
/// comptime text, so a plugin can compare it against its own manifest.json in
/// a native test.
pub fn settingsJson(comptime spec_list: anytype) []const u8 {
    // Through a container constant, so the text is built once at comptime
    // whatever the call site: a caller must not have to write `comptime`.
    return struct {
        const text = build();

        fn build() []const u8 {
            // Every range and default is an f64 formatted at comptime, and one
            // of those costs most of the default 3000-branch quota. A schema
            // holds up to `max_fields` fields of three numbers each.
            @setEvalBranchQuota(4_000 * max_fields);
            comptime {
                var out: []const u8 = "{\"groups\":[";
                var total = 0;
                for (spec_list, 0..) |entry, i| {
                    if (i > 0) out = out ++ ",";
                    if (@TypeOf(entry) == type) {
                        out = out ++ fieldsGroupJson(entry);
                        total += @typeInfo(entry).@"struct".fields.len;
                    } else {
                        out = out ++ listGroupJson(entry[0], entry[1], entry[2]);
                        total += @typeInfo(@TypeOf(entry[1])).@"struct".fields.len +
                            @typeInfo(entry[2]).@"struct".fields.len;
                    }
                }
                if (total > max_fields) @compileError(std.fmt.comptimePrint(
                    "the settings schema declares {d} fields; the host allows {d}",
                    .{ total, max_fields },
                ));
                return out ++ "]}";
            }
        }
    }.text;
}

fn fieldsGroupJson(comptime G: type) []const u8 {
    comptime {
        var out: []const u8 = "{" ++ labelAndTab(groupLabel(G), groupTab(G)) ++ ",\"fields\":[";
        for (@typeInfo(G).@"struct".fields, 0..) |f, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ fieldJson(f.name, spec(f));
        }
        return out ++ "]}";
    }
}

/// A list group. `fixed` carries the four standard columns as the caller worded
/// them and `Extra` the plugin's own; the standard ones come first because a
/// shell draws them in order and the address is what a mariner fills in first.
fn listGroupJson(comptime list: ListSpec, comptime fixed: RowColumns, comptime Extra: type) []const u8 {
    comptime {
        var out: []const u8 = "{" ++ labelAndTab(list.group, list.tab) ++
            ",\"list\":{\"key\":" ++ str(list.key);
        if (list.footer.len > 0) out = out ++ ",\"footer\":" ++ str(list.footer);
        if (list.empty.len > 0) out = out ++ ",\"empty\":" ++ str(list.empty);
        if (list.add_label.len > 0) out = out ++ ",\"add_label\":" ++ str(list.add_label);
        if (list.discover.len > 0) {
            out = out ++ ",\"discover\":[";
            for (list.discover, 0..) |d, i| {
                if (i > 0) out = out ++ ",";
                out = out ++ "{\"service\":" ++ str(d.service);
                // `set` is written into the manifest as it stands, so it has to
                // be an object here rather than wherever the host parses it.
                if (d.set.len > 0) {
                    if (d.set[0] != '{' or d.set[d.set.len - 1] != '}') @compileError(
                        "a discover entry's `set` must be a JSON object, for example \"{\\\"websocket\\\":true}\"",
                    );
                    out = out ++ ",\"set\":" ++ d.set;
                }
                out = out ++ "}";
            }
            out = out ++ "]";
        }
        out = out ++ ",\"switch_key\":" ++ str(list.switch_key) ++ ",\"item_fields\":[";

        var n = 0;
        for (@typeInfo(RowColumns).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "enabled")) continue; // the switch goes last
            if (n > 0) out = out ++ ",";
            n += 1;
            out = out ++ fieldJson(f.name, @field(fixed, f.name));
        }
        for (@typeInfo(Extra).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "id")) @compileError(
                "a connection column may not be called 'id': the host writes that key itself",
            );
            if (n > 0) out = out ++ ",";
            n += 1;
            out = out ++ fieldJson(f.name, spec(f));
        }
        if (n > 0) out = out ++ ",";
        return out ++ fieldJson("enabled", fixed.enabled) ++ "]}}";
    }
}

fn labelAndTab(comptime label: []const u8, comptime tab: Tab) []const u8 {
    return "\"label\":" ++ str(label) ++ ",\"tab\":\"" ++ @tagName(tab) ++ "\"";
}

fn fieldJson(comptime key: []const u8, comptime f: anytype) []const u8 {
    comptime {
        var out: []const u8 = "{\"key\":" ++ str(key) ++ ",\"label\":" ++ str(f.label);
        if (f.desc.len > 0) out = out ++ ",\"desc\":" ++ str(f.desc);
        return out ++ switch (@TypeOf(f)) {
            Num => ",\"kind\":\"number\"" ++
                (if (f.unit.len > 0) ",\"unit\":" ++ str(f.unit) else "") ++
                ",\"min\":" ++ num(f.min) ++ ",\"max\":" ++ num(f.max) ++
                ",\"default\":" ++ num(f.default) ++ "}",
            Flag => ",\"kind\":\"toggle\",\"default\":" ++
                (if (f.default) "true" else "false") ++ "}",
            // An optional column declares no default: the shell says the
            // mariner may leave it empty, and empty is what the plugin reads.
            Text => ",\"kind\":\"text\"" ++
                (if (f.optional) ",\"optional\":true" else ",\"default\":" ++ str(f.default)) ++ "}",
            else => @compileError("a settings field must be lk.Num, lk.Flag or lk.Text"),
        };
    }
}

fn num(comptime v: f64) []const u8 {
    return std.fmt.comptimePrint("{d}", .{v});
}

fn str(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (s) |c| out = out ++ switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11, 12, 14...31 => std.fmt.comptimePrint("\\u{x:0>4}", .{c}),
            else => &[_]u8{c},
        };
        return out ++ "\"";
    }
}

// ---------------------------------------------------------------------------
// Checking a manifest against the declaration
// ---------------------------------------------------------------------------

/// Fail when `manifest_text`'s `"settings"` is not the schema `spec_list`
/// generates. Both sides are parsed, so key order and whitespace do not
/// matter; everything else does.
///
/// For a plugin's own native test:
///
///   test "the manifest carries the schema the settings struct declares" {
///       try schema.expectManifest(@embedFile("manifest.json"), .{Settings});
///   }
pub fn expectManifest(manifest_text: []const u8, comptime spec_list: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, a, manifest_text, .{});
    const got = switch (manifest) {
        .object => |o| o.get("settings") orelse {
            std.debug.print("manifest declares no settings; the struct declares:\n{s}\n", .{settingsJson(spec_list)});
            return error.NoSettingsInManifest;
        },
        else => return error.ManifestIsNotAnObject,
    };
    const want_text = comptime settingsJson(spec_list);
    const want = try std.json.parseFromSliceLeaky(std.json.Value, a, want_text, .{});
    if (!equal(got, want)) {
        std.debug.print("manifest settings do not match the settings struct.\nthe struct declares:\n{s}\n", .{want_text});
        return error.ManifestSchemaMismatch;
    }
}

/// Deep equality over parsed JSON. Numbers compare by value, so 926 and 926.0
/// are the same schema. `lk2.expectTables` checks a manifest's tables with it.
pub fn equal(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer, .float, .number_string => blk: {
            const x = number(a) orelse break :blk false;
            const y = number(b) orelse break :blk false;
            break :blk x == y;
        },
        .string => |x| b == .string and std.mem.eql(u8, b.string, x),
        .array => |x| {
            if (b != .array or b.array.items.len != x.items.len) return false;
            for (x.items, b.array.items) |i, j| {
                if (!equal(i, j)) return false;
            }
            return true;
        },
        .object => |x| {
            if (b != .object or b.object.count() != x.count()) return false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse return false;
                if (!equal(e.value_ptr.*, other)) return false;
            }
            return true;
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

const Alarm = struct {
    pub const group = "Collision alarm";
    pub const tab: Tab = .alarms;

    cpa_limit: Num = .{
        .label = "Closest approach (CPA)",
        .desc = "Alarm when a vessel will pass closer than this.",
        .unit = "m",
        .min = 93,
        .max = 9260,
        .default = 926,
    },
    cpa_alarm: Flag = .{
        .label = "Collision alarm",
        .desc = "Sound the alarm and colour the vessel red. Off silences both.",
        .default = true,
    },
};

test "the values struct carries plain types at the declared defaults" {
    const v = defaults(Alarm);
    try t.expectEqual(@as(f64, 926), v.cpa_limit);
    try t.expectEqual(true, v.cpa_alarm);
    try t.expectEqual(f64, @TypeOf(v.cpa_limit));
    try t.expectEqual(bool, @TypeOf(v.cpa_alarm));
}

test "a config object updates the keys it carries and leaves the rest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"cpa_limit\":1500}",
        .{},
    );
    var v = defaults(Alarm);
    read(Alarm, &v, cfg);
    try t.expectEqual(@as(f64, 1500), v.cpa_limit);
    try t.expectEqual(true, v.cpa_alarm);
}

test "a number outside the declared range is clamped, not taken" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const cfg = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"cpa_limit\":99999,\"cpa_alarm\":42}",
        .{},
    );
    var v = defaults(Alarm);
    read(Alarm, &v, cfg);
    try t.expectEqual(@as(f64, 9260), v.cpa_limit);
    // A toggle sent as a number is a shell with the wrong type, and is refused
    // rather than coerced.
    try t.expectEqual(true, v.cpa_alarm);
}

test "the generated schema is the manifest the ais plugin ships" {
    // The ais plugin's first group, written out by hand in its manifest.
    const want =
        \\{"groups":[{"label":"Collision alarm","tab":"alarms","fields":[
        \\{"key":"cpa_limit","label":"Closest approach (CPA)","desc":"Alarm when a vessel will pass closer than this.","kind":"number","unit":"m","min":93,"max":9260,"default":926},
        \\{"key":"cpa_alarm","label":"Collision alarm","desc":"Sound the alarm and colour the vessel red. Off silences both.","kind":"toggle","default":true}]}]}
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try std.json.parseFromSliceLeaky(std.json.Value, a, settingsJson(.{Alarm}), .{});
    const expected = try std.json.parseFromSliceLeaky(std.json.Value, a, want, .{});
    try t.expect(equal(got, expected));
}

test "a group with no tab lands on advanced, and an empty desc is left out" {
    const Bare = struct {
        scale: Num = .{ .label = "Size", .min = 0.5, .max = 3, .default = 1 },
    };
    try t.expectEqualStrings(
        "{\"groups\":[{\"label\":\"\",\"tab\":\"advanced\",\"fields\":[" ++
            "{\"key\":\"scale\",\"label\":\"Size\",\"kind\":\"number\"," ++
            "\"min\":0.5,\"max\":3,\"default\":1}]}]}",
        settingsJson(.{Bare}),
    );
}

test "a list puts its switch column last and names it" {
    const Extra = struct {
        websocket: Flag = .{ .label = "WebSocket", .default = false },
    };
    const json = settingsJson(.{.{
        ListSpec{ .key = "servers", .group = "Signal K servers", .add_label = "Add Server" },
        RowColumns{},
        Extra,
    }});
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{});
    const list = root.object.get("groups").?.array.items[0].object.get("list").?.object;
    try t.expectEqualStrings("servers", list.get("key").?.string);
    try t.expectEqualStrings("enabled", list.get("switch_key").?.string);
    try t.expectEqualStrings("Add Server", list.get("add_label").?.string);

    const cols = list.get("item_fields").?.array.items;
    const want = [_][]const u8{ "name", "host", "port", "websocket", "enabled" };
    try t.expectEqual(want.len, cols.len);
    for (cols, want) |got, key| try t.expectEqualStrings(key, got.object.get("key").?.string);
    // An optional text column declares no default; a required one does.
    try t.expect(cols[0].object.get("default") == null);
    try t.expect(cols[0].object.get("optional").?.bool);
    try t.expectEqualStrings("", cols[1].object.get("default").?.string);
}

test "a label with a quote in it is escaped rather than closing the string" {
    const Quoted = struct {
        x: Flag = .{ .label = "The \"big\" switch", .default = false },
    };
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        settingsJson(.{Quoted}),
        .{},
    );
    const f = root.object.get("groups").?.array.items[0].object.get("fields").?.array.items[0];
    try t.expectEqualStrings("The \"big\" switch", f.object.get("label").?.string);
}
