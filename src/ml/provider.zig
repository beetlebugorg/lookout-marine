//! Serves `lookout://` resources to MapLibre out of tile57.
//!
//! WHY THIS EXISTS. MapLibre points a source at ONE url. Lookout does not have
//! one archive: it opens a folder of per-chart `.pmtiles` and composes them at
//! runtime through `tile57_compose`, resolving band handoff and ownership per
//! tile. There is no merged archive to point at.
//!
//! THE SCHEME
//!
//!   lookout://tile/{z}/{x}/{y}          composed vector tile (MLT or MVT)
//!   lookout://sprite.json               MapLibre sprite index, current scheme
//!   lookout://sprite.png                 the sheet the index addresses
//!   lookout://sprite@2x.json|png        the same at a second density
//!   lookout://glyphs/{stack}/{a}-{b}.pbf  SDF glyph range for a fontstack
//!
//! THREADING. MapLibre calls `handle` on a worker or network thread and states
//! the callback must return promptly and must not re-enter the map or runtime.
//! A composed tile is far too slow to serve inline — it reads archives and
//! stitches faces — so the callback only takes the request handle and queues it.
//! A small pool of workers completes requests off-thread. The COMPOSE path is
//! safe to run concurrently: the ownership partition is read-only and the
//! pmtiles readers lock their own lazy directory state (tile57's GPU compose
//! already builds a view's tiles on several threads through the same calls).
//! One worker per view level was the difference between a zoom-out filling in
//! over several seconds and filling in as fast as the tiles decode. A single
//! CHART handle is NOT internally synchronized, so that path serializes on
//! chart_mu.
//!
//! CANCELLATION. MapLibre cancels tiles constantly while a view moves. The
//! worker asks `handle.cancelled()` before doing the work, so a queue that has
//! fallen behind a pan discards instead of composing tiles nobody wants.

const std = @import("std");
const cc = @import("../c.zig").c;
const t57 = @import("tile57");
const maplibre = @import("maplibre_native_ffi");
const mlog = @import("host.zig").mlog;
const Lock = @import("../lock.zig").Lock;
const sleepMs = @import("../lock.zig").sleepMs;
const setThreadQos = @import("../lock.zig").setThreadQos;

const glyphpbf = t57.sprite.glyphpbf;

const nowMs = @import("../lock.zig").nowMs;
const memoryPressureRelief = @import("../lock.zig").memoryPressureRelief;

/// Compose workers. Four keeps a zoom-out's tile burst wide without owning
/// the machine; the compose path measured comfortably parallel at this width.
const n_workers = 4;

/// Served-tile cache budget. ~32 MB holds a few hundred tiles — several whole
/// view levels — so a zoom out and back re-serves instead of re-composing
/// through the partition (the booleans there dominated the zoom profile).
const tile_cache_budget: usize = 32 << 20;

const CacheEntry = struct { bytes: []u8, stamp: u32 };

/// One tile's worth of served bytes and who owns them (the engine's buffer,
/// the cache's copy, or a cached empty).
const TileBytes = struct { bytes: []const u8, from_cache: bool };

fn tileKey(z: u8, x: u32, y: u32) u64 {
    return (@as(u64, z) << 44) | (@as(u64, x) << 22) | @as(u64, y);
}

pub const scheme = "lookout://";

/// Speculative candidates per view hint: 6 zoom-out parents, the 8-tile ring
/// at the view zoom, and the ring one level up (the first zoom-out step).
const spec_candidates = 6 + 8 + 8;
const spec_done: u32 = 0xffff_ffff;

/// What a parsed `lookout://` url asks for.
const Ask = union(enum) {
    tile: struct { z: u8, x: u32, y: u32 },
    sprite_json: struct { pixel_ratio: u8, scheme: cc.tile57_scheme },
    sprite_png: struct { pixel_ratio: u8, scheme: cc.tile57_scheme },
    glyphs: struct { stack: []const u8, start: u21 },
};

/// A request the callback accepted and the worker still owes a response for.
const Job = struct {
    handle: maplibre.ResourceRequestHandle,
    ask: Ask,
    /// Owns `ask.glyphs.stack` when the ask carries one; freed with the job.
    stack_buf: ?[]u8 = null,
};

