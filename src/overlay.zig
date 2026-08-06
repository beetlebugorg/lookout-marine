//! Retained chart overlays: the geometry a plugin DESCRIBES and the core DRAWS.
//!
//! A plugin never touches a pipeline. It posts JSON batches of retained
//! objects (symbol / polyline / polygon anchored to lon/lat, coloured by
//! palette TOKEN), and this store keeps them, expands them to triangles in
//! web-mercator world space, and hands the render thread one flat vertex array
//! the backend uploads verbatim. Colour is a token, never an RGB, so night
//! never breaks: the token table below resolves per scheme.
//!
//! THE API root.zig DRIVES
//!
//!   var ov = overlay.Store.init(alloc);      // once, at open
//!   defer ov.deinit();
//!   try ov.applyBatch("org.beetlebug.ais", json);   // broker thread, any time
//!   ov.removeSource("org.beetlebug.ais");           // plugin stopped/failed
//!   const fr = try ov.buildIfNeeded(cam.zoom, .day); // render thread, per frame
//!   try gpu.setOverlay(fr);                          // re-uploads iff fr.generation moved
//!
//! THREADING. `applyBatch` / `removeSource` run on the broker's worker: they
//! take the mutex and touch only the object map. `buildIfNeeded` takes the same
//! mutex, rebuilds the vertex array under it, and returns a slice of it. That
//! slice stays valid until the NEXT buildIfNeeded, and only the render thread
//! calls that — so the render thread may read the frame lock-free, and an apply
//! landing mid-frame is simply picked up by the next build.
//!
//! SCREEN SIZES. Symbol radii and line widths are screen POINTS. There is no
//! per-vertex screen-offset channel here (the chart's px_to_clip trick needs a
//! vertex format this pass does not carry), so a point size is converted to
//! world units at BUILD time from the zoom, and the build is redone when the
//! zoom has moved more than 5% in scale. Between rebuilds a symbol scales with
//! the chart, which at 5% is under half a point on an 8 pt symbol.
//!
//! COORDINATES. Vertices are ABSOLUTE web-mercator world [0,1] as f32 — the
//! same space, and the same f32 precision, as the chart vertices the engine
//! emits (root.zig builds the MVP with origin 0,0). The backend's overlay
//! shader applies the same antimeridian wrap the chart shader does.
const std = @import("std");
const camera = @import("camera.zig");
const lock = @import("lock.zig");

/// Palette scheme. Mirrors tile57's day/dusk/night; kept as a local enum so
/// this file (and its tests) need no C import.
pub const Scheme = enum(u8) { day = 0, dusk = 1, night = 2 };

/// The prototype's colour vocabulary (PROTOTYPE.md "Color tokens"). A plugin
/// names one of these; the core picks the RGBA for the active scheme.
pub const Token = enum(u8) {
    ownship,
    target,
    target_danger,
    track,
    layline_port,
    layline_stbd,
    warning,
};

pub const Kind = enum(u8) { symbol, polyline, polygon };

/// The symbol shapes the prototype draws. Expanded to vector geometry here —
/// no sprite atlas, so the overlay pass carries no texture.
pub const Sym = enum(u8) { ownship, target };

/// Straight-alpha RGBA, 0..1 (what the shader wants).
pub const Rgba = [4]f32;

fn rgb(hex: u24, a: f32) Rgba {
    return .{
        @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(hex & 0xFF)) / 255.0,
        a,
    };
}

/// Token -> RGBA per scheme, indexed [token][scheme].
///
/// PICKED BY EYE, not from a published table: S-52 standardises the chart's
/// colours, not an overlay set, so these are judgement calls against the three
/// tile57 palettes (day background NODTA #93aebb, dusk #404d53, night #171e21).
/// Day values are dark and saturated because the day chart is pale; dusk values
/// are light because the dusk chart is dark slate; night values are dim reds
/// and ambers at low luminance so a night-adapted eye is not reset, with
/// `target_danger` the brightest of them because an alarm must be seen.
const TOKENS: [7][3]Rgba = .{
    // ownship: black on the day chart (the S-52 convention), pale on dusk,
    // dim orange at night — the one symbol that must always be findable.
    .{ rgb(0x101418, 1.0), rgb(0xC8D2D8, 1.0), rgb(0x9A4218, 1.0) },
    // target: magenta by day/dusk (the chart's "attention" hue, and clear of
    // both the blue water and the red danger state); dim amber at night.
    .{ rgb(0x8C1EA8, 1.0), rgb(0xB478D2, 1.0), rgb(0x7A4A10, 1.0) },
    // target_danger: red in every scheme, brightest token at night.
    .{ rgb(0xD40B1E, 1.0), rgb(0xE03A44, 1.0), rgb(0xC2301C, 1.0) },
    // track: quiet — it is history, and it must not compete with the chart.
    .{ rgb(0x2D4F8F, 0.85), rgb(0x7F9FD0, 0.85), rgb(0x5A2410, 0.85) },
    // laylines: port red / starboard green, the sides' own colours.
    .{ rgb(0xC8102E, 0.95), rgb(0xE0505F, 0.95), rgb(0x8E2418, 0.95) },
    .{ rgb(0x0F8A3C, 0.95), rgb(0x4FBD74, 0.95), rgb(0x2A5C1C, 0.95) },
    // warning: amber.
    .{ rgb(0xE06A00, 1.0), rgb(0xF0A040, 1.0), rgb(0x7E5008, 1.0) },
};

