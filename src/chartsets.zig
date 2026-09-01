//! The installed sets: the folders of charts the mariner added, which of them
//! are drawn, and what each holds.
//!
//! A SET is a folder, or one .zip, as a chart agency publishes them. The chart
//! is composed as the UNION of the sets switched on, so switching one off keeps
//! it installed and drops it from the chart.
//!
//! Every mutator returns whether anything changed. What a change MEANS is the
//! shell's: reopen the chart, redraw a settings page. The one thing this
//! announces on its own is a background scan landing, through `changed`.
//!
//! ONE SCAN AT A TIME, on one worker thread. Two scans of a big library compete
//! for the same disk, and the full NOAA library is 7,217 archives.

const std = @import("std");

const library = @import("library.zig");
const settings = @import("settings.zig");
const Lock = @import("lock.zig").Lock;
const sleepMs = @import("lock.zig").sleepMs;

/// One row of the list, as a settings page or a first-run page draws it.
pub const Set = extern struct {
    /// The folder or archive. Also the identity: adding the same one twice
    /// updates the row rather than making a second.
    path: [*:0]const u8,
    /// The agency when the charts agree on one, else the folder name.
    title: [*:0]const u8,
    /// The two-letter producer code. Empty when the charts disagree.
    producer: [*:0]const u8,
    /// 0 when the mariner switched this set off. It stays installed.
    on: c_int,
    /// 1 once the background scan has read this folder. Every count below is
    /// 0 until then.
    scanned: c_int,
    /// The vector charts ready to draw, and the pictures.
    charts: usize,
    pictures: usize,
    /// Files that bake before they draw.
    unprepared: usize,
    bytes: u64,
    /// The coarsest and finest usage bands present, 1 to 6. 0 when the set
    /// holds no cell with a band in its name.
    band_lo: c_int,
    band_hi: c_int,
};

/// One set's rows, held while the model owns them.
const Row = struct {
    path: [:0]u8,
    title: [:0]u8,
    producer: [:0]u8,
    on: bool,
    scanned: bool,
    charts: usize = 0,
    pictures: usize = 0,
    unprepared: usize = 0,
    bytes: u64 = 0,
    band_lo: u8 = 0,
    band_hi: u8 = 0,
    /// Every chart in this set that can be handed to the engine now, sorted.
    openable: [][:0]u8 = &.{},
};

