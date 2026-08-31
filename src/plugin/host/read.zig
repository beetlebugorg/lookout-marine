//! What a shell reads about the plugins, in the shapes src/plugins.zig
//! declares.
//!
//! This and `registryJson` both walk one `Entry`, so a manifest field added to
//! one and left out of the other fails the test at the foot of this file.

const std = @import("std");

const host = @import("../host.zig");
const install = @import("install.zig");
const manifest = @import("manifest.zig");
const settings_json = @import("settings_json.zig");
const pl = @import("plugins");

const Entry = host.Entry;
const Field = manifest.Field;
const List = manifest.List;

/// Every plugin the host holds, into `out`'s arena.
pub fn build(h: *host.Host, out: *pl.Read) !void {
    h.cfg_mu.lock();
    defer h.cfg_mu.unlock();
    const a = out.alloc();

    var kept: usize = 0;
    for (h.entries.items) |e| {
        if (!e.removed) kept += 1;
    }
    const recs = try a.alloc(pl.PluginRec, kept);
    var i: usize = 0;
    for (h.entries.items) |e| {
        if (e.removed) continue;
        recs[i] = try pluginRec(a, e);
        i += 1;
    }
    out.rows = try pl.published(pl.PluginRec, "plugin", a, recs);
}

fn pluginRec(a: std.mem.Allocator, e: *const Entry) !pl.PluginRec {
    const caps = try capabilities(a, e);
    const sets = try settings(a, e);
    return .{
        .plugin = .{
            .id = try pl.str(a, e.manifest.id),
            .name = try pl.str(a, e.manifest.name),
            .version = try pl.str(a, e.manifest.version),
            .status = try pl.str(a, e.state.status()),
            .origin = originOf(e.origin),
            .live = @intFromBool(e.isLive()),
        },
        .capabilities = caps.ptr,
        .capabilities_len = caps.len,
        .settings = sets.ptr,
        .settings_len = sets.len,
    };
}

/// The manifest's capabilities in consent wording, in the order the consent
/// sheet reads them, each with the allowlist the mariner agreed to.
fn capabilities(a: std.mem.Allocator, e: *const Entry) ![]const *const pl.Capability {
    var recs: std.ArrayList(pl.CapabilityRec) = .empty;
    for (host.sentence_order) |cap| {
        if (!e.manifest.caps.contains(cap)) continue;

        var sentence: std.ArrayList(u8) = .empty;
        defer sentence.deinit(a);
        try install.writeSentence(&sentence, a, cap, &e.manifest);

        const allows = try allowlist(a, &e.manifest, cap);
        try recs.append(a, .{
            .capability = .{
                .name = try pl.str(a, cap.name()),
                .sentence = try pl.str(a, sentence.items),
                .granted = @intFromBool(e.grants.contains(cap)),
            },
            .allows = allows.ptr,
            .allows_len = allows.len,
        });
    }
    return pl.published(pl.CapabilityRec, "capability", a, try recs.toOwnedSlice(a));
}

/// What one capability was asked for: the addresses, topics, ports or file
/// extensions it names. A capability with nothing to name has none.
fn allowlist(
    a: std.mem.Allocator,
    m: *const manifest.Manifest,
    cap: @TypeOf(host.sentence_order[0]),
) ![]const [*:0]const u8 {
    return switch (cap) {
        .net_http => pl.strs(a, m.http_hosts),
        .net_ws => pl.strs(a, m.ws_hosts),
        .net_tcp_client => pl.strs(a, m.tcp_addrs),
        .bus_publish => pl.strs(a, m.pub_topics),
        .bus_read => pl.strs(a, m.sub_topics),
        .files => pl.strs(a, m.file_types),
        .net_udp => blk: {
            const out = try a.alloc([*:0]const u8, m.udp_ports.len);
            for (m.udp_ports, out) |port, *dst| {
                dst.* = (try std.fmt.allocPrintSentinel(a, "{d}", .{port}, 0)).ptr;
            }
            break :blk out;
        },
        else => &.{},
    };
}

/// The scalar settings, then the lists, which is the order the JSON writes.
fn settings(a: std.mem.Allocator, e: *const Entry) ![]const *const pl.Setting {
    const recs = try a.alloc(pl.SettingRec, e.manifest.settings.len + e.manifest.lists.len);
    for (e.manifest.settings, e.values, recs[0..e.manifest.settings.len]) |f, v, *dst| {
        dst.* = .{
            .setting = scalar(try field(a, f, v)),
            .fields = undefined,
            .fields_len = 0,
            .items = undefined,
            .items_len = 0,
            .services = undefined,
            .services_len = 0,
        };
    }
    for (e.manifest.lists, e.rows, recs[e.manifest.settings.len..]) |l, rows_json, *dst| {
        dst.* = try listRec(a, l, rows_json);
    }
    return pl.published(pl.SettingRec, "setting", a, recs);
}

