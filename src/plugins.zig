//! What a shell reads about the plugins: what is loaded, what each asks consent
//! for, and what each lets the mariner set.
//!
//! These are the C structs include/lookout-plugins.h declares, and the records
//! behind them. A public struct is the first field of its record, so the
//! pointer a shell holds is the record's own address and `recOf` casts it back
//! to reach the collections hanging off it.
//!
//! src/plugin/host/read.zig fills them, beside the JSON writer that reads the
//! same Entry.

const std = @import("std");
const owned = @import("owned.zig");

pub const str = owned.str;
pub const strs = owned.strs;
pub const published = owned.published;

/// Where a plugin was loaded from.
pub const Origin = enum(c_int) { bundled = 0, installed = 1, developer = 2 };

/// What a setting is.
pub const Kind = enum(c_int) { number = 0, toggle = 1, text = 2, list = 3 };

/// The app's own settings sections, which a plugin's settings file into
/// alongside the shell's.
pub const Section = enum(c_int) {
    display = 0,
    depths = 1,
    text = 2,
    charts = 3,
    vessels = 4,
    alarms = 5,
    connections = 6,
    advanced = 7,
};

// ---- what is loaded -----------------------------------------------------------

pub const Plugin = extern struct {
    id: [*:0]const u8,
    name: [*:0]const u8,
    version: [*:0]const u8,
    status: [*:0]const u8,
    origin: Origin,
    live: c_int,
};

pub const PluginRec = extern struct {
    plugin: Plugin,
    capabilities: [*]const *const Capability,
    capabilities_len: usize,
    settings: [*]const *const Setting,
    settings_len: usize,
};

// ---- what a plugin asks consent for -------------------------------------------

pub const Capability = extern struct {
    name: [*:0]const u8,
    sentence: [*:0]const u8,
    granted: c_int,
};

pub const CapabilityRec = extern struct {
    capability: Capability,
    allows: [*]const [*:0]const u8,
    allows_len: usize,
};

// ---- what a plugin lets the mariner set ---------------------------------------

pub const Setting = extern struct {
    key: [*:0]const u8,
    label: [*:0]const u8,
    desc: [*:0]const u8,
    group: [*:0]const u8,
    kind: Kind,
    section: Section,

    unit: [*:0]const u8,
    min: f64,
    max: f64,
    default_number: f64,

    default_text: [*:0]const u8,
    placeholder: [*:0]const u8,
    optional: c_int,
    max_text: usize,

    footer: [*:0]const u8,
    empty: [*:0]const u8,
    add_label: [*:0]const u8,
    switch_key: [*:0]const u8,
    max_items: usize,

    value: f64,
};

pub const SettingRec = extern struct {
    setting: Setting,
    fields: [*]const *const Setting,
    fields_len: usize,
    items: [*]const *const Item,
    items_len: usize,
    services: [*]const *const Service,
    services_len: usize,
};

pub const Item = extern struct {
    id: [*:0]const u8,
};

pub const ItemRec = extern struct {
    item: Item,
    values: [*]const *const Value,
    values_len: usize,
};

pub const Value = extern struct {
    key: [*:0]const u8,
    kind: Kind,
    number: f64,
    text: [*:0]const u8,
};

pub const Service = extern struct {
    type: [*:0]const u8,
};

pub const ServiceRec = extern struct {
    service: Service,
    values: [*]const *const Value,
    values_len: usize,
};

/// The read a shell holds until it frees it.
pub const Read = owned.Owned(Plugin);

/// The record a published pointer came from. `Pub` is the record's first field,
/// so the pointer is the record's address.
pub fn recOf(comptime Rec: type, p: anytype) *const Rec {
    return @ptrCast(@alignCast(p));
}

/// One value of `it`, by its field key. Null when the item holds no such field.
pub fn itemValue(it: *const Item, key: []const u8) ?*const Value {
    const rec = recOf(ItemRec, it);
    for (rec.values[0..rec.values_len]) |v| {
        if (std.mem.eql(u8, std.mem.span(v.key), key)) return v;
    }
    return null;
}

const t = std.testing;

test "the enum values are the ones the header states" {
    try t.expectEqual(@as(c_int, 0), @intFromEnum(Section.display));
    try t.expectEqual(@as(c_int, 7), @intFromEnum(Section.advanced));
    try t.expectEqual(@as(c_int, 3), @intFromEnum(Kind.list));
    try t.expectEqual(@as(c_int, 2), @intFromEnum(Origin.developer));
}

test "a public struct is the first field of its record" {
    try t.expectEqual(@as(usize, 0), @offsetOf(PluginRec, "plugin"));
    try t.expectEqual(@as(usize, 0), @offsetOf(CapabilityRec, "capability"));
    try t.expectEqual(@as(usize, 0), @offsetOf(SettingRec, "setting"));
    try t.expectEqual(@as(usize, 0), @offsetOf(ItemRec, "item"));
    try t.expectEqual(@as(usize, 0), @offsetOf(ServiceRec, "service"));
}

test "an item finds its value by field key" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const values = try a.alloc(Value, 2);
    values[0] = .{ .key = try str(a, "host"), .kind = .text, .number = 0, .text = try str(a, "10.0.0.4") };
    values[1] = .{ .key = try str(a, "port"), .kind = .number, .number = 10111, .text = try str(a, "") };
    const by_ptr = try a.alloc(*const Value, 2);
    for (values, by_ptr) |*v, *dst| dst.* = v;

    const recs = try a.alloc(ItemRec, 1);
    recs[0] = .{
        .item = .{ .id = try str(a, "r1") },
        .values = by_ptr.ptr,
        .values_len = by_ptr.len,
    };
    const items = try published(ItemRec, "item", a, recs);

    try t.expectEqualStrings("10.0.0.4", std.mem.span(itemValue(items[0], "host").?.text));
    try t.expectEqual(@as(f64, 10111), itemValue(items[0], "port").?.number);
    try t.expect(itemValue(items[0], "enabled") == null);
}
