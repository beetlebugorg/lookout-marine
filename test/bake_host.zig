//! A real bake, over real cells.
//!
//! `test/cells/` holds three S-57 cells taken out of a NOAA exchange set, one
//! each from bands 3, 4 and 5 and the smallest of their band: 13.8 KB for the
//! three. They are embedded and written into a temp directory. Enough to drive
//! `src/bakejob.zig` for real: the phase split, the counters, the cancel and
//! the output layout. tile57's own bake CLI covers
//! none of that, because it drives tile57's baker and never calls this code.
//!
//! $LOOKOUT_BAKE_ARCHIVE points at a full exchange-set .zip and adds the
//! archive path: the entry names, the mirrored output and the lift. The tests
//! that need it skip without it.

const std = @import("std");

const lk = @import("lookout");
const bakejob = lk.bakejob;
const rules = lk.bake_rules;

const t = std.testing;

/// Zig 0.16 moved sleep behind an Io this test does not take, the same reason
/// src/lock.zig declares its own.
extern "c" fn usleep(usec: u32) c_int;
fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}

/// The cells this test carries, coarse band first. They travel as bytes and
/// are written into the temp directory, because a test binary's working
/// directory belongs to the build runner.
const cells = [_]struct { name: []const u8, band: u8, bytes: []const u8 }{
    .{ .name = "US3CU1EF.000", .band = 3, .bytes = @embedFile("cell_US3CU1EF") },
    .{ .name = "US4TE3W0.000", .band = 4, .bytes = @embedFile("cell_US4TE3W0") },
    .{ .name = "US5OR2XF.000", .band = 5, .bytes = @embedFile("cell_US5OR2XF") },
};

fn archivePath() ?[]const u8 {
    const p = std.c.getenv("LOOKOUT_BAKE_ARCHIVE") orelse return null;
    const span = std.mem.span(p);
    return if (span.len == 0) null else span;
}

/// A bake set up over `items`, run to the end or cancelled. Returns the poll.
fn bake(
    a: std.mem.Allocator,
    source: []const u8,
    items: []rules.Item,
    out_dir: []const u8,
    archive: bool,
    cancel: bool,
    outs_seen: ?*std.ArrayList([:0]u8),
) !bakejob.Progress {
    rules.order(items);
    const ins = try a.alloc([:0]u8, items.len);
    const outs = try a.alloc([:0]u8, items.len);
    const io = std.Io.Threaded.global_single_threaded.io();
    for (items, ins, outs) |item, *i, *o| {
        i.* = try a.dupeZ(u8, item.path);
        const p = try rules.outputPath(a, out_dir, source, item);
        o.* = try a.dupeZ(u8, p);
        std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(p).?) catch {};
        if (outs_seen) |s| try s.append(a, o.*);
    }

    const job = bakejob.Job.start(
        a,
        try a.dupeZ(u8, source),
        ins,
        outs,
        items.len,
        0,
        0,
        archive,
    ).?;
    defer job.free();
    if (cancel) job.cancel();

    var waited: usize = 0;
    while (job.isRunning() and waited < 900) : (waited += 1) sleepMs(100);
    return job.poll();
}

/// Write the carried cells into `dir` and name them as items to prepare.
fn localItems(a: std.mem.Allocator, tmp: *std.testing.TmpDir, dir: []const u8) ![]rules.Item {
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.createDirPath(io, "src");
    const out = try a.alloc(rules.Item, cells.len);
    for (cells, out) |c, *item| {
        const sub = try std.fmt.allocPrint(a, "src/{s}", .{c.name});
        try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = c.bytes });
        item.* = .{
            .path = try std.fs.path.join(a, &.{ dir, sub }),
            .name = c.name,
            .band = c.band,
            .work = .cell,
        };
    }
    return out;
}

