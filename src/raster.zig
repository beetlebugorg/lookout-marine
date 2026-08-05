//! Raster charts beneath the vector chart.
//!
//! WHY THIS EXISTS. A mariner going into a bay the ENC barely covers carries
//! offline satellite imagery. The chart gives depths, aids and hazards; the
//! picture gives what is actually there — the coral heads, the sand bar across
//! the entrance, the breakwater built since the last edition. This puts the
//! picture on the display under the chart.
//!
//! WHY IT IS A SEPARATE SUBSYSTEM. The vector scene is tessellated ONCE over an
//! overscanned box and only rebuilt when the view leaves it; that is why the app
//! holds 60 fps. Raster tiles do not behave that way. They arrive continuously
//! while the mariner pans, each one a file read and a JPEG decode, so they need
//! their own worker, their own cache and their own memory ceiling. Nothing here
//! touches the scene.
//!
//! WHY THE SPRITE PIPELINE. A raster tile is a textured quad in world space with
//! a tint, and `sprite_vert`/`sprite_frag` already draw exactly that —
//! `atlas.sample(smp, uv) * color`, with the antimeridian wrap and the
//! paint-order depth built in. So no backend needs a new shader or a new
//! pipeline: it binds the tile's texture, points at these quads, and draws.
//! The tint is what dims the picture at dusk and night (a daylight photograph at
//! full brightness costs the mariner dark adaptation, which is what those
//! schemes exist to protect).
//!
//! ORDERING. Tiles draw FIRST, before the opaque phase, with depth just under
//! the cleared 1.0 and no depth write. The chart's own area fills then paint
//! over them — which is correct, and is exactly what the chart-over-picture
//! portrayal mode has to undo before any of this is visible with a chart loaded.
//!
//! THREADING. `tile57_raster_chart_*` is not internally synchronized, and the
//! WORKER owns it: the main thread reads a source's info and label once at open
//! and never calls the engine for a tile.

const std = @import("std");
const cc = @import("c.zig").c;
const camera = @import("camera.zig");
const gpu = @import("gpu.zig");

const Lock = @import("lock.zig").Lock;
const sleepMs = @import("lock.zig").sleepMs;

/// LOOKOUT_RASTER_DEBUG=1 traces tile selection, the worker queue and every
/// fetch. Read once — this is on the per-tile path.
var debug_on: ?bool = null;

fn debugOn() bool {
    if (debug_on) |d| return d;
    const d = std.c.getenv("LOOKOUT_RASTER_DEBUG") != null;
    debug_on = d;
    return d;
}

/// 256 px of RGBA is 256 KB resident per tile, so a ceiling is not optional on a
/// phone. A 1080p view at one zoom needs about forty tiles; this holds several
/// zoom levels of history so a pinch back out is instant.
pub const DEFAULT_BUDGET_BYTES: usize = 160 * 1024 * 1024;

/// How many tiles may be in flight. The worker decodes one at a time and the
/// view asks for the whole screen at once; a bound keeps a fast pan from
/// queueing thousands of tiles the mariner has already left behind.
const MAX_INFLIGHT: usize = 64;

/// How many tiles decode at once.
const WORKERS: usize = 4;

/// How many sets may draw in one frame. Sets only draw together when they cover
/// different water, so this is a count of separate cruising grounds on screen at
/// once, not a count of charts.
const MAX_DRAW_SETS: usize = 16;

/// One open raster chart.
pub const Source = struct {
    chart: *cc.tile57_raster_chart,
    info: cc.tile57_raster_chart_info,
    /// What to show the mariner. Derived from the file name, because a chart's
    /// own `name` is routinely something like
    /// "EU-SI-Full.W3.00.ArcGIS.Imagery.Z10-Z18.mbtiles 20240822051758 Unknown".
    label: []u8,
    path: []u8,
    /// Serializes ENGINE access to this chart. `tile57_raster_chart_*` is not
    /// internally synchronized, so the fetch is held under this; the JPEG
    /// decode that follows is not, which is the whole point — decoding is the
    /// expensive half and it runs in parallel across the pool.
    mu: Lock = .{},
    /// Off keeps the file installed and stops drawing it. A mariner who carries
    /// four providers for one coast wants three of them quiet, not deleted —
    /// they are half-gigabyte downloads.
    enabled: bool = true,
};

/// One or more sources drawn as one continuous layer. A mariner carrying
/// adjacent regions from one provider sees one picture; the provider is what
/// they cycle between.
pub const Set = struct {
    /// NUL-terminated: the C ABI hands this to a host as a C string.
    name: [:0]u8,
    sources: std.ArrayList(Source) = .empty,

    fn deinit(self: *Set, a: std.mem.Allocator) void {
        for (self.sources.items) |*s| {
            cc.tile57_raster_chart_close(s.chart);
            a.free(s.label);
            a.free(s.path);
        }
        self.sources.deinit(a);
        a.free(self.name);
    }
};

const Key = packed struct(u64) {
    x: u28,
    y: u28,
    z: u5,
    set: u3,

    fn pack(self: Key) u64 {
        return @bitCast(self);
    }
};

const State = enum { pending, ready, absent };

const Entry = struct {
    state: State,
    tex: ?gpu.RasterTex = null,
    bytes: usize = 0,
    /// Frame counter at last use, for the eviction sweep.
    used: u64 = 0,
};

const Req = struct { set: u8, z: u8, x: u32, y: u32 };
const Res = struct {
    key: u64,
    /// stb_image RGBA, freed with stbi_image_free once uploaded. Null = the
    /// chart has no tile there, or it would not decode.
    rgba: ?[*]u8 = null,
    w: u32 = 0,
    h: u32 = 0,
};

