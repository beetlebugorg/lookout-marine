//! Downloading NOAA's charts: the catalog, the plan, and the transfer.
//!
//! The core decides which cells a region needs (src/noaa.zig), asks the shell
//! for each url, and writes the exchange-set zips into a staging directory.
//! The shell fetches bytes and bakes the directory afterward. No socket opens
//! here, for the reason chart links give: one fetcher serves the whole app,
//! and the shell owns it.
//!
//! A district arrives as one zip where NOAA publishes one, so a region costs a
//! handful of requests rather than a thousand. Those zips run to a couple of
//! hundred megabytes, so a body is written to its part file as it arrives
//! (lookout_http_respond_chunk) and never held whole.
//!
//! Request ids have bit 63 set so lookout_http_respond can route an answer to
//! this service or to chartlinks without the two sharing an id space.

const std = @import("std");
const noaa = @import("noaa.zig");
const clinks = @import("chartlinks.zig");
const lock = @import("lock.zig");
const Lock = lock.Lock;
const clock = @import("clock.zig");
const httpgather = @import("httpgather.zig");
const cachedir = @import("cachedir.zig");
const chartsets = @import("chartsets.zig");
const settings = @import("settings.zig");

/// Set on every request id this service issues.
pub const id_mark: u64 = @as(u64, 1) << 63;

/// True when this answer belongs to a NOAA download.
pub fn ownsId(id: u64) bool {
    return id & id_mark != 0;
}

/// How many cell zips transfer at once. NOAA serves a public archive, and a
/// mariner on a marina uplink gains little past four.
pub const MAX_INFLIGHT = 4;


/// A cell zip larger than this is not the file we asked for. The catalog has
/// a limit of its own, noaa.max_catalog_bytes.
pub const MAX_ZIP_BYTES: u64 = 64 << 20;

/// The same guard for a district bundle. NOAA's largest is Alaska, measured at
/// 222.7 MB on 2026-09-12; the room above that is for the districts growing.
pub const MAX_BUNDLE_BYTES: u64 = 512 << 20;

/// What the service is doing.
pub const Phase = enum(u8) {
    idle = 0,
    /// One request out for ENCProdCat.xml.
    reading_catalog = 1,
    /// A catalog is loaded and a selection can be priced.
    ready = 2,
    downloading = 3,
};

/// How the last download ended, or that it is still running.
pub const Outcome = enum(u8) {
    /// No download has started on this service.
    none = 0,
    running = 1,
    /// The plan ran to its end and at least one chart arrived. Some may have
    /// failed; `failed` counts them.
    finished = 2,
    /// Every chart the order named is already installed, or an update found
    /// no reissue. No request went out.
    empty = 3,
    /// Stopped by a cancel, by a new download, or by clearing the fetcher.
    cancelled = 4,
    /// The plan ran to its end with no chart arriving, or hit an error.
    failed = 5,
    /// The order ended before any transfer: no catalog, no fetcher, or no
    /// download directory.
    refused = 6,
};

/// Called when a response is queued for adopt. From any thread, possibly
/// inside the shell's own call to respond.
pub const WakeFn = *const fn (user: ?*anyopaque) callconv(.c) void;

/// One cell to fetch. The slices point into the catalog arena.
const Job = struct {
    /// What the answer is written as while it is unpacked. Owned, because a
    /// bundle's name is built rather than read out of the catalog.
    name: []const u8,
    /// Owned, for the same reason.
    url: []const u8,
    bytes: u64,
    /// How many of the picked cells this transfer brings. One for a cell, a
    /// district's worth for a bundle, so the count a mariner watches stays a
    /// count of charts.
    cells: u32 = 1,
    /// The district a bundle covers, 0 for a single cell. A bundle NOAA has
    /// moved answers 404, and the cells it stood for are asked for instead.
    district: u8 = 0,
};

const Kind = enum { catalog, cell };

const Req = struct {
    id: u64,
    kind: Kind,
    /// Index into `plan` for a cell request.
    job: usize = 0,
};

const Answer = struct {
    id: u64,
    /// The catalog's bytes. A cell's bytes are unpacked on the fetch thread
    /// and do not reach here.
    bytes: []u8,
    status: c_int,
    /// A cell zip that was unpacked into the staging directory, and its size.
    stored: bool = false,
    size: usize = 0,
    /// Set when the unpack failed, for the error adopt reports.
    write_failed: bool = false,
};

/// One outstanding transfer, written to disk as it arrives.
///
/// A district bundle runs to a couple of hundred megabytes, which no phone can
/// hold in memory alongside the copy the shell made and the copy the core
/// would make. So the body goes to `<dest>/<name>.zip.part` a piece at a time
/// and the file is what gets unpacked.
const Stage = struct {
    id: u64,
    name: []u8,
    /// Opened on the first piece of the body, closed on the last.
    file: ?std.Io.File = null,
    /// What has been written so far.
    size: u64 = 0,
    /// What the transfer may reach before it is not the file we asked for.
    limit: u64 = MAX_ZIP_BYTES,
    /// Set when a piece would not write or the body ran past the limit. The
    /// rest is dropped and the answer reports a failure.
    broken: bool = false,
    /// The directory the part file is in, set when the file is created. A
    /// later download sets a new `stage_dest`, and this file stays here.
    dest: []u8 = &.{},
};

/// One transfer on disk, waiting to be unpacked. The unpack thread owns the
/// name and the directory once it is queued.
const Pending = struct {
    id: u64,
    name: []u8,
    /// The directory the transfer was staged in.
    dest: []u8,
    size: u64,
    status: c_int,
};

/// One unpack thread and the transfers queued for it. Each download starts
/// its own, so a stopped thread drops only its own queue, and a new download
/// does not wait for it to end.
const Unpacker = struct {
    thread: std.Thread = undefined,
    /// Guarded by `Service.unpack_mu`.
    q: std.ArrayList(Pending) = .empty,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by the thread as it returns, so adopt can join it without waiting.
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The cells this download leaves alone, sorted, copied from `held` when
    /// the thread starts. A bundle holds every cell in its district, and the
    /// ones already held are neither deleted nor extracted. Empty when the
    /// download fetches held cells as well.
    skip: [][]u8 = &.{},
};

/// The snapshot a shell renders. Plain data, copied out under the api lock.
pub const State = extern struct {
    phase: u8 = 0,
    /// 1 once a catalog is loaded.
    have_catalog: u8 = 0,
    /// NOAA's validity date for the loaded catalog, "20250903".
    date: [16]u8 = @splat(0),
    /// Unix seconds of the last catalog read that succeeded. 0 for never.
    checked_at: i64 = 0,
    /// Cells in the catalog.
    catalog_cells: u32 = 0,
    /// The current download.
    total: u32 = 0,
    done: u32 = 0,
    failed: u32 = 0,
    bytes_total: u64 = 0,
    bytes_done: u64 = 0,
    /// What went wrong, or an empty string.
    err: [256]u8 = @splat(0),
    /// An Outcome.
    outcome: u8 = 0,
    /// Counts the downloads ordered on this service. The first is 1.
    run: u32 = 0,
    /// 1 when ordering again can clear the cause of a failed or refused
    /// download.
    retry: u8 = 0,
};

