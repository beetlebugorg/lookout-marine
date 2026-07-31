//! What a cursor pick reports, and in what order.
//!
//! The engine returns the features under the cursor in DRAW order, which puts
//! the land area and the depth area before the light that was tapped. Every
//! shell would otherwise re-invent the same three rules, so they live here and
//! reach the shells through `lookout_pick_ranked`:
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
