//! Downloading NOAA's charts: the catalog, the plan, and the transfer.
//!
//! The core decides which cells a region needs (src/noaa.zig), asks the shell
//! for each url, and writes the exchange-set zips into a staging directory.
//! The shell fetches bytes and bakes the directory afterward. No socket opens
//! here, for the reason chart links give: one fetcher serves the whole app,
//! and the shell owns it.
//!
//! Request ids have bit 63 set so lookout_http_respond can route an answer to
//! this service or to chartlinks without the two sharing an id space.

const std = @import("std");
const noaa = @import("noaa.zig");
const clinks = @import("chartlinks.zig");
const lock = @import("lock.zig");
const Lock = lock.Lock;
const clock = @import("clock.zig");

/// Set on every request id this service issues.
pub const id_mark: u64 = @as(u64, 1) << 63;

/// True when this answer belongs to a NOAA download.
pub fn ownsId(id: u64) bool {
    return id & id_mark != 0;
}

/// How many cell zips transfer at once. NOAA serves a public archive, and a
/// mariner on a marina uplink gains little past four.
pub const MAX_INFLIGHT = 4;


/// A cell zip larger than this is not the file we asked for.
pub const MAX_ZIP_BYTES: usize = 64 << 20;

/// What the service is doing.
pub const Phase = enum(u8) {
    idle = 0,
    /// One request out for ENCProdCat.xml.
    reading_catalog = 1,
    /// A catalog is loaded and a selection can be priced.
    ready = 2,
    downloading = 3,
};

