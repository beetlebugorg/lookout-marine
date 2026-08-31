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

// ---- what the plugins are alarming about --------------------------------------

/// An alarm is audible and repeats until it is acknowledged. A warning and a
/// notice are visible only. A marine alarm does not time out, and looking at it
/// is not acknowledging it.
pub const Severity = enum(c_int) { notice = 0, warning = 1, alarm = 2 };

pub const Alert = extern struct {
    /// What an acknowledgement names. Never reused.
    id: u64,
    plugin: [*:0]const u8,
    title: [*:0]const u8,
    body: [*:0]const u8,
    severity: Severity,
    acknowledged: c_int,
    /// Wall clock in milliseconds since the epoch.
    raised: i64,
};

pub const AlertRec = extern struct { alert: Alert };

/// The alerts a shell holds until it frees them.
pub const Alerts = owned.Owned(Alert);

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

// ---- the tables the plugins declare -------------------------------------------

/// What a column holds. The type is what makes sorting honest, and the plugin
/// sends SI: distance in metres, speed in metres per second, bearing in degrees
/// true, duration in seconds. The shell formats for the mariner's units.
pub const ColumnType = enum(c_int) {
    distance = 0,
    speed = 1,
    bearing = 2,
    duration = 3,
    number = 4,
    text = 5,
    /// "alarm", "warning" or empty. The shell colours the row by it.
    flag = 6,
};

pub const Column = extern struct {
    key: [*:0]const u8,
    label: [*:0]const u8,
    type: ColumnType,
};

pub const Table = extern struct {
    plugin: [*:0]const u8,
    key: [*:0]const u8,
    title: [*:0]const u8,
    /// The menu a shell puts this table's item in.
    menu: [*:0]const u8,
    /// The column to sort by until the mariner says otherwise, and which way.
    /// Empty when the table declares no default.
    sort_key: [*:0]const u8,
    sort_ascending: c_int,
    /// The row keys holding a position. Empty when a row of this table is not
    /// locatable; both are set together.
    at_lat: [*:0]const u8,
    at_lon: [*:0]const u8,
    /// 1 while a shell has told the plugin the table is on screen.
    open: c_int,
    /// How many rows the plugin is holding now.
    rows: usize,
    /// Bumps on every accepted batch. Re-read the rows when it moves.
    seq: u64,
};

pub const TableRec = extern struct {
    table: Table,
    columns: [*]const *const Column,
    columns_len: usize,
};

/// The tables a shell holds until it frees them.
pub const Tables = owned.Owned(Table);

// ---- one table's rows ---------------------------------------------------------

pub const Row = extern struct {
    id: [*:0]const u8,
    /// The plugin's own ordering policy, 0 first. A column sort never crosses
    /// a band, so a plugin that puts its alarmed rows in band 0 keeps them at
    /// the top whatever the mariner sorted by.
    band: i32,
    /// 1 when the table declares an `at` and this row holds one.
    located: c_int,
    lon: f64,
    lat: f64,
};

pub const RowRec = extern struct {
    row: Row,
    cells: [*]const *const Cell,
    cells_len: usize,
};

/// Which of a cell's two values holds it. `absent` is a cell the plugin did not
/// send, which renders as a dash: never heard and heard as zero are different
/// values.
pub const CellKind = enum(c_int) {
    absent = 0,
    number = 1,
    text = 2,
};

/// One value of one row. `type` says how to format it, `kind` says which field
/// holds it. A plugin may send a string for a numeric column.
pub const Cell = extern struct {
    type: ColumnType,
    kind: CellKind,
    number: f64,
    text: [*:0]const u8,
};

/// One table's rows, already in order.
pub const Rows = owned.Owned(Row);

test "the table enum values are the ones the header states" {
    try t.expectEqual(@as(c_int, 0), @intFromEnum(ColumnType.distance));
    try t.expectEqual(@as(c_int, 6), @intFromEnum(ColumnType.flag));
    try t.expectEqual(@as(c_int, 2), @intFromEnum(Severity.alarm));
    try t.expectEqual(@as(c_int, 0), @intFromEnum(CellKind.absent));
    try t.expectEqual(@as(c_int, 2), @intFromEnum(CellKind.text));
    try t.expectEqual(@as(usize, 0), @offsetOf(TableRec, "table"));
    try t.expectEqual(@as(usize, 0), @offsetOf(RowRec, "row"));
    try t.expectEqual(@as(usize, 0), @offsetOf(AlertRec, "alert"));
}