/// A scalar setting names none of a list's wording.
fn scalar(f: pl.Setting) pl.Setting {
    return f;
}

/// One control, with the value in force. A list's field passes its default.
fn field(a: std.mem.Allocator, f: Field, v: f64) !pl.Setting {
    const none = try pl.str(a, "");
    return .{
        .key = try pl.str(a, f.key),
        .label = try pl.str(a, f.label),
        .desc = try pl.str(a, f.desc),
        .group = try pl.str(a, f.group),
        .kind = kindOf(f.kind),
        .section = sectionOf(f.tab),
        .unit = try pl.str(a, f.unit),
        .min = f.min,
        .max = f.max,
        .default_number = f.default_value,
        .default_text = try pl.str(a, f.default_text),
        .placeholder = try pl.str(a, f.placeholder),
        .optional = @intFromBool(f.optional),
        .max_text = manifest.max_text_bytes,
        .footer = none,
        .empty = none,
        .add_label = none,
        .switch_key = none,
        .max_items = 0,
        .value = v,
    };
}

/// A setting the mariner adds more of: its wording, the shape of one item, the
/// items in force, and what to browse the network for.
fn listRec(a: std.mem.Allocator, l: List, rows_json: []const u8) !pl.SettingRec {
    const none = try pl.str(a, "");
    const field_recs = try a.alloc(pl.SettingRec, l.items.len);
    for (l.items, field_recs) |f, *dst| {
        dst.* = .{
            .setting = try field(a, f, f.default_value),
            .fields = undefined,
            .fields_len = 0,
            .items = undefined,
            .items_len = 0,
            .services = undefined,
            .services_len = 0,
        };
    }
    const fields = try pl.published(pl.SettingRec, "setting", a, field_recs);
    const items = try listItems(a, fields, rows_json);
    const services = try listServices(a, fields, l.discover);

    return .{
        .setting = .{
            .key = try pl.str(a, l.key),
            .label = none,
            .desc = none,
            .group = try pl.str(a, l.group),
            .kind = .list,
            .section = sectionOf(l.tab),
            .unit = none,
            .min = 0,
            .max = 0,
            .default_number = 0,
            .default_text = none,
            .placeholder = none,
            .optional = 0,
            .max_text = 0,
            .footer = try pl.str(a, l.footer),
            .empty = try pl.str(a, l.empty),
            .add_label = try pl.str(a, l.add_label),
            .switch_key = try pl.str(a, l.switch_key),
            .max_items = manifest.max_list_rows,
            .value = 0,
        },
        .fields = fields.ptr,
        .fields_len = fields.len,
        .items = items.ptr,
        .items_len = items.len,
        .services = services.ptr,
        .services_len = services.len,
    };
}

/// The items a list holds, from the JSON array the host keeps for it. An item
/// with no id is skipped, which is what a shell reading the JSON does.
fn listItems(
    a: std.mem.Allocator,
    fields: []const *const pl.Setting,
    text: []const u8,
) ![]const *const pl.Item {
    var recs: std.ArrayList(pl.ItemRec) = .empty;
    if (text.len > 0) {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, text, .{})) |doc| {
            if (doc == .array) {
                for (doc.array.items) |entry| {
                    if (entry != .object) continue;
                    const id = switch (entry.object.get("id") orelse continue) {
                        .string => |s| s,
                        else => continue,
                    };
                    const vals = try values(a, fields, entry.object);
                    try recs.append(a, .{
                        .item = .{ .id = try pl.str(a, id) },
                        .values = vals.ptr,
                        .values_len = vals.len,
                    });
                }
            }
        } else |_| {}
    }
    return pl.published(pl.ItemRec, "item", a, try recs.toOwnedSlice(a));
}

/// One value per field, taking the field's default where the item says nothing.
fn values(
    a: std.mem.Allocator,
    fields: []const *const pl.Setting,
    object: std.json.ObjectMap,
) ![]const *const pl.Value {
    const vals = try a.alloc(pl.Value, fields.len);
    for (fields, vals) |f, *dst| dst.* = try value(a, f, object.get(std.mem.span(f.key)));
    const out = try a.alloc(*const pl.Value, vals.len);
    for (vals, out) |*v, *dst| dst.* = v;
    return out;
}