/// The RGBA a token resolves to under `scheme`.
pub fn resolve(tok: Token, scheme: Scheme) Rgba {
    return TOKENS[@intFromEnum(tok)][@intFromEnum(scheme)];
}

/// One overlay vertex: world position + colour. 24 bytes, mirrored by
/// `OverlayVertex` in the backends' overlay shader.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// What the render thread hands the GPU layer. `generation` only moves when the
/// vertices changed, so the backend re-uploads on a change and never per frame.
pub const Frame = struct {
    verts: []const Vertex,
    generation: u64,
};

/// One retained object, as posted. Geometry is kept in GEO and expanded per
/// build, so a zoom change re-expands without the plugin resending anything.
const Object = struct {
    kind: Kind,
    token: Token,
    // symbol
    sym: Sym = .ownship,
    at: [2]f64 = .{ 0, 0 }, // lon, lat
    rot_deg: f32 = 0, // true bearing, clockwise from north
    scale: f32 = 1,
    // polyline / polygon
    pts: [][2]f64 = &.{}, // lon, lat; owned
    width_pt: f32 = 1.5,
    dash: bool = false,
    alpha: f32 = 1, // polygon fill alpha, multiplies the token's

    fn free(self: *Object, alloc: std.mem.Allocator) void {
        if (self.pts.len > 0) alloc.free(self.pts);
        self.pts = &.{};
    }
};

// ---- geometry constants (screen points) ------------------------------------

const CIRCLE_SEGS = 24; // ring tessellation; 24 is smooth at 8 pt
const OWNSHIP_R_OUTER = 8.0;
const OWNSHIP_R_INNER = 5.0;
const OWNSHIP_STROKE = 1.6;
const OWNSHIP_NOTCH_TIP = 13.0; // bow notch apex, from the centre
const OWNSHIP_NOTCH_BASE = 7.2; // where the notch meets the outer ring
const OWNSHIP_NOTCH_HALF = 3.2;
const TARGET_TIP = 6.5; // AIS triangle: apex ahead of the anchor
const TARGET_TAIL = 3.5; // ...and base behind it (10 pt overall)
const TARGET_HALF = 3.5;
const DASH_ON = 7.0;
const DASH_OFF = 5.0;
/// Above this many dash cycles a segment draws solid — see emitPolyline.
const MAX_DASHES_PER_SEG = 4096;

/// Vertices one `ownship` symbol expands to: two stroked rings + the bow notch.
pub const OWNSHIP_VERTS = CIRCLE_SEGS * 6 * 2 + 3;
/// Vertices one `target` symbol expands to.
pub const TARGET_VERTS = 3;

/// Rebuild when the scale has moved more than 5% — log2(1.05) of zoom.
const ZOOM_REBUILD_DZ = 0.070389327891398;

/// Per-store object ceiling. A plugin that leaks objects costs frame time and
/// memory; over the cap the batch is rejected rather than silently truncated.
const MAX_OBJECTS = 4096;
/// Per-object point ceiling — the prototype's longest line is a 600-point
/// track, and an unbounded ring or polyline is an unbounded vertex buffer.
const MAX_POINTS = 8192;

pub const Error = error{ BadBatch, Budget, OutOfMemory };

