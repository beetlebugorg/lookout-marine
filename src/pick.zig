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
