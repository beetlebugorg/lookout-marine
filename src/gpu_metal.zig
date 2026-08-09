//! Metal transport: device, the pipelines, persistent buffers, and a per-frame
//! render (present into the host's CAMetalLayer OR headless offscreen
//! readback). All vector work happened in the engine — the frame phase here
//! only updates a uniform and issues draws (spec §6).
//!
//! Apple-only by design (see the `sdl-gpu` tag for the cross-platform SDL_GPU
//! predecessor and the driver-stack workarounds this replaces): the ObjC lives
//! in metal_shim.m, the chart shaders in shaders/lookout.metal and the overlay
//! shader in metal_shim.m itself (both compiled at runtime).
const std = @import("std");
const cc = @import("c.zig").c;
const mc = @import("c_metal.zig").c;
const png = @import("png.zig");
const ov = @import("overlay.zig");
const msl_source = @embedFile("metal_src");

/// Vertex-shader uniform block (128 bytes), matching `struct U` in
/// shaders/lookout.metal. THE ENGINE OWNS THIS LAYOUT (tile57 render/gpu.zig
/// Uniforms, mirrored as tile57_gpu_uniforms) — all three backends declared
/// their own copy, and this one's `color` comment had gone stale claiming a
/// per-range flat colour; the shader only ever reads it as the SDF halo
/// background. Field docs live in the engine; root.zig's ABI gate catches skew.
pub const Uniforms = cc.tile57_gpu_uniforms;

/// RGBA colour 0..1 (drop-in for the old SDL_FColor uses).
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// One raster tile's texture. Opaque to src/raster.zig, which only ever holds
/// and returns it.
pub const RasterTex = *mc.lkm_tex;

/// One tile of the raster underlay: its texture, and the six quad vertices for
/// it in the frame's raster buffer.
pub const RasterDraw = struct { tex: RasterTex, first: u32, count: u32 };

