//! SDL_GPU transport: device, one flat-color pipeline, persistent buffers, and a
//! per-frame render (window present OR headless offscreen readback). SDL is the
//! window + GPU transport only — all vector work happened in scene.zig. The
//! frame phase here only updates a uniform and issues draws (spec §6).
const std = @import("std");
const cc = @import("c.zig").c;
const png = @import("png.zig");

/// Vertex-shader uniform block (std140; 128 bytes). Matches chart.vert /
/// pattern.vert / sprite.vert. Colour is per-RANGE now (one draw = one colour),
/// so it rides the uniform; `anchor_px`/`cell_px` drive the pattern tiling.
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

fn check(ok: bool, comptime what: []const u8) !void {
    if (!ok) {
        std.debug.print("SDL error at {s}: {s}\n", .{ what, cc.SDL_GetError() });
        return error.SdlFailure;
    }
}
fn checkPtr(p: anytype, comptime what: []const u8) !@typeInfo(@TypeOf(p)).optional.child {
    if (p == null) {
        std.debug.print("SDL null at {s}: {s}\n", .{ what, cc.SDL_GetError() });
        return error.SdlFailure;
    }
    return p.?;
}

/// How to interpret Options.native_handle — the host's own window/view handle.
/// SDL is wrapped internally; the host never sees or links SDL.
pub const NativeKind = enum(c_int) {
    none = 0,
    cocoa_window = 1, // NSWindow*  (macOS)
    cocoa_view = 2, // NSView*    (macOS, embed in a view hierarchy)
    win32_hwnd = 3, // HWND       (Windows)
    x11_window = 4, // X11 Window (XID, passed as the pointer's integer value)
    // UIWindowScene* (iOS). SDL can't wrap an existing UIView — it creates its
    // own full-screen UIWindow inside the given scene (null => active scene);
    // the host layers its chrome window above and forwards touches to us.
    uikit_windowscene = 5,
};

pub const Options = struct {
    width: u32,
    height: u32,
    want_window: bool,
    want_msaa: bool,
    /// Embed into the HOST's existing native window (NSWindow / HWND / X11 …).
    /// lookout wraps it with SDL internally and renders/presents into it — the
    /// host keeps its own toolkit and event loop and never touches SDL. null =>
    /// lookout owns its own SDL window (want_window) or renders offscreen.
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,
};

