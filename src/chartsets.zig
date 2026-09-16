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
const bake = @import("shell/bake.zig");
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
    /// 1 when a downloader owns this set rather than the mariner. The charts
    /// are added and removed where they were downloaded, and the set wins a
    /// name it shares with a set the mariner added by hand.
    managed: c_int,
    /// 1 once the background scan has read this folder. 0 while it is being
    /// read: on the first pass with every count below 0, and after a rescan
    /// with what the last pass found.
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

/// One chart that can be handed to the engine, and the dataset it holds.
///
/// The name and the edition are what compose deduplicates on. Two sets holding
/// the same cell used to compose it twice, and the engine drew both.
const Openable = struct {
    path: [:0]u8,
    /// The dataset name without its extension. Empty for a file that states no
    /// dataset name. Such a file is never deduplicated by name.
    name: []u8,
    /// DSID EDTN and UPDN. Both 0 for a baked archive, which states neither.
    edition: u32 = 0,
    update: u32 = 0,

    /// True when this chart should replace `other` in the composed list.
    ///
    /// The newer edition wins, so a mariner who downloads fresh cells over an
    /// old folder draws the fresh ones without removing anything. With neither
    /// edition known the downloaded set wins, because that is the one whose
    /// provenance this app knows.
    fn beats(self: Openable, other: Openable, mine_managed: bool, other_managed: bool) bool {
        if (self.edition != other.edition) return self.edition > other.edition;
        if (self.update != other.update) return self.update > other.update;
        return mine_managed and !other_managed;
    }
};

/// One set's rows, held while the model owns them.
const Row = struct {
    path: [:0]u8,
    title: [:0]u8,
    producer: [:0]u8,
    on: bool,
    managed: bool = false,
    scanned: bool,
    charts: usize = 0,
    pictures: usize = 0,
    unprepared: usize = 0,
    bytes: u64 = 0,
    band_lo: u8 = 0,
    band_hi: u8 = 0,
    /// Every chart in this set that can be handed to the engine now, sorted.
    openable: []Openable = &.{},
    /// Every file the scan found, as the scan found it. A shell bakes from
    /// this rather than walking the folder again.
    files: []library.File = &.{},
    /// The arena the files' strings live in, freed with them.
    files_arena: ?std.heap.ArenaAllocator = null,
};