/// The catalog, the plan, and the transfer.
pub const Service = struct {
    alloc: std.mem.Allocator,

    get: ?clinks.HttpGetFn = null,
    cancel: ?clinks.HttpCancelFn = null,
    /// Called after each response is queued, so a shell with no frame loop
    /// running knows to adopt it. Null for a service on a chart handle,
    /// whose frame loop adopts.
    wake: ?WakeFn = null,
    user: ?*anyopaque = null,

    cat: ?noaa.Catalog = null,
    checked_at: i64 = 0,
    /// Counts the catalog reads from the network that succeeded. 0 while the
    /// catalog in hand is the cached one, which can predate a reissue.
    fresh_reads: u32 = 0,
    err: []u8 = &.{},
    phase: Phase = .idle,
    /// A catalog read is out. Held apart from `phase`, because a read can run
    /// beside a download and the download's end is read off the phase.
    catalog_inflight: bool = false,
    /// Raised when the snapshot needs publishing.
    changed: bool = false,

    /// The download's number, and how it ended.
    run: u32 = 0,
    outcome: Outcome = .none,
    /// Ordering again can clear the cause: the catalog was missing, or a
    /// transfer failed on the network.
    retry: bool = false,

    next_req: u64 = 1,
    reqs: std.ArrayList(Req) = .empty,

    plan: std.ArrayList(Job) = .empty,
    next_job: usize = 0,
    inflight: usize = 0,
    done: u32 = 0,
    failed: u32 = 0,
    bytes_done: u64 = 0,
    bytes_total: u64 = 0,
    dest: []u8 = &.{},

    /// The staging directory and the cell behind each outstanding request, as
    /// the fetch threads read them.
    ///
    /// A second lock, and not the api lock. Unpacking a cell is file work.
    /// Doing it where adopt runs held the api lock for the length of the
    /// download, the shell's poll blocked on that lock, and the count sat at
    /// 1 of 829 while the disk filled.
    stage_mu: Lock = .{},
    stage_dest: []u8 = &.{},
    stage: std.ArrayList(Stage) = .empty,

    /// The cells this device already holds, sorted by name, so picking water
    /// that is already downloaded fetches what is missing from it. A Handle
    /// with chart sets reads them off the sets. The chart handle's service is
    /// handed them by the shell.
    held: std.ArrayList([]u8) = .empty,

    /// Cells fetched and not yet written, and the thread that writes them.
    ///
    /// A thread of its own, because writing a cell is file work of a few
    /// milliseconds. On the frame loop it held the api lock and the window
    /// stopped repainting. On the fetch thread it held the shell's fetch
    /// lock, which the frame loop needs to start the next transfer. Under
    /// both, the count sat at 1 of 829 while the disk filled.
    unpack_mu: Lock = .{},
    /// The current download's unpack thread.
    unpacker: ?*Unpacker = null,
    /// Stopped threads that adopt has not joined yet.
    reap: std.ArrayList(*Unpacker) = .empty,
    /// Held while one transfer is unpacked. A stopped thread may still be on
    /// its last transfer when the next download's thread starts, and both
    /// can write the same directory.
    unpack_work: Lock = .{},

    /// The snapshot a shell reads, and the lock that guards it.
    ///
    /// A lock of its own, held for one struct copy. The api lock is
    /// os_unfair_lock and the frame loop reclaims it the instant it drops it,
    /// so a poll on the main thread blocked for the whole download and the
    /// count read 0 of 829 until it ended.
    pub_mu: Lock = .{},
    pub_state: State = .{},
    /// Set when a publish stores a state that differs from the one before,
    /// and cleared by takeChanged. Guarded by pub_mu.
    pub_changed: bool = false,

    /// Whether this download was asked to fetch water already held. Kept for
    /// the bundle fallback, which plans the same cells a second time.
    again: bool = false,

    /// Set by a piece of a transfer, and cleared by the adopt that publishes
    /// the bytes it brought.
    progress: std.atomic.Value(bool) = .init(false),
    /// When a piece last woke the shell, in monotonic milliseconds. Pieces
    /// arrive on several fetch threads at once.
    progress_woke_ms: std.atomic.Value(i64) = .init(0),

    /// Answers from the shell's fetch threads, guarded by inbox_mu alone.
    inbox_mu: Lock = .{},
    inbox: std.ArrayList(Answer) = .empty,
    inbox_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// The catalog, held until it is whole. Everything else this service
    /// fetches goes to disk as it arrives.
    gather: httpgather.Gather = undefined,

    pub fn init(alloc: std.mem.Allocator) Service {
        return .{
            .alloc = alloc,
            .gather = httpgather.Gather.init(alloc, noaa.max_catalog_bytes),
        };
    }

    pub fn deinit(self: *Service) void {
        for (self.held.items) |n| self.alloc.free(n);
        self.held.deinit(self.alloc);
        self.cancelAll();
        // After cancelAll, which clears it.
        self.gather.deinit();
        self.stopUnpacker();
        self.reap.deinit(self.alloc);
        self.freeStr(&self.stage_dest);
        self.stage.deinit(self.alloc);
        if (self.cat) |*c| c.deinit();
        self.cat = null;
        self.freeStr(&self.err);
        if (self.dest.len != 0) self.alloc.free(self.dest);
        self.dest = &.{};
        self.freePlan();
        self.plan.deinit(self.alloc);
        self.reqs.deinit(self.alloc);
        for (self.inbox.items) |a| self.alloc.free(a.bytes);
        self.inbox.deinit(self.alloc);
    }

    fn freeStr(self: *Service, s: *[]u8) void {
        if (s.len != 0) self.alloc.free(s.*);
        s.* = &.{};
    }

    fn setErr(self: *Service, msg: []const u8) void {
        self.freeStr(&self.err);
        self.err = self.alloc.dupe(u8, msg) catch &.{};
        self.changed = true;
    }

    // ---- the shell's fetcher ----------------------------------------------

    pub fn setProvider(self: *Service, get: ?clinks.HttpGetFn, cancel: ?clinks.HttpCancelFn, wake: ?WakeFn, user: ?*anyopaque) void {
        self.get = get;
        self.cancel = cancel;
        self.wake = wake;
        self.user = user;
        if (get == null) self.cancelAll();
    }

    /// Hand one url to the shell. Returns the request id, or 0 when no
    /// fetcher is set or the request could not be recorded.
    /// Record which cell an outstanding request fetches, for the fetch
    /// thread.
    fn stageCell(self: *Service, id: u64, name: []const u8, limit: u64) void {
        const own = self.alloc.dupe(u8, name) catch return;
        self.stage_mu.lock();
        defer self.stage_mu.unlock();
        self.stage.append(self.alloc, .{
            .id = id,
            .name = own,
            .limit = limit,
        }) catch self.alloc.free(own);
    }

    /// Write one piece of a transfer to its part file. Returns false for a
    /// request that is not a staged transfer.
    ///
    /// Under stage_mu for the write: four fetch threads run at once, the disk
    /// serializes them anyway, and holding the lock keeps the entry from
    /// moving under a thread mid-write.
    fn appendStaged(self: *Service, id: u64, bytes: []const u8, status: c_int) bool {
        self.stage_mu.lock();
        defer self.stage_mu.unlock();
        var at: ?usize = null;
        for (self.stage.items, 0..) |st, i| {
            if (st.id == id) at = i;
        }
        const st = &self.stage.items[at orelse return false];
        if (st.broken) return true;
        if (status < 200 or status >= 300) {
            st.broken = true;
            return true;
        }
        if (bytes.len == 0) return true;
        if (st.size + bytes.len > st.limit) {
            st.broken = true;
            return true;
        }
        const io = std.Io.Threaded.global_single_threaded.io();
        if (st.file == null) {
            if (self.stage_dest.len == 0) {
                st.broken = true;
                return true;
            }
            var buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}.zip.part", .{ self.stage_dest, st.name }) catch {
                st.broken = true;
                return true;
            };
            st.dest = self.alloc.dupe(u8, self.stage_dest) catch {
                st.broken = true;
                return true;
            };
            st.file = std.Io.Dir.cwd().createFile(io, path, .{}) catch {
                st.broken = true;
                return true;
            };
        }
        st.file.?.writeStreamingAll(io, bytes) catch {
            st.broken = true;
            return true;
        };
        st.size += bytes.len;
        return true;
    }

    /// Close a finished transfer and take what it came to. The caller owns the
    /// name and frees it.
    fn takeStaged(self: *Service, id: u64) ?Stage {
        self.stage_mu.lock();
        defer self.stage_mu.unlock();
        for (self.stage.items, 0..) |st, i| {
            if (st.id != id) continue;
            var taken = self.stage.swapRemove(i);
            if (taken.file) |f| {
                f.close(std.Io.Threaded.global_single_threaded.io());
                taken.file = null;
            }
            return taken;
        }
        return null;
    }

    /// Where the fetch threads unpack. Set when the download starts, before
    /// any request goes out.
    fn setStageDest(self: *Service, dest: []const u8) void {
        const own = self.alloc.dupe(u8, dest) catch return;
        self.stage_mu.lock();
        defer self.stage_mu.unlock();
        if (self.stage_dest.len != 0) self.alloc.free(self.stage_dest);
        self.stage_dest = own;
    }

    fn clearStage(self: *Service) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.stage_mu.lock();
        defer self.stage_mu.unlock();
        for (self.stage.items) |st| {
            if (st.file) |f| f.close(io);
            self.alloc.free(st.name);
            if (st.dest.len != 0) self.alloc.free(st.dest);
        }
        self.stage.clearRetainingCapacity();
    }

    fn issue(self: *Service, url: []const u8, kind: Kind, job: usize) u64 {
        const get = self.get orelse return 0;
        const z = self.alloc.dupeZ(u8, url) catch return 0;
        defer self.alloc.free(z);
        const id = self.next_req | id_mark;
        self.next_req += 1;
        self.reqs.append(self.alloc, .{ .id = id, .kind = kind, .job = job }) catch return 0;
        if (kind == .catalog and !self.gather.begin(id)) {
            _ = self.reqs.pop();
            return 0;
        }
        if (kind == .cell) {
            const t = self.plan.items[job];
            self.stageCell(id, t.name, if (t.district == 0) MAX_ZIP_BYTES else MAX_BUNDLE_BYTES);
        }
        // The api lock is held. The shell starts the fetch and returns. It may
        // respond before this call ends, and respond only enqueues, so that
        // ordering is safe.
        get(self.user, id, z.ptr, 0);
        return id;
    }

    fn retire(self: *Service, id: u64) ?Req {
        for (self.reqs.items, 0..) |r, i| {
            if (r.id == id) return self.reqs.swapRemove(i);
        }
        return null;
    }

    /// Drop every outstanding request and tell the shell it may stop.
    pub fn cancelAll(self: *Service) void {
        if (self.cancel) |c| {
            for (self.reqs.items) |r| c(self.user, r.id);
        }
        self.reqs.clearRetainingCapacity();
        self.gather.clear();
        self.clearStage();
        self.inflight = 0;
        self.catalog_inflight = false;
        if (self.phase == .downloading) self.outcome = .cancelled;
        if (self.phase == .downloading or self.phase == .reading_catalog) {
            self.phase = if (self.cat != null) .ready else .idle;
            self.changed = true;
        }
    }

    // ---- the catalog ------------------------------------------------------

    /// What the cached catalog is called, under cachedir.fetchedDir.
    const catalog_file = "ENCProdCat.xml";

    /// The catalog's path in the cache, or null when no cache root resolves.
    /// Owned by `alloc`.
    fn catalogCachePath(self: *Service) ?[]u8 {
        const dir = cachedir.fetchedDir(self.alloc) orelse return null;
        defer self.alloc.free(dir);
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ dir, catalog_file }) catch null;
    }

    /// Store the catalog just parsed, so the next run has one before it has a
    /// network.
    ///
    /// Writes through a temporary and a rename, as every other write here
    /// does. A machine that loses power mid-write keeps the catalog it already
    /// had.
    fn cacheCatalog(self: *Service, bytes: []const u8) void {
        const path = self.catalogCachePath() orelse return;
        defer self.alloc.free(path);
        const tmp = std.fmt.allocPrint(self.alloc, "{s}.new", .{path}) catch return;
        defer self.alloc.free(tmp);

        const io = std.Io.Threaded.global_single_threaded.io();
        const cwd = std.Io.Dir.cwd();
        cwd.writeFile(io, .{ .sub_path = tmp, .data = bytes }) catch return;
        cwd.rename(tmp, cwd, path, io) catch {
            cwd.deleteFile(io, tmp) catch {};
        };
    }

    /// Load the catalog this device last read from the disk.
    ///
    /// This is what lets a mariner price and remove water with no network.
    /// Every region control requires a catalog, and the picker is the only
    /// route into a downloaded set. An old catalog still names the cells the
    /// device holds. It can be wrong only about water not yet downloaded, and
    /// the network read that follows corrects that.
    ///
    /// `checked_at` comes from the file's mtime, so the picker reports when
    /// the catalog was read.
    fn loadCachedCatalog(self: *Service) void {
        if (self.cat != null) return;
        const path = self.catalogCachePath() orelse return;
        defer self.alloc.free(path);

        const io = std.Io.Threaded.global_single_threaded.io();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc,
                                                     .limited(noaa.max_catalog_bytes)) catch return;
        defer self.alloc.free(bytes);

        var parsed = noaa.parse(self.alloc, bytes) catch return;
        if (parsed.cells.len == 0) {
            parsed.deinit();
            return;
        }
        self.cat = parsed;
        self.checked_at = cachedFileSeconds(io, path);
        self.phase = .ready;
        self.changed = true;
    }

    /// When a cached file was last written, in unix seconds. 0 when unknown,
    /// which the picker shows as never checked.
    fn cachedFileSeconds(io: std.Io, path: []const u8) i64 {
        const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
        defer f.close(io);
        const st = f.stat(io) catch return 0;
        return @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s));
    }

    /// Read NOAA's product catalog. One request is outstanding at a time.
    ///
    /// A read during a download leaves the phase at downloading. Every shell
    /// reads the download's end off the phase, so a read that moved it ended
    /// the download there and stranded the rest of the plan.
    pub fn refresh(self: *Service) void {
        if (self.catalog_inflight) return;
        // Load the cached catalog first, so the picker works while the read
        // below is in flight and after it fails.
        self.loadCachedCatalog();
        if (self.get == null) {
            self.setErr("no network provider");
            return;
        }
        if (self.phase != .downloading) {
            self.freeStr(&self.err);
            self.phase = .reading_catalog;
        }
        self.catalog_inflight = true;
        self.changed = true;
        if (self.issue(noaa.catalog_url, .catalog, 0) == 0) {
            self.catalogEnded();
            self.setErr("could not start the catalog request");
        }
    }

    /// End the catalog read, whether or not it succeeded.
    fn catalogEnded(self: *Service) void {
        self.catalog_inflight = false;
        if (self.phase != .downloading) self.phase = if (self.cat != null) .ready else .idle;
        self.changed = true;
    }

    pub fn haveCatalog(self: *const Service) bool {
        return self.cat != null;
    }

    /// What downloading these regions costs. Returns a zero cost when no
    /// catalog is loaded.
    pub fn costOf(self: *Service, districts: []const u8) noaa.Cost {
        const cat = &(self.cat orelse return .{});
        const picked = noaa.selectRegions(self.alloc, cat, districts) catch return .{};
        defer self.alloc.free(picked);
        return noaa.cost(cat, picked, self.held.items);
    }

    /// The dataset names of every cell covering these regions, in catalog
    /// order. Borrowed from the catalog, so valid until the next read.
    ///
    /// A shell removing water needs the names, because regions overlap: NOAA
    /// files a cell under one district that covers another's water, and the
    /// cells to delete are the unpicked regions' minus every region still
    /// picked.
    pub fn cellsOf(self: *Service, districts: []const u8, out: *std.ArrayList([]const u8)) void {
        const cat = &(self.cat orelse return);
        const picked = noaa.selectRegions(self.alloc, cat, districts) catch return;
        defer self.alloc.free(picked);
        for (picked) |i| {
            if (i >= cat.cells.len) continue;
            out.append(self.alloc, cat.cells[i].name) catch return;
        }
    }

    /// Replace the list of cells this device holds. Sorted here, so the
    /// caller hands them over in whatever order it walked its folders.
    pub fn setHeld(self: *Service, names: []const []const u8) void {
        for (self.held.items) |n| self.alloc.free(n);
        self.held.clearRetainingCapacity();
        for (names) |n| {
            if (n.len == 0) continue;
            const copy = self.alloc.dupe(u8, n) catch continue;
            self.held.append(self.alloc, copy) catch {
                self.alloc.free(copy);
                break;
            };
        }
        std.mem.sort([]u8, self.held.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        self.changed = true;
    }

    // ---- the download -----------------------------------------------------

    /// Download every cell covering these regions into `dest`.
    ///
    /// Replaces any download already running. `dest` is created if it does not
    /// exist, and each cell is written there as <NAME>.zip for the shell to
    /// bake as one directory.
    /// `again` fetches the cells this device already holds as well, so a
    /// mariner can repair or refresh water they have.
    /// How many charts the plan brings. That is what a mariner counts, and a
    /// bundle is one transfer and a district's worth of charts.
    fn planCells(self: *const Service) u32 {
        var n: u32 = 0;
        for (self.plan.items) |j| n += j.cells;
        return n;
    }

    /// Free the strings a plan owns. The catalog may go before the plan does.
    fn freePlan(self: *Service) void {
        for (self.plan.items) |j| {
            self.alloc.free(j.name);
            self.alloc.free(j.url);
        }
        self.plan.clearRetainingCapacity();
    }

    /// Take one transfer onto the plan, copying the strings it needs.
    fn planAppend(self: *Service, name: []const u8, url: []const u8, bytes: u64, cells: u32, district: u8) void {
        const n = self.alloc.dupe(u8, name) catch return;
        const u = self.alloc.dupe(u8, url) catch {
            self.alloc.free(n);
            return;
        };
        self.plan.append(self.alloc, .{
            .name = n,
            .url = u,
            .bytes = bytes,
            .cells = cells,
            .district = district,
        }) catch {
            self.alloc.free(n);
            self.alloc.free(u);
            return;
        };
        self.bytes_total += bytes;
    }

    /// Number a new download and mark it running.
    fn beginRun(self: *Service) void {
        self.run +%= 1;
        self.outcome = .running;
        self.retry = false;
        self.changed = true;
    }

    /// End the current download with `outcome`, and state why.
    fn endRun(self: *Service, outcome: Outcome, why: []const u8) void {
        if (why.len != 0) self.setErr(why);
        self.outcome = outcome;
        self.changed = true;
    }

    /// End an order before it starts. A download already running goes on
    /// and keeps its number.
    fn refuse(self: *Service, outcome: Outcome, why: []const u8, retry: bool) void {
        if (self.phase == .downloading) {
            self.setErr(why);
            return;
        }
        self.beginRun();
        self.retry = retry;
        self.endRun(outcome, why);
    }

    pub fn start(self: *Service, districts: []const u8, dest: []const u8, again: bool) void {
        const cat = &(self.cat orelse return self.refuse(.refused, "no catalog yet", true));
        if (self.get == null) return self.refuse(.refused, "no network provider", false);

        self.cancelAll();
        self.beginRun();
        self.freePlan();
        self.again = again;
        self.next_job = 0;
        self.done = 0;
        self.failed = 0;
        self.bytes_done = 0;
        self.bytes_total = 0;
        self.freeStr(&self.err);

        // A district arrives as one zip where it can. NOAA serves a public
        // archive, and a region holds hundreds of cells: asking for each one
        // is hundreds of requests for water a single bundle already answers.
        const fetches = noaa.planFetches(self.alloc, cat, districts, self.held.items, again) catch
            return self.endRun(.failed, "out of memory planning the download");
        defer self.alloc.free(fetches);

        var url_buf: [256]u8 = undefined;
        var name_buf: [64]u8 = undefined;
        for (fetches) |t| {
            if (t.cell) |i| {
                const c = cat.cells[i];
                self.planAppend(c.name, c.zip_url, c.zip_bytes, 1, 0);
                continue;
            }
            const url = noaa.bundleUrl(&url_buf, t.district) catch continue;
            const name = std.fmt.bufPrint(&name_buf, "{d:0>2}CGD_ENCs", .{t.district}) catch continue;
            self.planAppend(name, url, t.bytes, t.cells, t.district);
        }
        if (self.plan.items.len == 0)
            return self.endRun(.empty, "every chart for those regions is already installed");
        if (!self.stageAt(dest)) return;
        self.startUnpacker(!again);

        self.phase = .downloading;
        self.changed = true;
        self.pump();
    }

    /// Download the cells NOAA has reissued since these were installed.
    pub fn startUpdate(self: *Service, installed: []const noaa.Installed, dest: []const u8) void {
        const cat = &(self.cat orelse return self.refuse(.refused, "no catalog yet", true));
        if (self.get == null) return self.refuse(.refused, "no network provider", false);
        const stale = noaa.outdated(self.alloc, cat, installed) catch
            return self.refuse(.failed, "out of memory checking editions", false);
        defer self.alloc.free(stale);

        self.cancelAll();
        self.beginRun();
        self.freePlan();
        self.next_job = 0;
        self.done = 0;
        self.failed = 0;
        self.bytes_done = 0;
        self.bytes_total = 0;
        self.freeStr(&self.err);

        // Cell by cell, whatever the count. A reissue is a handful of cells
        // scattered across the country, and no bundle is the shape of that.
        for (stale) |i| {
            const c = cat.find(installed[i].name) orelse continue;
            if (c.zip_url.len == 0) continue;
            self.planAppend(c.name, c.zip_url, c.zip_bytes, 1, 0);
        }
        if (self.plan.items.len == 0) {
            self.phase = .ready;
            return self.endRun(.empty, "");
        }
        if (!self.stageAt(dest)) return;
        self.startUnpacker(false);

        self.phase = .downloading;
        self.changed = true;
        self.pump();
    }

    /// Fill the transfer budget from the plan.
    fn pump(self: *Service) void {
        while (self.inflight < MAX_INFLIGHT and self.next_job < self.plan.items.len) {
            const i = self.next_job;
            self.next_job += 1;
            if (self.issue(self.plan.items[i].url, .cell, i) == 0) {
                self.failed += self.plan.items[i].cells;
                continue;
            }
            self.inflight += 1;
        }
        if (self.inflight == 0 and self.next_job >= self.plan.items.len and self.phase == .downloading) {
            self.phase = .ready;
            self.endRun(if (self.done > 0) .finished else .failed, "");
        }
    }

    /// Create `dest` and point the fetch threads at it. Ends the run and
    /// returns false when it cannot.
    fn stageAt(self: *Service, dest: []const u8) bool {
        self.freeStr(&self.dest);
        self.dest = self.alloc.dupe(u8, dest) catch {
            self.endRun(.failed, "out of memory");
            return false;
        };
        makeDir(dest) catch {
            self.endRun(.refused, "could not create the download directory");
            return false;
        };
        self.setStageDest(dest);
        return true;
    }

    // ---- answers ----------------------------------------------------------

    /// Take one answer from a fetch thread. Does not hold the api lock.
    pub fn respond(self: *Service, req_id: u64, bytes: []const u8, status: c_int) void {
        self.respondChunk(req_id, bytes, status, true);
    }

    /// Take one piece of an answer. Pieces for one request arrive on one
    /// thread in order, with `done` set on the last; a shell holding the whole
    /// body calls this once.
    ///
    /// A transfer goes straight to its part file as it arrives, so a district
    /// bundle never sits in memory. The catalog is parsed whole, under the api
    /// lock, so its pieces are gathered instead.
    pub fn respondChunk(self: *Service, req_id: u64, bytes: []const u8, status: c_int, done: bool) void {
        if (self.appendStaged(req_id, bytes, status)) {
            if (!done) return self.noteProgress(bytes.len);
            self.finishStaged(req_id, status);
            return;
        }

        const whole = self.gather.take(req_id, bytes, status, done) orelse return;
        self.post(.{ .id = req_id, .bytes = whole.bytes, .status = whole.status });
    }

    /// The shortest gap between two wakes for bytes arriving.
    pub const progress_every_ms: i64 = 250;

    /// Mark the byte count moved, and wake the shell at most four times a
    /// second for it. The piece that ends a transfer wakes it through post.
    fn noteProgress(self: *Service, len: usize) void {
        if (len == 0) return;
        self.progress.store(true, .release);
        const w = self.wake orelse return;
        const now = clock.ticksMs();
        const last = self.progress_woke_ms.load(.acquire);
        if (now - last < progress_every_ms) return;
        if (self.progress_woke_ms.cmpxchgStrong(last, now, .acq_rel, .acquire) != null) return;
        w(self.user);
    }

    /// Close a finished transfer and hand it to the unpack thread.
    ///
    /// Unpacking runs off the api lock: adopt holds it, and file work there
    /// blocked the shell's poll for the length of the download.
    fn finishStaged(self: *Service, req_id: u64, status: c_int) void {
        const st = self.takeStaged(req_id) orelse return;
        const ok = !st.broken and st.size != 0 and status >= 200 and status < 300;
        if (ok and st.dest.len != 0 and self.queueUnpack(req_id, st.name, st.dest, st.size, status)) return;
        dropPart(st.dest, st.name);
        self.alloc.free(st.name);
        if (st.dest.len != 0) self.alloc.free(st.dest);
        self.post(.{ .id = req_id, .bytes = &.{}, .status = if (st.broken) 0 else status });
    }

    /// Remove the part file of a transfer that will not be unpacked.
    fn dropPart(dest: []const u8, name: []const u8) void {
        if (dest.len == 0) return;
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.zip.part", .{ dest, name }) catch return;
        std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    }

    /// Queue one answer for the next adopt.
    fn post(self: *Service, a: Answer) void {
        {
            self.inbox_mu.lock();
            defer self.inbox_mu.unlock();
            self.inbox.append(self.alloc, a) catch {
                if (a.bytes.len != 0) self.alloc.free(a.bytes);
                return;
            };
            self.inbox_len.store(self.inbox.items.len, .release);
        }
        if (self.wake) |w| w(self.user);
    }

    /// Hand a written transfer to the unpack thread. Owns `name` and `dest`
    /// on success. Returns false when no thread runs, when it is stopping, or
    /// when the queue could not be grown, and the caller then posts the
    /// answer itself.
    fn queueUnpack(self: *Service, id: u64, name: []u8, dest: []u8, size: u64, status: c_int) bool {
        self.unpack_mu.lock();
        defer self.unpack_mu.unlock();
        const u = self.unpacker orelse return false;
        if (u.stop.load(.acquire)) return false;
        u.q.append(self.alloc, .{
            .id = id,
            .name = name,
            .dest = dest,
            .size = size,
            .status = status,
        }) catch return false;
        return true;
    }

    /// The longest an idle unpack thread sleeps between looks at its queue.
    const unpack_idle_max_ms = 50;

    /// The unpack thread. Writes one cell at a time and posts an answer for
    /// each.
    ///
    /// The stop flag is read before each transfer, so a stopped thread ends
    /// after the transfer it is on. What is still queued is dropped and its
    /// part files deleted.
    ///
    /// Zig 0.16 has no semaphore outside an Io, so an empty queue is polled
    /// with a backoff: 1 ms, doubling to 50 ms while the queue stays empty,
    /// and back to 1 ms after each transfer.
    fn unpackMain(self: *Service, u: *Unpacker) void {
        var idle_ms: u32 = 1;
        while (true) {
            const next: ?Pending = blk: {
                self.unpack_mu.lock();
                defer self.unpack_mu.unlock();
                if (u.stop.load(.acquire)) break;
                if (u.q.items.len == 0) break :blk null;
                break :blk u.q.orderedRemove(0);
            };
            const job = next orelse {
                lock.sleepMs(idle_ms);
                idle_ms = @min(idle_ms * 2, unpack_idle_max_ms);
                continue;
            };
            idle_ms = 1;
            self.unpackOne(u, job);
        }
        self.dropQueue(u);
        u.exited.store(true, .release);
    }

    /// Unpack one transfer and post its answer. A transfer whose thread was
    /// stopped while it waited for `unpack_work` is dropped.
    fn unpackOne(self: *Service, u: *Unpacker, job: Pending) void {
        defer self.alloc.free(job.name);
        defer self.alloc.free(job.dest);
        self.unpack_work.lock();
        defer self.unpack_work.unlock();
        if (u.stop.load(.acquire)) {
            dropPart(job.dest, job.name);
            return;
        }
        var a: Answer = .{ .id = job.id, .bytes = &.{}, .status = job.status };
        if (self.unpack(job.dest, job.name, u.skip)) {
            a.stored = true;
            a.size = @intCast(job.size);
        } else |_| {
            a.write_failed = true;
        }
        self.post(a);
    }

    /// Drop every transfer still queued for `u` and delete its part file.
    fn dropQueue(self: *Service, u: *Unpacker) void {
        var q: std.ArrayList(Pending) = .empty;
        {
            self.unpack_mu.lock();
            defer self.unpack_mu.unlock();
            q = u.q;
            u.q = .empty;
        }
        defer q.deinit(self.alloc);
        for (q.items) |job| {
            dropPart(job.dest, job.name);
            self.alloc.free(job.name);
            self.alloc.free(job.dest);
        }
    }

    /// Start an unpack thread for a download.
    ///
    /// Called under the api lock, so the thread from the last download is
    /// stopped and left for adopt to join. It ends after the transfer it is
    /// on, and `unpack_work` keeps that transfer from running beside the new
    /// thread's first.
    ///
    /// `skip_held` leaves the cells in `held` as they are on disk.
    fn startUnpacker(self: *Service, skip_held: bool) void {
        self.retireUnpacker();
        const u = self.alloc.create(Unpacker) catch return;
        u.* = .{};
        if (skip_held) u.skip = self.copyHeld() catch {
            self.alloc.destroy(u);
            return;
        };
        u.thread = std.Thread.spawn(.{}, unpackMain, .{ self, u }) catch {
            self.freeUnpacker(u);
            return;
        };
        self.unpack_mu.lock();
        defer self.unpack_mu.unlock();
        self.unpacker = u;
    }

    /// Stop the current thread and move it to `reap`. Joins it here only
    /// when `reap` cannot grow.
    fn retireUnpacker(self: *Service) void {
        const u = blk: {
            self.unpack_mu.lock();
            defer self.unpack_mu.unlock();
            const u = self.unpacker orelse return;
            u.stop.store(true, .release);
            self.unpacker = null;
            break :blk u;
        };
        self.reap.append(self.alloc, u) catch self.joinUnpacker(u);
    }

    /// Join a stopped thread and free it.
    fn joinUnpacker(self: *Service, u: *Unpacker) void {
        u.thread.join();
        self.dropQueue(u);
        self.freeUnpacker(u);
    }

    fn freeUnpacker(self: *Service, u: *Unpacker) void {
        for (u.skip) |n| self.alloc.free(n);
        self.alloc.free(u.skip);
        self.alloc.destroy(u);
    }

    /// A copy of `held`, for a thread to read while the api side replaces it.
    fn copyHeld(self: *Service) ![][]u8 {
        const out = try self.alloc.alloc([]u8, self.held.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |c| self.alloc.free(c);
            self.alloc.free(out);
        }
        for (self.held.items) |h| {
            out[n] = try self.alloc.dupe(u8, h);
            n += 1;
        }
        return out;
    }

    /// Stop every thread and wait for each. For deinit.
    fn stopUnpacker(self: *Service) void {
        self.retireUnpacker();
        for (self.reap.items) |u| {
            u.stop.store(true, .release);
            self.joinUnpacker(u);
        }
        self.reap.clearRetainingCapacity();
    }

    /// Join the stopped threads that have returned, and stop the current one
    /// once no download runs.
    fn idleUnpacker(self: *Service) void {
        var i: usize = 0;
        while (i < self.reap.items.len) {
            const u = self.reap.items[i];
            if (!u.exited.load(.acquire)) {
                i += 1;
                continue;
            }
            _ = self.reap.swapRemove(i);
            self.joinUnpacker(u);
        }
        if (self.phase == .downloading) return;
        const u = self.unpacker orelse return;
        u.stop.store(true, .release);
        if (!u.exited.load(.acquire)) return;
        {
            self.unpack_mu.lock();
            defer self.unpack_mu.unlock();
            self.unpacker = null;
        }
        self.joinUnpacker(u);
    }

    /// True while an unpack thread is alive or not yet joined.
    pub fn unpackerRunning(self: *const Service) bool {
        return self.unpacker != null or self.reap.items.len != 0;
    }

    /// True while an answer waits to be adopted.
    pub fn pending(self: *const Service) bool {
        return self.inbox_len.load(.acquire) != 0;
    }

    /// Adopt every queued answer. Called from the frame loop under the api
    /// lock.
    pub fn adopt(self: *Service) void {
        const moved = self.progress.swap(false, .acq_rel);
        if (!self.pending()) {
            // No answer arrived. The api side may still have changed the
            // state since the last frame, and bytes may have arrived.
            self.idleUnpacker();
            if (self.changed or moved) self.publish();
            return;
        }
        while (true) {
            var a: Answer = undefined;
            {
                self.inbox_mu.lock();
                defer self.inbox_mu.unlock();
                if (self.inbox.items.len == 0) break;
                a = self.inbox.items[0];
                const left = self.inbox.items.len - 1;
                std.mem.copyForwards(Answer, self.inbox.items[0..left], self.inbox.items[1..]);
                self.inbox.shrinkRetainingCapacity(left);
                self.inbox_len.store(left, .release);
            }
            defer if (a.bytes.len != 0) self.alloc.free(a.bytes);
            if (self.retire(a.id)) |req| switch (req.kind) {
                .catalog => self.tookCatalog(a),
                .cell => {
                    self.inflight -= 1;
                    self.tookCell(req.job, a);
                },
            };
        }
        if (self.phase == .downloading) self.pump();
        self.idleUnpacker();
        self.publish();
    }

    fn tookCatalog(self: *Service, a: Answer) void {
        if (a.status < 200 or a.status >= 300 or a.bytes.len == 0) {
            self.catalogEnded();
            self.setErr("could not read NOAA's chart catalog");
            return;
        }
        var parsed = noaa.parse(self.alloc, a.bytes) catch {
            self.catalogEnded();
            self.setErr("NOAA's chart catalog did not parse");
            return;
        };
        if (parsed.cells.len == 0) {
            parsed.deinit();
            self.catalogEnded();
            self.setErr("NOAA's chart catalog listed no cells");
            return;
        }
        // A running download's plan owns copies of its names and urls, so the
        // old catalog can be freed.
        if (self.cat) |*old| old.deinit();
        self.cat = parsed;
        self.checked_at = @divFloor(clock.wallMs(), 1000);
        self.fresh_reads +%= 1;
        self.catalogEnded();
        self.cacheCatalog(a.bytes);
    }

    fn tookCell(self: *Service, job: usize, a: Answer) void {
        if (job >= self.plan.items.len) return;
        if (!a.stored) {
            if (!a.write_failed and self.expandBundle(job)) return;
            // Count every cell in the transfer, as `done` does, so done plus
            // failed reaches the total.
            self.failed += self.plan.items[job].cells;
            if (a.write_failed) self.setErr("could not write a downloaded chart") else self.retry = true;
            self.changed = true;
            return;
        }
        self.done += self.plan.items[job].cells;
        self.bytes_done += a.size;
        self.changed = true;
    }

    /// A bundle NOAA did not serve, asked for cell by cell instead.
    ///
    /// The bundle url is a convention of the download site rather than
    /// something the catalog states, so a district NOAA renames or retires
    /// answers 404. Every cell it stood for is still published under its own
    /// url, and the download goes on with the requests the bundle was there to
    /// save. Returns false for anything that is not a bundle, and for a
    /// district whose cells are all in hand.
    fn expandBundle(self: *Service, job: usize) bool {
        const district = self.plan.items[job].district;
        if (district == 0) return false;
        const cat = &(self.cat orelse return false);
        const before = self.plan.items.len;
        for (cat.cells) |c| {
            if (c.district != district or c.zip_url.len == 0) continue;
            if (!self.again and noaa.isHeld(self.held.items, c.name)) continue;
            self.planAppend(c.name, c.zip_url, c.zip_bytes, 1, 0);
        }
        if (self.plan.items.len == before) return false;
        // The bundle's share of the counters goes with it, or the cells it
        // stood for are counted twice.
        const t = &self.plan.items[job];
        self.bytes_total -= @min(self.bytes_total, t.bytes);
        t.cells = 0;
        t.district = 0;
        self.changed = true;
        return true;
    }

    /// Unpack one transfer's exchange set into the staging directory.
    ///
    /// The body was written to a scratch file as it arrived. It is extracted
    /// and removed. Leaving the zips in place gave the shell a directory of
    /// 829 archives, and it bakes a folder of cells or a single archive, so it
    /// refused the pick. Extracting turns the directory into an ordinary
    /// ENC_ROOT, and a district bundle unpacks the same way a cell does.
    ///
    /// Each cell directory in the archive is deleted first. An update or a
    /// repair unpacks over the installed edition, and std.zip does not
    /// overwrite files, so the old cell stayed and a reissue's update files
    /// were written beside a base they do not apply to.
    ///
    /// An entry in the directory of a cell named in `skip` is left out of
    /// both the delete and the extract.
    fn unpack(self: *Service, dest: []const u8, name: []const u8, skip: []const []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var buf: [512]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&buf, "{s}/{s}.zip.part", .{ dest, name });
        defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

        var dir = try std.Io.Dir.cwd().openDir(io, dest, .{});
        defer dir.close(io);
        var f = try std.Io.Dir.cwd().openFile(io, tmp, .{});
        defer f.close(io);
        var reader_buf: [4096]u8 = undefined;
        var fr = f.reader(io, &reader_buf);

        try self.clearCellDirs(&fr, dir, skip);

        // Entry by entry. std.zip.extract stops at the first file already on
        // disk, every cell's exchange set holds its own ENC_ROOT/CATALOG.031,
        // and they all unpack into the one directory. From the second cell on
        // that entry collided and the rest of the archive went unread, so 828
        // of 829 cells counted as failures. The cell directories were deleted
        // above, so the only collisions left are files every exchange set
        // shares.
        var iter = try std.zip.Iterator.init(&fr);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (try iter.next()) |entry| {
            if (skip.len != 0) {
                const path = try entryName(&fr, entry, &name_buf) orelse continue;
                if (inSkippedCell(path, skip)) continue;
            }
            entry.extract(&fr, .{ .allow_backslashes = true }, &name_buf, dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
    }

    /// Delete every cell directory under `dir` that this archive holds a cell
    /// file for.
    fn clearCellDirs(self: *Service, fr: *std.Io.File.Reader, dir: std.Io.Dir, skip: []const []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var cells: std.ArrayList([]u8) = .empty;
        defer {
            for (cells.items) |c| self.alloc.free(c);
            cells.deinit(self.alloc);
        }

        var iter = try std.zip.Iterator.init(fr);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (try iter.next()) |entry| {
            const path = try entryName(fr, entry, &name_buf) orelse continue;
            const cell = cellDirOf(path) orelse continue;
            if (inSkippedCell(path, skip)) continue;
            var seen = false;
            for (cells.items) |c| {
                if (std.mem.eql(u8, c, cell)) seen = true;
            }
            if (seen) continue;
            try cells.append(self.alloc, try self.alloc.dupe(u8, cell));
        }
        for (cells.items) |c| try dir.deleteTree(io, c);
    }

    // ---- the snapshot -----------------------------------------------------

    /// Copy the state where a shell can read it without the api lock. Called
    /// from the api side, the only side that changes it.
    pub fn publish(self: *Service) void {
        const s = self.snapshot();
        self.pub_mu.lock();
        defer self.pub_mu.unlock();
        if (std.meta.eql(s, self.pub_state)) return;
        self.pub_state = s;
        self.pub_changed = true;
    }

    /// True when a publish has changed the state since the last call. Safe
    /// from any thread.
    pub fn takeChanged(self: *Service) bool {
        self.pub_mu.lock();
        defer self.pub_mu.unlock();
        const was = self.pub_changed;
        self.pub_changed = false;
        return was;
    }

    /// The last published state. Safe from any thread.
    pub fn published(self: *Service) State {
        self.pub_mu.lock();
        defer self.pub_mu.unlock();
        return self.pub_state;
    }

    /// What the transfers in flight have brought so far.
    ///
    /// Bytes are exact: they are what has been written to the part files. The
    /// chart count is the share of each transfer's bytes that has landed,
    /// because a district bundle is one transfer worth hundreds of charts and
    /// the count otherwise stood at zero for the whole download and then
    /// jumped to the district in one step.
    fn inFlight(self: *Service) struct { cells: u32, bytes: u64 } {
        self.stage_mu.lock();
        defer self.stage_mu.unlock();
        var cells: u64 = 0;
        var bytes: u64 = 0;
        for (self.stage.items) |st| {
            if (st.broken or st.size == 0) continue;
            bytes += st.size;
            const job = self.jobOf(st.id) orelse continue;
            const t = self.plan.items[job];
            // One cell rounds to nothing, and a transfer with no stated size
            // has no share to take.
            if (t.cells <= 1 or t.bytes == 0) continue;
            const got = @min(st.size, t.bytes);
            cells += (got * t.cells) / t.bytes;
        }
        return .{ .cells = std.math.cast(u32, cells) orelse 0, .bytes = bytes };
    }

    /// Which plan entry a request is fetching, for the counts above.
    fn jobOf(self: *const Service, id: u64) ?usize {
        for (self.reqs.items) |r| {
            if (r.id == id and r.kind == .cell and r.job < self.plan.items.len) return r.job;
        }
        return null;
    }

    pub fn snapshot(self: *Service) State {
        const live = self.inFlight();
        const total = self.planCells();
        var s = State{
            .phase = @intFromEnum(self.phase),
            .have_catalog = if (self.cat != null) 1 else 0,
            .checked_at = self.checked_at,
            .total = total,
            .done = @min(self.done + live.cells, total),
            .failed = self.failed,
            .bytes_total = self.bytes_total,
            .bytes_done = self.bytes_done + live.bytes,
            .outcome = @intFromEnum(self.outcome),
            .run = self.run,
            .retry = @intFromBool(self.retry),
        };
        if (self.cat) |*c| {
            s.catalog_cells = @intCast(c.cells.len);
            copyZ(&s.date, c.date);
        }
        copyZ(&s.err, self.err);
        self.changed = false;
        return s;
    }
};

/// One box of a region's coverage, in degrees.
pub const Box = extern struct {
    west: f64,
    south: f64,
    east: f64,
    north: f64,
};

/// A service and the lock that serializes calls into it.
///
/// lookout_noaa is one of these on its own. A chart handle holds one as well,
/// for the calls that take a chart handle, and adopts it from its frame loop.
/// Every method except respondChunk and poll locks `mu`, and the shell's
/// fetcher is called with it held.
pub const Handle = struct {
    mu: Lock = .{},
    svc: Service,
    /// The names regionCells last handed out, valid until its next call.
    cells: ?std.heap.ArenaAllocator = null,
    /// Borrowed from the shell, which keeps both open for the life of the
    /// handle. Either may be null. With sets, the held cells and their
    /// editions are read off them. Without, the shell names them through
    /// `have`.
    store: ?*settings.Store = null,
    sets: ?*chartsets.Sets = null,

    /// An update check is waiting on the catalog read that started with
    /// `check_reads` fresh reads behind it.
    check_pending: bool = false,
    check_reads: u32 = 0,
    /// A check has been recorded since the handle opened. The startup
    /// cadence checks once per launch.
    checked_run: bool = false,
    /// The last check, for a handle with no store.
    last_check: i64 = 0,

    pub fn init(alloc: std.mem.Allocator) Handle {
        return .{ .svc = Service.init(alloc) };
    }

    pub fn deinit(self: *Handle) void {
        self.svc.deinit();
        if (self.cells) |*a| a.deinit();
        self.cells = null;
    }

    pub fn setProvider(self: *Handle, get: ?clinks.HttpGetFn, stop: ?clinks.HttpCancelFn, wake: ?WakeFn, user: ?*anyopaque) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.svc.setProvider(get, stop, wake, user);
        self.svc.publish();
    }

    /// One piece of a response. No lock: see Service.respondChunk.
    pub fn respondChunk(self: *Handle, req_id: u64, bytes: []const u8, status: c_int, done: bool) void {
        self.svc.respondChunk(req_id, bytes, status, done);
    }

    /// Adopt the responses that arrived and publish what changed.
    pub fn adopt(self: *Handle) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.svc.adopt();
        self.settleCheck();
    }

    /// Adopt, then report whether the published state changed since the
    /// last call.
    pub fn changed(self: *Handle) bool {
        self.adopt();
        return self.svc.takeChanged();
    }

    /// The last published state. No lock beyond the snapshot's own.
    pub fn poll(self: *Handle) State {
        return self.svc.published();
    }

    pub fn refresh(self: *Handle) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.svc.refresh();
        self.svc.publish();
    }

    pub fn have(self: *Handle, names: []const []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.svc.setHeld(names);
    }

    /// Null when no catalog is loaded.
    pub fn cost(self: *Handle, districts: []const u8) ?noaa.Cost {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.svc.haveCatalog()) return null;
        self.syncHeld();
        return self.svc.costOf(districts);
    }

    /// Read the held cells off the sets. Leaves `held` as the shell named it
    /// when the handle has no sets. Called with `mu` held.
    fn syncHeld(self: *Handle) void {
        const sets = self.sets orelse return;
        const alloc = self.svc.alloc;
        const cells = sets.heldCells(alloc, .names) catch return;
        defer chartsets.Sets.freeHeld(alloc, cells);
        const names = alloc.alloc([]const u8, cells.len) catch return;
        defer alloc.free(names);
        for (cells, names) |c, *n| n.* = c.name;
        self.svc.setHeld(names);
    }

    /// The managed sets' cells that state an edition, for the update check.
    /// Empty without sets. Free with chartsets.Sets.freeHeld.
    fn managedEditions(self: *Handle) ![]chartsets.Sets.Held {
        const sets = self.sets orelse return self.svc.alloc.alloc(chartsets.Sets.Held, 0);
        return sets.heldCells(self.svc.alloc, .editions);
    }

    /// Write at most `cap` names into `out` and return how many there are.
    /// The names stay valid until the next call.
    pub fn regionCells(self: *Handle, districts: []const u8, out: ?[*][*:0]const u8, cap: usize) usize {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.svc.haveCatalog()) return 0;
        const alloc = self.svc.alloc;
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(alloc);
        self.svc.cellsOf(districts, &names);
        const dst = out orelse return names.items.len;

        // The catalog holds the names unterminated. A caller reads C strings,
        // so they are copied into an arena that lives until the next call.
        if (self.cells) |*old| old.deinit();
        var arena = std.heap.ArenaAllocator.init(alloc);
        const a = arena.allocator();
        var n: usize = 0;
        for (names.items) |name| {
            if (n >= cap) break;
            const z = a.dupeZ(u8, name) catch break;
            dst[n] = z.ptr;
            n += 1;
        }
        self.cells = arena;
        return names.items.len;
    }

    /// The boxes of the finest coarse band a region has. Writes at most `cap`
    /// and returns how many there are.
    pub fn regionCoverage(self: *Handle, region_id: []const u8, out: ?[*]Box, cap: usize) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const cat = &(self.svc.cat orelse return 0);
        const region = noaa.regionById(region_id) orelse return 0;
        // The finest of the coarse bands this district has. Band 3 is coastal
        // and hugs the shore; band 1 is an ocean basin and blots out the
        // coastline it is meant to describe. The Great Lakes have no band 3,
        // so the choice is made per district rather than fixed.
        var band: u8 = 0;
        for ([_]u8{ 3, 2, 1 }) |b| {
            for (cat.cells) |c| {
                if (c.district == region.district and c.band == b and c.box.known) {
                    band = b;
                    break;
                }
            }
            if (band != 0) break;
        }
        if (band == 0) return 0;

        var n: usize = 0;
        for (cat.cells) |c| {
            if (c.district != region.district or !c.box.known) continue;
            if (c.band != band) continue;
            if (out) |o| {
                if (n < cap) o[n] = .{
                    .west = c.box.start,
                    .south = c.box.south,
                    .east = c.box.start + c.box.width,
                    .north = c.box.north,
                };
            }
            n += 1;
        }
        return n;
    }

    pub fn download(self: *Handle, districts: []const u8, dest: []const u8, again: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.syncHeld();
        self.svc.start(districts, dest, again);
        self.svc.publish();
    }

    /// How many of `installed` the catalog has reissued. 0 with no catalog.
    pub fn outdated(self: *Handle, installed: []const noaa.Installed) u32 {
        self.mu.lock();
        defer self.mu.unlock();
        const cat = &(self.svc.cat orelse return 0);
        const stale = noaa.outdated(self.svc.alloc, cat, installed) catch return 0;
        defer self.svc.alloc.free(stale);
        return @intCast(stale.len);
    }

    pub fn update(self: *Handle, installed: []const noaa.Installed, dest: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.svc.startUpdate(installed, dest);
        self.svc.publish();
    }

    /// How many of the managed sets' cells the catalog has reissued. 0 until
    /// a catalog has been read from the network: the cached one can predate a
    /// reissue, and the cells it names may be the ones installed from it.
    pub fn outdatedOfSets(self: *Handle) u32 {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.svc.fresh_reads == 0) return 0;
        const cat = &(self.svc.cat orelse return 0);
        const alloc = self.svc.alloc;
        const held = self.managedEditions() catch return 0;
        defer chartsets.Sets.freeHeld(alloc, held);
        // Both lists are keyed by name. The catalog is walked once, and each
        // name is looked up in the sorted list the sets returned.
        var n: u32 = 0;
        for (cat.cells) |c| {
            const i = heldIndex(held, c.name) orelse continue;
            const h = held[i];
            if (c.edition > h.edition or (c.edition == h.edition and c.update > h.update)) n += 1;
        }
        return n;
    }

    /// Download the reissues of the managed sets' cells into `dest`.
    pub fn updateOfSets(self: *Handle, dest: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const alloc = self.svc.alloc;
        const held = self.managedEditions() catch return;
        defer chartsets.Sets.freeHeld(alloc, held);
        const list = alloc.alloc(noaa.Installed, held.len) catch return;
        defer alloc.free(list);
        for (held, list) |h, *o| o.* = .{ .name = h.name, .edition = h.edition, .update = h.update };
        self.svc.startUpdate(list, dest);
        self.svc.publish();
    }

    pub const cadence_key = "noaa-update-check";
    pub const checked_key = "noaa-update-checked";
    const day_s: i64 = 24 * 60 * 60;

    /// Start an update check when the cadence calls for one, and return true
    /// while one is running or has just been recorded. The count is
    /// outdatedOfSets once the catalog read ends.
    ///
    /// The cadence is "never", "startup" or "daily", daily when unset. A
    /// check needs a catalog read from the network. One read within the day
    /// is used as it is, and otherwise a read starts here. The check is
    /// recorded only when that read succeeds, so a failed read leaves it due.
    /// With no managed cell that states an edition there is no check to make,
    /// and no request goes out.
    pub fn updateDue(self: *Handle, now_s: i64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const cadence: []const u8 = if (self.store) |st|
            st.text(settings.group_chartsets, cadence_key) orelse "daily"
        else
            "daily";
        if (std.mem.eql(u8, cadence, "never")) return false;
        const startup = std.mem.eql(u8, cadence, "startup");

        const held = self.managedEditions() catch return false;
        chartsets.Sets.freeHeld(self.svc.alloc, held);
        if (held.len == 0) return false;

        if (self.check_pending) return true;
        const due = if (startup) !self.checked_run else now_s - self.lastCheck() >= day_s;
        if (!due) return false;

        if (self.svc.fresh_reads != 0 and !self.svc.catalog_inflight and
            (startup or now_s - self.svc.checked_at < day_s))
        {
            self.recordCheck(self.svc.checked_at);
            return true;
        }
        self.check_pending = true;
        self.check_reads = self.svc.fresh_reads;
        self.svc.refresh();
        self.svc.publish();
        self.settleCheck();
        return true;
    }

    /// End a pending check once its catalog read has ended, and record it
    /// when the read succeeded. Called with `mu` held.
    fn settleCheck(self: *Handle) void {
        if (!self.check_pending or self.svc.catalog_inflight) return;
        self.check_pending = false;
        if (self.svc.fresh_reads != self.check_reads) self.recordCheck(self.svc.checked_at);
    }

    fn lastCheck(self: *Handle) i64 {
        const st = self.store orelse return self.last_check;
        const v = st.number(settings.group_chartsets, checked_key, 0);
        if (!std.math.isFinite(v)) return 0;
        return std.math.lossyCast(i64, v);
    }

    fn recordCheck(self: *Handle, at: i64) void {
        self.checked_run = true;
        self.last_check = at;
        if (self.store) |st| st.setNumber(settings.group_chartsets, checked_key, @floatFromInt(at));
    }

    pub fn cancel(self: *Handle) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.svc.cancelAll();
        self.svc.publish();
    }
};