pub const Sets = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *settings.Store,
    mu: Lock = .{},

    rows: std.ArrayList(Row) = .empty,
    /// Set when a scan lands. `takeChanged` clears it.
    dirty: bool = false,

    /// The worker, and the queue it drains. One scan at a time.
    thread: ?std.Thread = null,
    queue: std.ArrayList([:0]u8) = .empty,
    running: bool = false,
    stopping: bool = false,

    /// What a read hands out. Reset by the next call that changes the list.
    reads: std.heap.ArenaAllocator,

    const group = settings.group_chartsets;
    const paths_key = "paths";
    const off_key = "off";

    /// Load the saved list and start scanning it.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, store: *settings.Store) !*Sets {
        const self = try gpa.create(Sets);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .store = store,
            .reads = std.heap.ArenaAllocator.init(gpa),
        };
        errdefer self.close();

        const off = store.list(group, off_key);
        var off_owned = std.ArrayList([:0]u8).empty;
        defer {
            for (off_owned.items) |p| gpa.free(p);
            off_owned.deinit(gpa);
        }
        for (off) |p| try off_owned.append(gpa, try gpa.dupeZ(u8, p));

        for (store.list(group, paths_key)) |p| {
            var on = true;
            for (off_owned.items) |o| {
                if (std.mem.eql(u8, o, p)) on = false;
            }
            _ = try self.addRow(p, on);
        }
        self.startScans();
        return self;
    }

    pub fn close(self: *Sets) void {
        self.mu.lock();
        self.stopping = true;
        self.mu.unlock();
        if (self.thread) |th| th.join();
        self.thread = null;

        for (self.rows.items) |*r| self.freeRow(r);
        self.rows.deinit(self.gpa);
        for (self.queue.items) |p| self.gpa.free(p);
        self.queue.deinit(self.gpa);
        self.reads.deinit();
        self.gpa.destroy(self);
    }

    fn freeRow(self: *Sets, r: *Row) void {
        self.gpa.free(r.path);
        self.gpa.free(r.title);
        self.gpa.free(r.producer);
        for (r.openable) |p| self.gpa.free(p);
        self.gpa.free(r.openable);
    }

    // ---- the list --------------------------------------------------------

    /// True once since a background scan landed, then false.
    pub fn takeChanged(self: *Sets) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const was = self.dirty;
        self.dirty = false;
        return was;
    }

    /// The list, in the order added. Borrowed until the next call that changes
    /// it.
    pub fn all(self: *Sets) []const *const Set {
        self.mu.lock();
        defer self.mu.unlock();
        const a = self.reads.allocator();
        const out = a.alloc(Set, self.rows.items.len) catch return &.{};
        const by_ptr = a.alloc(*const Set, out.len) catch return &.{};
        for (self.rows.items, out, by_ptr) |r, *dst, *p| {
            dst.* = .{
                .path = r.path.ptr,
                .title = r.title.ptr,
                .producer = r.producer.ptr,
                .on = @intFromBool(r.on),
                .scanned = @intFromBool(r.scanned),
                .charts = r.charts,
                .pictures = r.pictures,
                .unprepared = r.unprepared,
                .bytes = r.bytes,
                .band_lo = r.band_lo,
                .band_hi = r.band_hi,
            };
            p.* = dst;
        }
        return by_ptr;
    }

    /// Put a folder on the list and scan it. False when it is already there.
    pub fn add(self: *Sets, path: []const u8) bool {
        const added = self.addRow(path, true) catch return false;
        if (!added) return false;
        self.save();
        self.startScans();
        return true;
    }

    /// Take a folder off the list. False when it was not on it.
    pub fn remove(self: *Sets, path: []const u8) bool {
        self.mu.lock();
        var found = false;
        for (self.rows.items, 0..) |*r, i| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            self.freeRow(r);
            _ = self.rows.orderedRemove(i);
            found = true;
            break;
        }
        _ = self.reads.reset(.retain_capacity);
        self.mu.unlock();
        if (found) self.save();
        return found;
    }

    /// Switch a set on or off. False when the switch was already there.
    pub fn setOn(self: *Sets, path: []const u8, on: bool) bool {
        self.mu.lock();
        var changed = false;
        for (self.rows.items) |*r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            if (r.on != on) {
                r.on = on;
                changed = true;
            }
            break;
        }
        if (changed) _ = self.reads.reset(.retain_capacity);
        self.mu.unlock();
        if (changed) self.save();
        return changed;
    }

    pub fn isOn(self: *Sets, path: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |r| {
            if (std.mem.eql(u8, r.path, path)) return r.on;
        }
        return false;
    }

    /// Every chart the switched-on sets hold, sorted and deduplicated. Two
    /// sets may overlap, and the same cell twice would be composed twice.
    /// Borrowed until the next call that changes the list.
    pub fn compose(self: *Sets) []const [*:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        const a = self.reads.allocator();
        var out = std.ArrayList([:0]const u8).empty;
        for (self.rows.items) |r| {
            if (!r.on) continue;
            for (r.openable) |p| {
                var seen = false;
                for (out.items) |q| {
                    if (std.mem.eql(u8, q, p)) seen = true;
                }
                if (!seen) out.append(a, p) catch return &.{};
            }
        }
        std.mem.sort([:0]const u8, out.items, {}, struct {
            fn lt(_: void, x: [:0]const u8, y: [:0]const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        const ptrs = a.alloc([*:0]const u8, out.items.len) catch return &.{};
        for (out.items, ptrs) |p, *dst| dst.* = p.ptr;
        return ptrs;
    }

    // ---- persistence -----------------------------------------------------

    /// The paths and the switched-off set. The CELLS are not saved: a folder
    /// changes underneath the app, and a stored cell list would offer charts
    /// that are no longer there.
    fn save(self: *Sets) void {
        self.mu.lock();
        defer self.mu.unlock();
        var paths = std.ArrayList([]const u8).empty;
        defer paths.deinit(self.gpa);
        var off = std.ArrayList([]const u8).empty;
        defer off.deinit(self.gpa);
        for (self.rows.items) |r| {
            paths.append(self.gpa, r.path) catch return;
            if (!r.on) off.append(self.gpa, r.path) catch return;
        }
        self.store.setList(group, paths_key, paths.items);
        self.store.setList(group, off_key, off.items);
    }

    // ---- the scans -------------------------------------------------------

    /// Add a row, or return false when the path is already listed.
    fn addRow(self: *Sets, path: []const u8, on: bool) !bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |r| {
            if (std.mem.eql(u8, r.path, path)) return false;
        }
        const owned = try self.gpa.dupeZ(u8, path);
        errdefer self.gpa.free(owned);
        const title = try self.gpa.dupeZ(u8, library.baseName(path));
        errdefer self.gpa.free(title);
        const producer = try self.gpa.dupeZ(u8, "");
        try self.rows.append(self.gpa, .{
            .path = owned,
            .title = title,
            .producer = producer,
            .on = on,
            .scanned = false,
        });
        try self.queue.append(self.gpa, try self.gpa.dupeZ(u8, path));
        _ = self.reads.reset(.retain_capacity);
        return true;
    }

    /// Start the worker if it is not already running.
    fn startScans(self: *Sets) void {
        self.mu.lock();
        const idle = !self.running and self.queue.items.len > 0;
        if (idle) self.running = true;
        self.mu.unlock();
        if (!idle) return;
        if (self.thread) |th| th.join();
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch {
            self.mu.lock();
            self.running = false;
            self.mu.unlock();
            return;
        };
    }

    /// One scan at a time, in the order the folders were added.
    fn worker(self: *Sets) void {
        while (true) {
            self.mu.lock();
            if (self.stopping or self.queue.items.len == 0) {
                self.running = false;
                self.mu.unlock();
                return;
            }
            const path = self.queue.orderedRemove(0);
            self.mu.unlock();
            defer self.gpa.free(path);

            var scan = library.scan(self.gpa, self.io, path, null, null) catch continue;
            defer scan.deinit();
            self.land(path, &scan);
        }
    }

    /// Put what a scan found on its row.
    fn land(self: *Sets, path: []const u8, scan: *const library.Scan) void {
        var openable = std.ArrayList([:0]u8).empty;
        var charts: usize = 0;
        var pictures: usize = 0;
        var unprepared: usize = 0;
        var lo: u8 = 0;
        var hi: u8 = 0;
        for (scan.cells) |c| {
            if (c.kind == .source) {
                unprepared += 1;
            } else {
                charts += 1;
                openable.append(self.gpa, self.gpa.dupeZ(u8, c.path) catch continue) catch {};
            }
            if (c.band >= 1 and c.band <= 6) {
                if (lo == 0 or c.band < lo) lo = c.band;
                if (c.band > hi) hi = c.band;
            }
        }
        for (scan.raster) |c| {
            if (c.kind == .raster_source) unprepared += 1 else pictures += 1;
        }

        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |*r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            for (r.openable) |p| self.gpa.free(p);
            self.gpa.free(r.openable);
            r.openable = openable.toOwnedSlice(self.gpa) catch &.{};
            r.charts = charts;
            r.pictures = pictures;
            r.unprepared = unprepared;
            r.bytes = scan.totalBytes();
            r.band_lo = lo;
            r.band_hi = hi;
            r.scanned = true;
            // The agency when the charts agree on one, else the folder name.
            if (scan.producer) |p| {
                if (self.gpa.dupeZ(u8, &p)) |owned| {
                    self.gpa.free(r.producer);
                    r.producer = owned;
                } else |_| {}
            }
            self.dirty = true;
            _ = self.reads.reset(.retain_capacity);
            return;
        }
        // The row went while the scan ran.
        for (openable.items) |p| self.gpa.free(p);
        openable.deinit(self.gpa);
    }
};

