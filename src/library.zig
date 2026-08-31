//! What a folder of charts holds.
//!
//! A chart folder holds files that are not charts. An exchange set carries
//! CATALOG.031 and a README. A bake leaves partition.tpart beside the archives.
//! A cell carries the text files its features reference. The app must name each
//! file before it tries to open it, or it offers the mariner a dead end.
//!
//! The verdict has two parts. This file makes the part that needs only the
//! name. A .pmtiles archive gets its second verdict from tile57, which opens
//! the archive and reports whether it carries a vector chart this build draws.
//!
//! S-57 names a dataset with 8 characters: 2 for the producer, 1 digit for the
//! usage band, 5 the producer assigns. The extension is 000 for the base cell,
//! and 001 upward for the updates that follow it. An update never opens alone.
//! It applies to its base cell, and tile57 reads the chain when it bakes.

const std = @import("std");
const format = @import("shell/format.zig");

/// What a file is, from its name alone.
pub const Kind = enum {
    /// A baked archive. It opens as a chart if tile57 accepts it.
    baked,
    /// An S-57 base cell. It bakes before it draws.
    source,
    /// An S-57 update file. It bakes with its base cell.
    update,
    /// A picture chart. It belongs in the raster chart list.
    raster,
    /// A picture chart in a format that bakes first.
    raster_source,
    /// Not a chart.
    other,
};

/// The usage bands S-57 numbers 1 to 6, in the words the readouts use.
pub const bandName = format.bandName;

/// The name of the file, without its directory.
pub fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |i| return path[i + 1 ..];
    return path;
}

/// The part of `basename` before the last dot, and the part after it. A name
/// with no dot has an empty extension.
fn split(basename: []const u8) struct { stem: []const u8, ext: []const u8 } {
    const i = std.mem.lastIndexOfScalar(u8, basename, '.') orelse
        return .{ .stem = basename, .ext = "" };
    return .{ .stem = basename[0..i], .ext = basename[i + 1 ..] };
}

