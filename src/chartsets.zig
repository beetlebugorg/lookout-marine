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
    /// Files that bake before they draw. Inside a .zip that is every chart,
    /// because a baked one is lifted out of the archive first.
    unprepared: usize,
    bytes: u64,
    /// The coarsest and finest usage bands present, 1 to 6. 0 when the set
    /// holds no cell with a band in its name.
    band_lo: c_int,
    band_hi: c_int,
    /// The charts this set holds that another switched-on set draws instead,
    /// because both hold the same cell and the other copy has the newer
    /// edition or is in the managed set. They stay installed. 0 for a set
    /// switched off.
    held_back: usize = 0,
    /// The files `Sets.toPrepare` lists: `unprepared` less `refused`.
    to_prepare: usize = 0,
    /// Files a finished bake of this set did not prepare. They stay out of
    /// `to_prepare` until a new edition or update of the cell arrives.
    refused: usize = 0,
    /// `to_prepare` by usage band: `band_todo[0]` is band 1. A file with no
    /// band is in no entry.
    band_todo: [6]usize = @splat(0),
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
    /// The files that bake or lift before they draw and have no current
    /// prepared chart, as indices into `files`. In `files_arena`. Refused
    /// files are left out when read, because a refusal can arrive after the
    /// scan.
    todo: []const u32 = &.{},
    /// The files to prepare when the last bake of this set was cancelled or
    /// failed, as hashes of `refusalKey`. Null when none is recorded. A
    /// landing scan that finds a file to prepare outside it clears it.
    stopped: ?std.AutoHashMapUnmanaged(u64, void) = null,
    /// The number of the last scan read into this row. 0 before the first.
    last_scan: u64 = 0,
};

