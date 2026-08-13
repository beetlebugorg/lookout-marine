//! Serves composed chart tiles to charttable out of tile57.
//!
//! WHY THIS EXISTS. charttable can read a .pmtiles archive itself, and for a
//! single chart it does — no code here is involved. A chart SET is different:
//! lookout opens a folder of per-cell archives and composes them at runtime
//! through `tile57_compose`, which resolves band handoff and ownership per
//! tile. There is no merged archive to point at, so those tiles arrive
//! through charttable's host-provider door instead.
//!
//! THREADING. charttable raises its asks on the thread that drives the map
//! and parks the tile until someone answers. Composing is far too slow to do
//! inline — it reads archives and stitches faces — so `pump` only takes the
//! asks and queues them; a small pool of workers composes off-thread and
//! calls `respond`, which is safe from any thread. A tile that is merely SLOW
//! is never cached as missing (charttable's parking rule), so a late answer
//! still lands.
//!
//! The compose path is safe to run concurrently: the ownership partition is
//! read-only and the pmtiles readers lock their own lazy directory state. It
//! still runs under the caller's engine lock, because everything else that
//! touches the compositor (a pick, a rebuild, a close) has to be excluded.

const std = @import("std");
const cc = @import("../c.zig").c;
const ct = @import("charttable");
const Lock = @import("../lock.zig").Lock;
const sleepMs = @import("../lock.zig").sleepMs;

const Request = ct.provider.Request;

/// How many compose workers. One per view level was the difference, on the
/// maplibre branch, between a zoom-out filling in over several seconds and
/// filling in as fast as the tiles decode.
const MAX_WORKERS = 4;

