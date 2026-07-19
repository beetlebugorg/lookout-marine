//! Build phase (spec §6): drive tile57_chart_surface with RECORDING callbacks,
//! tessellate everything to triangles ONCE in web-mercator space, and pack a
//! single interleaved vertex stream + one color stream per palette. Runs on
//! chart load / view change only — never per frame.
//!
//! Key ABI facts this relies on (see NOTES.md): geometry is identical across
//! color schemes, so we tessellate on the first (day) pass and only re-collect
//! per-draw-call colors on later passes; symbols/soundings/text arrive as
//! pre-tessellated outline rings (draw_sprite/draw_pattern/draw_text_str left
//! NULL); soundings ride draw_symbol with cls=="SOUNDG"; the stream is NOT paint
//! sorted, so we sort by (class-major, plane, seq) mirroring pixel.zig.
const std = @import("std");
const cc = @import("c.zig").c;
const camera = @import("camera.zig");
const atlas = @import("atlas.zig");

pub const MAX_SCHEMES = 3;

/// Textured-quad vertex for sprite symbols (and later SDF text). 28 bytes.
/// One vertex of a pattern-filled polygon: the tessellated position in world
/// space, plus the atlas cell to tile over it and that cell's size in PHYSICAL
/// px (device density folded in at build time, since the fragment shader tiles
/// against gl_FragCoord which is in framebuffer px).
pub const PatternVertex = extern struct {
    wx: f32,
    wy: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    cw: f32,
    ch: f32,
};

pub const QuadVertex = extern struct {
    wx: f32,
    wy: f32,
    lx: f32,
    ly: f32,
    u: f32,
    v: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
    /// SDF stroke weight: 0 = normal, >0 embolden. S-52 "important text"
    /// (group 11) is drawn heavier so it reads over a busy chart. Sprites
    /// leave it 0 — sprite.frag ignores it.
    weight: f32 = 0,
};

/// One GPU vertex. `world` is camera-relative web-mercator (f32, origin
/// pre-subtracted); `local` is a reference-px offset the shader adds in screen
/// space (0 for area/line; ± half-width for lines; glyph/symbol px for marks).
pub const Vertex = extern struct {
    wx: f32,
    wy: f32,
    lx: f32,
    ly: f32,
    scamin: f32,
    flags: u32,
};
pub const Color = extern struct { r: u8, g: u8, b: u8, a: u8 };

// paint-order class == shader kind (they share the numbering, conveniently)
const CLASS_AREA: u8 = 0;
const CLASS_LINE: u8 = 1;
const CLASS_SYMBOL: u8 = 2;
const CLASS_SOUNDING: u8 = 3;
const CLASS_TEXT: u8 = 4;

fn packFlags(disp_cat: u32, kind: u8, map_align: bool) u32 {
    return (disp_cat & 3) | (@as(u32, kind) << 2) | (@as(u32, @intFromBool(map_align)) << 5);
}

const DrawItem = struct {
    class: u8,
    plane: i32,
    seq: u32,
    vtx_first: u32,
    vtx_count: u32,
    idx_first: u32, // into temp idx list
    idx_count: u32,
    colors: [MAX_SCHEMES]Color,
};