/// The index of `name` in `have`, sorted by name, or null.
fn heldIndex(have: []const chartsets.Sets.Held, name: []const u8) ?usize {
    var lo: usize = 0;
    var hi: usize = have.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, have[mid].name, name)) {
            .eq => return mid,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// The cell directory that holds an exchange set entry, or null when the
/// entry is not a cell file.
///
/// A cell file is `<NAME>.<nnn>`, the base at 000 and each update after it, in
/// a directory named for the cell: `ENC_ROOT/US5MD1MC/US5MD1MC.000`. The shared
/// `ENC_ROOT/CATALOG.031` and anything else that is not in a directory of its
/// own name is left alone.
fn cellDirOf(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    const file = path[slash + 1 ..];
    const parent = path[0..slash];
    const dir_name = parent[(if (std.mem.lastIndexOfScalar(u8, parent, '/')) |i| i + 1 else 0)..];
    if (file.len < 5 or file[file.len - 4] != '.') return null;
    for (file[file.len - 3 ..]) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }
    const stem = file[0 .. file.len - 4];
    if (dir_name.len == 0 or !std.mem.eql(u8, stem, dir_name)) return null;
    return parent;
}

/// The name of a zip entry, with forward slashes. Null when it does not fit
/// `buf`.
fn entryName(fr: *std.Io.File.Reader, entry: std.zip.Iterator.Entry, buf: []u8) !?[]u8 {
    if (entry.filename_len > buf.len) return null;
    const path = buf[0..entry.filename_len];
    try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    try fr.interface.readSliceAll(path);
    std.mem.replaceScalar(u8, path, '\\', '/');
    return path;
}