pub const Tiles = struct {
    alloc: std.mem.Allocator,
    provider: ct.provider.Provider,

    /// The compositor to serve from, and the lock that guards every engine
    /// entry. Both are owned by the caller and may be replaced while the
    /// workers run (a library recompose), which is why they are read under
    /// `mu` on every job rather than captured once.
    compose: ?*cc.tile57_compose = null,
    engine_mu: *Lock,

    mu: Lock = .{},
    queue: std.ArrayListUnmanaged(Request) = .empty,
    /// Jobs a worker has taken but not answered yet. Queue length alone would
    /// read empty in the window where the last tile is still composing.
    in_flight: usize = 0,
    threads: [MAX_WORKERS]?std.Thread = .{null} ** MAX_WORKERS,
    n_threads: usize = 0,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Asks drained from charttable, reused so a frame allocates nothing new.
    asks: std.ArrayListUnmanaged(Request) = .empty,

    pub fn init(alloc: std.mem.Allocator, engine_mu: *Lock) Tiles {
        return .{
            .alloc = alloc,
            .provider = ct.provider.Provider.init(alloc),
            .engine_mu = engine_mu,
        };
    }

    /// Start the workers. Idempotent.
    pub fn start(self: *Tiles) void {
        if (self.n_threads != 0) return;
        const cpus = std.Thread.getCpuCount() catch 1;
        const want = @min(@max(cpus / 2, 1), MAX_WORKERS);
        while (self.n_threads < want) : (self.n_threads += 1) {
            self.threads[self.n_threads] = std.Thread.spawn(.{}, worker, .{self}) catch break;
        }
    }

    pub fn deinit(self: *Tiles) void {
        self.stopping.store(true, .release);
        for (self.threads[0..self.n_threads]) |t| if (t) |th| th.join();
        self.n_threads = 0;
        self.queue.deinit(self.alloc);
        self.asks.deinit(self.alloc);
        self.provider.deinit();
    }

    /// Point the workers at a different composition. The old one may still be
    /// in a worker's hands, so the caller closes it only after this returns
    /// and the workers have drained (see drain).
    pub fn setCompose(self: *Tiles, c: ?*cc.tile57_compose) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.compose = c;
        // Whatever is queued was asked of the old composition. Those tiles
        // are still wanted — charttable will ask again — but answering them
        // from the new one is right, so the queue stands.
    }

    /// Take charttable's outstanding asks and hand them to the workers. Call
    /// once per frame, from whichever thread drives the map.
    pub fn pump(self: *Tiles) void {
        self.asks.clearRetainingCapacity();
        self.provider.drain(&self.asks, self.alloc);
        if (self.asks.items.len == 0) return;
        self.mu.lock();
        self.queue.appendSlice(self.alloc, self.asks.items) catch {};
        self.mu.unlock();
    }

    /// True while any tile is queued or being composed. The caller waits on
    /// this before closing a composition the workers may still be reading.
    pub fn busy(self: *Tiles) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.queue.items.len != 0 or self.in_flight != 0;
    }

    /// Polled rather than waited on a condition variable, and backed off the
    /// way raster.zig's pool is: Zig 0.16 has no std.Thread.Condition outside
    /// an Io. 1 ms while tiles are moving keeps the fill-in prompt; 32 ms once
    /// the view settles means an idle chart is not paying for a pool.
    fn worker(self: *Tiles) void {
        var idle_ms: u32 = 1;
        while (!self.stopping.load(.acquire)) {
            const job = self.take() orelse {
                sleepMs(idle_ms);
                if (idle_ms < 32) idle_ms *= 2;
                continue;
            };
            idle_ms = 1;
            self.serve(job);
        }
    }

    fn take(self: *Tiles) ?Request {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.queue.items.len == 0) return null;
        // Newest first: a pan leaves stale asks behind it, and the tiles the
        // mariner is looking at now are the ones at the end of the queue.
        const job = self.queue.pop() orelse return null;
        self.in_flight += 1;
        return job;
    }

    fn serve(self: *Tiles, job: Request) void {
        defer {
            self.mu.lock();
            self.in_flight -= 1;
            self.mu.unlock();
        }
        self.mu.lock();
        const compose = self.compose;
        self.mu.unlock();
        if (compose == null) {
            self.provider.respond(job.id, "", .failed);
            return;
        }

        var bytes: [*c]u8 = null;
        var len: usize = 0;
        var owned: bool = false;
        var err: cc.tile57_error = undefined;
        self.engine_mu.lock();
        const st = cc.tile57_compose_tile(compose, job.z, job.x, job.y, &bytes, &len, &owned, &err);
        self.engine_mu.unlock();

        if (st != cc.TILE57_OK) {
            self.provider.respond(job.id, "", .failed);
            return;
        }
        defer if (bytes != null) cc.tile57_free(bytes);
        if (bytes == null or len == 0) {
            // No bytes. `owned` says which empty this is: no chart owns the
            // ground (a true empty, safe to remember) against a chart that
            // owns it but produced nothing, which is transient while its bake
            // finishes. Remembering the second one as empty leaves a hole
            // that never fills, so it is reported as a failure — cacheable
            // too, but the tile is asked for again after an eviction.
            self.provider.respond(job.id, "", if (owned) .failed else .empty);
            return;
        }
        self.provider.respond(job.id, bytes[0..len], .ok);
    }
};

// ---- tests -----------------------------------------------------------------

test "tiles: an ask with no composition is answered, not dropped" {
    // A parked tile that is never answered is a hole in the chart forever, so
    // even the degenerate case has to produce an answer.
    var engine_mu: Lock = .{};
    var t = Tiles.init(std.testing.allocator, &engine_mu);
    defer t.deinit();

    const src = t.provider.source();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const id = ct.coord.TileId{ .z = 5, .x = 9, .y = 12 };
    try std.testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .not_ready);

    t.pump();
    const job = t.take() orelse return error.NothingQueued;
    t.serve(job);
    try std.testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .failed);
}

test "tiles: pump moves every ask onto the queue" {
    var engine_mu: Lock = .{};
    var t = Tiles.init(std.testing.allocator, &engine_mu);
    defer t.deinit();

    const src = t.provider.source();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..3) |i| {
        const id = ct.coord.TileId{ .z = 6, .x = @intCast(i), .y = 1 };
        try std.testing.expect(src.fetch(src.ptr, arena.allocator(), id) == .not_ready);
    }
    t.pump();
    try std.testing.expectEqual(@as(usize, 3), t.queue.items.len);
    try std.testing.expect(t.busy());
}