/// The files a finished bake was given, for the next scan of its set to
/// resolve. A file among them that the scan still lists to prepare was
/// refused.
const Note = struct {
    set: [:0]u8,
    /// The scans started when the note was made. Only a scan started after
    /// it reads the bake's output.
    after: u64,
    paths: std.StringHashMapUnmanaged(void) = .empty,

    fn free(self: *Note, gpa: std.mem.Allocator) void {
        var it = self.paths.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.paths.deinit(gpa);
        gpa.free(self.set);
    }
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

    /// What a read hands out. Reset only by a call that changes the list. A
    /// shell reads `files` inside a loop over `all`, and a scan can land
    /// between the two reads.
    reads: std.heap.ArenaAllocator,
    /// Bumped by every landing scan. A read made in the same generation as
    /// the last one of its kind returns that one again, so reads between two
    /// changes allocate once.
    gen: u64 = 0,
    all_read: ?Kept(*const Set) = null,
    compose_read: ?Kept([*:0]const u8) = null,
    /// One per set path read.
    files_reads: std.ArrayList(Kept(*const library.File)) = .empty,
    /// What landing scans replaced.
    ///
    /// A read hands out pointers into a row's files_arena, its openable paths
    /// and its producer. `land` runs on the scan worker, and a shell may be
    /// walking the list on its own thread. They are held here and freed with
    /// the read arena, by the next call that changes the list.
    retired: std.ArrayList(Retired) = .empty,
    /// One per set path read, as `files_reads` is.
    todo_reads: std.ArrayList(Kept(*const library.File)) = .empty,

    /// The cells a bake did not prepare, by `refusalKey`. Saved, so a refused
    /// cell is not baked again on every launch.
    refused: std.StringHashMapUnmanaged(void) = .empty,
    /// Bake results waiting for the scan that reads their output.
    notes: std.ArrayList(Note) = .empty,
    /// How many scans the worker has started.
    scans: u64 = 0,
    /// Called under `mu` each time a scan ends or a set is removed. The NOAA
    /// service sets it to follow the set it prepares. Null with no follower.
    on_scan: ?OnScan = null,

    /// A function called when a scan ends or a set is removed, and its
    /// context. It runs with `mu` held, often on the scan worker, so it posts
    /// and returns.
    pub const OnScan = struct {
        call: *const fn (ctx: *anyopaque) void,
        ctx: *anyopaque,
    };

    /// Where a scan of one set stands, for `scannedSince`.
    pub const ScanState = enum { waiting, read, gone };

    const group = settings.group_chartsets;
    const paths_key = "paths";
    const off_key = "off";
    const managed_key = "managed";
    const refused_key = "refused";

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

        for (store.list(group, refused_key)) |k| {
            const owned = try gpa.dupe(u8, k);
            self.refused.put(gpa, owned, {}) catch {
                gpa.free(owned);
                return error.OutOfMemory;
            };
        }

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
        for (self.retired.items) |*x| x.free(self.gpa);
        self.retired.deinit(self.gpa);
        self.files_reads.deinit(self.gpa);
        self.todo_reads.deinit(self.gpa);
        var keys = self.refused.keyIterator();
        while (keys.next()) |k| self.gpa.free(k.*);
        self.refused.deinit(self.gpa);
        for (self.notes.items) |*n| n.free(self.gpa);
        self.notes.deinit(self.gpa);
        self.gpa.free(self.prepared_root);
        self.reads.deinit();
        self.gpa.destroy(self);
    }

    fn freeRow(self: *Sets, r: *Row) void {
        self.gpa.free(r.path);
        self.gpa.free(r.title);
        self.gpa.free(r.producer);
        freeOpenable(self.gpa, r.openable);
        if (r.files_arena) |*a| a.deinit();
        if (r.stopped) |*m| m.deinit(self.gpa);
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

    /// Follow the scans as they end and the sets as they are removed, or
    /// stop with null.
    pub fn followScans(self: *Sets, f: ?OnScan) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.on_scan = f;
    }

    /// How many scans the worker has started. A scan of a set numbered above
    /// this read the set after this call.
    pub fn scanCount(self: *Sets) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.scans;
    }

    /// Whether a scan of `path` numbered above `after` has been read into its
    /// row.
    pub fn scannedSince(self: *Sets, path: []const u8, after: u64) ScanState {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            return if (r.last_scan > after) .read else .waiting;
        }
        return .gone;
    }

    /// Raise the flag takeChanged reads, for a change made outside a scan.
    pub fn noteChanged(self: *Sets) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.dirty = true;
    }

    /// Free everything a read handed out, and what landing scans replaced.
    /// Called with `mu` held, by each call that changes the list.
    fn resetReads(self: *Sets) void {
        _ = self.reads.reset(.retain_capacity);
        self.all_read = null;
        self.compose_read = null;
        self.files_reads.clearRetainingCapacity();
        self.todo_reads.clearRetainingCapacity();
        for (self.retired.items) |*x| x.free(self.gpa);
        self.retired.clearRetainingCapacity();
    }

    /// Every file one set holds, as the scan found it: the charts ready to
    /// draw and the ones that bake first, with the band and the size. A shell
    /// bakes from this rather than walking the folder again.
    ///
    /// Borrowed until the next call that changes the list. Empty until the
    /// background scan has read the folder.
    pub fn files(self: *Sets, path: []const u8) []const *const library.File {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            const kept = self.keptFor(&self.files_reads, r.path) orelse return &.{};
            if (kept.gen == self.gen) return kept.out;
            const out = self.reads.allocator().alloc(*const library.File, r.files.len) catch return &.{};
            for (r.files, out) |*f, *dst| dst.* = f;
            kept.gen = self.gen;
            kept.out = out;
            return out;
        }
        return &.{};
    }

    /// The kept read for one set path in `list`, made stale when new. `path`
    /// is the row's own, which outlives the entry. Called with `mu` held.
    fn keptFor(
        self: *Sets,
        list: *std.ArrayList(Kept(*const library.File)),
        path: []const u8,
    ) ?*Kept(*const library.File) {
        for (list.items) |*k| {
            if (k.path.ptr == path.ptr) return k;
        }
        const k = list.addOne(self.gpa) catch return null;
        k.* = .{ .gen = self.gen -% 1, .out = &.{}, .path = path };
        return k;
    }

    /// The files one set still has to prepare: each file that bakes before it
    /// draws and has no prepared chart, or whose prepared chart is older than
    /// it. Inside a .zip a baked chart is listed too, until it is lifted out.
    /// A file a finished bake refused is left out.
    ///
    /// Borrowed until the next call that changes the list, as `files` is.
    pub fn toPrepare(self: *Sets, path: []const u8) []const *const library.File {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            const kept = self.keptFor(&self.todo_reads, r.path) orelse return &.{};
            if (kept.gen == self.gen) return kept.out;
            const a = self.reads.allocator();
            var out = std.ArrayList(*const library.File).initCapacity(a, r.todo.len) catch return &.{};
            for (r.todo) |i| {
                const f = &r.files[i];
                if (!self.isRefused(f)) out.appendAssumeCapacity(f);
            }
            kept.gen = self.gen;
            kept.out = out.items;
            return out.items;
        }
        return &.{};
    }

    /// The counts `toPrepare` answers to, for one row. Called with `mu` held.
    fn countTodo(self: *Sets, r: Row) struct { to_prepare: usize, refused: usize, bands: [6]usize } {
        var to_prepare: usize = 0;
        var refused: usize = 0;
        var bands: [6]usize = @splat(0);
        for (r.todo) |i| {
            const f = &r.files[i];
            if (self.isRefused(f)) {
                refused += 1;
                continue;
            }
            to_prepare += 1;
            if (f.band >= 1 and f.band <= 6) bands[@intCast(f.band - 1)] += 1;
        }
        return .{ .to_prepare = to_prepare, .refused = refused, .bands = bands };
    }

    /// Called with `mu` held.
    fn isRefused(self: *Sets, f: *const library.File) bool {
        if (self.refused.size == 0) return false;
        var buf: [refusal_key_max]u8 = undefined;
        return self.refused.contains(refusalKey(&buf, f));
    }

    /// Record how a bake of one set ended. `ins` is what it was given.
    ///
    /// A bake that ran to the end leaves a note. The next scan of the set that
    /// starts after it records each file of `ins` it still lists to prepare as
    /// refused, keyed by `refusalKey`. A shell rescans the set after a bake,
    /// so that scan is the one. A cancelled or failed bake records a stop, as
    /// `noteCancel` does.
    pub fn noteBake(self: *Sets, path: []const u8, ins: []const [:0]const u8, finished: bool) void {
        if (!finished) {
            self.noteCancel(path);
            return;
        }
        var note: Note = .{ .set = self.gpa.dupeZ(u8, path) catch return, .after = 0 };
        var norm: [std.fs.max_path_bytes]u8 = undefined;
        for (ins) |p| {
            const owned = self.gpa.dupe(u8, sepNormal(&norm, p)) catch break;
            const gop = note.paths.getOrPut(self.gpa, owned) catch {
                self.gpa.free(owned);
                break;
            };
            if (gop.found_existing) self.gpa.free(owned);
        }
        self.mu.lock();
        defer self.mu.unlock();
        note.after = self.scans;
        for (self.notes.items, 0..) |*n, i| {
            if (!std.mem.eql(u8, n.set, path)) continue;
            n.free(self.gpa);
            self.notes.items[i] = note;
            return;
        }
        self.notes.append(self.gpa, note) catch note.free(self.gpa);
    }

    /// Record that the prepare of one set was stopped. `resumePath` then skips
    /// the set until a scan of it finds a file to prepare that was not there
    /// when it stopped: a new cell, or a new edition of one.
    pub fn noteCancel(self: *Sets, path: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |*r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            var held: std.AutoHashMapUnmanaged(u64, void) = .empty;
            for (r.todo) |i| {
                held.put(self.gpa, keyHash(&r.files[i]), {}) catch break;
            }
            if (r.stopped) |*m| m.deinit(self.gpa);
            r.stopped = held;
            return;
        }
    }

    /// A managed set, switched on and scanned, with files to prepare and no
    /// stop recorded since it last changed. Null when there is none. The
    /// path is the row's own.
    pub fn resumePath(self: *Sets) ?[:0]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |r| {
            if (!r.managed or !r.on or !r.scanned or r.stopped != null) continue;
            if (self.countTodo(r).to_prepare > 0) return r.path;
        }
        return null;
    }

    /// The list, in the order added. Borrowed until the next call that changes
    /// it.
    pub fn all(self: *Sets) []const *const Set {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.all_read) |k| {
            if (k.gen == self.gen) return k.out;
        }
        const a = self.reads.allocator();
        const out = a.alloc(Set, self.rows.items.len) catch return &.{};
        const by_ptr = a.alloc(*const Set, out.len) catch return &.{};
        const held_back = a.alloc(usize, out.len) catch return &.{};
        self.countHeldBack(held_back);
        for (self.rows.items, out, by_ptr, held_back) |r, *dst, *p, held| {
            const todo = self.countTodo(r);
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
                .held_back = held,
                .to_prepare = todo.to_prepare,
                .refused = todo.refused,
                .band_todo = todo.bands,
            };
            p.* = dst;
        }
        self.all_read = .{ .gen = self.gen, .out = by_ptr };
        return by_ptr;
    }

    /// For each row, how many of its named charts compose draws from another
    /// row instead. Called with `mu` held.
    fn countHeldBack(self: *Sets, out: []usize) void {
        @memset(out, 0);
        const Won = struct { row: usize, held: Openable, managed: bool };
        var byName = std.StringHashMap(Won).init(self.gpa);
        defer byName.deinit();
        for (self.rows.items, 0..) |r, i| {
            if (!r.on) continue;
            for (r.openable) |o| {
                if (o.name.len == 0) continue;
                if (byName.get(o.name)) |won| {
                    if (!o.beats(won.held, r.managed, won.managed)) continue;
                }
                byName.put(o.name, .{ .row = i, .held = o, .managed = r.managed }) catch return;
            }
        }
        for (self.rows.items, 0..) |r, i| {
            if (!r.on) continue;
            for (r.openable) |o| {
                if (o.name.len == 0) continue;
                const won = byName.get(o.name) orelse continue;
                if (won.row != i) out[i] += 1;
            }
        }
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
            self.resetReads();
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
        for (self.notes.items, 0..) |*n, i| {
            if (!std.mem.eql(u8, n.set, path)) continue;
            n.free(self.gpa);
            _ = self.notes.swapRemove(i);
            break;
        }
        self.resetReads();
        if (found) if (self.on_scan) |f| f.call(f.ctx);
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
        if (changed) self.resetReads();
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
        if (changed) self.resetReads();
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

    /// One survey cell the sets hold, by dataset name.
    pub const Held = struct { name: []u8, edition: u32, update: u32 };

    /// Which cells heldCells reads.
    pub const HeldOf = enum {
        /// Every set, switched on or off. Edition and update are the highest
        /// found and may be 0.
        names,
        /// The managed sets, and only the cells that state an edition. A cell
        /// with no edition cannot be compared with the catalog: 0 is lower than
        /// every edition the catalog lists.
        editions,
        /// The managed sets' charts that draw now. A cell that still has to be
        /// prepared is left out. Edition and update are the chart's.
        charts,
    };

    /// The survey cells the sets hold, one per dataset name, upper case and
    /// sorted by name. Pictures are left out. Where two files hold one name,
    /// the higher edition and update are kept, because that is the chart
    /// compose draws.
    ///
    /// Owned by `alloc`. Free it with freeHeld.
    pub fn heldCells(self: *Sets, alloc: std.mem.Allocator, of: HeldOf) ![]Held {
        var by_name = std.StringHashMapUnmanaged(Held).empty;
        defer by_name.deinit(alloc);
        errdefer {
            var it = by_name.valueIterator();
            while (it.next()) |h| alloc.free(h.name);
        }
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.rows.items) |r| {
                if (of != .names and !r.managed) continue;
                if (of == .charts) {
                    for (r.openable) |o| try putHeld(alloc, &by_name, o.name, o.edition, o.update);
                    continue;
                }
                for (r.files) |f| {
                    if (f.kind != .baked and f.kind != .source) continue;
                    if (of == .editions and f.edition == 0) continue;
                    try putHeld(alloc, &by_name, library.stemOf(std.mem.span(f.name)), f.edition, f.update);
                }
            }
        }
        const out = try alloc.alloc(Held, by_name.count());
        var it = by_name.valueIterator();
        var n: usize = 0;
        while (it.next()) |h| : (n += 1) out[n] = h.*;
        std.mem.sort(Held, out, {}, struct {
            fn lt(_: void, a: Held, b: Held) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
        return out;
    }

    /// Add one cell to a heldCells map by its upper case name, keeping the
    /// higher edition and update.
    fn putHeld(alloc: std.mem.Allocator, by_name: *std.StringHashMapUnmanaged(Held), stem: []const u8, edition: u32, update: u32) !void {
        var buf: [64]u8 = undefined;
        if (stem.len == 0 or stem.len > buf.len) return;
        const upper = std.ascii.upperString(&buf, stem);
        const gop = try by_name.getOrPut(alloc, upper);
        if (gop.found_existing) {
            const had = gop.value_ptr;
            if (edition > had.edition or (edition == had.edition and update > had.update)) {
                had.edition = edition;
                had.update = update;
            }
            return;
        }
        const name = alloc.dupe(u8, upper) catch |e| {
            by_name.removeByPtr(gop.key_ptr);
            return e;
        };
        gop.key_ptr.* = name;
        gop.value_ptr.* = .{ .name = name, .edition = edition, .update = update };
    }

    pub fn freeHeld(alloc: std.mem.Allocator, cells: []Held) void {
        for (cells) |h| alloc.free(h.name);
        alloc.free(cells);
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
        if (self.compose_read) |k| {
            if (k.gen == self.gen) return k.out;
        }
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
        self.compose_read = .{ .gen = self.gen, .out = ptrs };
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
        self.resetReads();
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
            self.scans += 1;
            const number = self.scans;
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
            self.land(path, number, &scan, if (prepared) |*p| p else null);
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

    /// When a file was last written, in nanoseconds, or null when it cannot be
    /// read. An entry inside an archive has no file to stat.
    fn modifiedAt(self: *Sets, path: []const u8) ?i128 {
        const f = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
        defer f.close(self.io);
        const st = f.stat(self.io) catch return null;
        return st.mtime.nanoseconds;
    }

    /// Where the shell would have put what it prepared from `path`, or null
    /// when it prepares nowhere. The caller frees it.
    fn preparedPath(self: *Sets, path: []const u8) ?[]u8 {
        if (self.prepared_root.len == 0) return null;
        const name = bake.preparedName(path);
        return std.fs.path.join(self.gpa, &.{ self.prepared_root, name }) catch null;
    }

    /// Record as refused each file of `r` to prepare that the set's bake note
    /// names, and drop the note. Only a scan started after the note resolves
    /// it. Called with `mu` held.
    fn resolveNote(self: *Sets, r: Row, number: u64) void {
        const at = for (self.notes.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.set, r.path)) break i;
        } else return;
        var note = self.notes.items[at];
        if (number <= note.after) return;
        _ = self.notes.swapRemove(at);
        defer note.free(self.gpa);
        var added = false;
        for (r.todo) |i| {
            const f = &r.files[i];
            var norm: [std.fs.max_path_bytes]u8 = undefined;
            if (!note.paths.contains(sepNormal(&norm, std.mem.span(f.path)))) continue;
            var buf: [refusal_key_max]u8 = undefined;
            const key = refusalKey(&buf, f);
            if (self.refused.contains(key)) continue;
            const owned = self.gpa.dupe(u8, key) catch continue;
            self.refused.put(self.gpa, owned, {}) catch {
                self.gpa.free(owned);
                continue;
            };
            added = true;
        }
        if (!added) return;
        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(self.gpa);
        var it = self.refused.keyIterator();
        while (it.next()) |k| keys.append(self.gpa, k.*) catch return;
        self.store.setList(group, refused_key, keys.items);
    }

    /// Put what a scan found on its row. `prepared` is the same set as the
    /// shell prepared it, when there is one. `number` is the scan's, counted
    /// from the first the worker started.
    fn land(
        self: *Sets,
        path: []const u8,
        number: u64,
        scan: *const library.Scan,
        prepared: ?*const library.Scan,
    ) void {
        // The files, in the arena that holds their strings, so a shell bakes
        // from what the scan found rather than walking the folder again.
        var files_arena = std.heap.ArenaAllocator.init(self.gpa);
        const fa = files_arena.allocator();
        var found = std.ArrayList(library.File).empty;
        var todo = std.ArrayList(u32).empty;
        // Inside a .zip every chart is prepared before it draws. A baked
        // chart there is lifted out of the archive.
        const archive = bake.isArchive(path);

        // The first cell to prepare of each stem, for the stale test below.
        var sources = std.StringHashMap(*const library.Cell).init(self.gpa);
        defer sources.deinit();
        for (scan.cells) |*o| {
            if (o.kind != .source and !archive) continue;
            const gop = sources.getOrPut(library.stemOf(o.name)) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = o;
        }

        // The stems whose prepared chart is older than the cell it was made
        // from. An update writes a new base cell beside the chart prepared
        // from the edition before it, and that chart goes on drawing the old
        // edition until it is prepared again.
        var stale = std.StringHashMap(void).init(self.gpa);
        defer stale.deinit();
        if (prepared) |p| {
            for ([_][]const library.Cell{ p.cells, p.raster }) |list| {
                for (list) |c| {
                    const stem = library.stemOf(c.name);
                    const o = sources.get(stem) orelse continue;
                    const at = self.modifiedAt(c.path) orelse continue;
                    const src = self.modifiedAt(o.path) orelse continue;
                    if (src > at) stale.put(stem, {}) catch {};
                }
            }
        }

        // A prepared chart WINS over the file it was made from, matched by the
        // name without its extension. Otherwise a set that has been imported
        // reports every cell as still needing one.
        var ready = std.StringHashMap(void).init(self.gpa);
        defer ready.deinit();
        if (prepared) |p| {
            for ([_][]const library.Cell{ p.cells, p.raster }) |list| {
                for (list) |c| {
                    const stem = library.stemOf(c.name);
                    // A stale chart draws, and the cell beside it still counts
                    // as one to prepare.
                    if (stale.contains(stem)) continue;
                    ready.put(stem, {}) catch {};
                }
            }
        }

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
                const stem = library.stemOf(c.name);
                if (ready.contains(stem)) continue;
                var f = library.fileOf(fa, c) catch continue;
                const id = identityOf(c, scan);
                f.edition = id.edition;
                f.update = id.update;
                // A shell prepares this cell again, and the list holds the
                // chart made from it as well.
                f.stale = @intFromBool(stale.contains(stem));
                const at: u32 = @intCast(found.items.len);
                found.append(fa, f) catch continue;
                if (c.kind == .source or c.kind == .raster_source or archive) todo.append(fa, at) catch {};
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
            if (c.kind == .source or archive) {
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
            if (c.kind == .raster_source or archive) unprepared += 1 else pictures += 1;
        }

        self.mu.lock();
        defer self.mu.unlock();
        for (self.rows.items) |*r| {
            if (!std.mem.eql(u8, r.path, path)) continue;
            var old: Retired = .{ .arena = r.files_arena, .openable = r.openable };
            r.openable = openable.toOwnedSlice(self.gpa) catch &.{};
            r.files_arena = files_arena;
            r.files = found.items;
            r.todo = todo.items;
            self.resolveNote(r.*, number);
            // A file to prepare that was not there when the prepare stopped
            // is a change, and the set may resume.
            if (r.stopped) |*held| {
                for (r.todo) |i| {
                    if (held.contains(keyHash(&r.files[i]))) continue;
                    held.deinit(self.gpa);
                    r.stopped = null;
                    break;
                }
            }
            r.charts = charts;
            r.pictures = pictures;
            r.unprepared = unprepared;
            r.bytes = scan.totalBytes();
            r.band_lo = lo;
            r.band_hi = hi;
            r.scanned = true;
            r.last_scan = number;
            // The agency when the charts agree on one, else the folder name.
            if (scan.producer) |p| {
                if (self.gpa.dupeZ(u8, &p)) |owned| {
                    old.producer = r.producer;
                    r.producer = owned;
                } else |_| {}
            }
            self.retired.append(self.gpa, old) catch old.free(self.gpa);
            self.gen +%= 1;
            self.dirty = true;
            if (self.on_scan) |f| f.call(f.ctx);
            return;
        }
        // The row went while the scan ran.
        if (self.on_scan) |f| f.call(f.ctx);
        for (openable.items) |o| {
            self.gpa.free(o.path);
            self.gpa.free(o.name);
        }
        openable.deinit(self.gpa);
        files_arena.deinit();
    }
};

