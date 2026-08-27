//! The JSON the settings surface is written in: the config object a plugin
//! receives, the rows one of its lists holds, and the description a shell draws
//! a control from.
//!
//! Every string in it goes through `writeJsonString`. A manifest is a file on
//! disk and a status line is text a plugin wrote; neither may break the shape
//! of what it lands in.

const std = @import("std");

const host = @import("../host.zig");
const manifest = @import("manifest.zig");
const testing = @import("testing.zig");

const Error = host.Error;
const Field = manifest.Field;
const List = manifest.List;
const Manifest = manifest.Manifest;
const jsonNumber = manifest.jsonNumber;
const max_list_rows = manifest.max_list_rows;
const max_row_id = manifest.max_row_id;
const max_text_bytes = manifest.max_text_bytes;

fn boolText(v: f64) []const u8 {
    return if (v != 0) "true" else "false";
}

/// `"key":value` for each field and `"key":[rows]` for each list,
/// comma-separated. `first` says whether the object it is going into is still
/// empty.
pub fn writeSettings(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    m: *const Manifest,
    values: []const f64,
    rows: []const []u8,
    first: bool,
) !void {
    var lead = first;
    for (m.settings, values) |f, v| {
        if (!lead) try out.append(alloc, ',');
        lead = false;
        try writeJsonString(out, alloc, f.key);
        switch (f.kind) {
            .number => try out.print(alloc, ":{d}", .{v}),
            .toggle => try out.print(alloc, ":{s}", .{boolText(v)}),
            .text => unreachable, // never a scalar; see parseManifest
        }
    }
    for (m.lists, rows) |l, text| {
        if (!lead) try out.append(alloc, ',');
        lead = false;
        try writeJsonString(out, alloc, l.key);
        try out.append(alloc, ':');
        try out.appendSlice(alloc, text);
    }
}

/// Rewrite a list the shell sent into the rows the plugin will see: every
/// column the schema declares, in schema order, clamped and capped, with the
/// row's id kept.
///
/// The rules match the scalar ones. A number out of range is clamped, not
/// refused; a missing column takes its default; a column the schema does not
/// declare is dropped. A row is dropped only if it is not an object, and rows
/// past `max_list_rows` are dropped: a boat with nine NMEA gateways is a
/// misconfiguration, not a use case.
///
/// `over` counts the rows the cap dropped. The caller says so, because a row
/// the mariner filled in and the host quietly forgot is a row they will sit and
/// wait for.
pub fn normalizeRows(alloc: std.mem.Allocator, l: List, v: std.json.Value, over: *usize) ![]u8 {
    if (v != .array) return Error.BadConfig;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, '[');
    var written: usize = 0;
    for (v.array.items) |rv| {
        if (written >= max_list_rows) {
            // Not an object is not a row at all, and is not counted as one the
            // mariner will miss.
            if (rv == .object) over.* += 1;
            continue;
        }
        const ro = switch (rv) {
            .object => |o| o,
            else => continue,
        };
        if (written > 0) try out.append(alloc, ',');
        // The id is the shell's, and it is what a status item points at. A row
        // that arrives without one gets its position, so the plugin always has
        // something to echo.
        try out.appendSlice(alloc, "{\"id\":");
        const id = switch (ro.get("id") orelse std.json.Value{ .string = "" }) {
            .string => |s| if (s.len > max_row_id) s[0..max_row_id] else s,
            else => "",
        };
        if (id.len > 0) {
            try writeJsonString(&out, alloc, id);
        } else {
            try out.print(alloc, "\"row{d}\"", .{written + 1});
        }
        for (l.items) |f| {
            try out.append(alloc, ',');
            try writeJsonString(&out, alloc, f.key);
            try out.append(alloc, ':');
            const cell = ro.get(f.key);
            switch (f.kind) {
                .number => {
                    const n = jsonNumber(cell) orelse f.default_value;
                    try out.print(alloc, "{d}", .{std.math.clamp(n, f.min, f.max)});
                },
                .toggle => {
                    const b = switch (cell orelse std.json.Value{ .bool = f.default_value != 0 }) {
                        .bool => |x| x,
                        else => f.default_value != 0,
                    };
                    try out.appendSlice(alloc, if (b) "true" else "false");
                },
                .text => {
                    const s = switch (cell orelse std.json.Value{ .string = f.default_text }) {
                        .string => |x| x,
                        else => f.default_text,
                    };
                    try writeJsonString(&out, alloc, if (s.len > max_text_bytes) s[0..max_text_bytes] else s);
                },
            }
        }
        try out.append(alloc, '}');
        written += 1;
    }
    try out.append(alloc, ']');
    return out.toOwnedSlice(alloc);
}