fn value(a: std.mem.Allocator, f: *const pl.Setting, v: ?std.json.Value) !pl.Value {
    var out: pl.Value = .{
        .key = f.key,
        .kind = f.kind,
        .number = 0,
        .text = try pl.str(a, ""),
    };
    switch (f.kind) {
        .number => out.number = jsonNumber(v) orelse f.default_number,
        .toggle => out.number = if (jsonBool(v) orelse (f.default_number != 0)) 1 else 0,
        .text => out.text = if (jsonString(v)) |s| try pl.str(a, s) else f.default_text,
        .list => {},
    }
    return out;
}

/// What to browse the network for, and the values an item added from a find
/// takes beyond its name, address and port.
fn listServices(
    a: std.mem.Allocator,
    fields: []const *const pl.Setting,
    discover: []const manifest.Discover,
) ![]const *const pl.Service {
    const recs = try a.alloc(pl.ServiceRec, discover.len);
    for (discover, recs) |d, *dst| {
        const preset = try presetValues(a, fields, d.set);
        dst.* = .{
            .service = .{ .type = try pl.str(a, d.service) },
            .values = preset.ptr,
            .values_len = preset.len,
        };
    }
    return pl.published(pl.ServiceRec, "service", a, recs);
}

/// Only the fields the `set` object names get a value.
fn presetValues(
    a: std.mem.Allocator,
    fields: []const *const pl.Setting,
    text: []const u8,
) ![]const *const pl.Value {
    var vals: std.ArrayList(pl.Value) = .empty;
    if (text.len > 0) {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, text, .{})) |doc| {
            if (doc == .object) {
                for (fields) |f| {
                    const v = doc.object.get(std.mem.span(f.key)) orelse continue;
                    try vals.append(a, try value(a, f, v));
                }
            }
        } else |_| {}
    }
    const owned_vals = try vals.toOwnedSlice(a);
    const out = try a.alloc(*const pl.Value, owned_vals.len);
    for (owned_vals, out) |*v, *dst| dst.* = v;
    return out;
}

fn jsonNumber(v: ?std.json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn jsonBool(v: ?std.json.Value) ?bool {
    return switch (v orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

fn jsonString(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

// The three enums the read restates. Each switch is exhaustive, so a section or
// a kind added to the manifest stops the build here.
fn sectionOf(tab: manifest.Tab) pl.Section {
    return switch (tab) {
        .display => .display,
        .depths => .depths,
        .text => .text,
        .charts => .charts,
        .vessels => .vessels,
        .alarms => .alarms,
        .connections => .connections,
        .advanced => .advanced,
    };
}

fn kindOf(k: Field.Kind) pl.Kind {
    return switch (k) {
        .number => .number,
        .toggle => .toggle,
        .text => .text,
    };
}

fn originOf(o: host.Origin) pl.Origin {
    return switch (o) {
        .bundled => .bundled,
        .installed => .installed,
        .developer => .developer,
    };
}

// ---- tests --------------------------------------------------------------------

const t = std.testing;
const testing = @import("testing.zig");

fn span(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}

/// The JSON one field writes, parsed back.
fn jsonField(a: std.mem.Allocator, f: Field, v: f64) !std.json.Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try settings_json.writeFieldJson(&out, a, f, v);
    return std.json.parseFromSliceLeaky(std.json.Value, a, out.items, .{});
}

test "a setting says the same thing typed as it does in JSON" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m = try manifest.parseManifest(a, testing.v2_manifest);
    for (m.settings) |f| {
        const typed = try field(a, f, f.default_value);
        const doc = (try jsonField(a, f, f.default_value)).object;

        try t.expectEqualStrings(doc.get("key").?.string, span(typed.key));
        try t.expectEqualStrings(doc.get("label").?.string, span(typed.label));
        try t.expectEqualStrings(doc.get("kind").?.string, @tagName(typed.kind));
        try t.expectEqualStrings(doc.get("tab").?.string, @tagName(typed.section));
        try t.expectEqualStrings(if (doc.get("desc")) |d| d.string else "", span(typed.desc));
        try t.expectEqualStrings(if (doc.get("unit")) |u| u.string else "", span(typed.unit));
        try t.expectEqualStrings(if (doc.get("group")) |g| g.string else "", span(typed.group));
        switch (typed.kind) {
            .number => {
                try t.expectEqual(jsonNumber(doc.get("min")).?, typed.min);
                try t.expectEqual(jsonNumber(doc.get("max")).?, typed.max);
                try t.expectEqual(jsonNumber(doc.get("default")).?, typed.default_number);
                try t.expectEqual(jsonNumber(doc.get("value")).?, typed.value);
            },
            .toggle => {
                try t.expectEqual(doc.get("default").?.bool, typed.default_number != 0);
                try t.expectEqual(doc.get("value").?.bool, typed.value != 0);
            },
            .text, .list => try t.expect(false), // a scalar setting is neither
        }
    }
}

test "a list setting has its wording, its fields and its items" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m = try manifest.parseManifest(a, testing.list_manifest);
    try t.expect(m.lists.len > 0);
    const spec = m.lists[0];
    const rec = try listRec(a, spec,
        \\[{"id":"r1","name":"Pilot","host":"10.0.0.4","port":10111,"enabled":true}]
    );

    try t.expectEqual(pl.Kind.list, rec.setting.kind);
    try t.expectEqualStrings(spec.key, span(rec.setting.key));
    try t.expectEqualStrings(spec.footer, span(rec.setting.footer));
    try t.expectEqualStrings(spec.empty, span(rec.setting.empty));
    try t.expectEqualStrings(spec.add_label, span(rec.setting.add_label));
    try t.expectEqualStrings(spec.switch_key, span(rec.setting.switch_key));
    try t.expectEqual(manifest.max_list_rows, rec.setting.max_items);
    try t.expectEqual(spec.items.len, rec.fields_len);
    try t.expectEqual(@as(usize, 1), rec.items_len);

    const item = rec.items[0];
    try t.expectEqualStrings("r1", span(item.id));
    try t.expectEqualStrings("10.0.0.4", span(pl.itemValue(item, "host").?.text));
    try t.expectEqual(@as(f64, 10111), pl.itemValue(item, "port").?.number);
    try t.expectEqual(@as(f64, 1), pl.itemValue(item, "enabled").?.number);
}

test "a value the item leaves out takes its field's default" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m = try manifest.parseManifest(a, testing.list_manifest);
    const rec = try listRec(a, m.lists[0], "[{\"id\":\"r1\"}]");
    try t.expectEqual(@as(usize, 1), rec.items_len);

    const item = rec.items[0];
    for (rec.fields[0..rec.fields_len]) |f| {
        const v = pl.itemValue(item, span(f.key)).?;
        switch (f.kind) {
            .number, .toggle => try t.expectEqual(f.default_number, v.number),
            .text => try t.expectEqualStrings(span(f.default_text), span(v.text)),
            .list => unreachable,
        }
    }
}