pub const Store = struct {
    alloc: std.mem.Allocator,
    mu: lock.Lock = .{},
    /// Keyed by "<source_id>/<object id>" — the host's namespace, so two
    /// plugins may both call their symbol "ownship". Ordered map: draw order is
    /// insertion order within a kind, which is stable frame to frame.
    objs: std.StringArrayHashMapUnmanaged(Object) = .empty,
    verts: std.ArrayList(Vertex) = .empty,
    gen: u64 = 0,
    dirty: bool = true,
    has_build: bool = false,
    built_zoom: f64 = 0,
    built_scheme: Scheme = .day,

    pub fn init(alloc: std.mem.Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        var it = self.objs.iterator();
        while (it.next()) |e| {
            self.alloc.free(e.key_ptr.*);
            e.value_ptr.free(self.alloc);
        }
        self.objs.deinit(self.alloc);
        self.verts.deinit(self.alloc);
        self.* = undefined;
    }

    /// Objects currently retained (all sources).
    pub fn count(self: *Store) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.objs.count();
    }

    // ---- the control plane ------------------------------------------------

    /// Apply one overlay batch from `source_id`:
    /// `{"set":[<obj>,...],"del":["id",...]}`. Ids are namespaced by source.
    /// A `set` replaces the whole object. Malformed OBJECTS are skipped (a
    /// plugin's bad row must not drop its good ones); malformed JSON, a missing
    /// top-level object, or exceeding the object budget fail the batch.
    pub fn applyBatch(self: *Store, source_id: []const u8, json: []const u8) Error!void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, json, .{}) catch return Error.BadBatch;
        defer parsed.deinit();
        if (parsed.value != .object) return Error.BadBatch;
        const root = parsed.value.object;

        self.mu.lock();
        defer self.mu.unlock();

        if (root.get("del")) |d| {
            if (d == .array) for (d.array.items) |it| {
                const id = jstr(it) orelse continue;
                const key = self.makeKey(source_id, id) catch return Error.OutOfMemory;
                defer self.alloc.free(key);
                self.removeLocked(key);
            };
        }
        if (root.get("set")) |s| {
            if (s != .array) return Error.BadBatch;
            for (s.array.items) |it| {
                if (it != .object) continue;
                const o = it.object;
                const id = jstr(o.get("id") orelse continue) orelse continue;
                var obj = self.parseObject(o) catch |e| switch (e) {
                    error.OutOfMemory => return Error.OutOfMemory,
                    error.Skip => continue,
                };
                errdefer obj.free(self.alloc);
                const key = self.makeKey(source_id, id) catch return Error.OutOfMemory;
                const gop = self.objs.getOrPut(self.alloc, key) catch {
                    self.alloc.free(key);
                    obj.free(self.alloc);
                    return Error.OutOfMemory;
                };
                if (gop.found_existing) {
                    self.alloc.free(key); // the map already owns an equal key
                    gop.value_ptr.free(self.alloc);
                } else if (self.objs.count() > MAX_OBJECTS) {
                    _ = self.objs.orderedRemove(key);
                    self.alloc.free(key);
                    obj.free(self.alloc);
                    return Error.Budget;
                }
                gop.value_ptr.* = obj;
                self.dirty = true;
            }
        }
    }

    /// Drop every object a source owns — a plugin that stopped, failed or was
    /// disabled must leave nothing on the chart.
    pub fn removeSource(self: *Store, source_id: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const prefix = self.makeKey(source_id, "") catch return; // "<source>/"
        defer self.alloc.free(prefix);
        var i: usize = 0;
        while (i < self.objs.count()) {
            const k = self.objs.keys()[i];
            if (std.mem.startsWith(u8, k, prefix)) {
                self.objs.values()[i].free(self.alloc);
                self.objs.orderedRemoveAt(i);
                self.alloc.free(k);
                self.dirty = true;
            } else i += 1;
        }
    }

    fn removeLocked(self: *Store, k: []const u8) void {
        if (self.objs.fetchOrderedRemove(k)) |kv| {
            self.alloc.free(kv.key);
            var v = kv.value;
            v.free(self.alloc);
            self.dirty = true;
        }
    }

    fn makeKey(self: *Store, source_id: []const u8, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ source_id, id });
    }

    fn parseObject(self: *Store, o: std.json.ObjectMap) (error{ OutOfMemory, Skip })!Object {
        const kind = std.meta.stringToEnum(Kind, jstr(o.get("kind") orelse return error.Skip) orelse return error.Skip) orelse return error.Skip;
        const token = std.meta.stringToEnum(Token, jstr(o.get("color") orelse return error.Skip) orelse return error.Skip) orelse return error.Skip;
        var obj = Object{ .kind = kind, .token = token };
        switch (kind) {
            .symbol => {
                obj.sym = std.meta.stringToEnum(Sym, jstr(o.get("sym") orelse return error.Skip) orelse return error.Skip) orelse return error.Skip;
                obj.at = jpoint(o.get("at") orelse return error.Skip) orelse return error.Skip;
                obj.rot_deg = @floatCast(jnum(o.get("rot_deg")) orelse 0);
                obj.scale = @floatCast(jnum(o.get("scale")) orelse 1);
                if (!(obj.scale > 0.05 and obj.scale < 20)) obj.scale = 1;
            },
            .polyline, .polygon => {
                const arr = o.get(if (kind == .polyline) "pts" else "ring") orelse return error.Skip;
                if (arr != .array) return error.Skip;
                const need: usize = if (kind == .polyline) 2 else 3;
                if (arr.array.items.len < need or arr.array.items.len > MAX_POINTS) return error.Skip;
                var pts = try self.alloc.alloc([2]f64, arr.array.items.len);
                errdefer self.alloc.free(pts);
                var n: usize = 0;
                for (arr.array.items) |p| {
                    pts[n] = jpoint(p) orelse return error.Skip;
                    n += 1;
                }
                obj.pts = pts;
                obj.width_pt = @floatCast(jnum(o.get("width_pt")) orelse 1.5);
                if (!(obj.width_pt > 0.1 and obj.width_pt < 64)) obj.width_pt = 1.5;
                obj.dash = jbool(o.get("dash")) orelse false;
                obj.alpha = @floatCast(jnum(o.get("alpha")) orelse 1);
                obj.alpha = std.math.clamp(obj.alpha, 0, 1);
            },
        }
        return obj;
    }

    // ---- the geometry -----------------------------------------------------

    /// True when the vertex array no longer matches (zoom, scheme) or an apply
    /// has landed since the last build.
    pub fn needsRebuild(self: *Store, zoom: f64, scheme: Scheme) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.needsRebuildLocked(zoom, scheme);
    }

    fn needsRebuildLocked(self: *Store, zoom: f64, scheme: Scheme) bool {
        if (!self.has_build or self.dirty) return true;
        if (scheme != self.built_scheme) return true;
        return @abs(zoom - self.built_zoom) > ZOOM_REBUILD_DZ;
    }

    /// Render-thread entry: rebuild if needed and return the current frame.
    /// The returned slice is valid until the next call.
    pub fn buildIfNeeded(self: *Store, zoom: f64, scheme: Scheme) Error!Frame {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.needsRebuildLocked(zoom, scheme)) try self.buildLocked(zoom, scheme);
        return .{ .verts = self.verts.items, .generation = self.gen };
    }

    fn buildLocked(self: *Store, zoom: f64, scheme: Scheme) Error!void {
        self.verts.clearRetainingCapacity();
        const wpp = worldPerPt(zoom);
        // Paint order: areas, then lines, then symbols. A track must not cover
        // the boat, and a warning area must not cover either.
        for ([3]Kind{ .polygon, .polyline, .symbol }) |pass| {
            for (self.objs.values()) |*o| {
                if (o.kind != pass) continue;
                var c = resolve(o.token, scheme);
                switch (o.kind) {
                    .polygon => {
                        c[3] *= o.alpha;
                        try self.emitPolygon(o.pts, c);
                    },
                    .polyline => try self.emitPolyline(o.pts, @as(f64, o.width_pt) * wpp, o.dash, wpp, c),
                    .symbol => try self.emitSymbol(o, wpp, c),
                }
            }
        }
        self.gen += 1;
        self.dirty = false;
        self.has_build = true;
        self.built_zoom = zoom;
        self.built_scheme = scheme;
    }

    fn push(self: *Store, w: camera.Vec2, c: Rgba) Error!void {
        try self.verts.append(self.alloc, .{
            .x = @floatCast(w.x),
            .y = @floatCast(w.y),
            .r = c[0],
            .g = c[1],
            .b = c[2],
            .a = c[3],
        });
    }

    fn tri(self: *Store, a: camera.Vec2, b: camera.Vec2, d: camera.Vec2, c: Rgba) Error!void {
        try self.push(a, c);
        try self.push(b, c);
        try self.push(d, c);
    }

    /// Fan-triangulate a ring. Convex assumption (prototype): a concave ring
    /// draws its hull's wedges too.
    fn emitPolygon(self: *Store, pts: [][2]f64, c: Rgba) Error!void {
        if (pts.len < 3) return;
        const a = geo(pts[0]);
        var i: usize = 1;
        while (i + 1 < pts.len) : (i += 1) {
            try self.tri(a, geo(pts[i]), geo(pts[i + 1]), c);
        }
    }

    /// One quad per segment, `w_world` wide, mitre-less: at prototype line
    /// widths (1–3 pt) a butt join is invisible, and a mitre needs a join pass
    /// that would double the vertex count.
    fn emitPolyline(self: *Store, pts: [][2]f64, w_world: f64, dash: bool, wpp: f64, c: Rgba) Error!void {
        if (pts.len < 2) return;
        const hw = w_world * 0.5;
        const on = DASH_ON * wpp;
        const period = (DASH_ON + DASH_OFF) * wpp;
        var phase: f64 = 0; // distance along the whole line, so dashes run through vertices
        var i: usize = 0;
        while (i + 1 < pts.len) : (i += 1) {
            const a = geo(pts[i]);
            const b = geo(pts[i + 1]);
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const len = @sqrt(dx * dx + dy * dy);
            if (!(len > 0)) continue;
            // Draw solid when the pattern cannot show: a zero or absent period, or
            // a segment so long at this zoom that its dashes are sub-pixel — the
            // cut loop would otherwise emit millions of invisible quads.
            const solid = !dash or !(period > 0) or len / period > MAX_DASHES_PER_SEG;
            if (solid) {
                try self.quad(a, b, dx / len, dy / len, hw, c);
                phase += len;
                continue;
            }
            // Walk the segment, cutting at the dash boundaries. Every step must
            // ADVANCE: a run shorter than d's own ULP leaves d unchanged, and
            // the loop then never ends (seen as an out-of-memory kill, not a
            // hang, because each turn appends a quad).
            var d: f64 = 0;
            while (d < len) {
                const cyc = @mod(phase + d, period);
                const run = @min(if (cyc < on) on - cyc else period - cyc, len - d);
                if (!(run > 0)) break;
                if (cyc < on) {
                    const p0 = camera.Vec2{ .x = a.x + dx * (d / len), .y = a.y + dy * (d / len) };
                    const p1 = camera.Vec2{ .x = a.x + dx * ((d + run) / len), .y = a.y + dy * ((d + run) / len) };
                    try self.quad(p0, p1, dx / len, dy / len, hw, c);
                }
                const next = d + run;
                if (!(next > d)) break;
                d = next;
            }
            phase += len;
        }
    }

    fn quad(self: *Store, a: camera.Vec2, b: camera.Vec2, ux: f64, uy: f64, hw: f64, c: Rgba) Error!void {
        const nx = -uy * hw;
        const ny = ux * hw;
        const p0 = camera.Vec2{ .x = a.x + nx, .y = a.y + ny };
        const p1 = camera.Vec2{ .x = b.x + nx, .y = b.y + ny };
        const p2 = camera.Vec2{ .x = b.x - nx, .y = b.y - ny };
        const p3 = camera.Vec2{ .x = a.x - nx, .y = a.y - ny };
        try self.tri(p0, p1, p2, c);
        try self.tri(p0, p2, p3, c);
    }

    fn emitSymbol(self: *Store, o: *const Object, wpp: f64, c: Rgba) Error!void {
        const at = geo(o.at);
        const s = wpp * @as(f64, o.scale);
        // True bearing -> world direction: world y runs SOUTH, so north is -y.
        const th = @as(f64, o.rot_deg) * std.math.pi / 180.0;
        const fx = std.math.sin(th); // unit vector along the heading
        const fy = -std.math.cos(th);
        switch (o.sym) {
            .ownship => {
                try self.ring(at, OWNSHIP_R_OUTER * s, OWNSHIP_STROKE * s, c);
                try self.ring(at, OWNSHIP_R_INNER * s, OWNSHIP_STROKE * s, c);
                // Bow notch: a filled wedge from the outer ring forward, the
                // only part of the symbol that shows which way the boat points.
                const px = -fy; // starboard unit vector
                const py = fx;
                const tip = camera.Vec2{ .x = at.x + fx * OWNSHIP_NOTCH_TIP * s, .y = at.y + fy * OWNSHIP_NOTCH_TIP * s };
                const l = camera.Vec2{
                    .x = at.x + fx * OWNSHIP_NOTCH_BASE * s - px * OWNSHIP_NOTCH_HALF * s,
                    .y = at.y + fy * OWNSHIP_NOTCH_BASE * s - py * OWNSHIP_NOTCH_HALF * s,
                };
                const r = camera.Vec2{
                    .x = at.x + fx * OWNSHIP_NOTCH_BASE * s + px * OWNSHIP_NOTCH_HALF * s,
                    .y = at.y + fy * OWNSHIP_NOTCH_BASE * s + py * OWNSHIP_NOTCH_HALF * s,
                };
                try self.tri(l, tip, r, c);
            },
            .target => {
                const px = -fy;
                const py = fx;
                const tip = camera.Vec2{ .x = at.x + fx * TARGET_TIP * s, .y = at.y + fy * TARGET_TIP * s };
                const l = camera.Vec2{
                    .x = at.x - fx * TARGET_TAIL * s - px * TARGET_HALF * s,
                    .y = at.y - fy * TARGET_TAIL * s - py * TARGET_HALF * s,
                };
                const r = camera.Vec2{
                    .x = at.x - fx * TARGET_TAIL * s + px * TARGET_HALF * s,
                    .y = at.y - fy * TARGET_TAIL * s + py * TARGET_HALF * s,
                };
                try self.tri(l, tip, r, c);
            },
        }
    }

    /// A stroked circle of radius `r`, `w` wide, as CIRCLE_SEGS quads.
    fn ring(self: *Store, at: camera.Vec2, r: f64, w: f64, c: Rgba) Error!void {
        const ri = r - w * 0.5;
        const ro = r + w * 0.5;
        var i: usize = 0;
        while (i < CIRCLE_SEGS) : (i += 1) {
            const a0 = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / CIRCLE_SEGS;
            const a1 = 2.0 * std.math.pi * @as(f64, @floatFromInt(i + 1)) / CIRCLE_SEGS;
            const c0 = std.math.cos(a0);
            const s0 = std.math.sin(a0);
            const c1 = std.math.cos(a1);
            const s1 = std.math.sin(a1);
            const in0 = camera.Vec2{ .x = at.x + c0 * ri, .y = at.y + s0 * ri };
            const out0 = camera.Vec2{ .x = at.x + c0 * ro, .y = at.y + s0 * ro };
            const in1 = camera.Vec2{ .x = at.x + c1 * ri, .y = at.y + s1 * ri };
            const out1 = camera.Vec2{ .x = at.x + c1 * ro, .y = at.y + s1 * ro };
            try self.tri(in0, out0, out1, c);
            try self.tri(in0, out1, in1, c);
        }
    }
};

