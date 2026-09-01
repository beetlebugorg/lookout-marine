//! The rules for turning raw cells into charts the app can draw.
//!
//! tile57 does the work. What is here is what four shells each decided for
//! themselves: the order the cells go in, where each output lands, which
//! directory a set's charts are prepared into, how many workers to run, and how
//! often to report progress.
//!
//! This file is pure. The threads, the file system and the tile57 calls stay in
//! the shell, which knows its own platform.

const std = @import("std");

/// What has to happen to one file before it can be drawn.
pub const Prepare = enum(c_int) {
    /// An S-57 or S-101 cell: parse the survey and portray it.
    cell = 0,
    /// A BSB/KAP sheet: decode the picture and warp it.
    sheet = 1,
    /// Already a chart, and only has to come out of the archive.
    lift = 2,
};

/// One file to prepare, as the scan found it.
pub const Item = struct {
    /// The absolute path, or the entry name inside an archive.
    path: []const u8,
    /// The dataset name, such as US5MD1MC.pmtiles.
    name: []const u8,
    /// 1 to 6, or 0 when the name has no usage band.
    band: u8,
    work: Prepare,
};

/// How many workers to run, given the cores available.
///
/// A memory bound, not a speed dial: each worker holds a whole cell's working
/// set, so the cap is what stops a big cell set from filling memory.
///
/// Every core otherwise. Holding one back does not buy a smooth window: the
/// bake threads are not scheduled below the render loop, so a saturated machine
/// is choppy either way, and the mariner is waiting on this and nothing else.
pub const max_workers: u32 = 8;

pub fn workers(cores: u32) u32 {
    return @max(1, @min(max_workers, cores));
}

/// How often a bake reports progress, in milliseconds. A 7,000 cell import
/// would otherwise post 7,000 times and lay out the panel 7,000 times, against
/// a machine with nothing spare.
pub const post_ms: i64 = 200;

/// True when a report at `now` should reach the shell. The last one always
/// lands, whatever the rate.
pub fn shouldPost(last_ms: i64, now_ms: i64, done: usize, total: usize) bool {
    if (done == total) return true;
    return now_ms - last_ms >= post_ms;
}

/// The prefix a directory being deleted is renamed to. Removing a set renames
/// first and deletes behind: a 7,224-chart library is 36,000 files, measured at
/// 3.7 seconds of disk work.
pub const trash_prefix = ".removing-";

/// True when `name` is a directory a removal left behind, for the sweep at
/// launch.
pub fn isTrash(name: []const u8) bool {
    return std.mem.startsWith(u8, name, trash_prefix);
}

// ---- the order ----------------------------------------------------------------

/// Where one item goes in the run. Lower first.
///
/// Coarse band first: Overview, General, Coastal, then the harbor detail. A
/// mariner who cancels half way then has charts that cover the whole passage at
/// a usable scale. The other order gives them every berth in one river and
/// nothing between rivers.
///
/// Sheets after the survey, which is what a mariner needs to sail and what they
/// compare a picture against. Anything only being lifted out of an archive
/// last, because it is the cheapest and the least urgent.
pub fn before(a: Item, b: Item) bool {
    const ra = @intFromEnum(a.work);
    const rb = @intFromEnum(b.work);
    if (ra != rb) return ra < rb;
    if (a.band != b.band) return a.band < b.band;
    // By name after that, so a run is repeatable.
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Sort `items` into the order they are prepared in.
pub fn order(items: []Item) void {
    std.mem.sort(Item, items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return before(a, b);
        }
    }.lt);
}

// ---- where the output goes ----------------------------------------------------