pub const Scene = struct {
    a: std.mem.Allocator,
    origin: camera.Vec2, // fixed world reference; verts are relative to it

    verts: std.ArrayList(Vertex),
    idx_tmp: std.ArrayList(u32), // per-item ranges, unsorted
    items: std.ArrayList(DrawItem),
    scratch: std.ArrayList(f32), // reusable f32 point scratch for tessellation
    tess: ?*cc.TESStesselator,

    // recorder state
    mode_full: bool,
    scheme_k: usize,
    color_counter: usize,
    /// SCAMIN cull: features whose 1:N min-display-scale denominator is finer
    /// than this view's display scale are NOT tessellated (they wouldn't show at
    /// this zoom). 0 = tessellate everything. This is what keeps a zoomed-out
    /// view from tessellating the whole library's fine detail.
    cull_scale: f32 = 0,
    /// Reference px per world unit at the scale this scene is built for
    /// (256 * 2^z). Dash patterns arrive in screen px but the geometry is
    /// world-space, so this is what converts between them.
    px_per_world: f32 = 256.0,
    tess_ns: u64 = 0, // time spent in libtess2 (to profile tessellation vs engine)

    // sprite symbols: textured quads (no tessellation), one shared atlas
    quads: std.ArrayList(QuadVertex) = .empty,
    sprite_atlas: ?*const atlas.SpriteAtlas = null,
    // SDF text: textured quads sampling the glyph atlas
    text_quads: std.ArrayList(QuadVertex) = .empty,
    pattern_verts: std.ArrayList(PatternVertex) = .empty,
    /// One entry per SPRITE QUAD (6 verts): layer*1000 + S-52 draw priority.
    /// tile57 streams features in walk order and tags each with `plane`; a host
    /// that re-buckets them into its own batches has to restore paint order
    /// itself, which is what finish() does with this.
    quad_planes: std.ArrayList(i32) = .empty,
    /// Physical px per reference px (HiDPI density), folded into pattern cell
    /// sizes so screen-space tiling matches the framebuffer.
    density: f32 = 1.0,
    glyph_atlas: ?*const atlas.GlyphAtlas = null,

    // built outputs (after finish)
    indices: []u32 = &.{}, // final paint-ordered index buffer
    scheme_colors: [MAX_SCHEMES][]Color = .{ &.{}, &.{}, &.{} },
    n_schemes: usize = 0,

    pub fn init(a: std.mem.Allocator, origin: camera.Vec2) !Scene {
        return .{
            .a = a,
            .origin = origin,
            .verts = .empty,
            .idx_tmp = .empty,
            .items = .empty,
            .scratch = .empty,
            .tess = cc.tessNewTess(null),
            .mode_full = true,
            .scheme_k = 0,
            .color_counter = 0,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.verts.deinit(self.a);
        self.idx_tmp.deinit(self.a);
        self.items.deinit(self.a);
        self.scratch.deinit(self.a);
        self.quads.deinit(self.a);
        self.text_quads.deinit(self.a);
        self.pattern_verts.deinit(self.a);
        self.quad_planes.deinit(self.a);
        if (self.tess) |t| cc.tessDeleteTess(t);
        if (self.indices.len != 0) self.a.free(self.indices);
        for (0..MAX_SCHEMES) |k| if (self.scheme_colors[k].len != 0) self.a.free(self.scheme_colors[k]);
    }

    fn relX(self: *Scene, wx: f64) f32 {
        return @floatCast(wx - self.origin.x);
    }
    fn relY(self: *Scene, wy: f64) f32 {
        return @floatCast(wy - self.origin.y);
    }

    // ---- tessellation (libtess2) -------------------------------------------
    // Tessellate a set of 2D contours to triangles. Returns triangle indices
    // into the returned vertex slice (both valid until the next tess call).
    const TessOut = struct { verts: [*c]const f32, nverts: usize, elems: [*c]const c_int, nelems: usize };
    fn tessContours(self: *Scene, pts: []const f32, ring_starts: []const u32, ring_count: u32, even_odd: bool) ?TessOut {
        const t = self.tess orelse return null;
        const t0 = cc.SDL_GetPerformanceCounter();
        defer self.tess_ns += cc.SDL_GetPerformanceCounter() - t0;
        var r: u32 = 0;
        while (r < ring_count) : (r += 1) {
            const start = ring_starts[r];
            const end = if (r + 1 < ring_count) ring_starts[r + 1] else @as(u32, @intCast(pts.len / 2));
            const count = end - start;
            if (count < 3) continue;
            cc.tessAddContour(t, 2, &pts[start * 2], @sizeOf(f32) * 2, @intCast(count));
        }
        const rule: c_int = if (even_odd) cc.TESS_WINDING_ODD else cc.TESS_WINDING_NONZERO;
        if (cc.tessTesselate(t, rule, cc.TESS_POLYGONS, 3, 2, null) == 0) return null;
        return .{
            .verts = cc.tessGetVertices(t),
            .nverts = @intCast(cc.tessGetVertexCount(t)),
            .elems = cc.tessGetElements(t),
            .nelems = @intCast(cc.tessGetElementCount(t)),
        };
    }

    // Append tessellated triangles as vertices+indices. `anchored`: if true the
    // tess points become the LOCAL px offset and every vertex shares `wrel`;
    // else the tess points ARE the world-relative position (local = 0).
    fn appendTess(self: *Scene, out: TessOut, anchored: bool, wrel: [2]f32, scamin: f32, flags: u32, item: *DrawItem) !void {
        const base: u32 = @intCast(self.verts.items.len);
        const UNDEF: c_int = ~@as(c_int, 0); // TESS_UNDEF
        var i: usize = 0;
        while (i < out.nverts) : (i += 1) {
            const px = out.verts[i * 2];
            const py = out.verts[i * 2 + 1];
            try self.verts.append(self.a, .{
                .wx = if (anchored) wrel[0] else px,
                .wy = if (anchored) wrel[1] else py,
                .lx = if (anchored) px else 0,
                .ly = if (anchored) py else 0,
                .scamin = scamin,
                .flags = flags,
            });
        }
        var e: usize = 0;
        while (e < out.nelems) : (e += 1) {
            const a0 = out.elems[e * 3];
            const b0 = out.elems[e * 3 + 1];
            const c0 = out.elems[e * 3 + 2];
            if (a0 == UNDEF or b0 == UNDEF or c0 == UNDEF) continue;
            try self.idx_tmp.append(self.a, base + @as(u32, @intCast(a0)));
            try self.idx_tmp.append(self.a, base + @as(u32, @intCast(b0)));
            try self.idx_tmp.append(self.a, base + @as(u32, @intCast(c0)));
        }
        item.vtx_count = @as(u32, @intCast(self.verts.items.len)) - item.vtx_first;
        item.idx_count = @as(u32, @intCast(self.idx_tmp.items.len)) - item.idx_first;
    }

    // ---- line stroking (own; libtess2 doesn't stroke) ----------------------
    // Centerline stays world-relative; half-width goes in the LOCAL px channel
    // along the world-space normal, so the line holds a constant screen width
    // (isotropic-scale approximation — see NOTES.md §4). One quad per segment
    // with a simple miter join.
    fn strokePolyline(self: *Scene, pts: []const f32, ring_starts: []const u32, ring_count: u32, half_px: f32, scamin: f32, flags: u32, anchored: bool, wrel: [2]f32, item: *DrawItem) !void {
        return self.strokePolylineDashed(pts, ring_starts, ring_count, half_px, 0, 0, scamin, flags, anchored, wrel, item);
    }

    /// Stroke a polyline, honouring an S-52 dash pattern. `dash_on`/`dash_off`
    /// are SCREEN px (0 off = solid); the run is walked in world units via
    /// px_per_world so the pattern keeps its screen length at the scale this
    /// scene is built for. The phase carries across segments so a dash spans a
    /// corner instead of restarting at every vertex.
    fn strokePolylineDashed(self: *Scene, pts: []const f32, ring_starts: []const u32, ring_count: u32, half_px: f32, dash_on: f32, dash_off: f32, scamin: f32, flags: u32, anchored: bool, wrel: [2]f32, item: *DrawItem) !void {
        const ppw = if (self.px_per_world > 0) self.px_per_world else 256.0;
        const on_w = dash_on / ppw;
        const off_w = dash_off / ppw;
        const period = on_w + off_w;
        const dashed = dash_off > 0 and dash_on > 0 and period > 0;
        var r: u32 = 0;
        while (r < ring_count) : (r += 1) {
            const start = ring_starts[r];
            const end = if (r + 1 < ring_count) ring_starts[r + 1] else @as(u32, @intCast(pts.len / 2));
            if (end - start < 2) continue;
            var phase: f32 = 0;
            var i: u32 = start;
            while (i + 1 < end) : (i += 1) {
                const ax = pts[i * 2];
                const ay = pts[i * 2 + 1];
                const bx = pts[(i + 1) * 2];
                const by = pts[(i + 1) * 2 + 1];
                var dx = bx - ax;
                var dy = by - ay;
                const len = @sqrt(dx * dx + dy * dy);
                if (len < 1e-12) continue;
                dx /= len;
                dy /= len;
                const nx = -dy * half_px; // normal * half width (px)
                const ny = dx * half_px;
                if (!dashed) {
                    try self.emitSegQuad(anchored, wrel, ax, ay, bx, by, nx, ny, scamin, flags);
                    continue;
                }
                var t: f32 = 0;
                while (t < len) {
                    const in_period = @mod(phase, period);
                    const is_on = in_period < on_w;
                    const left = if (is_on) on_w - in_period else period - in_period;
                    const step = @min(@max(left, 1e-9), len - t);
                    if (is_on) {
                        const sx = ax + dx * t;
                        const sy = ay + dy * t;
                        const ex = ax + dx * (t + step);
                        const ey = ay + dy * (t + step);
                        try self.emitSegQuad(anchored, wrel, sx, sy, ex, ey, nx, ny, scamin, flags);
                    }
                    t += step;
                    phase += step;
                }
            }
        }
        item.vtx_count = @as(u32, @intCast(self.verts.items.len)) - item.vtx_first;
        item.idx_count = @as(u32, @intCast(self.idx_tmp.items.len)) - item.idx_first;
    }
    fn emitSegQuad(self: *Scene, anchored: bool, wrel: [2]f32, ax: f32, ay: f32, bx: f32, by: f32, nx: f32, ny: f32, scamin: f32, flags: u32) !void {
        // 4 corners: a+n, b+n, b-n, a-n
        const base: u32 = @intCast(self.verts.items.len);
        try self.pushLineVtx(anchored, wrel, ax, ay, nx, ny, scamin, flags);
        try self.pushLineVtx(anchored, wrel, bx, by, nx, ny, scamin, flags);
        try self.pushLineVtx(anchored, wrel, bx, by, -nx, -ny, scamin, flags);
        try self.pushLineVtx(anchored, wrel, ax, ay, -nx, -ny, scamin, flags);
        for ([_]u32{ 0, 1, 2, 0, 2, 3 }) |o| try self.idx_tmp.append(self.a, base + o);
    }

    fn pushLineVtx(self: *Scene, anchored: bool, wrel: [2]f32, cx: f32, cy: f32, nx: f32, ny: f32, scamin: f32, flags: u32) !void {
        // world = centerline point; local = normal px offset. For anchored
        // (symbol-stroke) both the base point and offset are px in local.
        try self.verts.append(self.a, .{
            .wx = if (anchored) wrel[0] else cx,
            .wy = if (anchored) wrel[1] else cy,
            .lx = if (anchored) cx + nx else nx,
            .ly = if (anchored) cy + ny else ny,
            .scamin = scamin,
            .flags = flags,
        });
    }

    fn newItem(self: *Scene, class: u8, plane: i32, color: Color) !*DrawItem {
        const seq: u32 = @intCast(self.items.items.len);
        try self.items.append(self.a, .{
            .class = class,
            .plane = plane,
            .seq = seq,
            .vtx_first = @intCast(self.verts.items.len),
            .vtx_count = 0,
            .idx_first = @intCast(self.idx_tmp.items.len),
            .idx_count = 0,
            .colors = .{ color, color, color },
        });
        return &self.items.items[self.items.items.len - 1];
    }

    fn scaminF(s: i64) f32 {
        return if (s <= 0) 0 else @floatFromInt(s);
    }
    /// Unpack tile57's 0xRRGGBBAA scalar (see tile57_color in tile57.h — it is
    /// a scalar because a small extern struct by value is miscompiled across
    /// callconv(.c) in optimized builds).
    fn rgba(c: cc.tile57_color) Color {
        return .{
            .r = @truncate(c >> 24),
            .g = @truncate(c >> 16),
            .b = @truncate(c >> 8),
            .a = @truncate(c),
        };
    }

    // Convert a tile57_world_rings to the reusable f32 scratch (world-relative).
    fn worldToScratch(self: *Scene, rings: *const cc.tile57_world_rings) !void {
        self.scratch.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < rings.n) : (i += 1) {
            try self.scratch.append(self.a, self.relX(rings.pts[i].x));
            try self.scratch.append(self.a, self.relY(rings.pts[i].y));
        }
    }
    fn localToScratch(self: *Scene, rings: *const cc.tile57_local_rings) !void {
        self.scratch.clearRetainingCapacity();
        var i: u32 = 0;
        while (i < rings.n) : (i += 1) {
            try self.scratch.append(self.a, rings.pts[i].x);
            try self.scratch.append(self.a, rings.pts[i].y);
        }
    }
    fn ringStartsSlice(rings_ring_starts: [*c]const u32, ring_count: u32) []const u32 {
        return rings_ring_starts[0..ring_count];
    }

    // ---- finish: sort into paint order, build final buffers ----------------
    /// Stable-sort whole sprite quads (6 verts each) by their feature's draw
    /// priority. Stability matters: within one plane the engine's walk order IS
    /// the intended order, so only the priority may reorder them.
    fn sortQuadsByPlane(self: *Scene) !void {
        const nq = self.quad_planes.items.len;
        if (nq < 2 or self.quads.items.len != nq * 6) return;
        const order = try self.a.alloc(u32, nq);
        defer self.a.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        const planes = self.quad_planes.items;
        std.mem.sortUnstable(u32, order, planes, struct {
            fn lt(p: []const i32, l: u32, r: u32) bool {
                if (p[l] != p[r]) return p[l] < p[r];
                return l < r; // ties keep walk order -> stable
            }
        }.lt);
        const src = try self.a.alloc(QuadVertex, self.quads.items.len);
        defer self.a.free(src);
        @memcpy(src, self.quads.items);
        for (order, 0..) |from, to| {
            @memcpy(self.quads.items[to * 6 ..][0..6], src[@as(usize, from) * 6 ..][0..6]);
        }
    }

    pub fn finish(self: *Scene, n_schemes: usize) !void {
        self.n_schemes = n_schemes;
        // stable sort by (class-major, plane, seq) — mirror pixel.zig:549.
        std.mem.sort(DrawItem, self.items.items, {}, struct {
            fn lt(_: void, l: DrawItem, r: DrawItem) bool {
                if (l.class != r.class) return l.class < r.class;
                if (l.plane != r.plane) return l.plane < r.plane;
                return l.seq < r.seq;
            }
        }.lt);
        // Sprites bypass DrawItem (they are their own textured pass), so restore
        // S-52 paint order here: stable-sort the quads by the feature plane each
        // was tagged with. Without this a low-priority symbol drawn later in the
        // walk covers a high-priority one — lights under wrecks.
        try self.sortQuadsByPlane();
        // final index buffer: concatenate each item's temp index range in order.
        var total_idx: usize = 0;
        for (self.items.items) |it| total_idx += it.idx_count;
        const idx = try self.a.alloc(u32, total_idx);
        var w: usize = 0;
        for (self.items.items) |it| {
            @memcpy(idx[w .. w + it.idx_count], self.idx_tmp.items[it.idx_first .. it.idx_first + it.idx_count]);
            w += it.idx_count;
        }
        self.indices = idx;
        // per-scheme color buffers (per vertex).
        const nv = self.verts.items.len;
        for (0..n_schemes) |k| {
            const cbuf = try self.a.alloc(Color, nv);
            for (self.items.items) |it| {
                var v = it.vtx_first;
                while (v < it.vtx_first + it.vtx_count) : (v += 1) cbuf[v] = it.colors[k];
            }
            self.scheme_colors[k] = cbuf;
        }
    }

    pub fn triangleCount(self: *Scene) usize {
        return self.indices.len / 3;
    }
};