/// lon/lat -> web-mercator world [0,1]. The chart's own transform: overlay
/// geometry and chart geometry must land in the same space to the last bit.
pub fn geo(lonlat: [2]f64) camera.Vec2 {
    return camera.lonLatToWorld(lonlat[0], lonlat[1]);
}

/// World units per screen POINT at `zoom` — 256 px per tile, the reciprocal of
/// camera.worldToPx (whose vw/vh are logical points, so this is too).
pub fn worldPerPt(zoom: f64) f64 {
    return 1.0 / (256.0 * std.math.pow(f64, 2.0, zoom));
}

// ---- JSON helpers ----------------------------------------------------------

fn jstr(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn jnum(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn jbool(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// `[lon, lat]`, both finite and in range.
fn jpoint(v: std.json.Value) ?[2]f64 {
    if (v != .array or v.array.items.len < 2) return null;
    const lon = jnum(v.array.items[0]) orelse return null;
    const lat = jnum(v.array.items[1]) orelse return null;
    if (!std.math.isFinite(lon) or !std.math.isFinite(lat)) return null;
    if (@abs(lon) > 360 or @abs(lat) > 85.06) return null;
    return .{ lon, lat };
}

// ---- tests -----------------------------------------------------------------

const t = std.testing;

test "geo matches camera.zig and known mercator values" {
    // Hand-computed web-mercator for Annapolis harbour and the origin.
    const a = geo(.{ -76.4767, 38.9763 });
    try t.expectApproxEqAbs(@as(f64, 0.28756472222222224), a.x, 1e-15);
    try t.expectApproxEqAbs(@as(f64, 0.38226387137161233), a.y, 1e-15);
    const o = geo(.{ 0, 0 });
    try t.expectApproxEqAbs(@as(f64, 0.5), o.x, 1e-15);
    try t.expectApproxEqAbs(@as(f64, 0.5), o.y, 1e-15);
    // ...and it IS the camera's transform, for every point the prototype uses.
    for ([_][2]f64{ .{ -76.4767, 38.9763 }, .{ -76.48, 38.98 }, .{ 179.9, -35.2 }, .{ 0, 0 } }) |p| {
        const g = geo(p);
        const cw = camera.lonLatToWorld(p[0], p[1]);
        try t.expectEqual(cw.x, g.x);
        try t.expectEqual(cw.y, g.y);
    }
}

test "apply set/del and per-source namespacing" {
    var s = Store.init(t.allocator);
    defer s.deinit();

    try s.applyBatch("plug.a",
        \\{"set":[{"id":"boat","kind":"symbol","sym":"ownship","at":[-76.48,38.98],"rot_deg":90,"color":"ownship"}]}
    );
    try s.applyBatch("plug.b",
        \\{"set":[{"id":"boat","kind":"symbol","sym":"target","at":[-76.47,38.97],"color":"target"}]}
    );
    // Same object id, different sources: two objects, not one.
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expect(s.objs.contains("plug.a/boat"));
    try t.expect(s.objs.contains("plug.b/boat"));

    // A set with a known id REPLACES.
    try s.applyBatch("plug.a",
        \\{"set":[{"id":"boat","kind":"symbol","sym":"target","at":[-76.40,38.90],"color":"target_danger"}]}
    );
    try t.expectEqual(@as(usize, 2), s.count());
    try t.expectEqual(Token.target_danger, s.objs.get("plug.a/boat").?.token);

    // del is namespaced too: plug.b cannot delete plug.a's object.
    try s.applyBatch("plug.b", "{\"del\":[\"boat\"]}");
    try t.expectEqual(@as(usize, 1), s.count());
    try t.expect(s.objs.contains("plug.a/boat"));

    // removeSource takes everything that source owns.
    try s.applyBatch("plug.a",
        \\{"set":[{"id":"trk","kind":"polyline","pts":[[-76.5,38.9],[-76.4,38.95]],"width_pt":2,"color":"track"}]}
    );
    try t.expectEqual(@as(usize, 2), s.count());
    s.removeSource("plug.a");
    try t.expectEqual(@as(usize, 0), s.count());
}

test "malformed rows are skipped, malformed batches rejected" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try t.expectError(Error.BadBatch, s.applyBatch("p", "not json"));
    try t.expectError(Error.BadBatch, s.applyBatch("p", "[1,2]"));
    // Unknown colour token, unknown kind, missing geometry, bad point: all
    // dropped; the good row in the same batch survives.
    try s.applyBatch("p",
        \\{"set":[
        \\ {"id":"a","kind":"symbol","sym":"ownship","at":[-76.4,38.9],"color":"chartreuse"},
        \\ {"id":"b","kind":"hologram","color":"warning"},
        \\ {"id":"c","kind":"polyline","color":"track"},
        \\ {"id":"d","kind":"polyline","pts":[[-76.4,38.9],[-999,38.9]],"color":"track"},
        \\ {"id":"e","kind":"symbol","sym":"target","at":[-76.4,38.9],"color":"target"}]}
    );
    try t.expectEqual(@as(usize, 1), s.count());
    try t.expect(s.objs.contains("p/e"));
}

test "symbol expansion vertex counts and orientation" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"o","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],"rot_deg":0,"color":"ownship"}]}
    );
    var fr = try s.buildIfNeeded(15.0, .day);
    try t.expectEqual(@as(usize, OWNSHIP_VERTS), fr.verts.len);
    try t.expectEqual(@as(usize, 291), fr.verts.len);

    // The bow notch is the last triangle; heading 0 (north) puts its apex ABOVE
    // the anchor, which in world space (y down) is a SMALLER y.
    const at = geo(.{ -76.4767, 38.9763 });
    const tip_n = fr.verts[fr.verts.len - 2];
    try t.expect(@as(f64, tip_n.y) < at.y);
    try t.expectApproxEqAbs(@as(f32, @floatCast(at.x)), tip_n.x, 1e-9);

    // Heading 90 (east) puts it to the RIGHT, at the same latitude.
    try s.applyBatch("p",
        \\{"set":[{"id":"o","kind":"symbol","sym":"ownship","at":[-76.4767,38.9763],"rot_deg":90,"color":"ownship"}]}
    );
    fr = try s.buildIfNeeded(15.0, .day);
    const tip_e = fr.verts[fr.verts.len - 2];
    try t.expect(@as(f64, tip_e.x) > at.x);
    try t.expectApproxEqAbs(@as(f32, @floatCast(at.y)), tip_e.y, 1e-9);

    // A target is one triangle; two objects add up.
    try s.applyBatch("p",
        \\{"set":[{"id":"t1","kind":"symbol","sym":"target","at":[-76.47,38.97],"rot_deg":210,"color":"target"}]}
    );
    fr = try s.buildIfNeeded(15.0, .day);
    try t.expectEqual(@as(usize, OWNSHIP_VERTS + TARGET_VERTS), fr.verts.len);
}