pub const Provider = struct {
    alloc: std.mem.Allocator,

    /// The compositor over the open library. Borrowed: root.zig owns it and
    /// must not close it while this provider runs. Null while a compose is
    /// being rebuilt, which serves tiles as 404 rather than blocking.
    compose: ?*cc.tile57_compose = null,
    /// Single chart shortcut: when the library holds exactly one chart there is
    /// no compositor and tiles come straight off the archive.
    chart: ?*cc.tile57_chart = null,
    /// Guards `compose`/`chart` against a swap while the worker reads them.
    src_lock: Lock = .{},

    /// Baked once per (scheme, density) and handed out for the process life.
    sprite_cache: std.ArrayList(SpriteEntry) = .empty,
    sprite_lock: Lock = .{},
    scheme_now: cc.tile57_scheme = cc.TILE57_SCHEME_DAY,
    catalog_dir: ?[:0]const u8 = null,

    /// Glyph ranges are small and re-requested constantly; cache them forever.
    glyph_cache: std.StringHashMapUnmanaged([]u8) = .empty,
    glyph_lock: Lock = .{},

    /// Served-tile LRU (see tile_cache_budget). Cleared whenever the source
    /// changes; empty results are cached too — open ocean classifies as
    /// expensively as a busy harbour and answers nothing either way.
    tile_cache: std.AutoHashMapUnmanaged(u64, CacheEntry) = .empty,
    cache_lock: Lock = .{},
    cache_bytes: usize = 0,
    cache_tick: u32 = 0,

    queue: std.ArrayList(Job) = .empty,
    queue_lock: Lock = .{},
    workers: [n_workers]?std.Thread = @splat(null),
    /// Serializes single-chart tile reads (tile57_chart_tile): a lone chart
    /// handle is not internally synchronized. The compositor needs no lock.
    chart_mu: Lock = .{},
    /// Serializes sprite BAKES. tile57_bake_sprite_mln is not safe to run
    /// twice at once (shared catalogue registries + the C ABI's process-wide
    /// io), and the palette warm can otherwise overlap a user's scheme flip —
    /// the corrupted sheets came out black, and a poisoned bake could even be
    /// persisted to the disk cache.
    bake_mu: Lock = .{},
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by serve(); the worker that drains the queue returns the compose
    /// transients to the OS (rate-limited below). A zoom-out's fill path
    /// allocates ~100 MB per fat tile and libmalloc keeps the freed pages
    /// cached — the footprint read GBs over the live heap mid-session.
    did_work: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_relief_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// The view's centre tile (packed via tileKey with z in the top bits) as
    /// last hinted by the host, and the speculative work counter it re-arms.
    /// Idle workers walk a fixed candidate list around the hint — the
    /// zoom-out parents first, then the pan ring — so a gesture usually finds
    /// its tiles already composed.
    hint_key: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    spec_idx: std.atomic.Value(u32) = std.atomic.Value(u32).init(spec_done),
    /// One background warm of the other palettes per process (see warmSprites).
    sprite_warm_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    warm_thread: ?std.Thread = null,
    /// Directory for baked-sprite persistence (root.zig atlasCacheDir), keyed
    /// by engine version. A sheet bake is seconds of SVG rasterization; doing
    /// it once per install instead of once per launch is the difference
    /// between the chart appearing immediately and the startup loader
    /// lingering. Owned.
    disk_cache_dir: ?[]u8 = null,
    /// Bumped every time a request is answered. The host watches it to know
    /// that MapLibre has new material and another frame is worth drawing —
    /// `isFullyLoaded` goes true before the arriving tiles are placed, so on
    /// its own it parks the render loop and the chart never fills in.
    served: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const SpriteEntry = struct {
        pixel_ratio: u8,
        scheme: cc.tile57_scheme,
        json: []u8,
        png: []u8,
    };

    pub fn init(alloc: std.mem.Allocator) Provider {
        return .{ .alloc = alloc };
    }

    pub fn start(self: *Provider) !void {
        if (self.workers[0] != null) return;
        self.stopping.store(false, .release);
        for (&self.workers, 0..) |*w, i| w.* = std.Thread.spawn(.{}, run, .{ self, i }) catch null;
    }

    pub fn deinit(self: *Provider) void {
        self.stopping.store(true, .release);
        for (&self.workers) |*w| {
            if (w.*) |t| t.join();
            w.* = null;
        }
        // The palette warm may still be baking; it must not outlive the
        // caches it inserts into.
        if (self.warm_thread) |t| t.join();
        self.warm_thread = null;

        // Anything still queued was never completed. Release each handle so
        // MapLibre stops waiting on it.
        for (self.queue.items) |*job| {
            job.handle.release();
            if (job.stack_buf) |b| self.alloc.free(b);
        }
        self.queue.deinit(self.alloc);

        for (self.sprite_cache.items) |e| {
            self.alloc.free(e.json);
            self.alloc.free(e.png);
        }
        self.sprite_cache.deinit(self.alloc);

        var it = self.glyph_cache.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.key_ptr.*);
            self.alloc.free(kv.value_ptr.*);
        }
        self.glyph_cache.deinit(self.alloc);

        self.clearTileCache();
        self.tile_cache.deinit(self.alloc);

        if (self.disk_cache_dir) |d| self.alloc.free(d);
        if (self.catalog_dir) |d| self.alloc.free(d);
    }

    /// The host's per-frame view hint. Cheap: a packed compare and, when the
    /// centre tile changed, a counter re-arm.
    pub fn hintView(self: *Provider, z: u8, x: u32, y: u32) void {
        const key = tileKey(z, x, y);
        if (self.hint_key.swap(key, .acq_rel) != key) {
            self.spec_idx.store(0, .release);
        }
    }

    /// The idx-th speculative tile around the hint, or null past the list.
    fn specCandidate(key: u64, idx: u32) ?struct { z: u8, x: u32, y: u32 } {
        const z: u8 = @intCast(key >> 44);
        const x: u32 = @intCast((key >> 22) & 0x3f_ffff);
        const y: u32 = @intCast(key & 0x3f_ffff);
        if (idx < 6) { // parents: the zoom-out path pays compose for coarse tiles
            const d: u5 = @intCast(idx + 1);
            if (z < d + 1) return null;
            return .{ .z = z - d, .x = x >> d, .y = y >> d };
        }
        const ring = [8][2]i2{ .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };
        var rz = z;
        var rx = x;
        var ry = y;
        var ri = idx - 6;
        if (ri >= 8) { // ring one level up: the first zoom-out step's neighbours
            if (z < 1) return null;
            rz = z - 1;
            rx = x >> 1;
            ry = y >> 1;
            ri -= 8;
        }
        if (ri >= 8) return null;
        const n: i64 = @as(i64, 1) << @intCast(rz);
        const cx = @as(i64, rx) + ring[ri][0];
        const cy = @as(i64, ry) + ring[ri][1];
        if (cx < 0 or cy < 0 or cx >= n or cy >= n) return null;
        return .{ .z = rz, .x = @intCast(cx), .y = @intCast(cy) };
    }

    fn isCached(self: *Provider, key: u64) bool {
        self.cache_lock.lock();
        defer self.cache_lock.unlock();
        return self.tile_cache.contains(key);
    }

    /// One unit of speculative work, run only when the queue is empty. Returns
    /// false when the candidate list is exhausted.
    fn speculate(self: *Provider) bool {
        if (self.spec_idx.load(.acquire) >= spec_candidates) return false;
        const idx = self.spec_idx.fetchAdd(1, .acq_rel);
        if (idx >= spec_candidates) return false;
        const key = self.hint_key.load(.acquire);
        if (key == 0) return false;
        const c = specCandidate(key, idx) orelse return true;
        if (self.isCached(tileKey(c.z, c.x, c.y))) return true;
        const r = self.composeTile(c.z, c.x, c.y) orelse return true; // remember() cached it
        if (r.bytes.len != 0) {
            if (r.from_cache) self.alloc.free(@constCast(r.bytes)) else cc.tile57_free(@constCast(r.bytes.ptr));
        }
        return true;
    }

    /// Adopt the on-disk sprite cache directory (called once at open).
    pub fn setDiskCacheDir(self: *Provider, dir: ?[]u8) void {
        if (self.disk_cache_dir) |d| self.alloc.free(d);
        self.disk_cache_dir = dir;
    }

    fn diskSpritePath(self: *Provider, buf: []u8, scheme_ask: cc.tile57_scheme, ratio: u8, ext: []const u8) ?[:0]const u8 {
        const dir = self.disk_cache_dir orelse return null;
        const name = switch (scheme_ask) {
            cc.TILE57_SCHEME_DUSK => "dusk",
            cc.TILE57_SCHEME_NIGHT => "night",
            else => "day",
        };
        // "mln3": generation 2 was baked at the pre-drawn-scale resolution;
        // the rename orphans it (and gen 1's possibly poisoned sheets).
        return std.fmt.bufPrintZ(buf, "{s}/sprite-mln3-{s}@{d}x.{s}", .{ dir, name, ratio, ext }) catch null;
    }

    fn readDiskFile(self: *Provider, path: [:0]const u8) ?[]u8 {
        const f = std.c.fopen(path.ptr, "r") orelse return null;
        defer _ = std.c.fclose(f);
        var out = std.ArrayList(u8).empty;
        var chunk: [65536]u8 = undefined;
        while (true) {
            const n = std.c.fread(&chunk, 1, chunk.len, f);
            if (n == 0) break;
            out.appendSlice(self.alloc, chunk[0..n]) catch {
                out.deinit(self.alloc);
                return null;
            };
        }
        if (out.items.len == 0) {
            out.deinit(self.alloc);
            return null;
        }
        return out.toOwnedSlice(self.alloc) catch null;
    }

    fn writeDiskFile(path: [:0]const u8, bytes: []const u8) void {
        const f = std.c.fopen(path.ptr, "w") orelse return;
        defer _ = std.c.fclose(f);
        _ = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
    }

    /// Point the provider at the open library. Called from the api thread with
    /// the compositor root.zig just built; the worker picks it up on its next
    /// job. Passing null (mid-rebuild) makes tiles 404 until the next set.
    pub fn setSource(self: *Provider, compose: ?*cc.tile57_compose, chart: ?*cc.tile57_chart) void {
        self.src_lock.lock();
        self.compose = compose;
        self.chart = chart;
        self.src_lock.unlock();
        self.clearTileCache();
    }

    fn clearTileCache(self: *Provider) void {
        self.cache_lock.lock();
        defer self.cache_lock.unlock();
        var it = self.tile_cache.valueIterator();
        while (it.next()) |e| if (e.bytes.len != 0) self.alloc.free(e.bytes);
        self.tile_cache.clearRetainingCapacity();
        self.cache_bytes = 0;
    }

    pub fn setScheme(self: *Provider, s: cc.tile57_scheme) void {
        self.sprite_lock.lock();
        defer self.sprite_lock.unlock();
        self.scheme_now = s;
    }

    pub fn setCatalogDir(self: *Provider, dir: ?[]const u8) !void {
        self.sprite_lock.lock();
        defer self.sprite_lock.unlock();
        if (self.catalog_dir) |d| self.alloc.free(d);
        self.catalog_dir = if (dir) |d| try self.alloc.dupeZ(u8, d) else null;
    }

    // ---- the MapLibre-facing callback ------------------------------------

    /// `maplibre.ResourceProvider.handler`. Runs on a MapLibre thread: parse,
    /// queue, return. No tile57 call happens here.
    pub fn handler(
        ctx: ?*anyopaque,
        request: maplibre.ResourceRequest,
        handle: ?maplibre.ResourceRequestHandle,
    ) maplibre.ResourceProviderDecision {
        const self: *Provider = @ptrCast(@alignCast(ctx orelse return .pass_through));
        const h = handle orelse return .pass_through;

        // Everything that is not ours goes to MapLibre's own file source, so a
        // style that also names an http basemap still works.
        if (!std.mem.startsWith(u8, request.resolved_url, scheme)) {
            return .pass_through;
        }

        const ask = parse(request.resolved_url[scheme.len..]) orelse {
            mlog("prov: unparsed url {s}\n", .{request.resolved_url});
            completeEmpty(h);
            return .handle;
        };
        if (ask == .tile) mlog("prov: req {d}/{d}/{d}\n", .{ ask.tile.z, ask.tile.x, ask.tile.y });

        var job = Job{ .handle = h, .ask = ask };
        if (ask == .glyphs) {
            // The url is borrowed for the callback only; the worker needs its
            // own copy of the fontstack name.
            const buf = percentDecode(self.alloc, ask.glyphs.stack) catch {
                completeEmpty(h);
                return .handle;
            };
            job.stack_buf = buf;
            job.ask = .{ .glyphs = .{ .stack = buf, .start = ask.glyphs.start } };
        }

        self.queue_lock.lock();
        defer self.queue_lock.unlock();
        self.queue.append(self.alloc, job) catch {
            if (job.stack_buf) |b| self.alloc.free(b);
            completeEmpty(h);
            return .handle;
        };
        return .handle;
    }

    fn completeEmpty(h: maplibre.ResourceRequestHandle) void {
        h.complete(.{ .status = .no_content }) catch {};
        h.release();
    }

    fn hasSource(self: *Provider) bool {
        self.src_lock.lock();
        defer self.src_lock.unlock();
        return self.compose != null or self.chart != null;
    }

    // ---- the worker ------------------------------------------------------

    fn run(self: *Provider, worker_id: usize) void {
        setThreadQos(.user_initiated);
        mlog("prov: worker up\n", .{});
        while (true) {
            self.queue_lock.lock();
            if (self.queue.items.len == 0) {
                self.queue_lock.unlock();
                if (self.stopping.load(.acquire)) return;
                // The burst is served: hand the compose transients back to
                // the OS, at most once every couple of seconds across the
                // pool. Waiting for full idle let the footprint climb for as
                // long as the mariner kept the chart moving.
                if (self.did_work.swap(false, .acq_rel)) {
                    const now = nowMs();
                    const last = self.last_relief_ms.load(.acquire);
                    if (now - last > 2000 and
                        self.last_relief_ms.cmpxchgStrong(last, now, .acq_rel, .acquire) == null)
                    {
                        memoryPressureRelief();
                    }
                }
                // Nothing queued: worker 0 alone may spend the idle on ONE
                // speculative tile around the hinted view (see hintView) —
                // one background core at most, and only after the map
                // settled. Everyone else just naps.
                if (worker_id == 0 and self.speculate()) continue;
                sleepMs(2);
                continue;
            }
            const job = self.queue.orderedRemove(0);
            self.queue_lock.unlock();

            // A tile answered while NO library is open would complete as a
            // permanent empty: the source URL never changes across style
            // swaps, so MapLibre caches the emptiness and never asks again —
            // the start view stays blank until a gesture visits new tiles.
            // Park tile jobs until setLibrary lands (sprites/glyphs pass:
            // their generation URLs re-request naturally).
            if (job.ask == .tile and !self.hasSource()) {
                if (job.handle.cancelled() catch false) {
                    job.handle.release();
                    if (job.stack_buf) |b| self.alloc.free(b);
                    continue;
                }
                self.queue_lock.lock();
                self.queue.append(self.alloc, job) catch {
                    self.queue_lock.unlock();
                    job.handle.release();
                    if (job.stack_buf) |b| self.alloc.free(b);
                    continue;
                };
                self.queue_lock.unlock();
                sleepMs(25);
                continue;
            }

            self.serve(job);
            if (job.stack_buf) |b| self.alloc.free(b);
        }
    }

    fn serve(self: *Provider, job: Job) void {
        defer job.handle.release();

        // A pan queues far more tiles than it keeps. Drop the ones MapLibre has
        // already given up on before paying to compose them.
        if (job.handle.cancelled() catch false) return;

        var tile_res: ?TileBytes = null;
        const bytes: ?[]const u8 = switch (job.ask) {
            .tile => |t| blk: {
                tile_res = self.composeTile(t.z, t.x, t.y);
                const r = tile_res orelse break :blk null;
                break :blk if (r.bytes.len == 0) null else r.bytes;
            },
            .sprite_json => |s| self.sprite(s.pixel_ratio, s.scheme, .json),
            .sprite_png => |s| self.sprite(s.pixel_ratio, s.scheme, .png),
            .glyphs => |g| self.glyphRange(g.stack, g.start),
        };

        _ = self.served.fetchAdd(1, .release);
        self.did_work.store(true, .release);
        if (job.ask == .tile) {
            const t = job.ask.tile;
            mlog("prov: tile {d}/{d}/{d} -> {d} bytes\n", .{ t.z, t.x, t.y, if (bytes) |b| b.len else 0 });
        }
        // Debug: mirror every served tile to a directory, so a tile MapLibre
        // rejects can be replayed through the reference decoder offline.
        if (std.c.getenv("LOOKOUT_ML_TILE_DIR")) |dir| {
            if (job.ask == .tile) if (bytes) |b| {
                var pbuf: [512]u8 = undefined;
                const t = job.ask.tile;
                if (std.fmt.bufPrintZ(&pbuf, "{s}/{d}-{d}-{d}.mlt", .{ dir, t.z, t.x, t.y })) |p| {
                    if (std.c.fopen(p.ptr, "w")) |f| {
                        _ = std.c.fwrite(b.ptr, 1, b.len, f);
                        _ = std.c.fclose(f);
                    }
                } else |_| {}
            };
        }
        if (bytes) |b| {
            job.handle.complete(.{ .status = .ok, .bytes = b }) catch |e| switch (e) {
                // MapLibre cancelled the request while the tile was being
                // composed. Expected during pan/zoom; no error.
                error.InvalidState, error.AlreadyCompleted, error.ClosedHandle => {},
                else => mlog("prov: complete FAILED {s}\n", .{@errorName(e)}),
            };
        } else {
            // "Nothing here" is not an error for a chart library: most of the
            // world has no cell. A 404 tells MapLibre to stop asking rather
            // than to retry.
            job.handle.complete(.{ .status = .no_content }) catch {};
        }

        // A tile's bytes are per-request either way: the engine's buffer for a
        // fresh compose, this provider's copy for a cache hit. Sprite and
        // glyph bytes are cached and outlive the job.
        if (job.ask == .tile) if (tile_res) |r| if (r.bytes.len != 0) {
            if (r.from_cache) self.alloc.free(@constCast(r.bytes)) else cc.tile57_free(@constCast(r.bytes.ptr));
        };
    }

    fn composeTile(self: *Provider, z: u8, x: u32, y: u32) ?TileBytes {
        const key = tileKey(z, x, y);
        self.cache_lock.lock();
        if (self.tile_cache.getPtr(key)) |e| {
            self.cache_tick +%= 1;
            e.stamp = self.cache_tick;
            if (e.bytes.len == 0) {
                self.cache_lock.unlock();
                return .{ .bytes = "", .from_cache = true }; // cached empty
            }
            if (self.alloc.dupe(u8, e.bytes)) |dup| {
                self.cache_lock.unlock();
                return .{ .bytes = dup, .from_cache = true };
            } else |_| {} // OOM: fall through and compose
        }
        self.cache_lock.unlock();

        self.src_lock.lock();
        const compose = self.compose;
        const chart = self.chart;
        self.src_lock.unlock();

        var out: [*c]u8 = null;
        var out_len: usize = 0;
        var owned: bool = false;
        var err: cc.tile57_error = undefined;

        const st = if (compose) |c|
            cc.tile57_compose_tile(c, z, x, y, &out, &out_len, &owned, &err)
        else if (chart) |ch| blk: {
            // The lone chart handle is not internally synchronized (unlike the
            // compositor's readers); one worker in it at a time.
            self.chart_mu.lock();
            defer self.chart_mu.unlock();
            break :blk cc.tile57_chart_tile(ch, z, x, y, &out, &out_len, &err);
        } else return null;

        if (st != cc.TILE57_OK) {
            mlog("prov: tile {d}/{d}/{d} status {d}\n", .{ z, x, y, st });
            return null;
        }
        if (out == null or out_len == 0) mlog("prov: tile {d}/{d}/{d} EMPTY owned={}\n", .{ z, x, y, owned });
        const fresh: []const u8 = if (out == null) "" else out[0..out_len];
        self.remember(key, fresh);
        if (fresh.len == 0) return .{ .bytes = "", .from_cache = false };
        return .{ .bytes = fresh, .from_cache = false };
    }

    /// Keep a copy of a served tile (or its emptiness) for the next visit,
    /// evicting least-recently-served entries past the byte budget.
    fn remember(self: *Provider, key: u64, bytes: []const u8) void {
        const copy: []u8 = if (bytes.len == 0) &.{} else self.alloc.dupe(u8, bytes) catch return;
        self.cache_lock.lock();
        defer self.cache_lock.unlock();
        self.cache_tick +%= 1;
        const gop = self.tile_cache.getOrPut(self.alloc, key) catch {
            if (copy.len != 0) self.alloc.free(copy);
            return;
        };
        if (gop.found_existing and gop.value_ptr.bytes.len != 0) {
            self.cache_bytes -= gop.value_ptr.bytes.len;
            self.alloc.free(gop.value_ptr.bytes);
        }
        gop.value_ptr.* = .{ .bytes = copy, .stamp = self.cache_tick };
        self.cache_bytes += copy.len;
        while (self.cache_bytes > tile_cache_budget) {
            var oldest_key: u64 = 0;
            var oldest_stamp: u32 = std.math.maxInt(u32);
            var have = false;
            var it = self.tile_cache.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.bytes.len != 0 and kv.value_ptr.stamp < oldest_stamp) {
                    oldest_stamp = kv.value_ptr.stamp;
                    oldest_key = kv.key_ptr.*;
                    have = true;
                }
            }
            if (!have) break;
            const e = self.tile_cache.fetchRemove(oldest_key).?;
            self.cache_bytes -= e.value.bytes.len;
            self.alloc.free(e.value.bytes);
        }
    }

    const SpriteKind = enum { json, png };

    fn sprite(self: *Provider, pixel_ratio: u8, scheme_ask: cc.tile57_scheme, kind: SpriteKind) ?[]const u8 {
        self.sprite_lock.lock();
        for (self.sprite_cache.items) |e| {
            if (e.pixel_ratio == pixel_ratio and e.scheme == scheme_ask) {
                self.sprite_lock.unlock();
                return if (kind == .json) e.json else e.png;
            }
        }
        self.sprite_lock.unlock();

        // The first sprite request also warms the OTHER two palettes on their
        // own thread: a dusk/night switch then swaps sheets instead of paying
        // ~seconds of SVG rasterization while the chart waits.
        if (!self.sprite_warm_started.swap(true, .acq_rel)) {
            self.warm_thread = std.Thread.spawn(.{}, warmSprites, .{ self, pixel_ratio, scheme_ask }) catch null;
        }

        // The disk cache first: a sheet persisted by an earlier launch loads in
        // milliseconds where the bake below takes seconds.
        {
            var jb: [512]u8 = undefined;
            var pb: [512]u8 = undefined;
            const jp = self.diskSpritePath(&jb, scheme_ask, pixel_ratio, "json");
            const pp = self.diskSpritePath(&pb, scheme_ask, pixel_ratio, "png");
            if (jp != null and pp != null) {
                if (self.readDiskFile(jp.?)) |dj| {
                    if (self.readDiskFile(pp.?)) |dp| {
                        self.sprite_lock.lock();
                        defer self.sprite_lock.unlock();
                        for (self.sprite_cache.items) |e| {
                            if (e.pixel_ratio == pixel_ratio and e.scheme == scheme_ask) {
                                self.alloc.free(dj);
                                self.alloc.free(dp);
                                return if (kind == .json) e.json else e.png;
                            }
                        }
                        self.sprite_cache.append(self.alloc, .{
                            .pixel_ratio = pixel_ratio,
                            .scheme = scheme_ask,
                            .json = dj,
                            .png = dp,
                        }) catch {
                            self.alloc.free(dj);
                            self.alloc.free(dp);
                            return null;
                        };
                        return if (kind == .json) dj else dp;
                    } else self.alloc.free(dj);
                }
            }
        }

        // Bake with sprite_lock RELEASED (a cached palette must stay servable
        // while this takes seconds) but bake_mu HELD: the engine's sprite bake
        // must never run twice at once. Re-check the cache after acquiring —
        // the thread we waited on probably baked exactly this palette.
        self.bake_mu.lock();
        defer self.bake_mu.unlock();
        self.sprite_lock.lock();
        for (self.sprite_cache.items) |e| {
            if (e.pixel_ratio == pixel_ratio and e.scheme == scheme_ask) {
                self.sprite_lock.unlock();
                return if (kind == .json) e.json else e.png;
            }
        }
        self.sprite_lock.unlock();

        var assets: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
        var err: cc.tile57_error = undefined;
        const dir: [*c]const u8 = if (self.catalog_dir) |d| d.ptr else null;
        const st = cc.tile57_bake_sprite_mln(
            dir,
            @floatFromInt(pixel_ratio),
            scheme_ask,
            &assets,
            &err,
        );
        if (st != cc.TILE57_OK) return null;
        defer cc.tile57_assets_free(&assets);

        // Debug: dump the sprite pair for a density, to chase entries MapLibre
        // rejects ("invalid metrics" — e.g. an image over its 1024px cap).
        if (std.c.getenv("LOOKOUT_ML_SPRITE")) |base| {
            var pbuf: [512]u8 = undefined;
            for ([_]SpriteKind{ .json, .png }) |k| {
                const ext = if (k == .json) "json" else "png";
                const p = std.fmt.bufPrintZ(&pbuf, "{s}@{d}x.{s}", .{ base, pixel_ratio, ext }) catch continue;
                if (std.c.fopen(p.ptr, "w")) |f| {
                    const b = if (k == .json) assets.sprite_json[0..assets.sprite_json_len] else assets.sprite_png[0..assets.sprite_png_len];
                    _ = std.c.fwrite(b.ptr, 1, b.len, f);
                    _ = std.c.fclose(f);
                }
            }
        }
        const json = self.alloc.dupe(u8, assets.sprite_json[0..assets.sprite_json_len]) catch return null;
        const png = self.alloc.dupe(u8, assets.sprite_png[0..assets.sprite_png_len]) catch {
            self.alloc.free(json);
            return null;
        };
        // Persist for the next launch, before the insert races anything.
        {
            var jb: [512]u8 = undefined;
            var pb: [512]u8 = undefined;
            if (self.diskSpritePath(&jb, scheme_ask, pixel_ratio, "json")) |jp| writeDiskFile(jp, json);
            if (self.diskSpritePath(&pb, scheme_ask, pixel_ratio, "png")) |pp| writeDiskFile(pp, png);
        }
        self.sprite_lock.lock();
        defer self.sprite_lock.unlock();
        // Two threads may have baked the same palette; first insert wins and
        // the loser's copy is dropped.
        for (self.sprite_cache.items) |e| {
            if (e.pixel_ratio == pixel_ratio and e.scheme == scheme_ask) {
                self.alloc.free(json);
                self.alloc.free(png);
                return if (kind == .json) e.json else e.png;
            }
        }
        self.sprite_cache.append(self.alloc, .{
            .pixel_ratio = pixel_ratio,
            .scheme = scheme_ask,
            .json = json,
            .png = png,
        }) catch {
            self.alloc.free(json);
            self.alloc.free(png);
            return null;
        };
        return if (kind == .json) json else png;
    }

    /// Bake the palettes the first request did NOT ask for, so a scheme
    /// switch finds its sheet already cached. Runs once, on its own thread.
    fn warmSprites(self: *Provider, pixel_ratio: u8, first: cc.tile57_scheme) void {
        for ([_]cc.tile57_scheme{ cc.TILE57_SCHEME_DAY, cc.TILE57_SCHEME_DUSK, cc.TILE57_SCHEME_NIGHT }) |sch| {
            if (sch == first) continue;
            if (self.stopping.load(.acquire)) return;
            _ = self.sprite(pixel_ratio, sch, .json);
        }
    }

    /// tile57 can encode a MapLibre glyph range but does NOT expose it on the C
    /// ABI (only the GPU path's SDF atlas, which is a different format). We
    /// reach it as a Zig module instead. See specs/maplibre/concerns.md C2.
    fn glyphRange(self: *Provider, stack: []const u8, first_cp: u21) ?[]const u8 {
        var key_buf: [96]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}/{d}", .{ stack, first_cp }) catch return null;

        self.glyph_lock.lock();
        defer self.glyph_lock.unlock();
        if (self.glyph_cache.get(key)) |v| return v;

        const face = faceFor(stack);
        const bytes = glyphpbf.encodeRange(self.alloc, face, stack, first_cp) catch return null;
        const owned_key = self.alloc.dupe(u8, key) catch {
            self.alloc.free(bytes);
            return null;
        };
        self.glyph_cache.put(self.alloc, owned_key, bytes) catch {
            self.alloc.free(owned_key);
            self.alloc.free(bytes);
            return null;
        };
        return bytes;
    }

    /// The style names three fontstacks for the label tiers (bold for populated
    /// places, italic for hydrography, regular otherwise). Return the embedded
    /// TrueType bytes for each — `encodeRange` shapes from the face itself, not
    /// from a face name.
    fn faceFor(stack: []const u8) []const u8 {
        const font = t57.render.font;
        if (std.mem.indexOf(u8, stack, "Bold") != null) return font.notosans_bold;
        if (std.mem.indexOf(u8, stack, "Italic") != null) return font.notosans_italic;
        return font.notosans;
    }
};

