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
    tess_ns: u64 = 0, // time spent in libtess2 (to profile tessellation vs engine)

    // sprite symbols: textured quads (no tessellation), one shared atlas
    quads: std.ArrayList(QuadVertex) = .empty,
    sprite_atlas: ?*const atlas.SpriteAtlas = null,
    // SDF text: textured quads sampling the glyph atlas
    text_quads: std.ArrayList(QuadVertex) = .empty,
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
        var r: u32 = 0;
        while (r < ring_count) : (r += 1) {
            const start = ring_starts[r];
            const end = if (r + 1 < ring_count) ring_starts[r + 1] else @as(u32, @intCast(pts.len / 2));
            if (end - start < 2) continue;
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
                // 4 corners: a+n, b+n, b-n, a-n
                const base: u32 = @intCast(self.verts.items.len);
                try self.pushLineVtx(anchored, wrel, ax, ay, nx, ny, scamin, flags);
                try self.pushLineVtx(anchored, wrel, bx, by, nx, ny, scamin, flags);
                try self.pushLineVtx(anchored, wrel, bx, by, -nx, -ny, scamin, flags);
                try self.pushLineVtx(anchored, wrel, ax, ay, -nx, -ny, scamin, flags);
                for ([_]u32{ 0, 1, 2, 0, 2, 3 }) |o| try self.idx_tmp.append(self.a, base + o);
            }
        }
        item.vtx_count = @as(u32, @intCast(self.verts.items.len)) - item.vtx_first;
        item.idx_count = @as(u32, @intCast(self.idx_tmp.items.len)) - item.idx_first;
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
    fn rgba(c: cc.tile57_rgba) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
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