/// The longest `refusalKey`: an 8 character name with room to spare, and two
/// u32s.
const refusal_key_max = 96;

/// One path in the form a bake note keys on: every separator a forward
/// slash. A shell hands the bake the paths a scan gave it, and on Windows a
/// scan writes a backslash while a shell that built the path itself writes
/// either. A path longer than the buffer is returned unchanged.
fn sepNormal(buf: []u8, p: []const u8) []const u8 {
    if (p.len > buf.len) return p;
    for (p, 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    return buf[0..p.len];
}

/// What a refusal is recorded under: the dataset name without its extension,
/// the edition and the update number. A new edition of a refused cell is a new
/// key, so it is prepared.
fn refusalKey(buf: *[refusal_key_max]u8, f: *const library.File) []const u8 {
    var name = library.stemOf(std.mem.span(f.name));
    if (name.len > refusal_key_max - 24) name = name[0 .. refusal_key_max - 24];
    return std.fmt.bufPrint(buf, "{s}/{d}/{d}", .{ name, f.edition, f.update }) catch unreachable;
}

fn keyHash(f: *const library.File) u64 {
    var buf: [refusal_key_max]u8 = undefined;
    return std.hash.Wyhash.hash(0, refusalKey(&buf, f));
}

/// A read's result, and the generation it was made in.
fn Kept(comptime T: type) type {
    return struct {
        gen: u64,
        out: []const T,
        /// The set path, for a `files` read.
        path: []const u8 = "",
    };
}

/// What one landing scan replaced on a row. A read may still point into any
/// of it.
const Retired = struct {
    arena: ?std.heap.ArenaAllocator = null,
    openable: []Openable = &.{},
    producer: ?[:0]u8 = null,

    fn free(self: *Retired, gpa: std.mem.Allocator) void {
        if (self.arena) |*a| a.deinit();
        freeOpenable(gpa, self.openable);
        if (self.producer) |p| gpa.free(p);
    }
};

fn freeOpenable(gpa: std.mem.Allocator, list: []Openable) void {
    for (list) |o| {
        gpa.free(o.path);
        gpa.free(o.name);
    }
    gpa.free(list);
}

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

/// A test allocator over `t.allocator` that records the ranges freed and the
/// bytes live. The scan worker allocates as well, so it locks.
///
/// It never resizes in place, so every change of size is an alloc and a free
/// that it sees.
const Watch = struct {
    mu: Lock = .{},
    live: usize = 0,
    freed: std.ArrayList([2]usize) = .empty,

    fn allocator(self: *Watch) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn deinit(self: *Watch) void {
        self.freed.deinit(t.allocator);
    }

    /// True when `ptr` lies in memory freed since it was last allocated.
    fn wasFreed(self: *Watch, ptr: anytype) bool {
        const at = @intFromPtr(ptr);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.freed.items) |r| {
            if (at >= r[0] and at < r[1]) return true;
        }
        return false;
    }

    fn liveBytes(self: *Watch) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.live;
    }

    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Watch = @ptrCast(@alignCast(ctx));
        const p = t.allocator.rawAlloc(len, al, ra) orelse return null;
        self.mu.lock();
        defer self.mu.unlock();
        self.live += len;
        // Memory handed out again is no longer freed.
        const lo = @intFromPtr(p);
        var i: usize = 0;
        while (i < self.freed.items.len) {
            const r = self.freed.items[i];
            if (r[0] < lo + len and lo < r[1]) {
                _ = self.freed.swapRemove(i);
            } else i += 1;
        }
        return p;
    }

    fn free(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, ra: usize) void {
        const self: *Watch = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        self.live -= mem.len;
        const at = @intFromPtr(mem.ptr);
        self.freed.append(t.allocator, .{ at, at + @max(mem.len, 1) }) catch {};
        self.mu.unlock();
        t.allocator.rawFree(mem, al, ra);
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

test "a cell written after its prepared chart is prepared again" {
    var f = try Fixture.init();
    defer f.deinit();

    const src = try f.folderNamed("Set A", &.{"US5MD1MC.000"});
    defer t.allocator.free(src);
    const root = try f.folderNamed("Prepared", &.{});
    defer t.allocator.free(root);
    try f.tmp.dir.createDirPath(f.io, "Prepared/Set A/US5MD1MC");
    try f.tmp.dir.writeFile(f.io, .{
        .sub_path = "Prepared/Set A/US5MD1MC/US5MD1MC.pmtiles",
        .data = "x",
    });

    // The update writes the cell again, after the chart made from it.
    sleepMs(20);
    try f.tmp.dir.writeFile(f.io, .{ .sub_path = "Set A/US5MD1MC.000", .data = "edition 28" });

    const s = try Sets.open(t.allocator, f.io, f.store, root, null);
    defer s.close();
    try t.expect(s.add(src));
    settle(s);

    const rows = s.all();
    try t.expectEqual(@as(usize, 1), rows.len);
    // The prepared chart still draws, and the cell beside it is one to
    // prepare.
    try t.expectEqual(@as(usize, 1), rows[0].charts);
    try t.expectEqual(@as(usize, 1), rows[0].unprepared);

    // The file list holds both, and says which one to prepare.
    var stale_cells: usize = 0;
    var baked: usize = 0;
    for (s.files(src)) |file| {
        if (file.stale != 0) stale_cells += 1;
        if (file.kind == .baked) baked += 1;
    }
    try t.expectEqual(@as(usize, 1), stale_cells);
    try t.expectEqual(@as(usize, 1), baked);
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

test "the set that loses a cell by name counts it as held back" {
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

    const rows = s.all();
    try t.expectEqual(@as(usize, 2), rows.len);
    for (rows) |r| {
        const is_mine = std.mem.eql(u8, std.mem.span(r.path), mine);
        // The download draws the cell. The mariner's copy is held back.
        try t.expectEqual(@as(usize, if (is_mine) 1 else 0), r.held_back);
    }

    // With the download switched off, no row holds a chart back.
    try t.expect(s.setOn(downloaded, false));
    for (s.all()) |r| try t.expectEqual(@as(usize, 0), r.held_back);
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
    s.mu.unlock();
    try t.expectEqual(@as(usize, 1), retired);

    // A read keeps it. A call that changes the list frees it.
    try t.expect(s.files(dir).len > 0);
    s.mu.lock();
    const after_read = s.retired.items.len;
    s.mu.unlock();
    try t.expectEqual(@as(usize, 1), after_read);
    try t.expect(s.setOn(dir, false));
    s.mu.lock();
    const after_change = s.retired.items.len;
    s.mu.unlock();
    try t.expectEqual(@as(usize, 0), after_change);
}

test "the list stays valid across a file read after a scan lands" {
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

    // The rescan is asked for before the list is read, so the only thing
    // between the read and the file reads below is the scan landing.
    try t.expect(s.rescan(a));
    const rows = s.all();
    try t.expectEqual(@as(usize, 2), rows.len);
    const want = [2]Set{ rows[0].*, rows[1].* };
    settle(s);

    // A shell reads each set's files inside its loop over the list.
    for (rows) |r| _ = s.files(std.mem.span(r.path));
    for (rows, want) |r, w| {
        try t.expectEqual(w.path, r.path);
        try t.expectEqual(w.title, r.title);
        try t.expectEqual(w.charts, r.charts);
        try t.expectEqual(w.band_hi, r.band_hi);
    }
    try t.expectEqualStrings(b, std.mem.span(rows[1].path));
}

test "a list held across a finished scan keeps its producer" {
    var f = try Fixture.init();
    defer f.deinit();
    const dir = try f.folder("Set A");
    defer t.allocator.free(dir);

    var w: Watch = .{};
    defer w.deinit();
    const s = try Sets.open(w.allocator(), f.io, f.store, "", null);
    defer s.close();
    try t.expect(s.add(dir));
    settle(s);

    // The list is read after the rescan is asked for, so the only thing
    // between it and the checks below is the worker landing the scan.
    try t.expect(s.rescan(dir));
    const rows = s.all();
    const producer = rows[0].producer;
    const composed = s.compose();
    try t.expectEqual(@as(usize, 1), composed.len);
    settle(s);

    // The scan replaced both, and freed neither.
    try t.expect(!w.wasFreed(producer));
    try t.expectEqualStrings("US", std.mem.span(producer));
    try t.expect(!w.wasFreed(composed[0]));
}

test "a list and a file read held across a finished scan stay valid through more reads" {
    var f = try Fixture.init();
    defer f.deinit();
    const dir = try f.folder("Set A");
    defer t.allocator.free(dir);

    var w: Watch = .{};
    defer w.deinit();
    const s = try Sets.open(w.allocator(), f.io, f.store, "", null);
    defer s.close();
    try t.expect(s.add(dir));
    settle(s);

    try t.expect(s.rescan(dir));
    const rows = s.all();
    const held = s.files(dir);
    try t.expect(held.len > 0);
    settle(s);

    // A shell reads again after the scan. Both reads return the new scan,
    // and what was held before stays readable.
    try t.expect(s.files(dir).ptr != held.ptr);
    try t.expect(s.all().ptr != rows.ptr);
    _ = s.compose();
    try t.expect(!w.wasFreed(rows.ptr));
    try t.expect(!w.wasFreed(rows[0].producer));
    try t.expect(!w.wasFreed(held.ptr));
    try t.expect(!w.wasFreed(held[0].path));
    try t.expectEqualStrings(dir, std.mem.span(rows[0].path));

    // A call that changes the list ends the borrow.
    try t.expect(s.setOn(dir, false));
    try t.expect(w.wasFreed(held[0].path));
}

test "reads between two changes allocate once" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = try f.folder("Set A");
    defer t.allocator.free(a);
    const b = try f.folder("Set B");
    defer t.allocator.free(b);

    var w: Watch = .{};
    defer w.deinit();
    const s = try Sets.open(w.allocator(), f.io, f.store, "", null);
    defer s.close();
    try t.expect(s.add(a));
    try t.expect(s.add(b));
    settle(s);

    const Reads = struct {
        fn round(x: *Sets, p: []const u8, q: []const u8) void {
            _ = x.all();
            _ = x.files(p);
            _ = x.files(q);
            _ = x.compose();
        }
    };
    Reads.round(s, a, b);
    const live = w.liveBytes();
    for (0..1000) |_| Reads.round(s, a, b);
    try t.expectEqual(live, w.liveBytes());
}

// ---- what a set still has to prepare ------------------------------------------

/// Write a prepared chart for `stem` under the fixture's prepared root.
fn prepare(f: *Fixture, set: []const u8, stem: []const u8) !void {
    var buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "Prepared/{s}/{s}", .{ set, stem });
    try f.tmp.dir.createDirPath(f.io, dir);
    var file_buf: [256]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buf, "{s}/{s}.pmtiles", .{ dir, stem });
    try f.tmp.dir.writeFile(f.io, .{ .sub_path = file, .data = "x" });
}

