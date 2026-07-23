//! Metal transport: device, four pipelines, persistent buffers, and a per-frame
//! render (present into the host's CAMetalLayer OR headless offscreen
//! readback). All vector work happened in the engine — the frame phase here
//! only updates a uniform and issues draws (spec §6).
//!
//! Apple-only by design (see the `sdl-gpu` tag for the cross-platform SDL_GPU
//! predecessor and the driver-stack workarounds this replaces): the ObjC lives
//! in metal_shim.m, shaders in shaders/lookout.metal (compiled at runtime).
const std = @import("std");
const cc = @import("c.zig").c;
const png = @import("png.zig");
const msl_source = @embedFile("metal_src");

/// Vertex-shader uniform block (128 bytes). Matches `struct U` in
/// shaders/lookout.metal. Colour is per-RANGE (one draw = one colour), so it
/// rides the uniform; `anchor_px`/`cell_px` drive the pattern tiling.
pub const Uniforms = extern struct {
    mvp: [16]f32,
    px_to_clip: [2]f32,
    size_scale: f32,
    current_scale: f32,
    cat_mask: u32,
    /// Camera center world-x: the vertex shaders wrap each vertex to the world
    /// instance (x, x±1) nearest this, making the antimeridian seamless.
    wrap_x: f32 = 0.5,
    rot_sin: f32,
    rot_cos: f32,
    color: [4]f32 = .{ 0, 0, 0, 1 }, // per-range flat colour (triangles), straight alpha
    anchor_px: [2]f32 = .{ 0, 0 }, // pattern: framebuffer px of the scene's phase origin
    cell_px: [2]f32 = .{ 1, 1 }, // pattern: cell period in framebuffer px
};

/// RGBA colour 0..1 (drop-in for the old SDL_FColor uses).
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// Monotonic milliseconds from an arbitrary epoch (drop-in for SDL_GetTicks).
pub fn ticksMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// How to interpret Options.native_handle. Apple-only: the host hands us its
/// CAMetalLayer (an NSView's backing layer on macOS, a UIView's layerClass on
/// iOS) and keeps its own toolkit and event loop.
pub const NativeKind = enum(c_int) {
    none = 0,
    metal_layer = 1, // CAMetalLayer* (macOS & iOS)
};

pub const Options = struct {
    width: u32,
    height: u32,
    /// Kept for ABI shape; there is no library-owned window anymore. Without a
    /// layer, rendering is offscreen (snapshot) only.
    want_window: bool,
    want_msaa: bool,
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,
};

