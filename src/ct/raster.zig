//! The raster underlay: the mariner's picture charts (community MBTiles,
//! baked BSB/KAP sheets) served to charttable as raster sources.
//!
//! charttable owns the drawing — it decodes PNG and WebP, draws a raster
//! layer as world-space quads in style order, and parks slow tiles rather
//! than caching them as missing. This file holds what charttable cannot know:
//!
//!   * the SETS — files group by provider ("Navionics") or by the bake they
//!     came from, and only sets covering the same water exclude each other;
//!   * the SERVING — a small pool answers charttable's asks from
//!     `tile57_raster_chart_tile`, first enabled chart in the set that holds
//!     the tile, encoded bytes straight through (charttable decodes);
//!   * what the STYLE needs — one raster source + one raster layer per set,
//!     which ct/style.zig splices above the area fills and below the lines.
//!
//! THREADING. Each set's provider is charttable's Provider: `fetch` runs on
//! charttable's cache workers, `pump` drains the asks on the map-driving
//! thread and queues them, and this pool answers from its own threads via
//! `respond`, which is safe from any thread. tile57's raster chart handle is
//! not internally synchronized, so each chart carries a lock held across
//! exactly one tile read. Providers are heap-boxed and never freed while the
//! map lives (charttable holds pointers into them); they go at deinit, after
//! the map has stopped its workers.

const std = @import("std");
const cc = @import("../c.zig").c;
const ct = @import("charttable");
const Lock = @import("../lock.zig").Lock;
const sleepMs = @import("../lock.zig").sleepMs;

const Request = ct.provider.Request;
const Camera = ct.camera.Camera;

/// The cycle's practical limit, and the style splice's: "raster0".."raster7".
pub const MAX_SETS = 8;
const WORKERS = 2;

const Box = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// One open raster chart.
const Chart = struct {
    chart: *cc.tile57_raster_chart,
    info: cc.tile57_raster_chart_info,
    path: []u8,
    /// Serializes ENGINE access: tile57_raster_chart_* is not internally
    /// synchronized. Held across one tile read, never across a respond.
    mu: Lock = .{},
    /// Off keeps the file installed and stops drawing it — a mariner carrying
    /// four providers for one coast wants three of them quiet, not deleted.
    enabled: bool = true,
};

/// One or more charts drawn as one continuous layer, cycled as one name.
const Set = struct {
    /// NUL-terminated: the C ABI hands this to a host as a C string.
    name: [:0]u8,
    /// The style source ("raster0"…): stable for the set's whole life, which
    /// is what lets a style rebuild rebind the same provider.
    source_name: [:0]const u8,
    charts: std.ArrayListUnmanaged(Chart) = .empty,
    /// Drawn where it covers. PER SET: switching the Atlantic on must not
    /// switch the west coast, so one selection index cannot express this.
    shown: bool = false,
    /// Heap-boxed; the map holds a pointer into it for the set's lifetime.
    provider: *ct.provider.Provider,
};

const SOURCE_NAMES = [MAX_SETS][:0]const u8{
    "raster0", "raster1", "raster2", "raster3",
    "raster4", "raster5", "raster6", "raster7",
};

/// What the style splice needs to declare one set (ct/style.zig).
pub const StyleInfo = @import("style.zig").RasterSet;