// ======================= recording callbacks ================================
// Full-mode table (pass 0): tessellate + record geometry + scheme-0 color.

fn asScene(ctx: ?*anyopaque) *Scene {
    return @ptrCast(@alignCast(ctx.?));
}
fn clsIs(f: [*c]const cc.tile57_feature, name: []const u8) bool {
    const p = f.*.cls;
    if (p == null) return false;
    return std.mem.eql(u8, std.mem.span(p), name);
}
// Skip features that SCAMIN-out at this view's zoom, so a zoomed-out build never
// tessellates fine detail. Deterministic, so the full and color passes agree.
fn scaminCulled(s: *Scene, f: [*c]const cc.tile57_feature) bool {
    if (s.cull_scale <= 0) return false;
    const sc = f.*.scamin;
    if (sc <= 0) return false;
    if (@as(u32, @intCast(f.*.disp_cat)) == 0) return false; // BASE is never SCAMIN-culled
    return s.cull_scale > @as(f32, @floatFromInt(sc));
}

fn fFillArea(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, rings: [*c]const cc.tile57_world_rings, color: cc.tile57_color, even_odd: c_int) callconv(.c) void {
    const s = asScene(ctx);
    if (scaminCulled(s, f)) return;
    const item = s.newItem(CLASS_AREA, f.*.plane, Scene.rgba(color)) catch return;
    const dc: u32 = @intCast(f.*.disp_cat);
    const flags = packFlags(dc, CLASS_AREA, false);
    s.worldToScratch(rings) catch return;
    if (s.tessContours(s.scratch.items, Scene.ringStartsSlice(rings.*.ring_starts, rings.*.ring_count), rings.*.ring_count, even_odd != 0)) |out| {
        s.appendTess(out, false, .{ 0, 0 }, Scene.scaminF(f.*.scamin), flags, item) catch return;
    }
}

