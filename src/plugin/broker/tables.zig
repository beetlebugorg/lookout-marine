//! A plugin's tabular surface: what a declaration may carry, the cells a batch
//! fills it with, and the order the shell reads the rows back in.
//!
//! The Broker owns the declarations and applies the batches; this file is the
//! shape they take and the budgets they live inside.

const std = @import("std");

const broker = @import("../broker.zig");
const caps = @import("caps.zig");
const testing = @import("testing.zig");

const vstore = @import("../store.zig");
const ais_store = @import("../aisstore.zig");

const Broker = broker.Broker;
const Plugin = broker.Plugin;
const Caps = caps.Caps;
const Kind = caps.Kind;

/// The budgets one table lives inside, the house pattern: a batch that would
/// take a table past any of them is refused whole and logged, never trimmed.
/// Sixteen columns is what a declaration may carry; 512 rows is what a shell
/// will show.
pub const max_table_columns = 16;
pub const max_table_rows = 512;

/// Tables one plugin may declare. One surface per declaration; a plugin with
/// five of them is building an application, not reporting data.
pub const max_tables = 4;

/// Longest key, heading and text cell kept. Longer refuses the declaration or
/// the batch rather than cutting a name in half.
pub const max_table_key = 48;
pub const max_table_label = 64;
pub const max_table_cell = 96;

/// The shortest gap between two ACCEPTED batches for one table. The spec's
/// rate is one update per status cadence, which is a second; the slack is for
/// a plugin timer landing a few milliseconds early.
pub const table_min_interval_ms: i64 = 900;

/// What a column carries, which is what makes shell-side sorting honest. The
/// plugin sends SI and the shell formats for the mariner's units, the reverse
/// of the pick report, because a table sorts and converts where a pick shows
/// one formatted line.
pub const ColumnType = enum {
    /// Metres.
    distance,
    /// Metres per second.
    speed,
    /// Degrees true.
    bearing,
    /// Seconds.
    duration,
    number,
    text,
    /// "alarm", "warning" or null. The shell colours the row by it.
    flag,

    pub fn name(self: ColumnType) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(text: []const u8) ?ColumnType {
        inline for (comptime std.enums.values(ColumnType)) |c| {
            if (std.mem.eql(u8, text, @tagName(c))) return c;
        }
        return null;
    }

    /// True when the cell holds a number, which is what the shell sorts on.
    pub fn numeric(self: ColumnType) bool {
        return switch (self) {
            .distance, .speed, .bearing, .duration, .number => true,
            .text, .flag => false,
        };
    }
};

pub const Column = struct {
    key: []u8,
    label: []u8,
    type: ColumnType,
};

/// One cell. `none` is a cell the plugin sent as null, which the shell renders
/// as a dash: never heard and heard as zero are different readings and stay
/// different here.
pub const Cell = union(enum) {
    none,
    num: f64,
    text: []u8,
};

/// A flag cell's rank, for sorting a `flag` column: an alarm before a warning
/// before anything else, and a cell with nothing in it last of all.
fn flagRank(cell: Cell) u8 {
    return switch (cell) {
        .text => |s| if (std.mem.eql(u8, s, "alarm"))
            0
        else if (std.mem.eql(u8, s, "warning")) 1 else 2,
        else => 3,
    };
}

pub const Row = struct {
    id: []u8,
    /// THE PLUGIN OWNS THE ORDERING POLICY: the mariner's column sort applies
    /// within a band and never across one, so a plugin that puts its alarmed
    /// rows in band 0 keeps them at the top whatever column is sorted by.
    band: i32,
    /// One per declared column, in declaration order.
    cells: []Cell,
    /// Where the row is, when the declaration's `at` named two keys and the
    /// row carried both. A row with a position is locatable: the shell centres
    /// the chart on it and pins its bubble.
    lat: ?f64 = null,
    lon: ?f64 = null,
    /// Arrival order, which is the tiebreak that makes the sort total. Two
    /// rows equal on the sorted column keep the order they were first seen in,
    /// so a table does not shuffle under the mariner's hands.
    seq: u64 = 0,
};