test "a stale cell is listed to prepare" {
    var f = try Fixture.init();
    defer f.deinit();
    const src = try f.folderNamed("Set A", &.{"US5MD1MC.000"});
    defer t.allocator.free(src);
    const root = try f.folderNamed("Prepared", &.{});
    defer t.allocator.free(root);
    try prepare(&f, "Set A", "US5MD1MC");
    // The update writes the cell again, after the chart made from it.
    sleepMs(20);
    try f.tmp.dir.writeFile(f.io, .{ .sub_path = "Set A/US5MD1MC.000", .data = "edition 28" });

    const s = try Sets.open(t.allocator, f.io, f.store, root, null);
    defer s.close();
    try t.expect(s.add(src));
    settle(s);

    const list = s.toPrepare(src);
    try t.expectEqual(@as(usize, 1), list.len);
    try t.expectEqual(library.FileKind.source, list[0].kind);
    try t.expectEqual(@as(c_int, 1), list[0].stale);
    const row = s.all()[0];
    try t.expectEqual(@as(usize, 1), row.to_prepare);
    try t.expectEqual(@as(usize, 1), row.band_todo[4]);
}

test "a refused cell is not listed after its bake result is noted" {
    var f = try Fixture.init();
    defer f.deinit();
    const src = try f.folderNamed("Set A", &.{ "US5MD1MC.000", "US5MD2MC.000" });
    defer t.allocator.free(src);
    const root = try f.folderNamed("Prepared", &.{});
    defer t.allocator.free(root);
    const one = try std.fmt.allocPrintSentinel(t.allocator, "{s}/US5MD1MC.000", .{src}, 0);
    defer t.allocator.free(one);
    const two = try std.fmt.allocPrintSentinel(t.allocator, "{s}/US5MD2MC.000", .{src}, 0);
    defer t.allocator.free(two);

    {
        const s = try Sets.open(t.allocator, f.io, f.store, root, null);
        defer s.close();
        try t.expect(s.add(src));
        settle(s);
        try t.expectEqual(@as(usize, 2), s.toPrepare(src).len);

        // The bake is given both cells and writes a chart for one.
        try prepare(&f, "Set A", "US5MD1MC");
        s.noteBake(src, &.{ one, two }, true);
        // The note waits for the scan that reads the bake's output.
        try t.expectEqual(@as(usize, 2), s.toPrepare(src).len);
        try t.expect(s.rescan(src));
        settle(s);

        try t.expectEqual(@as(usize, 0), s.toPrepare(src).len);
        const row = s.all()[0];
        try t.expectEqual(@as(usize, 0), row.to_prepare);
        try t.expectEqual(@as(usize, 1), row.refused);
        try t.expectEqual(@as(usize, 1), row.unprepared);
    }

    // The refusal is saved, so the next launch does not bake the cell again.
    const s = try Sets.open(t.allocator, f.io, f.store, root, null);
    defer s.close();
    settle(s);
    try t.expectEqual(@as(usize, 0), s.toPrepare(src).len);
    try t.expectEqual(@as(usize, 1), s.all()[0].refused);
}