/// Decode %XX escapes. MapLibre encodes the space in "Noto Sans Bold".
fn percentDecode(alloc: std.mem.Allocator, in: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(alloc, in.len);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < in.len) {
        if (in[i] == '%' and i + 2 < in.len) {
            if (std.fmt.parseInt(u8, in[i + 1 .. i + 3], 16)) |b| {
                try out.append(alloc, b);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(alloc, in[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

// ---- url parsing ---------------------------------------------------------

/// Parse the part after `lookout://`. Returns null for anything unrecognised,
/// which the caller answers 404 rather than passing through — a malformed
/// lookout url is our bug, not something MapLibre's http source should see.
fn parse(path: []const u8) ?Ask {
    if (std.mem.startsWith(u8, path, "tile/")) {
        var it = std.mem.splitScalar(u8, path["tile/".len..], '/');
        const z = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
        const x = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const y_s = it.next() orelse return null;
        if (it.next() != null) return null;
        const y = std.fmt.parseInt(u32, y_s, 10) catch return null;
        return .{ .tile = .{ .z = z, .x = x, .y = y } };
    }

    if (std.mem.startsWith(u8, path, "sprite")) {
        var rest = path["sprite".len..];
        // The palette rides the url (sprite-day / sprite-dusk / sprite-night):
        // one shared url let MapLibre cache a day sheet into a night style.
        // A bare "sprite" stays valid as the day sheet.
        var sch: cc.tile57_scheme = cc.TILE57_SCHEME_DAY;
        if (std.mem.startsWith(u8, rest, "-day")) {
            rest = rest["-day".len..];
        } else if (std.mem.startsWith(u8, rest, "-dusk")) {
            sch = cc.TILE57_SCHEME_DUSK;
            rest = rest["-dusk".len..];
        } else if (std.mem.startsWith(u8, rest, "-night")) {
            sch = cc.TILE57_SCHEME_NIGHT;
            rest = rest["-night".len..];
        }
        // Strip the style-generation suffix (-gN). It exists so MapLibre
        // cannot pair a stale in-flight sprite with a newer style; the
        // provider serves the same palette bytes for every generation.
        if (std.mem.startsWith(u8, rest, "-g")) {
            var d: usize = 2;
            while (d < rest.len and std.ascii.isDigit(rest[d])) d += 1;
            if (d > 2) rest = rest[d..];
        }
        // MapLibre asks for `<base>.json`, `<base>.png`, and the @2x variants.
        var ratio: u8 = 1;
        var tail = rest;
        if (std.mem.startsWith(u8, tail, "@2x")) {
            ratio = 2;
            tail = tail["@2x".len..];
        } else if (std.mem.startsWith(u8, tail, "@3x")) {
            ratio = 3;
            tail = tail["@3x".len..];
        }
        if (std.mem.eql(u8, tail, ".json")) return .{ .sprite_json = .{ .pixel_ratio = ratio, .scheme = sch } };
        if (std.mem.eql(u8, tail, ".png")) return .{ .sprite_png = .{ .pixel_ratio = ratio, .scheme = sch } };
        return null;
    }

    if (std.mem.startsWith(u8, path, "glyphs/")) {
        // MapLibre percent-encodes the fontstack ("Noto%20Sans%20Bold"). The
        // name has to be decoded before it reaches the encoder, because the
        // encoder writes it into the pbf as the fontstack's OWN name and the
        // client matches that against what it asked for.
        const rest = path["glyphs/".len..];
        const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return null;
        const stack = rest[0..slash];
        const range = rest[slash + 1 ..];
        if (!std.mem.endsWith(u8, range, ".pbf")) return null;
        const nums = range[0 .. range.len - ".pbf".len];
        const dash = std.mem.indexOfScalar(u8, nums, '-') orelse return null;
        const start = std.fmt.parseInt(u21, nums[0..dash], 10) catch return null;
        if (stack.len == 0) return null;
        return .{ .glyphs = .{ .stack = stack, .start = start } };
    }

    return null;
}

// ---- tests ---------------------------------------------------------------

test "parse: a composed tile url" {
    const a = parse("tile/14/4711/6262").?;
    try std.testing.expectEqual(@as(u8, 14), a.tile.z);
    try std.testing.expectEqual(@as(u32, 4711), a.tile.x);
    try std.testing.expectEqual(@as(u32, 6262), a.tile.y);
}

test "parse: a tile url with a trailing segment is refused" {
    // Guards against a style template that appends an extension: serving the
    // wrong tile is worse than serving none.
    try std.testing.expect(parse("tile/14/4711/6262/extra") == null);
    try std.testing.expect(parse("tile/14/4711") == null);
    try std.testing.expect(parse("tile/x/4711/6262") == null);
}

test "parse: sprite at each density" {
    try std.testing.expectEqual(@as(u8, 1), parse("sprite.json").?.sprite_json.pixel_ratio);
    try std.testing.expectEqual(@as(u8, 1), parse("sprite.png").?.sprite_png.pixel_ratio);
    try std.testing.expectEqual(@as(u8, 2), parse("sprite@2x.json").?.sprite_json.pixel_ratio);
    try std.testing.expectEqual(@as(u8, 2), parse("sprite@2x.png").?.sprite_png.pixel_ratio);
    try std.testing.expect(parse("sprite.gif") == null);
}

test "parse: the palette and style generation ride the sprite url" {
    // The exact shapes MapLibre derives from the style's base url after the
    // host stamps scheme + generation (style.zig spriteUrlFor + -gN).
    const d = parse("sprite-day-g3@2x.json").?.sprite_json;
    try std.testing.expectEqual(@as(u8, 2), d.pixel_ratio);
    try std.testing.expectEqual(cc.TILE57_SCHEME_DAY, d.scheme);
    const k = parse("sprite-dusk-g12@2x.png").?.sprite_png;
    try std.testing.expectEqual(cc.TILE57_SCHEME_DUSK, k.scheme);
    const n = parse("sprite-night-g1.json").?.sprite_json;
    try std.testing.expectEqual(@as(u8, 1), n.pixel_ratio);
    try std.testing.expectEqual(cc.TILE57_SCHEME_NIGHT, n.scheme);
    // Different generations resolve to the same ask.
    const g9 = parse("sprite-night-g9.json").?.sprite_json;
    try std.testing.expectEqual(n.scheme, g9.scheme);
}

test "percentDecode: the fontstack's space survives the url" {
    const a = std.testing.allocator;
    const d = try percentDecode(a, "Noto%20Sans%20Bold");
    defer a.free(d);
    try std.testing.expectEqualStrings("Noto Sans Bold", d);

    const plain = try percentDecode(a, "Noto Sans Regular");
    defer a.free(plain);
    try std.testing.expectEqualStrings("Noto Sans Regular", plain);
}

test "parse: a glyph range keeps a fontstack containing spaces" {
    const a = parse("glyphs/Noto Sans Regular/0-255.pbf").?;
    try std.testing.expectEqualStrings("Noto Sans Regular", a.glyphs.stack);
    try std.testing.expectEqual(@as(u21, 0), a.glyphs.start);

    const b = parse("glyphs/Noto Sans Bold/256-511.pbf").?;
    try std.testing.expectEqualStrings("Noto Sans Bold", b.glyphs.stack);
    try std.testing.expectEqual(@as(u21, 256), b.glyphs.start);
}

test "parse: unknown paths are refused, not passed through" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("style.json") == null);
    try std.testing.expect(parse("glyphs/NoRange") == null);
}

test "faceFor: the three label tiers select three distinct faces" {
    const font = t57.render.font;
    try std.testing.expectEqual(font.notosans.ptr, Provider.faceFor("Noto Sans Regular").ptr);
    try std.testing.expectEqual(font.notosans_bold.ptr, Provider.faceFor("Noto Sans Bold").ptr);
    try std.testing.expectEqual(font.notosans_italic.ptr, Provider.faceFor("Noto Sans Italic").ptr);
}