fn fFillArea(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, rings: [*c]const cc.tile57_world_rings, color: cc.tile57_rgba, even_odd: c_int) callconv(.c) void {
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

fn fStrokeLine(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, lines: [*c]const cc.tile57_world_rings, width_px: f32, dash_on: f32, dash_off: f32, color: cc.tile57_rgba) callconv(.c) void {
    _ = dash_on;
    _ = dash_off;
    const s = asScene(ctx);
    if (scaminCulled(s, f)) return;
    const item = s.newItem(CLASS_LINE, f.*.plane, Scene.rgba(color)) catch return;
    const dc: u32 = @intCast(f.*.disp_cat);
    const flags = packFlags(dc, CLASS_LINE, false);
    s.worldToScratch(lines) catch return;
    const hw = @max(width_px, 1.0) * 0.5;
    s.strokePolyline(s.scratch.items, Scene.ringStartsSlice(lines.*.ring_starts, lines.*.ring_count), lines.*.ring_count, hw, Scene.scaminF(f.*.scamin), flags, false, .{ 0, 0 }, item) catch return;
}

fn fDrawSymbol(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, anchor: cc.tile57_world_point, rings: [*c]const cc.tile57_local_rings, color: cc.tile57_rgba, even_odd: c_int, stroke_w: f32, align_: cc.tile57_rot_align) callconv(.c) void {
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

fn fDrawText(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, anchor: cc.tile57_world_point, glyphs: [*c]const cc.tile57_local_rings, color: cc.tile57_rgba, halo: cc.tile57_rgba, halo_px: f32, align_: cc.tile57_rot_align) callconv(.c) void {
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
}

// SDF text: lay the UTF-8 run out from glyph metrics into textured quads
// sampling the glyph atlas. Anchor is world; (ox,oy) is the baseline-left origin
// in reference px (alignment already applied); metrics are EM units × size_px.
fn fDrawTextStr(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, anchor: cc.tile57_world_point, ox_px: f32, oy_px: f32, text: [*c]const u8, text_len: usize, size_px: f32, rot_deg: f32, align_: cc.tile57_rot_align, color: cc.tile57_rgba, halo: cc.tile57_rgba) callconv(.c) void {
    _ = align_;
    _ = halo;
    const s = asScene(ctx);
    if (scaminCulled(s, f)) return;
    const ga = s.glyph_atlas orelse return;
    if (text == null or text_len == 0) return;
    const wx = s.relX(anchor.x);
    const wy = s.relY(anchor.y);
    const rad = rot_deg * std.math.pi / 180.0;
    const cs = std.math.cos(rad);
    const sn = std.math.sin(rad);
    var pen: f32 = ox_px;
    var it = std.unicode.Utf8Iterator{ .bytes = text[0..text_len], .i = 0 };
    while (it.nextCodepoint()) |cp| {
        const gi = ga.lookup(@intCast(cp)) orelse {
            continue;
        };
        const gx = pen + gi.off_x * size_px;
        const gy = oy_px + gi.off_y * size_px;
        const gw = gi.w * size_px;
        const gh = gi.h * size_px;
        const local = [4][2]f32{ .{ gx, gy }, .{ gx + gw, gy }, .{ gx + gw, gy + gh }, .{ gx, gy + gh } };
        const uvs = [4][2]f32{ .{ gi.u0, gi.v0 }, .{ gi.u1, gi.v0 }, .{ gi.u1, gi.v1 }, .{ gi.u0, gi.v1 } };
        var q: [4]QuadVertex = undefined;
        for (0..4) |i| {
            q[i] = .{ .wx = wx, .wy = wy, .lx = local[i][0] * cs - local[i][1] * sn, .ly = local[i][0] * sn + local[i][1] * cs, .u = uvs[i][0], .v = uvs[i][1], .r = color.r, .g = color.g, .b = color.b, .a = color.a };
        }
        for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |k| s.text_quads.append(s.a, q[k]) catch return;
        pen += gi.advance * size_px;
    }
}

// Color-only table (pass k>0): geometry already captured; just record this
// scheme's per-draw-call color into the matching DrawItem, in emission order.
// draw_sprite is a no-op here (sprites captured once, no per-scheme color) — but
// it must be PRESENT so features route identically and draw_symbol parity holds.
fn cDrawSprite(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: [*c]const u8, _: usize, _: cc.tile57_world_point, _: f32, _: cc.tile57_rot_align, _: f32, _: f32) callconv(.c) void {}
fn recordColor(ctx: ?*anyopaque, color: cc.tile57_rgba) void {
    const s = asScene(ctx);
    if (s.color_counter < s.items.items.len) {
        s.items.items[s.color_counter].colors[s.scheme_k] = Scene.rgba(color);
    }
    s.color_counter += 1;
}
fn cFillArea(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, _: [*c]const cc.tile57_world_rings, color: cc.tile57_rgba, _: c_int) callconv(.c) void {
    if (scaminCulled(asScene(ctx), f)) return;
    recordColor(ctx, color);
}
fn cStrokeLine(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, _: [*c]const cc.tile57_world_rings, _: f32, _: f32, _: f32, color: cc.tile57_rgba) callconv(.c) void {
    if (scaminCulled(asScene(ctx), f)) return;
    recordColor(ctx, color);
}
fn cDrawSymbol(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: [*c]const cc.tile57_local_rings, color: cc.tile57_rgba, _: c_int, _: f32, _: cc.tile57_rot_align) callconv(.c) void {
    if (scaminCulled(asScene(ctx), f)) return;
    recordColor(ctx, color);
}
fn cDrawText(ctx: ?*anyopaque, f: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: [*c]const cc.tile57_local_rings, color: cc.tile57_rgba, _: cc.tile57_rgba, _: f32, _: cc.tile57_rot_align) callconv(.c) void {
    if (scaminCulled(asScene(ctx), f)) return;
    recordColor(ctx, color);
}

// No-op callbacks. tile57 requires fill_area/stroke_line/draw_symbol/draw_text
// to be non-null, so each pass silences what it doesn't want: the TILE pass
// drops text (it comes from the view-level decluttered pass instead), the LABEL
// pass drops geometry (it comes from the tile cache instead).
fn nFillArea(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: [*c]const cc.tile57_world_rings, _: cc.tile57_rgba, _: c_int) callconv(.c) void {}
fn nStrokeLine(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: [*c]const cc.tile57_world_rings, _: f32, _: f32, _: f32, _: cc.tile57_rgba) callconv(.c) void {}
fn nDrawSymbol(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: [*c]const cc.tile57_local_rings, _: cc.tile57_rgba, _: c_int, _: f32, _: cc.tile57_rot_align) callconv(.c) void {}
fn nDrawText(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: [*c]const cc.tile57_local_rings, _: cc.tile57_rgba, _: cc.tile57_rgba, _: f32, _: cc.tile57_rot_align) callconv(.c) void {}
fn nDrawTextStr(_: ?*anyopaque, _: [*c]const cc.tile57_feature, _: cc.tile57_world_point, _: f32, _: f32, _: [*c]const u8, _: usize, _: f32, _: f32, _: cc.tile57_rot_align, _: cc.tile57_rgba, _: cc.tile57_rgba) callconv(.c) void {}

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
        .draw_pattern = null,
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