/// True when `stem` is an S-57 dataset name: 2 letters for the producer, a
/// usage band digit of 1 to 6, then 5 characters the producer assigns.
///
/// CATALOG.031 passes an extension test for an update file, so the name test
/// is what rejects it. Its third character is a letter.
pub fn isDatasetName(stem: []const u8) bool {
    if (stem.len != 8) return false;
    if (!std.ascii.isAlphabetic(stem[0]) or !std.ascii.isAlphabetic(stem[1])) return false;
    if (stem[2] < '1' or stem[2] > '6') return false;
    for (stem[3..]) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// The producing agency's code: the first two characters of an S-57 dataset
/// name, which the standard reserves for it (US5MD12M -> US). Null when the
/// name is not a dataset name.
///
/// This is what lets a library be named by WHO MADE IT rather than by the
/// folder it arrived in — "All_ENCs.zip" and "ENC_ROOT" say nothing, and the
/// charts themselves know.
pub fn producerCode(stem: []const u8) ?[]const u8 {
    if (!isDatasetName(stem)) return null;
    return stem[0..2];
}

/// The usage band an S-57 dataset name carries, or null when the name is not
/// a dataset name.
pub fn usageBand(stem: []const u8) ?u8 {
    if (!isDatasetName(stem)) return null;
    return stem[2] - '0';
}

/// True when `ext` is a 3 digit S-57 extension of `low` to `high`.
fn isDigitExt(ext: []const u8, low: u16, high: u16) bool {
    if (ext.len != 3) return false;
    const n = std.fmt.parseInt(u16, ext, 10) catch return false;
    return n >= low and n <= high;
}

/// What a file is, from its name.
pub fn classify(basename: []const u8) Kind {
    const p = split(basename);
    if (std.ascii.eqlIgnoreCase(p.ext, "pmtiles")) return .baked;
    if (std.ascii.eqlIgnoreCase(p.ext, "mbtiles")) return .raster;
    if (std.ascii.eqlIgnoreCase(p.ext, "kap") or std.ascii.eqlIgnoreCase(p.ext, "bsb"))
        return .raster_source;
    if (!isDatasetName(p.stem)) return .other;
    if (isDigitExt(p.ext, 0, 0)) return .source;
    if (isDigitExt(p.ext, 1, 999)) return .update;
    return .other;
}

/// The cell name a chart file carries, or null when the name is not a dataset
/// name. A bake writes the cell name as the archive stem, so this answers for
/// both a source cell and a baked archive.
pub fn cellName(basename: []const u8) ?[]const u8 {
    const p = split(basename);
    return if (isDatasetName(p.stem)) p.stem else null;
}

// ---- scanning a folder ------------------------------------------------------

/// What tile57 reports about a baked archive.
pub const Facts = struct {
    /// The compilation scale the bake embedded. 0 when the archive carries none.
    scale: i32 = 0,
    /// West, south, east, north. Null when the archive carries no bounds.
    bounds: ?[4]f64 = null,
};

/// What a baked archive turned out to hold.
pub const Verdict = enum {
    /// A vector chart this build draws.
    chart,
    /// Images, not vector tiles. A baked RNC or imagery. It draws, through
    /// the raster chart list.
    raster,
    /// Neither. A foreign archive, or one that does not open.
    no,
};

/// Opens a baked archive and reports what it holds. capi.zig binds this to
/// tile57, which is the only thing that can tell a chart from a picture: both
/// open, and both carry coverage and a scale.
pub const Verify = *const fn (ctx: ?*anyopaque, path: [:0]const u8, out: *Facts) Verdict;

/// One chart file the scan found.
pub const Cell = struct {
    /// The absolute path, owned by the Scan.
    path: [:0]u8,
    /// The 8 character dataset name. A slice of `path`.
    name: []const u8,
    kind: Kind,
    /// 1 to 6. 0 when the name carries no usage band.
    band: u8,
    bytes: u64,
    facts: Facts = .{},
    /// False when the file carries a chart name and tile57 refused it.
    usable: bool = true,
};

/// What one folder holds.
pub const Scan = struct {
    alloc: std.mem.Allocator,
    /// The folder or file the scan started from.
    root: []u8,
    /// The baked archives and the source cells, by name.
    cells: []Cell,
    /// The picture charts, which belong in the raster chart list.
    raster: []Cell,
    /// S-57 update files. Each one bakes with its base cell.
    updates: usize,
    /// Files that are not charts.
    other: usize,
    /// Files that carry a chart name and that tile57 refused.
    refused: usize,
    /// The agency every chart here came from, when they all came from one.
    /// Null when they disagree, or when nothing here carries a dataset name:
    /// a mixed folder has no one name, and picking one of them would be wrong.
    producer: ?[2]u8 = null,

    pub fn deinit(self: *Scan) void {
        for (self.cells) |c| self.alloc.free(c.path);
        for (self.raster) |c| self.alloc.free(c.path);
        self.alloc.free(self.cells);
        self.alloc.free(self.raster);
        self.alloc.free(self.root);
    }

    /// How many cells bake before they draw.
    pub fn sourceCount(self: *const Scan) usize {
        var n: usize = 0;
        for (self.cells) |c| if (c.kind == .source) {
            n += 1;
        };
        return n;
    }

    /// The bytes of every cell.
    pub fn totalBytes(self: *const Scan) u64 {
        var n: u64 = 0;
        for (self.cells) |c| n += c.bytes;
        return n;
    }
};

/// The agency every cell agrees on, or null. A set of charts from two offices
/// has no single name, and one of the two would be a lie about the rest.
fn agreedProducer(cells: []const Cell) ?[2]u8 {
    var found: ?[2]u8 = null;
    for (cells) |c| {
        const code = producerCode(c.name) orelse return null;
        const two: [2]u8 = .{ code[0], code[1] };
        if (found) |f| {
            if (!std.mem.eql(u8, &f, &two)) return null;
        } else found = two;
    }
    return found;
}

/// Walk `root` and name everything under it. `root` is a folder or a single
/// file. A folder is walked to the bottom, because a bake mirrors the exchange
/// set's tree and a library is nested, not flat.
///
/// `verify` gives the second verdict on each baked archive. Pass null to take
/// the name as the whole answer, which is what a caller without the engine
/// does.
pub fn scan(
    alloc: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    verify: ?Verify,
    verify_ctx: ?*anyopaque,
) !Scan {
    var cells: std.ArrayList(Cell) = .empty;
    var raster: std.ArrayList(Cell) = .empty;
    errdefer {
        for (cells.items) |c| alloc.free(c.path);
        for (raster.items) |c| alloc.free(c.path);
        cells.deinit(alloc);
        raster.deinit(alloc);
    }
    var counts = struct { updates: usize = 0, other: usize = 0, refused: usize = 0 }{};

    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, root, .{ .iterate = true })) |*d| {
        var dir = d.*;
        defer dir.close(io);
        var w = try dir.walk(alloc);
        defer w.deinit();
        while (try w.next(io)) |e| {
            if (e.kind == .directory) continue;
            const path = try std.fs.path.joinZ(alloc, &.{ root, e.path });
            errdefer alloc.free(path);
            try take(alloc, path, e.basename, fileSize(io, path), verify, verify_ctx, &cells, &raster, &counts);
        }
    } else |_| {
        // A single file. The open panel takes one archive as readily as a
        // folder of them.
        const path = try alloc.dupeZ(u8, root);
        errdefer alloc.free(path);
        try take(alloc, path, baseName(root), fileSize(io, path), verify, verify_ctx, &cells, &raster, &counts);
    }

    const by_name = struct {
        fn lessThan(_: void, a: Cell, b: Cell) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan;
    std.mem.sort(Cell, cells.items, {}, by_name);
    std.mem.sort(Cell, raster.items, {}, by_name);

    const owned_cells = try cells.toOwnedSlice(alloc);
    return .{
        .alloc = alloc,
        .root = try alloc.dupe(u8, root),
        .cells = owned_cells,
        .raster = try raster.toOwnedSlice(alloc),
        .updates = counts.updates,
        .other = counts.other,
        .refused = counts.refused,
        .producer = agreedProducer(owned_cells),
    };
}

