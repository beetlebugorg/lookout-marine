//! What a cursor pick reports, in what order, and in which unit.
//!
//! The engine returns the features under the cursor in DRAW order, which puts
//! the land area and the depth area before the light that was tapped. Every
//! shell would otherwise re-invent the same rules, so they live here and reach
//! the shells through `lookout_pick_ranked`:
//!
//!   1. A meta object stays only when it carries something to read. M_QUAL
//!      covers the whole cell and answers every pick; M_NPUB carries the
//!      chart's cautions.
//!   2. A feature the cell gave no attributes never leads: an empty land area
//!      loses to the note beside it.
//!   3. The most SPECIFIC object wins. A sounding is a point the mariner aimed
//!      at; the depth area under it is water they are merely inside. So the
//!      primitive decides first — point, then line, then area — and what the
//!      object is decides within that.
//!   4. A depth reads in the unit the chart is drawn in, and states that unit.

const std = @import("std");
const owned = @import("owned");

/// One picked feature, as the engine reports it.
pub const Feature = struct {
    cls: []const u8,
    s57: []const u8,
    chart: []const u8,
};

/// The attributes that make a feature worth reading.
const informational = [_][]const u8{
    "INFORM", "NINFOM", "TXTDSC", "NTXTDS", "PICREP", "fileReference",
};

/// True when the payload names one of those attributes with a value.
pub fn carriesInformation(s57: []const u8) bool {
    for (informational) |name| {
        var buf: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "\"{s}\":", .{name}) catch continue;
        const at = std.mem.indexOf(u8, s57, key) orelse continue;
        // A key with an empty string after it says nothing.
        var rest = s57[at + key.len ..];
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        if (!std.mem.startsWith(u8, rest, "\"\"")) return true;
    }
    return false;
}

/// True when the cell gave the feature no attributes at all.
pub fn isEmpty(s57: []const u8) bool {
    const t = std.mem.trim(u8, s57, " \t\r\n");
    return t.len == 0 or std.mem.eql(u8, t, "{}");
}

/// True for a meta or collection object: it describes the data, not the water.
pub fn isMeta(cls: []const u8) bool {
    return std.mem.startsWith(u8, cls, "M_") or std.mem.startsWith(u8, cls, "C_");
}

/// True when the pick should report the feature at all.
pub fn keep(f: Feature) bool {
    // A sounding's depth is the figure on the chart, not an attribute. The
    // rest of its payload is provenance. Like a meta object, it reports
    // only when the cell attached something to read.
    if (std.mem.eql(u8, f.cls, "SOUNDG")) return carriesInformation(f.s57);
    if (!isMeta(f.cls)) return true;
    return carriesInformation(f.s57);
}

/// True when two picked features read as the same object. One feature draws
/// several times — a fill, a boundary, a symbol, the rings the pick tests — and
/// every drawing answers, so a chart note would otherwise fill four pages.
pub fn same(a: Feature, b: Feature) bool {
    return std.mem.eql(u8, a.cls, b.cls) and
        std.mem.eql(u8, a.s57, b.s57) and
        std.mem.eql(u8, a.chart, b.chart);
}

const Primitive = enum(u32) { point = 0, line = 1, area = 2 };

const lines = [_][]const u8{
    "DEPCNT", "COALNE", "SLCONS", "NAVLNE", "RECTRC", "CBLSUB", "PIPSOL",
    "TSELNE", "RIVERS", "FERYRT", "DWRTCL", "LNDELV", "CANALS",
};
const areas = [_][]const u8{
    "DEPARE", "DRGARE", "SBDARE", "LNDARE", "BUAARE", "SEAARE", "ACHARE",
    "RESARE", "FAIRWY", "CBLARE", "PIPARE", "MIPARE", "DWRTPT", "TSSLPT",
    "UNSARE", "LNDRGN", "VEGATN", "HRBFAC", "BERTHS", "ADMARE", "CTNARE",
    "OSPARE", "SPLARE", "MARCUL", "DMPGRD",
};

/// What you steer by, then what can hurt you, then the water, then the ground.
const kinds = [_][]const []const u8{
    &.{ "LIGHTS", "LITVES", "LITFLT" },
    &.{ "BOYLAT", "BOYCAR", "BOYSAW", "BOYISD", "BOYSPP", "BOYINB", "BCNLAT", "BCNCAR", "BCNSAW", "BCNISD", "BCNSPP", "DAYMAR", "TOPMAR" },
    &.{ "WRECKS", "OBSTRN", "UWTROC", "ROCKS", "MORFAC", "PILPNT" },
    &.{ "SOUNDG", "DEPCNT", "DEPARE", "DRGARE", "SBDARE" },
    &.{ "ACHARE", "RESARE", "TSSLPT", "TSELNE", "FAIRWY", "NAVLNE", "RECTRC", "CBLARE", "PIPARE", "CBLSUB", "PIPSOL", "DWRTPT", "MIPARE" },
    &.{ "COALNE", "SLCONS", "PONTON", "HRBFAC", "BERTHS", "LNDMRK", "BUISGL" },
    &.{ "LNDARE", "BUAARE", "SEAARE", "LNDRGN", "VEGATN" },
};