/// Monotonic milliseconds from an arbitrary epoch (drop-in for SDL_GetTicks).
pub fn ticksMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Monotonic microseconds — frame-cost timing needs sub-ms resolution.
pub fn ticksUs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
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
    ctx: *mc.lkm_ctx,
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
    /// Non-zero once the host DECLARED its scale factor (setPixelDensity); it
    /// then wins over the drawable/point ratio derived below.
    host_density: f32 = 0,

    /// background = S-52 NODATA for the active palette (set by Lookout).
    clear: Color = .{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 },

    // The current draw-ready scene from tile57 (one whole-view GPU scene:
    // triangles + sprite/SDF quads + pattern cells, all range-sorted in paint
    // order). Uploaded once per rebuild; a frame only pushes uniforms + draws.
    scene: ?Scene = null,

    sprite_tex: ?*mc.lkm_tex = null,
    glyph_tex: ?*mc.lkm_tex = null,
    glyph_bold_tex: ?*mc.lkm_tex = null,
    glyph_italic_tex: ?*mc.lkm_tex = null,
    /// The raster underlay (src/raster.zig): world-space textured quads drawn
    /// BEFORE the chart, one texture per tile. Reuses the sprite pipeline —
    /// a raster tile IS a textured world-space quad with a tint — so no backend
    /// carries a shader for it. Owned here; replaced whenever the visible tile
    /// set changes, which is far less often than once per frame.
    raster_buf: ?*mc.lkm_buf = null,
    raster_draws: []RasterDraw = &.{},
    raster_alloc: ?std.mem.Allocator = null,
    /// Chart overlays (src/overlay.zig): one triangle stream in world space,
    /// coloured per vertex, drawn after everything else. Re-uploaded when the
    /// store's generation moves — a plugin batch or a zoom step, not a frame.
    overlay_buf: ?*mc.lkm_buf = null,
    overlay_count: u32 = 0,
    /// Canvas text: SDF glyph quads in the overlay's own frame, one buffer
    /// per atlas face, drawn with the chart's SDF pipeline and the glyph
    /// texture(s) already uploaded for labels.
    overlay_text_buf: ?*mc.lkm_buf = null,
    overlay_text_count: u32 = 0,
    overlay_text_bold_buf: ?*mc.lkm_buf = null,
    overlay_text_bold_count: u32 = 0,
    overlay_gen: u64 = 0, // 0 = nothing uploaded yet (a built store is >= 1)
    /// The overlay pass's own frame uniform — the chart's, with the MVP and
    /// wrap rebuilt for the overlay's origin. setOverlay writes it, and it is
    /// the only thing that creates overlay_buf, so a buffer to draw always has
    /// a uniform to draw it with.
    overlay_u: Uniforms = std.mem.zeroes(Uniforms),
    /// recordDraws outcome signature — a new line prints only when it changes.
    last_draw_log: u64 = 0,
    // Rolling frame-cost stats, printed once per STAT_FRAMES rendered frames:
    // CPU encode ms (recordDraws walk) and the GPU ms of the last completed
    // frame — the CPU-vs-GPU-bound discriminator for the frame-rate work.
    stat_enc_sum_ms: f64 = 0,
    stat_enc_max_ms: f64 = 0,
    stat_gpu_sum_ms: f64 = 0,
    stat_gpu_max_ms: f64 = 0,
    stat_frames: u32 = 0,
    stat_acq_sum_ms: f64 = 0,
    stat_acq_max_ms: f64 = 0,
    stat_active_ms: i64 = 0, // sum of sub-100ms inter-frame gaps (idle pauses excluded)
    stat_last_frame_ms: i64 = 0,
    /// 2^(display_zoom - scene_build_zoom): scales the pattern cell period so a
    /// constant-screen-size fill tracks the (MVP-scaled) geometry during a zoom
    /// instead of swimming, resetting to 1 when the scene rebuilds at the new zoom.
    pattern_scale: f32 = 1,

    pub fn init(opts: Options) !Gpu {
        const layer: ?*anyopaque = if (opts.native_kind == .metal_layer) opts.native_handle else null;
        var err: [mc.LKM_ERR_LEN]u8 = undefined;
        err[0] = 0;
        var msaa_out: c_int = 0;
        const ctx = mc.lkm_create(layer, msl_source, @intFromBool(opts.want_msaa), &msaa_out, &err) orelse {
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
            mc.lkm_layer_sync(ctx, &pw, &ph);
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

    /// The host's own scale factor, declared rather than derived. Apple hosts
    /// normally need not call this — the layer carries contentsScale — but the
    /// C ABI offers it on every backend, and a declared value must not then be
    /// overwritten by the per-frame drawable/point ratio.
    pub fn setPixelDensity(self: *Gpu, d: f32) void {
        if (d > 0.2 and d < 8.0) {
            self.host_density = d;
            self.pixel_density = d;
        }
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
    fn makeAtlasTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !*mc.lkm_tex {
        if (rgba.len < @as(usize, w) * h * 4) return error.MetalFailure;
        return mc.lkm_new_texture_rgba(self.ctx, rgba.ptr, w, h) orelse error.MetalFailure;
    }

    // ---- the raster underlay ----------------------------------------------

    pub fn newRasterTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !RasterTex {
        return self.makeAtlasTexture(rgba, w, h);
    }

    pub fn freeRasterTexture(self: *Gpu, t: RasterTex) void {
        _ = self;
        mc.lkm_free_texture(t);
    }

    /// Adopt this frame's raster quads + per-tile draws. Replaces whatever was
    /// held; the caller only calls this when the visible tile set changed.
    pub fn setRasterFrame(self: *Gpu, quads: []const cc.tile57_gpu_quad, draws: []const RasterDraw) !void {
        self.clearRasterFrame();
        if (quads.len == 0 or draws.len == 0) return;
        const a = self.raster_alloc orelse std.heap.c_allocator;
        self.raster_alloc = a;
        const bytes = std.mem.sliceAsBytes(quads);
        self.raster_buf = mc.lkm_new_buffer(self.ctx, bytes.ptr, bytes.len) orelse return error.MetalFailure;
        self.raster_draws = try a.dupe(RasterDraw, draws);
    }

    pub fn clearRasterFrame(self: *Gpu) void {
        if (self.raster_buf) |b| mc.lkm_free_buffer(b);
        self.raster_buf = null;
        if (self.raster_draws.len > 0) {
            if (self.raster_alloc) |a| a.free(self.raster_draws);
            self.raster_draws = &.{};
        }
    }

    /// The depth that puts the underlay immediately IN FRONT OF the chart's
    /// opaque area fills, and behind everything else.
    ///
    /// WHY THIS WORKS. The engine gives range i of N the depth (N-i)/(N+1) —
    /// paint order, normalized. So a depth is a position in that order, and
    /// picking one is picking a place to insert the picture. Just in front of
    /// the LAST opaque area range means the picture hides the fills and nothing
    /// else: every contour, symbol, light, sounding and label paints over it,
    /// because they all paint after the fills and so sit closer.
    ///
    /// WHY IT IS BETTER THAN SUPPRESSING THE FILLS. This is PER PIXEL. The
    /// chart keeps its depth shading everywhere the mariner has no picture, and
    /// loses it only under one — including across a coverage edge, and around
    /// every hole in a pyramid clipped to a coastline. No scene rebuild, and no
    /// all-or-nothing decision about a whole view.
    ///
    /// 0.999 with no scene: behind everything, which is right when there is no
    /// chart to sit in front of.
    /// The depth that puts the underlay in front of the WHOLE chart, so the
    /// chart falls out exactly where a picture covers and stays everywhere else.
    /// Half the closest range's depth, so nothing the engine emits can be nearer.
    pub fn rasterDepthFront(self: *const Gpu) f32 {
        const s = self.scene orelse return 0.5;
        const nr = s.ranges.len;
        if (nr == 0) return 0.5;
        return @floatCast(0.5 / @as(f64, @floatFromInt(nr + 1)));
    }

    pub fn rasterDepth(self: *const Gpu) f32 {
        const s = self.scene orelse return 0.999;
        if (s.ranges.len == 0) return 0.999;
        var last: usize = 0;
        var found = false;
        for (s.ranges, 0..) |r, i| {
            // flags bit 0 is OPAQUE: a pattern-less triangle range with every
            // alpha at 255. Those are the fills that hide a picture.
            if (r.kind == cc.TILE57_GPU_AREA and (r.flags & 1) != 0) {
                last = i;
                found = true;
            }
        }
        if (!found) return 0.999;
        const nr = s.ranges.len;
        // The slot immediately after that range — the same formula the engine
        // uses, evaluated one step later.
        const d = @as(f64, @floatFromInt(nr - last - 1)) / @as(f64, @floatFromInt(nr + 1));
        return @floatCast(d);
    }

    /// Draw the underlay: sprite pipeline, one draw per tile because each
    /// carries its own texture. Runs BEFORE the chart, and WRITES depth — that
    /// is what makes the chart's area fills lose the depth test exactly where a
    /// picture covers them, and keep it everywhere else.
    fn recordRaster(self: *Gpu, f: *mc.lkm_frame, u: Uniforms) void {
        const buf = self.raster_buf orelse return;
        if (self.raster_draws.len == 0) return;
        mc.lkm_set_depth_mode(f, 1);
        mc.lkm_set_pipeline(f, mc.LKM_PIPE_SPRITE);
        mc.lkm_bind_vbuf(f, buf);
        var uu = u;
        // The underlay is BASE category and never scale-gated: it is the only
        // thing on screen where the chart has nothing, so a category filter must
        // not take it away.
        uu.cat_mask = 0xFFFFFFFF;
        mc.lkm_set_uniforms(f, &uu, @sizeOf(Uniforms));
        for (self.raster_draws) |d| {
            mc.lkm_bind_texture(f, d.tex);
            mc.lkm_draw(f, d.first, d.count);
        }
    }

    // ---- chart overlays ----------------------------------------------------

    /// Adopt an overlay frame and the view it is drawn with. The BUFFER upload
    /// is a no-op while the generation is unchanged, so the render thread may
    /// call this every frame; the buffer is replaced wholesale otherwise (the
    /// encoder retains what an in-flight frame bound, so releasing the old one
    /// here is safe — same contract as the raster buffer). `u` is taken every
    /// time: the vertices are relative to the frame's origin, so the pass needs
    /// the MVP and wrap built for that origin, and the camera moves every frame
    /// while the geometry does not.
    pub fn setOverlay(self: *Gpu, fr: ov.Frame, u: Uniforms) !void {
        // The overlay's TextVertex rides the SDF pipeline, whose shader
        // fetches tile57_gpu_quad — the layouts must agree byte for byte.
        comptime std.debug.assert(@sizeOf(ov.TextVertex) == @sizeOf(cc.tile57_gpu_quad));
        self.overlay_u = u;
        if (fr.generation == self.overlay_gen) return;
        self.overlay_gen = fr.generation;
        self.freeOverlayBuf();
        if (fr.verts.len > 0) {
            const bytes = std.mem.sliceAsBytes(fr.verts);
            self.overlay_buf = mc.lkm_new_buffer(self.ctx, bytes.ptr, bytes.len) orelse return error.MetalFailure;
            self.overlay_count = @intCast(fr.verts.len);
        }
        if (fr.text.len > 0) {
            const bytes = std.mem.sliceAsBytes(fr.text);
            self.overlay_text_buf = mc.lkm_new_buffer(self.ctx, bytes.ptr, bytes.len) orelse return error.MetalFailure;
            self.overlay_text_count = @intCast(fr.text.len);
        }
        if (fr.text_bold.len > 0) {
            const bytes = std.mem.sliceAsBytes(fr.text_bold);
            self.overlay_text_bold_buf = mc.lkm_new_buffer(self.ctx, bytes.ptr, bytes.len) orelse return error.MetalFailure;
            self.overlay_text_bold_count = @intCast(fr.text_bold.len);
        }
    }

    /// Drop the overlay geometry (every plugin stopped, or teardown). The next
    /// setOverlay re-uploads whatever the store then holds.
    pub fn clearOverlay(self: *Gpu) void {
        self.freeOverlayBuf();
        self.overlay_gen = 0;
    }

    fn freeOverlayBuf(self: *Gpu) void {
        if (self.overlay_buf) |b| mc.lkm_free_buffer(b);
        self.overlay_buf = null;
        self.overlay_count = 0;
        if (self.overlay_text_buf) |b| mc.lkm_free_buffer(b);
        self.overlay_text_buf = null;
        self.overlay_text_count = 0;
        if (self.overlay_text_bold_buf) |b| mc.lkm_free_buffer(b);
        self.overlay_text_bold_buf = null;
        self.overlay_text_bold_count = 0;
    }

    /// Draw the overlay LAST — after the raster underlay and the whole chart,
    /// in the same encoder. Depth test only: the shader emits z = 0 (the near
    /// plane) so nothing the chart wrote can hide plugin content, and the pass
    /// writes no depth so plugin content cannot hide the chart from a later
    /// pass either. The overlay carries its OWN uniform (setOverlay): the
    /// shader reads mvp and wrap_x, and both are built for the overlay's
    /// origin, not the chart's.
    fn recordOverlay(self: *Gpu, f: *mc.lkm_frame) void {
        if (self.overlay_buf) |buf| {
            if (self.overlay_count > 0) {
                mc.lkm_set_depth_mode(f, 0);
                mc.lkm_set_pipeline(f, mc.LKM_PIPE_OVERLAY);
                mc.lkm_bind_vbuf(f, buf);
                mc.lkm_set_uniforms(f, &self.overlay_u, @sizeOf(Uniforms));
                mc.lkm_draw(f, 0, self.overlay_count);
            }
        }
        // Canvas text, over the triangles: the chart's SDF pipeline with the
        // overlay's uniform. The quads carry depth 0 and the pass writes no
        // depth, so the near-plane contract holds for text too. Category and
        // scale gates are the chart's business, not a plugin drawing's.
        if (self.overlay_text_count == 0 and self.overlay_text_bold_count == 0) return;
        var uu = self.overlay_u;
        uu.cat_mask = 0xFFFFFFFF;
        mc.lkm_set_depth_mode(f, 0);
        if (self.overlay_text_buf) |buf| {
            if (self.overlay_text_count > 0) {
                if (self.glyph_tex) |tex| {
                    mc.lkm_set_pipeline(f, mc.LKM_PIPE_SDF);
                    mc.lkm_bind_vbuf(f, buf);
                    mc.lkm_bind_texture(f, tex);
                    mc.lkm_set_uniforms(f, &uu, @sizeOf(Uniforms));
                    mc.lkm_draw(f, 0, self.overlay_text_count);
                }
            }
        }
        if (self.overlay_text_bold_buf) |buf| {
            if (self.overlay_text_bold_count > 0) {
                if (self.glyph_bold_tex orelse self.glyph_tex) |tex| {
                    mc.lkm_set_pipeline(f, mc.LKM_PIPE_SDF);
                    mc.lkm_bind_vbuf(f, buf);
                    mc.lkm_bind_texture(f, tex);
                    mc.lkm_set_uniforms(f, &uu, @sizeOf(Uniforms));
                    mc.lkm_draw(f, 0, self.overlay_text_bold_count);
                }
            }
        }
    }

    // ---- the draw-ready scene from tile57 ----------------------------------
    // One pattern cell as its own sampler texture, plus its device-px size (the
    // on-screen tiling period). Uploaded per pattern the scene references.
    const PatternTex = struct { tex: ?*mc.lkm_tex = null, w: f32 = 1, h: f32 = 1 };

    /// GPU-resident whole-view scene: the triangle stream (pre-expanded from
    /// tile57's indexed buffers — see uploadGpuScene), the sprite/SDF quads, the
    /// paint-ordered ranges (host-owned copy), and one texture per pattern cell.
    pub const Scene = struct {
        vbuf: ?*mc.lkm_buf = null, // triangle vertices (tile57_gpu_vertex), indexed by ibuf
        ibuf: ?*mc.lkm_buf = null, // u32 triangle indices; ranges' first/count index HERE
        qbuf: ?*mc.lkm_buf = null, // sprite/SDF quads (tile57_gpu_quad)
        index_count: u32 = 0, // entries in ibuf (== the engine's index count)
        ranges: []cc.tile57_gpu_range = &.{},
        patterns: []PatternTex = &.{},
        /// Scratch for the engine's batch (tile57_gpu_batch). Sized to the range
        /// count, which is the ceiling — draws only ever merge, never split — so
        /// a frame never allocates and a batch never truncates.
        draws: []cc.tile57_gpu_draw = &.{},
        alloc: std.mem.Allocator,
    };

    /// Which atlases we actually uploaded, as the bitmask the batcher wants.
    /// A missing bold/italic tier falls back to the regular glyph atlas there.
    fn atlasHave(self: *const Gpu) u8 {
        var m: u8 = 0;
        if (self.sprite_tex != null) m |= 1 << cc.TILE57_GPU_ATLAS_SPRITE;
        if (self.glyph_tex != null) m |= 1 << cc.TILE57_GPU_ATLAS_GLYPH;
        if (self.glyph_bold_tex != null) m |= 1 << cc.TILE57_GPU_ATLAS_GLYPH_BOLD;
        if (self.glyph_italic_tex != null) m |= 1 << cc.TILE57_GPU_ATLAS_GLYPH_ITALIC;
        return m;
    }

    fn atlasTexture(self: *const Gpu, atlas: u8) ?*mc.lkm_tex {
        return switch (atlas) {
            cc.TILE57_GPU_ATLAS_GLYPH => self.glyph_tex,
            cc.TILE57_GPU_ATLAS_GLYPH_BOLD => self.glyph_bold_tex,
            cc.TILE57_GPU_ATLAS_GLYPH_ITALIC => self.glyph_italic_tex,
            else => self.sprite_tex,
        };
    }

    /// Ask the engine which draws this scene needs. `two_phase` excludes the
    /// opaque triangles phase A already drew. Returns an empty slice if the
    /// batch somehow exceeds the buffer, since a truncated batch is missing
    /// chart rather than merely slow.
    fn batchScene(self: *const Gpu, s: *const Scene, text_on: bool, sound_on: bool, two_phase: bool) []const cc.tile57_gpu_draw {
        if (s.ranges.len == 0 or s.draws.len == 0) return &.{};
        const opts = cc.tile57_gpu_batch_opts{
            .text_on = text_on,
            .sound_on = sound_on,
            .exclude_opaque_tris = two_phase,
            .atlas_have = self.atlasHave(),
            .halo = .{ self.clear.r, self.clear.g, self.clear.b, 1 },
        };
        const n = cc.tile57_gpu_batch(s.ranges.ptr, s.ranges.len, &opts, s.draws.ptr, s.draws.len);
        return if (n > s.draws.len) &.{} else s.draws[0..n];
    }

    /// Upload a `tile57_gpu_scene` into GPU buffers + pattern textures and adopt
    /// it as the current scene (freeing any previous one). The C scene's pointers
    /// are borrowed — everything needed is copied here, so the caller may free it
    /// (tile57_gpu_scene_free) as soon as this returns.
    pub fn uploadGpuScene(self: *Gpu, alloc: std.mem.Allocator, s: *const cc.tile57_gpu_scene) !void {
        self.adoptScene(try self.makeScene(alloc, s));
    }

    /// Swap the staged scene in as current (frees the previous one). This is
    /// the ONLY mutation recordDraws can race with, so it must run on the
    /// render thread; everything expensive lives in makeScene.
    pub fn adoptScene(self: *Gpu, sc: Scene) void {
        self.freeScene();
        self.scene = sc;
    }

    /// Free a staged Scene that was never adopted (e.g. superseded build).
    pub fn freeStagedScene(self: *Gpu, sc: *Scene) void {
        self.freeSceneValue(sc);
    }

    /// Build a GPU-resident Scene from the engine's C scene WITHOUT installing
    /// it. Thread-safe: Metal resource creation may run on ANY thread, and this
    /// is where the whole scene's bytes get copied into MTLBuffers — tens of MB
    /// that measured as ~40% of active CPU when it ran on the render thread
    /// mid-gesture. The build worker stages here; the render thread adopts.
    pub fn makeScene(self: *Gpu, alloc: std.mem.Allocator, s: *const cc.tile57_gpu_scene) !Scene {
        var out = Scene{ .alloc = alloc };
        errdefer self.freeSceneValue(&out);
        if (std.c.getenv("LOOKOUT_SCENE_DEBUG") != null) {
            std.debug.print("scene bytes: tris {d} ({d} verts x {d}B + {d} idx x4B) quads {d} ({d} quads x6x{d}B) patterns {d}\n", .{
                s.vertex_count * @sizeOf(cc.tile57_gpu_vertex) + s.index_count * 4, s.vertex_count, @sizeOf(cc.tile57_gpu_vertex), s.index_count,
                s.quad_count * 6 * @sizeOf(cc.tile57_gpu_quad),                     s.quad_count,   @sizeOf(cc.tile57_gpu_quad),   s.pattern_count,
            });
        }

        if (s.vertex_count > 0 and s.index_count > 0) {
            // The engine hands indexed triangles; upload BOTH buffers verbatim
            // and draw indexed. The ranges' first/count are index units, which
            // is exactly drawIndexedPrimitives' addressing — and the vertex
            // buffer stays at vertex_count instead of the ~2x de-indexed
            // flat stream this path historically uploaded.
            const vb = std.mem.sliceAsBytes(s.vertices[0..s.vertex_count]);
            out.vbuf = mc.lkm_new_buffer(self.ctx, vb.ptr, vb.len) orelse return error.MetalFailure;
            const ib = std.mem.sliceAsBytes(s.indices[0..s.index_count]);
            out.ibuf = mc.lkm_new_buffer(self.ctx, ib.ptr, ib.len) orelse return error.MetalFailure;
            out.index_count = @intCast(s.index_count);
        }
        if (s.quad_count > 0) {
            const bytes = std.mem.sliceAsBytes(s.quads[0..s.quad_count]);
            out.qbuf = mc.lkm_new_buffer(self.ctx, bytes.ptr, bytes.len) orelse return error.MetalFailure;
        }
        if (s.range_count > 0) {
            out.ranges = try alloc.dupe(cc.tile57_gpu_range, s.ranges[0..s.range_count]);
            out.draws = try alloc.alloc(cc.tile57_gpu_draw, s.range_count);
            // DEPTH AUDIT (diagnostic, env-gated): paint-order depth must strictly decrease
            // across triangle ranges, or the depth-tested opaque pass inverts.
            if (std.c.getenv("LOOKOUT_DEPTH_AUDIT") != null and s.index_count > 0) {
                var prev_d: f32 = 2.0;
                var bad: u32 = 0;
                for (s.ranges[0..s.range_count], 0..) |r, ri| {
                    if (r.prim != cc.TILE57_GPU_TRIANGLES or r.count == 0) continue;
                    const d = s.vertices[s.indices[r.first]].depth;
                    var mixed: u32 = 0;
                    for (s.indices[r.first..][0..r.count]) |ix| {
                        if (s.vertices[ix].depth != d) mixed += 1;
                    }
                    if (mixed > 0) std.debug.print("MIXED DEPTH range {d}: {d}/{d} verts differ from {d}\n", .{ ri, mixed, r.count, d });
                    if (d >= prev_d) {
                        bad += 1;
                        if (bad <= 5)
                            std.debug.print("DEPTH INVERSION at range {d}: d={d} prev={d} key={d} flags={d}\n", .{ ri, d, prev_d, r.paint_key, r.flags });
                    }
                    prev_d = d;
                }
                if (bad > 0) std.debug.print("DEPTH AUDIT: {d} inversions of {d} ranges\n", .{ bad, s.range_count });
            }
            // BOUNDS AUDIT: a range pointing past its buffer draws undefined
            // memory — recycled heap on one platform (often coincidentally
            // correct), fresh zero pages on another (tile-shaped nothing).
            // The scene hash never covered ranges, so this must scream.
            var bad_tri: u32 = 0;
            var bad_quad: u32 = 0;
            var bad_idx: u32 = 0;
            for (out.ranges) |r| {
                const first: u64 = r.first;
                const count: u64 = r.count;
                if (r.prim == cc.TILE57_GPU_TRIANGLES) {
                    if (first + count > s.index_count) bad_tri += 1;
                } else {
                    if (first + count > s.quad_count * 6) bad_quad += 1;
                }
            }
            if (s.index_count > 0) {
                for (s.indices[0..s.index_count]) |ii| {
                    if (ii >= s.vertex_count) bad_idx += 1;
                }
            }
            if (bad_tri + bad_quad + bad_idx > 0)
                std.debug.print("SCENE BOUNDS VIOLATION: {d} tri-ranges, {d} quad-ranges past their buffers; {d} indices past vertex count (verts={d} idx={d} quads={d})\n", .{ bad_tri, bad_quad, bad_idx, s.vertex_count, s.index_count, s.quad_count });
        }
        if (s.pattern_count > 0) {
            out.patterns = try alloc.alloc(PatternTex, s.pattern_count);
            for (out.patterns) |*p| p.* = .{};
            for (s.patterns[0..s.pattern_count], out.patterns) |cell, *p| {
                p.w = @floatFromInt(cell.w);
                p.h = @floatFromInt(cell.h);
                const need = @as(usize, cell.w) * cell.h * 4;
                if (cell.w > 0 and cell.h > 0 and cell.w <= 4096 and cell.h <= 4096 and cell.rgba != null and cell.rgba_len >= need)
                    p.tex = mc.lkm_new_texture_rgba(self.ctx, cell.rgba, cell.w, cell.h);
            }
        }
        return out;
    }

    fn freeSceneValue(self: *Gpu, s: *Scene) void {
        _ = self;
        if (s.vbuf) |b| mc.lkm_free_buffer(b);
        if (s.ibuf) |b| mc.lkm_free_buffer(b);
        if (s.qbuf) |b| mc.lkm_free_buffer(b);
        for (s.patterns) |p| if (p.tex) |t| mc.lkm_free_texture(t);
        if (s.ranges.len > 0) s.alloc.free(s.ranges);
        if (s.draws.len > 0) s.alloc.free(s.draws);
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
    // The whole frame, in paint order: raster underlay and chart (recordScene),
    // then the overlay on top. The overlay runs even when there is no scene —
    // an own-ship symbol must not vanish because the chart is still loading.
    fn recordDraws(self: *Gpu, f: *mc.lkm_frame, u: Uniforms, text_on: bool, sound_on: bool) void {
        self.recordScene(f, u, text_on, sound_on);
        self.recordOverlay(f);
    }

    // Walk the ranges in paint order, switching pipeline per range: triangles ->
    // flat-colour (or pattern) pipeline; quads -> sprite or SDF pipeline.
    // `text_on`/`sound_on` drop those ranges live (the engine emits them; the
    // host gates by skipping the draw). The pattern anchor + per-cell period
    // ride the uniform.
    fn recordScene(self: *Gpu, f: *mc.lkm_frame, u: Uniforms, text_on: bool, sound_on: bool) void {
        // Before anything the chart draws, and before the early return below:
        // where the chart has no data at all is exactly where the mariner most
        // needs the picture, so a missing scene must not take the underlay away.
        self.recordRaster(f, u);
        const s = if (self.scene) |*sc| sc else {
            if (self.last_draw_log != 0) {
                self.last_draw_log = 0;
                std.debug.print("draw: NO SCENE (nothing to draw)\n", .{});
            }
            return;
        };
        self.labelDebug(s);
        var drawn: u32 = 0; // DRAW CALLS issued (after merging), not ranges
        var ranges_drawn: u32 = 0;
        var sk_patt: u32 = 0;
        var sk_nobuf: u32 = 0;
        var sk_noatlas: u32 = 0;
        var last_u: ?Uniforms = null;
        var usets: u32 = 0;

        // One draw call, already merged. The engine collapses contiguous ranges
        // sharing a draw spec into one of these (tile57_gpu_batch): colour lives
        // in the vertices, so a whole band of differently-coloured fills is a
        // single spec, and at coastal zooms that turns thousands of per-range
        // draws (measured as the phone's frame-rate cap) into a handful.
        const Run = struct {
            active: bool = false,
            prim: @TypeOf(s.ranges[0].prim) = undefined,
            pipe: c_int = 0,
            tex: ?*mc.lkm_tex = null,
            first: u32 = 0,
            count: u32 = 0,
            uu: Uniforms = undefined,
        };
        var opq_runs: u32 = 0;
        const Flush = struct {
            fn go(f2: *mc.lkm_frame, sc: *const Scene, rn: *const Run, lu: *?Uniforms, us: *u32, dr: *u32) void {
                if (rn.prim == cc.TILE57_GPU_TRIANGLES) {
                    mc.lkm_bind_vbuf(f2, sc.vbuf.?);
                    mc.lkm_set_pipeline(f2, rn.pipe);
                    if (rn.tex) |t| mc.lkm_bind_texture(f2, t);
                } else {
                    mc.lkm_set_pipeline(f2, rn.pipe);
                    mc.lkm_bind_vbuf(f2, sc.qbuf.?);
                    mc.lkm_bind_texture(f2, rn.tex.?);
                }
                if (lu.* == null or !std.mem.eql(u8, std.mem.asBytes(&lu.*.?), std.mem.asBytes(&rn.uu))) {
                    mc.lkm_set_uniforms(f2, &rn.uu, @sizeOf(Uniforms));
                    lu.* = rn.uu;
                    us.* += 1;
                }
                if (rn.prim == cc.TILE57_GPU_TRIANGLES)
                    mc.lkm_draw_indexed(f2, sc.ibuf.?, rn.first, rn.count)
                else
                    mc.lkm_draw(f2, rn.first, rn.count);
                dr.* += 1;
            }
        };

        // PHASE A — OPAQUE, front-to-back, depth write ON: every fragment that
        // loses the depth test never shades, so stacked S-52 fills cost ~one
        // shade per pixel instead of one per layer. Walked in REVERSE paint
        // order (front first); contiguous ranges merge exactly as in phase B.
        // Correctness leans on per-range depth, not draw order — order here is
        // purely an early-z optimization.
        // Diagnostic valve: single-phase painter's order (no opaque pass) — the
        // ground truth to diff against when a depth-pass artifact is suspected.
        const two_phase = std.c.getenv("LOOKOUT_NO_OPAQUE_PASS") == null;
        if (s.vbuf != null and s.ibuf != null and two_phase) {
            mc.lkm_set_depth_mode(f, 1);
            var a_first: u32 = 0;
            var a_count: u32 = 0;
            var a_uu: Uniforms = u;
            var i: usize = s.ranges.len;
            while (i > 0) {
                i -= 1;
                const r = s.ranges[i];
                if ((r.flags & 1) == 0 or r.prim != cc.TILE57_GPU_TRIANGLES or r.pattern != cc.TILE57_GPU_NO_PATTERN) continue;
                if (r.kind == cc.TILE57_GPU_TEXT and !text_on) continue; // counted in phase B
                if (r.kind == cc.TILE57_GPU_SOUNDING and !sound_on) continue;
                var uu = u;
                if (r.kind == cc.TILE57_GPU_SOUNDING) uu.cat_mask |= @as(u32, 1) << 2; // same tweak as phase B
                ranges_drawn += 1;
                if (a_count > 0 and r.first + r.count == a_first and
                    std.mem.eql(u8, std.mem.asBytes(&a_uu), std.mem.asBytes(&uu)))
                {
                    a_first = r.first;
                    a_count += r.count;
                    continue;
                }
                if (a_count > 0) {
                    const orun = Run{ .active = true, .prim = r.prim, .pipe = mc.LKM_PIPE_CHART, .tex = null, .first = a_first, .count = a_count, .uu = a_uu };
                    Flush.go(f, s, &orun, &last_u, &usets, &drawn);
                    opq_runs += 1;
                }
                a_first = r.first;
                a_count = r.count;
                a_uu = uu;
            }
            if (a_count > 0) {
                const orun = Run{ .active = true, .prim = cc.TILE57_GPU_TRIANGLES, .pipe = mc.LKM_PIPE_CHART, .tex = null, .first = a_first, .count = a_count, .uu = a_uu };
                Flush.go(f, s, &orun, &last_u, &usets, &drawn);
                opq_runs += 1;
            }
        }

        // PHASE B — everything else in paint order, depth test only: content
        // UNDER an opaque surface is culled by the phase-A depth, everything
        // else blends exactly as painter's order always did. The engine decides
        // what each range draws and merges contiguous ranges sharing a spec
        // (tile57_gpu_batch); phase A's ranges are excluded there rather than
        // re-skipped here.
        mc.lkm_set_depth_mode(f, 0);
        for (self.batchScene(s, text_on, sound_on, two_phase)) |d| {
            var uu = u;
            uu.cat_mask |= d.cat_mask_or;
            var pipe: c_int = undefined;
            var tex: ?*mc.lkm_tex = null;
            if (d.prim == cc.TILE57_GPU_TRIANGLES) {
                if (s.vbuf == null or s.ibuf == null) {
                    sk_nobuf += 1;
                    continue;
                }
                if (d.pipeline == cc.TILE57_GPU_PIPE_PATTERN) {
                    // Whether a cell rasterized is ours to know; without one the
                    // fill under it already drew, so this draws nothing.
                    if (d.pattern >= s.patterns.len or s.patterns[d.pattern].tex == null) {
                        sk_patt += 1;
                        continue;
                    }
                    const pt = s.patterns[d.pattern];
                    // Scale the cell with the zoom so it tracks the geometry (which
                    // the MVP scales) rather than swimming during a zoom animation.
                    const cs = self.pixel_density * self.pattern_scale;
                    uu.cell_px = .{ pt.w * cs, pt.h * cs };
                    pipe = mc.LKM_PIPE_PATTERN;
                    tex = pt.tex;
                } else {
                    // Colour rides the VERTICES (see tile57_gpu_vertex.color).
                    pipe = mc.LKM_PIPE_CHART;
                }
            } else { // QUADS
                if (s.qbuf == null) {
                    sk_nobuf += 1;
                    continue;
                }
                const is_glyph = d.pipeline == cc.TILE57_GPU_PIPE_SDF;
                tex = self.atlasTexture(d.atlas) orelse {
                    sk_noatlas += 1;
                    continue;
                };
                pipe = if (is_glyph) mc.LKM_PIPE_SDF else mc.LKM_PIPE_SPRITE;
                // Text halos render in the PALETTE background colour (see
                // sdf_frag): night text was unreadable inside a hardcoded
                // white halo. Part of the draw spec, so the batch splits on it.
                if (is_glyph) uu.color = d.color;
            }
            ranges_drawn += 1;
            const one = Run{ .active = true, .prim = d.prim, .pipe = pipe, .tex = tex, .first = d.first, .count = d.count, .uu = uu };
            Flush.go(f, s, &one, &last_u, &usets, &drawn);
        }
        // One line per DISTINCT draw outcome (not per frame): what the GPU was
        // actually asked to draw for this scene, and everything withheld, with
        // reasons. The scene said what exists; this says what made it to Metal.
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&drawn));
        h.update(std.mem.asBytes(&sk_patt));
        h.update(std.mem.asBytes(&sk_nobuf));
        h.update(std.mem.asBytes(&sk_noatlas));
        h.update(std.mem.asBytes(&s.index_count));
        const sig = h.final();
        if (sig != self.last_draw_log) {
            self.last_draw_log = sig;
            std.debug.print("draw: {d}/{d} ranges in {d} draws ({d} uniform sends) (skipped: pattern={d} nobuf={d} noatlas={d}) verts={d} drawable={d}x{d} density={d:.2}\n", .{ ranges_drawn, s.ranges.len, drawn, usets, sk_patt, sk_nobuf, sk_noatlas, s.index_count, self.width, self.height, self.pixel_density });
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
        // Time the drawable acquire separately: nextDrawable BLOCKS when the
        // swapchain is exhausted, and that wait is invisible to the encode/gpu
        // numbers — the third column of the frame-cost triage.
        const ta0 = ticksUs();
        // NULL = swapchain saturated (or mid-transition): SKIP without stalling.
        // Returning false tells render() to keep view_dirty set, so the display
        // link retries next tick and the skipped content still lands.
        const f = mc.lkm_begin_frame(self.ctx, &clear) orelse return false;
        const acq_ms = @as(f64, @floatFromInt(ticksUs() - ta0)) / 1000.0;
        self.stat_acq_sum_ms += acq_ms;
        self.stat_acq_max_ms = @max(self.stat_acq_max_ms, acq_ms);
        // The drawable is the ground truth for the frame's size: viewport and
        // (via logicalSize) the camera follow it, so the picture, the cursor
        // math and the mark sizes stay consistent across host transitions.
        var w: u32 = 0;
        var h: u32 = 0;
        mc.lkm_layer_sync(self.ctx, &w, &h);
        if (w != self.width or h != self.height) {
            std.debug.print("drawable {d}x{d} (was {d}x{d}); adopting\n", .{ w, h, self.width, self.height });
            self.size_changed_ms = ticksMs();
            self.width = w;
            self.height = h;
        }
        // Density is recomputed every frame: during an animated transition the
        // point size briefly lags the drawable, and a ratio captured at that
        // moment would otherwise stick forever.
        if (self.host_density == 0 and self.host_pt_w > 0) {
            const d = @as(f32, @floatFromInt(w)) / self.host_pt_w;
            if (d > 0.25 and d < 8 and @abs(d - self.pixel_density) > 0.001) {
                std.debug.print("pixel density {d:.2} -> {d:.2}\n", .{ self.pixel_density, d });
                self.pixel_density = d;
            }
        }
        const t0 = ticksUs();
        self.recordDraws(f, u, text_on, sound_on);
        const enc_ms = @as(f64, @floatFromInt(ticksUs() - t0)) / 1000.0;
        mc.lkm_end_frame(f);
        const gpu_ms = mc.lkm_last_gpu_ms(self.ctx);
        self.stat_enc_sum_ms += enc_ms;
        self.stat_enc_max_ms = @max(self.stat_enc_max_ms, enc_ms);
        self.stat_gpu_sum_ms += gpu_ms;
        self.stat_gpu_max_ms = @max(self.stat_gpu_max_ms, gpu_ms);
        self.stat_frames += 1;
        {
            // fps over ACTIVE time only: the display link pauses when idle, so
            // wall-clock fps would count think-time between gestures. Gaps
            // >=100ms are idle (or a hitch so bad it reads the same) and are
            // excluded from the denominator.
            const now = ticksMs();
            const gap = now - self.stat_last_frame_ms;
            if (self.stat_last_frame_ms > 0 and gap < 100) self.stat_active_ms += gap;
            self.stat_last_frame_ms = now;
        }
        if (self.stat_frames >= 120) {
            const n: f64 = @floatFromInt(self.stat_frames);
            const fps: f64 = if (self.stat_active_ms > 0)
                n * 1000.0 / @as(f64, @floatFromInt(self.stat_active_ms))
            else
                0;
            std.debug.print("frame: acquire avg {d:.2} max {d:.2} | encode avg {d:.2} max {d:.2} | gpu avg {d:.2} max {d:.2} ms | ~{d:.0} fps active ({d} frames)\n", .{
                self.stat_acq_sum_ms / n, self.stat_acq_max_ms,
                self.stat_enc_sum_ms / n, self.stat_enc_max_ms,
                self.stat_gpu_sum_ms / n, self.stat_gpu_max_ms,
                fps,                      self.stat_frames,
            });
            self.stat_acq_sum_ms = 0;
            self.stat_acq_max_ms = 0;
            self.stat_active_ms = 0;
            self.stat_enc_sum_ms = 0;
            self.stat_enc_max_ms = 0;
            self.stat_gpu_sum_ms = 0;
            self.stat_gpu_max_ms = 0;
            self.stat_frames = 0;
        }
        return true;
    }

    /// Render one frame offscreen and read the pixels back (RGBA8, top-down).
    pub fn renderOffscreen(self: *Gpu, alloc: std.mem.Allocator, u: Uniforms, text_on: bool, sound_on: bool) ![]u8 {
        const clear = [4]f32{ self.clear.r, self.clear.g, self.clear.b, self.clear.a };
        const f = mc.lkm_begin_offscreen(self.ctx, self.width, self.height, &clear) orelse return error.MetalFailure;
        self.recordDraws(f, u, text_on, sound_on);
        const n = @as(usize, self.width) * self.height * 4;
        const pixels = try alloc.alloc(u8, n);
        errdefer alloc.free(pixels);
        if (mc.lkm_end_offscreen_read(f, pixels.ptr) == 0) return error.MetalFailure;
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
        self.clearRasterFrame();
        self.clearOverlay();
        if (self.sprite_tex) |t| mc.lkm_free_texture(t);
        if (self.glyph_tex) |t| mc.lkm_free_texture(t);
        if (self.glyph_bold_tex) |t| mc.lkm_free_texture(t);
        if (self.glyph_italic_tex) |t| mc.lkm_free_texture(t);
        mc.lkm_destroy(self.ctx);
    }
};