/// One entry of an archive's listing: the name as stored, and what it weighs
/// unpacked.
pub const Entry = struct {
    name: []const u8,
    bytes: u64 = 0,
};

/// `scan` over an ARCHIVE's entry names instead of a folder's files. `root` is
/// the archive itself, and each Cell's `path` is the ENTRY NAME — which is
/// what the engine's zip bake takes back, so what this reports can be handed
/// straight to it.
///
/// There is no verify pass. Verifying means opening the archive and asking the
/// engine what it is, and an entry has no path to open; inside a .zip a name
/// is the whole answer. So a `.pmtiles` in here is believed rather than
/// checked, and the refused count is always zero — a foreign archive that a
/// folder scan would reject is only found when it is read.
pub fn scanEntries(alloc: std.mem.Allocator, root: []const u8, entries: []const Entry) !Scan {
    var cells: std.ArrayList(Cell) = .empty;
    var raster: std.ArrayList(Cell) = .empty;
    errdefer {
        for (cells.items) |c| alloc.free(c.path);
        for (raster.items) |c| alloc.free(c.path);
        cells.deinit(alloc);
        raster.deinit(alloc);
    }
    var counts = struct { updates: usize = 0, other: usize = 0, refused: usize = 0 }{};

    for (entries) |e| {
        if (e.name.len == 0 or e.name[e.name.len - 1] == '/') continue;
        const path = try alloc.dupeZ(u8, e.name);
        errdefer alloc.free(path);
        try take(alloc, path, baseName(e.name), e.bytes, null, null, &cells, &raster, &counts);
    }

    const by_name = struct {
        fn lessThan(_: void, a: Cell, b: Cell) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan;
    std.mem.sort(Cell, cells.items, {}, by_name);
    std.mem.sort(Cell, raster.items, {}, by_name);

    const owned_cells = try cells.toOwnedSlice(alloc);
    return .{
        .alloc = alloc,
        .root = try alloc.dupe(u8, root),
        .cells = owned_cells,
        .raster = try raster.toOwnedSlice(alloc),
        .updates = counts.updates,
        .other = counts.other,
        .refused = counts.refused,
        .producer = agreedProducer(owned_cells),
    };
}

/// Name one file and put it on the list it belongs on. `path` is owned by this
/// function from here down: it goes on a list or it is freed.
fn take(
    alloc: std.mem.Allocator,
    path: [:0]u8,
    basename: []const u8,
    bytes: u64,
    verify: ?Verify,
    verify_ctx: ?*anyopaque,
    cells: *std.ArrayList(Cell),
    raster: *std.ArrayList(Cell),
    counts: anytype,
) !void {
    const kind = classify(basename);
    switch (kind) {
        .other => {
            alloc.free(path);
            counts.other += 1;
            return;
        },
        .update => {
            alloc.free(path);
            counts.updates += 1;
            return;
        },
        else => {},
    }

    const name_start = path.len - basename.len;
    const stem = cellName(basename);
    var cell: Cell = .{
        .path = path,
        .name = if (stem) |s| path[name_start .. name_start + s.len] else path[name_start..],
        .kind = kind,
        .band = if (stem) |s| usageBand(s) orelse 0 else 0,
        .bytes = bytes,
    };

    if (kind == .raster or kind == .raster_source) {
        try raster.append(alloc, cell);
        return;
    }

    // A baked archive keeps its chart name whatever it holds inside. Only the
    // engine can tell a chart from a picture archive or a foreign bake.
    if (kind == .baked) {
        if (verify) |v| {
            var facts: Facts = .{};
            switch (v(verify_ctx, path, &facts)) {
                .chart => cell.facts = facts,
                .raster => {
                    // A baked RNC. It is a chart, and the raster chart list is
                    // where it draws.
                    cell.kind = .raster;
                    try raster.append(alloc, cell);
                    return;
                },
                .no => {
                    counts.refused += 1;
                    alloc.free(path);
                    return;
                },
            }
        }
    }
    try cells.append(alloc, cell);
}

fn fileSize(io: std.Io, path: [:0]const u8) u64 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer f.close(io);
    const st = f.stat(io) catch return 0;
    return st.size;
}