fn has(list: []const []const u8, cls: []const u8) bool {
    for (list) |c| if (std.mem.eql(u8, c, cls)) return true;
    return false;
}

fn primitive(cls: []const u8) Primitive {
    if (has(&lines, cls)) return .line;
    if (has(&areas, cls)) return .area;
    // An unlisted class ending in ARE is an area by convention.
    if (std.mem.endsWith(u8, cls, "ARE")) return .area;
    return .point;
}

fn kind(cls: []const u8) u32 {
    for (kinds, 0..) |group, i| if (has(group, cls)) return @intCast(i);
    return 8;
}

/// The sort key of a feature, lowest first.
pub fn rank(f: Feature) u32 {
    if (isEmpty(f.s57)) return 10_000; // nothing to read: never the answer
    if (isMeta(f.cls)) return 900; // a note, but not what was aimed at
    return @intFromEnum(primitive(f.cls)) * 100 + kind(f.cls);
}

/// Sort in place, keeping the engine's order between equals.
pub fn order(features: []Feature) void {
    std.mem.sort(Feature, features, {}, struct {
        fn lessThan(_: void, a: Feature, b: Feature) bool {
            return rank(a) < rank(b);
        }
    }.lessThan);
}

// ---- depth units -----------------------------------------------------------
//
// A cell states every depth in metres. The chart draws them in the mariner's
// unit, so a raw report reads `VALDCO: 5.4` beside a contour drawn `17`. The
// core converts what it reports, because the engine's query cannot: it reports
// what the cell states and takes no mariner. Doing it here also gives every
// shell the same report without reimplementing the attribute list.

/// The attributes that carry a depth in metres.
///
/// VERCLR, HEIGHT and ELEVAT are NOT in this list. They carry a height, which
/// is a separate unit that the mariner does not have, so they stay metric. One
/// report can therefore hold feet depths and metric heights.
const depths = [_][]const u8{ "VALSOU", "VALDCO", "DRVAL1", "DRVAL2" };

/// Metres to feet. The factor the engine draws with (tile57 sndfrm.M_TO_FT).
const M_TO_FT: f64 = 3.280839895;

fn isDepth(name: []const u8) bool {
    for (depths) |d| if (std.mem.eql(u8, d, name)) return true;
    return false;
}

/// One depth as the report shows it: the value, then its unit.
///
/// Feet are WHOLE feet, truncated DOWN, which is what the chart draws — see
/// sndfrm.safconSyms and sndfrm.depthText in the engine — so the report and the
/// label agree digit for digit and both err SHALLOW. A 5.4 m contour reads
/// 17 ft, never 18. A negative value is a drying height, which the chart draws
/// by magnitude, so the truncation applies to the magnitude and the sign stays.
///
/// Metres keep the cell's own text, so the report loses no digit the cell
/// stated.
///
/// Null when the value is not a number. The caller then reports it unchanged.
fn depthText(a: std.mem.Allocator, value: []const u8, feet: bool) ?[]const u8 {
    const m = std.fmt.parseFloat(f64, value) catch return null;
    if (!std.math.isFinite(m)) return null;
    if (!feet) return std.fmt.allocPrint(a, "{s} m", .{value}) catch null;
    const ft = @floor(@abs(m) * M_TO_FT + 1e-6);
    return std.fmt.allocPrint(a, "{d} ft", .{if (m < 0) -ft else ft}) catch null;
}

/// The index just past the string that opens at `at`, or null when it never
/// closes. A backslash escapes the character after it, so an attribute value
/// holding a quote does not end the string early.
fn stringEnd(s: []const u8, at: usize) ?usize {
    var i = at + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') return i + 1;
    }
    return null;
}