/// One declared table and the rows a plugin has fed it.
pub const Table = struct {
    /// Registry index of the plugin that declared it.
    plugin: u32,
    /// Manifest id, borrowed from the plugin record like `Plugin.id`.
    plugin_id: []const u8,
    key: []u8,
    title: []u8,
    /// The menu the shell opens it from: "Vessels".
    menu: []u8,
    columns: []Column,
    /// The column the shell sorts by until the mariner says otherwise. Empty
    /// when the declaration named none.
    sort_key: []u8,
    sort_asc: bool = true,
    /// The two row keys carrying a position, empty when the table declares no
    /// `at`. They need not be declared columns.
    at_lat: []u8,
    at_lon: []u8,
    rows: std.ArrayList(Row) = .empty,
    /// True while a shell has the dialog on screen. The plugin is told, so it
    /// does not build rows nobody is looking at.
    open: bool = false,
    /// When the last batch was accepted, monotonic.
    last_ms: i64 = 0,
    /// Bumps on every accepted batch. A shell reloads when it changes and
    /// leaves the table alone when it does not.
    seq: u64 = 0,
    next_row_seq: u64 = 0,
    /// Batches refused over budget. The first one is logged and then one in a
    /// hundred, so a plugin sending too fast says so without filling the log.
    refused: u64 = 0,

    pub fn column(self: *const Table, key: []const u8) ?usize {
        for (self.columns, 0..) |c, i| {
            if (std.mem.eql(u8, c.key, key)) return i;
        }
        return null;
    }

    pub fn row(self: *Table, id: []const u8) ?*Row {
        for (self.rows.items) |*r| {
            if (std.mem.eql(u8, r.id, id)) return r;
        }
        return null;
    }
};

pub fn freeCells(alloc: std.mem.Allocator, cells: []Cell) void {
    for (cells) |c| switch (c) {
        .text => |s| alloc.free(s),
        else => {},
    };
    alloc.free(cells);
}

pub fn freeRow(alloc: std.mem.Allocator, r: Row) void {
    alloc.free(r.id);
    freeCells(alloc, r.cells);
}

pub fn freeTable(alloc: std.mem.Allocator, tab: *Table) void {
    for (tab.rows.items) |r| freeRow(alloc, r);
    tab.rows.deinit(alloc);
    for (tab.columns) |c| {
        alloc.free(c.key);
        alloc.free(c.label);
    }
    alloc.free(tab.columns);
    alloc.free(tab.key);
    alloc.free(tab.title);
    alloc.free(tab.menu);
    alloc.free(tab.sort_key);
    alloc.free(tab.at_lat);
    alloc.free(tab.at_lon);
}

/// The order a table is read in: band first and always ascending, then the
/// column the shell asked for, then the order the rows arrived in.
///
/// A cell with nothing in it sorts LAST in both directions. A dash is not a
/// small number, and the mariner sorting by CPA is asking which vessel is
/// closest, not which one has never said.
pub const Order = struct {
    rows: []const Row,
    col: ?usize,
    asc: bool,
    kind: ColumnType,

    pub fn less(self: Order, a: u32, b: u32) bool {
        const x = self.rows[a];
        const y = self.rows[b];
        if (x.band != y.band) return x.band < y.band;
        if (self.col) |c| {
            if (self.compare(x.cells[c], y.cells[c])) |ord| return switch (ord) {
                .lt => self.asc,
                .gt => !self.asc,
                .eq => x.seq < y.seq,
            };
            // One of them is empty and the other is not: empty last, whichever
            // way the column is sorted.
            return x.cells[c] != .none;
        }
        return x.seq < y.seq;
    }

    /// How two cells of this column compare, or null when exactly one of them
    /// is empty.
    fn compare(self: Order, a: Cell, b: Cell) ?std.math.Order {
        if (self.kind == .flag) {
            const ra = flagRank(a);
            const rb = flagRank(b);
            return std.math.order(ra, rb);
        }
        if (a == .none and b == .none) return .eq;
        if (a == .none or b == .none) return null;
        return switch (a) {
            .num => |x| std.math.order(x, if (b == .num) b.num else 0),
            .text => |x| std.ascii.orderIgnoreCase(x, if (b == .text) b.text else ""),
            .none => .eq,
        };
    }
};