test "the cells beside this file bake into charts" {
    const a = t.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const out_dir = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const items = try localItems(aa, &tmp, out_dir);
    var outs = std.ArrayList([:0]u8).empty;
    const p = try bake(aa, out_dir, items, out_dir, false, false, &outs);

    try t.expectEqual(@as(c_int, 0), p.running);
    try t.expectEqual(@as(c_int, 1), p.ok);
    try t.expectEqual(@as(u32, cells.len), p.total);
    try t.expectEqual(@as(u32, cells.len), p.baked);
    try t.expectEqual(@as(u32, cells.len), p.done);

    // Coarse band first, so a mariner who cancels half way keeps the passage.
    try t.expectEqual(@as(u8, 3), items[0].band);
    try t.expectEqual(@as(u8, 4), items[1].band);
    try t.expectEqual(@as(u8, 5), items[2].band);

    // And every chart landed where the rules said it would, in a directory of
    // its own name.
    const io = std.Io.Threaded.global_single_threaded.io();
    for (outs.items) |o| {
        const f = std.Io.Dir.cwd().openFile(io, o, .{}) catch {
            std.debug.print("bake: nothing at {s}\n", .{o});
            return error.TestUnexpectedResult;
        };
        defer f.close(io);
        const st = try f.stat(io);
        try t.expect(st.size > 0);
        try t.expect(std.mem.endsWith(u8, o, ".pmtiles"));
    }
}

test "a cancelled bake stops, and what landed is still usable" {
    const a = t.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const out_dir = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const items = try localItems(aa, &tmp, out_dir);
    const p = try bake(aa, out_dir, items, out_dir, false, true, null);

    try t.expectEqual(@as(c_int, 0), p.running);
    // tile57 stops at the next chart boundary, and a cancel is not a failure:
    // whatever landed is a usable library.
    try t.expectEqual(@as(c_int, 1), p.ok);
    try t.expect(p.baked <= p.total);
}

test "an archive bakes by entry name, and mirrors the entry's path" {
    const archive = archivePath() orelse return error.SkipZigTest;
    const a = t.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    var scan = try lk.scanZip(aa, archive);
    defer scan.deinit();

    var items = std.ArrayList(rules.Item).empty;
    for (scan.cells) |c| {
        if (c.kind != .source) continue;
        try items.append(aa, .{
            .path = try aa.dupe(u8, c.path),
            .name = try aa.dupe(u8, c.name),
            .band = c.band,
            .work = .cell,
        });
        if (items.items.len == 3) break;
    }
    if (items.items.len == 0) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const out_dir = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var outs = std.ArrayList([:0]u8).empty;
    const p = try bake(aa, archive, items.items, out_dir, true, false, &outs);
    try t.expectEqual(@as(c_int, 1), p.ok);
    try t.expectEqual(@as(u32, @intCast(items.items.len)), p.baked);

    // Nothing was unzipped: each `in` was the entry name, read where it lies.
    // The output mirrors it, so a cell's referenced text lands beside it.
    for (outs.items) |o| try t.expect(std.mem.indexOf(u8, o, "/ENC_ROOT/") != null);
}

/// The NOAA fetcher's side: what the service asked for.
const Asked = struct {
    ids: std.ArrayList(u64) = .empty,
    urls: std.ArrayList([]u8) = .empty,
    alloc: std.mem.Allocator,

    fn get(user: ?*anyopaque, req_id: u64, url: [*:0]const u8, allow_file: c_int) callconv(.c) void {
        _ = allow_file;
        const self: *Asked = @ptrCast(@alignCast(user orelse return));
        self.ids.append(self.alloc, req_id) catch return;
        self.urls.append(self.alloc, self.alloc.dupe(u8, std.mem.span(url)) catch return) catch return;
    }
};