/// A pick payload with its depths in the mariner's unit. Everything else is
/// copied through byte for byte, escapes included.
///
/// The payload is the engine's flat acronym -> value JSON. Anything that does
/// not parse as that is returned untouched: a report must never lose an
/// attribute to a rewrite.
pub fn depthsInUnit(a: std.mem.Allocator, s57: []const u8, feet: bool) []const u8 {
    if (s57.len < 2 or s57[0] != '{') return s57;
    var out = std.ArrayList(u8).empty;
    out.append(a, '{') catch return s57;

    var i: usize = 1;
    var n: usize = 0;
    while (i < s57.len and s57[i] != '}') : (n += 1) {
        if (n > 0) {
            if (s57[i] != ',') return s57;
            i += 1;
            out.append(a, ',') catch return s57;
        }
        if (i >= s57.len or s57[i] != '"') return s57;
        const key_end = stringEnd(s57, i) orelse return s57;
        if (key_end >= s57.len or s57[key_end] != ':') return s57;
        const val_at = key_end + 1;
        if (val_at >= s57.len or s57[val_at] != '"') return s57;
        const val_end = stringEnd(s57, val_at) orelse return s57;

        // The key and its colon, then the value the report shows.
        out.appendSlice(a, s57[i..val_at]) catch return s57;
        const key = s57[i + 1 .. key_end - 1];
        const shown = if (isDepth(key)) depthText(a, s57[val_at + 1 .. val_end - 1], feet) else null;
        if (shown) |text| {
            out.append(a, '"') catch return s57;
            out.appendSlice(a, text) catch return s57;
            out.append(a, '"') catch return s57;
        } else {
            out.appendSlice(a, s57[val_at..val_end]) catch return s57;
        }
        i = val_end;
    }
    if (i >= s57.len or s57[i] != '}') return s57;
    out.append(a, '}') catch return s57;
    return out.items;
}

// ---- the read a shell renders ------------------------------------------------
//
// The same pick as `lookout_pick_ranked`, as structs: the composed page beside
// the payload the cell states, so a shell renders one and folds the other.

/// Why a feature's body has nothing to read.
pub const Empty = enum(c_int) {
    /// It has something to read.
    reads = 0,
    /// The cell gave the feature no attributes at all.
    no_attributes = 1,
    /// What it gave is provenance, which is not what a mariner asked for.
    source_only = 2,
};

/// One line of the page, or one line of the fold. `depth` indents a
/// sub-attribute under its heading.
pub const ReportRow = extern struct {
    label: [*:0]const u8,
    value: [*:0]const u8,
    depth: c_int,
    /// 1 when the value names a file the bake stored beside the chart, and
    /// 1 again when that file is a picture rather than text.
    file: c_int,
    picture: c_int,
};

pub const Report = extern struct {
    /// The S-57 class and the cell, as the engine reported them.
    cls: [*:0]const u8,
    chart: [*:0]const u8,
    /// The operative fact, then the object in chart language. `subtitle` is
    /// empty when the page has none.
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    chip: [*:0]const u8,
    /// The provenance line: the cell, the source, its date, the scale range.
    footnote: [*:0]const u8,
    empty: Empty,
    /// The payload as the cell states it, in METRES, for the clipboard.
    raw: [*:0]const u8,
};

pub const ReportRec = extern struct {
    report: Report,
    notes: [*]const [*:0]const u8,
    notes_len: usize,
    rows: [*]const *const ReportRow,
    rows_len: usize,
    source: [*]const *const ReportRow,
    source_len: usize,
};

/// The features under a point, best first.
pub const Read = owned.Owned(Report);

pub const str = owned.str;
pub const published = owned.published;

/// The record behind a feature a shell holds. The public struct is the
/// record's first field, so the pointer is the record's own address.
pub fn recOf(f: *const Report) *const ReportRec {
    return @ptrCast(@alignCast(f));
}

