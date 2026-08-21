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
//! read-only and the pmtiles readers lock their own lazy directory state. So a
//! worker takes the caller's engine lock SHARED, and the pool composes in
//! parallel. What the lock still excludes is the handful of operations that
//! replace what is being read — opening charts, swapping and closing a
//! composition, trimming the engine's caches, a pick — and those take it
//! exclusively.

const std = @import("std");
const cc = @import("../c.zig").c;
const ct = @import("charttable");
const Lock = @import("../lock.zig").Lock;
const RwLock = @import("../lock.zig").RwLock;
const sleepMs = @import("../lock.zig").sleepMs;

const Request = ct.provider.Request;
const clock = @import("../clock.zig");

/// $LOOKOUT_TILE_PROF=<path>: what the compose pool actually achieved.
///
/// Wall time against summed compose time is the whole question for the pool:
/// equal means the workers ran one at a time, and a ratio near the worker count
/// means they ran together.
const Stats = struct {
    mu: Lock = .{},
    on: bool = false,
    checked: bool = false,
    path: []const u8 = "",
    n: usize = 0,
    compose_us: i64 = 0,
    wait_us: i64 = 0,
    first_us: i64 = 0,
    last_us: i64 = 0,

    fn add(self: *Stats, wait_us: i64, compose_us: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.checked) {
            self.checked = true;
            if (std.c.getenv("LOOKOUT_TILE_PROF")) |p| {
                self.path = std.mem.span(p);
                self.on = true;
            }
        }
        if (!self.on) return;
        const now = clock.ticksUs();
        if (self.n == 0) self.first_us = now - compose_us - wait_us;
        self.n += 1;
        self.compose_us += compose_us;
        self.wait_us += wait_us;
        self.last_us = now;
        if (self.n % 16 != 0) return;
        const wall = self.last_us - self.first_us;
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "tiles {d}\nwall_ms {d}\ncompose_ms {d}\nlockwait_ms {d}\nparallelism {d:.2}\n",
            .{ self.n, @divTrunc(wall, 1000), @divTrunc(self.compose_us, 1000), @divTrunc(self.wait_us, 1000), if (wall > 0) @as(f64, @floatFromInt(self.compose_us)) / @as(f64, @floatFromInt(wall)) else 0 },
        ) catch return;
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path, .data = line }) catch {};
    }
};

var stats: Stats = .{};

/// How many compose workers. One per view level was the difference, on the
/// maplibre branch, between a zoom-out filling in over several seconds and
/// filling in as fast as the tiles decode.
const MAX_WORKERS = 4;

/// How long a worker polls an empty queue before standing down. Two seconds
/// outlasts any pan's settling; past it the boat is at anchor and the pool
/// costs nothing.
pub const IDLE_EXIT_MS = 2_000;

pub const Tiles = struct {
    alloc: std.mem.Allocator,
    provider: ct.provider.Provider,

    /// The compositor to serve from, and the lock that guards every engine
    /// entry. Both are owned by the caller and may be replaced while the
    /// workers run (a library recompose), which is why they are read under
    /// `mu` on every job rather than captured once.
    compose: ?*cc.tile57_compose = null,
    engine_mu: *RwLock,

    mu: Lock = .{},
    queue: std.ArrayListUnmanaged(Request) = .empty,
    /// Jobs a worker has taken but not answered yet. Queue length alone would
    /// read empty in the window where the last tile is still composing.
    in_flight: usize = 0,
    /// Workers standing, detached. They hand the badge in after IDLE_EXIT_MS
    /// with nothing to do and the next ask spawns them again, so an idle
    /// chart holds ZERO ticking threads — the invariant is "no poll that
    /// could be an event", and between interactions there is no event coming
    /// that pump() does not know about first.
    alive: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Asks drained from charttable, reused so a frame allocates nothing new.
    asks: std.ArrayListUnmanaged(Request) = .empty,

    pub fn init(alloc: std.mem.Allocator, engine_mu: *RwLock) Tiles {
        return .{
            .alloc = alloc,
            .provider = ct.provider.Provider.init(alloc),
            .engine_mu = engine_mu,
        };
    }

    /// Bring the pool up to strength. Called again freely: workers stand
    /// down when idle, and every path that queues work calls this behind it.
    /// Serialized by the api lock like every other mutator here.
    pub fn start(self: *Tiles) void {
        const cpus = std.Thread.getCpuCount() catch 1;
        const want = @min(@max(cpus / 2, 1), MAX_WORKERS);
        while (self.alive.load(.acquire) < want) {
            _ = self.alive.fetchAdd(1, .acq_rel);
            const th = std.Thread.spawn(.{}, worker, .{self}) catch {
                _ = self.alive.fetchSub(1, .acq_rel);
                break;
            };
            th.detach();
        }
    }

    pub fn deinit(self: *Tiles) void {
        self.stopping.store(true, .release);
        // Detached, so joined by handshake: each worker's last act is the
        // decrement, and they wake within a backoff step to see `stopping`.
        while (self.alive.load(.acquire) != 0) sleepMs(1);
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
        // The pool may have stood down since the last ask.
        self.start();
    }

    /// True while any tile is queued or being composed. The caller waits on
    /// this before closing a composition the workers may still be reading.
    pub fn busy(self: *Tiles) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.queue.items.len != 0 or self.in_flight != 0;
    }

    /// Polled rather than waited on a condition variable — Zig 0.16 has no
    /// std.Thread.Condition outside an Io — but the poll is BOUNDED: after
    /// IDLE_EXIT_MS with nothing to do the worker stands down, and the next
    /// pump spawns the pool again. 1 ms while tiles are moving keeps the
    /// fill-in prompt; an idle chart holds no threads at all.
    fn worker(self: *Tiles) void {
        var idle_ms: u32 = 1;
        var idle_total: u32 = 0;
        while (!self.stopping.load(.acquire)) {
            const job = self.take() orelse {
                if (idle_total >= IDLE_EXIT_MS) {
                    // The LAST one out re-checks the queue: an ask that landed
                    // after its final take would otherwise sit unserved, and a
                    // parked tile that is never answered is a hole in the
                    // chart forever.
                    if (self.alive.fetchSub(1, .acq_rel) == 1 and self.queued()) {
                        _ = self.alive.fetchAdd(1, .acq_rel);
                        idle_ms = 1;
                        idle_total = 0;
                        continue;
                    }
                    return;
                }
                sleepMs(idle_ms);
                idle_total += idle_ms;
                if (idle_ms < 32) idle_ms *= 2;
                continue;
            };
            idle_ms = 1;
            idle_total = 0;
            self.serve(job);
        }
        _ = self.alive.fetchSub(1, .acq_rel);
    }

    fn queued(self: *Tiles) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.queue.items.len != 0;
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
        // SHARED: composing only reads the compositor, so every worker composes
        // at once. Held exclusively, the four workers served a view's tiles one
        // after another, which is what a zoom waited on.
        const t0 = clock.ticksUs();
        self.engine_mu.lockShared();
        const t1 = clock.ticksUs();
        const st = cc.tile57_compose_tile(compose, job.z, job.x, job.y, &bytes, &len, &owned, &err);
        const t2 = clock.ticksUs();
        self.engine_mu.unlockShared();
        stats.add(t1 - t0, t2 - t1);

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
    var engine_mu: RwLock = .{};
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
    var engine_mu: RwLock = .{};
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