/// True when `path` is in the directory of a cell named in `skip`.
fn inSkippedCell(path: []const u8, skip: []const []const u8) bool {
    if (skip.len == 0) return false;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    const parent = path[0..slash];
    const cell = parent[(if (std.mem.lastIndexOfScalar(u8, parent, '/')) |i| i + 1 else 0)..];
    return noaa.isHeld(skip, cell);
}

/// Create a directory and every parent it needs.
fn makeDir(path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, path);
}

/// Copy a slice into a fixed buffer and terminate it. A value too long for the
/// buffer is truncated.
fn copyZ(dst: []u8, src: []const u8) void {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

// ---- tests ----------------------------------------------------------------

const testing = std.testing;

test "request ids are distinguishable from chartlinks ids" {
    try testing.expect(ownsId(id_mark | 1));
    try testing.expect(!ownsId(1));
    try testing.expect(!ownsId(0));
    // chartlinks counts up from 1 and never sets the top bit.
    try testing.expect(!ownsId(std.math.maxInt(u32)));
}

/// A catalog of one cell, small enough to write in a test and complete enough
/// to parse.
const test_catalog =
    \\<ENC_Product_Catalog><date_valid>20250903</date_valid>
    \\<cell><name>US5MD1MC</name><lname>Chesapeake Bay Entrance</lname>
    \\<cscale>20000</cscale><edtn>27</edtn><updn>3</updn><isdt>20250801</isdt>
    \\<zipfile_location>https://charts.noaa.gov/ENCs/US5MD1MC.zip</zipfile_location>
    \\<zipfile_size>1048576</zipfile_size><coast_guard_district>5</coast_guard_district>
    \\<panel><vertex><lat>36.0</lat><long>-76.5</long></vertex>
    \\<vertex><lat>37.0</lat><long>-75.5</long></vertex></panel></cell>
    \\</ENC_Product_Catalog>
;

/// Point the cache root at a directory of this test's own.
///
/// Every test that reaches the catalog cache needs this. The root is a global
/// the host sets once. Without it a test reads whatever catalog the machine
/// running it holds, and passes or fails on that.
fn testCacheRoot(tmp: *std.testing.TmpDir) ![]u8 {
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    cachedir.setRoot(dir);
    return dir;
}

test "a service with no fetcher reports why and stays idle" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testCacheRoot(&tmp);
    defer testing.allocator.free(root);

    var s = Service.init(testing.allocator);
    defer s.deinit();

    s.refresh();
    try testing.expectEqual(Phase.idle, s.phase);
    try testing.expect(s.err.len != 0);
    try testing.expect(!s.haveCatalog());

    // Pricing a selection with no catalog returns a zero cost.
    const c = s.costOf(&.{5});
    try testing.expectEqual(@as(u32, 0), c.cells);
}