// S-52 area fill pattern (AP): tile a cell from the shared sprite atlas across
// the polygon. Without this the engine falls back to a flat tint, which loses
// the distinction between e.g. dredged, foul and quality-of-data areas.
fn fDrawPattern(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, name: [*c]const u8, name_len: usize, rings: [*c]const cc.tile57_world_rings) callconv(.c) void {
    const s = asScene(ctx);
    if (scaminCulled(s, f)) return;
    const sa = s.sprite_atlas orelse return;
    if (name == null or name_len == 0) return;
    const raw = name[0..name_len];
    // the engine may hand the name with or without the atlas's "pat:" prefix
    const cell = sa.lookup(raw) orelse blk: {
        var buf: [128]u8 = undefined;
        if (raw.len + 4 > buf.len) return;
        @memcpy(buf[0..4], "pat:");
        @memcpy(buf[4..][0..raw.len], raw);
        break :blk sa.lookup(buf[0 .. raw.len + 4]) orelse return;
    };
    const aw: f32 = @floatFromInt(sa.width);
    const ah: f32 = @floatFromInt(sa.height);
    s.worldToScratch(rings) catch return;
    const out = s.tessContours(s.scratch.items, Scene.ringStartsSlice(rings.*.ring_starts, rings.*.ring_count), rings.*.ring_count, false) orelse return;
    const UNDEF: c_int = ~@as(c_int, 0);
    const pv = PatternVertex{
        .wx = 0,
        .wy = 0,
        .u0 = cell.x / aw,
        .v0 = cell.y / ah,
        .u1 = (cell.x + cell.w) / aw,
        .v1 = (cell.y + cell.h) / ah,
        .cw = cell.w * s.density,
        .ch = cell.h * s.density,
    };
    var e: usize = 0;
    while (e < out.nelems) : (e += 1) {
        const tri = [3]c_int{ out.elems[e * 3], out.elems[e * 3 + 1], out.elems[e * 3 + 2] };
        if (tri[0] == UNDEF or tri[1] == UNDEF or tri[2] == UNDEF) continue;
        for (tri) |idx| {
            var v = pv;
            v.wx = out.verts[@as(usize, @intCast(idx)) * 2];
            v.wy = out.verts[@as(usize, @intCast(idx)) * 2 + 1];
            s.pattern_verts.append(s.a, v) catch return;
        }
    }
}