pub const Rasters = struct {
    alloc: std.mem.Allocator,
    sets: std.ArrayListUnmanaged(Set) = .empty,

    mu: Lock = .{},
    queue: std.ArrayListUnmanaged(Job) = .empty,
    in_flight: usize = 0,
    threads: [WORKERS]?std.Thread = .{null} ** WORKERS,
    n_threads: usize = 0,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Drain scratch, reused so a frame allocates nothing new. Map thread only.
    asks: std.ArrayListUnmanaged(Request) = .empty,

    const Job = struct { set: usize, req: Request };

    pub fn init(alloc: std.mem.Allocator) Rasters {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Rasters) void {
        self.stopping.store(true, .release);
        for (self.threads[0..self.n_threads]) |t| if (t) |th| th.join();
        self.n_threads = 0;
        for (self.sets.items) |*s| {
            for (s.charts.items) |*c| {
                cc.tile57_raster_chart_close(c.chart);
                self.alloc.free(c.path);
            }
            s.charts.deinit(self.alloc);
            s.provider.deinit();
            self.alloc.destroy(s.provider);
            self.alloc.free(s.name);
        }
        self.sets.deinit(self.alloc);
        self.queue.deinit(self.alloc);
        self.asks.deinit(self.alloc);
    }

    // ---- sources ---------------------------------------------------------

    /// Open a raster chart and add it to its set, creating the set when the
    /// name is new. False when the file will not open — a bad chart must
    /// never take the app down with it, so the caller logs and carries on.
    pub fn add(self: *Rasters, path: [:0]const u8) bool {
        var chart: ?*cc.tile57_raster_chart = null;
        var err: cc.tile57_error = undefined;
        if (cc.tile57_raster_chart_open(path.ptr, &chart, &err) != cc.TILE57_OK) {
            std.debug.print("raster: {s}: {s}\n", .{ path, @as([*:0]const u8, @ptrCast(&err.message)) });
            return false;
        }
        const ch = chart orelse return false;
        errdefer cc.tile57_raster_chart_close(ch);

        var info: cc.tile57_raster_chart_info = undefined;
        cc.tile57_raster_chart_get_info(ch, &info);

        const set = self.setNamed(setNameFor(path)) orelse return false;
        const path_copy = self.alloc.dupe(u8, path) catch return false;
        set.charts.append(self.alloc, .{
            .chart = ch,
            .info = info,
            .path = path_copy,
        }) catch {
            self.alloc.free(path_copy);
            return false;
        };

        // The provider must declare where its data stops, or the map asks for
        // tiles that can only ever be answered "no tile there".
        const idx = (@intFromPtr(set) - @intFromPtr(self.sets.items.ptr)) / @sizeOf(Set);
        self.refreshBand(idx);

        // Draw a new set unless something already covering that water is
        // drawn: a second provider for one coast is a choice, not a
        // replacement; a new coast has nothing to compete with.
        if (!self.anyShownOver(idx)) self.sets.items[idx].shown = true;

        self.start();
        return true;
    }

    /// The set called `name`, creating it if room remains.
    fn setNamed(self: *Rasters, name: []const u8) ?*Set {
        for (self.sets.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        if (self.sets.items.len >= MAX_SETS) return null;
        const owned = self.alloc.dupeZ(u8, name) catch return null;
        const p = self.alloc.create(ct.provider.Provider) catch {
            self.alloc.free(owned);
            return null;
        };
        p.* = ct.provider.Provider.init(self.alloc);
        p.kind = .raster;
        // Ids must be unique ACROSS sets: one respond serves them all, and two
        // providers numbering from 1 would answer each other's tiles.
        p.id_bias = @as(u64, self.sets.items.len + 1) << 48;
        self.sets.append(self.alloc, .{
            .name = owned,
            .source_name = SOURCE_NAMES[self.sets.items.len],
            .provider = p,
        }) catch {
            p.deinit();
            self.alloc.destroy(p);
            self.alloc.free(owned);
            return null;
        };
        return &self.sets.items[self.sets.items.len - 1];
    }

    /// Re-derive a set's zoom band and tile size from its enabled charts.
    fn refreshBand(self: *Rasters, i: usize) void {
        const s = &self.sets.items[i];
        var minz: u8 = 255;
        var maxz: u8 = 0;
        var ts: u32 = 256;
        for (s.charts.items) |*c| {
            if (!c.enabled) continue;
            minz = @min(minz, c.info.min_zoom);
            maxz = @max(maxz, c.info.max_zoom);
            if (c.info.tile_size != 0) ts = c.info.tile_size;
        }
        if (minz == 255) {
            minz = 0;
            maxz = 0;
        }
        s.provider.minzoom = minz;
        s.provider.maxzoom = maxz;
        s.provider.tile_size = ts;
    }

    /// Turn one chart on or off by path, without removing it. The provider's
    /// answered tiles are stale after this — which picture a given address
    /// answers with changed — so its memory of them has to go with it; the
    /// caller rebuilds the style, and the fresh source refetches.
    pub fn setEnabled(self: *Rasters, path: []const u8, on: bool) bool {
        var found = false;
        for (self.sets.items, 0..) |*set, i| {
            var hit = false;
            for (set.charts.items) |*c| {
                if (!std.mem.eql(u8, c.path, path)) continue;
                if (c.enabled != on) {
                    c.enabled = on;
                    hit = true;
                }
            }
            if (hit) {
                found = true;
                self.refreshBand(i);
                // A set with nothing enabled cannot draw at all.
                if (!self.setHasEnabled(i)) set.shown = false;
            }
        }
        return found;
    }

    pub fn isEnabled(self: *Rasters, path: []const u8) bool {
        for (self.sets.items) |*set| {
            for (set.charts.items) |*c| {
                if (std.mem.eql(u8, c.path, path)) return c.enabled;
            }
        }
        return false;
    }

    fn setHasEnabled(self: *const Rasters, i: usize) bool {
        for (self.sets.items[i].charts.items) |*c| {
            if (c.enabled) return true;
        }
        return false;
    }

    // ---- what the style needs -------------------------------------------

    /// One entry per set, in set order, into `buf`. The style splice draws
    /// these above the chart's area fills and below its lines.
    pub fn styleInfos(self: *const Rasters, buf: *[MAX_SETS]StyleInfo) []const StyleInfo {
        for (self.sets.items, 0..) |*s, i| {
            buf[i] = .{
                .source_name = s.source_name,
                .minzoom = s.provider.minzoom,
                .maxzoom = s.provider.maxzoom,
                .tile_size = s.provider.tile_size,
                .visible = s.shown and self.setHasEnabled(i),
            };
        }
        return buf[0..self.sets.items.len];
    }

    /// The provider standing behind set `i`, for the host to bind by name
    /// after each style set.
    pub fn providerAt(self: *Rasters, i: usize) *ct.provider.Provider {
        return self.sets.items[i].provider;
    }

    // ---- serving ---------------------------------------------------------

    fn start(self: *Rasters) void {
        if (self.n_threads != 0) return;
        while (self.n_threads < WORKERS) : (self.n_threads += 1) {
            self.threads[self.n_threads] = std.Thread.spawn(.{}, worker, .{self}) catch break;
        }
    }

    /// Take charttable's outstanding asks and queue them for the pool. Call
    /// once per frame from whichever thread drives the map.
    pub fn pump(self: *Rasters) void {
        for (self.sets.items, 0..) |*s, i| {
            self.asks.clearRetainingCapacity();
            s.provider.drain(&self.asks, self.alloc);
            if (self.asks.items.len == 0) continue;
            self.mu.lock();
            for (self.asks.items) |req| {
                self.queue.append(self.alloc, .{ .set = i, .req = req }) catch break;
            }
            self.mu.unlock();
        }
    }

    pub fn busy(self: *Rasters) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.queue.items.len != 0 or self.in_flight != 0;
    }

    fn worker(self: *Rasters) void {
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

    fn take(self: *Rasters) ?Job {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.queue.items.len == 0) return null;
        // Newest first: a pan leaves stale asks behind it.
        const job = self.queue.pop() orelse return null;
        self.in_flight += 1;
        return job;
    }

    fn serve(self: *Rasters, job: Job) void {
        defer {
            self.mu.lock();
            self.in_flight -= 1;
            self.mu.unlock();
        }
        // Sets are append-only, so the index stays valid for the set's life.
        if (job.set >= self.sets.items.len) return;
        const s = &self.sets.items[job.set];

        // First enabled chart in the set that holds the tile wins. These
        // pyramids are clipped to a coastline and run about 38% dense, so
        // "no tile there" is the ordinary case, not a failure.
        for (s.charts.items) |*c| {
            if (!c.enabled) continue;
            if (job.req.z < c.info.min_zoom or job.req.z > c.info.max_zoom) continue;
            var bytes: [*c]u8 = null;
            var len: usize = 0;
            var err: cc.tile57_error = undefined;
            c.mu.lock();
            const st = cc.tile57_raster_chart_tile(c.chart, job.req.z, job.req.x, job.req.y, &bytes, &len, &err);
            c.mu.unlock();
            if (st != cc.TILE57_OK) continue;
            if (bytes == null or len == 0) continue;
            defer cc.tile57_free(bytes);
            s.provider.respond(job.req.id, bytes[0..len], .ok);
            return;
        }
        s.provider.respond(job.req.id, "", .empty);
    }

    // ---- the election ----------------------------------------------------
    // Only sets covering the same water exclude each other, and every
    // control speaks about ONE view's water.

    pub fn setCount(self: *const Rasters) usize {
        return self.sets.items.len;
    }

    pub fn setNameAt(self: *const Rasters, i: usize) [:0]const u8 {
        if (i >= self.sets.items.len) return "";
        return self.sets.items[i].name;
    }

    pub fn isShown(self: *const Rasters, i: usize) bool {
        if (i >= self.sets.items.len) return false;
        return self.sets.items[i].shown;
    }

    /// Draw set `i`, or stop drawing it, without a camera — what restores a
    /// saved selection. Showing goes through `show`, so the election holds.
    pub fn setShown(self: *Rasters, i: usize, on: bool) void {
        if (i >= self.sets.items.len) return;
        if (on) {
            if (!self.setHasEnabled(i)) return;
            self.show(i);
        } else {
            self.sets.items[i].shown = false;
        }
    }

    /// Draw set `i`, or stop drawing over THIS view when `i` is null. "None"
    /// hides what is drawn here, not everywhere.
    pub fn selectSet(self: *Rasters, cam: Camera, i: ?usize) void {
        if (i) |n| {
            if (n >= self.sets.items.len) return;
            self.show(n);
        } else if (self.shownSet(cam)) |cur| {
            self.sets.items[cur].shown = false;
        }
    }

    /// Draw set `i` and hide the sets it competes with.
    fn show(self: *Rasters, i: usize) void {
        self.sets.items[i].shown = true;
        for (self.sets.items, 0..) |*s, j| {
            if (j == i or !s.shown) continue;
            if (self.setsOverlap(i, j)) s.shown = false;
        }
    }

    /// Is any OTHER set covering the same water already drawn?
    fn anyShownOver(self: *const Rasters, i: usize) bool {
        for (self.sets.items, 0..) |*s, j| {
            if (j == i or !s.shown) continue;
            if (self.setsOverlap(i, j)) return true;
        }
        return false;
    }

    fn setsOverlap(self: *const Rasters, a: usize, b: usize) bool {
        const ba = self.setBounds(a) orelse return false;
        const bb = self.setBounds(b) orelse return false;
        if (ba.y1 < bb.y0 or ba.y0 > bb.y1) return false;
        // Longitude wraps, so test each world instance the spans can reach.
        for ([_]f64{ -1, 0, 1 }) |shift| {
            if (ba.x1 >= bb.x0 + shift and ba.x0 <= bb.x1 + shift) return true;
        }
        return false;
    }

    /// The world bounds of a set: the union of its enabled charts.
    fn setBounds(self: *const Rasters, i: usize) ?Box {
        if (i >= self.sets.items.len) return null;
        var out: ?Box = null;
        for (self.sets.items[i].charts.items) |*c| {
            if (!c.enabled) continue;
            const b: Box = .{
                .x0 = lonToWorldX(c.info.west),
                .y0 = latToWorldY(c.info.north),
                .x1 = lonToWorldX(c.info.east),
                .y1 = latToWorldY(c.info.south),
            };
            if (out) |*u| {
                u.x0 = @min(u.x0, b.x0);
                u.y0 = @min(u.y0, b.y0);
                u.x1 = @max(u.x1, b.x1);
                u.y1 = @max(u.y1, b.y1);
            } else out = b;
        }
        return out;
    }

    pub fn setInView(self: *const Rasters, i: usize, cam: Camera) bool {
        if (i >= self.sets.items.len) return false;
        const box = visibleBox(cam);
        for (self.sets.items[i].charts.items) |*c| {
            if (!c.enabled) continue;
            const n = latToWorldY(c.info.north);
            const s2 = latToWorldY(c.info.south);
            if (box.y1 < n or box.y0 > s2) continue;
            const w = lonToWorldX(c.info.west);
            const e = lonToWorldX(c.info.east);
            // visibleBox keeps a CONTINUOUS x span, which may run outside
            // [0,1] across the antimeridian.
            for ([_]f64{ -1, 0, 1 }) |shift| {
                if (box.x1 >= w + shift and box.x0 <= e + shift) return true;
            }
        }
        return false;
    }

    /// The set covering THE WATER THE MARINER IS LOOKING AT, drawn or not:
    /// centred under the view, else filling most of it.
    fn focusSet(self: *const Rasters, cam: Camera) ?usize {
        const box = visibleBox(cam);
        var best: ?usize = null;
        var best_area: f64 = 0;
        var best_centred = false;
        for (self.sets.items, 0..) |_, i| {
            if (!self.setInView(i, cam)) continue;
            const b = self.setBounds(i) orelse continue;
            var area: f64 = 0;
            var centred = false;
            for ([_]f64{ -1, 0, 1 }) |shift| {
                const x0 = @max(box.x0, b.x0 + shift);
                const x1 = @min(box.x1, b.x1 + shift);
                const y0 = @max(box.y0, b.y0);
                const y1 = @min(box.y1, b.y1);
                if (x1 <= x0 or y1 <= y0) continue;
                area += (x1 - x0) * (y1 - y0);
                if (cam.center.x >= b.x0 + shift and cam.center.x <= b.x1 + shift and
                    cam.center.y >= b.y0 and cam.center.y <= b.y1) centred = true;
            }
            const better = best == null or
                (centred and !best_centred) or
                (centred == best_centred and area > best_area);
            if (better) {
                best = i;
                best_area = area;
                best_centred = centred;
            }
        }
        return best;
    }

    /// The drawn set covering the same water as `anchor`, or null.
    fn shownInGroup(self: *const Rasters, cam: Camera, anchor: usize) ?usize {
        for (self.sets.items, 0..) |*s, j| {
            if (!s.shown) continue;
            if (!self.setInView(j, cam)) continue;
            if (!self.setsOverlap(j, anchor)) continue;
            return j;
        }
        return null;
    }

    fn shownSet(self: *const Rasters, cam: Camera) ?usize {
        const anchor = self.focusSet(cam) orelse return null;
        return self.shownInGroup(cam, anchor);
    }

    /// Which set the pill names and the list marks: what is DRAWN HERE.
    pub fn shownIndex(self: *const Rasters, cam: Camera) ?usize {
        return self.shownSet(cam);
    }

    /// The name of the set drawn over this view, or "".
    pub fn activeNameFor(self: *const Rasters, cam: Camera) [:0]const u8 {
        const i = self.shownSet(cam) orelse return "";
        return self.sets.items[i].name;
    }

    /// The name of a set whose imagery is on screen, DRAWN OR NOT — what lets
    /// a host say "there is a picture here" while it is switched off.
    pub fn availableName(self: *const Rasters, cam: Camera) [:0]const u8 {
        if (self.shownSet(cam)) |i| return self.sets.items[i].name;
        if (self.focusSet(cam)) |i| return self.sets.items[i].name;
        return "";
    }

    /// Step to the next set covering THIS WATER, then to nothing, then round
    /// again. Never moves the camera. Every other coast keeps its state.
    pub fn cycle(self: *Rasters, cam: Camera) void {
        const n = self.sets.items.len;
        if (n == 0) return;
        const anchor = self.focusSet(cam) orelse return;
        const cur = self.shownInGroup(cam, anchor);
        var j: usize = if (cur) |i| i + 1 else 0;
        while (j < n) : (j += 1) {
            if (!self.setInView(j, cam)) continue;
            // setsOverlap(anchor, anchor) is true, so the anchor is a step.
            if (!self.setsOverlap(j, anchor)) continue;
            self.show(j);
            return;
        }
        if (cur) |i| self.sets.items[i].shown = false;
    }

    /// The lon/lat box every installed chart covers (west, south, east,
    /// north), or null. Frames the view when there is no vector chart.
    pub fn coverage(self: *const Rasters) ?[4]f64 {
        var out: ?[4]f64 = null;
        for (self.sets.items) |*set| {
            for (set.charts.items) |*c| {
                const b: [4]f64 = .{ c.info.west, c.info.south, c.info.east, c.info.north };
                if (b[0] == 0 and b[1] == 0 and b[2] == 0 and b[3] == 0) continue;
                if (out) |*u| {
                    u[0] = @min(u[0], b[0]);
                    u[1] = @min(u[1], b[1]);
                    u[2] = @max(u[2], b[2]);
                    u[3] = @max(u[3], b[3]);
                } else out = b;
            }
        }
        return out;
    }
};