test "a download refuses to start before a catalog is read" {
    var s = Service.init(testing.allocator);
    defer s.deinit();
    s.start(&.{5}, "/tmp/lookout-noaa-test-should-not-exist", false);
    try testing.expectEqual(Phase.idle, s.phase);
    try testing.expect(s.err.len != 0);
}

test "the catalog is kept, and the next run reads it with no network" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testCacheRoot(&tmp);
    defer testing.allocator.free(root);

    {
        var s = Service.init(testing.allocator);
        defer s.deinit();
        s.cacheCatalog(test_catalog);
    }

    // A separate run with no fetcher. This is a mariner with no network. The
    // picker has to price their water and let them delete it.
    var s = Service.init(testing.allocator);
    defer s.deinit();

    try testing.expect(!s.haveCatalog());
    s.refresh();
    try testing.expect(s.haveCatalog());
    try testing.expectEqual(Phase.ready, s.phase);
    // The catalog is real, so a region prices against it.
    try testing.expect(s.costOf(&.{5}).cells > 0);
    // checked_at is the time of the network read, from the file's mtime.
    try testing.expect(s.checked_at > 0);
}

test "a catalog the cache does not hold leaves the service idle" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testCacheRoot(&tmp);
    defer testing.allocator.free(root);

    var s = Service.init(testing.allocator);
    defer s.deinit();

    s.refresh();
    try testing.expect(!s.haveCatalog());
    try testing.expectEqual(Phase.idle, s.phase);
}

test "the snapshot fits a long error into its buffer" {
    var s = Service.init(testing.allocator);
    defer s.deinit();
    const long = "x" ** 400;
    s.setErr(long);
    const snap = s.snapshot();
    try testing.expectEqual(@as(u8, 0), snap.err[255]);
    try testing.expectEqual(@as(u8, 'x'), snap.err[254]);
    // Reading the snapshot clears the change flag.
    try testing.expect(!s.changed);
}

test "copyZ terminates a value that fits and one that does not" {
    var buf: [8]u8 = @splat(0xAA);
    copyZ(&buf, "abc");
    try testing.expectEqualStrings("abc", std.mem.sliceTo(&buf, 0));
    copyZ(&buf, "abcdefghijkl");
    try testing.expectEqualStrings("abcdefg", std.mem.sliceTo(&buf, 0));
}

