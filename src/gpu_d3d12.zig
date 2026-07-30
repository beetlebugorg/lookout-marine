//! Direct3D 12 transport: device, four pipelines, persistent buffers, and a
//! per-frame render (present through the context's own composition swapchain
//! OR headless offscreen readback). All vector work happened in the engine —
//! the frame phase here only updates a uniform and issues draws (spec §6).
//!
//! Windows-only by design: the D3D12 lives in d3d12_shim.c, shaders in
//! shaders/lookout.hlsl (compiled at runtime). The Windows counterpart of
//! gpu_metal.zig — the host attaches the swapchain (lookout_d3d12_swapchain)
//! to its SwapChainPanel and keeps its own toolkit and event loop. WARP keeps
//! it working on machines with no GPU driver.
const std = @import("std");
const cc = @import("c.zig").c;
const dc = @cImport(@cInclude("d3d12_shim.h"));
const png = @import("png.zig");
const hlsl_source = @embedFile("hlsl_src");

/// Vertex-shader uniform block (128 bytes), matching `cbuffer U` in
/// shaders/lookout.hlsl. THE ENGINE OWNS THIS LAYOUT (tile57 render/gpu.zig
/// Uniforms, mirrored as tile57_gpu_uniforms); root.zig's ABI gate catches skew.
pub const Uniforms = cc.tile57_gpu_uniforms;

/// RGBA colour 0..1.
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

// Monotonic clock: QueryPerformanceCounter (the MSVC CRT has no clock_gettime).
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) c_int;

/// Monotonic microseconds — frame-cost timing needs sub-ms resolution.
pub fn ticksUs() i64 {
    var ctr: i64 = 0;
    var freq: i64 = 0;
    _ = QueryPerformanceCounter(&ctr);
    _ = QueryPerformanceFrequency(&freq);
    if (freq == 0) return 0;
    // Split the divide so a large counter × 1e6 can't overflow i64.
    return @divTrunc(ctr, freq) * 1_000_000 + @divTrunc(@rem(ctr, freq) * 1_000_000, freq);
}

/// Monotonic milliseconds from an arbitrary epoch.
pub fn ticksMs() i64 {
    return @divTrunc(ticksUs(), 1000);
}

/// How to interpret Options.native_handle. The context OWNS its swapchain, so
/// the host passes no handle: kind d3d12_panel means "make a composition
/// swapchain"; the host fetches it (lookout_d3d12_swapchain) and attaches it
/// to its SwapChainPanel.
pub const NativeKind = enum(c_int) {
    none = 0,
    d3d12_panel = 10, // composition swapchain for a SwapChainPanel
};

pub const Options = struct {
    width: u32,
    height: u32,
    /// Kept for ABI shape; there is no library-owned window anymore. Without a
    /// swapchain, rendering is offscreen (snapshot) only.
    want_window: bool,
    want_msaa: bool,
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,
};