test "an item with no id is left out" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m = try manifest.parseManifest(a, testing.list_manifest);
    const rec = try listRec(a, m.lists[0], "[{\"host\":\"10.0.0.4\"},{\"id\":\"r2\"}]");
    try t.expectEqual(@as(usize, 1), rec.items_len);
    try t.expectEqualStrings("r2", span(rec.items[0].id));
}

test "items that are not an array leave the setting empty" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m = try manifest.parseManifest(a, testing.list_manifest);
    for ([_][]const u8{ "", "[]", "{}", "not json" }) |text| {
        const rec = try listRec(a, m.lists[0], text);
        try t.expectEqual(@as(usize, 0), rec.items_len);
    }
}

const allowlist_manifest =
    \\{"id":"org.example.weather","name":"Weather","api":1,"capabilities":[
    \\ "ais.read",
    \\ {"net.udp":[10110,4001]},
    \\ {"net.http":["nomads.ncep.noaa.gov","opendap.nasa.gov"]},
    \\ "files"],
    \\ "file_types":[".grib2",".grb"]}
;

test "a capability's allowlist is what the manifest named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m = try manifest.parseManifest(a, allowlist_manifest);

    const hosts = try allowlist(a, &m, .net_http);
    try t.expectEqual(@as(usize, 2), hosts.len);
    try t.expectEqualStrings("nomads.ncep.noaa.gov", span(hosts[0]));

    // A port is an allowlist entry like any other.
    const ports = try allowlist(a, &m, .net_udp);
    try t.expectEqual(@as(usize, 2), ports.len);
    try t.expectEqualStrings("10110", span(ports[0]));
    try t.expectEqualStrings("4001", span(ports[1]));

    // The file types a manifest claims are what `files` may open.
    const types = try allowlist(a, &m, .files);
    try t.expectEqual(@as(usize, 2), types.len);
    try t.expectEqualStrings(".grib2", span(types[0]));

    // A capability with nothing to name has no entries.
    try t.expectEqual(@as(usize, 0), (try allowlist(a, &m, .ais_read)).len);
}