test "a dashed line cannot run away" {
    // The cut loop advanced by the run length, which reaches zero at the end of
    // a segment and at a dash boundary; once a run falls below the ULP of the
    // distance walked, the walk stops advancing and appends quads forever. It
    // showed up in a real frame as the renderer being KILLED for memory rather
    // than as a hang, so it must be tested here, not found there again.
    var s = Store.init(t.allocator);
    defer s.deinit();

    // Zoom 22, a degree of longitude: ~250,000 dash cycles, every one of them
    // far under a pixel. Over the cap it draws solid — one quad, not a flood.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-77.0,38.9],[-76.0,38.9]],"dash":true,"color":"track"}]}
    );
    try t.expectEqual(@as(usize, 6), (try s.buildIfNeeded(22.0, .day)).verts.len);

    // Repeated and reversed points: zero-length segments, and a walk that has
    // to survive its own boundary arithmetic.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-76.48,38.98],[-76.48,38.98],[-76.4799,38.98],[-76.48,38.98]],"dash":true,"color":"track"}]}
    );
    const fr = try s.buildIfNeeded(17.0, .day);
    try t.expect(fr.verts.len > 0);
    try t.expectEqual(@as(usize, 0), fr.verts.len % 6);
}

test "polyline, dash and polygon expansion" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    // 3 points = 2 segments = 2 quads = 12 vertices.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-76.50,38.90],[-76.48,38.92],[-76.46,38.90]],"width_pt":2,"color":"track"}]}
    );
    var fr = try s.buildIfNeeded(15.0, .day);
    try t.expectEqual(@as(usize, 12), fr.verts.len);
    const solid = fr.verts.len;

    // The same line dashed covers the same run with MORE, shorter quads.
    try s.applyBatch("p",
        \\{"set":[{"id":"l","kind":"polyline","pts":[[-76.50,38.90],[-76.48,38.92],[-76.46,38.90]],"width_pt":2,"dash":true,"color":"track"}]}
    );
    fr = try s.buildIfNeeded(15.0, .day);
    try t.expect(fr.verts.len > solid);
    try t.expectEqual(@as(usize, 0), fr.verts.len % 6);

    // A 5-point ring fans to 3 triangles.
    s.removeSource("p");
    try s.applyBatch("p",
        \\{"set":[{"id":"z","kind":"polygon","ring":[[-76.5,38.9],[-76.4,38.9],[-76.4,39.0],[-76.45,39.05],[-76.5,39.0]],"alpha":0.25,"color":"warning"}]}
    );
    fr = try s.buildIfNeeded(15.0, .day);
    try t.expectEqual(@as(usize, 9), fr.verts.len);
    // The polygon's alpha multiplies the token's.
    try t.expectApproxEqAbs(@as(f32, 0.25), fr.verts[0].a, 1e-6);
}