fn fStrokeLine(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, lines: [*c]const cc.tile57_world_rings, width_px: f32, dash_on: f32, dash_off: f32, color: cc.tile57_color) callconv(.c) void {
    const s = asScene(ctx);
    if (scaminCulled(s, f)) return;
    const item = s.newItem(CLASS_LINE, f.*.plane, Scene.rgba(color)) catch return;
    const dc: u32 = @intCast(f.*.disp_cat);
    const flags = packFlags(dc, CLASS_LINE, false);
    s.worldToScratch(lines) catch return;
    const hw = @max(width_px, 1.0) * 0.5;
    s.strokePolylineDashed(s.scratch.items, Scene.ringStartsSlice(lines.*.ring_starts, lines.*.ring_count), lines.*.ring_count, hw, dash_on, dash_off, Scene.scaminF(f.*.scamin), flags, false, .{ 0, 0 }, item) catch return;
}

fn fDrawSymbol(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, anchor: cc.tile57_world_point, rings: [*c]const cc.tile57_local_rings, color: cc.tile57_color, even_odd: c_int, stroke_w: f32, align_: cc.tile57_rot_align) callconv(.c) void {
    const s = asScene(ctx);
    if (scaminCulled(s, f)) return;
    const sounding = clsIs(f, "SOUNDG") or clsIs(f, "SOUNDS");
    const class: u8 = if (sounding) CLASS_SOUNDING else CLASS_SYMBOL;
    const kind: u8 = class;
    const item = s.newItem(class, f.*.plane, Scene.rgba(color)) catch return;
    const dc: u32 = @intCast(f.*.disp_cat);
    const map_align = align_ == cc.TILE57_ALIGN_MAP;
    const flags = packFlags(dc, kind, map_align);
    const wrel = [2]f32{ s.relX(anchor.x), s.relY(anchor.y) };
    s.localToScratch(rings) catch return;
    if (stroke_w > 0) {
        s.strokePolyline(s.scratch.items, Scene.ringStartsSlice(rings.*.ring_starts, rings.*.ring_count), rings.*.ring_count, stroke_w * 0.5, Scene.scaminF(f.*.scamin), flags, true, wrel, item) catch return;
    } else if (s.tessContours(s.scratch.items, Scene.ringStartsSlice(rings.*.ring_starts, rings.*.ring_count), rings.*.ring_count, even_odd != 0)) |out| {
        s.appendTess(out, true, wrel, Scene.scaminF(f.*.scamin), flags, item) catch return;
    }
}