/// A catalog holding `cells` charts in one district, each with a zip url.
pub fn oneDistrict(alloc: std.mem.Allocator, district: u8, cells: u32) !noaa.Catalog {
    const xml = try districtXml(alloc, district, cells, 1);
    defer alloc.free(xml);
    return noaa.parse(alloc, xml);
}

/// The catalog text oneDistrict parses, with every cell at `edition`. The
/// caller frees it.
fn districtXml(alloc: std.mem.Allocator, district: u8, cells: u32, edition: u32) ![]u8 {
    var xml: std.ArrayList(u8) = .empty;
    errdefer xml.deinit(alloc);
    try xml.appendSlice(alloc, "<ENC_Product_Catalog><date_valid>20250903</date_valid>");
    for (0..cells) |k| {
        const row = try std.fmt.allocPrint(alloc,
            "<cell><name>US5{d:0>2}{d:0>3}</name><lname>Cell</lname>" ++
                "<cscale>20000</cscale><edtn>{d}</edtn><updn>0</updn>" ++
                "<zipfile_location>https://charts.noaa.gov/ENCs/US5{d:0>2}{d:0>3}.zip</zipfile_location>" ++
                "<zipfile_size>1000</zipfile_size>" ++
                "<coast_guard_district>{d}</coast_guard_district>" ++
                "<panel><vertex><lat>1.00</lat><long>-70.00</long></vertex>" ++
                "<vertex><lat>1.40</lat><long>-69.60</long></vertex></panel></cell>",
            .{ district, k, edition, district, k, district },
        );
        defer alloc.free(row);
        try xml.appendSlice(alloc, row);
    }
    try xml.appendSlice(alloc, "</ENC_Product_Catalog>");
    return xml.toOwnedSlice(alloc);
}

/// A fetcher that records what it was asked for and answers nothing.
const Recorder = struct {
    ids: std.ArrayList(u64) = .empty,
    urls: std.ArrayList([]u8) = .empty,
    alloc: std.mem.Allocator,

    fn deinit(self: *Recorder) void {
        for (self.urls.items) |u| self.alloc.free(u);
        self.urls.deinit(self.alloc);
        self.ids.deinit(self.alloc);
    }

    fn get(user: ?*anyopaque, req_id: u64, url: [*:0]const u8, allow_file: c_int) callconv(.c) void {
        _ = allow_file;
        const self: *Recorder = @ptrCast(@alignCast(user orelse return));
        self.ids.append(self.alloc, req_id) catch return;
        const own = self.alloc.dupe(u8, std.mem.span(url)) catch return;
        self.urls.append(self.alloc, own) catch self.alloc.free(own);
    }
};

test "a bundle NOAA does not serve is asked for cell by cell" {
    const alloc = testing.allocator;
    const dest = "/tmp/lookout-noaa-bundle-404";
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dest) catch {};

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();

    var s = Service.init(alloc);
    defer s.deinit();
    s.cat = try oneDistrict(alloc, 5, 30);
    s.phase = .ready;
    s.setProvider(Recorder.get, null, null, &rec);

    // Thirty cells is past bundle_at, so the district goes as one zip.
    s.start(&.{5}, dest, false);
    try testing.expectEqual(Phase.downloading, s.phase);
    try testing.expectEqual(@as(usize, 1), s.plan.items.len);
    try testing.expectEqual(@as(u32, 30), s.planCells());
    try testing.expectEqual(@as(usize, 1), rec.ids.items.len);
    try testing.expect(std.mem.endsWith(u8, rec.urls.items[0], "05CGD_ENCs.zip"));

    // NOAA answers 404. The download goes on with a request for each cell,
    // and the bundle stops counting toward the total.
    s.respondChunk(rec.ids.items[0], "", 404, true);
    s.adopt();
    try testing.expectEqual(@as(usize, 31), s.plan.items.len);
    try testing.expectEqual(@as(u32, 30), s.planCells());
    try testing.expectEqual(@as(u32, 0), s.failed);
    try testing.expectEqual(@as(u32, 0), s.done);
    // Four go out at once, and the rest follow as those land.
    try testing.expectEqual(@as(usize, 1 + MAX_INFLIGHT), rec.ids.items.len);
    try testing.expect(std.mem.endsWith(u8, rec.urls.items[1], ".zip"));
    try testing.expect(!std.mem.endsWith(u8, rec.urls.items[1], "CGD_ENCs.zip"));

    s.cancelAll();
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dest) catch {};
}

test "a bundle part way down counts the charts its bytes have brought" {
    const alloc = testing.allocator;
    const dest = "/tmp/lookout-noaa-inflight";
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dest) catch {};

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();

    var s = Service.init(alloc);
    defer s.deinit();
    s.cat = try oneDistrict(alloc, 5, 30);
    s.phase = .ready;
    s.setProvider(Recorder.get, null, null, &rec);
    s.start(&.{5}, dest, false);

    // One bundle standing for thirty cells of a thousand bytes each.
    try testing.expectEqual(@as(u32, 30), s.snapshot().total);
    try testing.expectEqual(@as(u32, 0), s.snapshot().done);

    // Half the bytes have landed and nothing has finished.
    const id = rec.ids.items[0];
    const half = [_]u8{0} ** 15000;
    s.respondChunk(id, &half, 200, false);
    const mid = s.snapshot();
    try testing.expectEqual(@as(u32, 15), mid.done);
    try testing.expectEqual(@as(u64, 15000), mid.bytes_done);

    // It never runs past the plan.
    const rest = [_]u8{0} ** 30000;
    s.respondChunk(id, &rest, 200, false);
    try testing.expectEqual(@as(u32, 30), s.snapshot().done);

    s.cancelAll();
    std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), dest) catch {};
}

/// One file in a zip a test builds.
pub const TestEntry = struct { name: []const u8, data: []const u8 };

/// A zip of stored entries, in the layout of an exchange set. Owned by
/// `alloc`.
pub fn testZip(alloc: std.mem.Allocator, entries: []const TestEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const offsets = try alloc.alloc(u32, entries.len);
    defer alloc.free(offsets);
    const put16 = struct {
        fn f(a: std.mem.Allocator, o: *std.ArrayList(u8), v: u16) !void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v, .little);
            try o.appendSlice(a, &b);
        }
    }.f;
    const put32 = struct {
        fn f(a: std.mem.Allocator, o: *std.ArrayList(u8), v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try o.appendSlice(a, &b);
        }
    }.f;
    for (entries, 0..) |e, i| {
        offsets[i] = @intCast(out.items.len);
        const crc = std.hash.Crc32.hash(e.data);
        try put32(alloc, &out, 0x04034b50);
        try put16(alloc, &out, 20); // version needed
        try put16(alloc, &out, 0); // flags
        try put16(alloc, &out, 0); // stored
        try put16(alloc, &out, 0); // time
        try put16(alloc, &out, 0x21); // date
        try put32(alloc, &out, crc);
        try put32(alloc, &out, @intCast(e.data.len));
        try put32(alloc, &out, @intCast(e.data.len));
        try put16(alloc, &out, @intCast(e.name.len));
        try put16(alloc, &out, 0);
        try out.appendSlice(alloc, e.name);
        try out.appendSlice(alloc, e.data);
    }
    const cd_start: u32 = @intCast(out.items.len);
    for (entries, 0..) |e, i| {
        try put32(alloc, &out, 0x02014b50);
        try put16(alloc, &out, 20); // made by
        try put16(alloc, &out, 20); // needed
        try put16(alloc, &out, 0);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, 0x21);
        try put32(alloc, &out, std.hash.Crc32.hash(e.data));
        try put32(alloc, &out, @intCast(e.data.len));
        try put32(alloc, &out, @intCast(e.data.len));
        try put16(alloc, &out, @intCast(e.name.len));
        try put16(alloc, &out, 0); // extra
        try put16(alloc, &out, 0); // comment
        try put16(alloc, &out, 0); // disk
        try put16(alloc, &out, 0); // internal attributes
        try put32(alloc, &out, 0); // external attributes
        try put32(alloc, &out, offsets[i]);
        try out.appendSlice(alloc, e.name);
    }
    const cd_size: u32 = @as(u32, @intCast(out.items.len)) - cd_start;
    try put32(alloc, &out, 0x06054b50);
    try put16(alloc, &out, 0);
    try put16(alloc, &out, 0);
    try put16(alloc, &out, @intCast(entries.len));
    try put16(alloc, &out, @intCast(entries.len));
    try put32(alloc, &out, cd_size);
    try put32(alloc, &out, cd_start);
    try put16(alloc, &out, 0);
    return out.toOwnedSlice(alloc);
}

/// Read a file a test expects to exist. Owned by `alloc`.
fn testRead(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 20));
}

fn testExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "a cell directory is named for the cell it holds" {
    try testing.expectEqualStrings("ENC_ROOT/US5MD1MC", cellDirOf("ENC_ROOT/US5MD1MC/US5MD1MC.000").?);
    try testing.expectEqualStrings("05CGD_ENCs/ENC_ROOT/US5MD1MC", cellDirOf("05CGD_ENCs/ENC_ROOT/US5MD1MC/US5MD1MC.012").?);
    try testing.expect(cellDirOf("ENC_ROOT/CATALOG.031") == null);
    try testing.expect(cellDirOf("ENC_ROOT/US5MD1MC/US5MD1MC.TXT") == null);
    try testing.expect(cellDirOf("ENC_ROOT/US5MD1MC/README.000") == null);
    try testing.expect(cellDirOf("US5MD1MC.000") == null);
}

test "a reissued cell replaces the edition already unpacked" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dest = "/tmp/lookout-noaa-reissue";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    try makeDir(dest);

    var s = Service.init(alloc);
    defer s.deinit();

    const first = try testZip(alloc, &.{
        .{ .name = "ENC_ROOT/CATALOG.031", .data = "catalog 27" },
        .{ .name = "ENC_ROOT/US5MD1MC/US5MD1MC.000", .data = "edition 27" },
        .{ .name = "ENC_ROOT/US5MD1MC/US5MD1MC.001", .data = "update 27.1" },
        .{ .name = "ENC_ROOT/US5MD1MD/US5MD1MD.000", .data = "neighbour" },
    });
    defer alloc.free(first);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest ++ "/a.zip.part", .data = first });
    try s.unpack(dest, "a", &.{});

    // The reissue has a new base and no update files.
    const second = try testZip(alloc, &.{
        .{ .name = "ENC_ROOT/CATALOG.031", .data = "catalog 28" },
        .{ .name = "ENC_ROOT/US5MD1MC/US5MD1MC.000", .data = "edition 28" },
    });
    defer alloc.free(second);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest ++ "/b.zip.part", .data = second });
    try s.unpack(dest, "b", &.{});

    const base = try testRead(alloc, dest ++ "/ENC_ROOT/US5MD1MC/US5MD1MC.000");
    defer alloc.free(base);
    try testing.expectEqualStrings("edition 28", base);
    // The old edition's update file is deleted with it.
    try testing.expect(!testExists(dest ++ "/ENC_ROOT/US5MD1MC/US5MD1MC.001"));
    // A cell missing from the reissue is untouched.
    try testing.expect(testExists(dest ++ "/ENC_ROOT/US5MD1MD/US5MD1MD.000"));
    // The part files are gone.
    try testing.expect(!testExists(dest ++ "/b.zip.part"));
}

test "a catalog read during a download leaves the download running" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dest = "/tmp/lookout-noaa-refresh-mid";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testCacheRoot(&tmp);
    defer alloc.free(root);

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();

    var s = Service.init(alloc);
    defer s.deinit();
    // Ten cells, under bundle_at, so each is its own request.
    s.cat = try oneDistrict(alloc, 5, 10);
    s.phase = .ready;
    s.setProvider(Recorder.get, null, null, &rec);
    s.start(&.{5}, dest, false);
    try testing.expectEqual(Phase.downloading, s.phase);
    try testing.expectEqual(@as(usize, MAX_INFLIGHT), rec.ids.items.len);

    // Try Again in the picker reads the catalog mid transfer.
    s.refresh();
    try testing.expectEqual(Phase.downloading, s.phase);
    try testing.expect(s.catalog_inflight);
    const cat_id = rec.ids.items[rec.ids.items.len - 1];
    try testing.expect(std.mem.endsWith(u8, rec.urls.items[rec.urls.items.len - 1], "ENCProdCat.xml"));
    // A second refresh issues no request while the first is out.
    s.refresh();
    try testing.expectEqual(@as(usize, MAX_INFLIGHT + 1), rec.ids.items.len);

    s.respond(cat_id, test_catalog, 200);
    s.adopt();
    try testing.expect(!s.catalog_inflight);
    try testing.expectEqual(Phase.downloading, s.phase);

    // Every cell request fails. The plan issues all ten requests and ends,
    // instead of stopping after the first four.
    var answered: usize = 0;
    while (answered < rec.ids.items.len) : (answered += 1) {
        const id = rec.ids.items[answered];
        if (id == cat_id) continue;
        s.respond(id, "", 500);
        s.adopt();
    }
    try testing.expectEqual(@as(usize, 10 + 1), rec.ids.items.len);
    try testing.expectEqual(Phase.ready, s.phase);
    try testing.expectEqual(@as(u32, 10), s.failed);
}

test "an update with no fetcher says so and leaves the phase" {
    var s = Service.init(testing.allocator);
    defer s.deinit();
    s.cat = try oneDistrict(testing.allocator, 5, 3);
    s.phase = .ready;
    const installed = [_]noaa.Installed{.{ .name = "US505000", .edition = 0, .update = 0 }};
    s.startUpdate(&installed, "/tmp/lookout-noaa-test-should-not-exist");
    try testing.expectEqual(Phase.ready, s.phase);
    try testing.expectEqualStrings("no network provider", s.err);
}