// ---- the JSON a shell reads -------------------------------------------------

fn writeJsonString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
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

fn writeCell(out: *std.ArrayList(u8), alloc: std.mem.Allocator, c: Cell) !void {
    try out.appendSlice(alloc, "{\"path\":");
    try writeJsonString(out, alloc, c.path);
    try out.appendSlice(alloc, ",\"name\":");
    try writeJsonString(out, alloc, c.name);
    try out.print(alloc, ",\"kind\":\"{s}\",\"band\":{d},\"bytes\":{d}", .{
        @tagName(c.kind), c.band, c.bytes,
    });
    if (c.band >= 1 and c.band <= 6) {
        try out.appendSlice(alloc, ",\"bandName\":");
        try writeJsonString(out, alloc, bandName(c.band));
    }
    if (c.facts.scale != 0) try out.print(alloc, ",\"scale\":{d}", .{c.facts.scale});
    if (c.facts.bounds) |b| try out.print(
        alloc,
        ",\"west\":{d},\"south\":{d},\"east\":{d},\"north\":{d}",
        .{ b[0], b[1], b[2], b[3] },
    );
    try out.append(alloc, '}');
}

/// The scan as JSON, for a shell to read. The caller owns the bytes.
///
/// NUL terminated. The length is what a host should use, but a host that
/// reaches for strlen must not read past the answer.
pub fn toJson(alloc: std.mem.Allocator, s: *const Scan) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"root\":");
    try writeJsonString(&out, alloc, s.root);
    try out.print(alloc, ",\"updates\":{d},\"other\":{d},\"refused\":{d}", .{
        s.updates, s.other, s.refused,
    });
    // Absent rather than empty when the charts disagree: a host that reads a
    // producer knows every chart here came from it.
    if (s.producer) |p| {
        try out.appendSlice(alloc, ",\"producer\":");
        try writeJsonString(&out, alloc, &p);
    }
    try out.print(alloc, ",\"sources\":{d},\"bytes\":{d},\"cells\":[", .{
        s.sourceCount(), s.totalBytes(),
    });
    for (s.cells, 0..) |c, i| {
        if (i > 0) try out.append(alloc, ',');
        try writeCell(&out, alloc, c);
    }
    try out.appendSlice(alloc, "],\"raster\":[");
    for (s.raster, 0..) |c, i| {
        if (i > 0) try out.append(alloc, ',');
        try writeCell(&out, alloc, c);
    }
    try out.appendSlice(alloc, "]}");
    return out.toOwnedSliceSentinel(alloc, 0);
}