/// One feature's record: the page the engine composed, parsed into the structs,
/// and the payload folded into rows beside it.
///
/// `page` is what tile57_s57_report wrote, `raw` the payload as the cell states
/// it. A page that does not parse leaves the class and the cell on screen, which
/// is what the engine's own fallback does.
pub fn record(
    a: std.mem.Allocator,
    sa: std.mem.Allocator,
    f: Feature,
    raw: []const u8,
    page: []const u8,
) !ReportRec {
    const none = try str(a, "");
    // A page that does not parse leaves every field empty, and the
    // fallbacks below put the class and the cell back on screen.
    const parsed: ?std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, sa, page, .{}) catch null;
    const obj: ?std.json.ObjectMap = if (parsed) |v|
        (if (v == .object) v.object else null)
    else
        null;

    const field = struct {
        fn go(o: ?std.json.ObjectMap, key: []const u8) ?std.json.Value {
            return (o orelse return null).get(key);
        }
    }.go;
    const text = struct {
        fn go(o: ?std.json.ObjectMap, key: []const u8) []const u8 {
            const v = (o orelse return "").get(key) orelse return "";
            return if (v == .string) v.string else "";
        }
    }.go;

    // The notes: what the cell wrote for a mariner to read.
    var notes = std.ArrayList([*:0]const u8).empty;
    if (field(obj, "notes")) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                if (item == .string) try notes.append(a, try str(a, item.string));
            }
        }
    }

    // The detail rows, in the reading order the engine put them in.
    var rows = std.ArrayList(ReportRow).empty;
    if (field(obj, "rows")) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                if (item != .object) continue;
                const r = item.object;
                const label = text(r, "label");
                const value = text(r, "value");
                const depth = if (r.get("depth")) |d| (if (d == .integer) d.integer else 0) else 0;
                const file = if (r.get("file")) |x| (x == .bool and x.bool) else false;
                const picture = if (r.get("picture")) |x| (x == .bool and x.bool) else false;
                try rows.append(a, .{
                    .label = try str(a, label),
                    .value = try str(a, value),
                    .depth = @intCast(depth),
                    .file = @intFromBool(file),
                    .picture = @intFromBool(picture),
                });
            }
        }
    }

    // The fold: the payload as the cell states it, in metres.
    var fold = std.ArrayList(Row).empty;
    try foldRows(sa, &fold, raw);
    const source = try a.alloc(ReportRow, fold.items.len);
    for (fold.items, source) |row, *dst| dst.* = .{
        .label = try str(a, row.name),
        .value = try str(a, row.value),
        .depth = row.depth,
        .file = @intFromBool(isFileRef(row.name, row.value)),
        .picture = @intFromBool(isPicture(row.value)),
    };

    const subtitle = text(obj, "subtitle");
    const title = text(obj, "title");
    const chip = text(obj, "chip");
    const footnote = text(obj, "footnote");
    const empty = text(obj, "empty");

    return .{
        .report = .{
            .cls = try str(a, f.cls),
            .chart = try str(a, f.chart),
            // The engine falls back to the class and the cell when a
            // compose fails, and so does the read.
            .title = if (title.len > 0) try str(a, title) else try str(a, f.cls),
            .subtitle = if (subtitle.len > 0) try str(a, subtitle) else none,
            .chip = if (chip.len > 0) try str(a, chip) else try str(a, f.cls),
            .footnote = if (footnote.len > 0) try str(a, footnote) else try str(a, f.chart),
            .empty = if (std.mem.eql(u8, empty, "none"))
                .no_attributes
            else if (std.mem.eql(u8, empty, "source"))
                .source_only
            else
                .reads,
            .raw = try str(a, raw),
        },
        .notes = notes.items.ptr,
        .notes_len = notes.items.len,
        .rows = try byPtr(a, ReportRow, rows.items),
        .rows_len = rows.items.len,
        .source = try byPtr(a, ReportRow, source),
        .source_len = source.len,
    };
}

/// An array of values as an array of pointers into it.
fn byPtr(a: std.mem.Allocator, comptime T: type, items: []T) ![*]const *const T {
    const out = try a.alloc(*const T, items.len);
    for (items, out) |*item, *dst| dst.* = item;
    return out.ptr;
}

// ---- the source fold ---------------------------------------------------------
//
// The payload as the cell states it, one row per value. Four shells had four
// implementations of the same walk, and they had drifted on what a JSON null
// and a JSON boolean read as. This is the one walk they all call now.

/// One row of the fold. A container becomes a heading row with no value and
/// its parts indent under it: S-101 nests where S-57 was flat.
pub const Row = struct {
    name: []const u8,
    value: []const u8,
    depth: u8,
};

/// The attribute names whose value points at a file beside the chart rather
/// than holding what it says.
const file_refs = [_][]const u8{ "TXTDSC", "NTXTDS", "PICREP", "fileReference" };

/// True when this row names a file the bake stored beside the chart.
pub fn isFileRef(name: []const u8, value: []const u8) bool {
    if (value.len == 0) return false;
    for (file_refs) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

const picture_suffixes = [_][]const u8{ ".tif", ".tiff", ".jpg", ".jpeg", ".png" };

/// True when the file a row names is an image rather than text. The compare is
/// case-insensitive: a cell writes US348MDE.TIF as often as .tif.
pub fn isPicture(value: []const u8) bool {
    for (picture_suffixes) |suffix| {
        if (value.len < suffix.len) continue;
        if (std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix)) return true;
    }
    return false;
}

/// The payload flattened depth-first, object keys in alphabetical order, into
/// `out`. Everything is allocated in `a`.
///
/// A payload that does not parse gives no rows. The top-level object writes no
/// heading of its own, so its attributes are at depth 0.
pub fn foldRows(a: std.mem.Allocator, out: *std.ArrayList(Row), payload: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, payload, .{}) catch return;
    try foldValue(a, out, parsed.value, null, 0);
}