/// True when `path` is under `root`, the directory this app prepares into.
///
/// The boundary matters beyond tidiness: what is under it was made from the
/// mariner's cells and can be made again, so removing a set may delete it. What
/// is outside is the mariner's own and is never touched.
pub fn isDerived(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return false;
    if (std.mem.eql(u8, path, root)) return true;
    return path.len > root.len and
        std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// The name of the directory `source` is prepared into, under the charts root.
///
/// An archive names its directory without the .zip: what comes out of
/// All_ENCs.zip is charts, and "All_ENCs.zip/" as a folder full of them reads
/// like a mistake.
pub fn preparedName(source: []const u8) []const u8 {
    const base = std.fs.path.basename(source);
    if (!isArchive(source)) return base;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

/// True for a chart set that arrives as one archive.
pub fn isArchive(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".zip");
}

/// Where one prepared chart is written, under `out_dir`.
///
/// Every prepared chart goes in a directory of its own name, which is the
/// layout tile57's own bake writes and the layout an exchange set uses. Two
/// things depend on it. The raster layer reads a provider from the directory
/// ABOVE, so a folder of 900 sheets written flat becomes 900 providers and 900
/// switches instead of one. And a cell carries the text and pictures it
/// references beside it, which the engine only writes when the chart has a
/// directory to hold them: those files are named per exchange set, not per
/// chart, so charts written flat would share one manifest and overwrite each
/// other's.
///
/// From an ARCHIVE the output mirrors the entry's own path, so what comes out
/// is laid out like what went in and a cell's referenced text lands beside the
/// right chart.
///
/// A LIFT keeps its own name: an .mbtiles is a chart already, and renaming it
/// to .pmtiles would be a lie about what is in the file.
pub fn outputPath(
    a: std.mem.Allocator,
    out_dir: []const u8,
    source: []const u8,
    item: Item,
) ![]u8 {
    const stem = stemOf(item.name);
    const base = if (isArchive(source))
        try std.fs.path.join(a, &.{ out_dir, std.fs.path.dirname(item.path) orelse "" })
    else
        try a.dupe(u8, out_dir);
    defer a.free(base);

    // The chart's own directory, unless the mirrored path IS one already, which
    // it is for every exchange set: they put each cell in a directory of its
    // name. Appending it again would give US1EEZ3M/US1EEZ3M/US1EEZ3M.pmtiles.
    const dir = if (item.work == .lift or std.mem.eql(u8, std.fs.path.basename(base), stem))
        try a.dupe(u8, base)
    else
        try std.fs.path.join(a, &.{ base, stem });
    defer a.free(dir);

    const file = if (item.work == .lift)
        try a.dupe(u8, std.fs.path.basename(item.name))
    else
        try std.fmt.allocPrint(a, "{s}.pmtiles", .{stem});
    defer a.free(file);

    return std.fs.path.join(a, &.{ dir, file });
}

fn stemOf(name: []const u8) []const u8 {
    const base = std.fs.path.basename(name);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

// ---- tests ---------------------------------------------------------------------

const t = std.testing;

fn one(name: []const u8, band: u8, work: Prepare) Item {
    return .{ .path = name, .name = name, .band = band, .work = work };
}

test "the run goes coarse band first, then by name" {
    var items = [_]Item{
        one("US5MD1MC.000", 5, .cell),
        one("US1EEZ3M.000", 1, .cell),
        one("US4MD1PM.000", 4, .cell),
        one("US5AA1AA.000", 5, .cell),
    };
    order(&items);
    try t.expectEqualStrings("US1EEZ3M.000", items[0].name);
    try t.expectEqualStrings("US4MD1PM.000", items[1].name);
    // Same band, so by name, which makes a run repeatable.
    try t.expectEqualStrings("US5AA1AA.000", items[2].name);
    try t.expectEqualStrings("US5MD1MC.000", items[3].name);
}

test "the survey goes before the sheets, and a lift goes last" {
    var items = [_]Item{
        one("photo.KAP", 0, .sheet),
        one("ready.pmtiles", 6, .lift),
        one("US5MD1MC.000", 5, .cell),
    };
    order(&items);
    try t.expectEqual(Prepare.cell, items[0].work);
    try t.expectEqual(Prepare.sheet, items[1].work);
    try t.expectEqual(Prepare.lift, items[2].work);
}

test "the worker count is a memory bound, and at least one" {
    try t.expectEqual(@as(u32, 1), workers(0));
    try t.expectEqual(@as(u32, 1), workers(1));
    try t.expectEqual(@as(u32, 4), workers(4));
    try t.expectEqual(@as(u32, max_workers), workers(max_workers));
    try t.expectEqual(@as(u32, max_workers), workers(64));
}

test "progress posts at the cadence, and the last one always lands" {
    try t.expect(!shouldPost(1000, 1100, 3, 100));
    try t.expect(shouldPost(1000, 1200, 3, 100));
    try t.expect(shouldPost(1000, 1000, 100, 100));
}

test "only what this app prepared is derived" {
    const root = "/Users/m/Library/Application Support/Lookout/Charts";
    try t.expect(isDerived(root, root));
    try t.expect(isDerived(root, root ++ "/Set A/US5MD1MC/US5MD1MC.pmtiles"));
    try t.expect(!isDerived(root, "/Users/m/Charts/US5MD1MC.000"));
    // A directory whose name merely starts with the root's is not under it.
    try t.expect(!isDerived(root, root ++ "-old/x"));
    try t.expect(!isDerived("", "/anything"));
}

test "a set is prepared into a directory of its own name" {
    try t.expectEqualStrings("ENC_ROOT", preparedName("/Users/m/Charts/ENC_ROOT"));
    // The archive's charts, without the .zip.
    try t.expectEqualStrings("All_ENCs", preparedName("/Users/m/Downloads/All_ENCs.zip"));
    try t.expectEqualStrings("All_ENCs", preparedName("/Users/m/Downloads/All_ENCs.ZIP"));
}

test "a directory being deleted is named so the sweep finds it" {
    try t.expect(isTrash(trash_prefix ++ "0BFE-11EE"));
    try t.expect(!isTrash("ENC_ROOT"));
}

test "a prepared chart goes in a directory of its own name" {
    const a = t.allocator;
    const out = "/support/Lookout/Charts/ENC_ROOT";
    const p = try outputPath(a, out, "/Users/m/Charts/ENC_ROOT", one("US5MD1MC.000", 5, .cell));
    defer a.free(p);
    try t.expectEqualStrings(out ++ "/US5MD1MC/US5MD1MC.pmtiles", p);
}

test "an archive's output mirrors the entry's own path" {
    const a = t.allocator;
    const out = "/support/Lookout/Charts/All_ENCs";
    // The entry name inside the archive, which exchange sets lay out as
    // ENC_ROOT/<cell>/<cell>.000.
    var it = one("US5MD1MC.000", 5, .cell);
    it.path = "ENC_ROOT/US5MD1MC/US5MD1MC.000";
    const p = try outputPath(a, out, "/Users/m/Downloads/All_ENCs.zip", it);
    defer a.free(p);
    // The mirrored directory IS already the cell's own name, so it is not
    // appended twice.
    try t.expectEqualStrings(out ++ "/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles", p);
}

test "a lift keeps the name the file already has" {
    const a = t.allocator;
    const out = "/support/Lookout/Charts/Imagery";
    var it = one("ncds_08.mbtiles", 0, .lift);
    it.path = "pictures/ncds_08.mbtiles";
    const p = try outputPath(a, out, "/Users/m/Downloads/Imagery.zip", it);
    defer a.free(p);
    // An .mbtiles is a chart already, and no directory of its own.
    try t.expectEqualStrings(out ++ "/pictures/ncds_08.mbtiles", p);
}