pub const Gpu = struct {
    ctx: *dc.lkd_ctx,
    has_swapchain: bool,
    msaa_used: bool,
    width: u32,
    height: u32,
    /// True when presenting into the host's panel: the host drives the size
    /// (its resize() calls set the LOGICAL size; pixels = points × density).
    external_window: bool = false,
    /// Host view's LOGICAL size from its latest resize() call — the pixel
    /// density denominator.
    host_pt_w: f32 = 0,
    host_pt_h: f32 = 0,
    /// ticksMs() when the swapchain last changed size — scenes built mid-resize
    /// are rebuilt by the host while this is recent.
    size_changed_ms: i64 = -100000,
    /// pixels per logical point (Windows scale 150% = 1.5).
    pixel_density: f32 = 1.0,

    /// background = S-52 NODATA for the active palette (set by Lookout).
    clear: Color = .{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 },

    // The current draw-ready scene from tile57 (one whole-view GPU scene:
    // triangles + sprite/SDF quads + pattern cells, all range-sorted in paint
    // order). Uploaded once per rebuild; a frame only pushes uniforms + draws.
    scene: ?Scene = null,

    sprite_tex: ?*dc.lkd_tex = null,
    glyph_tex: ?*dc.lkd_tex = null,
    glyph_bold_tex: ?*dc.lkd_tex = null,
    glyph_italic_tex: ?*dc.lkd_tex = null,
    /// recordDraws outcome signature — a new line prints only when it changes.
    last_draw_log: u64 = 0,
    // Rolling frame-cost stats, printed once per 120 rendered frames: CPU
    // encode ms (recordDraws walk) and the GPU ms of the last completed frame.
    stat_enc_sum_ms: f64 = 0,
    stat_enc_max_ms: f64 = 0,
    stat_gpu_sum_ms: f64 = 0,
    stat_gpu_max_ms: f64 = 0,
    stat_frames: u32 = 0,
    stat_active_ms: i64 = 0, // sum of sub-100ms inter-frame gaps (idle pauses excluded)
    stat_last_frame_ms: i64 = 0,
    /// 2^(display_zoom - scene_build_zoom): scales the pattern cell period so a
    /// constant-screen-size fill tracks the (MVP-scaled) geometry during a zoom
    /// instead of swimming, resetting to 1 when the scene rebuilds at the new zoom.
    pattern_scale: f32 = 1,

    pub fn init(opts: Options) !Gpu {
        const want_sc = opts.native_kind == .d3d12_panel;
        var err: [dc.LKD_ERR_LEN]u8 = undefined;
        err[0] = 0;
        var msaa_out: c_int = 0;
        const ctx = dc.lkd_create(opts.width, opts.height, @intFromBool(want_sc), hlsl_source, @intFromBool(opts.want_msaa), &msaa_out, &err) orelse {
            std.debug.print("D3D12 init failed: {s}\n", .{std.mem.sliceTo(&err, 0)});
            return error.D3d12Failure;
        };
        var g = Gpu{
            .ctx = ctx,
            .has_swapchain = want_sc,
            .msaa_used = msaa_out != 0,
            .width = opts.width,
            .height = opts.height,
            .external_window = want_sc,
        };
        if (want_sc) {
            g.host_pt_w = @floatFromInt(opts.width);
            g.host_pt_h = @floatFromInt(opts.height);
        }
        // Debug: force the atlas/scene density (repro a scaled display headless).
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

    /// The IDXGISwapChain* for the host's SwapChainPanel (null offscreen-only).
    pub fn swapchainPtr(self: *Gpu) ?*anyopaque {
        return dc.lkd_swapchain(self.ctx);
    }

    /// The host's scale factor, declared (there is no layer to derive it from).
    /// Pixels = the declared logical size × this.
    pub fn setPixelDensity(self: *Gpu, d: f32) void {
        if (d > 0.2 and d < 8.0) {
            self.pixel_density = d;
            if (self.has_swapchain and self.host_pt_w > 0)
                self.resizePixels(self.host_pt_w, self.host_pt_h);
        }
    }

    /// Resize the render surface. width/height are in logical points; the
    /// swapchain resizes to points × density.
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) !void {
        if (self.has_swapchain) {
            self.host_pt_w = @floatFromInt(width_pts);
            self.host_pt_h = @floatFromInt(height_pts);
            self.resizePixels(self.host_pt_w, self.host_pt_h);
            return;
        }
        if (width_pts == self.width and height_pts == self.height) return;
        self.width = width_pts;
        self.height = height_pts;
    }

    fn resizePixels(self: *Gpu, pt_w: f32, pt_h: f32) void {
        const w: u32 = @intFromFloat(@max(1.0, @round(pt_w * self.pixel_density)));
        const h: u32 = @intFromFloat(@max(1.0, @round(pt_h * self.pixel_density)));
        if (w == self.width and h == self.height) return;
        if (dc.lkd_resize(self.ctx, w, h) != 0) {
            std.debug.print("swapchain {d}x{d} (was {d}x{d}); adopting\n", .{ w, h, self.width, self.height });
            self.width = w;
            self.height = h;
            self.size_changed_ms = ticksMs();
        }
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
    fn makeAtlasTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !*dc.lkd_tex {
        if (rgba.len < @as(usize, w) * h * 4) return error.D3d12Failure;
        return dc.lkd_new_texture_rgba(self.ctx, rgba.ptr, w, h) orelse error.D3d12Failure;
    }

    // ---- the draw-ready scene from tile57 ----------------------------------
    // One pattern cell as its own sampler texture, plus its device-px size (the
    // on-screen tiling period). Uploaded per pattern the scene references.
    const PatternTex = struct { tex: ?*dc.lkd_tex = null, w: f32 = 1, h: f32 = 1 };

    /// GPU-resident whole-view scene: the indexed triangle buffers, the
    /// sprite/SDF quads, the paint-ordered ranges (host-owned copy), and one
    /// texture per pattern cell.
    pub const Scene = struct {
        vbuf: ?*dc.lkd_buf = null, // triangle vertices (tile57_gpu_vertex), indexed by ibuf
        ibuf: ?*dc.lkd_buf = null, // u32 triangle indices; ranges' first/count index HERE
        qbuf: ?*dc.lkd_buf = null, // sprite/SDF quads (tile57_gpu_quad)
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

    fn atlasTexture(self: *const Gpu, atlas: u8) ?*dc.lkd_tex {
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
    /// it. Thread-safe: the shim's resource creation may run on ANY thread, and
    /// this is where the whole scene's bytes get copied into GPU buffers — the
    /// build worker stages here; the render thread adopts.
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
            // is exactly DrawIndexedInstanced's addressing.
            const vb = std.mem.sliceAsBytes(s.vertices[0..s.vertex_count]);
            out.vbuf = dc.lkd_new_buffer(self.ctx, vb.ptr, vb.len) orelse return error.D3d12Failure;
            const ib = std.mem.sliceAsBytes(s.indices[0..s.index_count]);
            out.ibuf = dc.lkd_new_buffer(self.ctx, ib.ptr, ib.len) orelse return error.D3d12Failure;
            out.index_count = @intCast(s.index_count);
        }
        if (s.quad_count > 0) {
            const bytes = std.mem.sliceAsBytes(s.quads[0..s.quad_count]);
            out.qbuf = dc.lkd_new_buffer(self.ctx, bytes.ptr, bytes.len) orelse return error.D3d12Failure;
        }
        if (s.range_count > 0) {
            out.ranges = try alloc.dupe(cc.tile57_gpu_range, s.ranges[0..s.range_count]);
            out.draws = try alloc.alloc(cc.tile57_gpu_draw, s.range_count);
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
                    p.tex = dc.lkd_new_texture_rgba(self.ctx, cell.rgba, cell.w, cell.h);
            }
        }
        return out;
    }

    fn freeSceneValue(self: *Gpu, s: *Scene) void {
        _ = self;
        if (s.vbuf) |b| dc.lkd_free_buffer(b);
        if (s.ibuf) |b| dc.lkd_free_buffer(b);
        if (s.qbuf) |b| dc.lkd_free_buffer(b);
        for (s.patterns) |p| if (p.tex) |t| dc.lkd_free_texture(t);
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

    // ---- record one frame's draws into an open frame ------------------------
    // Walk the ranges in paint order, switching pipeline per range: triangles ->
    // flat-colour (or pattern) pipeline; quads -> sprite or SDF pipeline.
    // `text_on`/`sound_on` drop those ranges live (the engine emits them; the
    // host gates by skipping the draw). The pattern anchor + per-cell period
    // ride the uniform.
    fn recordDraws(self: *Gpu, f: *dc.lkd_frame, u: Uniforms, text_on: bool, sound_on: bool) void {
        const s = if (self.scene) |*sc| sc else {
            if (self.last_draw_log != 0) {
                self.last_draw_log = 0;
                std.debug.print("draw: NO SCENE (nothing to draw)\n", .{});
            }
            return;
        };
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
        // single spec.
        const Run = struct {
            active: bool = false,
            prim: @TypeOf(s.ranges[0].prim) = undefined,
            pipe: c_int = 0,
            tex: ?*dc.lkd_tex = null,
            first: u32 = 0,
            count: u32 = 0,
            uu: Uniforms = undefined,
        };
        var opq_runs: u32 = 0;
        const Flush = struct {
            fn go(f2: *dc.lkd_frame, sc: *const Scene, rn: *const Run, lu: *?Uniforms, us: *u32, dr: *u32) void {
                if (rn.prim == cc.TILE57_GPU_TRIANGLES) {
                    dc.lkd_bind_vbuf(f2, sc.vbuf.?);
                    dc.lkd_set_pipeline(f2, rn.pipe);
                    if (rn.tex) |t| dc.lkd_bind_texture(f2, t);
                } else {
                    dc.lkd_set_pipeline(f2, rn.pipe);
                    dc.lkd_bind_vbuf(f2, sc.qbuf.?);
                    dc.lkd_bind_texture(f2, rn.tex.?);
                }
                if (lu.* == null or !std.mem.eql(u8, std.mem.asBytes(&lu.*.?), std.mem.asBytes(&rn.uu))) {
                    dc.lkd_set_uniforms(f2, &rn.uu, @sizeOf(Uniforms));
                    lu.* = rn.uu;
                    us.* += 1;
                }
                if (rn.prim == cc.TILE57_GPU_TRIANGLES)
                    dc.lkd_draw_indexed(f2, sc.ibuf.?, rn.first, rn.count)
                else
                    dc.lkd_draw(f2, rn.first, rn.count);
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
            dc.lkd_set_depth_mode(f, 1);
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
                    const orun = Run{ .active = true, .prim = r.prim, .pipe = dc.LKD_PIPE_CHART, .tex = null, .first = a_first, .count = a_count, .uu = a_uu };
                    Flush.go(f, s, &orun, &last_u, &usets, &drawn);
                    opq_runs += 1;
                }
                a_first = r.first;
                a_count = r.count;
                a_uu = uu;
            }
            if (a_count > 0) {
                const orun = Run{ .active = true, .prim = cc.TILE57_GPU_TRIANGLES, .pipe = dc.LKD_PIPE_CHART, .tex = null, .first = a_first, .count = a_count, .uu = a_uu };
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
        dc.lkd_set_depth_mode(f, 0);
        for (self.batchScene(s, text_on, sound_on, two_phase)) |d| {
            var uu = u;
            uu.cat_mask |= d.cat_mask_or;
            var pipe: c_int = undefined;
            var tex: ?*dc.lkd_tex = null;
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
                    pipe = dc.LKD_PIPE_PATTERN;
                    tex = pt.tex;
                } else {
                    // Colour rides the VERTICES (see tile57_gpu_vertex.color).
                    pipe = dc.LKD_PIPE_CHART;
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
                pipe = if (is_glyph) dc.LKD_PIPE_SDF else dc.LKD_PIPE_SPRITE;
                // Text halos render in the PALETTE background colour (see
                // sdf_ps): night text was unreadable inside a hardcoded
                // white halo. Part of the draw spec, so the batch splits on it.
                if (is_glyph) uu.color = d.color;
            }
            ranges_drawn += 1;
            const one = Run{ .active = true, .prim = d.prim, .pipe = pipe, .tex = tex, .first = d.first, .count = d.count, .uu = uu };
            Flush.go(f, s, &one, &last_u, &usets, &drawn);
        }
        // One line per DISTINCT draw outcome (not per frame): what the GPU was
        // actually asked to draw for this scene, and everything withheld, with
        // reasons. The scene said what exists; this says what made it to D3D12.
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&drawn));
        h.update(std.mem.asBytes(&sk_patt));
        h.update(std.mem.asBytes(&sk_nobuf));
        h.update(std.mem.asBytes(&sk_noatlas));
        h.update(std.mem.asBytes(&s.index_count));
        const sig = h.final();
        if (sig != self.last_draw_log) {
            self.last_draw_log = sig;
            std.debug.print("draw: {d}/{d} ranges in {d} draws ({d} uniform sends) (skipped: pattern={d} nobuf={d} noatlas={d}) verts={d} target={d}x{d} density={d:.2}\n", .{ ranges_drawn, s.ranges.len, drawn, usets, sk_patt, sk_nobuf, sk_noatlas, s.index_count, self.width, self.height, self.pixel_density });
        }
    }

    /// Render one frame into the swapchain and present. Returns false when
    /// there is no swapchain to present into.
    pub fn renderWindow(self: *Gpu, u: Uniforms, text_on: bool, sound_on: bool) !bool {
        if (!self.has_swapchain) return false;
        const clear = [4]f32{ self.clear.r, self.clear.g, self.clear.b, self.clear.a };
        const f = dc.lkd_begin_frame(self.ctx, &clear) orelse return false;
        const t0 = ticksUs();
        self.recordDraws(f, u, text_on, sound_on);
        const enc_ms = @as(f64, @floatFromInt(ticksUs() - t0)) / 1000.0;
        dc.lkd_end_frame(f);
        const gpu_ms = dc.lkd_last_gpu_ms(self.ctx);
        self.stat_enc_sum_ms += enc_ms;
        self.stat_enc_max_ms = @max(self.stat_enc_max_ms, enc_ms);
        self.stat_gpu_sum_ms += gpu_ms;
        self.stat_gpu_max_ms = @max(self.stat_gpu_max_ms, gpu_ms);
        self.stat_frames += 1;
        {
            // fps over ACTIVE time only: the render loop pauses when idle, so
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
            std.debug.print("frame: encode avg {d:.2} max {d:.2} | gpu avg {d:.2} max {d:.2} ms | ~{d:.0} fps active ({d} frames)\n", .{
                self.stat_enc_sum_ms / n, self.stat_enc_max_ms,
                self.stat_gpu_sum_ms / n, self.stat_gpu_max_ms,
                fps,                      self.stat_frames,
            });
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
        const f = dc.lkd_begin_offscreen(self.ctx, self.width, self.height, &clear) orelse return error.D3d12Failure;
        self.recordDraws(f, u, text_on, sound_on);
        const n = @as(usize, self.width) * self.height * 4;
        const pixels = try alloc.alloc(u8, n);
        errdefer alloc.free(pixels);
        if (dc.lkd_end_offscreen_read(f, pixels.ptr) == 0) return error.D3d12Failure;
        // The render target is the swapchain-native BGRA8 — swizzle to the RGBA
        // the snapshot ABI promises.
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
        if (self.sprite_tex) |t| dc.lkd_free_texture(t);
        if (self.glyph_tex) |t| dc.lkd_free_texture(t);
        if (self.glyph_bold_tex) |t| dc.lkd_free_texture(t);
        if (self.glyph_italic_tex) |t| dc.lkd_free_texture(t);
        dc.lkd_destroy(self.ctx);
    }
};