pub const Gpu = struct {
    device: *cc.SDL_GPUDevice,
    window: ?*cc.SDL_Window,
    pipeline: *cc.SDL_GPUGraphicsPipeline,
    color_format: cc.SDL_GPUTextureFormat,
    sample_count: cc.SDL_GPUSampleCount,
    msaa_used: bool,
    width: u32,
    height: u32,
    /// True when `window` wraps a host-owned native view (embed mode): the host
    /// runs the window; we must never drive its size from our side.
    external_window: bool = false,
    /// Embed mode: the host view's LOGICAL size, from its latest resize() call —
    /// the authoritative point size (SDL's own idea of a wrapped window's size
    /// goes stale across host-driven transitions like full screen).
    host_pt_w: f32 = 0,
    host_pt_h: f32 = 0,
    /// SDL_GetTicks when the swapchain drawable last changed size — scenes
    /// built near a swapchain recreation can be silently broken on this stack,
    /// so the host schedules follow-up rebuilds while this is recent.
    size_changed_ms: i64 = -100000,
    /// pixels per logical point (Retina/HiDPI = 2.0). SDL mouse events are in
    /// logical points; multiply by this to reach the pixel-space viewport.
    pixel_density: f32 = 1.0,

    // offscreen targets (headless path)
    msaa_tex: ?*cc.SDL_GPUTexture = null, // multisample color (if MSAA)
    resolve_tex: ?*cc.SDL_GPUTexture = null, // single-sample readback target
    download_tb: ?*cc.SDL_GPUTransferBuffer = null,

    /// background = S-52 NODATA for the active palette (set by Lookout).
    clear: cc.SDL_FColor = .{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 },

    // The current draw-ready scene from tile57 (one whole-view GPU scene:
    // triangles + sprite/SDF quads + pattern cells, all range-sorted in paint
    // order). Uploaded once per rebuild; a frame only pushes uniforms + draws.
    scene: ?Scene = null,

    // pipelines + shared atlas textures the ranges select between.
    sprite_pipeline: ?*cc.SDL_GPUGraphicsPipeline = null,
    sprite_tex: ?*cc.SDL_GPUTexture = null,
    sampler: ?*cc.SDL_GPUSampler = null,
    sdf_pipeline: ?*cc.SDL_GPUGraphicsPipeline = null,
    pattern_pipeline: ?*cc.SDL_GPUGraphicsPipeline = null,
    glyph_tex: ?*cc.SDL_GPUTexture = null,
    glyph_bold_tex: ?*cc.SDL_GPUTexture = null,
    glyph_italic_tex: ?*cc.SDL_GPUTexture = null,
    /// 2^(display_zoom - scene_build_zoom): scales the pattern cell period so a
    /// constant-screen-size fill tracks the (MVP-scaled) geometry during a zoom
    /// instead of swimming, resetting to 1 when the scene rebuilds at the new zoom.
    pattern_scale: f32 = 1,

    pub fn init(opts: Options, vert_spv: []const u8, frag_spv: []const u8, sprite_vert_spv: []const u8, sprite_frag_spv: []const u8, sdf_frag_spv: []const u8, pattern_vert_spv: []const u8, pattern_frag_spv: []const u8) !Gpu {
        // lookout always owns SDL + the GPU device; the host never sees them.
        // The host app owns main(), not SDL_main — declare that before Init
        // (required on platforms that check, e.g. the iOS UIKit backend).
        cc.SDL_SetMainReady();
        // iOS has no system Vulkan: SDL's default dlopen("libvulkan.dylib")
        // fails, so point it at the app-embedded MoltenVK framework (dlopen
        // resolves @rpath via the app's LC_RPATH → @executable_path/Frameworks).
        // An SDL_VULKAN_LIBRARY env var still overrides via the hint priority.
        if (@import("builtin").os.tag == .ios and std.c.getenv("SDL_VULKAN_LIBRARY") == null) {
            _ = cc.SDL_SetHint(cc.SDL_HINT_VULKAN_LIBRARY, "@rpath/MoltenVK.framework/MoltenVK");
        }
        // iOS simulator: SimMetalHost (the simulator's Metal XPC service)
        // crashes encoding Metal argument buffers — MoltenVK's default
        // descriptor path (SIGABRT in MVKDescriptorPool::initDescriptorSet).
        // Classic descriptor binding works; leave real devices on the default.
        if (@import("builtin").os.tag == .ios and @import("builtin").abi == .simulator) {
            _ = cc.SDL_setenv_unsafe("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "0", 0);
        }
        try check(cc.SDL_Init(cc.SDL_INIT_VIDEO), "SDL_Init");
        // debug_mode only on request: with it on, SDL enables the Khronos
        // validation layer whenever one is installed — a big frame cost, and the
        // layer itself can corrupt state or crash across swapchain recreations
        // (observed: SIGSEGV in vvl::QueueSubmission::BeginUse after the
        // full-screen transition).
        const debug_gpu = std.c.getenv("LOOKOUT_GPU_DEBUG") != null;
        const gpu_props = cc.SDL_CreateProperties();
        defer cc.SDL_DestroyProperties(gpu_props);
        _ = cc.SDL_SetBooleanProperty(gpu_props, cc.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true);
        _ = cc.SDL_SetBooleanProperty(gpu_props, cc.SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, debug_gpu);
        // Opt OUT of the Vulkan device features SDL requests by default —
        // 2D chart rendering uses none of them, and requiring them rejects
        // limited drivers outright (the iOS-simulator MoltenVK device, "GPU
        // Family Apple 2", fails SDL's suitability check on them).
        _ = cc.SDL_SetBooleanProperty(gpu_props, cc.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_CLIP_DISTANCE_BOOLEAN, false);
        _ = cc.SDL_SetBooleanProperty(gpu_props, cc.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_DEPTH_CLAMPING_BOOLEAN, false);
        _ = cc.SDL_SetBooleanProperty(gpu_props, cc.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_INDIRECT_DRAW_FIRST_INSTANCE_BOOLEAN, false);
        _ = cc.SDL_SetBooleanProperty(gpu_props, cc.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_ANISOTROPY_BOOLEAN, false);
        const device = try checkPtr(cc.SDL_CreateGPUDeviceWithProperties(gpu_props), "CreateGPUDevice");

        var window: ?*cc.SDL_Window = null;
        var color_format: cc.SDL_GPUTextureFormat = cc.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        var width = opts.width;
        var height = opts.height;
        var pixel_density: f32 = 1.0;
        if (opts.native_kind != .none) {
            window = createNativeWindow(opts.native_handle, opts.native_kind, opts.width, opts.height);
            if (window == null) std.debug.print("wrap native window failed: {s}\n", .{cc.SDL_GetError()});
        } else if (opts.want_window) {
            // HIGH_PIXEL_DENSITY: render at true pixels on Retina/HiDPI.
            const flags: cc.SDL_WindowFlags = cc.SDL_WINDOW_HIGH_PIXEL_DENSITY | cc.SDL_WINDOW_RESIZABLE;
            window = cc.SDL_CreateWindow("lookout — tile57 SDL_GPU", @intCast(opts.width), @intCast(opts.height), flags);
            if (window == null) std.debug.print("no window ({s}); falling back to offscreen\n", .{cc.SDL_GetError()});
        }
        if (window != null) {
            try check(cc.SDL_ClaimWindowForGPUDevice(device, window), "ClaimWindow");
            color_format = cc.SDL_GetGPUSwapchainTextureFormat(device, window);
            var pw: c_int = 0;
            var ph: c_int = 0;
            if (cc.SDL_GetWindowSizeInPixels(window, &pw, &ph) and pw > 0 and ph > 0) {
                width = @intCast(pw);
                height = @intCast(ph);
                const d = cc.SDL_GetWindowPixelDensity(window);
                if (d > 0) pixel_density = d;
                std.debug.print("window: {d}x{d} logical -> {d}x{d} pixels (density {d:.2})\n", .{ opts.width, opts.height, pw, ph, pixel_density });
            }
        }

        // MSAA probe
        var sample_count: cc.SDL_GPUSampleCount = cc.SDL_GPU_SAMPLECOUNT_1;
        var msaa_used = false;
        if (opts.want_msaa and std.c.getenv("LOOKOUT_NO_MSAA") == null and cc.SDL_GPUTextureSupportsSampleCount(device, color_format, cc.SDL_GPU_SAMPLECOUNT_4)) {
            sample_count = cc.SDL_GPU_SAMPLECOUNT_4;
            msaa_used = true;
        }

        const pipeline = try buildPipeline(device, color_format, sample_count, vert_spv, frag_spv);
        const sprite_pipeline = try buildSpritePipeline(device, color_format, sample_count, sprite_vert_spv, sprite_frag_spv);
        const sdf_pipeline = try buildSpritePipeline(device, color_format, sample_count, sprite_vert_spv, sdf_frag_spv);
        const pattern_pipeline = try buildPatternPipeline(device, color_format, sample_count, pattern_vert_spv, pattern_frag_spv);
        const sampler = try makeSampler(device);

        var g = Gpu{
            .sprite_pipeline = sprite_pipeline,
            .sdf_pipeline = sdf_pipeline,
            .pattern_pipeline = pattern_pipeline,
            .sampler = sampler,
            .device = device,
            .window = window,
            .pipeline = pipeline,
            .color_format = color_format,
            .sample_count = sample_count,
            .msaa_used = msaa_used,
            .width = width,
            .height = height,
            .external_window = opts.native_kind != .none,
            .pixel_density = pixel_density,
        };

        if (window == null) {
            try g.ensureOffscreenTargets(); // headless: full readback (+snapshot)
        } else {
            try g.ensureMsaa(); // windowed MSAA needs the multisample intermediate
        }
        return g;
    }

    // Wrap the host's native window handle (NSWindow / HWND / X11 …) with SDL so
    // we can render into it. The host never links or sees SDL.
    fn createNativeWindow(handle: ?*anyopaque, kind: NativeKind, w: u32, h: u32) ?*cc.SDL_Window {
        const props = cc.SDL_CreateProperties();
        if (props == 0) return null;
        defer cc.SDL_DestroyProperties(props);
        switch (kind) {
            .cocoa_window => _ = cc.SDL_SetPointerProperty(props, cc.SDL_PROP_WINDOW_CREATE_COCOA_WINDOW_POINTER, handle),
            .cocoa_view => _ = cc.SDL_SetPointerProperty(props, cc.SDL_PROP_WINDOW_CREATE_COCOA_VIEW_POINTER, handle),
            .win32_hwnd => _ = cc.SDL_SetPointerProperty(props, cc.SDL_PROP_WINDOW_CREATE_WIN32_HWND_POINTER, handle),
            .x11_window => _ = cc.SDL_SetNumberProperty(props, cc.SDL_PROP_WINDOW_CREATE_X11_WINDOW_NUMBER, @intCast(@intFromPtr(handle))),
            // null scene is fine: SDL defaults to the active UIWindowScene.
            .uikit_windowscene => if (handle != null) {
                _ = cc.SDL_SetPointerProperty(props, cc.SDL_PROP_WINDOW_CREATE_WINDOWSCENE_POINTER, handle);
            },
            .none => return null,
        }
        _ = cc.SDL_SetNumberProperty(props, cc.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, @intCast(w));
        _ = cc.SDL_SetNumberProperty(props, cc.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, @intCast(h));
        _ = cc.SDL_SetBooleanProperty(props, cc.SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true);
        return cc.SDL_CreateWindowWithProperties(props);
    }

    fn makeColorTex(self: *Gpu, sc: cc.SDL_GPUSampleCount, sampler_readable: bool) !*cc.SDL_GPUTexture {
        var info = std.mem.zeroes(cc.SDL_GPUTextureCreateInfo);
        info.type = cc.SDL_GPU_TEXTURETYPE_2D;
        info.format = self.color_format;
        info.usage = cc.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | (if (sampler_readable) cc.SDL_GPU_TEXTUREUSAGE_SAMPLER else 0);
        info.width = self.width;
        info.height = self.height;
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        info.sample_count = sc;
        return try checkPtr(cc.SDL_CreateGPUTexture(self.device, &info), "CreateGPUTexture");
    }

    // Idempotent: the single-sample resolve/readback target + download buffer for
    // offscreen snapshots. Created lazily (embed mode makes them only if snapshot
    // is used). ensureMsaa covers the multisample intermediate separately.
    fn ensureOffscreenTargets(self: *Gpu) !void {
        try self.ensureMsaa();
        if (self.resolve_tex == null) self.resolve_tex = try self.makeColorTex(cc.SDL_GPU_SAMPLECOUNT_1, false);
        if (self.download_tb == null) {
            var tb = std.mem.zeroes(cc.SDL_GPUTransferBufferCreateInfo);
            tb.usage = cc.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
            tb.size = self.width * self.height * 4;
            self.download_tb = try checkPtr(cc.SDL_CreateGPUTransferBuffer(self.device, &tb), "CreateDownloadTB");
        }
    }
    fn ensureMsaa(self: *Gpu) !void {
        if (self.msaa_used and self.msaa_tex == null) self.msaa_tex = try self.makeColorTex(self.sample_count, false);
    }

    /// Resize the render surface. width/height are in logical points; the pixel
    /// size (HiDPI) is derived. Recreates the offscreen/MSAA targets.
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) !void {
        // Embed mode: ONLY remember the host's logical size (the density ground
        // truth) — pixel size and render targets follow the acquired swapchain
        // (renderWindow). Two reasons: SDL_SetWindowSize on a wrapped NSWindow
        // re-enters the AppKit layout pass that triggered the resize (unbounded
        // recursion, aborts in the full-screen transition), and SDL's pixel
        // query goes stale across host transitions — acting on it would thrash
        // the MSAA target against the real drawable and blank the resolve.
        if (self.external_window) {
            self.host_pt_w = @floatFromInt(width_pts);
            self.host_pt_h = @floatFromInt(height_pts);
            return;
        }
        var pw = width_pts;
        var ph = height_pts;
        if (self.window) |w| {
            _ = cc.SDL_SetWindowSize(w, @intCast(width_pts), @intCast(height_pts));
            var qw: c_int = 0;
            var qh: c_int = 0;
            if (cc.SDL_GetWindowSizeInPixels(w, &qw, &qh) and qw > 0 and qh > 0) {
                pw = @intCast(qw);
                ph = @intCast(qh);
            }
        }
        if (pw == self.width and ph == self.height) return;
        self.width = pw;
        self.height = ph;
        if (self.msaa_tex) |t| {
            cc.SDL_ReleaseGPUTexture(self.device, t);
            self.msaa_tex = null;
        }
        if (self.resolve_tex) |t| {
            cc.SDL_ReleaseGPUTexture(self.device, t);
            self.resolve_tex = null;
        }
        if (self.download_tb) |t| {
            cc.SDL_ReleaseGPUTransferBuffer(self.device, t);
            self.download_tb = null;
        }
        if (self.window == null) {
            try self.ensureOffscreenTargets();
        } else if (self.msaa_used) {
            self.msaa_tex = try self.makeColorTex(self.sample_count, false);
        }
        // WORKAROUND (SDL_GPU Vulkan + MoltenVK): after the implicit swapchain
        // recreation a resize causes, geometry draws stop rasterizing (clears
        // still land — the window shows only background). A full release +
        // re-claim rebuilds the swapchain cleanly and restores rasterization; a
        // minimal SDL_GPU triangle app reproduces the underlying bug. Safe here:
        // resize is called between frames, so no command buffer is in flight.
        if (self.window) |w| {
            _ = cc.SDL_WaitForGPUIdle(self.device);
            cc.SDL_ReleaseWindowFromGPUDevice(self.device, w);
            if (!cc.SDL_ClaimWindowForGPUDevice(self.device, w)) {
                std.debug.print("re-claim window failed: {s}\n", .{cc.SDL_GetError()});
                return error.SdlFailure;
            }
            self.color_format = cc.SDL_GetGPUSwapchainTextureFormat(self.device, w);
        }
    }

    fn buildPipeline(device: *cc.SDL_GPUDevice, color_format: cc.SDL_GPUTextureFormat, sc: cc.SDL_GPUSampleCount, vert_spv: []const u8, frag_spv: []const u8) !*cc.SDL_GPUGraphicsPipeline {
        var vinfo = std.mem.zeroes(cc.SDL_GPUShaderCreateInfo);
        vinfo.code = vert_spv.ptr;
        vinfo.code_size = vert_spv.len;
        vinfo.entrypoint = "main";
        vinfo.format = cc.SDL_GPU_SHADERFORMAT_SPIRV;
        vinfo.stage = cc.SDL_GPU_SHADERSTAGE_VERTEX;
        vinfo.num_uniform_buffers = 1;
        const vshader = try checkPtr(cc.SDL_CreateGPUShader(device, &vinfo), "vertex shader");
        defer cc.SDL_ReleaseGPUShader(device, vshader);

        var finfo = std.mem.zeroes(cc.SDL_GPUShaderCreateInfo);
        finfo.code = frag_spv.ptr;
        finfo.code_size = frag_spv.len;
        finfo.entrypoint = "main";
        finfo.format = cc.SDL_GPU_SHADERFORMAT_SPIRV;
        finfo.stage = cc.SDL_GPU_SHADERSTAGE_FRAGMENT;
        const fshader = try checkPtr(cc.SDL_CreateGPUShader(device, &finfo), "fragment shader");
        defer cc.SDL_ReleaseGPUShader(device, fshader);

        // tile57_gpu_vertex (24B): world f2@0, local f2@8, scamin f@16,
        // packed(disp_cat|map_align<<8) as a u32 read at @20. Colour is per-range
        // (a uniform), so there is no second vertex buffer.
        const vbufs = [_]cc.SDL_GPUVertexBufferDescription{
            .{ .slot = 0, .pitch = @sizeOf(cc.tile57_gpu_vertex), .input_rate = cc.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
        };
        const vattrs = [_]cc.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
            .{ .location = 1, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
            .{ .location = 2, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 16 },
            .{ .location = 3, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_UINT, .offset = 20 },
        };

        var blend = std.mem.zeroes(cc.SDL_GPUColorTargetBlendState);
        blend.enable_blend = true;
        blend.src_color_blendfactor = cc.SDL_GPU_BLENDFACTOR_SRC_ALPHA;
        blend.dst_color_blendfactor = cc.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend.color_blend_op = cc.SDL_GPU_BLENDOP_ADD;
        blend.src_alpha_blendfactor = cc.SDL_GPU_BLENDFACTOR_ONE;
        blend.dst_alpha_blendfactor = cc.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend.alpha_blend_op = cc.SDL_GPU_BLENDOP_ADD;

        const color_targets = [_]cc.SDL_GPUColorTargetDescription{.{ .format = color_format, .blend_state = blend }};

        var p = std.mem.zeroes(cc.SDL_GPUGraphicsPipelineCreateInfo);
        p.vertex_shader = vshader;
        p.fragment_shader = fshader;
        p.vertex_input_state = .{
            .vertex_buffer_descriptions = &vbufs,
            .num_vertex_buffers = 1,
            .vertex_attributes = &vattrs,
            .num_vertex_attributes = 4,
        };
        p.primitive_type = cc.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        p.rasterizer_state.fill_mode = cc.SDL_GPU_FILLMODE_FILL;
        p.rasterizer_state.cull_mode = cc.SDL_GPU_CULLMODE_NONE;
        p.rasterizer_state.enable_depth_clip = true; // clip z=2 cull verts
        p.multisample_state.sample_count = sc;
        p.target_info = .{
            .color_target_descriptions = &color_targets,
            .num_color_targets = 1,
            .depth_stencil_format = 0,
            .has_depth_stencil_target = false,
        };
        return try checkPtr(cc.SDL_CreateGPUGraphicsPipeline(device, &p), "CreateGraphicsPipeline");
    }

    // Textured-quad pipeline for sprite symbols (and SDF text). QuadVertex layout;
    // one fragment sampler (the atlas).
    /// Pipeline for area fill patterns: polygon geometry in world space, with
    /// the atlas cell and its screen size carried per vertex so one draw can
    /// cover many different patterns without a uniform change per polygon.
    fn buildPatternPipeline(device: *cc.SDL_GPUDevice, color_format: cc.SDL_GPUTextureFormat, sc: cc.SDL_GPUSampleCount, vspv: []const u8, fspv: []const u8) !*cc.SDL_GPUGraphicsPipeline {
        var vinfo = std.mem.zeroes(cc.SDL_GPUShaderCreateInfo);
        vinfo.code = vspv.ptr;
        vinfo.code_size = vspv.len;
        vinfo.entrypoint = "main";
        vinfo.format = cc.SDL_GPU_SHADERFORMAT_SPIRV;
        vinfo.stage = cc.SDL_GPU_SHADERSTAGE_VERTEX;
        vinfo.num_uniform_buffers = 1;
        const vshader = try checkPtr(cc.SDL_CreateGPUShader(device, &vinfo), "pattern vertex shader");
        defer cc.SDL_ReleaseGPUShader(device, vshader);

        var finfo = std.mem.zeroes(cc.SDL_GPUShaderCreateInfo);
        finfo.code = fspv.ptr;
        finfo.code_size = fspv.len;
        finfo.entrypoint = "main";
        finfo.format = cc.SDL_GPU_SHADERFORMAT_SPIRV;
        finfo.stage = cc.SDL_GPU_SHADERSTAGE_FRAGMENT;
        finfo.num_samplers = 1;
        const fshader = try checkPtr(cc.SDL_CreateGPUShader(device, &finfo), "pattern fragment shader");
        defer cc.SDL_ReleaseGPUShader(device, fshader);

        // Patterns draw the tessellated interior (tile57_gpu_vertex), tiling the
        // cell per-fragment; the vertex layout matches the chart pipeline.
        const vbufs = [_]cc.SDL_GPUVertexBufferDescription{
            .{ .slot = 0, .pitch = @sizeOf(cc.tile57_gpu_vertex), .input_rate = cc.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
        };
        const vattrs = [_]cc.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
            .{ .location = 1, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
            .{ .location = 2, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 16 },
            .{ .location = 3, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_UINT, .offset = 20 },
        };
        var blend = std.mem.zeroes(cc.SDL_GPUColorTargetBlendState);
        blend.enable_blend = true;
        blend.src_color_blendfactor = cc.SDL_GPU_BLENDFACTOR_SRC_ALPHA;
        blend.dst_color_blendfactor = cc.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend.color_blend_op = cc.SDL_GPU_BLENDOP_ADD;
        blend.src_alpha_blendfactor = cc.SDL_GPU_BLENDFACTOR_ONE;
        blend.dst_alpha_blendfactor = cc.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend.alpha_blend_op = cc.SDL_GPU_BLENDOP_ADD;
        const color_targets = [_]cc.SDL_GPUColorTargetDescription{.{ .format = color_format, .blend_state = blend }};

        var p = std.mem.zeroes(cc.SDL_GPUGraphicsPipelineCreateInfo);
        p.vertex_shader = vshader;
        p.fragment_shader = fshader;
        p.vertex_input_state = .{
            .vertex_buffer_descriptions = &vbufs,
            .num_vertex_buffers = 1,
            .vertex_attributes = &vattrs,
            .num_vertex_attributes = 4,
        };
        p.primitive_type = cc.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        p.rasterizer_state.fill_mode = cc.SDL_GPU_FILLMODE_FILL;
        p.rasterizer_state.cull_mode = cc.SDL_GPU_CULLMODE_NONE;
        p.rasterizer_state.enable_depth_clip = true;
        p.multisample_state.sample_count = sc;
        p.target_info = .{ .color_target_descriptions = &color_targets, .num_color_targets = 1, .depth_stencil_format = 0, .has_depth_stencil_target = false };
        return try checkPtr(cc.SDL_CreateGPUGraphicsPipeline(device, &p), "pattern pipeline");
    }

    fn buildSpritePipeline(device: *cc.SDL_GPUDevice, color_format: cc.SDL_GPUTextureFormat, sc: cc.SDL_GPUSampleCount, vspv: []const u8, fspv: []const u8) !*cc.SDL_GPUGraphicsPipeline {
        var vinfo = std.mem.zeroes(cc.SDL_GPUShaderCreateInfo);
        vinfo.code = vspv.ptr;
        vinfo.code_size = vspv.len;
        vinfo.entrypoint = "main";
        vinfo.format = cc.SDL_GPU_SHADERFORMAT_SPIRV;
        vinfo.stage = cc.SDL_GPU_SHADERSTAGE_VERTEX;
        vinfo.num_uniform_buffers = 1;
        const vshader = try checkPtr(cc.SDL_CreateGPUShader(device, &vinfo), "sprite vertex shader");
        defer cc.SDL_ReleaseGPUShader(device, vshader);

        var finfo = std.mem.zeroes(cc.SDL_GPUShaderCreateInfo);
        finfo.code = fspv.ptr;
        finfo.code_size = fspv.len;
        finfo.entrypoint = "main";
        finfo.format = cc.SDL_GPU_SHADERFORMAT_SPIRV;
        finfo.stage = cc.SDL_GPU_SHADERSTAGE_FRAGMENT;
        finfo.num_samplers = 1;
        const fshader = try checkPtr(cc.SDL_CreateGPUShader(device, &finfo), "sprite fragment shader");
        defer cc.SDL_ReleaseGPUShader(device, fshader);

        // tile57_gpu_quad (40B): world f2@0, local f2@8, uv f2@16, colour
        // ubyte4@24, weight f@28, scamin f@32, packed u32@36.
        const vbufs = [_]cc.SDL_GPUVertexBufferDescription{
            .{ .slot = 0, .pitch = @sizeOf(cc.tile57_gpu_quad), .input_rate = cc.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
        };
        const vattrs = [_]cc.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 }, // world
            .{ .location = 1, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 }, // local
            .{ .location = 2, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 16 }, // uv
            .{ .location = 3, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 24 }, // color
            .{ .location = 4, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 28 }, // SDF weight
            .{ .location = 5, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 32 }, // scamin
            .{ .location = 6, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_UINT, .offset = 36 }, // packed
        };
        var blend = std.mem.zeroes(cc.SDL_GPUColorTargetBlendState);
        blend.enable_blend = true;
        blend.src_color_blendfactor = cc.SDL_GPU_BLENDFACTOR_SRC_ALPHA;
        blend.dst_color_blendfactor = cc.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend.color_blend_op = cc.SDL_GPU_BLENDOP_ADD;
        blend.src_alpha_blendfactor = cc.SDL_GPU_BLENDFACTOR_ONE;
        blend.dst_alpha_blendfactor = cc.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        blend.alpha_blend_op = cc.SDL_GPU_BLENDOP_ADD;
        const color_targets = [_]cc.SDL_GPUColorTargetDescription{.{ .format = color_format, .blend_state = blend }};

        var p = std.mem.zeroes(cc.SDL_GPUGraphicsPipelineCreateInfo);
        p.vertex_shader = vshader;
        p.fragment_shader = fshader;
        p.vertex_input_state = .{
            .vertex_buffer_descriptions = &vbufs,
            .num_vertex_buffers = 1,
            .vertex_attributes = &vattrs,
            .num_vertex_attributes = 7,
        };
        p.primitive_type = cc.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        p.rasterizer_state.fill_mode = cc.SDL_GPU_FILLMODE_FILL;
        p.rasterizer_state.cull_mode = cc.SDL_GPU_CULLMODE_NONE;
        p.rasterizer_state.enable_depth_clip = true; // clip z=2 cull verts
        p.multisample_state.sample_count = sc;
        p.target_info = .{ .color_target_descriptions = &color_targets, .num_color_targets = 1, .depth_stencil_format = 0, .has_depth_stencil_target = false };
        return try checkPtr(cc.SDL_CreateGPUGraphicsPipeline(device, &p), "CreateSpritePipeline");
    }

    fn makeSampler(device: *cc.SDL_GPUDevice) !*cc.SDL_GPUSampler {
        var si = std.mem.zeroes(cc.SDL_GPUSamplerCreateInfo);
        si.min_filter = cc.SDL_GPU_FILTER_LINEAR;
        si.mag_filter = cc.SDL_GPU_FILTER_LINEAR;
        si.mipmap_mode = cc.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;
        si.address_mode_u = cc.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        si.address_mode_v = cc.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        si.address_mode_w = cc.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        return try checkPtr(cc.SDL_CreateGPUSampler(device, &si), "CreateSampler");
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
    /// Upload an RGBA8 atlas to a fresh sampler texture.
    fn makeAtlasTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !*cc.SDL_GPUTexture {
        var info = std.mem.zeroes(cc.SDL_GPUTextureCreateInfo);
        info.type = cc.SDL_GPU_TEXTURETYPE_2D;
        info.format = cc.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        info.usage = cc.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        info.width = w;
        info.height = h;
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        const tex = try checkPtr(cc.SDL_CreateGPUTexture(self.device, &info), "CreateAtlasTexture");

        var ti = std.mem.zeroes(cc.SDL_GPUTransferBufferCreateInfo);
        ti.usage = cc.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        ti.size = @intCast(rgba.len);
        const tb = try checkPtr(cc.SDL_CreateGPUTransferBuffer(self.device, &ti), "AtlasTB");
        defer cc.SDL_ReleaseGPUTransferBuffer(self.device, tb);
        const map = cc.SDL_MapGPUTransferBuffer(self.device, tb, false) orelse return error.SdlFailure;
        @memcpy(@as([*]u8, @ptrCast(map))[0..rgba.len], rgba);
        cc.SDL_UnmapGPUTransferBuffer(self.device, tb);

        const cmd = cc.SDL_AcquireGPUCommandBuffer(self.device);
        const cp = cc.SDL_BeginGPUCopyPass(cmd);
        var src = std.mem.zeroes(cc.SDL_GPUTextureTransferInfo);
        src.transfer_buffer = tb;
        src.pixels_per_row = w;
        src.rows_per_layer = h;
        var dst = std.mem.zeroes(cc.SDL_GPUTextureRegion);
        dst.texture = tex;
        dst.w = w;
        dst.h = h;
        dst.d = 1;
        cc.SDL_UploadToGPUTexture(cp, &src, &dst, false);
        cc.SDL_EndGPUCopyPass(cp);
        try check(cc.SDL_SubmitGPUCommandBuffer(cmd), "submit atlas upload");
        return tex;
    }

    // ---- upload the built scene into persistent GPU buffers (once) ----------
    // The upload is VERIFIED (read back and compared) and retried: copy commands
    // submitted around a swapchain recreation (a host window transition) can be
    // silently dropped on the macOS stack, leaving a zeroed buffer — a chart
    // that "renders" nothing. A few ms per scene rebuild buys certainty.
    fn uploadBuffer(self: *Gpu, usage: cc.SDL_GPUBufferUsageFlags, bytes: []const u8) !*cc.SDL_GPUBuffer {
        var bi = std.mem.zeroes(cc.SDL_GPUBufferCreateInfo);
        bi.usage = usage;
        bi.size = @intCast(bytes.len);
        const buf = try checkPtr(cc.SDL_CreateGPUBuffer(self.device, &bi), "CreateGPUBuffer");
        errdefer cc.SDL_ReleaseGPUBuffer(self.device, buf);

        var ti = std.mem.zeroes(cc.SDL_GPUTransferBufferCreateInfo);
        ti.usage = cc.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        ti.size = @intCast(bytes.len);
        const tb = try checkPtr(cc.SDL_CreateGPUTransferBuffer(self.device, &ti), "CreateUploadTB");
        defer cc.SDL_ReleaseGPUTransferBuffer(self.device, tb);

        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            const map = cc.SDL_MapGPUTransferBuffer(self.device, tb, true);
            const dst: [*]u8 = @ptrCast(map);
            @memcpy(dst[0..bytes.len], bytes);
            cc.SDL_UnmapGPUTransferBuffer(self.device, tb);

            const cmd = cc.SDL_AcquireGPUCommandBuffer(self.device);
            const cp = cc.SDL_BeginGPUCopyPass(cmd);
            const src = cc.SDL_GPUTransferBufferLocation{ .transfer_buffer = tb, .offset = 0 };
            const dstr = cc.SDL_GPUBufferRegion{ .buffer = buf, .offset = 0, .size = @intCast(bytes.len) };
            cc.SDL_UploadToGPUBuffer(cp, &src, &dstr, false);
            cc.SDL_EndGPUCopyPass(cp);
            try check(cc.SDL_SubmitGPUCommandBuffer(cmd), "submit upload");
            if (self.verifyBuffer(buf, bytes)) return buf;
            std.debug.print("scene upload verify failed (attempt {d}); retrying\n", .{attempt + 1});
        }
        return error.SdlFailure;
    }

    // Read `buf` back and compare with `bytes` (spot checks + full tail); false
    // when the GPU copy didn't land.
    fn verifyBuffer(self: *Gpu, buf: *cc.SDL_GPUBuffer, bytes: []const u8) bool {
        var ti = std.mem.zeroes(cc.SDL_GPUTransferBufferCreateInfo);
        ti.usage = cc.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        ti.size = @intCast(bytes.len);
        const tb = cc.SDL_CreateGPUTransferBuffer(self.device, &ti) orelse return false;
        defer cc.SDL_ReleaseGPUTransferBuffer(self.device, tb);
        const cmd = cc.SDL_AcquireGPUCommandBuffer(self.device);
        const cp = cc.SDL_BeginGPUCopyPass(cmd);
        const src = cc.SDL_GPUBufferRegion{ .buffer = buf, .offset = 0, .size = @intCast(bytes.len) };
        const dst = cc.SDL_GPUTransferBufferLocation{ .transfer_buffer = tb, .offset = 0 };
        cc.SDL_DownloadFromGPUBuffer(cp, &src, &dst);
        cc.SDL_EndGPUCopyPass(cp);
        const fence = cc.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
        if (fence == null) return false;
        _ = cc.SDL_WaitForGPUFences(self.device, true, @ptrCast(&fence), 1);
        cc.SDL_ReleaseGPUFence(self.device, fence);
        const map: [*]const u8 = @ptrCast(cc.SDL_MapGPUTransferBuffer(self.device, tb, false) orelse return false);
        defer cc.SDL_UnmapGPUTransferBuffer(self.device, tb);
        return std.mem.eql(u8, map[0..bytes.len], bytes);
    }

    // ---- the draw-ready scene from tile57 ----------------------------------
    // One pattern cell as its own sampler texture, plus its device-px size (the
    // on-screen tiling period). Uploaded per pattern the scene references.
    const PatternTex = struct { tex: ?*cc.SDL_GPUTexture = null, w: f32 = 1, h: f32 = 1 };

    /// GPU-resident whole-view scene: the triangle stream (pre-expanded from
    /// tile57's indexed buffers — see uploadGpuScene), the sprite/SDF quads, the
    /// paint-ordered ranges (host-owned copy), and one texture per pattern cell.
    pub const Scene = struct {
        vbuf: ?*cc.SDL_GPUBuffer = null, // de-indexed triangle vertices (tile57_gpu_vertex)
        qbuf: ?*cc.SDL_GPUBuffer = null, // sprite/SDF quads (tile57_gpu_quad)
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
        // Build the NEW scene's buffers BEFORE releasing the old ones: freeing
        // first lets the driver hand back a recycled buffer handle, and a stale
        // binding cache keyed on the handle can then reference the destroyed
        // buffer — draws that silently produce nothing.
        var out = Scene{ .alloc = alloc };
        errdefer self.freeSceneValue(&out);

        if (s.vertex_count > 0 and s.index_count > 0) {
            // The engine hands indexed triangles, but we expand them into a flat
            // vertex stream and draw NON-indexed. Indexed draws are broken on the
            // macOS stack under this renderer (SDL_GPU Vulkan -> MoltenVK 1.4.1
            // -> Metal): with byte-verified buffer contents, matching pipeline
            // layouts and clean validation, vkCmdDrawIndexed deterministically
            // resolves wrong (in-buffer but incorrect) vertices for draws deeper
            // into the index buffer, shredding polygons into giant wedges. The
            // same data drawn non-indexed is pixel-correct. Costs ~2x triangle
            // vertex memory (a few MB per scene) — correctness wins.
            const verts = s.vertices[0..s.vertex_count];
            const idx = s.indices[0..s.index_count];
            const flat = try alloc.alloc(cc.tile57_gpu_vertex, s.index_count);
            defer alloc.free(flat);
            for (idx, 0..) |ii, k| flat[k] = verts[ii];
            out.vbuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(flat));
            out.index_count = @intCast(s.index_count);
        }
        if (s.quad_count > 0) {
            const quads = s.quads[0..s.quad_count];
            out.qbuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(quads));
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
                    p.tex = self.makeAtlasTexture(cell.rgba[0..need], cell.w, cell.h) catch null;
            }
        }
        self.freeScene();
        self.scene = out;
    }

    fn freeSceneValue(self: *Gpu, s: *Scene) void {
        const d = self.device;
        if (s.vbuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        if (s.qbuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        for (s.patterns) |p| if (p.tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
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
    // GPU per atlas + whether the per-face textures uploaded. bold/italic=0 means
    // the tiles carry no tier (stale cache / not baked with labels); a nonzero
    // count with the texture present means the data is fine and the render is at
    // fault.
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

    // ---- record + issue one frame's draws into a target --------------------
    // Walk the ranges in paint order, switching pipeline per range: triangles ->
    // flat-colour (or pattern) pipeline; quads -> sprite or SDF pipeline. Both
    // draw non-indexed (the triangle stream is de-indexed at upload — see
    // uploadGpuScene). `text_on`/`sound_on` drop those ranges live (the engine
    // emits them; the host gates by skipping the draw). The pattern anchor
    // + per-cell period ride the uniform.
    fn recordDraws(self: *Gpu, cmd: *cc.SDL_GPUCommandBuffer, target: *cc.SDL_GPUTexture, resolve: ?*cc.SDL_GPUTexture, u: Uniforms, text_on: bool, sound_on: bool) void {
        var cti = std.mem.zeroes(cc.SDL_GPUColorTargetInfo);
        cti.texture = target;
        cti.clear_color = self.clear; // S-52 NODATA for the active palette
        cti.load_op = cc.SDL_GPU_LOADOP_CLEAR;
        if (resolve) |rt| {
            cti.store_op = cc.SDL_GPU_STOREOP_RESOLVE;
            cti.resolve_texture = rt;
        } else cti.store_op = cc.SDL_GPU_STOREOP_STORE;
        const pass = cc.SDL_BeginGPURenderPass(cmd, &cti, 1, null);
        if (pass == null) std.debug.print("BeginGPURenderPass FAILED: {s}\n", .{cc.SDL_GetError()});
        defer cc.SDL_EndGPURenderPass(pass);
        const vp = cc.SDL_GPUViewport{ .x = 0, .y = 0, .w = @floatFromInt(self.width), .h = @floatFromInt(self.height), .min_depth = 0, .max_depth = 1 };
        cc.SDL_SetGPUViewport(pass, &vp);
        // Set the scissor EXPLICITLY every pass: after a swapchain recreation
        // (host window transition) the inherited scissor state can be stale —
        // the load-op clear ignores scissor, so the symptom is a chart that
        // "renders" only its background.
        const scis = cc.SDL_Rect{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
        cc.SDL_SetGPUScissor(pass, &scis);

        if (std.c.getenv("LOOKOUT_DRAW_DEBUG") != null) {
            const S = struct {
                var n: u64 = 0;
            };
            S.n += 1;
            if (S.n % 20 == 1) {
                if (self.scene) |*sc| {
                    std.debug.print("draw: ranges={d} idx={d} vp={d}x{d} mvp=({d:.3},{d:.3},{d:.3},{d:.3}) cat={x} cs={e:.3} wrap={d:.4} sz={d:.2}\n", .{ sc.ranges.len, sc.index_count, self.width, self.height, u.mvp[0], u.mvp[5], u.mvp[12], u.mvp[13], u.cat_mask, u.current_scale, u.wrap_x, u.size_scale });
                } else {
                    std.debug.print("draw: NO SCENE vp={d}x{d}\n", .{ self.width, self.height });
                }
            }
        }
        const s = if (self.scene) |*sc| sc else return;
        self.labelDebug(s);
        const vbind = [_]cc.SDL_GPUBufferBinding{.{ .buffer = s.vbuf, .offset = 0 }};
        const qbind = [_]cc.SDL_GPUBufferBinding{.{ .buffer = s.qbuf, .offset = 0 }};

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
            // range only; SCAMIN still culls them (disp_cat != base). Mirrors
            // resolve.categoryVisible's SOUNDG special-case on the vector/pixel paths.
            if (r.kind == cc.TILE57_GPU_SOUNDING) uu.cat_mask |= @as(u32, 1) << 2;
            if (r.prim == cc.TILE57_GPU_TRIANGLES) {
                if (s.vbuf == null) continue;
                cc.SDL_BindGPUVertexBuffers(pass, 0, &vbind, 1);
                if (r.pattern != cc.TILE57_GPU_NO_PATTERN and self.pattern_pipeline != null and r.pattern < s.patterns.len and s.patterns[r.pattern].tex != null) {
                    const pt = s.patterns[r.pattern];
                    // Scale the cell with the zoom so it tracks the geometry (which
                    // the MVP scales) rather than swimming during a zoom animation.
                    const cs = self.pixel_density * self.pattern_scale;
                    uu.cell_px = .{ pt.w * cs, pt.h * cs };
                    cc.SDL_BindGPUGraphicsPipeline(pass, self.pattern_pipeline);
                    const samp = [_]cc.SDL_GPUTextureSamplerBinding{.{ .texture = pt.tex, .sampler = self.sampler }};
                    cc.SDL_BindGPUFragmentSamplers(pass, 0, &samp, 1);
                } else if (r.pattern != cc.TILE57_GPU_NO_PATTERN) {
                    continue; // a pattern with no cell texture: the fill under it already drew
                } else {
                    uu.color = normColor(r.color);
                    cc.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
                }
                cc.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
                // range.first/count are index-buffer units, which after the
                // upload-time expansion are exactly flat-vertex units.
                cc.SDL_DrawGPUPrimitives(pass, r.count, 1, r.first, 0);
            } else { // QUADS
                if (s.qbuf == null) continue;
                const is_glyph = r.atlas == cc.TILE57_GPU_ATLAS_GLYPH or
                    r.atlas == cc.TILE57_GPU_ATLAS_GLYPH_BOLD or
                    r.atlas == cc.TILE57_GPU_ATLAS_GLYPH_ITALIC;
                const tex = switch (r.atlas) {
                    cc.TILE57_GPU_ATLAS_GLYPH => self.glyph_tex,
                    cc.TILE57_GPU_ATLAS_GLYPH_BOLD => self.glyph_bold_tex orelse self.glyph_tex,
                    cc.TILE57_GPU_ATLAS_GLYPH_ITALIC => self.glyph_italic_tex orelse self.glyph_tex,
                    else => self.sprite_tex,
                };
                const pipe = if (is_glyph) self.sdf_pipeline else self.sprite_pipeline;
                if (tex == null or pipe == null) continue;
                cc.SDL_BindGPUGraphicsPipeline(pass, pipe);
                cc.SDL_BindGPUVertexBuffers(pass, 0, &qbind, 1);
                const samp = [_]cc.SDL_GPUTextureSamplerBinding{.{ .texture = tex, .sampler = self.sampler }};
                cc.SDL_BindGPUFragmentSamplers(pass, 0, &samp, 1);
                cc.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
                cc.SDL_DrawGPUPrimitives(pass, r.count, 1, r.first, 0);
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

    /// Render one frame to the window and present. Returns false if no window.
    pub fn renderWindow(self: *Gpu, u: Uniforms, text_on: bool, sound_on: bool) !bool {
        const window = self.window orelse return false;
        const cmd = try checkPtr(cc.SDL_AcquireGPUCommandBuffer(self.device), "AcquireCmd");
        var swap: ?*cc.SDL_GPUTexture = null;
        var w: u32 = 0;
        var h: u32 = 0;
        try check(cc.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swap, &w, &h), "AcquireSwapchain");
        if (swap == null) {
            _ = cc.SDL_SubmitGPUCommandBuffer(cmd);
            return true; // window minimized etc.
        }
        // The swapchain drawable is the ground truth for the frame's size — on a
        // wrapped native view it can differ from what SDL_GetWindowSizeInPixels
        // claims (the layer may be laid out, or scaled, after the wrap). Adopt
        // it: viewport, MSAA target and (via logicalSize) the camera all follow,
        // so the picture, the cursor math and the mark sizes stay consistent.
        if (w != self.width or h != self.height) {
            std.debug.print("swapchain {d}x{d} (was {d}x{d}); adopting\n", .{ w, h, self.width, self.height });
            self.size_changed_ms = @intCast(cc.SDL_GetTicks());
            self.width = w;
            self.height = h;
            if (self.msaa_tex) |t| {
                cc.SDL_ReleaseGPUTexture(self.device, t);
                self.msaa_tex = null;
            }
            if (self.resolve_tex) |t| {
                cc.SDL_ReleaseGPUTexture(self.device, t);
                self.resolve_tex = null;
            }
            if (self.download_tb) |t| {
                cc.SDL_ReleaseGPUTransferBuffer(self.device, t);
                self.download_tb = null;
            }
            try self.ensureMsaa();
            // WORKAROUND (SDL_GPU Vulkan + MoltenVK): after the IMPLICIT
            // swapchain recreation that follows a window resize, geometry draws
            // stop rasterizing — clears still land, so the window shows only
            // background. (A minimal 80-line SDL_GPU triangle app reproduces
            // it.) A full release + re-claim of the window rebuilds the
            // swapchain cleanly and restores rasterization. We skip this frame
            // (submit the empty command buffer — cancel is illegal once a
            // swapchain texture is acquired) and draw next tick.
            _ = cc.SDL_SubmitGPUCommandBuffer(cmd);
            _ = cc.SDL_WaitForGPUIdle(self.device);
            cc.SDL_ReleaseWindowFromGPUDevice(self.device, window);
            if (!cc.SDL_ClaimWindowForGPUDevice(self.device, window)) {
                std.debug.print("re-claim window failed: {s}\n", .{cc.SDL_GetError()});
                return false;
            }
            self.color_format = cc.SDL_GetGPUSwapchainTextureFormat(self.device, window);
            return true;
        }
        // Density is recomputed EVERY frame, not just on a size change: during an
        // animated transition (full screen) the point size briefly lags the
        // drawable, and a ratio captured at that moment would otherwise stick
        // forever, leaving every mark and the camera at the wrong scale. For a
        // wrapped view the point size comes from the HOST's resize calls —
        // SDL_GetWindowSize goes stale across host-driven transitions.
        {
            var lw_f: f32 = 0;
            if (self.external_window and self.host_pt_w > 0) {
                lw_f = self.host_pt_w;
            } else {
                var lw: c_int = 0;
                var lh: c_int = 0;
                if (cc.SDL_GetWindowSize(window, &lw, &lh) and lw > 0) lw_f = @floatFromInt(lw);
            }
            if (lw_f > 0) {
                const d = @as(f32, @floatFromInt(w)) / lw_f;
                if (d > 0.25 and d < 8 and @abs(d - self.pixel_density) > 0.001) {
                    std.debug.print("pixel density {d:.2} -> {d:.2}\n", .{ self.pixel_density, d });
                    self.pixel_density = d;
                }
            }
        }
        if (self.msaa_used) {
            self.recordDraws(cmd, self.msaa_tex.?, swap, u, text_on, sound_on);
        } else {
            self.recordDraws(cmd, swap.?, null, u, text_on, sound_on);
        }
        try check(cc.SDL_SubmitGPUCommandBuffer(cmd), "submit frame");
        return true;
    }

    /// Render one frame offscreen and read the pixels back (RGBA8, top-down).
    pub fn renderOffscreen(self: *Gpu, alloc: std.mem.Allocator, u: Uniforms, text_on: bool, sound_on: bool) ![]u8 {
        try self.ensureOffscreenTargets(); // lazy (embed mode makes these on first snapshot)
        const resolve = self.resolve_tex orelse return error.NoOffscreenTarget;
        const cmd = try checkPtr(cc.SDL_AcquireGPUCommandBuffer(self.device), "AcquireCmd");
        if (self.msaa_used) {
            self.recordDraws(cmd, self.msaa_tex.?, resolve, u, text_on, sound_on);
        } else {
            self.recordDraws(cmd, resolve, null, u, text_on, sound_on);
        }
        // download resolve_tex -> transfer buffer
        const cp = cc.SDL_BeginGPUCopyPass(cmd);
        var region = std.mem.zeroes(cc.SDL_GPUTextureRegion);
        region.texture = resolve;
        region.w = self.width;
        region.h = self.height;
        region.d = 1;
        var dst = std.mem.zeroes(cc.SDL_GPUTextureTransferInfo);
        dst.transfer_buffer = self.download_tb.?;
        dst.pixels_per_row = self.width;
        dst.rows_per_layer = self.height;
        cc.SDL_DownloadFromGPUTexture(cp, &region, &dst);
        cc.SDL_EndGPUCopyPass(cp);

        const fence = cc.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
        if (fence != null) {
            _ = cc.SDL_WaitForGPUFences(self.device, true, @ptrCast(&fence), 1);
            cc.SDL_ReleaseGPUFence(self.device, fence);
        }
        const map = cc.SDL_MapGPUTransferBuffer(self.device, self.download_tb.?, false);
        const src: [*]const u8 = @ptrCast(map);
        const n = self.width * self.height * 4;
        const pixels = try alloc.dupe(u8, src[0..n]);
        cc.SDL_UnmapGPUTransferBuffer(self.device, self.download_tb.?);
        return pixels;
    }

    pub fn savePng(self: *Gpu, alloc: std.mem.Allocator, path: []const u8, u: Uniforms, text_on: bool, sound_on: bool) !void {
        const pixels = try self.renderOffscreen(alloc, u, text_on, sound_on);
        defer alloc.free(pixels);
        try png.write(alloc, path, pixels, self.width, self.height);
    }

    pub fn deinit(self: *Gpu) void {
        const d = self.device;
        self.freeScene();
        if (self.msaa_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.resolve_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.download_tb) |t| cc.SDL_ReleaseGPUTransferBuffer(d, t);
        cc.SDL_ReleaseGPUGraphicsPipeline(d, self.pipeline);
        if (self.sprite_pipeline) |p| cc.SDL_ReleaseGPUGraphicsPipeline(d, p);
        if (self.sprite_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.glyph_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.glyph_bold_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.glyph_italic_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.sdf_pipeline) |p| cc.SDL_ReleaseGPUGraphicsPipeline(d, p);
        if (self.pattern_pipeline) |p| cc.SDL_ReleaseGPUGraphicsPipeline(d, p);
        if (self.sampler) |sm| cc.SDL_ReleaseGPUSampler(d, sm);
        if (self.window) |w| {
            cc.SDL_ReleaseWindowFromGPUDevice(d, w);
            cc.SDL_DestroyWindow(w);
        }
        cc.SDL_DestroyGPUDevice(d);
    }
};