pub const Gpu = struct {
    ctx: *cc.lkm_ctx,
    has_layer: bool,
    msaa_used: bool,
    width: u32,
    height: u32,
    /// True when rendering into a host-owned layer: the host drives the size
    /// (its resize() calls set the LOGICAL size; pixels follow the layer).
    external_window: bool = false,
    /// Host view's LOGICAL size from its latest resize() call — the pixel
    /// density denominator.
    host_pt_w: f32 = 0,
    host_pt_h: f32 = 0,
    /// ticksMs() when the drawable last changed size — scenes built mid-resize
    /// are rebuilt by the host while this is recent.
    size_changed_ms: i64 = -100000,
    /// pixels per logical point (Retina/HiDPI = 2.0/3.0).
    pixel_density: f32 = 1.0,

    /// background = S-52 NODATA for the active palette (set by Lookout).
    clear: Color = .{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 },

    // The current draw-ready scene from tile57 (one whole-view GPU scene:
    // triangles + sprite/SDF quads + pattern cells, all range-sorted in paint
    // order). Uploaded once per rebuild; a frame only pushes uniforms + draws.
    scene: ?Scene = null,

    sprite_tex: ?*cc.lkm_tex = null,
    glyph_tex: ?*cc.lkm_tex = null,
    glyph_bold_tex: ?*cc.lkm_tex = null,
    glyph_italic_tex: ?*cc.lkm_tex = null,
    /// 2^(display_zoom - scene_build_zoom): scales the pattern cell period so a
    /// constant-screen-size fill tracks the (MVP-scaled) geometry during a zoom
    /// instead of swimming, resetting to 1 when the scene rebuilds at the new zoom.
    pattern_scale: f32 = 1,

    pub fn init(opts: Options) !Gpu {
        const layer: ?*anyopaque = if (opts.native_kind == .metal_layer) opts.native_handle else null;
        var err: [cc.LKM_ERR_LEN]u8 = undefined;
        err[0] = 0;
        var msaa_out: c_int = 0;
        const ctx = cc.lkm_create(layer, msl_source, @intFromBool(opts.want_msaa), &msaa_out, &err) orelse {
            std.debug.print("Metal init failed: {s}\n", .{std.mem.sliceTo(&err, 0)});
            return error.MetalFailure;
        };

        var g = Gpu{
            .ctx = ctx,
            .has_layer = layer != null,
            .msaa_used = msaa_out != 0,
            .width = opts.width,
            .height = opts.height,
            .external_window = layer != null,
        };
        if (layer != null) {
            var pw: u32 = 0;
            var ph: u32 = 0;
            cc.lkm_layer_sync(ctx, &pw, &ph);
            if (pw > 0 and ph > 0) {
                g.width = pw;
                g.height = ph;
                g.host_pt_w = @floatFromInt(opts.width);
                g.host_pt_h = @floatFromInt(opts.height);
                if (opts.width > 0) {
                    const d = @as(f32, @floatFromInt(pw)) / @as(f32, @floatFromInt(opts.width));
                    if (d > 0.25 and d < 8) g.pixel_density = d;
                }
                std.debug.print("layer: {d}x{d} logical -> {d}x{d} pixels (density {d:.2})\n", .{ opts.width, opts.height, pw, ph, g.pixel_density });
            }
        }
        // Debug: force the atlas/scene density (repro a device's @3x path headless).
        if (std.c.getenv("LOOKOUT_DENSITY")) |ds| {
            if (std.fmt.parseFloat(f32, std.mem.sliceTo(ds, 0)) catch null) |d| {
                if (d > 0.25 and d < 8) {
                    g.pixel_density = d;
                    std.debug.print("LOOKOUT_DENSITY override: density {d:.2}\n", .{d});
                }
            }
        }
        return g;
    }

    /// Resize the render surface. width/height are in logical points. With a
    /// layer, only the logical size is recorded — pixels follow the layer's
    /// bounds × contentsScale each frame (renderWindow adopts them).
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) !void {
        if (self.has_layer) {
            self.host_pt_w = @floatFromInt(width_pts);
            self.host_pt_h = @floatFromInt(height_pts);
            return;
        }
        if (width_pts == self.width and height_pts == self.height) return;
        self.width = width_pts;
        self.height = height_pts;
    }

    pub fn uploadSpriteAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.sprite_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.glyph_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    /// Upload the bold / italic label-tier SDF atlas texture (TILE57_GPU_ATLAS_GLYPH_BOLD
    /// / _ITALIC ranges sample these).
    pub fn uploadGlyphAtlasBold(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.glyph_bold_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlasItalic(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.glyph_italic_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    fn makeAtlasTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !*cc.lkm_tex {
        if (rgba.len < @as(usize, w) * h * 4) return error.MetalFailure;
        return cc.lkm_new_texture_rgba(self.ctx, rgba.ptr, w, h) orelse error.MetalFailure;
    }

    // ---- the draw-ready scene from tile57 ----------------------------------
    // One pattern cell as its own sampler texture, plus its device-px size (the
    // on-screen tiling period). Uploaded per pattern the scene references.
    const PatternTex = struct { tex: ?*cc.lkm_tex = null, w: f32 = 1, h: f32 = 1 };

    /// GPU-resident whole-view scene: the triangle stream (pre-expanded from
    /// tile57's indexed buffers — see uploadGpuScene), the sprite/SDF quads, the
    /// paint-ordered ranges (host-owned copy), and one texture per pattern cell.
    pub const Scene = struct {
        vbuf: ?*cc.lkm_buf = null, // de-indexed triangle vertices (tile57_gpu_vertex)
        qbuf: ?*cc.lkm_buf = null, // sprite/SDF quads (tile57_gpu_quad)
        index_count: u32 = 0, // vertices in vbuf (== the engine's index count)
        ranges: []cc.tile57_gpu_range = &.{},
        patterns: []PatternTex = &.{},
        alloc: std.mem.Allocator,
    };

    /// Upload a `tile57_gpu_scene` into GPU buffers + pattern textures and adopt
    /// it as the current scene (freeing any previous one). The C scene's pointers
    /// are borrowed — everything needed is copied here, so the caller may free it
    /// (tile57_gpu_scene_free) as soon as this returns.
    pub fn uploadGpuScene(self: *Gpu, alloc: std.mem.Allocator, s: *const cc.tile57_gpu_scene) !void {
        var out = Scene{ .alloc = alloc };
        errdefer self.freeSceneValue(&out);

        if (s.vertex_count > 0 and s.index_count > 0) {
            // The engine hands indexed triangles; we keep the historical
            // de-indexed flat stream (the ranges' first/count are index units,
            // which after expansion are exactly flat-vertex units). ~2x vertex
            // memory, zero ambiguity.
            const verts = s.vertices[0..s.vertex_count];
            const idx = s.indices[0..s.index_count];
            const flat = try alloc.alloc(cc.tile57_gpu_vertex, s.index_count);
            defer alloc.free(flat);
            for (idx, 0..) |ii, k| flat[k] = verts[ii];
            const bytes = std.mem.sliceAsBytes(flat);
            out.vbuf = cc.lkm_new_buffer(self.ctx, bytes.ptr, bytes.len) orelse return error.MetalFailure;
            out.index_count = @intCast(s.index_count);
        }
        if (s.quad_count > 0) {
            const bytes = std.mem.sliceAsBytes(s.quads[0..s.quad_count]);
            out.qbuf = cc.lkm_new_buffer(self.ctx, bytes.ptr, bytes.len) orelse return error.MetalFailure;
        }
        if (s.range_count > 0) {
            out.ranges = try alloc.dupe(cc.tile57_gpu_range, s.ranges[0..s.range_count]);
        }
        if (s.pattern_count > 0) {
            out.patterns = try alloc.alloc(PatternTex, s.pattern_count);
            for (out.patterns) |*p| p.* = .{};
            for (s.patterns[0..s.pattern_count], out.patterns) |cell, *p| {
                p.w = @floatFromInt(cell.w);
                p.h = @floatFromInt(cell.h);
                const need = @as(usize, cell.w) * cell.h * 4;
                if (cell.w > 0 and cell.h > 0 and cell.w <= 4096 and cell.h <= 4096 and cell.rgba != null and cell.rgba_len >= need)
                    p.tex = cc.lkm_new_texture_rgba(self.ctx, cell.rgba, cell.w, cell.h);
            }
        }
        self.freeScene();
        self.scene = out;
    }

    fn freeSceneValue(self: *Gpu, s: *Scene) void {
        _ = self;
        if (s.vbuf) |b| cc.lkm_free_buffer(b);
        if (s.qbuf) |b| cc.lkm_free_buffer(b);
        for (s.patterns) |p| if (p.tex) |t| cc.lkm_free_texture(t);
        if (s.ranges.len > 0) s.alloc.free(s.ranges);
        if (s.patterns.len > 0) s.alloc.free(s.patterns);
        s.* = .{ .alloc = s.alloc };
    }

    pub fn freeScene(self: *Gpu) void {
        if (self.scene) |*s| {
            self.freeSceneValue(s);
            self.scene = null;
        }
    }

    // TILE57_LABEL_DEBUG: once per scene, report how many label ranges reach the
    // GPU per atlas + whether the per-face textures uploaded.
    var g_label_dbg: i8 = -1;
    var g_label_dbg_scene: usize = 0;
    fn labelDebug(self: *Gpu, s: *const Scene) void {
        if (g_label_dbg < 0) g_label_dbg = if (std.c.getenv("TILE57_LABEL_DEBUG") != null) 1 else 0;
        if (g_label_dbg != 1) return;
        if (s.ranges.len == g_label_dbg_scene) return; // one report per distinct scene
        g_label_dbg_scene = s.ranges.len;
        var reg: usize = 0;
        var bold: usize = 0;
        var ital: usize = 0;
        for (s.ranges) |r| switch (r.atlas) {
            cc.TILE57_GPU_ATLAS_GLYPH => reg += 1,
            cc.TILE57_GPU_ATLAS_GLYPH_BOLD => bold += 1,
            cc.TILE57_GPU_ATLAS_GLYPH_ITALIC => ital += 1,
            else => {},
        };
        std.debug.print("label ranges: regular={d} bold={d} italic={d} | bold_tex={} italic_tex={}\n", .{ reg, bold, ital, self.glyph_bold_tex != null, self.glyph_italic_tex != null });
    }

    // ---- record one frame's draws into an open frame ------------------------
    // Walk the ranges in paint order, switching pipeline per range: triangles ->
    // flat-colour (or pattern) pipeline; quads -> sprite or SDF pipeline.
    // `text_on`/`sound_on` drop those ranges live (the engine emits them; the
    // host gates by skipping the draw). The pattern anchor + per-cell period
    // ride the uniform.
    fn recordDraws(self: *Gpu, f: *cc.lkm_frame, u: Uniforms, text_on: bool, sound_on: bool) void {
        const s = if (self.scene) |*sc| sc else return;
        self.labelDebug(s);

        for (s.ranges) |r| {
            switch (r.kind) {
                cc.TILE57_GPU_TEXT => if (!text_on) continue,
                cc.TILE57_GPU_SOUNDING => if (!sound_on) continue,
                else => {},
            }
            var uu = u;
            // Soundings ride the mariner's show_soundings switch (the sound_on gate
            // above), NOT the OTHER display category — S-52 files SOUNDG under OTHER,
            // but a mariner asking for soundings isn't asking for seabed and cables.
            // The engine tags them disp_cat=OTHER, so force the OTHER bit on for this
            // range only; SCAMIN still culls them (disp_cat != base).
            if (r.kind == cc.TILE57_GPU_SOUNDING) uu.cat_mask |= @as(u32, 1) << 2;
            if (r.prim == cc.TILE57_GPU_TRIANGLES) {
                const vbuf = s.vbuf orelse continue;
                cc.lkm_bind_vbuf(f, vbuf);
                if (r.pattern != cc.TILE57_GPU_NO_PATTERN and r.pattern < s.patterns.len and s.patterns[r.pattern].tex != null) {
                    const pt = s.patterns[r.pattern];
                    // Scale the cell with the zoom so it tracks the geometry (which
                    // the MVP scales) rather than swimming during a zoom animation.
                    const cs = self.pixel_density * self.pattern_scale;
                    uu.cell_px = .{ pt.w * cs, pt.h * cs };
                    cc.lkm_set_pipeline(f, cc.LKM_PIPE_PATTERN);
                    cc.lkm_bind_texture(f, pt.tex.?);
                } else if (r.pattern != cc.TILE57_GPU_NO_PATTERN) {
                    continue; // a pattern with no cell texture: the fill under it already drew
                } else {
                    uu.color = normColor(r.color);
                    cc.lkm_set_pipeline(f, cc.LKM_PIPE_CHART);
                }
                cc.lkm_set_uniforms(f, &uu, @sizeOf(Uniforms));
                cc.lkm_draw(f, r.first, r.count);
            } else { // QUADS
                const qbuf = s.qbuf orelse continue;
                const is_glyph = r.atlas == cc.TILE57_GPU_ATLAS_GLYPH or
                    r.atlas == cc.TILE57_GPU_ATLAS_GLYPH_BOLD or
                    r.atlas == cc.TILE57_GPU_ATLAS_GLYPH_ITALIC;
                const tex = switch (r.atlas) {
                    cc.TILE57_GPU_ATLAS_GLYPH => self.glyph_tex,
                    cc.TILE57_GPU_ATLAS_GLYPH_BOLD => self.glyph_bold_tex orelse self.glyph_tex,
                    cc.TILE57_GPU_ATLAS_GLYPH_ITALIC => self.glyph_italic_tex orelse self.glyph_tex,
                    else => self.sprite_tex,
                } orelse continue;
                cc.lkm_set_pipeline(f, if (is_glyph) cc.LKM_PIPE_SDF else cc.LKM_PIPE_SPRITE);
                cc.lkm_bind_vbuf(f, qbuf);
                cc.lkm_bind_texture(f, tex);
                cc.lkm_set_uniforms(f, &uu, @sizeOf(Uniforms));
                cc.lkm_draw(f, r.first, r.count);
            }
        }
    }

    /// tile57 straight-alpha RGBA (0..255) -> shader colour (0..1).
    fn normColor(c: [4]u8) [4]f32 {
        return .{
            @as(f32, @floatFromInt(c[0])) / 255.0,
            @as(f32, @floatFromInt(c[1])) / 255.0,
            @as(f32, @floatFromInt(c[2])) / 255.0,
            @as(f32, @floatFromInt(c[3])) / 255.0,
        };
    }

    /// Render one frame into the host's layer and present. Returns false when
    /// there is no layer to present into.
    pub fn renderWindow(self: *Gpu, u: Uniforms, text_on: bool, sound_on: bool) !bool {
        if (!self.has_layer) return false;
        const clear = [4]f32{ self.clear.r, self.clear.g, self.clear.b, self.clear.a };
        const f = cc.lkm_begin_frame(self.ctx, &clear) orelse return true; // no drawable: skip the frame
        // The drawable is the ground truth for the frame's size: viewport and
        // (via logicalSize) the camera follow it, so the picture, the cursor
        // math and the mark sizes stay consistent across host transitions.
        var w: u32 = 0;
        var h: u32 = 0;
        cc.lkm_layer_sync(self.ctx, &w, &h);
        if (w != self.width or h != self.height) {
            std.debug.print("drawable {d}x{d} (was {d}x{d}); adopting\n", .{ w, h, self.width, self.height });
            self.size_changed_ms = ticksMs();
            self.width = w;
            self.height = h;
        }
        // Density is recomputed every frame: during an animated transition the
        // point size briefly lags the drawable, and a ratio captured at that
        // moment would otherwise stick forever.
        if (self.host_pt_w > 0) {
            const d = @as(f32, @floatFromInt(w)) / self.host_pt_w;
            if (d > 0.25 and d < 8 and @abs(d - self.pixel_density) > 0.001) {
                std.debug.print("pixel density {d:.2} -> {d:.2}\n", .{ self.pixel_density, d });
                self.pixel_density = d;
            }
        }
        self.recordDraws(f, u, text_on, sound_on);
        cc.lkm_end_frame(f);
        return true;
    }

    /// Render one frame offscreen and read the pixels back (RGBA8, top-down).
    pub fn renderOffscreen(self: *Gpu, alloc: std.mem.Allocator, u: Uniforms, text_on: bool, sound_on: bool) ![]u8 {
        const clear = [4]f32{ self.clear.r, self.clear.g, self.clear.b, self.clear.a };
        const f = cc.lkm_begin_offscreen(self.ctx, self.width, self.height, &clear) orelse return error.MetalFailure;
        self.recordDraws(f, u, text_on, sound_on);
        const n = @as(usize, self.width) * self.height * 4;
        const pixels = try alloc.alloc(u8, n);
        errdefer alloc.free(pixels);
        if (cc.lkm_end_offscreen_read(f, pixels.ptr) == 0) return error.MetalFailure;
        // The render target is the layer-native BGRA8 — swizzle to the RGBA the
        // snapshot ABI promises.
        var i: usize = 0;
        while (i < n) : (i += 4) {
            const b = pixels[i];
            pixels[i] = pixels[i + 2];
            pixels[i + 2] = b;
        }
        return pixels;
    }

    pub fn savePng(self: *Gpu, alloc: std.mem.Allocator, path: []const u8, u: Uniforms, text_on: bool, sound_on: bool) !void {
        const pixels = try self.renderOffscreen(alloc, u, text_on, sound_on);
        defer alloc.free(pixels);
        try png.write(alloc, path, pixels, self.width, self.height);
    }

    pub fn deinit(self: *Gpu) void {
        self.freeScene();
        if (self.sprite_tex) |t| cc.lkm_free_texture(t);
        if (self.glyph_tex) |t| cc.lkm_free_texture(t);
        if (self.glyph_bold_tex) |t| cc.lkm_free_texture(t);
        if (self.glyph_italic_tex) |t| cc.lkm_free_texture(t);
        cc.lkm_destroy(self.ctx);
    }
};