/// One cell to fetch. The slices point into the catalog arena.
const Job = struct {
    name: []const u8,
    url: []const u8,
    bytes: u64,
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

/// One outstanding cell. The fetch thread reads the name to unpack the bytes
/// it receives.
const Stage = struct {
    id: u64,
    name: []u8,
};

/// One fetched cell, waiting to be written. Owned by the unpack thread once
/// it is queued.
const Pending = struct {
    id: u64,
    name: []u8,
    bytes: []u8,
    status: c_int,
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
};

/// The catalog, the plan, and the transfer.
pub const Service = struct {
    alloc: std.mem.Allocator,

    get: ?clinks.HttpGetFn = null,
    cancel: ?clinks.HttpCancelFn = null,
    user: ?*anyopaque = null,

    cat: ?noaa.Catalog = null,
    checked_at: i64 = 0,
    err: []u8 = &.{},
    phase: Phase = .idle,
    /// Raised when the snapshot changes. The shell's frame loop reads it.
    changed: bool = false,

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

    /// The cells this device already holds, sorted by name. The shell reads
    /// them off the chart sets and hands them over, so picking water that is
    /// already downloaded fetches what is missing from it.
    held: std.ArrayList([]u8) = .empty,

    /// Cells fetched and not yet written, and the thread that writes them.
    ///
    /// A thread of its own, because writing a cell is file work of a few
    /// milliseconds. On the frame loop it held the api lock and the window
    /// stopped repainting. On the fetch thread it held the shell's fetch
    /// lock, which the frame loop needs to start the next transfer. Under
    /// both, the count sat at 1 of 829 while the disk filled.
    unpack_mu: Lock = .{},
    unpack_q: std.ArrayList(Pending) = .empty,
    unpack_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    unpack_thread: ?std.Thread = null,

    /// The snapshot a shell reads, and the lock that guards it.
    ///
    /// A lock of its own, held for one struct copy. The api lock is
    /// os_unfair_lock and the frame loop reclaims it the instant it drops it,
    /// so a poll on the main thread blocked for the whole download and the
    /// count read 0 of 829 until it ended.
    pub_mu: Lock = .{},
    pub_state: State = .{},

    /// Answers from the shell's fetch threads, guarded by inbox_mu alone.
    inbox_mu: Lock = .{},
    inbox: std.ArrayList(Answer) = .empty,
    inbox_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(alloc: std.mem.Allocator) Service {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Service) void {
        for (self.held.items) |n| self.alloc.free(n);
        self.held.deinit(self.alloc);
        self.cancelAll();
        self.stopUnpacker();
        self.unpack_q.deinit(self.alloc);
        self.freeStr(&self.stage_dest);
        self.stage.deinit(self.alloc);
        if (self.cat) |*c| c.deinit();
        self.cat = null;
        self.freeStr(&self.err);
        if (self.dest.len != 0) self.alloc.free(self.dest);
        self.dest = &.{};
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

    pub fn setProvider(self: *Service, get: ?clinks.HttpGetFn, cancel: ?clinks.HttpCancelFn, user: ?*anyopaque) void {
        self.get = get;
        self.cancel = cancel;
        self.user = user;
        if (get == null) self.cancelAll();
    }

    pub fn hasProvider(self: *const Service) bool {
        return self.get != null;
    }

    /// Hand one url to the shell. Returns the request id, or 0 when no
    /// fetcher is set or the request could not be recorded.
    /// Record which cell an outstanding request fetches, for the fetch
    /// thread.
    fn stageCell(self: *Service, id: u64, name: []const u8) void {
        const own = self.alloc.dupe(u8, name) catch return;
        self.stage_mu.lock();
        defer self.stage_mu.unlock();
        self.stage.append(self.alloc, .{ .id = id, .name = own }) catch self.alloc.free(own);
    }

    /// Take an outstanding cell's name, or null for a request that is not one.
    /// The caller owns the name and frees it.
    fn takeStaged(self: *Service, id: u64) ?[]u8 {
        self.stage_mu.lock();
        defer self.stage_mu.unlock();
        for (self.stage.items, 0..) |st, i| {
            if (st.id == id) return self.stage.swapRemove(i).name;
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
        self.stage_mu.lock();
        defer self.stage_mu.unlock();
        for (self.stage.items) |st| self.alloc.free(st.name);
        self.stage.clearRetainingCapacity();
    }

    fn issue(self: *Service, url: []const u8, kind: Kind, job: usize) u64 {
        const get = self.get orelse return 0;
        const z = self.alloc.dupeZ(u8, url) catch return 0;
        defer self.alloc.free(z);
        const id = self.next_req | id_mark;
        self.next_req += 1;
        self.reqs.append(self.alloc, .{ .id = id, .kind = kind, .job = job }) catch return 0;
        if (kind == .cell) self.stageCell(id, self.plan.items[job].name);
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
        self.clearStage();
        self.inflight = 0;
        if (self.phase == .downloading or self.phase == .reading_catalog) {
            self.phase = if (self.cat != null) .ready else .idle;
            self.changed = true;
        }
    }

    // ---- the catalog ------------------------------------------------------

    /// Read NOAA's product catalog. One request is outstanding at a time.
    pub fn refresh(self: *Service) void {
        if (self.phase == .reading_catalog) return;
        if (self.get == null) {
            self.setErr("no network provider");
            return;
        }
        self.freeStr(&self.err);
        self.phase = .reading_catalog;
        self.changed = true;
        if (self.issue(noaa.catalog_url, .catalog, 0) == 0) {
            self.phase = if (self.cat != null) .ready else .idle;
            self.setErr("could not start the catalog request");
        }
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
    pub fn start(self: *Service, districts: []const u8, dest: []const u8) void {
        const cat = &(self.cat orelse {
            self.setErr("no catalog yet");
            return;
        });
        if (self.get == null) {
            self.setErr("no network provider");
            return;
        }

        self.cancelAll();
        self.plan.clearRetainingCapacity();
        self.next_job = 0;
        self.done = 0;
        self.failed = 0;
        self.bytes_done = 0;
        self.bytes_total = 0;
        self.freeStr(&self.err);

        const picked = noaa.selectRegions(self.alloc, cat, districts) catch {
            self.setErr("out of memory selecting cells");
            return;
        };
        defer self.alloc.free(picked);

        for (picked) |i| {
            const c = cat.cells[i];
            if (c.zip_url.len == 0) continue;
            // Already on the device. A mariner picking water they have adds
            // what is missing from it.
            if (noaa.isHeld(self.held.items, c.name)) continue;
            self.plan.append(self.alloc, .{
                .name = c.name,
                .url = c.zip_url,
                .bytes = c.zip_bytes,
            }) catch break;
            self.bytes_total += c.zip_bytes;
        }
        if (self.plan.items.len == 0) {
            self.setErr("every chart for those regions is already installed");
            return;
        }

        self.freeStr(&self.dest);
        self.dest = self.alloc.dupe(u8, dest) catch {
            self.setErr("out of memory");
            return;
        };
        makeDir(dest) catch {
            self.setErr("could not create the download directory");
            return;
        };
        self.setStageDest(dest);
        self.startUnpacker();

        self.phase = .downloading;
        self.changed = true;
        self.pump();
    }

    /// Download the cells NOAA has reissued since these were installed.
    pub fn startUpdate(self: *Service, installed: []const noaa.Installed, dest: []const u8) void {
        const cat = &(self.cat orelse {
            self.setErr("no catalog yet");
            return;
        });
        const stale = noaa.outdated(self.alloc, cat, installed) catch {
            self.setErr("out of memory checking editions");
            return;
        };
        defer self.alloc.free(stale);

        self.cancelAll();
        self.plan.clearRetainingCapacity();
        self.next_job = 0;
        self.done = 0;
        self.failed = 0;
        self.bytes_done = 0;
        self.bytes_total = 0;
        self.freeStr(&self.err);

        for (stale) |i| {
            const c = cat.find(installed[i].name) orelse continue;
            if (c.zip_url.len == 0) continue;
            self.plan.append(self.alloc, .{
                .name = c.name,
                .url = c.zip_url,
                .bytes = c.zip_bytes,
            }) catch break;
            self.bytes_total += c.zip_bytes;
        }
        if (self.plan.items.len == 0) {
            self.phase = .ready;
            self.changed = true;
            return;
        }

        self.freeStr(&self.dest);
        self.dest = self.alloc.dupe(u8, dest) catch {
            self.setErr("out of memory");
            return;
        };
        makeDir(dest) catch {
            self.setErr("could not create the download directory");
            return;
        };
        self.setStageDest(dest);
        self.startUnpacker();

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
                self.failed += 1;
                continue;
            }
            self.inflight += 1;
        }
        if (self.inflight == 0 and self.next_job >= self.plan.items.len and self.phase == .downloading) {
            self.phase = .ready;
            self.changed = true;
        }
    }

    /// True once every cell in the plan has been written or has failed.
    pub fn finished(self: *const Service) bool {
        return self.phase != .downloading and self.plan.items.len != 0;
    }

    // ---- answers ----------------------------------------------------------

    /// Take one answer from a fetch thread. Does not hold the api lock.
    pub fn respond(self: *Service, req_id: u64, bytes: []const u8, status: c_int) void {
        const too_big = bytes.len > MAX_ZIP_BYTES;
        var answer: Answer = .{
            .id = req_id,
            .bytes = &.{},
            .status = if (too_big) 0 else status,
        };

        // Unpack a cell on the thread that fetched it. adopt runs under the
        // api lock, and this file work there blocked the shell's poll for the
        // length of the download.
        if (self.takeStaged(req_id)) |name| {
            const ok = !too_big and bytes.len != 0 and status >= 200 and status < 300;
            if (ok and self.queueUnpack(req_id, name, bytes, status)) return;
            self.alloc.free(name);
            self.post(answer);
            return;
        }

        // The catalog is parsed once, under the api lock, so its bytes go
        // through the inbox.
        if (!too_big and bytes.len != 0) {
            answer.bytes = self.alloc.dupe(u8, bytes) catch &.{};
        }
        self.post(answer);
    }

    /// Queue one answer for the next adopt.
    fn post(self: *Service, a: Answer) void {
        self.inbox_mu.lock();
        defer self.inbox_mu.unlock();
        self.inbox.append(self.alloc, a) catch {
            if (a.bytes.len != 0) self.alloc.free(a.bytes);
            return;
        };
        self.inbox_len.store(self.inbox.items.len, .release);
    }

    /// Hand a fetched cell to the unpack thread. Owns `name` on success.
    /// Returns false when the queue could not be grown, and the caller then
    /// posts the answer itself.
    fn queueUnpack(self: *Service, id: u64, name: []u8, bytes: []const u8, status: c_int) bool {
        const own = self.alloc.dupe(u8, bytes) catch return false;
        self.unpack_mu.lock();
        defer self.unpack_mu.unlock();
        self.unpack_q.append(self.alloc, .{
            .id = id,
            .name = name,
            .bytes = own,
            .status = status,
        }) catch {
            self.alloc.free(own);
            return false;
        };
        return true;
    }

    /// The unpack thread. Writes one cell at a time and posts an answer for
    /// each.
    fn unpackMain(self: *Service) void {
        // A poll, for the reason src/ct/tiles.zig gives: Zig 0.16 has no
        // std.Thread.Condition outside an Io. The download bounds it.
        while (!self.unpack_stop.load(.acquire)) {
            var wrote = false;
            while (true) {
                var job: Pending = undefined;
                {
                    self.unpack_mu.lock();
                    defer self.unpack_mu.unlock();
                    if (self.unpack_q.items.len == 0) break;
                    job = self.unpack_q.orderedRemove(0);
                }
                defer self.alloc.free(job.name);
                defer self.alloc.free(job.bytes);

                self.stage_mu.lock();
                const dest = self.alloc.dupe(u8, self.stage_dest) catch &.{};
                self.stage_mu.unlock();
                defer if (dest.len != 0) self.alloc.free(dest);

                var a: Answer = .{ .id = job.id, .bytes = &.{}, .status = job.status };
                if (dest.len == 0) {
                    a.write_failed = true;
                } else if (self.write(dest, job.name, job.bytes)) {
                    a.stored = true;
                    a.size = job.bytes.len;
                } else |_| {
                    a.write_failed = true;
                }
                self.post(a);
                wrote = true;
            }
            if (!wrote) lock.sleepMs(1);
        }
    }

    /// Start the unpack thread, once per download.
    fn startUnpacker(self: *Service) void {
        if (self.unpack_thread != null) return;
        self.unpack_stop.store(false, .release);
        self.unpack_thread = std.Thread.spawn(.{}, unpackMain, .{self}) catch null;
    }

    /// Stop it and wait for the cell it is on.
    fn stopUnpacker(self: *Service) void {
        const th = self.unpack_thread orelse return;
        self.unpack_stop.store(true, .release);
        th.join();
        self.unpack_thread = null;
        self.unpack_mu.lock();
        defer self.unpack_mu.unlock();
        for (self.unpack_q.items) |j| {
            self.alloc.free(j.name);
            self.alloc.free(j.bytes);
        }
        self.unpack_q.clearRetainingCapacity();
    }

    /// True while an answer waits to be adopted.
    pub fn pending(self: *const Service) bool {
        return self.inbox_len.load(.acquire) != 0;
    }

    /// Adopt every queued answer. Called from the frame loop under the api
    /// lock.
    pub fn adopt(self: *Service) void {
        if (!self.pending()) {
            // No answer arrived. The api side may still have changed the
            // state since the last frame.
            if (self.changed) self.publish();
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
        self.publish();
    }

    fn tookCatalog(self: *Service, a: Answer) void {
        if (a.status < 200 or a.status >= 300 or a.bytes.len == 0) {
            self.phase = if (self.cat != null) .ready else .idle;
            self.setErr("could not read NOAA's chart catalog");
            return;
        }
        var parsed = noaa.parse(self.alloc, a.bytes) catch {
            self.phase = if (self.cat != null) .ready else .idle;
            self.setErr("NOAA's chart catalog did not parse");
            return;
        };
        if (parsed.cells.len == 0) {
            parsed.deinit();
            self.phase = if (self.cat != null) .ready else .idle;
            self.setErr("NOAA's chart catalog listed no cells");
            return;
        }
        if (self.cat) |*old| old.deinit();
        self.cat = parsed;
        self.checked_at = @divFloor(clock.wallMs(), 1000);
        self.phase = .ready;
        self.changed = true;
    }

    fn tookCell(self: *Service, job: usize, a: Answer) void {
        if (job >= self.plan.items.len) return;
        if (!a.stored) {
            self.failed += 1;
            if (a.write_failed) self.setErr("could not write a downloaded chart");
            self.changed = true;
            return;
        }
        self.done += 1;
        self.bytes_done += a.size;
        self.changed = true;
    }

    /// Unpack one cell's exchange set into the staging directory.
    ///
    /// The zip is written to a scratch file, extracted, and removed. Leaving
    /// the zips in place gave the shell a directory of 829 archives, and it
    /// bakes a folder of cells or a single archive, so it refused the pick.
    /// Extracting turns the directory into an ordinary ENC_ROOT.
    fn write(self: *Service, dest: []const u8, name: []const u8, bytes: []const u8) !void {
        _ = self;
        const io = std.Io.Threaded.global_single_threaded.io();
        var buf: [512]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&buf, "{s}/{s}.zip.part", .{ dest, name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
        defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

        var dir = try std.Io.Dir.cwd().openDir(io, dest, .{});
        defer dir.close(io);
        var f = try std.Io.Dir.cwd().openFile(io, tmp, .{});
        defer f.close(io);
        var reader_buf: [4096]u8 = undefined;
        var fr = f.reader(io, &reader_buf);

        // Entry by entry. std.zip.extract stops at the first file already on
        // disk, every cell's exchange set holds its own ENC_ROOT/CATALOG.031,
        // and they all unpack into the one directory. From the second cell on
        // that entry collided and the rest of the archive went unread, so 828
        // of 829 cells counted as failures.
        var iter = try std.zip.Iterator.init(&fr);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (try iter.next()) |entry| {
            entry.extract(&fr, .{ .allow_backslashes = true }, &name_buf, dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
    }

    // ---- the snapshot -----------------------------------------------------

    /// Copy the state where a shell can read it without the api lock. Called
    /// from the api side, the only side that changes it.
    pub fn publish(self: *Service) void {
        const s = self.snapshot();
        self.pub_mu.lock();
        defer self.pub_mu.unlock();
        self.pub_state = s;
    }

    /// The last published state. Safe from any thread.
    pub fn published(self: *Service) State {
        self.pub_mu.lock();
        defer self.pub_mu.unlock();
        return self.pub_state;
    }

    pub fn snapshot(self: *Service) State {
        var s = State{
            .phase = @intFromEnum(self.phase),
            .have_catalog = if (self.cat != null) 1 else 0,
            .checked_at = self.checked_at,
            .total = @intCast(self.plan.items.len),
            .done = self.done,
            .failed = self.failed,
            .bytes_total = self.bytes_total,
            .bytes_done = self.bytes_done,
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

test "a service with no fetcher reports why and stays idle" {
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
    s.start(&.{5}, "/tmp/lookout-noaa-test-should-not-exist");
    try testing.expectEqual(Phase.idle, s.phase);
    try testing.expect(s.err.len != 0);
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