pub const Layer = struct {
    alloc: std.mem.Allocator,
    sets: std.ArrayList(Set) = .empty,
    /// Which set WINS WHERE SETS OVERLAP, or null for "no picture" — a position
    /// in the cycle, so one control also reaches the full chart.
    ///
    /// This does not mean "the only set drawn". Sets that cover different water
    /// draw together; see `drawList`.
    active: ?usize = null,
    /// How many sets the last `prepare` drew. Only so `wantsFrame` can tell an
    /// underlay that owes tiles from one that is switched off.
    drawing: usize = 0,

    cache: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    resident: usize = 0,
    budget: usize = DEFAULT_BUDGET_BYTES,
    frame: u64 = 0,

    /// Scratch for the frame's quads + draws, reused so a pan does not allocate.
    quads: std.ArrayList(cc.tile57_gpu_quad) = .empty,
    draws: std.ArrayList(gpu.RasterDraw) = .empty,
    /// The visible tile set the current GPU buffer was built from. Rebuilding is
    /// cheap but uploading is not, so a still view re-uses last frame's buffer.
    built_sig: u64 = 0,
    built_valid: bool = false,
    /// Tiles the last `prepare` wanted but did not have. A live frame draws
    /// without them and picks them up next frame; a snapshot has to wait.
    pending_now: usize = 0,

    /// Where the underlay sits in the chart's paint order, from
    /// gpu.Gpu.rasterDepth: immediately in front of the opaque area fills.
    /// Refreshed each frame, because a rebuilt scene renumbers its ranges.
    depth: f32 = 0.999,
    /// Hide the whole chart where a picture covers it, not only its fills. The
    /// mariner sees the bare picture over the raster chart and a full chart
    /// everywhere else — the comparison, without giving up the chart.
    hide_chart: bool = false,

    /// Scheme tint, straight alpha. White leaves the picture as shot; the dusk
    /// and night schemes drop it so a daylight photograph cannot destroy dark
    /// adaptation. Set by the host when the scheme changes.
    tint: [4]u8 = .{ 255, 255, 255, 255 },

    // ---- worker ----
    mu: Lock = .{},
    reqs: std.ArrayList(Req) = .empty,
    results: std.ArrayList(Res) = .empty,
    inflight: usize = 0,
    /// A POOL, not one worker. One tile at a time made a pan across cold ground
    /// fill in visibly serially, and a zoom wait for level after level. Four is
    /// enough to keep a 60 fps view fed without turning a phone into a heater.
    threads: [WORKERS]?std.Thread = .{null} ** WORKERS,
    stop: bool = false,

    pub fn init(a: std.mem.Allocator) Layer {
        return .{ .alloc = a };
    }

    pub fn deinit(self: *Layer, g: *gpu.Gpu) void {
        self.stopWorker();
        var it = self.cache.iterator();
        while (it.next()) |e| if (e.value_ptr.tex) |t| g.freeRasterTexture(t);
        self.cache.deinit(self.alloc);
        // Anything the worker had already decoded but that never got uploaded.
        for (self.results.items) |r| if (r.rgba) |p| cc.stbi_image_free(p);
        self.results.deinit(self.alloc);
        self.reqs.deinit(self.alloc);
        for (self.sets.items) |*s| s.deinit(self.alloc);
        self.sets.deinit(self.alloc);
        self.quads.deinit(self.alloc);
        self.draws.deinit(self.alloc);
    }

    // ---- sources ---------------------------------------------------------

    /// Open a raster chart and add it to a set, creating the set when its name is
    /// new. Returns false when the file will not open — a bad chart must never
    /// take the app down with it, so the caller logs and carries on.
    pub fn addSource(self: *Layer, path: [:0]const u8) bool {
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

        const base = std.fs.path.basename(path);
        const set_name = self.alloc.dupeZ(u8, setNameFor(path)) catch return false;
        const label = self.alloc.dupe(u8, base) catch {
            self.alloc.free(set_name);
            return false;
        };
        const path_copy = self.alloc.dupe(u8, path) catch {
            self.alloc.free(set_name);
            self.alloc.free(label);
            return false;
        };

        const set = self.setNamed(set_name) orelse {
            self.alloc.free(set_name);
            self.alloc.free(label);
            self.alloc.free(path_copy);
            return false;
        };
        set.sources.append(self.alloc, .{
            .chart = ch,
            .info = info,
            .label = label,
            .path = path_copy,
        }) catch return false;

        if (self.active == null) self.active = self.sets.items.len - 1;
        self.ensureWorker();
        return true;
    }

    /// The set called `name`, creating it if new. Takes ownership of `name` when
    /// it creates one and frees it when it does not.
    fn setNamed(self: *Layer, name: [:0]u8) ?*Set {
        for (self.sets.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) {
                self.alloc.free(name);
                return s;
            }
        }
        // Eight sets is the cycle's practical limit and the Key's `set` field.
        if (self.sets.items.len >= 8) return null;
        self.sets.append(self.alloc, .{ .name = name }) catch return null;
        return &self.sets.items[self.sets.items.len - 1];
    }

    /// Turn one chart on or off by its path, without removing it. Returns false
    /// when no installed chart has that path.
    ///
    /// This drops every cached tile: the worker takes the FIRST enabled source
    /// in a set that holds a tile, so a change here changes which picture a
    /// given address answers with, and a stale cache would keep serving the old
    /// one.
    pub fn setEnabled(self: *Layer, g: *gpu.Gpu, path: []const u8, on: bool) bool {
        var found = false;
        for (self.sets.items) |*set| {
            for (set.sources.items) |*src| {
                if (!std.mem.eql(u8, src.path, path)) continue;
                if (src.enabled != on) {
                    src.enabled = on;
                    found = true;
                }
            }
        }
        if (!found) return false;

        // A set with nothing enabled left cannot draw, so it must not stay
        // selected — the pill would keep naming a chart that is switched off.
        // Move to the first set that still has something, or to nothing.
        if (self.active) |i| {
            if (!self.setHasEnabled(i)) {
                self.active = null;
                for (self.sets.items, 0..) |_, j| {
                    if (self.setHasEnabled(j)) {
                        self.active = j;
                        break;
                    }
                }
            }
        } else {
            // Nothing was drawn. If the mariner just switched something back on,
            // draw it rather than making them find the pill.
            for (self.sets.items, 0..) |_, j| {
                if (self.setHasEnabled(j)) {
                    self.active = j;
                    break;
                }
            }
        }
        self.dropTiles(g);
        return true;
    }

    fn setHasEnabled(self: *const Layer, i: usize) bool {
        if (i >= self.sets.items.len) return false;
        for (self.sets.items[i].sources.items) |*src| {
            if (src.enabled) return true;
        }
        return false;
    }

    /// Is the chart at `path` installed and on?
    pub fn isEnabled(self: *Layer, path: []const u8) bool {
        for (self.sets.items) |*set| {
            for (set.sources.items) |*src| {
                if (std.mem.eql(u8, src.path, path)) return src.enabled;
            }
        }
        return false;
    }

    /// Release every cached tile and the current GPU frame.
    fn dropTiles(self: *Layer, g: *gpu.Gpu) void {
        var it = self.cache.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.tex) |t| g.freeRasterTexture(t);
        }
        self.cache.clearRetainingCapacity();
        self.resident = 0;
        g.clearRasterFrame();
        self.built_valid = false;
        self.built_sig = 0;
    }

    // ---- selecting a set --------------------------------------------------
    // A mariner carrying four providers for one coast has to be able to SEE
    // what they carry and pick one. A blind cycle cannot say what is installed,
    // and a single name cannot describe a state that belongs to another set.

    pub fn setNameAt(self: *const Layer, i: usize) [:0]const u8 {
        if (i >= self.sets.items.len) return "";
        return self.sets.items[i].name;
    }

    /// Is set `i` in view? Enabled sources only.
    pub fn setInView(self: *Layer, i: usize, cam: camera.Camera) bool {
        return self.setCoversView(i, cam);
    }

    /// Which set is drawn, or null.
    pub fn activeIndex(self: *const Layer) ?usize {
        return self.active;
    }

    /// Draw set `i`, or nothing when `i` is null.
    pub fn selectSet(self: *Layer, i: ?usize) void {
        if (i) |n| {
            if (n >= self.sets.items.len) return;
            self.active = n;
        } else {
            self.active = null;
        }
        self.built_valid = false;
        self.built_sig = 0;
    }

    /// The world bounds of a set: the union of its enabled sources.
    fn setBounds(self: *const Layer, i: usize) ?Box {
        if (i >= self.sets.items.len) return null;
        var out: ?Box = null;
        for (self.sets.items[i].sources.items) |*src| {
            if (!src.enabled) continue;
            const b: Box = .{
                .x0 = lonToWorldX(src.info.west),
                .y0 = latToWorldY(src.info.north),
                .x1 = lonToWorldX(src.info.east),
                .y1 = latToWorldY(src.info.south),
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

    /// Do two sets cover any of the same ground?
    ///
    /// WHY THE WHOLE BOUNDS AND NOT THE VIEW. Two sets that meet outside the
    /// window still compete, and testing only what is on screen would make the
    /// pair share the screen at one pan position and fight at the next — a set
    /// appearing and vanishing as the mariner scrolls. The answer has to hold
    /// still, so it is a property of the charts, not of the camera.
    fn setsOverlap(self: *const Layer, a: usize, b: usize) bool {
        const ba = self.setBounds(a) orelse return false;
        const bb = self.setBounds(b) orelse return false;
        if (ba.y1 < bb.y0 or ba.y0 > bb.y1) return false;
        // Longitude wraps, so test each world instance the spans can reach.
        for ([_]f64{ -1, 0, 1 }) |shift| {
            if (ba.x1 >= bb.x0 + shift and ba.x0 <= bb.x1 + shift) return true;
        }
        return false;
    }

    /// Which sets draw this frame, in paint order. Returns how many were written.
    ///
    /// SETS THAT COVER DIFFERENT WATER DRAW TOGETHER. A mariner carrying San
    /// Francisco and the Atlantic has no choice to make between them: the two
    /// never meet, and making one of them a mode would mean pressing a key on
    /// every passage to get back the chart already installed. Only sets that
    /// compete for the same ground are a choice, and `active` settles that
    /// choice.
    ///
    /// `active` is null for "no picture", which is off everywhere.
    fn drawList(self: *Layer, cam: camera.Camera, out: *[MAX_DRAW_SETS]usize) usize {
        var n: usize = 0;
        const act = self.active orelse return 0;
        if (act < self.sets.items.len and self.setCoversView(act, cam)) {
            out[n] = act;
            n += 1;
        }
        for (0..self.sets.items.len) |j| {
            if (n >= MAX_DRAW_SETS) break;
            if (j == act) continue;
            if (!self.setCoversView(j, cam)) continue;
            // The active set holds the ground it shares, whether or not it is
            // itself on screen: a set is either a competitor or it is not.
            if (self.setsOverlap(j, act)) continue;
            var clash = false;
            for (out[0..n]) |k| {
                if (self.setsOverlap(j, k)) {
                    clash = true;
                    break;
                }
            }
            if (clash) continue;
            out[n] = j;
            n += 1;
        }
        return n;
    }

    /// Step to the next set THAT IS IN VIEW, then to nothing, then round again.
    ///
    /// Only in-view sets, because the cycle is a comparison gesture: a mariner
    /// off San Francisco flipping between providers must not land on an
    /// Atlantic set and see the picture vanish. It steps through exactly what
    /// the pill's list offers, and that list holds only what covers the view.
    ///
    /// Never moves the camera and never rebuilds the vector scene.
    pub fn cycle(self: *Layer, cam: camera.Camera) void {
        const n = self.sets.items.len;
        if (n == 0) {
            self.active = null;
            self.built_valid = false;
            self.built_sig = 0;
            return;
        }
        // Step from what is DRAWN HERE, which is not always `active`: sailing
        // into San Francisco with the Atlantic set active shows San Francisco,
        // and the key has to move that picture, not the one over the horizon.
        const cur = self.shownSet(cam);
        const start: usize = if (cur) |i| i + 1 else 0;
        var j = start;
        while (j < n) : (j += 1) {
            if (!self.setCoversView(j, cam)) continue;
            // Only a set competing for this water is a step in the cycle. A set
            // covering other ground is drawn already and is not a choice.
            if (cur) |i| {
                if (!self.setsOverlap(j, i)) continue;
            }
            self.active = j;
            self.built_valid = false;
            self.built_sig = 0;
            return;
        }
        // Past the last competitor: show nothing. The next press starts over.
        self.active = null;
        self.built_valid = false;
        self.built_sig = 0;
    }

    /// The set the mariner sees over this view — the first of the draw list.
    /// Null when nothing is drawn here.
    fn shownSet(self: *Layer, cam: camera.Camera) ?usize {
        var list: [MAX_DRAW_SETS]usize = undefined;
        const n = self.drawList(cam, &list);
        return if (n == 0) null else list[0];
    }

    /// Which set the pill names and the list marks: what is DRAWN HERE, which is
    /// `active` only where sets compete. Null when nothing is drawn here.
    pub fn shownIndex(self: *Layer, cam: camera.Camera) ?usize {
        return self.shownSet(cam);
    }

    pub fn setCount(self: *const Layer) usize {
        return self.sets.items.len;
    }

    // ---- the frame -------------------------------------------------------

    /// Bring the cache up to date for `cam` and hand the GPU this frame's quads.
    /// Called on the render thread, before the scene draws.
    pub fn prepare(self: *Layer, g: *gpu.Gpu, cam: camera.Camera) void {
        self.frame +%= 1;
        self.drain(g);

        var list: [MAX_DRAW_SETS]usize = undefined;
        const n_sets = self.drawList(cam, &list);
        self.drawing = n_sets;
        if (n_sets == 0) {
            // Clear unconditionally. `cycle` already sets built_valid = false on
            // its way to "no picture", so a guard on that flag skipped the clear
            // and the last frame's tiles kept drawing after the mariner turned
            // the picture off.
            g.clearRasterFrame();
            self.built_valid = false;
            self.built_sig = 0;
            return;
        }

        self.quads.clearRetainingCapacity();
        self.draws.clearRetainingCapacity();
        self.pending_now = 0;

        // A rebuilt scene renumbers every range, so the slot the underlay sits
        // in moves. Re-read it, and rebuild the quads when it changes — the
        // depth rides in the vertices.
        const d = if (self.hide_chart) g.rasterDepthFront() else g.rasterDepth();
        if (d != self.depth) {
            self.depth = d;
            self.built_valid = false;
        }

        var sig: u64 = 0;
        var wanted: usize = 0;

        for (list[0..n_sets]) |set_idx| {
            sig = sig *% 0x9E3779B97F4A7C15 ^ set_idx;
            const set = &self.sets.items[set_idx];
            for (set.sources.items) |*src| {
                if (!src.enabled) continue;
                const z = pickZoom(src.info, cam.zoom);
                const span: f64 = @floatFromInt(@as(u64, 1) << @intCast(z));
                const box = visibleBox(cam);

                // Clamp to the source's own coverage so a view far from the chart
                // asks for nothing at all.
                const wx0 = @max(box.x0, lonToWorldX(src.info.west));
                const wx1 = @min(box.x1, lonToWorldX(src.info.east));
                const wy0 = @max(box.y0, latToWorldY(src.info.north));
                const wy1 = @min(box.y1, latToWorldY(src.info.south));
                if (wx1 <= wx0 or wy1 <= wy0) continue;

                var ty: i64 = @intFromFloat(@floor(wy0 * span));
                const ty1: i64 = @intFromFloat(@floor(wy1 * span));
                const n: i64 = @intFromFloat(span);
                while (ty <= ty1) : (ty += 1) {
                    if (ty < 0 or ty >= n) continue;
                    var tx: i64 = @intFromFloat(@floor(wx0 * span));
                    const tx1: i64 = @intFromFloat(@floor(wx1 * span));
                    while (tx <= tx1) : (tx += 1) {
                        const wrapped_x = @mod(tx, n);
                        const key: Key = .{
                            .x = @intCast(wrapped_x),
                            .y = @intCast(ty),
                            .z = @intCast(z),
                            .set = @intCast(set_idx),
                        };
                        const k = key.pack();
                        sig = sig *% 0x100000001B3 ^ k;
                        wanted += 1;

                        const gop = self.cache.getOrPut(self.alloc, k) catch continue;
                        if (!gop.found_existing) {
                            gop.value_ptr.* = .{ .state = .pending, .used = self.frame };
                            self.pending_now += 1;
                            _ = self.request(set_idx, z, @intCast(wrapped_x), @intCast(ty));
                            continue;
                        }
                        gop.value_ptr.used = self.frame;
                        if (gop.value_ptr.state == .pending) self.pending_now += 1;

                        // Not here yet: stand in with a COARSER ancestor already in
                        // the cache, magnified over this tile's ground.
                        //
                        // Without this a zoom shows the bare ENC for as long as the
                        // new level takes to arrive — the picture blinks out and
                        // fills back in, which is the one thing a comparison must
                        // not do. A tile map has the answer already: the parent
                        // covers the same ground at half the detail, and it is
                        // usually still in the cache from the zoom you just left.
                        var tex = gop.value_ptr.tex;
                        var tu0: f32 = 0;
                        var tv0: f32 = 0;
                        var tu1: f32 = 1;
                        var tv1: f32 = 1;
                        if (gop.value_ptr.state != .ready or tex == null) {
                            tex = null;
                            var up: u3 = 1;
                            while (up <= 5 and up <= z) : (up += 1) {
                                const az: u8 = z - up;
                                if (az < src.info.min_zoom) break;
                                const ax = wrapped_x >> up;
                                const ay = ty >> up;
                                const akey: Key = .{
                                    .x = @intCast(ax),
                                    .y = @intCast(ay),
                                    .z = @intCast(az),
                                    .set = @intCast(set_idx),
                                };
                                const anc = self.cache.getPtr(akey.pack()) orelse continue;
                                if (anc.state != .ready) continue;
                                anc.used = self.frame; // keep the stand-in alive
                                tex = anc.tex;
                                // Which quarter (or sixteenth, …) of the ancestor
                                // this tile is.
                                const span_a: f32 = @floatFromInt(@as(u32, 1) << up);
                                const mask: i64 = (@as(i64, 1) << up) - 1;
                                tu0 = @as(f32, @floatFromInt(wrapped_x & mask)) / span_a;
                                tv0 = @as(f32, @floatFromInt(ty & mask)) / span_a;
                                tu1 = tu0 + 1.0 / span_a;
                                tv1 = tv0 + 1.0 / span_a;
                                break;
                            }
                        }
                        const draw_tex = tex orelse continue;

                        // The tile's world rect. `tx` stays UNwrapped here so a view
                        // straddling the antimeridian gets a continuous span; the
                        // vertex shader wraps each vertex to the near world instance.
                        const x0: f32 = @floatCast(@as(f64, @floatFromInt(tx)) / span);
                        const x1: f32 = @floatCast(@as(f64, @floatFromInt(tx + 1)) / span);
                        const y0: f32 = @floatCast(@as(f64, @floatFromInt(ty)) / span);
                        const y1: f32 = @floatCast(@as(f64, @floatFromInt(ty + 1)) / span);

                        const first: u32 = @intCast(self.quads.items.len);
                        self.pushQuad(x0, y0, x1, y1, tu0, tv0, tu1, tv1) catch continue;
                        self.draws.append(self.alloc, .{
                            .tex = draw_tex,
                            .first = first,
                            .count = 6,
                        }) catch continue;
                    }
                }
            }
        }

        if (debugOn()) {
            const box = visibleBox(cam);
            std.debug.print("raster: sets={d} cam=({d:.5},{d:.5}) z={d:.2} vw={d}x{d} box=({d:.5},{d:.5})-({d:.5},{d:.5}) wanted={d} pending={d} quads={d} draws={d}\n", .{
                n_sets, cam.center.x,     cam.center.y,         cam.zoom,             cam.vw,
                cam.vh, box.x0,           box.y0,               box.x1,               box.y1,
                wanted, self.pending_now, self.quads.items.len, self.draws.items.len,
            });
            for (list[0..n_sets]) |set_idx| {
                const set = &self.sets.items[set_idx];
                std.debug.print("  set {d} {s} srcs={d}\n", .{ set_idx, set.name, set.sources.items.len });
                for (set.sources.items) |*src| {
                    std.debug.print("    src z={d}..{d} bounds=({d:.5},{d:.5},{d:.5},{d:.5}) -> worldx {d:.5}..{d:.5} worldy {d:.5}..{d:.5}\n", .{
                        src.info.min_zoom,          src.info.max_zoom,          src.info.west,               src.info.south,              src.info.east, src.info.north,
                        lonToWorldX(src.info.west), lonToWorldX(src.info.east), latToWorldY(src.info.north), latToWorldY(src.info.south),
                    });
                }
            }
        }
        if (sig != self.built_sig or !self.built_valid) {
            g.setRasterFrame(self.quads.items, self.draws.items) catch {
                self.built_valid = false;
                return;
            };
            self.built_sig = sig;
            self.built_valid = true;
        }

        self.evict(g);
    }

    /// Is any of this set's imagery ON SCREEN?
    ///
    /// WHY INTERSECTION AND NOT THE CENTRE. A host uses this to decide whether
    /// to offer the control at all, and the rule a mariner reads is "if I can
    /// see the picture, I can work it". A centre test breaks that at every zoom
    /// where the view is bigger than the coverage: at z8.6 over San Francisco
    /// the raster chart fills a third of the screen while the centre sits outside its
    /// bounds, so the control vanished with the picture still in plain sight.
    ///
    /// This is the same box the tile selection uses, so the answer cannot
    /// disagree with what is drawn.
    pub fn coversView(self: *Layer, cam: camera.Camera) bool {
        return self.shownSet(cam) != null;
    }

    /// The name of the set drawn over this view, or "".
    pub fn activeNameFor(self: *Layer, cam: camera.Camera) [:0]const u8 {
        const i = self.shownSet(cam) orelse return "";
        return self.sets.items[i].name;
    }

    /// The name of a set whose imagery is on screen, DRAWN OR NOT.
    ///
    /// This is what lets a host say "there is a picture here" while the picture
    /// is switched off. Without it the pill can only ever report what is drawn,
    /// so a mariner sailing into coverage sees no reason to touch it and never
    /// learns the raster chart they installed is under them.
    pub fn availableName(self: *Layer, cam: camera.Camera) [:0]const u8 {
        if (self.shownSet(cam)) |i| return self.sets.items[i].name;
        for (self.sets.items, 0..) |*set, i| {
            if (self.setCoversView(i, cam)) return set.name;
        }
        return "";
    }

    fn setCoversView(self: *Layer, set_idx: usize, cam: camera.Camera) bool {
        if (set_idx >= self.sets.items.len) return false;
        const box = visibleBox(cam);
        for (self.sets.items[set_idx].sources.items) |*src| {
            if (!src.enabled) continue;
            const n = latToWorldY(src.info.north);
            const s2 = latToWorldY(src.info.south);
            if (box.y1 < n or box.y0 > s2) continue;
            const w = lonToWorldX(src.info.west);
            const e = lonToWorldX(src.info.east);
            // visibleBox keeps a CONTINUOUS x span, which may run outside [0,1]
            // across the antimeridian. Test the source at each world instance
            // the span can reach.
            for ([_]f64{ -1, 0, 1 }) |shift| {
                if (box.x1 >= w + shift and box.x0 <= e + shift) return true;
            }
        }
        return false;
    }

    /// Does the underlay still owe the display a frame?
    ///
    /// WHY THIS EXISTS. The app renders ON DEMAND — an idle chart uses no CPU —
    /// so once the view settles nothing calls `prepare` again. Tiles arriving
    /// after that moment would never be drawn: the mariner would see whatever
    /// strip of imagery happened to have loaded when they stopped panning, and
    /// nothing more, forever. So the underlay has to be able to ask for a frame.
    ///
    /// True while any tile is in flight or any decoded tile is waiting to be
    /// uploaded. Goes false when the view is fully covered, so an idle chart
    /// goes back to costing nothing.
    pub fn wantsFrame(self: *Layer) bool {
        if (self.drawing == 0) return false;
        if (self.pending_now > 0) return true;
        self.mu.lock();
        defer self.mu.unlock();
        return self.results.items.len > 0 or self.inflight > 0 or self.reqs.items.len > 0;
    }

    /// Bring the underlay fully in, for a SNAPSHOT. A live frame draws what it
    /// has and picks the rest up next frame; a still image cannot, so this waits
    /// on the worker. Bounded, because a chart that covers none of the view
    /// would otherwise wait forever for tiles that do not exist.
    pub fn prepareBlocking(self: *Layer, g: *gpu.Gpu, cam: camera.Camera, timeout_ms: u32) void {
        var waited: u32 = 0;
        while (true) {
            self.prepare(g, cam);
            if (self.pending_now == 0 or waited >= timeout_ms) return;
            sleepMs(4);
            waited += 4;
        }
    }

    /// Six vertices, two triangles. The UV rect is normally the whole tile, and
    /// a SUB-RECT when this quad is showing a coarser ancestor in its place.
    fn pushQuad(self: *Layer, x0: f32, y0: f32, x1: f32, y1: f32, tu0: f32, tv0: f32, tu1: f32, tv1: f32) !void {
        const corner = struct {
            fn v(x: f32, y: f32, u: f32, vv: f32, tint: [4]u8, depth: f32) cc.tile57_gpu_quad {
                return .{
                    .x = x,
                    .y = y,
                    .ox = 0, // world-space quad: no screen-space offset at all
                    .oy = 0,
                    .u = u,
                    .v = vv,
                    .color = tint,
                    .weight = 0,
                    .scamin = 0,
                    .disp_cat = 0, // BASE: never gated by the category mask
                    .map_align = 0,
                    .flip = 0,
                    .tangent_q = 0,
                    // The chart's own paint order: immediately in front of the
                    // opaque area fills. The pass WRITES this, so those fills
                    // lose the depth test exactly where the picture covers them.
                    .depth = depth,
                };
            }
        };
        const t = self.tint;
        const d = self.depth;
        try self.quads.appendSlice(self.alloc, &.{
            corner.v(x0, y0, tu0, tv0, t, d),
            corner.v(x1, y0, tu1, tv0, t, d),
            corner.v(x1, y1, tu1, tv1, t, d),
            corner.v(x0, y0, tu0, tv0, t, d),
            corner.v(x1, y1, tu1, tv1, t, d),
            corner.v(x0, y1, tu0, tv1, t, d),
        });
    }

    /// Upload whatever the worker finished since the last frame.
    fn drain(self: *Layer, g: *gpu.Gpu) void {
        while (true) {
            self.mu.lock();
            const r = self.results.pop() orelse {
                self.mu.unlock();
                break;
            };
            self.inflight -|= 1;
            self.mu.unlock();

            const e = self.cache.getPtr(r.key) orelse {
                if (r.rgba) |p| cc.stbi_image_free(p);
                continue;
            };
            const rgba = r.rgba orelse {
                e.state = .absent;
                continue;
            };
            defer cc.stbi_image_free(rgba);
            const n = @as(usize, r.w) * r.h * 4;
            const tex = g.newRasterTexture(rgba[0..n], r.w, r.h) catch {
                e.state = .absent;
                continue;
            };
            e.state = .ready;
            e.tex = tex;
            e.bytes = n;
            self.resident += n;
            self.built_valid = false; // a new tile changes the frame's draw list
        }
    }

    /// Drop the least recently used tiles until the cache is back under budget.
    /// Tiles used THIS frame are never dropped — evicting one would re-request it
    /// on the next frame forever.
    fn evict(self: *Layer, g: *gpu.Gpu) void {
        if (self.resident <= self.budget) return;
        // A full sort per frame is not worth it: sweep for anything older than a
        // few frames and drop it, oldest first by a coarse age bucket.
        var age: u64 = 8;
        while (self.resident > self.budget and age < 4096) : (age *= 2) {
            var it = self.cache.iterator();
            while (it.next()) |kv| {
                if (self.resident <= self.budget) break;
                const e = kv.value_ptr;
                if (e.state != .ready) continue;
                if (self.frame -| e.used < age) continue;
                if (e.tex) |t| g.freeRasterTexture(t);
                self.resident -|= e.bytes;
                e.* = .{ .state = .absent, .used = 0 };
            }
        }
        self.built_valid = false;
    }

    // ---- the worker ------------------------------------------------------

    /// Queue one tile. False when the queue is full — the caller must then leave
    /// NO trace of the tile in the cache, or it is lost for good. See `prepare`.
    fn request(self: *Layer, set: usize, z: u8, x: u32, y: u32) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.inflight + self.reqs.items.len >= MAX_INFLIGHT) return false;
        self.reqs.append(self.alloc, .{ .set = @intCast(set), .z = z, .x = x, .y = y }) catch return false;
        return true;
    }

    fn ensureWorker(self: *Layer) void {
        for (&self.threads) |*t| {
            if (t.* != null) continue;
            t.* = std.Thread.spawn(.{}, workerMain, .{self}) catch |e| blk: {
                // Without a worker no tile ever lands and the underlay silently
                // stays empty — say so rather than leaving a blank chart to
                // explain.
                std.debug.print("raster: worker spawn failed ({s})\n", .{@errorName(e)});
                break :blk null;
            };
        }
    }

    fn stopWorker(self: *Layer) void {
        self.mu.lock();
        self.stop = true;
        self.mu.unlock();
        for (&self.threads) |*t| {
            if (t.*) |th| th.join();
            t.* = null;
        }
    }

    fn workerMain(self: *Layer) void {
        // Polled rather than waited on a condition variable: Zig 0.16 has no
        // std.Thread.Condition outside an Io, and a request queue that fills
        // during a pan and empties at anchor does not justify hand-rolling one
        // per platform. Backs off to 32 ms so an idle app is not paying for a
        // thread that wakes 500 times a second to find nothing.
        var idle_ms: u32 = 1;
        while (true) {
            self.mu.lock();
            if (self.stop) {
                self.mu.unlock();
                return;
            }
            const maybe = self.reqs.pop();
            if (maybe == null) {
                self.mu.unlock();
                sleepMs(idle_ms);
                if (idle_ms < 32) idle_ms *= 2;
                continue;
            }
            idle_ms = 1;
            const req = maybe.?;
            self.inflight += 1;
            self.mu.unlock();

            const key: Key = .{
                .x = @intCast(req.x),
                .y = @intCast(req.y),
                .z = @intCast(req.z),
                .set = @intCast(req.set),
            };
            var res: Res = .{ .key = key.pack() };

            // The worker OWNS the engine handles: nothing else calls a chart.
            if (req.set < self.sets.items.len) {
                const set = &self.sets.items[req.set];
                for (set.sources.items) |*src| {
                    if (!src.enabled) continue;
                    var bytes: ?[*]u8 = null;
                    var len: usize = 0;
                    var err: cc.tile57_error = undefined;
                    // The ENGINE call only. The decode below runs unlocked, so
                    // four workers decode four tiles at once.
                    src.mu.lock();
                    const st = cc.tile57_raster_chart_tile(src.chart, req.z, req.x, req.y, &bytes, &len, &err);
                    src.mu.unlock();
                    if (debugOn()) std.debug.print("raster: fetch z={d} x={d} y={d} -> status={d} len={d}\n", .{ req.z, req.x, req.y, st, len });
                    if (st != cc.TILE57_OK) continue;
                    const b = bytes orelse continue; // no tile here: the ordinary case
                    defer cc.tile57_free(b);
                    var w: c_int = 0;
                    var h: c_int = 0;
                    var comp: c_int = 0;
                    const px = cc.stbi_load_from_memory(b, @intCast(len), &w, &h, &comp, 4) orelse {
                        // A whole chart of these means an encoding the vendored
                        // decoder was not built for (WebP and AVIF are neither
                        // built nor supported by stb at all).
                        if (debugOn()) std.debug.print("raster: decode failed, {d} B: {s}\n", .{ len, cc.stbi_failure_reason() });
                        continue;
                    };
                    res.rgba = px;
                    res.w = @intCast(w);
                    res.h = @intCast(h);
                    break; // first source in the set that covers this tile wins
                }
            }

            self.mu.lock();
            self.results.append(self.alloc, res) catch {
                if (res.rgba) |p| cc.stbi_image_free(p);
                self.inflight -|= 1;
            };
            self.mu.unlock();
        }
    }
};