/// One string field of a JSON object, or "" when it is missing or is not a
/// string. Declarations and batches are small documents written by a plugin,
/// so a wrong type reads as absent rather than failing the whole batch.
pub fn jsonText(o: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (o.get(key) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

const t = std.testing;
const silentLog = testing.silentLog;

/// A broker with one plugin record, for the table tests. The record is the
/// host's in the real thing; here it is a local the fixture lends out.
const TableFixture = struct {
    vessels: *vstore.Store,
    ais: *ais_store.AisStore,
    broker: Broker,
    plugin: Plugin = undefined,

    fn init() !*TableFixture {
        const a = t.allocator;
        const self = try a.create(TableFixture);
        self.vessels = try a.create(vstore.Store);
        self.vessels.* = try vstore.Store.init(a);
        self.ais = try a.create(ais_store.AisStore);
        self.ais.* = ais_store.AisStore.init(a);
        self.broker = Broker.init(a, self.vessels, self.ais, .{});
        self.broker.setLog(null, silentLog);
        self.plugin = .{
            .broker = &self.broker,
            .index = 0,
            .id = "org.example.table",
            .source = 1,
            .caps = Caps.initEmpty(),
            .table_keys = &test_table_keys,
        };
        return self;
    }

    fn deinit(self: *TableFixture) void {
        const a = t.allocator;
        self.broker.deinit();
        self.ais.deinit();
        self.vessels.deinit();
        a.destroy(self.ais);
        a.destroy(self.vessels);
        a.destroy(self);
    }

    fn declare(self: *TableFixture, json: []const u8) i32 {
        return self.broker.declareTable(&self.plugin, json);
    }

    fn update(self: *TableFixture, json: []const u8) i32 {
        return self.broker.updateTable(&self.plugin, json);
    }

    /// Let the next batch through. The cadence is a wall-clock rule and a test
    /// is not going to wait a second for it.
    fn rewindCadence(self: *TableFixture) void {
        self.broker.mu.lock();
        defer self.broker.mu.unlock();
        for (self.broker.tables.items) |*tab| tab.last_ms = 0;
    }

    fn rows(self: *TableFixture, sort_key: []const u8, ascending: bool, out: *std.ArrayList(u8)) !void {
        out.clearRetainingCapacity();
        try t.expect(try self.broker.tableRowsJson("org.example.table", "targets", sort_key, ascending, out));
    }
};

/// The keys the fixture's manifest declares. "wide" and "t" are here so the
/// refusal tests below fail on the reason they are testing rather than on the
/// manifest check.
const test_table_keys = [_][]const u8{ "targets", "wide", "t" };

/// The declaration the tests work against: one of every kind of column that
/// sorts differently, and a position.
const test_table_decl =
    "{\"key\":\"targets\",\"title\":\"AIS Targets\",\"menu\":\"Vessels\",\"columns\":[" ++
    "{\"key\":\"name\",\"label\":\"Vessel\",\"type\":\"text\"}," ++
    "{\"key\":\"cpa\",\"label\":\"CPA\",\"type\":\"distance\"}," ++
    "{\"key\":\"state\",\"label\":\"\",\"type\":\"flag\"}]," ++
    "\"sort\":{\"key\":\"cpa\",\"ascending\":true},\"at\":{\"lat\":\"lat\",\"lon\":\"lon\"}}";

/// The ids of the rows a query answers with, in order.
fn rowOrder(alloc: std.mem.Allocator, json: []const u8, out: *std.ArrayList([]const u8)) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    for (out.items) |s| alloc.free(s);
    out.clearRetainingCapacity();
    for (parsed.value.object.get("rows").?.array.items) |r| {
        // The slice is the parse's, so it is copied into the caller's list.
        try out.append(alloc, try alloc.dupe(u8, r.object.get("id").?.string));
    }
}

fn freeOrder(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| alloc.free(s);
    list.deinit(alloc);
}

test "the mariner's sort applies within a band and never across one" {
    const a = t.allocator;
    const f = try TableFixture.init();
    defer f.deinit();
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));

    // ALARM is the alarmed vessel: it is the farthest away and its name sorts
    // last, so every sort below would put it at the bottom if the band did not
    // hold it at the top.
    try t.expectEqual(@as(i32, 4), f.update(
        "{\"key\":\"targets\",\"upsert\":[" ++
            "{\"id\":\"1\",\"band\":1,\"name\":\"BRAVO\",\"cpa\":400,\"lat\":38.9,\"lon\":-76.4}," ++
            "{\"id\":\"2\",\"band\":1,\"name\":\"ALPHA\",\"cpa\":900}," ++
            "{\"id\":\"3\",\"band\":1,\"name\":\"CHARLIE\"}," ++
            "{\"id\":\"4\",\"band\":0,\"name\":\"ZULU\",\"cpa\":5000,\"state\":\"alarm\"}]}",
    ));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    var order: std.ArrayList([]const u8) = .empty;
    defer freeOrder(a, &order);

    // By CPA, the declared sort: the alarm first because of its band, then the
    // closest, and the vessel that has never reported one LAST, because a dash is not
    // a small number.
    try f.rows("cpa", true, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqual(@as(usize, 4), order.items.len);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("1", order.items[1]);
    try t.expectEqualStrings("2", order.items[2]);
    try t.expectEqualStrings("3", order.items[3]);

    // By name, ascending and descending: the order under the alarm turns over,
    // the alarm does not move.
    try f.rows("name", true, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("2", order.items[1]);
    try t.expectEqualStrings("1", order.items[2]);
    try t.expectEqualStrings("3", order.items[3]);

    try f.rows("name", false, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("3", order.items[1]);
    try t.expectEqualStrings("1", order.items[2]);
    try t.expectEqualStrings("2", order.items[3]);

    // Sorted by the flag column itself, the alarm is still one band up and the
    // rest keep the order they arrived in.
    try f.rows("state", false, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("1", order.items[1]);

    // An unknown sort key falls back to the declared one rather than to no
    // order at all.
    try f.rows("nonesuch", false, &json);
    try rowOrder(a, json.items, &order);
    try t.expectEqualStrings("4", order.items[0]);
    try t.expectEqualStrings("1", order.items[1]);
    try t.expectEqualStrings("2", order.items[2]);

    // The position rides with the row that has one, and only with that row.
    try t.expect(std.mem.indexOf(u8, json.items, "\"at\":[-76.4,38.9]") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"id\":\"2\",\"band\":1,\"cells\"") != null);
    // A cell the plugin did not send is null on the wire, and a dash on screen.
    try t.expect(std.mem.indexOf(u8, json.items, "[\"CHARLIE\",null,null]") != null);
}

test "rows equal on the sorted column keep the order they arrived in" {
    const a = t.allocator;
    const f = try TableFixture.init();
    defer f.deinit();
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));
    try t.expectEqual(@as(i32, 3), f.update(
        "{\"key\":\"targets\",\"upsert\":[" ++
            "{\"id\":\"c\",\"band\":1,\"name\":\"SAME\",\"cpa\":100}," ++
            "{\"id\":\"a\",\"band\":1,\"name\":\"SAME\",\"cpa\":100}," ++
            "{\"id\":\"b\",\"band\":1,\"name\":\"SAME\",\"cpa\":100}]}",
    ));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    var order: std.ArrayList([]const u8) = .empty;
    defer freeOrder(a, &order);
    for ([_]bool{ true, false }) |asc| {
        try f.rows("cpa", asc, &json);
        try rowOrder(a, json.items, &order);
        try t.expectEqualStrings("c", order.items[0]);
        try t.expectEqualStrings("a", order.items[1]);
        try t.expectEqualStrings("b", order.items[2]);
    }
}