test "a bundle that will not unpack fails every chart it stood for" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dest = "/tmp/lookout-noaa-bundle-broken";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();

    var s = Service.init(alloc);
    defer s.deinit();
    s.cat = try oneDistrict(alloc, 5, 30);
    s.phase = .ready;
    s.setProvider(Recorder.get, null, null, &rec);
    s.start(&.{5}, dest, false);
    try testing.expectEqual(@as(u32, 30), s.planCells());

    // Bytes arrive and are not a zip.
    s.respond(rec.ids.items[0], "not a zip at all", 200);
    var tries: usize = 0;
    while (s.phase == .downloading and tries < 2000) : (tries += 1) {
        s.adopt();
        lock.sleepMs(1);
    }
    try testing.expectEqual(Phase.ready, s.phase);
    const snap = s.snapshot();
    try testing.expectEqual(@as(u32, 30), snap.failed);
    try testing.expectEqual(snap.total, snap.done + snap.failed);
}

test "the unpack thread ends with the download" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dest = "/tmp/lookout-noaa-unpacker-ends";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();

    var s = Service.init(alloc);
    defer s.deinit();
    s.cat = try oneDistrict(alloc, 5, 1);
    s.phase = .ready;
    s.setProvider(Recorder.get, null, null, &rec);
    s.start(&.{5}, dest, false);
    try testing.expect(s.unpackerRunning());

    const zip = try testZip(alloc, &.{
        .{ .name = "ENC_ROOT/US505000/US505000.000", .data = "cell" },
    });
    defer alloc.free(zip);
    s.respond(rec.ids.items[0], zip, 200);

    var tries: usize = 0;
    while ((s.phase == .downloading or s.unpackerRunning()) and tries < 2000) : (tries += 1) {
        s.adopt();
        lock.sleepMs(1);
    }
    try testing.expectEqual(Phase.ready, s.phase);
    try testing.expectEqual(@as(u32, 1), s.done);
    try testing.expect(!s.unpackerRunning());
    try testing.expect(testExists(dest ++ "/ENC_ROOT/US505000/US505000.000"));

    // A second download starts a thread of its own.
    s.start(&.{5}, dest, true);
    try testing.expect(s.unpackerRunning());
    s.cancelAll();
}

/// How many part files are left in `dir`.
fn testParts(dir: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var n: usize = 0;
    while (try it.next(io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".zip.part")) n += 1;
    }
    return n;
}

test "a new download starts while the cancelled one's cells are still queued" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const old = "/tmp/lookout-noaa-restart-old";
    const new = "/tmp/lookout-noaa-restart-new";
    std.Io.Dir.cwd().deleteTree(io, old) catch {};
    std.Io.Dir.cwd().deleteTree(io, new) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, old) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, new) catch {};

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();

    var s = Service.init(alloc);
    defer s.deinit();
    s.cat = try oneDistrict(alloc, 5, 10);
    s.phase = .ready;
    s.setProvider(Recorder.get, null, null, &rec);
    s.start(&.{5}, old, false);
    try testing.expectEqual(@as(usize, MAX_INFLIGHT), rec.ids.items.len);

    // The test holds the unpack lock, so the first thread cannot finish a
    // cell before the second download starts.
    s.unpack_work.lock();
    var held = true;
    defer if (held) s.unpack_work.unlock();

    const zip = try testZip(alloc, &.{
        .{ .name = "ENC_ROOT/US505000/US505000.000", .data = "cell" },
    });
    defer alloc.free(zip);
    for (rec.ids.items) |id| s.respond(id, zip, 200);
    try testing.expectEqual(@as(usize, MAX_INFLIGHT), try testParts(old));

    s.cancelAll();
    s.start(&.{5}, new, false);
    try testing.expectEqual(Phase.downloading, s.phase);
    try testing.expect(!testExists(old ++ "/ENC_ROOT"));

    s.unpack_work.unlock();
    held = false;
    var tries: usize = 0;
    while (s.reap.items.len != 0 and tries < 2000) : (tries += 1) {
        s.adopt();
        lock.sleepMs(1);
    }
    try testing.expectEqual(@as(usize, 0), s.reap.items.len);
    // Every queued cell of the cancelled download was dropped unwritten, and
    // its part file with it.
    try testing.expect(!testExists(old ++ "/ENC_ROOT"));
    try testing.expectEqual(@as(usize, 0), try testParts(old));
    s.cancelAll();
}

test "a bundle leaves the cells already held as they are" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dest = "/tmp/lookout-noaa-bundle-held";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();

    var s = Service.init(alloc);
    defer s.deinit();
    s.cat = try oneDistrict(alloc, 5, 412);
    s.phase = .ready;
    s.setProvider(Recorder.get, null, null, &rec);

    // The first 300 cells are held. Two of them are on disk here.
    var names: [412][8]u8 = undefined;
    var held: [300][]const u8 = undefined;
    for (&names, 0..) |*n, k| _ = try std.fmt.bufPrint(n, "US505{d:0>3}", .{k});
    for (&held, 0..) |*h, k| h.* = &names[k];
    s.setHeld(&held);
    try makeDir(dest ++ "/ENC_ROOT/US505000");
    try makeDir(dest ++ "/ENC_ROOT/US505299");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest ++ "/ENC_ROOT/US505000/US505000.000", .data = "held" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest ++ "/ENC_ROOT/US505299/US505299.000", .data = "held" });

    s.start(&.{5}, dest, false);
    // 112 missing is past bundle_at, so the district comes as one bundle.
    try testing.expectEqual(@as(usize, 1), rec.ids.items.len);

    var paths: [412][40]u8 = undefined;
    var entries: [412]TestEntry = undefined;
    for (&entries, 0..) |*e, k| e.* = .{
        .name = try std.fmt.bufPrint(&paths[k], "ENC_ROOT/{s}/{s}.000", .{ &names[k], &names[k] }),
        .data = "bundle",
    };
    const zip = try testZip(alloc, &entries);
    defer alloc.free(zip);
    s.respond(rec.ids.items[0], zip, 200);

    var tries: usize = 0;
    while (s.phase == .downloading and tries < 5000) : (tries += 1) {
        s.adopt();
        lock.sleepMs(1);
    }
    try testing.expectEqual(Phase.ready, s.phase);

    // The held cells on disk are the ones that were there.
    for ([_][]const u8{ dest ++ "/ENC_ROOT/US505000/US505000.000", dest ++ "/ENC_ROOT/US505299/US505299.000" }) |p| {
        const got = try testRead(alloc, p);
        defer alloc.free(got);
        try testing.expectEqualStrings("held", got);
    }
    // A held cell stored elsewhere is not written here.
    try testing.expect(!testExists(dest ++ "/ENC_ROOT/US505150"));
    // Every missing cell is written.
    var written: usize = 0;
    for (names[300..]) |*n| {
        var buf: [96]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, dest ++ "/ENC_ROOT/{s}/{s}.000", .{ n, n });
        if (testExists(p)) written += 1;
    }
    try testing.expectEqual(@as(usize, 112), written);
}

/// Run adopt until the download ends or two seconds pass. The unpack thread
/// posts on its own time.
fn testDrain(s: *Service) void {
    var tries: usize = 0;
    while ((s.phase == .downloading or s.unpackerRunning()) and tries < 2000) : (tries += 1) {
        s.adopt();
        lock.sleepMs(1);
    }
}

test "each way a download ends sets its outcome and numbers the run" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dest = "/tmp/lookout-noaa-outcomes";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Service.init(alloc);
    defer s.deinit();
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.none)), s.snapshot().outcome);
    try testing.expectEqual(@as(u32, 0), s.snapshot().run);

    // Refused: no catalog.
    s.start(&.{5}, dest, false);
    try testing.expectEqual(Outcome.refused, s.outcome);
    try testing.expectEqual(@as(u32, 1), s.run);

    s.cat = try oneDistrict(alloc, 5, 2);
    s.phase = .ready;
    s.setProvider(Recorder.get, null, null, &rec);

    // Finished: one chart arrives, one fails.
    s.start(&.{5}, dest, false);
    try testing.expectEqual(Outcome.running, s.outcome);
    try testing.expectEqual(@as(u32, 2), s.run);
    try testing.expectEqual(@as(usize, 2), rec.ids.items.len);
    const zip = try testZip(alloc, &.{.{ .name = "ENC_ROOT/US505000/US505000.000", .data = "cell" }});
    defer alloc.free(zip);
    s.respond(rec.ids.items[0], zip, 200);
    s.respond(rec.ids.items[1], "", 500);
    testDrain(&s);
    try testing.expectEqual(Outcome.finished, s.outcome);
    try testing.expectEqual(@as(u32, 1), s.done);
    try testing.expectEqual(@as(u32, 1), s.failed);

    // Failed: every chart fails.
    s.start(&.{5}, dest, true);
    try testing.expectEqual(@as(u32, 3), s.run);
    for (rec.ids.items[2..]) |id| s.respond(id, "", 404);
    testDrain(&s);
    try testing.expectEqual(Outcome.failed, s.outcome);

    // Cancelled.
    s.start(&.{5}, dest, true);
    try testing.expectEqual(@as(u32, 4), s.run);
    s.cancelAll();
    try testing.expectEqual(Outcome.cancelled, s.outcome);

    // Empty: every chart is held, so no request goes out.
    const before = rec.ids.items.len;
    s.setHeld(&.{ "US505000", "US505001" });
    s.start(&.{5}, dest, false);
    try testing.expectEqual(Outcome.empty, s.outcome);
    try testing.expectEqual(@as(u32, 5), s.run);
    try testing.expectEqual(before, rec.ids.items.len);

    // Empty: an update with no reissue.
    const current = [_]noaa.Installed{.{ .name = "US505000", .edition = 1, .update = 0 }};
    s.startUpdate(&current, dest);
    try testing.expectEqual(Outcome.empty, s.outcome);
    try testing.expectEqual(@as(u32, 6), s.run);

    // The snapshot has both.
    const snap = s.snapshot();
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.empty)), snap.outcome);
    try testing.expectEqual(@as(u32, 6), snap.run);
}

test "a refused order and a failed transfer each set retry by cause" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dest = "/tmp/lookout-noaa-retry";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var s = Service.init(alloc);
    defer s.deinit();

    // No catalog: a refresh can supply one.
    s.start(&.{5}, dest, false);
    var snap = s.snapshot();
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.refused)), snap.outcome);
    try testing.expectEqual(@as(u8, 1), snap.retry);

    s.cat = try oneDistrict(alloc, 5, 2);
    s.phase = .ready;

    // No fetcher.
    s.start(&.{5}, dest, false);
    snap = s.snapshot();
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.refused)), snap.outcome);
    try testing.expectEqual(@as(u8, 0), snap.retry);

    // No download directory: its parent is a file.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "x" });
    const under_file = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/file/lookout-noaa-retry", .{tmp.sub_path});
    defer alloc.free(under_file);
    s.setProvider(Recorder.get, null, null, &rec);
    s.start(&.{5}, under_file, false);
    snap = s.snapshot();
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.refused)), snap.outcome);
    try testing.expectEqual(@as(u8, 0), snap.retry);
    try testing.expectEqual(@as(usize, 0), rec.ids.items.len);

    // Every transfer fails on the network.
    s.start(&.{5}, dest, false);
    for (rec.ids.items) |id| s.respond(id, "", 503);
    testDrain(&s);
    snap = s.snapshot();
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.failed)), snap.outcome);
    try testing.expectEqual(@as(u8, 1), snap.retry);

    // Every transfer arrives and cannot be written.
    const before = rec.ids.items.len;
    s.start(&.{5}, dest, true);
    for (rec.ids.items[before..]) |id| s.respond(id, "not a zip", 200);
    testDrain(&s);
    snap = s.snapshot();
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.failed)), snap.outcome);
    try testing.expectEqual(@as(u8, 0), snap.retry);
}

test "changed rises once for each change and stays down while idle" {
    const alloc = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dest = "/tmp/lookout-noaa-changed";
    std.Io.Dir.cwd().deleteTree(io, dest) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dest) catch {};

    // A fetcher that records the ids and counts the wakes.
    const Fetch = struct {
        ids: std.ArrayList(u64) = .empty,
        wakes: std.atomic.Value(u32) = .init(0),

        fn get(user: ?*anyopaque, req_id: u64, url: [*:0]const u8, allow_file: c_int) callconv(.c) void {
            _ = url;
            _ = allow_file;
            const self: *@This() = @ptrCast(@alignCast(user orelse return));
            self.ids.append(testing.allocator, req_id) catch {};
        }
        fn wake(user: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user orelse return));
            _ = self.wakes.fetchAdd(1, .monotonic);
        }
    };
    var f = Fetch{};
    defer f.ids.deinit(alloc);

    var h = Handle.init(alloc);
    defer h.deinit();
    h.svc.cat = try oneDistrict(alloc, 5, 1);
    h.svc.phase = .ready;
    h.setProvider(Fetch.get, null, Fetch.wake, &f);

    // Publishing the catalog loaded above is one change.
    try testing.expect(h.changed());
    for (0..5) |_| try testing.expect(!h.changed());

    // Naming held cells leaves the published state as it was.
    h.have(&.{"US509999"});
    try testing.expect(!h.changed());

    h.download(&.{5}, dest, false);
    try testing.expect(h.changed());
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.running)), h.poll().outcome);
    for (0..5) |_| try testing.expect(!h.changed());
    try testing.expectEqual(@as(u32, 0), f.wakes.load(.monotonic));

    // The response wakes the shell. The state stays as it was until changed
    // adopts it.
    const zip = try testZip(alloc, &.{.{ .name = "ENC_ROOT/US505000/US505000.000", .data = "cell" }});
    defer alloc.free(zip);
    h.respondChunk(f.ids.items[0], zip, 200, true);
    var tries: usize = 0;
    while (f.wakes.load(.monotonic) == 0 and tries < 2000) : (tries += 1) lock.sleepMs(1);
    try testing.expectEqual(@as(u32, 1), f.wakes.load(.monotonic));
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.running)), h.poll().outcome);
    try testing.expect(h.changed());
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.finished)), h.poll().outcome);
    try testing.expectEqual(@as(u32, 1), h.poll().done);

    // Idle again. The unpack thread is joined without a change to report.
    tries = 0;
    while (h.svc.unpackerRunning() and tries < 2000) : (tries += 1) {
        try testing.expect(!h.changed());
        lock.sleepMs(1);
    }
    try testing.expect(!h.svc.unpackerRunning());
    for (0..5) |_| try testing.expect(!h.changed());
    try testing.expectEqual(@as(u32, 1), f.wakes.load(.monotonic));
}