test "a bake noted while an earlier scan runs waits for the next one" {
    var f = try Fixture.init();
    defer f.deinit();
    const src = try f.folderNamed("Set A", &.{"US5MD1MC.000"});
    defer t.allocator.free(src);
    const cell = try std.fmt.allocPrintSentinel(t.allocator, "{s}/US5MD1MC.000", .{src}, 0);
    defer t.allocator.free(cell);

    const s = try f.open();
    defer s.close();
    try t.expect(s.add(src));
    settle(s);

    // A scan that started before the note read the folder before the bake
    // wrote anything, so it cannot say what the bake refused.
    s.mu.lock();
    s.scans += 1;
    const early = s.scans;
    s.mu.unlock();
    s.noteBake(src, &.{cell}, true);
    s.mu.lock();
    s.resolveNote(s.rows.items[0], early);
    const waiting = s.notes.items.len;
    s.mu.unlock();
    try t.expectEqual(@as(usize, 1), waiting);
    try t.expectEqual(@as(usize, 1), s.toPrepare(src).len);
}

test "a cancel stops the resume until the set changes" {
    var f = try Fixture.init();
    defer f.deinit();
    const src = try f.folderNamed("NOAA", &.{ "US5MD1MC.000", "US5MD2MC.000" });
    defer t.allocator.free(src);
    const root = try f.folderNamed("Prepared", &.{});
    defer t.allocator.free(root);

    const s = try Sets.open(t.allocator, f.io, f.store, root, null);
    defer s.close();
    try t.expect(s.add(src));
    settle(s);
    // Only a downloader's set resumes. The mariner's own is prepared when
    // it is added.
    try t.expect(s.resumePath() == null);
    try t.expect(s.setManaged(src, true));
    try t.expectEqualStrings(src, s.resumePath().?);

    // The mariner stops the bake after one chart, and the set is read again.
    s.noteCancel(src);
    try t.expect(s.resumePath() == null);
    try prepare(&f, "NOAA", "US5MD1MC");
    try t.expect(s.rescan(src));
    settle(s);
    try t.expectEqual(@as(usize, 1), s.all()[0].to_prepare);
    try t.expect(s.resumePath() == null);

    // A download brings a cell that was not there when the bake stopped.
    try f.tmp.dir.writeFile(f.io, .{ .sub_path = "NOAA/US4MD1PM.000", .data = "x" });
    try t.expect(s.rescan(src));
    // Not while the set is being read.
    try t.expect(s.resumePath() == null);
    settle(s);
    try t.expectEqualStrings(src, s.resumePath().?);

    // A bake that failed stops it the same way.
    s.noteBake(src, &.{}, false);
    try t.expect(s.resumePath() == null);
}