// ---- tests ---------------------------------------------------------------------

const t = std.testing;

/// A store and a sets model in a temp directory, with a folder of charts under
/// it to add.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    io: std.Io = std.Io.Threaded.global_single_threaded.io(),
    store: *settings.Store,

    fn init() !Fixture {
        const tmp = std.testing.tmpDir(.{ .iterate = true });
        const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        const io = std.Io.Threaded.global_single_threaded.io();
        return .{ .tmp = tmp, .dir = dir, .store = try settings.Store.open(t.allocator, io, dir) };
    }

    fn deinit(self: *Fixture) void {
        self.store.close();
        t.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    /// A folder holding one baked cell and one picture, under the temp root.
    fn folder(self: *Fixture, name: []const u8) ![]u8 {
        try self.tmp.dir.createDirPath(self.io, name);
        var buf: [256]u8 = undefined;
        for ([_][]const u8{ "US5MD1MC.pmtiles", "ncds_08.mbtiles" }) |f| {
            const sub = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ name, f });
            try self.tmp.dir.writeFile(self.io, .{ .sub_path = sub, .data = "x" });
        }
        return std.fmt.allocPrint(t.allocator, "{s}/{s}", .{ self.dir, name });
    }

    fn open(self: *Fixture) !*Sets {
        return Sets.open(t.allocator, self.io, self.store);
    }
};

/// Wait for every queued scan to land. The worker runs on its own thread.
fn settle(s: *Sets) void {
    for (0..2000) |_| {
        s.mu.lock();
        const idle = !s.running and s.queue.items.len == 0;
        s.mu.unlock();
        if (idle) return;
        sleepMs(1);
    }
}