test "a baked archive and a source cell are charts" {
    try std.testing.expectEqual(Kind.baked, classify("US5MD1MC.pmtiles"));
    try std.testing.expectEqual(Kind.source, classify("US5MD1MC.000"));
    try std.testing.expectEqual(Kind.update, classify("US5MD1MC.004"));
}

test "the files beside a chart are not charts" {
    // Every one of these reached the recent list by being picked in the open
    // panel. None of them opens.
    try std.testing.expectEqual(Kind.other, classify("CATALOG.031"));
    try std.testing.expectEqual(Kind.other, classify("partition.tpart"));
    try std.testing.expectEqual(Kind.other, classify("delete_old_cluster.sh"));
    try std.testing.expectEqual(Kind.other, classify("README.TXT"));
    try std.testing.expectEqual(Kind.other, classify("US348MCA.TXT"));
    try std.testing.expectEqual(Kind.other, classify("US5MD1MC.pmtiles.sha"));
    try std.testing.expectEqual(Kind.other, classify("index.json"));
}

test "a picture chart is named as one" {
    // The mariner picked a chart. It is the other kind, and the open panel
    // for raster charts takes it.
    try std.testing.expectEqual(Kind.raster, classify("ncds_08.mbtiles"));
    try std.testing.expectEqual(Kind.raster_source, classify("11013_1.KAP"));
}

test "a dataset name carries the producer and the usage band" {
    try std.testing.expect(isDatasetName("US5MD1MC"));
    try std.testing.expect(isDatasetName("GB5X01SE")); // any producer, not only US
    try std.testing.expect(!isDatasetName("US5MD1M")); // 7 characters
    try std.testing.expect(!isDatasetName("US5MD1MCX")); // 9 characters
    try std.testing.expect(!isDatasetName("US7MD1MC")); // band 7 does not exist
    try std.testing.expect(!isDatasetName("U55MD1MC")); // producer is 2 letters
    try std.testing.expect(!isDatasetName("CATALOG.")); // the third character is a letter

    try std.testing.expectEqual(@as(?u8, 5), usageBand("US5MD1MC"));
    try std.testing.expectEqual(@as(?u8, 1), usageBand("US1EEZ1M"));
    try std.testing.expectEqual(@as(?u8, null), usageBand("partition"));
}

test "a cell name comes off either kind of chart file" {
    try std.testing.expectEqualStrings("US5MD1MC", cellName("US5MD1MC.000").?);
    try std.testing.expectEqualStrings("US5MD1MC", cellName("US5MD1MC.pmtiles").?);
    try std.testing.expectEqual(@as(?[]const u8, null), cellName("partition.tpart"));
}

test "the band names match the readouts" {
    try std.testing.expectEqualStrings("Overview", bandName(1));
    try std.testing.expectEqualStrings("Harbor", bandName(5));
    try std.testing.expectEqualStrings("Berthing", bandName(6));
}

test "a name with no directory is its own base name" {
    try std.testing.expectEqualStrings("US5MD1MC.000", baseName("/a/b/US5MD1MC.000"));
    try std.testing.expectEqualStrings("US5MD1MC.000", baseName("US5MD1MC.000"));
}

// ---- the scan ---------------------------------------------------------------