test "a batch over a budget is refused whole, and the table keeps what it had" {
    const a = t.allocator;
    const f = try TableFixture.init();
    defer f.deinit();
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));

    // Exactly the budget goes in.
    var batch: std.ArrayList(u8) = .empty;
    defer batch.deinit(a);
    try batch.appendSlice(a, "{\"key\":\"targets\",\"upsert\":[");
    for (0..max_table_rows) |i| {
        if (i > 0) try batch.append(a, ',');
        try batch.print(a, "{{\"id\":\"{d}\",\"band\":1,\"cpa\":{d}}}", .{ i, i });
    }
    try batch.appendSlice(a, "]}");
    try t.expectEqual(@as(i32, max_table_rows), f.update(batch.items));

    // One more row is one row too many: the batch is refused whole.
    f.rewindCadence();
    try t.expectEqual(@as(i32, -1), f.update(
        "{\"key\":\"targets\",\"upsert\":[{\"id\":\"over\",\"band\":1,\"cpa\":1}]}",
    ));
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.rows("cpa", true, &json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"over\"") == null);

    // A batch that makes room for what it adds is taken.
    f.rewindCadence();
    try t.expectEqual(@as(i32, 2), f.update(
        "{\"key\":\"targets\",\"remove\":[\"0\"]," ++
            "\"upsert\":[{\"id\":\"over\",\"band\":1,\"cpa\":1}]}",
    ));
    try f.rows("cpa", true, &json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"over\"") != null);

    // And a batch inside the status cadence is refused whatever is in it.
    try t.expectEqual(@as(i32, -1), f.update(
        "{\"key\":\"targets\",\"upsert\":[{\"id\":\"over\",\"band\":1,\"cpa\":2}]}",
    ));

    // A batch for a table nobody declared is refused too.
    f.rewindCadence();
    try t.expectEqual(@as(i32, -1), f.update("{\"key\":\"nosuch\",\"upsert\":[]}"));
}