test "the counts match the list" {
    var f = try Fixture.init();
    defer f.deinit();
    const src = try f.folderNamed("Set A", &.{
        "US3EC1AA.000", "US5MD1MC.000", "US5MD2MC.000", "11013_1.KAP", "US4MD1PM.pmtiles",
    });
    defer t.allocator.free(src);
    const root = try f.folderNamed("Prepared", &.{});
    defer t.allocator.free(root);
    const refused = try std.fmt.allocPrintSentinel(t.allocator, "{s}/US5MD2MC.000", .{src}, 0);
    defer t.allocator.free(refused);

    const s = try Sets.open(t.allocator, f.io, f.store, root, null);
    defer s.close();
    try t.expect(s.add(src));
    settle(s);
    s.noteBake(src, &.{refused}, true);
    try t.expect(s.rescan(src));
    settle(s);

    const list = s.toPrepare(src);
    const row = s.all()[0];
    // Two cells and the sheet. The chart draws now, and one cell was
    // refused.
    try t.expectEqual(@as(usize, 3), list.len);
    try t.expectEqual(list.len, row.to_prepare);
    try t.expectEqual(@as(usize, 1), row.refused);
    try t.expectEqual(row.unprepared, row.to_prepare + row.refused);

    var bands: [6]usize = @splat(0);
    for (list) |x| {
        if (x.band >= 1 and x.band <= 6) bands[@intCast(x.band - 1)] += 1;
    }
    try t.expectEqualSlices(usize, &bands, &row.band_todo);
    try t.expectEqual(@as(usize, 1), row.band_todo[2]);
    try t.expectEqual(@as(usize, 1), row.band_todo[4]);
}