const t = std.testing;

/// An exchange set beside a bake, with the files that are not charts. Every
/// name here is one the open panel accepted at least once.
fn writeTestTree(tmp: *t.TmpDir, io: std.Io) !void {
    try tmp.dir.createDirPath(io, "US5MD1MC");
    try tmp.dir.createDirPath(io, "US4MD1PM");
    const files = [_]struct { p: []const u8, d: []const u8 }{
        .{ .p = "US5MD1MC/US5MD1MC.000", .d = "cell" },
        .{ .p = "US5MD1MC/US5MD1MC.001", .d = "update" },
        .{ .p = "US5MD1MC/US348MCA.TXT", .d = "note" },
        .{ .p = "US4MD1PM/US4MD1PM.pmtiles", .d = "archive" },
        .{ .p = "CATALOG.031", .d = "catalog" },
        .{ .p = "README.TXT", .d = "readme" },
        .{ .p = "partition.tpart", .d = "sidecar" },
        .{ .p = "ncds_08.mbtiles", .d = "picture" },
    };
    for (files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f.p, .data = f.d });
}

fn tmpRoot(tmp: *t.TmpDir) ![]u8 {
    return std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "a scan finds the charts and counts the rest" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try writeTestTree(&tmp, io);
    const root = try tmpRoot(&tmp);
    defer t.allocator.free(root);

    var s = try scan(t.allocator, io, root, null, null);
    defer s.deinit();

    try t.expectEqual(@as(usize, 2), s.cells.len);
    try t.expectEqualStrings("US4MD1PM", s.cells[0].name);
    try t.expectEqual(Kind.baked, s.cells[0].kind);
    try t.expectEqual(@as(u8, 4), s.cells[0].band);
    try t.expectEqualStrings("US5MD1MC", s.cells[1].name);
    try t.expectEqual(Kind.source, s.cells[1].kind);
    try t.expectEqual(@as(u8, 5), s.cells[1].band);

    // The picture chart is found, and it is kept apart from the ENC.
    try t.expectEqual(@as(usize, 1), s.raster.len);
    try t.expectEqualStrings("ncds_08.mbtiles", baseName(s.raster[0].path));

    try t.expectEqual(@as(usize, 1), s.updates);
    try t.expectEqual(@as(usize, 4), s.other); // the TXTs, the catalog, the sidecar
    try t.expectEqual(@as(usize, 1), s.sourceCount());
    try t.expect(s.totalBytes() > 0);
}

/// Refuses every archive, as tile57 does for a foreign bake.
fn refuseAll(_: ?*anyopaque, _: [:0]const u8, _: *Facts) Verdict {
    return .no;
}

/// Accepts every archive and reports one Annapolis harbor chart.
fn acceptAll(_: ?*anyopaque, _: [:0]const u8, out: *Facts) Verdict {
    out.* = .{ .scale = 12000, .bounds = .{ -76.6, 38.9, -76.4, 39.0 } };
    return .chart;
}

/// Every archive holds images, as a baked RNC does.
fn rasterAll(_: ?*anyopaque, _: [:0]const u8, _: *Facts) Verdict {
    return .raster;
}

test "an archive the engine refuses is not offered as a chart" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try writeTestTree(&tmp, io);
    const root = try tmpRoot(&tmp);
    defer t.allocator.free(root);

    var s = try scan(t.allocator, io, root, refuseAll, null);
    defer s.deinit();

    // The source cell stays. Only the archive needed the engine's verdict.
    try t.expectEqual(@as(usize, 1), s.cells.len);
    try t.expectEqualStrings("US5MD1MC", s.cells[0].name);
    try t.expectEqual(@as(usize, 1), s.refused);
}

test "a baked RNC joins the raster charts, not the ENC" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try writeTestTree(&tmp, io);
    const root = try tmpRoot(&tmp);
    defer t.allocator.free(root);

    var s = try scan(t.allocator, io, root, rasterAll, null);
    defer s.deinit();

    // The archive moves across. The source cell is untouched: it never went to
    // the engine.
    try t.expectEqual(@as(usize, 1), s.cells.len);
    try t.expectEqual(Kind.source, s.cells[0].kind);
    try t.expectEqual(@as(usize, 2), s.raster.len); // the .mbtiles and the archive
    try t.expectEqual(@as(usize, 0), s.refused);
}