fn fDrawText(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, anchor: cc.tile57_world_point, glyphs: [*c]const cc.tile57_local_rings, color: cc.tile57_color, halo: cc.tile57_color, halo_px: f32, align_: cc.tile57_rot_align, _: i32) callconv(.c) void {
    _ = halo;
    _ = halo_px;
    const s = asScene(ctx);
    if (scaminCulled(s, f)) return;
    const item = s.newItem(CLASS_TEXT, f.*.plane, Scene.rgba(color)) catch return;
    const dc: u32 = @intCast(f.*.disp_cat);
    const map_align = align_ == cc.TILE57_ALIGN_MAP;
    const flags = packFlags(dc, CLASS_TEXT, map_align);
    const wrel = [2]f32{ s.relX(anchor.x), s.relY(anchor.y) };
    s.localToScratch(glyphs) catch return;
    if (s.tessContours(s.scratch.items, Scene.ringStartsSlice(glyphs.*.ring_starts, glyphs.*.ring_count), glyphs.*.ring_count, true)) |out| {
        s.appendTess(out, true, wrel, Scene.scaminF(f.*.scamin), flags, item) catch return;
    }
}

// Sprite symbol: look up the atlas cell for `name` and emit one textured quad
// (2 tris) at the world anchor, sized half_w/half_h reference px, rotated. No
// tessellation. Captured in pass 0 only (sprites have no per-scheme color).
fn fDrawSprite(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, name: [*c]const u8, name_len: usize, anchor: cc.tile57_world_point, rot_deg: f32, align_: cc.tile57_rot_align, half_w_px: f32, half_h_px: f32) callconv(.c) void {
    _ = align_;
    const s = asScene(ctx);
    if (scaminCulled(s, f)) return;
    const at = s.sprite_atlas orelse return;
    if (name == null) return;
    const cell = at.lookup(name[0..name_len]) orelse return;
    const aw: f32 = @floatFromInt(at.width);
    const ah: f32 = @floatFromInt(at.height);
    const tu0 = cell.x / aw;
    const tv0 = cell.y / ah;
    const tu1 = (cell.x + cell.w) / aw;
    const tv1 = (cell.y + cell.h) / ah;
    const wx = s.relX(anchor.x);
    const wy = s.relY(anchor.y);
    const rad = rot_deg * std.math.pi / 180.0;
    const cs = std.math.cos(rad);
    const sn = std.math.sin(rad);
    const local = [4][2]f32{ .{ -half_w_px, -half_h_px }, .{ half_w_px, -half_h_px }, .{ half_w_px, half_h_px }, .{ -half_w_px, half_h_px } };
    const uvs = [4][2]f32{ .{ tu0, tv0 }, .{ tu1, tv0 }, .{ tu1, tv1 }, .{ tu0, tv1 } };
    var q: [4]QuadVertex = undefined;
    for (0..4) |i| {
        q[i] = .{
            .wx = wx,
            .wy = wy,
            .lx = local[i][0] * cs - local[i][1] * sn,
            .ly = local[i][0] * sn + local[i][1] * cs,
            .u = uvs[i][0],
            .v = uvs[i][1],
            .r = 255,
            .g = 255,
            .b = 255,
            .a = 255,
        };
    }
    for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |idx| s.quads.append(s.a, q[idx]) catch return;
    // Key on (layer, plane) exactly like tile57 does. The engine sorts by
    // OpLayer first — symbol(3) before sounding(4) — and by draw_prio only
    // within a layer, so a beacon at prio 24 legitimately precedes a SOUNDG at
    // prio 18. lookout merges both layers into this one quad buffer, so sorting
    // on plane alone would flatten them and undo the engine's order.
    const layer: i32 = if (clsIs(f, "SOUNDG") or clsIs(f, "SOUNDS")) 4 else 3;
    s.quad_planes.append(s.a, layer * 1000 + f.*.plane) catch return;
}