// ---- geometry ---------------------------------------------------------------

fn visibleBox(cam: Camera) Box {
    var dx0: f64 = 1e9;
    var dx1: f64 = -1e9;
    var y0: f64 = 1e9;
    var y1: f64 = -1e9;
    const corners = [_][2]f32{
        .{ 0, 0 },
        .{ cam.vw, 0 },
        .{ 0, cam.vh },
        .{ cam.vw, cam.vh },
    };
    for (corners) |c| {
        const w = cam.screenToWorld(c[0], c[1]);
        const dx = ct.camera.wrapDx(w.x, cam.center.x);
        dx0 = @min(dx0, dx);
        dx1 = @max(dx1, dx);
        y0 = @min(y0, w.y);
        y1 = @max(y1, w.y);
    }
    return .{
        .x0 = cam.center.x + dx0,
        .y0 = @max(0.0, y0),
        .x1 = cam.center.x + dx1,
        .y1 = @min(1.0, y1),
    };
}

fn lonToWorldX(lon: f64) f64 {
    return (lon + 180.0) / 360.0;
}

fn latToWorldY(lat: f64) f64 {
    const clamped = @max(-85.05112878, @min(85.05112878, lat));
    const rad = std.math.degreesToRadians(clamped);
    const s = std.math.sin(rad);
    return 0.5 - std.math.log(f64, std.math.e, (1.0 + s) / (1.0 - s)) / (4.0 * std.math.pi);
}