pub const Sets = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *settings.Store,
    /// Where the shell puts what it prepared. Each set is scanned there as
    /// well as at its own path, and a prepared chart WINS over the file it was
    /// made from, so a folder scanned after an import does not ask to be
    /// imported again. Empty when the shell prepares nowhere.
    prepared_root: []u8,
    /// How the scan asks the engine what a file is. Null reads names instead.
    /// A test with no engine linked passes null.
    inventory: ?library.TakeInventory,
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
    /// The arenas a landing scan replaced, and whether `reads` holds a
    /// generation the caller has finished with.
    ///
    /// A read hands out pointers into a row's files_arena and an array out of
    /// `reads`. `land` runs on the scan worker, so freeing either there takes
    /// the list out from under a shell walking it: a background scan landing
    /// mid-loop is not a call the caller made, and the header promises a
    /// borrow until the caller's next one. Both are held here instead and
    /// freed at the head of the next read.
    retired: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    reads_stale: bool = false,

    const group = settings.group_chartsets;
    const paths_key = "paths";
    const off_key = "off";
    const managed_key = "managed";

    /// Load the saved list and start scanning it.
    pub fn open(
        gpa: std.mem.Allocator,
        io: std.Io,
        store: *settings.Store,
        prepared_root: []const u8,
        inventory: ?library.TakeInventory,
    ) !*Sets {
        const self = try gpa.create(Sets);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .store = store,
            .prepared_root = try gpa.dupe(u8, prepared_root),
            .inventory = inventory,
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

        const managed = store.list(group, managed_key);
        var managed_owned = std.ArrayList([:0]u8).empty;
        defer {
            for (managed_owned.items) |p| gpa.free(p);
            managed_owned.deinit(gpa);
        }
        for (managed) |p| try managed_owned.append(gpa, try gpa.dupeZ(u8, p));

        for (store.list(group, paths_key)) |p| {
            var on = true;
            for (off_owned.items) |o| {
                if (std.mem.eql(u8, o, p)) on = false;
            }
            var owned = false;
            for (managed_owned.items) |m| {
                if (std.mem.eql(u8, m, p)) owned = true;
            }
            _ = try self.addRow(p, on, owned);
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
        for (self.retired.items) |*a| a.deinit();
        self.retired.deinit(self.gpa);
        self.gpa.free(self.prepared_root);
        self.reads.deinit();
        self.gpa.destroy(self);
    }

    fn freeRow(self: *Sets, r: *Row) void {
        self.gpa.free(r.path);
        self.gpa.free(r.title);
        self.gpa.free(r.producer);
        for (r.openable) |o| {
            self.gpa.free(o.path);
            self.gpa.free(o.name);
        }
        self.gpa.free(r.openable);
        if (r.files_arena) |*a| a.deinit();
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

    /// Every file one set holds, as the scan found it: the charts ready to
    /// draw and the ones that bake first, with the band and the size. A shell
    /// bakes from this rather than walking the folder again.
    ///
    /// Borrowed until the next call that changes the list. Empty until the
    /// background scan has read the folder.
    /// Free what a landing scan replaced. Every read calls this first, under
    /// the lock, so the generation a caller was handed last time goes only
    /// once that caller has come back for another.
    fn releaseRetired(self: *Sets) void {
        for (self.retired.items) |*a| a.deinit();
        self.retired.clearRetainingCapacity();
        if (self.reads_stale) {
            _ = self.reads.reset(.retain_capacity);
            self.reads_stale = false;
        }
    }

    pub fn files(self: *Sets, path: []const u8) []const *const library.File {
        self.mu.lock();
        defer self.mu.unlock();
        self.releaseRetired();
        for (self.rows.items) |r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            const a = self.reads.allocator();
            const out = a.alloc(*const library.File, r.files.len) catch return &.{};
            for (r.files, out) |*f, *dst| dst.* = f;
            return out;
        }
        return &.{};
    }

    /// The list, in the order added. Borrowed until the next call that changes
    /// it.
    pub fn all(self: *Sets) []const *const Set {
        self.mu.lock();
        defer self.mu.unlock();
        self.releaseRetired();
        const a = self.reads.allocator();
        const out = a.alloc(Set, self.rows.items.len) catch return &.{};
        const by_ptr = a.alloc(*const Set, out.len) catch return &.{};
        for (self.rows.items, out, by_ptr) |r, *dst, *p| {
            dst.* = .{
                .path = r.path.ptr,
                .title = r.title.ptr,
                .producer = r.producer.ptr,
                .on = @intFromBool(r.on),
                .managed = @intFromBool(r.managed),
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
        const added = self.addRow(path, true, false) catch return false;
        if (!added) return false;
        self.save();
        self.startScans();
        return true;
    }

    /// Read a folder again. False when it is not on the list.
    ///
    /// A shell calls this after preparing charts. The bake writes into
    /// `prepared_root`, which is scanned beside each set, so a set keeps its
    /// pre-bake counts until the folder is read again: every chart unprepared,
    /// and no openable path to compose.
    ///
    /// The row returns to unscanned while the worker reads it and keeps the
    /// counts from the last scan, so a page drawn in that second shows the
    /// same set.
    pub fn rescan(self: *Sets, path: []const u8) bool {
        self.mu.lock();
        var found = false;
        for (self.rows.items) |*r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            r.scanned = false;
            found = true;
            break;
        }
        if (found) {
            if (self.gpa.dupeZ(u8, path)) |owned| {
                self.queue.append(self.gpa, owned) catch self.gpa.free(owned);
            } else |_| {}
            _ = self.reads.reset(.retain_capacity);
        }
        self.mu.unlock();
        if (found) self.startScans();
        return found;
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

    /// Mark a set as a downloader's rather than the mariner's. False when the
    /// path is not on the list, or already marked that way.
    pub fn setManaged(self: *Sets, path: []const u8, managed: bool) bool {
        self.mu.lock();
        var changed = false;
        for (self.rows.items) |*r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            if (r.managed != managed) {
                r.managed = managed;
                changed = true;
            }
            break;
        }
        if (changed) _ = self.reads.reset(.retain_capacity);
        self.mu.unlock();
        if (changed) self.save();
        return changed;
    }

    pub fn isManaged(self: *Sets, path: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |r| {
            if (std.mem.eql(u8, r.path, path)) return r.managed;
        }
        return false;
    }

    pub fn isOn(self: *Sets, path: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |r| {
            if (std.mem.eql(u8, r.path, path)) return r.on;
        }
        return false;
    }

    /// Every chart the switched-on sets hold, sorted and deduplicated.
    ///
    /// By path, and then BY DATASET NAME. Two sets overlap whenever a mariner
    /// downloads water they already hold in a folder of their own, and the
    /// same cell composed twice is drawn twice. Openable.beats decides which
    /// copy stays: the newer edition, then the downloaded set.
    ///
    /// A file that states no dataset name is kept on its path alone. Only a
    /// name identifies the water, and two unnamed files are two charts.
    ///
    /// Borrowed until the next call that changes the list.
    pub fn compose(self: *Sets) []const [*:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        self.releaseRetired();
        const a = self.reads.allocator();
        var out = std.ArrayList([:0]const u8).empty;
        // The winner so far for each dataset name, as its index in `out`.
        var byName = std.StringHashMap(struct {
            at: usize,
            held: Openable,
            managed: bool,
        }).init(self.gpa);
        defer byName.deinit();

        for (self.rows.items) |r| {
            if (!r.on) continue;
            for (r.openable) |o| {
                var seen = false;
                for (out.items) |q| {
                    if (std.mem.eql(u8, q, o.path)) seen = true;
                }
                if (seen) continue;
                if (o.name.len == 0) {
                    out.append(a, o.path) catch return &.{};
                    continue;
                }
                if (byName.get(o.name)) |won| {
                    if (!o.beats(won.held, r.managed, won.managed)) continue;
                    out.items[won.at] = o.path;
                    byName.put(o.name, .{ .at = won.at, .held = o, .managed = r.managed }) catch {};
                    continue;
                }
                byName.put(o.name, .{
                    .at = out.items.len,
                    .held = o,
                    .managed = r.managed,
                }) catch {};
                out.append(a, o.path) catch return &.{};
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
        var managed = std.ArrayList([]const u8).empty;
        defer managed.deinit(self.gpa);
        for (self.rows.items) |r| {
            paths.append(self.gpa, r.path) catch return;
            if (!r.on) off.append(self.gpa, r.path) catch return;
            if (r.managed) managed.append(self.gpa, r.path) catch return;
        }
        self.store.setList(group, paths_key, paths.items);
        self.store.setList(group, off_key, off.items);
        self.store.setList(group, managed_key, managed.items);
    }

    // ---- the scans -------------------------------------------------------

    /// Add a row, or return false when the path is already listed.
    fn addRow(self: *Sets, path: []const u8, on: bool, managed: bool) !bool {
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
            .managed = managed,
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

            var scan = library.scanWith(self.gpa, self.io, path, null, null, self.inventory, null) catch continue;
            defer scan.deinit();

            // What the shell prepared from this folder, if anything. It is
            // part of the same set: a folder holding both raw cells and ready
            // imagery arrives whole.
            var prepared: ?library.Scan = null;
            defer if (prepared) |*p| p.deinit();
            if (self.preparedPath(path)) |dir| {
                defer self.gpa.free(dir);
                prepared = library.scanWith(self.gpa, self.io, dir, null, null, self.inventory, null) catch null;
            }
            self.land(path, &scan, if (prepared) |*p| p else null);
        }
    }

    /// One openable chart, with the dataset identity compose deduplicates on.
    ///
    /// A BAKED archive states no DSID: the identity is in the source cell it
    /// was made from. That cell is still in the same folder, so the identity is
    /// read from `source` by stem. A set whose source cells have been deleted reports
    /// edition 0, and two such copies of a cell fall back to the downloaded
    /// one winning.
    fn openableOf(self: *Sets, c: library.Cell, source: *const library.Scan) !Openable {
        const id = identityOf(c, source);
        const path = try self.gpa.dupeZ(u8, c.path);
        errdefer self.gpa.free(path);
        return .{
            .path = path,
            .name = try self.gpa.dupe(u8, library.stemOf(c.name)),
            .edition = id.edition,
            .update = id.update,
        };
    }

    /// The dataset edition and update number of one chart.
    ///
    /// A BAKED archive states no DSID, so the identity is read off the source
    /// cell it was made from, matched by stem in the same folder. A set whose
    /// source cells have been deleted reports 0, and an update check skips it.
    fn identityOf(c: library.Cell, source: *const library.Scan) struct { edition: u32, update: u32 } {
        if (c.facts.edition != 0) return .{ .edition = c.facts.edition, .update = c.facts.update };
        const stem = library.stemOf(c.name);
        for (source.cells) |o| {
            if (o.facts.edition == 0) continue;
            if (!std.mem.eql(u8, library.stemOf(o.name), stem)) continue;
            return .{ .edition = o.facts.edition, .update = o.facts.update };
        }
        return .{ .edition = 0, .update = 0 };
    }

    /// True when the prepared scan holds a chart made from this file.
    fn readyHas(prepared: *const library.Scan, name: []const u8) bool {
        const stem = library.stemOf(name);
        for ([_][]const library.Cell{ prepared.cells, prepared.raster }) |list| {
            for (list) |c| {
                if (std.mem.eql(u8, library.stemOf(c.name), stem)) return true;
            }
        }
        return false;
    }

    /// Where the shell would have put what it prepared from `path`, or null
    /// when it prepares nowhere. The caller frees it.
    fn preparedPath(self: *Sets, path: []const u8) ?[]u8 {
        if (self.prepared_root.len == 0) return null;
        const name = bake.preparedName(path);
        return std.fs.path.join(self.gpa, &.{ self.prepared_root, name }) catch null;
    }

    /// Put what a scan found on its row. `prepared` is the same set as the
    /// shell prepared it, when there is one.
    fn land(
        self: *Sets,
        path: []const u8,
        scan: *const library.Scan,
        prepared: ?*const library.Scan,
    ) void {
        // The files, in the arena that holds their strings, so a shell bakes
        // from what the scan found rather than walking the folder again.
        var files_arena = std.heap.ArenaAllocator.init(self.gpa);
        const fa = files_arena.allocator();
        var found = std.ArrayList(library.File).empty;
        if (prepared) |p| {
            for ([_][]const library.Cell{ p.cells, p.raster }) |list| {
                for (list) |c| {
                    // The bake drops the source cell from this list, so the
                    // archive has to answer for the edition or a shell asking
                    // what is installed reads none.
                    var f = library.fileOf(fa, c) catch continue;
                    const id = identityOf(c, scan);
                    f.edition = id.edition;
                    f.update = id.update;
                    found.append(fa, f) catch {};
                }
            }
        }
        for ([_][]const library.Cell{ scan.cells, scan.raster }) |list| {
            for (list) |c| {
                if (prepared != null and readyHas(prepared.?, c.name)) continue;
                var f = library.fileOf(fa, c) catch continue;
                const id = identityOf(c, scan);
                f.edition = id.edition;
                f.update = id.update;
                found.append(fa, f) catch {};
            }
        }

        // A prepared chart WINS over the file it was made from, matched by the
        // name without its extension. Otherwise a set that has been imported
        // reports every cell as still needing one.
        var ready = std.StringHashMap(void).init(self.gpa);
        defer ready.deinit();
        if (prepared) |p| {
            for ([_][]const library.Cell{ p.cells, p.raster }) |list| {
                for (list) |c| ready.put(library.stemOf(c.name), {}) catch {};
            }
        }

        var openable = std.ArrayList(Openable).empty;
        var charts: usize = 0;
        var pictures: usize = 0;
        var unprepared: usize = 0;
        var lo: u8 = 0;
        var hi: u8 = 0;
        // The prepared charts first, then whatever the source folder still
        // holds that they did not replace.
        if (prepared) |p| {
            for (p.cells) |c| {
                if (c.kind == .source) continue;
                charts += 1;
                openable.append(self.gpa, self.openableOf(c, scan) catch continue) catch {};
                if (c.band >= 1 and c.band <= 6) {
                    if (lo == 0 or c.band < lo) lo = c.band;
                    if (c.band > hi) hi = c.band;
                }
            }
            for (p.raster) |c| {
                if (c.kind != .raster_source) pictures += 1;
            }
        }
        for (scan.cells) |c| {
            if (ready.contains(library.stemOf(c.name))) continue;
            if (c.kind == .source) {
                unprepared += 1;
            } else {
                charts += 1;
                openable.append(self.gpa, self.openableOf(c, scan) catch continue) catch {};
            }
            if (c.band >= 1 and c.band <= 6) {
                if (lo == 0 or c.band < lo) lo = c.band;
                if (c.band > hi) hi = c.band;
            }
        }
        for (scan.raster) |c| {
            if (ready.contains(library.stemOf(c.name))) continue;
            if (c.kind == .raster_source) unprepared += 1 else pictures += 1;
        }

        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |*r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            for (r.openable) |o| {
                self.gpa.free(o.path);
                self.gpa.free(o.name);
            }
            self.gpa.free(r.openable);
            r.openable = openable.toOwnedSlice(self.gpa) catch &.{};
            if (r.files_arena) |old_arena| {
                self.retired.append(self.gpa, old_arena) catch {
                    var tmp = old_arena;
                    tmp.deinit();
                };
            }
            r.files_arena = files_arena;
            r.files = found.items;
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
            self.reads_stale = true;
            return;
        }
        // The row went while the scan ran.
        for (openable.items) |o| {
            self.gpa.free(o.path);
            self.gpa.free(o.name);
        }
        openable.deinit(self.gpa);
        files_arena.deinit();
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

    /// A folder holding exactly the files named, under the temp root.
    fn folderNamed(self: *Fixture, name: []const u8, files: []const []const u8) ![]u8 {
        try self.tmp.dir.createDirPath(self.io, name);
        var buf: [256]u8 = undefined;
        for (files) |f| {
            const sub = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ name, f });
            try self.tmp.dir.writeFile(self.io, .{ .sub_path = sub, .data = "x" });
        }
        return std.fmt.allocPrint(t.allocator, "{s}/{s}", .{ self.dir, name });
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
        return Sets.open(t.allocator, self.io, self.store, "", null);
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
    // Two DIFFERENT cells. One cell in two folders is one chart, and the
    // next test covers that.
    const a = try f.folderNamed("Set A", &.{ "US5MD1MC.pmtiles", "ncds_08.mbtiles" });
    defer t.allocator.free(a);
    const b = try f.folderNamed("Set B", &.{ "US4MD2MC.pmtiles", "ncds_09.mbtiles" });
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

test "a prepared chart wins over the file it was made from" {
    var f = try Fixture.init();
    defer f.deinit();

    // The mariner's folder holds a raw cell.
    const src = try f.folderNamed("Set A", &.{"US5MD1MC.000"});
    defer t.allocator.free(src);
    // And the shell has prepared it into a root of its own.
    const root = try f.folderNamed("Prepared", &.{});
    defer t.allocator.free(root);
    try f.tmp.dir.createDirPath(f.io, "Prepared/Set A/US5MD1MC");
    try f.tmp.dir.writeFile(f.io, .{
        .sub_path = "Prepared/Set A/US5MD1MC/US5MD1MC.pmtiles",
        .data = "x",
    });

    const s = try Sets.open(t.allocator, f.io, f.store, root, null);
    defer s.close();
    try t.expect(s.add(src));
    settle(s);

    const rows = s.all();
    try t.expectEqual(@as(usize, 1), rows.len);
    // One chart ready to draw, and nothing left to prepare.
    try t.expectEqual(@as(usize, 1), rows[0].charts);
    try t.expectEqual(@as(usize, 0), rows[0].unprepared);
    // The prepared chart is what opens, rather than the cell it came from.
    const paths = s.compose();
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expect(std.mem.endsWith(u8, std.mem.span(paths[0]), ".pmtiles"));
}

test "a set with nothing prepared still reports what it holds" {
    var f = try Fixture.init();
    defer f.deinit();
    const src = try f.folderNamed("Set B", &.{"US5MD1MC.000"});
    defer t.allocator.free(src);

    const s = try Sets.open(t.allocator, f.io, f.store, "", null);
    defer s.close();
    try t.expect(s.add(src));
    settle(s);

    const rows = s.all();
    try t.expectEqual(@as(usize, 1), rows.len);
    try t.expectEqual(@as(usize, 0), rows[0].charts);
    try t.expectEqual(@as(usize, 1), rows[0].unprepared);
    // A cell that has not been prepared cannot be handed to the engine.
    try t.expectEqual(@as(usize, 0), s.compose().len);
    // And the file list is what a bake reads.
    const files = s.files(src);
    try t.expectEqual(@as(usize, 1), files.len);
    try t.expectEqual(library.FileKind.source, files[0].kind);
}

test "a set is read again after a bake, and its prepared charts open" {
    var f = try Fixture.init();
    defer f.deinit();

    const src = try f.folderNamed("Set C", &.{"US5MD1MC.000"});
    defer t.allocator.free(src);
    const root = try f.folderNamed("Prepared", &.{});
    defer t.allocator.free(root);

    const s = try Sets.open(t.allocator, f.io, f.store, root, null);
    defer s.close();
    try t.expect(s.add(src));
    settle(s);
    // A raw cell. It opens after a bake prepares it.
    try t.expectEqual(@as(usize, 1), s.all()[0].unprepared);
    try t.expectEqual(@as(usize, 0), s.compose().len);

    // The bake writes into the prepared root, under the folder the mariner
    // picked.
    try f.tmp.dir.createDirPath(f.io, "Prepared/Set C/US5MD1MC");
    try f.tmp.dir.writeFile(f.io, .{
        .sub_path = "Prepared/Set C/US5MD1MC/US5MD1MC.pmtiles",
        .data = "x",
    });
    // The path is already on the list, so add queues no scan.
    try t.expect(!s.add(src));
    settle(s);
    try t.expectEqual(@as(usize, 0), s.compose().len);

    try t.expect(s.rescan(src));
    settle(s);
    try t.expectEqual(@as(usize, 1), s.all()[0].charts);
    try t.expectEqual(@as(usize, 0), s.all()[0].unprepared);
    const paths = s.compose();
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expect(std.mem.endsWith(u8, std.mem.span(paths[0]), ".pmtiles"));
}

test "a folder that is not on the list is not read again" {
    var f = try Fixture.init();
    defer f.deinit();
    const s = try f.open();
    defer s.close();
    try t.expect(!s.rescan("/no/such/folder"));
}

test "a set being read again keeps what the last scan found" {
    var f = try Fixture.init();
    defer f.deinit();
    const dir = try f.folder("Set D");
    defer t.allocator.free(dir);

    const s = try f.open();
    defer s.close();
    try t.expect(s.add(dir));
    settle(s);
    try t.expectEqual(@as(usize, 1), s.all()[0].charts);

    // The row is unscanned while the worker reads it and keeps the counts
    // from the last scan.
    s.mu.lock();
    s.stopping = true;
    s.mu.unlock();
    try t.expect(s.rescan(dir));
    const rows = s.all();
    try t.expectEqual(@as(c_int, 0), rows[0].scanned);
    try t.expectEqual(@as(usize, 1), rows[0].charts);
}


// ---- composing one cell that two sets hold ------------------------------------

/// An inventory reporting one cell per folder, baked, with the source it was
/// made from beside it. The edition comes from the folder name, so a test
/// stands two editions of one cell against each other.
///
/// A real baked archive states no DSID, and openableOf reads the edition off
/// the source cell in the same folder. This reports both for that reason.
fn editionByFolder(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    path: []const u8,
    out: *std.ArrayList(library.InventoryRow),
) bool {
    const edition: u32 = if (std.mem.indexOf(u8, path, "New") != null) 28 else 27;
    const baked = std.fmt.allocPrint(alloc, "{s}/US5MD1MC.pmtiles", .{path}) catch return false;
    out.append(alloc, .{
        .path = baked,
        .name = alloc.dupe(u8, "US5MD1MC") catch return false,
        .kind = .baked,
        .bytes = 900,
    }) catch return false;
    const source = std.fmt.allocPrint(alloc, "{s}/US5MD1MC.000", .{path}) catch return false;
    out.append(alloc, .{
        .path = source,
        .name = alloc.dupe(u8, "US5MD1MC") catch return false,
        .kind = .source,
        .bytes = 4096,
        .edition = edition,
    }) catch return false;
    return true;
}

test "two sets holding one cell compose it once" {
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

    // Both folders hold US5MD1MC.pmtiles. Composed by path alone that is two
    // charts of the same water, and the engine draws both.
    try t.expectEqual(@as(usize, 1), s.compose().len);
}

test "the managed set wins a cell the mariner also holds" {
    var f = try Fixture.init();
    defer f.deinit();
    const mine = try f.folder("Mine");
    defer t.allocator.free(mine);
    const downloaded = try f.folder("NOAA");
    defer t.allocator.free(downloaded);

    const s = try f.open();
    defer s.close();
    try t.expect(s.add(mine));
    try t.expect(s.add(downloaded));
    try t.expect(s.setManaged(downloaded, true));
    settle(s);

    const paths = s.compose();
    try t.expectEqual(@as(usize, 1), paths.len);
    // Neither states an edition, so the downloaded copy wins even though the
    // mariner's folder was added first.
    try t.expect(std.mem.startsWith(u8, std.mem.span(paths[0]), downloaded));
}

test "the newer edition wins, whoever holds it" {
    var f = try Fixture.init();
    defer f.deinit();
    const old = try f.folderNamed("Old", &.{});
    defer t.allocator.free(old);
    const new = try f.folderNamed("New", &.{});
    defer t.allocator.free(new);

    const s = try Sets.open(t.allocator, f.io, f.store, "", editionByFolder);
    defer s.close();
    // The older edition is the managed set, so an edition that loses to the
    // mark would be caught here.
    try t.expect(s.add(old));
    try t.expect(s.setManaged(old, true));
    try t.expect(s.add(new));
    settle(s);

    const paths = s.compose();
    try t.expectEqual(@as(usize, 1), paths.len);
    try t.expect(std.mem.startsWith(u8, std.mem.span(paths[0]), new));
}

test "the managed mark is saved and read back" {
    var f = try Fixture.init();
    defer f.deinit();
    const dir = try f.folder("NOAA");
    defer t.allocator.free(dir);

    {
        const s = try f.open();
        defer s.close();
        try t.expect(s.add(dir));
        try t.expect(s.setManaged(dir, true));
        // Marking it twice changes nothing.
        try t.expect(!s.setManaged(dir, true));
        settle(s);
        try t.expectEqual(@as(c_int, 1), s.all()[0].managed);
    }

    const s = try f.open();
    defer s.close();
    settle(s);
    try t.expect(s.isManaged(dir));
    try t.expectEqual(@as(c_int, 1), s.all()[0].managed);
}

test "a baked chart reports the edition of the cell it was made from" {
    var f = try Fixture.init();
    defer f.deinit();
    const dir = try f.folderNamed("New", &.{});
    defer t.allocator.free(dir);

    const s = try Sets.open(t.allocator, f.io, f.store, "", editionByFolder);
    defer s.close();
    try t.expect(s.add(dir));
    settle(s);

    // The scan reports a .pmtiles and the .000 it was made from. A shell asks
    // what is installed to check NOAA for reissues, and the archive is what it
    // gets: it has to answer with the source cell's edition.
    const files = s.files(dir);
    var baked: ?*const library.File = null;
    for (files) |x| {
        if (std.mem.endsWith(u8, std.mem.span(x.path), ".pmtiles")) baked = x;
    }
    try t.expect(baked != null);
    try t.expectEqual(@as(u32, 28), baked.?.edition);
}

test "a landing scan retires the file arena rather than freeing it" {
    var f = try Fixture.init();
    defer f.deinit();
    const dir = try f.folder("Set A");
    defer t.allocator.free(dir);

    const s = try f.open();
    defer s.close();
    try t.expect(s.add(dir));
    settle(s);

    // The borrow is taken AFTER the rescan is asked for, so the only thing
    // between it and the read below is the worker landing the scan.
    try t.expect(s.rescan(dir));
    const held = s.files(dir);
    try t.expect(held.len > 0);
    settle(s);

    // land replaced the row's arena. Freeing it there would take `held` with
    // it, so it waits here instead. Reading the bytes proves nothing: a freed
    // arena still holds them.
    s.mu.lock();
    const retired = s.retired.items.len;
    const stale = s.reads_stale;
    s.mu.unlock();
    try t.expectEqual(@as(usize, 1), retired);
    try t.expect(stale);

    // The caller coming back is what releases the generation before it.
    try t.expect(s.files(dir).len > 0);
    s.mu.lock();
    const after = s.retired.items.len;
    const stale_after = s.reads_stale;
    s.mu.unlock();
    try t.expectEqual(@as(usize, 0), after);
    try t.expect(!stale_after);
}