// ---- geometry -------------------------------------------------------------

const Box = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// The world-space AABB of the viewport, rotation included. Taken from the four
/// screen corners rather than from the centre and a radius, because a rotated
/// view's bounding box is not the unrotated one.
///
/// x is expressed as an offset from the camera centre before being turned back
/// into absolute world x, so a view straddling the antimeridian yields a
/// CONTINUOUS span (possibly outside [0,1]) instead of two disjoint pieces. The
/// caller wraps tile indices; the vertex shader wraps the vertices.
fn visibleBox(cam: camera.Camera) Box {
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
        const dx = camera.wrapDx(w.x, cam.center.x);
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

/// Which integer zoom to draw from. Past the source's deepest level the last one
/// stretches rather than the picture vanishing — it matters most at the closest
/// zoom, which is exactly where these pyramids run out.
fn pickZoom(info: cc.tile57_raster_chart_info, view_zoom: f64) u8 {
    const z = @floor(view_zoom);
    const lo: f64 = @floatFromInt(info.min_zoom);
    const hi: f64 = @floatFromInt(info.max_zoom);
    return @intFromFloat(@max(lo, @min(hi, z)));
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

/// What to call the set a file belongs to.
///
/// TWO SHAPES, because raster charts arrive two ways.
///
/// A community MBTiles names its provider, and that is what a mariner chooses
/// between: the same water ships from ArcGIS, Bing, Google and Navionics side
/// by side, and the one that shows the bottom today is the one they want.
///
/// A BAKED RNC does not. `tile57 bake` writes `<root>/<stem>/<stem>.pmtiles`,
/// one directory per sheet, and a bundle holds hundreds — 968 in the
/// OpenSeaMap West Coast set. Naming each after its own file would make 968
/// sets of one sheet, which is not a choice a mariner can make. They belong to
/// the bake they came from, and they quilt: that is the whole point of a sheet
/// carrying a compilation scale.
pub fn setNameFor(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (providerIn(base)) |k| return k;

    const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];

    // The bake's layout: the file sits alone in a directory named for itself,
    // and the directory above is the bake. Group by the bake, and read the
    // producer out of ITS name — a baked sheet gives nothing usable of its own
    // (an OpenSeaMap sheet calls itself `L14-6320-2600-16-32`), while the
    // bundle it came from is named for who made it.
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

/// A producer this name carries, if any. Longest first, so "OpenSeaMap" is not
/// reported as "OSM".
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

// ---- tests ---------------------------------------------------------------

const testing = std.testing;

test "set names: a provider for a community file, the bake for a sheet" {
    // A community MBTiles names its provider.
    try testing.expectEqualStrings("ArcGIS", setNameFor("EU-SI-Full.ArcGIS.Z10-Z18.2024-08.mbtiles"));
    try testing.expectEqualStrings("Bing", setNameFor("/x/EU-FR-Corsica.Bing.Z10-Z18.2024-08.mbtiles"));
    try testing.expectEqualStrings("Google", setNameFor("CA-BC-Broughton-Archipelago.Google.Z10-Z18.2023-12.mbtiles"));
    try testing.expectEqualStrings("Navionics", setNameFor("Ru_Paramushir_Is_Navionics_Z10-Z18.mbtiles"));
    try testing.expectEqualStrings("ESRI", setNameFor("RU_Paramushir_Is_ESRI_Z10-Z18.mbtiles"));
    // No provider in the name: its own set, named for the file.
    try testing.expectEqualStrings("Algeria-Z19", setNameFor("Algeria-Z19.mbtiles"));

    // A BAKED SHEET belongs to its bake, not to itself. Without this the
    // OpenSeaMap West Coast bundle makes 968 sets of one sheet each.
    try testing.expectEqualStrings("USWestCoast", setNameFor("/c/USWestCoast/L14-6320-2600-16-32_14/L14-6320-2600-16-32_14.pmtiles"));
    try testing.expectEqualStrings("USWestCoast", setNameFor("/c/USWestCoast/L16-25312-10456-16-16_16/L16-25312-10456-16-16_16.pmtiles"));
    // And the bake's own name names the producer when it carries one. A sheet
    // calls itself L14-6320-2600-16-32; the bundle says who made it.
    try testing.expectEqualStrings("OSM", setNameFor("/c/OSM-OpenCPN2-KAP-USWestCoast-20260615/L14-x/L14-x.pmtiles"));
    try testing.expectEqualStrings("OpenSeaMap", setNameFor("/c/OpenSeaMap-WestCoast/L14-x/L14-x.pmtiles"));
    // A .pmtiles that is NOT in the bake's layout keeps its own name.
    try testing.expectEqualStrings("loose", setNameFor("/c/somewhere/loose.pmtiles"));
}

test "world y from latitude matches the mercator corners" {
    try testing.expectApproxEqAbs(@as(f64, 0.5), latToWorldY(0), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), latToWorldY(85.05112878), 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 1.0), latToWorldY(-85.05112878), 1e-6);
    // North is a SMALLER world y than south — the axis the whole TMS flip is about.
    try testing.expect(latToWorldY(46.0) < latToWorldY(45.0));
}

test "zoom selection clamps into the source's own band" {
    var info: cc.tile57_raster_chart_info = std.mem.zeroes(cc.tile57_raster_chart_info);
    info.min_zoom = 9;
    info.max_zoom = 17;
    try testing.expectEqual(@as(u8, 9), pickZoom(info, 3.0)); // zoomed out past it
    try testing.expectEqual(@as(u8, 12), pickZoom(info, 12.7));
    try testing.expectEqual(@as(u8, 17), pickZoom(info, 20.0)); // stretch, never vanish
}

test "the key packs a whole tile address" {
    const k: Key = .{ .x = 70458, .y = 84151, .z = 17, .set = 3 };
    const round: Key = @bitCast(k.pack());
    try testing.expectEqual(k.x, round.x);
    try testing.expectEqual(k.y, round.y);
    try testing.expectEqual(k.z, round.z);
    try testing.expectEqual(k.set, round.set);
}