fn foldValue(
    a: std.mem.Allocator,
    out: *std.ArrayList(Row),
    v: std.json.Value,
    name: ?[]const u8,
    depth: u8,
) !void {
    switch (v) {
        .object => |obj| {
            if (name) |n| try out.append(a, .{ .name = n, .value = "", .depth = depth });
            var keys = std.ArrayList([]const u8).empty;
            var it = obj.iterator();
            while (it.next()) |e| try keys.append(a, e.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            for (keys.items) |k| {
                try foldValue(a, out, obj.get(k).?, k, if (name == null) depth else depth + 1);
            }
        },
        .array => |arr| {
            if (name) |n| try out.append(a, .{ .name = n, .value = "", .depth = depth });
            for (arr.items) |item| try foldValue(a, out, item, null, depth + 1);
        },
        else => try out.append(a, .{
            .name = name orelse "",
            .value = try foldText(a, v),
            .depth = depth,
        }),
    }
}

/// One scalar as the fold prints it. A null keeps its name with no value, so
/// the fold still says the cell wrote the attribute.
fn foldText(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .null => "",
        .bool => |b| if (b) "true" else "false",
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| s,
        .string => |s| s,
        else => "",
    };
}

test "a sounding beats the water it sits in" {
    const sounding = Feature{ .cls = "SOUNDG", .s57 = "{\"VALSOU\":\"5.4\"}", .chart = "C" };
    const depare = Feature{ .cls = "DEPARE", .s57 = "{\"DRVAL1\":\"5.4\"}", .chart = "C" };
    try std.testing.expect(rank(sounding) < rank(depare));
}

test "a light beats a sounding" {
    const light = Feature{ .cls = "LIGHTS", .s57 = "{\"COLOUR\":\"3\"}", .chart = "C" };
    const sounding = Feature{ .cls = "SOUNDG", .s57 = "{\"VALSOU\":\"5.4\"}", .chart = "C" };
    try std.testing.expect(rank(light) < rank(sounding));
}

test "a feature with no attributes never leads" {
    const empty = Feature{ .cls = "LNDARE", .s57 = "", .chart = "C" };
    const note = Feature{ .cls = "M_NPUB", .s57 = "{\"TXTDSC\":\"US238FBA.TXT\"}", .chart = "C" };
    try std.testing.expect(rank(note) < rank(empty));
}

test "a sounding reports only when it carries a note" {
    try std.testing.expect(!keep(.{ .cls = "SOUNDG", .s57 = "{\"SCAMIN\":\"17999\"}", .chart = "C" }));
    try std.testing.expect(!keep(.{ .cls = "SOUNDG", .s57 = "{}", .chart = "C" }));
    try std.testing.expect(keep(.{ .cls = "SOUNDG", .s57 = "{\"INFORM\":\"Reported 2019\"}", .chart = "C" }));
}

test "a meta object stays only when it carries something" {
    try std.testing.expect(!keep(.{ .cls = "M_QUAL", .s57 = "{\"CATZOC\":\"2\"}", .chart = "C" }));
    try std.testing.expect(keep(.{ .cls = "M_NPUB", .s57 = "{\"TXTDSC\":\"A.TXT\"}", .chart = "C" }));
    try std.testing.expect(!keep(.{ .cls = "M_NPUB", .s57 = "{\"TXTDSC\":\"\"}", .chart = "C" }));
    try std.testing.expect(keep(.{ .cls = "LNDARE", .s57 = "", .chart = "C" }));
}

test "the same object twice is one report" {
    const note = Feature{ .cls = "M_NPUB", .s57 = "{\"TXTDSC\":\"A.TXT\"}", .chart = "US5BPGFB" };
    try std.testing.expect(same(note, note));
    try std.testing.expect(!same(note, .{ .cls = "M_NPUB", .s57 = note.s57, .chart = "US4LA31M" }));
    try std.testing.expect(!same(note, .{ .cls = "M_NPUB", .s57 = "{}", .chart = note.chart }));
}

test "a depth reads in the mariner's unit, and says which" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The contour drawn 17 by SAFCON01 reports 17 ft, not 5.4 (17.71 floored).
    try std.testing.expectEqualStrings(
        "{\"VALDCO\":\"17 ft\"}",
        depthsInUnit(a, "{\"VALDCO\":\"5.4\"}", true),
    );
    try std.testing.expectEqualStrings(
        "{\"VALDCO\":\"5.4 m\"}",
        depthsInUnit(a, "{\"VALDCO\":\"5.4\"}", false),
    );
    // Every depth attribute converts; the ones between them are untouched.
    try std.testing.expectEqualStrings(
        "{\"DRVAL1\":\"6 ft\",\"OBJNAM\":\"2\",\"DRVAL2\":\"32 ft\"}",
        depthsInUnit(a, "{\"DRVAL1\":\"2\",\"OBJNAM\":\"2\",\"DRVAL2\":\"10\"}", true),
    );
    try std.testing.expectEqualStrings(
        "{\"VALSOU\":\"15 ft\"}",
        depthsInUnit(a, "{\"VALSOU\":\"4.6\"}", true),
    );
}