pub fn freeRows(alloc: std.mem.Allocator, rows: [][]u8, built: usize) void {
    for (rows[0..built]) |r| alloc.free(r);
    if (rows.len > 0) alloc.free(rows);
}

/// What a control IS: the label, the sentence under it, the kind, the unit and
/// the limits. Shared by a scalar field and a list's columns. Keys a schema
/// does not declare are left out, so a v1 manifest still writes what it always
/// wrote.
pub fn writeFieldCore(out: *std.ArrayList(u8), alloc: std.mem.Allocator, f: Field) !void {
    try out.appendSlice(alloc, "\"key\":");
    try writeJsonString(out, alloc, f.key);
    try out.appendSlice(alloc, ",\"label\":");
    try writeJsonString(out, alloc, f.label);
    if (f.desc.len > 0) {
        try out.appendSlice(alloc, ",\"desc\":");
        try writeJsonString(out, alloc, f.desc);
    }
    try out.print(alloc, ",\"kind\":\"{s}\"", .{@tagName(f.kind)});
    if (f.unit.len > 0) {
        try out.appendSlice(alloc, ",\"unit\":");
        try writeJsonString(out, alloc, f.unit);
    }
    if (f.optional) try out.appendSlice(alloc, ",\"optional\":true");
    if (f.placeholder.len > 0) {
        try out.appendSlice(alloc, ",\"placeholder\":");
        try writeJsonString(out, alloc, f.placeholder);
    }
    switch (f.kind) {
        .number => try out.print(alloc, ",\"min\":{d},\"max\":{d},\"default\":{d}", .{ f.min, f.max, f.default_value }),
        .toggle => try out.print(alloc, ",\"default\":{s}", .{boolText(f.default_value)}),
        .text => {
            try out.appendSlice(alloc, ",\"default\":");
            try writeJsonString(out, alloc, f.default_text);
            try out.print(alloc, ",\"max_len\":{d}", .{max_text_bytes});
        },
    }
}

/// One scalar field of the registry JSON: what the control is, where the shell
/// puts it, and the value in force.
pub fn writeFieldJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, f: Field, v: f64) !void {
    try out.append(alloc, '{');
    try writeFieldCore(out, alloc, f);
    // Where the shell puts the control. The group is the section heading, left
    // out when the schema declares none. The tab is always written, and always
    // resolved, so every shell reads one answer.
    if (f.group.len > 0) {
        try out.appendSlice(alloc, ",\"group\":");
        try writeJsonString(out, alloc, f.group);
    }
    try out.print(alloc, ",\"tab\":\"{s}\"", .{@tagName(f.tab)});
    switch (f.kind) {
        .number => try out.print(alloc, ",\"value\":{d}", .{v}),
        .toggle => try out.print(alloc, ",\"value\":{s}", .{boolText(v)}),
        .text => unreachable, // never a scalar; see parseManifest
    }
    try out.append(alloc, '}');
}

/// A quoted, escaped JSON string. A manifest is a file on disk and a status
/// line is text a plugin wrote; neither may break the shape of what it lands
/// in.
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

// ---- tests -------------------------------------------------------------------

const t = std.testing;
const Tab = manifest.Tab;
const parseManifest = manifest.parseManifest;
const ais_settings_manifest = testing.ais_settings_manifest;
const list_manifest = testing.list_manifest;
const v2_manifest = testing.v2_manifest;