test "the engine's facts reach the cell" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try writeTestTree(&tmp, io);
    const root = try tmpRoot(&tmp);
    defer t.allocator.free(root);

    var s = try scan(t.allocator, io, root, acceptAll, null);
    defer s.deinit();

    try t.expectEqual(@as(usize, 2), s.cells.len);
    try t.expectEqual(@as(i32, 12000), s.cells[0].facts.scale);
    try t.expectEqual(@as(f64, -76.6), s.cells[0].facts.bounds.?[0]);
    try t.expectEqual(@as(usize, 0), s.refused);
}

test "a single file scans as itself" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try writeTestTree(&tmp, io);
    const root = try tmpRoot(&tmp);
    defer t.allocator.free(root);
    const one = try std.fmt.allocPrint(t.allocator, "{s}/US5MD1MC/US5MD1MC.000", .{root});
    defer t.allocator.free(one);

    var s = try scan(t.allocator, io, one, null, null);
    defer s.deinit();
    try t.expectEqual(@as(usize, 1), s.cells.len);
    try t.expectEqualStrings("US5MD1MC", s.cells[0].name);
}

test "the JSON carries what a shell needs to draw the list" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try writeTestTree(&tmp, io);
    const root = try tmpRoot(&tmp);
    defer t.allocator.free(root);

    var s = try scan(t.allocator, io, root, acceptAll, null);
    defer s.deinit();
    const json = try toJson(t.allocator, &s);
    defer t.allocator.free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try t.expectEqual(@as(usize, 2), o.get("cells").?.array.items.len);
    try t.expectEqual(@as(i64, 1), o.get("sources").?.integer);
    try t.expectEqual(@as(i64, 1), o.get("updates").?.integer);
    try t.expectEqual(@as(i64, 4), o.get("other").?.integer);

    // A C host reads this through a pointer. Without the terminator, strlen
    // runs off the end of the answer into whatever follows it.
    try t.expectEqual(@as(u8, 0), json[json.len]);

    const first = o.get("cells").?.array.items[0].object;
    try t.expectEqualStrings("US4MD1PM", first.get("name").?.string);
    try t.expectEqualStrings("baked", first.get("kind").?.string);
    try t.expectEqualStrings("Approach", first.get("bandName").?.string);
    try t.expectEqual(@as(i64, 12000), first.get("scale").?.integer);
}