test "a drying height keeps its sign, and a height stays metric" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A negative sounding dries: the chart draws the magnitude, so the report
    // truncates the magnitude and keeps the sign.
    try std.testing.expectEqualStrings(
        "{\"VALSOU\":\"-4 ft\"}",
        depthsInUnit(a, "{\"VALSOU\":\"-1.5\"}", true),
    );
    // VERCLR is a height. The mariner has no height unit, so it does not move.
    try std.testing.expectEqualStrings(
        "{\"VERCLR\":\"4.6\",\"HEIGHT\":\"12\"}",
        depthsInUnit(a, "{\"VERCLR\":\"4.6\",\"HEIGHT\":\"12\"}", true),
    );
}

test "a danger's depth converts, whatever class carries it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The rewrite reads the attribute, not the class, so every object that
    // states a depth in VALSOU reports it in the mariner's unit: a wreck, an
    // obstruction and an underwater rock as much as a sounding.
    try std.testing.expectEqualStrings(
        "{\"CATWRK\":\"2\",\"VALSOU\":\"18 ft\",\"WATLEV\":\"3\"}",
        depthsInUnit(a, "{\"CATWRK\":\"2\",\"VALSOU\":\"5.5\",\"WATLEV\":\"3\"}", true),
    );
    try std.testing.expectEqualStrings(
        "{\"CATOBS\":\"6\",\"VALSOU\":\"3 ft\"}",
        depthsInUnit(a, "{\"CATOBS\":\"6\",\"VALSOU\":\"1.2\"}", true),
    );
    try std.testing.expectEqualStrings(
        "{\"VALSOU\":\"2 ft\",\"QUASOU\":\"1\"}",
        depthsInUnit(a, "{\"VALSOU\":\"0.9\",\"QUASOU\":\"1\"}", true),
    );
    // A wreck that shows above water carries both units in one report: the
    // depth over it in feet, the part standing above it in metres.
    try std.testing.expectEqualStrings(
        "{\"VALSOU\":\"-4 ft\",\"HEIGHT\":\"2.4\"}",
        depthsInUnit(a, "{\"VALSOU\":\"-1.5\",\"HEIGHT\":\"2.4\"}", true),
    );
}

test "a payload that is not a depth survives the rewrite unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_][]const u8{ "", "{}", "{\"TXTDSC\":\"US238FBA.TXT\"}" }) |raw| {
        try std.testing.expectEqualStrings(raw, depthsInUnit(a, raw, true));
    }
    // An escaped quote does not end the value early.
    const escaped = "{\"INFORM\":\"a\\\"b\",\"VALSOU\":\"4.6\"}";
    try std.testing.expectEqualStrings(
        "{\"INFORM\":\"a\\\"b\",\"VALSOU\":\"15 ft\"}",
        depthsInUnit(a, escaped, true),
    );
    // A depth the cell did not write as a number is reported as it stands.
    try std.testing.expectEqualStrings(
        "{\"VALSOU\":\"unknown\"}",
        depthsInUnit(a, "{\"VALSOU\":\"unknown\"}", true),
    );
}

test "order puts the aimed-at object first" {
    var fs = [_]Feature{
        .{ .cls = "LNDARE", .s57 = "", .chart = "C" },
        .{ .cls = "DEPARE", .s57 = "{\"DRVAL1\":\"5\"}", .chart = "C" },
        .{ .cls = "LIGHTS", .s57 = "{\"COLOUR\":\"3\"}", .chart = "C" },
    };
    order(&fs);
    try std.testing.expectEqualStrings("LIGHTS", fs[0].cls);
    try std.testing.expectEqualStrings("DEPARE", fs[1].cls);
    try std.testing.expectEqualStrings("LNDARE", fs[2].cls);
}