test "token resolution per scheme" {
    // Every token resolves to something in range, in all three schemes, and no
    // two tokens collide within a scheme.
    for ([_]Scheme{ .day, .dusk, .night }) |sch| {
        var seen: [7]Rgba = undefined;
        for (std.enums.values(Token), 0..) |tok, i| {
            const c = resolve(tok, sch);
            for (c) |ch| try t.expect(ch >= 0 and ch <= 1);
            try t.expect(c[3] > 0);
            seen[i] = c;
            for (seen[0..i]) |prev| try t.expect(!std.mem.eql(u8, std.mem.asBytes(&prev), std.mem.asBytes(&c)));
        }
    }
    // Night must not be bright. The bound is on the sRGB-ENCODED luminance,
    // which is what a display emits before its own gamma: 0.35 encoded is ~0.09
    // of full linear output, dim enough not to reset a night-adapted eye while
    // still legible against the near-black night chart (#171e21).
    for (std.enums.values(Token)) |tok| {
        const n = resolve(tok, .night);
        const lum = 0.2126 * n[0] + 0.7152 * n[1] + 0.0722 * n[2];
        try t.expect(lum < 0.35);
    }
    // A token drives the built vertices' colour.
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"t","kind":"symbol","sym":"target","at":[-76.4,38.9],"color":"target_danger"}]}
    );
    const day = (try s.buildIfNeeded(15.0, .day)).verts[0];
    const want_day = resolve(.target_danger, .day);
    try t.expectEqual(want_day[0], day.r);
    const night = (try s.buildIfNeeded(15.0, .night)).verts[0];
    const want_night = resolve(.target_danger, .night);
    try t.expectEqual(want_night[0], night.r);
}