test "a list group parses, and its rows are policed like any other setting" {
    const a = t.allocator;
    var m = try parseManifest(a, list_manifest);
    defer m.deinit(a);
    try t.expectEqual(@as(usize, 0), m.settings.len);
    try t.expectEqual(@as(usize, 1), m.lists.len);

    const l = m.lists[0];
    try t.expectEqualStrings("connections", l.key);
    try t.expectEqualStrings("Connections", l.group);
    try t.expectEqual(Tab.connections, l.tab);
    // The wording around the rows belongs to the plugin, because only the
    // plugin knows what a row is. Two lists on one tab would otherwise both
    // wear whichever sentence the application hard-coded.
    try t.expectEqualStrings("Most WiFi gateways serve NMEA 0183 on port 10110.", l.footer);
    try t.expectEqualStrings("No gateways yet.", l.empty);
    try t.expectEqualStrings("Add Gateway", l.add_label);
    try t.expectEqualStrings("enabled", l.switch_key);
    try t.expectEqual(@as(usize, 4), l.items.len);
    try t.expectEqual(Field.Kind.text, l.items[0].kind);
    try t.expect(l.items[0].optional);
    try t.expectEqualStrings("127.0.0.1", l.items[1].default_text);
    try t.expectEqual(@as(usize, 0), m.list("connections").?);

    // A row keeps its id, takes the schema's order, clamps a number, drops a
    // column nobody declared, and fills in what is missing.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ja = arena.allocator();
    var over: usize = 0;
    const rows = try normalizeRows(
        a,
        l,
        try std.json.parseFromSliceLeaky(std.json.Value, ja,
            \\[{"id":"c1","name":"Masthead","host":"10.0.0.9","port":99999,"enabled":false,"junk":1},
            \\ {"host":"nav.local"}]
        , .{ .allocate = .alloc_if_needed }),
        &over,
    );
    defer a.free(rows);
    try t.expectEqual(@as(usize, 0), over);
    try t.expectEqualStrings(
        "[{\"id\":\"c1\",\"name\":\"Masthead\",\"host\":\"10.0.0.9\",\"port\":65535,\"enabled\":false}," ++
            "{\"id\":\"row2\",\"name\":\"\",\"host\":\"nav.local\",\"port\":10110,\"enabled\":true}]",
        rows,
    );

    // Rows past the cap are dropped, and a row that is not an object is not a
    // row at all. The three that were dropped are COUNTED, because the mariner
    // typed them in and would otherwise sit waiting for a connection that was
    // never made; the 7 on the end is not counted, because it is not a row.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    try many.append(a, '[');
    for (0..max_list_rows + 3) |i| {
        if (i > 0) try many.append(a, ',');
        try many.print(a, "{{\"host\":\"h{d}\"}}", .{i});
    }
    try many.appendSlice(a, ",7]");
    over = 0;
    const capped = try normalizeRows(a, l, try std.json.parseFromSliceLeaky(std.json.Value, ja, many.items, .{}), &over);
    defer a.free(capped);
    try t.expectEqual(max_list_rows, std.mem.count(u8, capped, "\"host\":"));
    try t.expectEqual(@as(usize, 3), over);

    // A list that is not an array is a shell fault, not a clamp.
    try t.expectError(Error.BadConfig, normalizeRows(a, l, .{ .bool = true }, &over));

    // The registry JSON carries the schema of one row and the rows in force.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try json.append(a, '{');
    try writeFieldCore(&json, a, l.items[1]);
    try json.append(a, '}');
    try t.expectEqualStrings(
        "{\"key\":\"host\",\"label\":\"Address\",\"desc\":\"The gateway on your network.\"," ++
            "\"kind\":\"text\",\"default\":\"127.0.0.1\",\"max_len\":512}",
        json.items,
    );

    // A column's placeholder reaches the shell that renders the empty control.
    json.clearRetainingCapacity();
    try json.append(a, '{');
    try writeFieldCore(&json, a, l.items[0]);
    try json.append(a, '}');
    try t.expectEqualStrings(
        "{\"key\":\"name\",\"label\":\"Name\",\"kind\":\"text\",\"optional\":true," ++
            "\"placeholder\":\"The gateway's own name\",\"default\":\"\",\"max_len\":128}",
        json.items,
    );
}

test "the registry JSON carries the schema the shell renders" {
    const a = t.allocator;
    var m = try parseManifest(a, v2_manifest);
    defer m.deinit(a);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    for (m.settings) |f| try writeFieldJson(&json, a, f, f.default_value);
    const s = json.items;
    try t.expect(std.mem.indexOf(u8, s, "\"desc\":\"Alarm when a vessel will pass closer than this.\"") != null);
    try t.expect(std.mem.indexOf(u8, s, "\"group\":\"Collision alarm\",\"tab\":\"alarms\"") != null);
    try t.expect(std.mem.indexOf(u8, s, "\"group\":\"AIS targets\",\"tab\":\"vessels\"") != null);
    // Nothing declared: no desc key, no group key, and the fallback tab.
    try t.expect(std.mem.indexOf(u8, s, "{\"key\":\"spare\",\"label\":\"Spare\",\"kind\":\"toggle\"," ++
        "\"default\":false,\"tab\":\"advanced\",\"value\":false}") != null);

    // v1 keeps the shape it always wrote, with the tab added.
    var v1 = try parseManifest(a, ais_settings_manifest);
    defer v1.deinit(a);
    json.clearRetainingCapacity();
    try writeFieldJson(&json, a, v1.settings[0], 926);
    try t.expectEqualStrings("{\"key\":\"cpa_limit\",\"label\":\"CPA limit\",\"kind\":\"number\",\"unit\":\"m\"," ++
        "\"min\":93,\"max\":9260,\"default\":926,\"tab\":\"advanced\",\"value\":926}", json.items);
}