test "an archive's entries classify by name, like a folder's files" {
    const a = t.allocator;
    // The shape NOAA ships: one directory per cell, the cell's referenced text
    // beside it, the catalogue at the top.
    var s = try scanEntries(a, "/Charts/All_ENCs.zip", &.{
        .{ .name = "ENC_ROOT/CATALOG.031", .bytes = 4_000_000 },
        .{ .name = "ENC_ROOT/README.TXT", .bytes = 900 },
        .{ .name = "ENC_ROOT/US1EEZ3M/US1EEZ3M.000", .bytes = 60_896 },
        .{ .name = "ENC_ROOT/US1EEZ3M/US1EEZ3M.001", .bytes = 59_563 },
        .{ .name = "ENC_ROOT/US1EEZ3M/US1EEZ3M.002", .bytes = 19_958 },
        .{ .name = "ENC_ROOT/US1EEZ3M/US1EEZ3A.TXT", .bytes = 992 },
        .{ .name = "ENC_ROOT/US5MD12M/US5MD12M.000", .bytes = 429_900 },
        .{ .name = "MBTILES/USA-Atlantic.mbtiles", .bytes = 4_015_247_360 },
        .{ .name = "KAP/13205_1.KAP", .bytes = 3_000_000 },
        .{ .name = "ENC_ROOT/", .bytes = 0 }, // a directory entry, not a chart
    });
    defer s.deinit();

    try t.expectEqual(@as(usize, 2), s.cells.len); // the two .000 cells
    try t.expectEqual(@as(usize, 2), s.raster.len); // the KAP sheet and the mbtiles
    try t.expectEqual(@as(usize, 2), s.updates); // .001 and .002
    // CATALOG.031, README.TXT and the cell's own .TXT are not charts.
    try t.expectEqual(@as(usize, 3), s.other);
    try t.expectEqual(@as(usize, 0), s.refused);

    // A cell's path is the ENTRY NAME, which is what the engine's zip bake
    // takes back — not a filesystem path that does not exist.
    try t.expectEqualStrings("ENC_ROOT/US1EEZ3M/US1EEZ3M.000", s.cells[0].path);
    try t.expectEqualStrings("US1EEZ3M", s.cells[0].name);
    try t.expectEqual(Kind.source, s.cells[0].kind);
    try t.expectEqual(@as(u8, 1), s.cells[0].band);
    try t.expectEqual(@as(u64, 60_896), s.cells[0].bytes);

    // A sheet must be baked; imagery is already drawable and only has to be
    // got out of the archive. The kinds are what tells the two apart.
    try t.expectEqualStrings("KAP/13205_1.KAP", s.raster[0].path);
    try t.expectEqual(Kind.raster_source, s.raster[0].kind);
    try t.expectEqualStrings("MBTILES/USA-Atlantic.mbtiles", s.raster[1].path);
    try t.expectEqual(Kind.raster, s.raster[1].kind);
    // The size comes from the listing: nothing here can stat an entry, and
    // this one is over 4 GB, which is the whole reason it streams.
    try t.expectEqual(@as(u64, 4_015_247_360), s.raster[1].bytes);
}

test "an archive with nothing in it that is a chart" {
    const a = t.allocator;
    var s = try scanEntries(a, "/Charts/photos.zip", &.{
        .{ .name = "holiday/IMG_0001.JPG", .bytes = 2_000_000 },
        .{ .name = "holiday/notes.txt", .bytes = 40 },
    });
    defer s.deinit();
    try t.expectEqual(@as(usize, 0), s.cells.len);
    try t.expectEqual(@as(usize, 0), s.raster.len);
    try t.expectEqual(@as(usize, 2), s.other);
}

test "a library is named by the agency that made it" {
    const a = t.allocator;
    // Every NOAA chart carries US in the first two characters: that is the
    // producer field of an S-57 dataset name, not a guess from the folder.
    var s = try scanEntries(a, "/Charts/All_ENCs.zip", &.{
        .{ .name = "ENC_ROOT/US1EEZ3M/US1EEZ3M.000" },
        .{ .name = "ENC_ROOT/US5MD12M/US5MD12M.000" },
        .{ .name = "ENC_ROOT/US4MD11M/US4MD11M.pmtiles" },
    });
    defer s.deinit();
    try t.expect(s.producer != null);
    try t.expectEqualStrings("US", &s.producer.?);

    const json = try toJson(a, &s);
    defer a.free(json);
    try t.expect(std.mem.indexOf(u8, json, "\"producer\":\"US\"") != null);
}

test "charts from two offices have no one name" {
    const a = t.allocator;
    var s = try scanEntries(a, "/Charts/mixed", &.{
        .{ .name = "US5MD12M.000" },
        .{ .name = "GB5X01SW.000" },
    });
    defer s.deinit();
    try t.expect(s.producer == null);

    // And the field is left out rather than sent empty, so a host cannot read
    // a blank producer as an agency.
    const json = try toJson(a, &s);
    defer a.free(json);
    try t.expect(std.mem.indexOf(u8, json, "producer") == null);
}

test "a folder of pictures has no producer to report" {
    const a = t.allocator;
    var s = try scanEntries(a, "/Charts/MBTILES", &.{
        .{ .name = "USA-Atlantic-CMap.mbtiles" },
        .{ .name = "13205_1.KAP" },
    });
    defer s.deinit();
    try t.expect(s.producer == null);
}