// ---- set naming -------------------------------------------------------------

/// What to call the set a file belongs to. A community MBTiles names its
/// provider; a BAKED sheet belongs to the bake it came from
/// (`<root>/<stem>/<stem>.pmtiles`), because a bundle holds hundreds and 968
/// sets of one sheet each is not a choice a mariner can make.
pub fn setNameFor(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (providerIn(base)) |k| return k;

    const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];

    if (std.mem.endsWith(u8, base, ".pmtiles")) {
        const dir = std.fs.path.dirname(path) orelse return stem;
        if (std.mem.eql(u8, std.fs.path.basename(dir), stem)) {
            if (std.fs.path.dirname(dir)) |root| {
                const root_name = std.fs.path.basename(root);
                if (root_name.len > 0) {
                    if (providerIn(root_name)) |k| return k;
                    return root_name;
                }
            }
        }
    }
    return if (stem.len == 0) base else stem;
}

/// A producer this name carries, if any. Longest first, so "OpenSeaMap" is
/// not reported as "OSM".
fn providerIn(name: []const u8) ?[]const u8 {
    const known = [_][]const u8{
        "OpenSeaMap", "Navionics", "Sentinel", "ArcGIS", "Google",
        "C-Map",      "Yandex",    "Imagery",  "Bing",   "ESRI",
        "Esri",       "CMap",      "NAIP",     "SASP",   "OSM",
    };
    for (known) |k| {
        if (containsIgnoreCase(name, k)) return k;
    }
    return null;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "set names: a provider for a community file, the bake for a sheet" {
    try testing.expectEqualStrings("ArcGIS", setNameFor("EU-SI-Full.ArcGIS.Z10-Z18.2024-08.mbtiles"));
    try testing.expectEqualStrings("Navionics", setNameFor("US-CA-San-Francisco-Bay.Navionics.Z10-Z18.2023-12.mbtiles"));
    try testing.expectEqualStrings("USWestCoast", setNameFor("/c/USWestCoast/L14-6320-2600-16-32_14/L14-6320-2600-16-32_14.pmtiles"));
    try testing.expectEqualStrings("OSM", setNameFor("/c/OSM-OpenCPN2-KAP-USWestCoast-20260615/L14-x/L14-x.pmtiles"));
    try testing.expectEqualStrings("loose", setNameFor("/c/somewhere/loose.pmtiles"));
}

test "world y from latitude matches the mercator corners" {
    try testing.expectApproxEqAbs(@as(f64, 0.5), latToWorldY(0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), latToWorldY(85.05112878), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.0), latToWorldY(-85.05112878), 1e-6);
    try testing.expect(latToWorldY(46.0) < latToWorldY(45.0));
}