test "rebuild gating on zoom, scheme and apply" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"t","kind":"symbol","sym":"target","at":[-76.4,38.9],"color":"target"}]}
    );
    const g0 = (try s.buildIfNeeded(15.0, .day)).generation;
    // Same inputs: no rebuild, same generation, so the GPU never re-uploads.
    try t.expect(!s.needsRebuild(15.0, .day));
    try t.expectEqual(g0, (try s.buildIfNeeded(15.0, .day)).generation);
    // Under 5% of scale: still no rebuild.
    try t.expect(!s.needsRebuild(15.05, .day));
    // Over it: rebuild.
    try t.expect(s.needsRebuild(15.1, .day));
    const g1 = (try s.buildIfNeeded(15.1, .day)).generation;
    try t.expect(g1 > g0);
    // A scheme change rebuilds; so does an apply.
    try t.expect(s.needsRebuild(15.1, .night));
    _ = try s.buildIfNeeded(15.1, .night);
    try t.expect(!s.needsRebuild(15.1, .night));
    try s.applyBatch("p", "{\"del\":[\"t\"]}");
    try t.expect(s.needsRebuild(15.1, .night));
    try t.expectEqual(@as(usize, 0), (try s.buildIfNeeded(15.1, .night)).verts.len);
}

test "symbol size tracks the zoom" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    try s.applyBatch("p",
        \\{"set":[{"id":"t","kind":"symbol","sym":"target","rot_deg":0,"at":[-76.4,38.9],"color":"target"}]}
    );
    const at = geo(.{ -76.4, 38.9 });
    const a = (try s.buildIfNeeded(10.0, .day)).verts[1]; // the apex
    const b = (try s.buildIfNeeded(11.0, .day)).verts[1];
    // One zoom level in = half the world size, so the symbol keeps its point
    // size. Tolerance is set by the f32 vertex grid, not the math: world x is
    // ~0.29 there, where an f32 step is 3e-8 — about 0.1% of a 6.5 pt offset at
    // zoom 10, and proportionally more the further in the view goes.
    const da = at.y - @as(f64, a.y);
    const db = at.y - @as(f64, b.y);
    try t.expectApproxEqRel(da, db * 2.0, 5e-3);
    try t.expectApproxEqRel(TARGET_TIP * worldPerPt(10.0), da, 5e-3);
}

test "object budget is enforced" {
    var s = Store.init(t.allocator);
    defer s.deinit();
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i <= MAX_OBJECTS) : (i += 1) {
        const json = try std.fmt.bufPrint(&buf,
            \\{{"set":[{{"id":"t{d}","kind":"symbol","sym":"target","at":[-76.4,38.9],"color":"target"}}]}}
        , .{i});
        s.applyBatch("p", json) catch |e| {
            try t.expectEqual(Error.Budget, e);
            try t.expectEqual(@as(usize, MAX_OBJECTS), s.count());
            return;
        };
    }
    try t.expect(false); // the cap must have fired
}