/// An inventory that lists one baked chart inside any .zip, as the engine
/// lists an archive's entries. Any other path falls back to the name walk.
fn oneBakedEntry(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    path: []const u8,
    out: *std.ArrayList(library.InventoryRow),
) bool {
    if (!bake.isArchive(path)) return false;
    out.append(alloc, .{
        .path = alloc.dupe(u8, "US5MD1MC/US5MD1MC.pmtiles") catch return false,
        .name = alloc.dupe(u8, "US5MD1MC") catch return false,
        .kind = .baked,
        .bytes = 900,
    }) catch return false;
    return true;
}

test "a zip's baked chart is listed to prepare until it is lifted" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(f.io, .{ .sub_path = "Set.zip", .data = "x" });
    const zip = try std.fmt.allocPrint(t.allocator, "{s}/Set.zip", .{f.dir});
    defer t.allocator.free(zip);
    const root = try f.folderNamed("Prepared", &.{});
    defer t.allocator.free(root);

    const s = try Sets.open(t.allocator, f.io, f.store, root, oneBakedEntry);
    defer s.close();
    try t.expect(s.add(zip));
    settle(s);

    const list = s.toPrepare(zip);
    try t.expectEqual(@as(usize, 1), list.len);
    try t.expectEqual(library.FileKind.baked, list[0].kind);
    try t.expectEqualStrings("US5MD1MC/US5MD1MC.pmtiles", std.mem.span(list[0].path));
    var row = s.all()[0];
    try t.expectEqual(@as(usize, 1), row.to_prepare);
    try t.expectEqual(@as(usize, 1), row.band_todo[4]);
    try t.expectEqual(@as(usize, 0), row.charts);
    // An entry name is no file the engine can open.
    try t.expectEqual(@as(usize, 0), s.compose().len);

    // The bake lifts the chart out under the prepared root.
    try prepare(&f, "Set", "US5MD1MC");
    try t.expect(s.rescan(zip));
    settle(s);
    try t.expectEqual(@as(usize, 0), s.toPrepare(zip).len);
    row = s.all()[0];
    try t.expectEqual(@as(usize, 0), row.to_prepare);
    try t.expectEqual(@as(usize, 1), row.charts);
    try t.expectEqual(@as(usize, 1), s.compose().len);
}