// SDF text: lay the UTF-8 run out from glyph metrics into textured quads
// sampling the glyph atlas. Anchor is world; (ox,oy) is the baseline-left origin
// in reference px (alignment already applied); metrics are EM units × size_px.
fn fDrawTextStr(ctx: ?*anyopaque, _: [*c]const cc.tile57_feature, anchor: cc.tile57_world_point, ox_px: f32, oy_px: f32, text: [*c]const u8, text_len: usize, size_px: f32, rot_deg: f32, align_: cc.tile57_rot_align, color: cc.tile57_color, halo: cc.tile57_color, text_group: i32) callconv(.c) void {
    _ = align_;
    _ = halo;
    const s = asScene(ctx);
    // NO SCAMIN cull here. Labels arrive already decluttered and already
    // SCAMIN-gated by the engine, which reserved screen space on the
    // assumption each survivor draws — dropping one here would leave a hole
    // the pool had allocated to it.
    const ga = s.glyph_atlas orelse return;
    if (text == null or text_len == 0) return;
    const wx = s.relX(anchor.x);
    const wy = s.relY(anchor.y);
    const col = Scene.rgba(color);
    // No per-group emphasis: enlarging and emboldening names did not make them
    // more legible, it just made a dense view heavier. text_group stays plumbed
    // through (tile57 reports it) for whatever styling does work later.
    _ = text_group;
    const size_px_eff = size_px;
    const weight: f32 = 0;
    const rad = rot_deg * std.math.pi / 180.0;
    const cs = std.math.cos(rad);
    const sn = std.math.sin(rad);
    var pen: f32 = ox_px;
    var it = std.unicode.Utf8Iterator{ .bytes = text[0..text_len], .i = 0 };
    while (it.nextCodepoint()) |cp| {
        const gi = ga.lookup(@intCast(cp)) orelse {
            continue;
        };
        const gx = pen + gi.off_x * size_px_eff;
        const gy = oy_px + gi.off_y * size_px_eff;
        const gw = gi.w * size_px_eff;
        const gh = gi.h * size_px_eff;
        const local = [4][2]f32{ .{ gx, gy }, .{ gx + gw, gy }, .{ gx + gw, gy + gh }, .{ gx, gy + gh } };
        const uvs = [4][2]f32{ .{ gi.u0, gi.v0 }, .{ gi.u1, gi.v0 }, .{ gi.u1, gi.v1 }, .{ gi.u0, gi.v1 } };
        var q: [4]QuadVertex = undefined;
        for (0..4) |i| {
            q[i] = .{ .wx = wx, .wy = wy, .lx = local[i][0] * cs - local[i][1] * sn, .ly = local[i][0] * sn + local[i][1] * cs, .u = uvs[i][0], .v = uvs[i][1], .r = col.r, .g = col.g, .b = col.b, .a = col.a, .weight = weight };
        }
        for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |k| s.text_quads.append(s.a, q[k]) catch return;
        pen += gi.advance * size_px_eff;
    }
}