test "a NOAA download of the carried cells is prepared into charts" {
    const a = t.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(aa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dest = try std.fmt.allocPrint(aa, "{s}/NOAA", .{dir});
    const prepared = try std.fmt.allocPrint(aa, "{s}/Charts", .{dir});
    try tmp.dir.createDirPath(io, "Charts");

    // A catalog of the three cells, all filed under district 5.
    var xml = std.ArrayList(u8).empty;
    try xml.appendSlice(aa, "<ENC_Product_Catalog><date_valid>20250903</date_valid>");
    for (cells) |c| {
        const stem = c.name[0 .. c.name.len - 4];
        try xml.appendSlice(aa, try std.fmt.allocPrint(aa,
            "<cell><name>{s}</name><lname>Cell</lname><cscale>20000</cscale>" ++
                "<edtn>1</edtn><updn>0</updn>" ++
                "<zipfile_location>https://charts.noaa.gov/ENCs/{s}.zip</zipfile_location>" ++
                "<zipfile_size>1000</zipfile_size><coast_guard_district>5</coast_guard_district>" ++
                "<panel><vertex><lat>1.00</lat><long>-70.00</long></vertex>" ++
                "<vertex><lat>1.40</lat><long>-69.60</long></vertex></panel></cell>",
            .{ stem, stem },
        ));
    }
    try xml.appendSlice(aa, "</ENC_Product_Catalog>");

    const store = try lk.settings.Store.open(a, io, dir);
    defer store.close();
    const sets = try lk.chartsets.Sets.open(a, io, store, prepared, lk.inventory);
    defer sets.close();

    var asked = Asked{ .alloc = aa };
    var h = lk.noaajob.Handle.init(a);
    defer h.deinit();
    h.store = store;
    h.sets = sets;
    h.baker = lk.bakejob.noaa_baker;
    h.follow();
    h.svc.cat = try lk.noaa.parse(a, xml.items);
    h.svc.phase = .ready;
    h.setProvider(Asked.get, null, null, &asked);

    h.download(&.{5}, dest, false);
    try t.expectEqual(@as(usize, cells.len), asked.ids.items.len);
    for (asked.ids.items, asked.urls.items) |id, url| {
        const base = std.fs.path.basename(url);
        const stem = base[0 .. base.len - ".zip".len];
        const cell = for (cells) |c| {
            if (std.mem.startsWith(u8, c.name, stem)) break c;
        } else return error.TestUnexpectedResult;
        const entry = try std.fmt.allocPrint(aa, "ENC_ROOT/{s}/{s}", .{ stem, cell.name });
        const zip = try lk.encunpack.testZip(aa, &.{.{ .name = entry, .data = cell.bytes }});
        h.respondChunk(id, zip, 200, true);
    }

    var st = h.poll();
    var waited: usize = 0;
    while (st.outcome == @intFromEnum(lk.noaajob.Outcome.running) and waited < 1800) : (waited += 1) {
        h.adopt();
        st = h.poll();
        sleepMs(50);
    }

    try t.expectEqual(@as(u8, @intFromEnum(lk.noaajob.Outcome.finished)), st.outcome);
    try t.expectEqual(@as(u32, cells.len), st.to_prepare);
    try t.expectEqual(@as(u32, cells.len), st.prepared);
    // One cell in each of bands 3, 4 and 5.
    for (2..5) |b| {
        try t.expectEqual(@as(u32, 1), st.band_total[b]);
        try t.expectEqual(@as(u32, 1), st.band_done[b]);
    }
    // Each chart is where a shell's bake puts it: under the prepared root, in
    // the download's own directory, in a directory of its own name.
    for (cells) |c| {
        const stem = c.name[0 .. c.name.len - 4];
        const out = try std.fmt.allocPrint(aa, "Charts/NOAA/{s}/{s}.pmtiles", .{ stem, stem });
        tmp.dir.access(io, out, .{}) catch {
            std.debug.print("prepare: no chart at {s}\n", .{out});
            return error.TestUnexpectedResult;
        };
    }
    // The set was read back and draws them.
    const rows = sets.all();
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqual(@as(c_int, 1), rows[0].managed);
    try t.expectEqual(@as(usize, cells.len), rows[0].charts);
    try t.expectEqual(@as(usize, 0), rows[0].to_prepare);
}