test "the fold walks the payload depth first with the keys sorted" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rows = std.ArrayList(Row).empty;
    try foldRows(arena.allocator(), &rows,
        \\{"OBJNAM":"Thomas Point","COLOUR":"4","information":{"text":"Seasonal","lang":"eng"}}
    );

    // The top-level object writes no heading of its own, so its attributes sit
    // at depth 0 and read alphabetically.
    try std.testing.expectEqual(@as(usize, 5), rows.items.len);
    try std.testing.expectEqualStrings("COLOUR", rows.items[0].name);
    try std.testing.expectEqualStrings("4", rows.items[0].value);
    try std.testing.expectEqual(@as(u8, 0), rows.items[0].depth);
    try std.testing.expectEqualStrings("OBJNAM", rows.items[1].name);

    // A complex attribute is a heading, and its parts indent under it.
    try std.testing.expectEqualStrings("information", rows.items[2].name);
    try std.testing.expectEqualStrings("", rows.items[2].value);
    try std.testing.expectEqual(@as(u8, 0), rows.items[2].depth);
    try std.testing.expectEqualStrings("lang", rows.items[3].name);
    try std.testing.expectEqual(@as(u8, 1), rows.items[3].depth);
    try std.testing.expectEqualStrings("text", rows.items[4].name);
    try std.testing.expectEqualStrings("Seasonal", rows.items[4].value);
}

test "the fold indents an array under its name" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rows = std.ArrayList(Row).empty;
    try foldRows(arena.allocator(), &rows,
        \\{"NINFOM":["one","two"]}
    );
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    try std.testing.expectEqualStrings("NINFOM", rows.items[0].name);
    try std.testing.expectEqualStrings("", rows.items[0].value);
    // An element has no name of its own.
    try std.testing.expectEqualStrings("", rows.items[1].name);
    try std.testing.expectEqualStrings("one", rows.items[1].value);
    try std.testing.expectEqual(@as(u8, 1), rows.items[1].depth);
    try std.testing.expectEqualStrings("two", rows.items[2].value);
}

test "the fold prints every scalar the way the shells will read it" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rows = std.ArrayList(Row).empty;
    try foldRows(arena.allocator(), &rows,
        \\{"a":17,"b":5.4,"c":true,"d":false,"e":null,"f":"text"}
    );
    try std.testing.expectEqual(@as(usize, 6), rows.items.len);
    try std.testing.expectEqualStrings("17", rows.items[0].value);
    try std.testing.expectEqualStrings("5.4", rows.items[1].value);
    try std.testing.expectEqualStrings("true", rows.items[2].value);
    try std.testing.expectEqualStrings("false", rows.items[3].value);
    // A null keeps its name, so the fold still says the cell wrote it.
    try std.testing.expectEqualStrings("e", rows.items[4].name);
    try std.testing.expectEqualStrings("", rows.items[4].value);
    try std.testing.expectEqualStrings("text", rows.items[5].value);
}

test "a payload that does not parse gives no rows" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var rows = std.ArrayList(Row).empty;
    try foldRows(arena.allocator(), &rows, "not json at all");
    try std.testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "a file reference is the four attributes that name one" {
    try std.testing.expect(isFileRef("TXTDSC", "US348MDE.TXT"));
    try std.testing.expect(isFileRef("NTXTDS", "US348MDE.TXT"));
    try std.testing.expect(isFileRef("PICREP", "US348MDE.TIF"));
    try std.testing.expect(isFileRef("fileReference", "US348MDE.TXT"));
    try std.testing.expect(!isFileRef("INFORM", "US348MDE.TXT"));
    // A named attribute with nothing in it points at no file.
    try std.testing.expect(!isFileRef("TXTDSC", ""));
}

test "a picture is the file the shell can show" {
    try std.testing.expect(isPicture("US348MDE.TIF"));
    try std.testing.expect(isPicture("a.tiff"));
    try std.testing.expect(isPicture("a.jpg"));
    try std.testing.expect(isPicture("a.jpeg"));
    try std.testing.expect(isPicture("a.PNG"));
    try std.testing.expect(!isPicture("US348MDE.TXT"));
    try std.testing.expect(!isPicture(".png.txt"));
    try std.testing.expect(!isPicture("png"));
}