// Color-only table (pass k>0): geometry already captured; just record this
// scheme's per-draw-call color into the matching DrawItem, in emission order.
// draw_sprite is a no-op here (sprites captured once, no per-scheme color) — but
// it must be PRESENT so features route identically and draw_symbol parity holds.
fn cDrawSprite(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: [*c]const u8, _: usize, _: cc.tile57_world_point, _: f32, _: cc.tile57_rot_align, _: f32, _: f32) callconv(.c) void {}
fn recordColor(ctx: ?*anyopaque, color: cc.tile57_color) void {
    const s = asScene(ctx);
    if (s.color_counter < s.items.items.len) {
        s.items.items[s.color_counter].colors[s.scheme_k] = Scene.rgba(color);
    }
    s.color_counter += 1;
}
fn cFillArea(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, _: [*c]const cc.tile57_world_rings, color: cc.tile57_color, _: c_int) callconv(.c) void {
    if (scaminCulled(asScene(ctx), f)) return;
    recordColor(ctx, color);
}
fn cStrokeLine(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, _: [*c]const cc.tile57_world_rings, _: f32, _: f32, _: f32, color: cc.tile57_color) callconv(.c) void {
    if (scaminCulled(asScene(ctx), f)) return;
    recordColor(ctx, color);
}
fn cDrawSymbol(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: [*c]const cc.tile57_local_rings, color: cc.tile57_color, _: c_int, _: f32, _: cc.tile57_rot_align) callconv(.c) void {
    if (scaminCulled(asScene(ctx), f)) return;
    recordColor(ctx, color);
}
fn cDrawText(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: [*c]const cc.tile57_local_rings, color: cc.tile57_color, _: cc.tile57_color, _: f32, _: cc.tile57_rot_align, _: i32) callconv(.c) void {
    if (scaminCulled(asScene(ctx), f)) return;
    recordColor(ctx, color);
}

// No-op callbacks. tile57 requires fill_area/stroke_line/draw_symbol/draw_text
// to be non-null, so each pass silences what it doesn't want: the TILE pass
// drops text (it comes from the view-level decluttered pass instead), the LABEL
// pass drops geometry (it comes from the tile cache instead).
fn nFillArea(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: [*c]const cc.tile57_world_rings, _: cc.tile57_color, _: c_int) callconv(.c) void {}
fn nStrokeLine(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: [*c]const cc.tile57_world_rings, _: f32, _: f32, _: f32, _: cc.tile57_color) callconv(.c) void {}
fn nDrawSymbol(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: [*c]const cc.tile57_local_rings, _: cc.tile57_color, _: c_int, _: f32, _: cc.tile57_rot_align) callconv(.c) void {}
fn nDrawText(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: [*c]const cc.tile57_local_rings, _: cc.tile57_color, _: cc.tile57_color, _: f32, _: cc.tile57_rot_align, _: i32) callconv(.c) void {}
fn nDrawTextStr(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: f32, _: f32, _: [*c]const u8, _: usize, _: f32, _: f32, _: cc.tile57_rot_align, _: cc.tile57_color, _: cc.tile57_color, _: i32) callconv(.c) void {}

/// Geometry + symbols for ONE cached tile. Text is deliberately dropped here:
/// a label on a feature that spans tiles gets re-anchored in every tile the
/// feature is clipped into, so per-tile text duplicates across seams. Labels
/// come from labelTable + tile57_{compose,chart}_labels instead, which resolves
/// the whole view against one collision pool (S-52 declutter).
pub fn tileTable(scene: *Scene) cc.tile57_surface_cb {
    return .{
        .ctx = scene,
        .fill_area = fFillArea,
        .stroke_line = fStrokeLine,
        .draw_symbol = fDrawSymbol, // fallback for symbols not in the sprite atlas
        .draw_text = nDrawText,
        .draw_sprite = fDrawSprite, // atlas symbols/soundings -> textured quads
        .draw_pattern = fDrawPattern, // area fill patterns -> tiled atlas cells
        .draw_text_str = nDrawTextStr,
    };
}

/// The view-level label pass: tile57 emits only the labels that WON their space
/// across the whole view, so everything arriving here is drawn as SDF quads.
/// Geometry never arrives (the engine's labels-only mode early-returns), but the
/// callbacks must still be present.
pub fn labelTable(scene: *Scene) cc.tile57_surface_cb {
    return .{
        .ctx = scene,
        .fill_area = nFillArea,
        .stroke_line = nStrokeLine,
        .draw_symbol = nDrawSymbol,
        .draw_text = nDrawText, // no glyph outlines: SDF only
        .draw_sprite = null,
        .draw_pattern = null,
        .draw_text_str = fDrawTextStr,
    };
}

pub fn fullTable(scene: *Scene) cc.tile57_surface_cb {
    return .{
        .ctx = scene,
        .fill_area = fFillArea,
        .stroke_line = fStrokeLine,
        .draw_symbol = fDrawSymbol, // fallback for symbols not in the sprite atlas
        .draw_text = fDrawText,
        .draw_sprite = fDrawSprite, // atlas symbols/soundings -> textured quads
        .draw_pattern = null, // -> pattern fills arrive as flat fill_area
        .draw_text_str = fDrawTextStr, // -> SDF text quads (draw_text stays a fallback)
    };
}
pub fn colorTable(scene: *Scene) cc.tile57_surface_cb {
    return .{
        .ctx = scene,
        .fill_area = cFillArea,
        .stroke_line = cStrokeLine,
        .draw_symbol = cDrawSymbol,
        .draw_text = cDrawText,
        .draw_sprite = cDrawSprite, // no-op, but present so routing matches pass 0
        .draw_pattern = null,
        .draw_text_str = null,
    };
}