// ---- the held cells and the update check, off the chart sets -----------------

const library = @import("library.zig");

/// A store and a chart set list in a directory of the test's own.
const SetsFixture = struct {
    tmp: std.testing.TmpDir,
    dir: []u8,
    store: *settings.Store,
    sets: *chartsets.Sets,

    const io = std.Io.Threaded.global_single_threaded.io();

    fn init(inventory: ?library.TakeInventory) !SetsFixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer testing.allocator.free(dir);
        const store = try settings.Store.open(testing.allocator, io, dir);
        errdefer store.close();
        const sets = try chartsets.Sets.open(testing.allocator, io, store, "", inventory);
        return .{ .tmp = tmp, .dir = dir, .store = store, .sets = sets };
    }

    fn deinit(self: *SetsFixture) void {
        self.sets.close();
        self.store.close();
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    /// A folder holding exactly the files named. The caller frees the path.
    fn folder(self: *SetsFixture, name: []const u8, files: []const []const u8) ![]u8 {
        try self.tmp.dir.createDirPath(io, name);
        var buf: [256]u8 = undefined;
        for (files) |f| {
            const sub = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ name, f });
            try self.tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "x" });
        }
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.dir, name });
    }

    /// Wait for the scan worker to finish.
    fn settle(self: *SetsFixture) void {
        for (0..2000) |_| {
            self.sets.mu.lock();
            const idle = !self.sets.running and self.sets.queue.items.len == 0;
            self.sets.mu.unlock();
            if (idle) return;
            lock.sleepMs(1);
        }
    }
};

/// An inventory reporting US505000 at edition 1 in every folder.
fn editionOne(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    path: []const u8,
    out: *std.ArrayList(library.InventoryRow),
) bool {
    const cell = std.fmt.allocPrint(alloc, "{s}/US505000.000", .{path}) catch return false;
    out.append(alloc, .{
        .path = cell,
        .name = alloc.dupe(u8, "US505000") catch return false,
        .kind = .source,
        .bytes = 4096,
        .edition = 1,
    }) catch return false;
    return true;
}

test "the held cells follow the chart sets as a set is added and removed" {
    const alloc = testing.allocator;
    var f = try SetsFixture.init(null);
    defer f.deinit();

    var h = Handle.init(alloc);
    defer h.deinit();
    h.sets = f.sets;
    h.svc.cat = try oneDistrict(alloc, 5, 3);
    h.svc.phase = .ready;

    const a = try f.folder("A", &.{"US505000.000"});
    defer alloc.free(a);
    const b = try f.folder("B", &.{"US505001.000"});
    defer alloc.free(b);

    try testing.expectEqual(@as(u32, 0), h.cost(&.{5}).?.held);
    try testing.expect(f.sets.add(a));
    f.settle();
    try testing.expectEqual(@as(u32, 1), h.cost(&.{5}).?.held);
    try testing.expect(f.sets.add(b));
    f.settle();
    try testing.expectEqual(@as(u32, 2), h.cost(&.{5}).?.held);
    // A set switched off still holds its cells.
    try testing.expect(f.sets.setOn(b, false));
    try testing.expectEqual(@as(u32, 2), h.cost(&.{5}).?.held);
    try testing.expect(f.sets.remove(a));
    const left = h.cost(&.{5}).?;
    try testing.expectEqual(@as(u32, 1), left.held);
    try testing.expectEqual(@as(u32, 2), left.cells);
}

test "the update count reads a catalog from the network, and the cached one counts 0" {
    const alloc = testing.allocator;
    var cache = testing.tmpDir(.{});
    defer cache.cleanup();
    const root = try testCacheRoot(&cache);
    defer alloc.free(root);

    var f = try SetsFixture.init(editionOne);
    defer f.deinit();
    const dir = try f.folder("NOAA", &.{});
    defer alloc.free(dir);
    try testing.expect(f.sets.add(dir));
    try testing.expect(f.sets.setManaged(dir, true));
    f.settle();

    // The cached catalog and the network both list edition 2.
    const xml = try districtXml(alloc, 5, 3, 2);
    defer alloc.free(xml);
    {
        var s = Service.init(alloc);
        defer s.deinit();
        s.cacheCatalog(xml);
    }

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var h = Handle.init(alloc);
    defer h.deinit();
    h.sets = f.sets;
    h.store = f.store;
    h.setProvider(Recorder.get, null, null, &rec);

    h.refresh();
    try testing.expect(h.svc.haveCatalog());
    try testing.expectEqual(@as(u32, 0), h.outdatedOfSets());
    try testing.expectEqual(@as(usize, 1), rec.ids.items.len);

    h.respondChunk(rec.ids.items[0], xml, 200, true);
    try testing.expect(h.changed());
    try testing.expectEqual(@as(u32, 1), h.outdatedOfSets());
}

test "with no managed cell the update check sends no request" {
    const alloc = testing.allocator;
    var cache = testing.tmpDir(.{});
    defer cache.cleanup();
    const root = try testCacheRoot(&cache);
    defer alloc.free(root);

    var f = try SetsFixture.init(editionOne);
    defer f.deinit();
    const dir = try f.folder("Mine", &.{});
    defer alloc.free(dir);
    try testing.expect(f.sets.add(dir));
    f.settle();

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var h = Handle.init(alloc);
    defer h.deinit();
    h.sets = f.sets;
    h.store = f.store;
    h.setProvider(Recorder.get, null, null, &rec);

    const now = @divFloor(clock.wallMs(), 1000);
    try testing.expect(!h.updateDue(now));
    try testing.expectEqual(@as(usize, 0), rec.ids.items.len);

    // The same cells in a managed set are checked.
    try testing.expect(f.sets.setManaged(dir, true));
    try testing.expect(h.updateDue(now));
    try testing.expectEqual(@as(usize, 1), rec.ids.items.len);
}

test "the update check follows the cadence and records a read that succeeded" {
    const alloc = testing.allocator;
    var cache = testing.tmpDir(.{});
    defer cache.cleanup();
    const root = try testCacheRoot(&cache);
    defer alloc.free(root);

    var f = try SetsFixture.init(editionOne);
    defer f.deinit();
    const dir = try f.folder("NOAA", &.{});
    defer alloc.free(dir);
    try testing.expect(f.sets.add(dir));
    try testing.expect(f.sets.setManaged(dir, true));
    f.settle();

    const xml = try districtXml(alloc, 5, 3, 2);
    defer alloc.free(xml);

    var rec = Recorder{ .alloc = alloc };
    defer rec.deinit();
    var h = Handle.init(alloc);
    defer h.deinit();
    h.sets = f.sets;
    h.store = f.store;
    h.setProvider(Recorder.get, null, null, &rec);

    const group = settings.group_chartsets;
    const now = @divFloor(clock.wallMs(), 1000);

    f.store.setText(group, Handle.cadence_key, "never");
    try testing.expect(!h.updateDue(now));
    try testing.expectEqual(@as(usize, 0), rec.ids.items.len);

    // Daily, never checked: due, and one read goes out.
    f.store.setText(group, Handle.cadence_key, "daily");
    try testing.expect(h.updateDue(now));
    try testing.expectEqual(@as(usize, 1), rec.ids.items.len);
    // A second call while it runs sends no second read.
    try testing.expect(h.updateDue(now));
    try testing.expectEqual(@as(usize, 1), rec.ids.items.len);

    // A failed read leaves the check unrecorded and due.
    h.respondChunk(rec.ids.items[0], "", 500, true);
    _ = h.changed();
    try testing.expect(!f.store.has(group, Handle.checked_key));
    try testing.expect(h.updateDue(now));
    try testing.expectEqual(@as(usize, 2), rec.ids.items.len);

    // A read that succeeds is recorded, and the next day is the next check.
    h.respondChunk(rec.ids.items[1], xml, 200, true);
    _ = h.changed();
    try testing.expect(f.store.has(group, Handle.checked_key));
    try testing.expectEqual(@as(u32, 1), h.outdatedOfSets());
    try testing.expect(!h.updateDue(now + 60 * 60));
    try testing.expectEqual(@as(usize, 2), rec.ids.items.len);
    try testing.expect(h.updateDue(now + 25 * 60 * 60));
    try testing.expectEqual(@as(usize, 3), rec.ids.items.len);
    h.respondChunk(rec.ids.items[2], xml, 200, true);
    _ = h.changed();

    // At startup: once per handle, whenever the last check was.
    f.store.setText(group, Handle.cadence_key, "startup");
    try testing.expect(!h.updateDue(now + 25 * 60 * 60));
    try testing.expectEqual(@as(usize, 3), rec.ids.items.len);

    var next = Handle.init(alloc);
    defer next.deinit();
    next.sets = f.sets;
    next.store = f.store;
    next.setProvider(Recorder.get, null, null, &rec);
    try testing.expect(next.updateDue(now));
    try testing.expectEqual(@as(usize, 4), rec.ids.items.len);
}

test "a streamed transfer wakes the shell as its bytes arrive, and an idle service stays asleep" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dest = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/NOAA", .{tmp.sub_path});
    defer alloc.free(dest);

    const Fetch = struct {
        ids: std.ArrayList(u64) = .empty,
        wakes: std.atomic.Value(u32) = .init(0),

        fn get(user: ?*anyopaque, req_id: u64, url: [*:0]const u8, allow_file: c_int) callconv(.c) void {
            _ = url;
            _ = allow_file;
            const self: *@This() = @ptrCast(@alignCast(user orelse return));
            self.ids.append(testing.allocator, req_id) catch {};
        }
        fn wake(user: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user orelse return));
            _ = self.wakes.fetchAdd(1, .monotonic);
        }
    };
    var f = Fetch{};
    defer f.ids.deinit(alloc);

    var h = Handle.init(alloc);
    defer h.deinit();
    h.svc.cat = try oneDistrict(alloc, 5, 1);
    h.svc.phase = .ready;
    h.setProvider(Fetch.get, null, Fetch.wake, &f);
    _ = h.changed();

    // Idle: no wake and no change.
    for (0..5) |_| try testing.expect(!h.changed());
    try testing.expectEqual(@as(u32, 0), f.wakes.load(.monotonic));

    h.download(&.{5}, dest, false);
    try testing.expect(h.changed());
    try testing.expectEqual(@as(u32, 0), f.wakes.load(.monotonic));

    const zip = try testZip(alloc, &.{.{ .name = "ENC_ROOT/US505000/US505000.000", .data = "cell" }});
    defer alloc.free(zip);
    const third = zip.len / 3;
    const id = f.ids.items[0];

    // The first piece wakes the shell, and the bytes are there to read.
    h.respondChunk(id, zip[0..third], 200, false);
    try testing.expectEqual(@as(u32, 1), f.wakes.load(.monotonic));
    try testing.expect(h.changed());
    try testing.expectEqual(@as(u64, third), h.poll().bytes_done);

    // A second piece inside the quarter second raises no wake.
    h.respondChunk(id, zip[third .. 2 * third], 200, false);
    try testing.expectEqual(@as(u32, 1), f.wakes.load(.monotonic));

    // After it, the next piece wakes the shell again.
    lock.sleepMs(Service.progress_every_ms + 10);
    h.respondChunk(id, zip[2 * third .. zip.len - 1], 200, false);
    try testing.expectEqual(@as(u32, 2), f.wakes.load(.monotonic));
    try testing.expect(h.changed());
    try testing.expectEqual(@as(u64, zip.len - 1), h.poll().bytes_done);
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.running)), h.poll().outcome);

    h.respondChunk(id, zip[zip.len - 1 ..], 200, true);
    var tries: usize = 0;
    while (h.poll().outcome == @intFromEnum(Outcome.running) and tries < 2000) : (tries += 1) {
        _ = h.changed();
        lock.sleepMs(1);
    }
    try testing.expectEqual(@as(u8, @intFromEnum(Outcome.finished)), h.poll().outcome);

    // Idle again: the wakes stop.
    tries = 0;
    while (h.svc.unpackerRunning() and tries < 2000) : (tries += 1) {
        _ = h.changed();
        lock.sleepMs(1);
    }
    const woke = f.wakes.load(.monotonic);
    for (0..5) |_| try testing.expect(!h.changed());
    lock.sleepMs(Service.progress_every_ms + 10);
    try testing.expect(!h.changed());
    try testing.expectEqual(woke, f.wakes.load(.monotonic));
}