test "a page parses into the structs the shell reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try record(a, a, .{
        .cls = "LIGHTS",
        .chart = "US5MD1MC",
        .s57 = "",
    },
        \\{"COLOUR":"4","INFORM":"Seasonal aid","TXTDSC":"US348MDE.TXT"}
    ,
        \\{"title":"Fl G 4s","subtitle":"Light","chip":"Light","notes":["Seasonal aid"],
        \\"rows":[{"label":"Colour","value":"green"},
        \\{"label":"Description","value":"US348MDE.TXT","file":true},
        \\{"label":"Language","value":"eng","depth":1}],
        \\"footnote":"US5MD1MC  ·  US,US,graph,Chart 12283"}
    );

    try std.testing.expectEqualStrings("LIGHTS", std.mem.span(rec.report.cls));
    try std.testing.expectEqualStrings("US5MD1MC", std.mem.span(rec.report.chart));
    try std.testing.expectEqualStrings("Fl G 4s", std.mem.span(rec.report.title));
    try std.testing.expectEqualStrings("Light", std.mem.span(rec.report.subtitle));
    try std.testing.expectEqualStrings("Light", std.mem.span(rec.report.chip));
    try std.testing.expectEqualStrings("US5MD1MC  ·  US,US,graph,Chart 12283",
        std.mem.span(rec.report.footnote));
    try std.testing.expectEqual(Empty.reads, rec.report.empty);

    try std.testing.expectEqual(@as(usize, 1), rec.notes_len);
    try std.testing.expectEqualStrings("Seasonal aid", std.mem.span(rec.notes[0]));

    try std.testing.expectEqual(@as(usize, 3), rec.rows_len);
    try std.testing.expectEqualStrings("Colour", std.mem.span(rec.rows[0].label));
    try std.testing.expectEqualStrings("green", std.mem.span(rec.rows[0].value));
    try std.testing.expectEqual(@as(c_int, 0), rec.rows[0].depth);
    try std.testing.expectEqual(@as(c_int, 0), rec.rows[0].file);
    // A row the engine marked as a file keeps the mark, and it is not a picture.
    try std.testing.expectEqual(@as(c_int, 1), rec.rows[1].file);
    try std.testing.expectEqual(@as(c_int, 0), rec.rows[1].picture);
    // A sub-attribute indents under its heading.
    try std.testing.expectEqual(@as(c_int, 1), rec.rows[2].depth);
}

test "the fold rides beside the page, in the cell's own words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw =
        \\{"VALSOU":"5.4","PICREP":"US348MDE.TIF"}
    ;
    const rec = try record(a, a, .{ .cls = "SOUNDG", .chart = "C", .s57 = "" }, raw,
        \\{"title":"17 ft","rows":[{"label":"Depth","value":"17 ft"}]}
    );

    // The page states the depth in the mariner's unit; the fold keeps the
    // metres the cell wrote.
    try std.testing.expectEqualStrings("17 ft", std.mem.span(rec.rows[0].value));
    try std.testing.expectEqual(@as(usize, 2), rec.source_len);
    try std.testing.expectEqualStrings("PICREP", std.mem.span(rec.source[0].label));
    try std.testing.expectEqual(@as(c_int, 1), rec.source[0].file);
    try std.testing.expectEqual(@as(c_int, 1), rec.source[0].picture);
    try std.testing.expectEqualStrings("VALSOU", std.mem.span(rec.source[1].label));
    try std.testing.expectEqualStrings("5.4", std.mem.span(rec.source[1].value));
    // And the whole payload stays reachable for the clipboard.
    try std.testing.expectEqualStrings(raw, std.mem.span(rec.report.raw));
}

test "a page that says nothing says why" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = Feature{ .cls = "DEPARE", .chart = "US5MD1MC", .s57 = "" };

    const none = try record(a, a, f, "{}", "{\"title\":\"Depth area\",\"empty\":\"none\"}");
    try std.testing.expectEqual(Empty.no_attributes, none.report.empty);

    const source = try record(a, a, f, "{}", "{\"title\":\"Depth area\",\"empty\":\"source\"}");
    try std.testing.expectEqual(Empty.source_only, source.report.empty);

    const reads = try record(a, a, f, "{}", "{\"title\":\"Depth area\"}");
    try std.testing.expectEqual(Empty.reads, reads.report.empty);
}

test "a page that does not parse leaves the class and the cell on screen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try record(a, a,
        .{ .cls = "OBSTRN", .chart = "US5MD1MC", .s57 = "" },
        "{\"CATOBS\":\"6\"}", "not json at all");

    try std.testing.expectEqualStrings("OBSTRN", std.mem.span(rec.report.title));
    try std.testing.expectEqualStrings("OBSTRN", std.mem.span(rec.report.chip));
    try std.testing.expectEqualStrings("US5MD1MC", std.mem.span(rec.report.footnote));
    try std.testing.expectEqualStrings("", std.mem.span(rec.report.subtitle));
    try std.testing.expectEqual(@as(usize, 0), rec.notes_len);
    try std.testing.expectEqual(@as(usize, 0), rec.rows_len);
    // The fold still shows everything the cell wrote.
    try std.testing.expectEqual(@as(usize, 1), rec.source_len);
    try std.testing.expectEqualStrings("CATOBS", std.mem.span(rec.source[0].label));
}

test "a record's public struct is the record's own address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = try a.create(ReportRec);
    rec.* = try record(a, a, .{ .cls = "LNDARE", .chart = "C", .s57 = "" }, "{}", "{}");
    try std.testing.expectEqual(rec, recOf(&rec.report));
}