test "a declaration the shell could not render is refused with a reason" {
    const f = try TableFixture.init();
    defer f.deinit();

    // Seventeen columns, one over the budget.
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(t.allocator);
    try wide.appendSlice(t.allocator, "{\"key\":\"wide\",\"title\":\"W\",\"menu\":\"M\",\"columns\":[");
    for (0..max_table_columns + 1) |i| {
        if (i > 0) try wide.append(t.allocator, ',');
        try wide.print(t.allocator, "{{\"key\":\"c{d}\",\"label\":\"C\",\"type\":\"number\"}}", .{i});
    }
    try wide.appendSlice(t.allocator, "]}");
    try t.expectEqual(@as(i32, -1), f.declare(wide.items));

    // A column type the shell has no idea how to sort or show.
    try t.expectEqual(@as(i32, -1), f.declare(
        "{\"key\":\"t\",\"title\":\"T\",\"menu\":\"M\"," ++
            "\"columns\":[{\"key\":\"a\",\"label\":\"A\",\"type\":\"colour\"}]}",
    ));
    // A default sort naming a column that is not there.
    try t.expectEqual(@as(i32, -1), f.declare(
        "{\"key\":\"t\",\"title\":\"T\",\"menu\":\"M\"," ++
            "\"columns\":[{\"key\":\"a\",\"label\":\"A\",\"type\":\"number\"}]," ++
            "\"sort\":{\"key\":\"b\"}}",
    ));
    // Two columns under one key: a cell would land in both.
    try t.expectEqual(@as(i32, -1), f.declare(
        "{\"key\":\"t\",\"title\":\"T\",\"menu\":\"M\",\"columns\":[" ++
            "{\"key\":\"a\",\"label\":\"A\",\"type\":\"number\"}," ++
            "{\"key\":\"a\",\"label\":\"B\",\"type\":\"text\"}]}",
    ));
    try t.expectEqual(@as(i32, -1), f.declare("not json at all"));

    // None of them left anything behind.
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(t.allocator);
    try f.broker.tablesJson(&json);
    try t.expectEqualStrings("{\"tables\":[]}", json.items);
}