test "a folder added is listed, scanned and saved" {
    var f = try Fixture.init();
    defer f.deinit();
    const dir = try f.folder("Set A");
    defer t.allocator.free(dir);

    const s = try f.open();
    defer s.close();
    try t.expect(s.add(dir));
    // Adding the same folder twice updates the row rather than making a second.
    try t.expect(!s.add(dir));
    settle(s);

    const rows = s.all();
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqualStrings(dir, std.mem.span(rows[0].path));
    try t.expectEqual(@as(c_int, 1), rows[0].on);
    try t.expectEqual(@as(c_int, 1), rows[0].scanned);
    try t.expectEqual(@as(usize, 1), rows[0].charts);
    try t.expectEqual(@as(usize, 1), rows[0].pictures);
    try t.expectEqual(@as(c_int, 5), rows[0].band_lo);
    try t.expectEqual(@as(c_int, 5), rows[0].band_hi);

    // The path is in the store, and the cells are not: a folder changes
    // underneath the app.
    const saved = f.store.list(settings.group_chartsets, "paths");
    try t.expectEqual(@as(usize, 1), saved.len);
    try t.expectEqualStrings(dir, saved[0]);
}

test "a set switched off stays listed and drops out of the composition" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.folder("Set A");
    defer t.allocator.free(a);

    const s = try f.open();
    defer s.close();
    try t.expect(s.add(a));
    settle(s);
    try t.expectEqual(@as(usize, 1), s.compose().len);

    try t.expect(s.setOn(a, false));
    // Setting the switch it already has changes nothing.
    try t.expect(!s.setOn(a, false));
    try t.expectEqual(@as(usize, 1), s.all().len);
    try t.expect(!s.isOn(a));
    try t.expectEqual(@as(usize, 0), s.compose().len);

    try t.expect(s.setOn(a, true));
    try t.expectEqual(@as(usize, 1), s.compose().len);
}

test "the composition is the union of the sets switched on, deduplicated" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.folder("Set A");
    defer t.allocator.free(a);
    const b = try f.folder("Set B");
    defer t.allocator.free(b);

    const s = try f.open();
    defer s.close();
    try t.expect(s.add(a));
    try t.expect(s.add(b));
    settle(s);

    const paths = s.compose();
    try t.expectEqual(@as(usize, 2), paths.len);
    // Sorted, so two shells reading the same library open it the same way.
    try t.expect(std.mem.lessThan(u8, std.mem.span(paths[0]), std.mem.span(paths[1])));
    // The picture is not a chart to compose.
    for (paths) |p| try t.expect(std.mem.endsWith(u8, std.mem.span(p), ".pmtiles"));

    // The same folder under both sets composes once. Adding the parent brings
    // both cells in, and they are already listed.
    try t.expect(s.add(f.dir));
    settle(s);
    var seen = std.StringHashMap(void).init(t.allocator);
    defer seen.deinit();
    for (s.compose()) |p| {
        const r = try seen.getOrPut(std.mem.span(p));
        try t.expect(!r.found_existing);
    }
}

test "a set removed goes from the list and the store" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.folder("Set A");
    defer t.allocator.free(a);

    const s = try f.open();
    defer s.close();
    try t.expect(s.add(a));
    settle(s);
    try t.expect(s.remove(a));
    try t.expect(!s.remove(a));
    try t.expectEqual(@as(usize, 0), s.all().len);
    try t.expectEqual(@as(usize, 0), f.store.list(settings.group_chartsets, "paths").len);
}

test "the saved list and the switches come back on the next launch" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.folder("Set A");
    defer t.allocator.free(a);
    const b = try f.folder("Set B");
    defer t.allocator.free(b);

    {
        const s = try f.open();
        defer s.close();
        try t.expect(s.add(a));
        try t.expect(s.add(b));
        try t.expect(s.setOn(b, false));
        settle(s);
    }

    const s = try f.open();
    defer s.close();
    settle(s);
    const rows = s.all();
    try t.expectEqual(@as(usize, 2), rows.len);
    // In the order added.
    try t.expectEqualStrings(a, std.mem.span(rows[0].path));
    try t.expectEqualStrings(b, std.mem.span(rows[1].path));
    try t.expectEqual(@as(c_int, 1), rows[0].on);
    try t.expectEqual(@as(c_int, 0), rows[1].on);
}

test "a scan landing raises the changed flag once" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.folder("Set A");
    defer t.allocator.free(a);

    const s = try f.open();
    defer s.close();
    _ = s.takeChanged();
    try t.expect(s.add(a));
    settle(s);
    try t.expect(s.takeChanged());
    try t.expect(!s.takeChanged());
}

test "a folder that is not there is listed and scans to nothing" {
    var f = try Fixture.init();
    defer f.deinit();

    const s = try f.open();
    defer s.close();
    // A drive that is not plugged in. The set stays listed, because a folder
    // that did not answer is not a folder the mariner threw away.
    try t.expect(s.add("/no/such/folder"));
    settle(s);
    const rows = s.all();
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqual(@as(usize, 0), rows[0].charts);
    try t.expectEqual(@as(usize, 0), s.compose().len);
    try t.expectEqual(@as(usize, 1), f.store.list(settings.group_chartsets, "paths").len);
}
