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
const Lock = @import("lock.zig").Lock;
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

    /// Answers from the shell's fetch threads, guarded by inbox_mu alone.
    inbox_mu: Lock = .{},
    inbox: std.ArrayList(Answer) = .empty,
    inbox_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(alloc: std.mem.Allocator) Service {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Service) void {
        self.cancelAll();
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
    fn issue(self: *Service, url: []const u8, kind: Kind, job: usize) u64 {
        const get = self.get orelse return 0;
        const z = self.alloc.dupeZ(u8, url) catch return 0;
        defer self.alloc.free(z);
        const id = self.next_req | id_mark;
        self.next_req += 1;
        self.reqs.append(self.alloc, .{ .id = id, .kind = kind, .job = job }) catch return 0;
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
        return noaa.cost(cat, picked);
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
            self.plan.append(self.alloc, .{
                .name = c.name,
                .url = c.zip_url,
                .bytes = c.zip_bytes,
            }) catch break;
            self.bytes_total += c.zip_bytes;
        }
        if (self.plan.items.len == 0) {
            self.setErr("those regions name no cells");
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
        const keep: []u8 = if (bytes.len == 0 or too_big)
            &.{}
        else
            self.alloc.dupe(u8, bytes) catch &.{};
        self.inbox_mu.lock();
        defer self.inbox_mu.unlock();
        self.inbox.append(self.alloc, .{
            .id = req_id,
            .bytes = keep,
            .status = if (too_big) 0 else status,
        }) catch {
            if (keep.len != 0) self.alloc.free(keep);
            return;
        };
        self.inbox_len.store(self.inbox.items.len, .release);
    }

    /// True while an answer waits to be adopted.
    pub fn pending(self: *const Service) bool {
        return self.inbox_len.load(.acquire) != 0;
    }

    /// Adopt every queued answer. Called from the frame loop under the api
    /// lock.
    pub fn adopt(self: *Service) void {
        if (!self.pending()) return;
        var taken: std.ArrayList(Answer) = .empty;
        {
            self.inbox_mu.lock();
            defer self.inbox_mu.unlock();
            taken = self.inbox;
            self.inbox = .empty;
            self.inbox_len.store(0, .release);
        }
        defer taken.deinit(self.alloc);

        for (taken.items) |a| {
            defer if (a.bytes.len != 0) self.alloc.free(a.bytes);
            const req = self.retire(a.id) orelse continue;
            switch (req.kind) {
                .catalog => self.tookCatalog(a),
                .cell => {
                    self.inflight -= 1;
                    self.tookCell(req.job, a);
                },
            }
        }
        if (self.phase == .downloading) self.pump();
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
        const cell = self.plan.items[job];
        if (a.status < 200 or a.status >= 300 or a.bytes.len == 0) {
            self.failed += 1;
            self.changed = true;
            return;
        }
        self.write(cell.name, a.bytes) catch {
            self.failed += 1;
            self.setErr("could not write a downloaded chart");
            return;
        };
        self.done += 1;
        self.bytes_done += a.bytes.len;
        self.changed = true;
    }

    /// Unpack one cell's exchange set into the staging directory.
    ///
    /// The zip is written to a scratch file, extracted, and removed. Leaving
    /// the zips in place gave the shell a directory of 829 archives, and it
    /// bakes a folder of cells or a single archive, so it refused the pick.
    /// Extracting turns the directory into an ordinary ENC_ROOT.
    fn write(self: *Service, name: []const u8, bytes: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var buf: [512]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&buf, "{s}/{s}.zip.part", .{ self.dest, name });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
        defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

        var dir = try std.Io.Dir.cwd().openDir(io, self.dest, .{});
        defer dir.close(io);
        var f = try std.Io.Dir.cwd().openFile(io, tmp, .{});
        defer f.close(io);
        var reader_buf: [4096]u8 = undefined;
        var fr = f.reader(io, &reader_buf);
        try std.zip.extract(dir, &fr, .{ .allow_backslashes = true });
    }

    // ---- the snapshot -----------------------------------------------------

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