test "a declaration reaches the shell, and closing the dialog empties it" {
    const a = t.allocator;
    const f = try TableFixture.init();
    defer f.deinit();
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));
    try t.expectEqual(@as(i32, 1), f.update(
        "{\"key\":\"targets\",\"upsert\":[{\"id\":\"1\",\"band\":0,\"name\":\"ZULU\",\"state\":\"alarm\"}]}",
    ));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(a);
    try f.broker.tablesJson(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"plugin\":\"org.example.table\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"menu\":\"Vessels\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"type\":\"distance\"") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"sort\":{\"key\":\"cpa\",\"ascending\":true}") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"at\":{\"lat\":\"lat\",\"lon\":\"lon\"}") != null);
    try t.expect(std.mem.indexOf(u8, json.items, "\"rows\":1") != null);

    // Opening tells the plugin so, and so does closing.
    try t.expect(f.broker.setTableOpen("org.example.table", "targets", true));
    try t.expect(f.broker.tableOpen("org.example.table", "targets"));
    const opened = f.broker.popFor(0).?;
    defer f.broker.freeEvent(opened);
    try t.expectEqual(Kind.table_open, opened.kind);
    try t.expectEqualStrings("{\"key\":\"targets\"}", opened.payload);

    try t.expect(f.broker.setTableOpen("org.example.table", "targets", false));
    const closed = f.broker.popFor(0).?;
    defer f.broker.freeEvent(closed);
    try t.expectEqual(Kind.table_closed, closed.kind);
    // A table nobody is watching keeps no rows: the plugin describes the whole
    // set again the moment it is opened.
    json.clearRetainingCapacity();
    try f.broker.tablesJson(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"rows\":0") != null);
    // And a table the plugin never declared answers nothing at all.
    try t.expect(!f.broker.setTableOpen("org.example.table", "nosuch", true));
    json.clearRetainingCapacity();
    try t.expect(!try f.broker.tableRowsJson("org.example.other", "targets", "", true, &json));
}

// THE MANIFEST IS THE CONSENT. The runtime declaration and the manifest block
// come out of one comptime source in the SDK, so a plugin only reaches this
// refusal when its manifest was edited apart from its code — or when a module
// is asking for a surface its manifest never showed the mariner.
test "a table the manifest never declared is refused by key" {
    const f = try TableFixture.init();
    defer f.deinit();

    // Everything about it is well formed; only the key is unaccounted for.
    try t.expectEqual(@as(i32, -1), f.declare(
        "{\"key\":\"smuggled\",\"title\":\"Smuggled\",\"menu\":\"Vessels\"," ++
            "\"columns\":[{\"key\":\"a\",\"label\":\"A\",\"type\":\"text\"}]}",
    ));

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(t.allocator);
    try f.broker.tablesJson(&json);
    try t.expectEqualStrings("{\"tables\":[]}", json.items);

    // A key the manifest does carry still goes through, so the check refuses
    // the undeclared table and nothing else.
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));
    json.clearRetainingCapacity();
    try f.broker.tablesJson(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"key\":\"targets\"") != null);

    // A plugin whose manifest declares no tables at all may declare none: the
    // key that worked a line ago is refused once the manifest stops carrying
    // it, and the table already registered is left where it is.
    f.plugin.table_keys = &.{};
    try t.expectEqual(@as(i32, -1), f.declare(test_table_decl));
    json.clearRetainingCapacity();
    try f.broker.tablesJson(&json);
    try t.expect(std.mem.indexOf(u8, json.items, "\"key\":\"targets\"") != null);
}

test "a plugin that goes takes its tables with it" {
    const f = try TableFixture.init();
    defer f.deinit();
    try f.broker.registerPlugin(&f.plugin);
    try t.expectEqual(@as(i32, 0), f.declare(test_table_decl));
    f.broker.dropPlugin(0, 1000);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(t.allocator);
    try f.broker.tablesJson(&json);
    try t.expectEqualStrings("{\"tables\":[]}", json.items);
}
