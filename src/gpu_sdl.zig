//! SDL_GPU transport: device, four pipelines, persistent buffers, and a
//! per-frame render (present into a window/native surface OR headless offscreen
//! readback). The non-Apple renderer backend (Android/Windows/Linux via Vulkan
//! /D3D12, and macOS via Metal for testing) — selected by src/gpu.zig. All
//! vector work happens in tile57; the frame phase only pushes a uniform and
//! issues draws in paint order.
//!
//! Adapted from the `sdl-gpu` tag's renderer, reconciled to the CURRENT
//! tile57_gpu_vertex(32B)/quad(44B): per-vertex colour + paint-order depth, the
//! shaders in shaders/vk/*.spv (embedded). Triangles are de-indexed at upload
//! (indexed draws mis-resolve on the macOS SDL_GPU->MoltenVK->Metal stack), and
//! ranges are drawn in paint order with alpha blending (single phase).
const std = @import("std");
const cc = @import("c.zig").c; // tile57 + stb (shared; matches root's scene types)
const sdl = @import("c_sdl.zig").c; // SDL3 (window + SDL_GPU)
const png = @import("png.zig");

// Precompiled SPIR-V (see build.zig: -Dbackend=sdl embeds these).
const chart_vert_spv: []const u8 = @embedFile("chart_vert_spv");
const chart_frag_spv: []const u8 = @embedFile("chart_frag_spv");
const sprite_vert_spv: []const u8 = @embedFile("sprite_vert_spv");
const sprite_frag_spv: []const u8 = @embedFile("sprite_frag_spv");
const sdf_frag_spv: []const u8 = @embedFile("sdf_frag_spv");
const pattern_vert_spv: []const u8 = @embedFile("pattern_vert_spv");
const pattern_frag_spv: []const u8 = @embedFile("pattern_frag_spv");

/// Vertex/fragment uniform block (128 bytes). Byte-identical to `struct U` in
/// shaders/vk/*.
pub const Uniforms = extern struct {
    mvp: [16]f32,
    px_to_clip: [2]f32,
    size_scale: f32,
    current_scale: f32,
    cat_mask: u32,
    wrap_x: f32 = 0.5,
    rot_sin: f32,
    rot_cos: f32,
    color: [4]f32 = .{ 0, 0, 0, 1 }, // SDF halo bg (palette NODATA); chart uses per-vertex colour
    anchor_px: [2]f32 = .{ 0, 0 },
    cell_px: [2]f32 = .{ 1, 1 },
};

/// RGBA colour 0..1.
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// Monotonic milliseconds / microseconds (SDL's own timer).
pub fn ticksMs() i64 {
    return @intCast(sdl.SDL_GetTicks());
}
pub fn ticksUs() i64 {
    return @intCast(@divTrunc(sdl.SDL_GetTicksNS(), 1000));
}

/// How to interpret Options.native_handle. Superset across backends (the Metal
/// backend's is a subset) so root/capi share one ABI; the SDL backend wraps the
/// non-Apple kinds and treats metal_layer/none as "no host window".
pub const NativeKind = enum(c_int) {
    none = 0,
    metal_layer = 1, // Apple CAMetalLayer* — capi/root ABI parity only
    cocoa_window = 2,
    cocoa_view = 3,
    win32_hwnd = 4,
    x11_window = 5,
    uikit_windowscene = 6,
    android_window = 7, // ANativeWindow* (SDL usually owns the window on Android)
};

pub const Options = struct {
    width: u32,
    height: u32,
    want_window: bool,
    want_msaa: bool = true,
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,
};

fn check(ok: bool, comptime what: []const u8) !void {
    if (!ok) {
        std.debug.print("SDL error at {s}: {s}\n", .{ what, sdl.SDL_GetError() });
        return error.SdlFailure;
    }
}
fn checkPtr(p: anytype, comptime what: []const u8) !@typeInfo(@TypeOf(p)).optional.child {
    if (p == null) {
        std.debug.print("SDL null at {s}: {s}\n", .{ what, sdl.SDL_GetError() });
        return error.SdlFailure;
    }
    return p.?;
}

pub const Gpu = struct {
    device: *sdl.SDL_GPUDevice,
    window: ?*sdl.SDL_Window,
    pipeline: *sdl.SDL_GPUGraphicsPipeline, // chart (flat-colour triangles)
    sprite_pipeline: ?*sdl.SDL_GPUGraphicsPipeline = null,
    sdf_pipeline: ?*sdl.SDL_GPUGraphicsPipeline = null,
    pattern_pipeline: ?*sdl.SDL_GPUGraphicsPipeline = null,
    sampler: ?*sdl.SDL_GPUSampler = null,
    color_format: sdl.SDL_GPUTextureFormat,
    sample_count: sdl.SDL_GPUSampleCount,
    msaa_used: bool,
    width: u32,
    height: u32,
    external_window: bool = false,
    host_pt_w: f32 = 0,
    host_pt_h: f32 = 0,
    size_changed_ms: i64 = -100000,
    pixel_density: f32 = 1.0,
    pattern_scale: f32 = 1,

    msaa_tex: ?*sdl.SDL_GPUTexture = null,
    resolve_tex: ?*sdl.SDL_GPUTexture = null,
    download_tb: ?*sdl.SDL_GPUTransferBuffer = null,

    clear: Color = .{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 },
    scene: ?Scene = null,

    sprite_tex: ?*sdl.SDL_GPUTexture = null,
    glyph_tex: ?*sdl.SDL_GPUTexture = null,
    glyph_bold_tex: ?*sdl.SDL_GPUTexture = null,
    glyph_italic_tex: ?*sdl.SDL_GPUTexture = null,

    pub fn init(opts: Options) !Gpu {
        sdl.SDL_SetMainReady();
        try check(sdl.SDL_Init(sdl.SDL_INIT_VIDEO), "SDL_Init");
        const debug_gpu = std.c.getenv("LOOKOUT_GPU_DEBUG") != null;
        const props = sdl.SDL_CreateProperties();
        defer sdl.SDL_DestroyProperties(props);
        _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true);
        _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, debug_gpu);
        _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_CLIP_DISTANCE_BOOLEAN, false);
        _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_DEPTH_CLAMPING_BOOLEAN, false);
        _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_INDIRECT_DRAW_FIRST_INSTANCE_BOOLEAN, false);
        _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_ANISOTROPY_BOOLEAN, false);
        const device = try checkPtr(sdl.SDL_CreateGPUDeviceWithProperties(props), "CreateGPUDevice");

        var window: ?*sdl.SDL_Window = null;
        var color_format: sdl.SDL_GPUTextureFormat = sdl.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        var width = opts.width;
        var height = opts.height;
        var pixel_density: f32 = 1.0;
        if (opts.native_kind != .none and opts.native_kind != .metal_layer) {
            window = createNativeWindow(opts.native_handle, opts.native_kind, opts.width, opts.height);
        } else if (opts.want_window) {
            const flags: sdl.SDL_WindowFlags = sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY | sdl.SDL_WINDOW_RESIZABLE;
            window = sdl.SDL_CreateWindow("lookout marine", @intCast(opts.width), @intCast(opts.height), flags);
        }
        if (window != null) {
            try check(sdl.SDL_ClaimWindowForGPUDevice(device, window), "ClaimWindow");
            color_format = sdl.SDL_GetGPUSwapchainTextureFormat(device, window);
            var pw: c_int = 0;
            var ph: c_int = 0;
            if (sdl.SDL_GetWindowSizeInPixels(window, &pw, &ph) and pw > 0 and ph > 0) {
                width = @intCast(pw);
                height = @intCast(ph);
                const d = sdl.SDL_GetWindowPixelDensity(window);
                if (d > 0) pixel_density = d;
            }
        }

        var sample_count: sdl.SDL_GPUSampleCount = sdl.SDL_GPU_SAMPLECOUNT_1;
        var msaa_used = false;
        if (opts.want_msaa and std.c.getenv("LOOKOUT_NO_MSAA") == null and
            sdl.SDL_GPUTextureSupportsSampleCount(device, color_format, sdl.SDL_GPU_SAMPLECOUNT_4))
        {
            sample_count = sdl.SDL_GPU_SAMPLECOUNT_4;
            msaa_used = true;
        }

        var g = Gpu{
            .device = device,
            .window = window,
            .pipeline = try buildTriPipeline(device, color_format, sample_count, chart_vert_spv, chart_frag_spv),
            .sprite_pipeline = try buildQuadPipeline(device, color_format, sample_count, sprite_vert_spv, sprite_frag_spv, 0),
            .sdf_pipeline = try buildQuadPipeline(device, color_format, sample_count, sprite_vert_spv, sdf_frag_spv, 1),
            .pattern_pipeline = try buildTriPipeline(device, color_format, sample_count, pattern_vert_spv, pattern_frag_spv),
            .sampler = try makeSampler(device),
            .color_format = color_format,
            .sample_count = sample_count,
            .msaa_used = msaa_used,
            .width = width,
            .height = height,
            .external_window = opts.native_kind != .none and opts.native_kind != .metal_layer,
            .pixel_density = pixel_density,
        };
        if (window == null) try g.ensureOffscreenTargets() else try g.ensureMsaa();
        return g;
    }

    fn createNativeWindow(handle: ?*anyopaque, kind: NativeKind, w: u32, h: u32) ?*sdl.SDL_Window {
        const props = sdl.SDL_CreateProperties();
        if (props == 0) return null;
        defer sdl.SDL_DestroyProperties(props);
        switch (kind) {
            .cocoa_window => _ = sdl.SDL_SetPointerProperty(props, sdl.SDL_PROP_WINDOW_CREATE_COCOA_WINDOW_POINTER, handle),
            .cocoa_view => _ = sdl.SDL_SetPointerProperty(props, sdl.SDL_PROP_WINDOW_CREATE_COCOA_VIEW_POINTER, handle),
            .win32_hwnd => _ = sdl.SDL_SetPointerProperty(props, sdl.SDL_PROP_WINDOW_CREATE_WIN32_HWND_POINTER, handle),
            .x11_window => _ = sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_X11_WINDOW_NUMBER, @intCast(@intFromPtr(handle))),
            .uikit_windowscene => if (handle != null) {
                _ = sdl.SDL_SetPointerProperty(props, sdl.SDL_PROP_WINDOW_CREATE_WINDOWSCENE_POINTER, handle);
            },
            else => return null, // android/metal_layer/none: SDL owns (or no) window
        }
        _ = sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, @intCast(w));
        _ = sdl.SDL_SetNumberProperty(props, sdl.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, @intCast(h));
        _ = sdl.SDL_SetBooleanProperty(props, sdl.SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN, true);
        return sdl.SDL_CreateWindowWithProperties(props);
    }

    fn makeColorTex(self: *Gpu, sc: sdl.SDL_GPUSampleCount, sampler_readable: bool) !*sdl.SDL_GPUTexture {
        var info = std.mem.zeroes(sdl.SDL_GPUTextureCreateInfo);
        info.type = sdl.SDL_GPU_TEXTURETYPE_2D;
        info.format = self.color_format;
        info.usage = sdl.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | (if (sampler_readable) sdl.SDL_GPU_TEXTUREUSAGE_SAMPLER else 0);
        info.width = self.width;
        info.height = self.height;
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        info.sample_count = sc;
        return try checkPtr(sdl.SDL_CreateGPUTexture(self.device, &info), "CreateColorTex");
    }
    fn ensureMsaa(self: *Gpu) !void {
        if (self.msaa_used and self.msaa_tex == null) self.msaa_tex = try self.makeColorTex(self.sample_count, false);
    }
    fn ensureOffscreenTargets(self: *Gpu) !void {
        try self.ensureMsaa();
        if (self.resolve_tex == null) self.resolve_tex = try self.makeColorTex(sdl.SDL_GPU_SAMPLECOUNT_1, false);
        if (self.download_tb == null) {
            var tb = std.mem.zeroes(sdl.SDL_GPUTransferBufferCreateInfo);
            tb.usage = sdl.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
            tb.size = self.width * self.height * 4;
            self.download_tb = try checkPtr(sdl.SDL_CreateGPUTransferBuffer(self.device, &tb), "CreateDownloadTB");
        }
    }

    /// Resize the render surface. width/height are logical points; the pixel size
    /// (HiDPI) is derived. Recreates the offscreen/MSAA targets.
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) !void {
        if (self.external_window) {
            self.host_pt_w = @floatFromInt(width_pts);
            self.host_pt_h = @floatFromInt(height_pts);
            return;
        }
        var pw = width_pts;
        var ph = height_pts;
        if (self.window) |w| {
            _ = sdl.SDL_SetWindowSize(w, @intCast(width_pts), @intCast(height_pts));
            var qw: c_int = 0;
            var qh: c_int = 0;
            if (sdl.SDL_GetWindowSizeInPixels(w, &qw, &qh) and qw > 0 and qh > 0) {
                pw = @intCast(qw);
                ph = @intCast(qh);
            }
        }
        if (pw == self.width and ph == self.height) return;
        self.width = pw;
        self.height = ph;
        self.releaseTargets();
        if (self.window == null) try self.ensureOffscreenTargets() else try self.ensureMsaa();
    }

    fn releaseTargets(self: *Gpu) void {
        if (self.msaa_tex) |t| {
            sdl.SDL_ReleaseGPUTexture(self.device, t);
            self.msaa_tex = null;
        }
        if (self.resolve_tex) |t| {
            sdl.SDL_ReleaseGPUTexture(self.device, t);
            self.resolve_tex = null;
        }
        if (self.download_tb) |t| {
            sdl.SDL_ReleaseGPUTransferBuffer(self.device, t);
            self.download_tb = null;
        }
    }

    fn makeShader(device: *sdl.SDL_GPUDevice, spv: []const u8, stage: sdl.SDL_GPUShaderStage, samplers: u32, uniforms: u32, comptime what: []const u8) !*sdl.SDL_GPUShader {
        var info = std.mem.zeroes(sdl.SDL_GPUShaderCreateInfo);
        info.code = spv.ptr;
        info.code_size = spv.len;
        info.entrypoint = "main";
        info.format = sdl.SDL_GPU_SHADERFORMAT_SPIRV;
        info.stage = stage;
        info.num_samplers = samplers;
        info.num_uniform_buffers = uniforms;
        return try checkPtr(sdl.SDL_CreateGPUShader(device, &info), what);
    }

    fn blendState() sdl.SDL_GPUColorTargetBlendState {
        var b = std.mem.zeroes(sdl.SDL_GPUColorTargetBlendState);
        b.enable_blend = true;
        b.src_color_blendfactor = sdl.SDL_GPU_BLENDFACTOR_SRC_ALPHA;
        b.dst_color_blendfactor = sdl.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        b.color_blend_op = sdl.SDL_GPU_BLENDOP_ADD;
        b.src_alpha_blendfactor = sdl.SDL_GPU_BLENDFACTOR_ONE;
        b.dst_alpha_blendfactor = sdl.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
        b.alpha_blend_op = sdl.SDL_GPU_BLENDOP_ADD;
        return b;
    }

    // chart + pattern: tile57_gpu_vertex (32B) — world f2@0, local f2@8,
    // scamin f@16, packed u32@20, colour ubyte4@24, depth f@28.
    fn buildTriPipeline(device: *sdl.SDL_GPUDevice, color_format: sdl.SDL_GPUTextureFormat, sc: sdl.SDL_GPUSampleCount, vspv: []const u8, fspv: []const u8) !*sdl.SDL_GPUGraphicsPipeline {
        const is_pattern = std.mem.eql(u8, vspv, pattern_vert_spv);
        const vshader = try makeShader(device, vspv, sdl.SDL_GPU_SHADERSTAGE_VERTEX, 0, 1, "tri vertex shader");
        defer sdl.SDL_ReleaseGPUShader(device, vshader);
        const fshader = try makeShader(device, fspv, sdl.SDL_GPU_SHADERSTAGE_FRAGMENT, if (is_pattern) 1 else 0, 0, "tri fragment shader");
        defer sdl.SDL_ReleaseGPUShader(device, fshader);

        const vbufs = [_]sdl.SDL_GPUVertexBufferDescription{
            .{ .slot = 0, .pitch = @sizeOf(cc.tile57_gpu_vertex), .input_rate = sdl.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
        };
        const vattrs = [_]sdl.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
            .{ .location = 1, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
            .{ .location = 2, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 16 },
            .{ .location = 3, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_UINT, .offset = 20 },
            .{ .location = 4, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 24 },
            .{ .location = 5, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 28 },
        };
        const color_targets = [_]sdl.SDL_GPUColorTargetDescription{.{ .format = color_format, .blend_state = blendState() }};
        var p = std.mem.zeroes(sdl.SDL_GPUGraphicsPipelineCreateInfo);
        p.vertex_shader = vshader;
        p.fragment_shader = fshader;
        p.vertex_input_state = .{ .vertex_buffer_descriptions = &vbufs, .num_vertex_buffers = 1, .vertex_attributes = &vattrs, .num_vertex_attributes = vattrs.len };
        p.primitive_type = sdl.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        p.rasterizer_state.fill_mode = sdl.SDL_GPU_FILLMODE_FILL;
        p.rasterizer_state.cull_mode = sdl.SDL_GPU_CULLMODE_NONE;
        p.rasterizer_state.enable_depth_clip = true; // clip z=2 cull verts
        p.multisample_state.sample_count = sc;
        p.target_info = .{ .color_target_descriptions = &color_targets, .num_color_targets = 1, .depth_stencil_format = 0, .has_depth_stencil_target = false };
        return try checkPtr(sdl.SDL_CreateGPUGraphicsPipeline(device, &p), "tri pipeline");
    }

    // sprite + SDF: tile57_gpu_quad (44B) — world f2@0, local f2@8, uv f2@16,
    // colour ubyte4@24, weight f@28, scamin f@32, packed u32@36, depth f@40.
    // frag_uniforms=1 for the SDF pipeline (halo bg colour), 0 for sprites.
    fn buildQuadPipeline(device: *sdl.SDL_GPUDevice, color_format: sdl.SDL_GPUTextureFormat, sc: sdl.SDL_GPUSampleCount, vspv: []const u8, fspv: []const u8, frag_uniforms: u32) !*sdl.SDL_GPUGraphicsPipeline {
        const vshader = try makeShader(device, vspv, sdl.SDL_GPU_SHADERSTAGE_VERTEX, 0, 1, "quad vertex shader");
        defer sdl.SDL_ReleaseGPUShader(device, vshader);
        const fshader = try makeShader(device, fspv, sdl.SDL_GPU_SHADERSTAGE_FRAGMENT, 1, frag_uniforms, "quad fragment shader");
        defer sdl.SDL_ReleaseGPUShader(device, fshader);

        const vbufs = [_]sdl.SDL_GPUVertexBufferDescription{
            .{ .slot = 0, .pitch = @sizeOf(cc.tile57_gpu_quad), .input_rate = sdl.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
        };
        const vattrs = [_]sdl.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
            .{ .location = 1, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
            .{ .location = 2, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 16 },
            .{ .location = 3, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 24 },
            .{ .location = 4, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 28 },
            .{ .location = 5, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 32 },
            .{ .location = 6, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_UINT, .offset = 36 },
            .{ .location = 7, .buffer_slot = 0, .format = sdl.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 40 },
        };
        const color_targets = [_]sdl.SDL_GPUColorTargetDescription{.{ .format = color_format, .blend_state = blendState() }};
        var p = std.mem.zeroes(sdl.SDL_GPUGraphicsPipelineCreateInfo);
        p.vertex_shader = vshader;
        p.fragment_shader = fshader;
        p.vertex_input_state = .{ .vertex_buffer_descriptions = &vbufs, .num_vertex_buffers = 1, .vertex_attributes = &vattrs, .num_vertex_attributes = vattrs.len };
        p.primitive_type = sdl.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        p.rasterizer_state.fill_mode = sdl.SDL_GPU_FILLMODE_FILL;
        p.rasterizer_state.cull_mode = sdl.SDL_GPU_CULLMODE_NONE;
        p.rasterizer_state.enable_depth_clip = true;
        p.multisample_state.sample_count = sc;
        p.target_info = .{ .color_target_descriptions = &color_targets, .num_color_targets = 1, .depth_stencil_format = 0, .has_depth_stencil_target = false };
        return try checkPtr(sdl.SDL_CreateGPUGraphicsPipeline(device, &p), "quad pipeline");
    }

    fn makeSampler(device: *sdl.SDL_GPUDevice) !*sdl.SDL_GPUSampler {
        var si = std.mem.zeroes(sdl.SDL_GPUSamplerCreateInfo);
        si.min_filter = sdl.SDL_GPU_FILTER_LINEAR;
        si.mag_filter = sdl.SDL_GPU_FILTER_LINEAR;
        si.mipmap_mode = sdl.SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;
        si.address_mode_u = sdl.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        si.address_mode_v = sdl.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        si.address_mode_w = sdl.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
        return try checkPtr(sdl.SDL_CreateGPUSampler(device, &si), "CreateSampler");
    }

    pub fn uploadSpriteAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.sprite_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.glyph_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlasBold(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.glyph_bold_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlasItalic(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.glyph_italic_tex = try self.makeAtlasTexture(rgba, w, h);
    }
    fn makeAtlasTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !*sdl.SDL_GPUTexture {
        var info = std.mem.zeroes(sdl.SDL_GPUTextureCreateInfo);
        info.type = sdl.SDL_GPU_TEXTURETYPE_2D;
        info.format = sdl.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        info.usage = sdl.SDL_GPU_TEXTUREUSAGE_SAMPLER;
        info.width = w;
        info.height = h;
        info.layer_count_or_depth = 1;
        info.num_levels = 1;
        const tex = try checkPtr(sdl.SDL_CreateGPUTexture(self.device, &info), "CreateAtlasTexture");
        var ti = std.mem.zeroes(sdl.SDL_GPUTransferBufferCreateInfo);
        ti.usage = sdl.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        ti.size = @intCast(rgba.len);
        const tb = try checkPtr(sdl.SDL_CreateGPUTransferBuffer(self.device, &ti), "AtlasTB");
        defer sdl.SDL_ReleaseGPUTransferBuffer(self.device, tb);
        const map = sdl.SDL_MapGPUTransferBuffer(self.device, tb, false) orelse return error.SdlFailure;
        @memcpy(@as([*]u8, @ptrCast(map))[0..rgba.len], rgba);
        sdl.SDL_UnmapGPUTransferBuffer(self.device, tb);
        const cmd = sdl.SDL_AcquireGPUCommandBuffer(self.device);
        const cp = sdl.SDL_BeginGPUCopyPass(cmd);
        var src = std.mem.zeroes(sdl.SDL_GPUTextureTransferInfo);
        src.transfer_buffer = tb;
        src.pixels_per_row = w;
        src.rows_per_layer = h;
        var dst = std.mem.zeroes(sdl.SDL_GPUTextureRegion);
        dst.texture = tex;
        dst.w = w;
        dst.h = h;
        dst.d = 1;
        sdl.SDL_UploadToGPUTexture(cp, &src, &dst, false);
        sdl.SDL_EndGPUCopyPass(cp);
        try check(sdl.SDL_SubmitGPUCommandBuffer(cmd), "submit atlas upload");
        return tex;
    }

    fn uploadBuffer(self: *Gpu, usage: sdl.SDL_GPUBufferUsageFlags, bytes: []const u8) !*sdl.SDL_GPUBuffer {
        var bi = std.mem.zeroes(sdl.SDL_GPUBufferCreateInfo);
        bi.usage = usage;
        bi.size = @intCast(bytes.len);
        const buf = try checkPtr(sdl.SDL_CreateGPUBuffer(self.device, &bi), "CreateGPUBuffer");
        errdefer sdl.SDL_ReleaseGPUBuffer(self.device, buf);
        var ti = std.mem.zeroes(sdl.SDL_GPUTransferBufferCreateInfo);
        ti.usage = sdl.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        ti.size = @intCast(bytes.len);
        const tb = try checkPtr(sdl.SDL_CreateGPUTransferBuffer(self.device, &ti), "CreateUploadTB");
        defer sdl.SDL_ReleaseGPUTransferBuffer(self.device, tb);
        const map = sdl.SDL_MapGPUTransferBuffer(self.device, tb, true);
        @memcpy(@as([*]u8, @ptrCast(map))[0..bytes.len], bytes);
        sdl.SDL_UnmapGPUTransferBuffer(self.device, tb);
        const cmd = sdl.SDL_AcquireGPUCommandBuffer(self.device);
        const cp = sdl.SDL_BeginGPUCopyPass(cmd);
        const src = sdl.SDL_GPUTransferBufferLocation{ .transfer_buffer = tb, .offset = 0 };
        const dstr = sdl.SDL_GPUBufferRegion{ .buffer = buf, .offset = 0, .size = @intCast(bytes.len) };
        sdl.SDL_UploadToGPUBuffer(cp, &src, &dstr, false);
        sdl.SDL_EndGPUCopyPass(cp);
        try check(sdl.SDL_SubmitGPUCommandBuffer(cmd), "submit buffer upload");
        return buf;
    }

    const PatternTex = struct { tex: ?*sdl.SDL_GPUTexture = null, w: f32 = 1, h: f32 = 1 };

    /// GPU-resident whole-view scene. Triangles are DE-INDEXED (flat, non-indexed)
    /// at upload — indexed draws mis-resolve on the macOS MoltenVK stack.
    pub const Scene = struct {
        vbuf: ?*sdl.SDL_GPUBuffer = null, // de-indexed triangle vertices (tile57_gpu_vertex)
        qbuf: ?*sdl.SDL_GPUBuffer = null, // sprite/SDF quads (tile57_gpu_quad)
        index_count: u32 = 0, // vertices in vbuf (== the engine's index count)
        ranges: []cc.tile57_gpu_range = &.{},
        patterns: []PatternTex = &.{},
        alloc: std.mem.Allocator,
    };

    /// Build a GPU-resident Scene from the engine's C scene WITHOUT installing it.
    pub fn makeScene(self: *Gpu, alloc: std.mem.Allocator, s: *const cc.tile57_gpu_scene) !Scene {
        var out = Scene{ .alloc = alloc };
        errdefer self.freeSceneValue(&out);
        if (s.vertex_count > 0 and s.index_count > 0) {
            const verts = s.vertices[0..s.vertex_count];
            const idx = s.indices[0..s.index_count];
            const flat = try alloc.alloc(cc.tile57_gpu_vertex, s.index_count);
            defer alloc.free(flat);
            for (idx, 0..) |ii, k| flat[k] = verts[ii];
            out.vbuf = try self.uploadBuffer(sdl.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(flat));
            out.index_count = @intCast(s.index_count);
        }
        if (s.quad_count > 0) {
            out.qbuf = try self.uploadBuffer(sdl.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(s.quads[0..s.quad_count]));
        }
        if (s.range_count > 0) out.ranges = try alloc.dupe(cc.tile57_gpu_range, s.ranges[0..s.range_count]);
        sdl.SDL_Log("makeScene: verts=%d idx=%d quads=%d ranges=%d", @as(c_int, @intCast(s.vertex_count)), @as(c_int, @intCast(s.index_count)), @as(c_int, @intCast(s.quad_count)), @as(c_int, @intCast(s.range_count)));
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
        return out;
    }

    /// Swap a staged scene in as current (frees the previous one).
    pub fn adoptScene(self: *Gpu, sc: Scene) void {
        self.freeScene();
        self.scene = sc;
    }
    /// Build + adopt in one step (single-threaded callers).
    pub fn uploadGpuScene(self: *Gpu, alloc: std.mem.Allocator, s: *const cc.tile57_gpu_scene) !void {
        self.adoptScene(try self.makeScene(alloc, s));
    }
    pub fn freeStagedScene(self: *Gpu, sc: *Scene) void {
        self.freeSceneValue(sc);
    }
    fn freeSceneValue(self: *Gpu, s: *Scene) void {
        const d = self.device;
        if (s.vbuf) |b| sdl.SDL_ReleaseGPUBuffer(d, b);
        if (s.qbuf) |b| sdl.SDL_ReleaseGPUBuffer(d, b);
        for (s.patterns) |p| if (p.tex) |t| sdl.SDL_ReleaseGPUTexture(d, t);
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

    fn normColor(c: [4]u8) [4]f32 {
        return .{
            @as(f32, @floatFromInt(c[0])) / 255.0, @as(f32, @floatFromInt(c[1])) / 255.0,
            @as(f32, @floatFromInt(c[2])) / 255.0, @as(f32, @floatFromInt(c[3])) / 255.0,
        };
    }

    // Walk the ranges in paint order, one draw per range (contiguous same-state
    // ranges could merge; kept simple here). Triangles -> chart/pattern pipeline;
    // quads -> sprite/SDF. All blended; paint order preserved by draw order.
    fn recordDraws(self: *Gpu, cmd: *sdl.SDL_GPUCommandBuffer, target: *sdl.SDL_GPUTexture, resolve: ?*sdl.SDL_GPUTexture, u: Uniforms, text_on: bool, sound_on: bool) void {
        var cti = std.mem.zeroes(sdl.SDL_GPUColorTargetInfo);
        cti.texture = target;
        cti.clear_color = .{ .r = self.clear.r, .g = self.clear.g, .b = self.clear.b, .a = self.clear.a };
        cti.load_op = sdl.SDL_GPU_LOADOP_CLEAR;
        if (resolve) |rt| {
            cti.store_op = sdl.SDL_GPU_STOREOP_RESOLVE;
            cti.resolve_texture = rt;
        } else cti.store_op = sdl.SDL_GPU_STOREOP_STORE;
        const pass = sdl.SDL_BeginGPURenderPass(cmd, &cti, 1, null);
        defer sdl.SDL_EndGPURenderPass(pass);
        const vp = sdl.SDL_GPUViewport{ .x = 0, .y = 0, .w = @floatFromInt(self.width), .h = @floatFromInt(self.height), .min_depth = 0, .max_depth = 1 };
        sdl.SDL_SetGPUViewport(pass, &vp);
        const scis = sdl.SDL_Rect{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
        sdl.SDL_SetGPUScissor(pass, &scis);

        const s = if (self.scene) |*sc| sc else {
            sdl.SDL_Log("recordDraws: no scene (blank frame)");
            return;
        };
        const vbind = [_]sdl.SDL_GPUBufferBinding{.{ .buffer = s.vbuf, .offset = 0 }};
        const qbind = [_]sdl.SDL_GPUBufferBinding{.{ .buffer = s.qbuf, .offset = 0 }};

        for (s.ranges) |r| {
            switch (r.kind) {
                cc.TILE57_GPU_TEXT => if (!text_on) continue,
                cc.TILE57_GPU_SOUNDING => if (!sound_on) continue,
                else => {},
            }
            var uu = u;
            if (r.kind == cc.TILE57_GPU_SOUNDING) uu.cat_mask |= @as(u32, 1) << 2;
            if (r.prim == cc.TILE57_GPU_TRIANGLES) {
                if (s.vbuf == null) continue;
                sdl.SDL_BindGPUVertexBuffers(pass, 0, &vbind, 1);
                if (r.pattern != cc.TILE57_GPU_NO_PATTERN and self.pattern_pipeline != null and r.pattern < s.patterns.len and s.patterns[r.pattern].tex != null) {
                    const pt = s.patterns[r.pattern];
                    const cs = self.pixel_density * self.pattern_scale;
                    uu.cell_px = .{ pt.w * cs, pt.h * cs };
                    sdl.SDL_BindGPUGraphicsPipeline(pass, self.pattern_pipeline);
                    const samp = [_]sdl.SDL_GPUTextureSamplerBinding{.{ .texture = pt.tex, .sampler = self.sampler }};
                    sdl.SDL_BindGPUFragmentSamplers(pass, 0, &samp, 1);
                } else if (r.pattern != cc.TILE57_GPU_NO_PATTERN) {
                    continue; // pattern with no cell texture: the fill under it already drew
                } else {
                    sdl.SDL_BindGPUGraphicsPipeline(pass, self.pipeline); // colour rides the vertices
                }
                sdl.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
                sdl.SDL_DrawGPUPrimitives(pass, r.count, 1, r.first, 0);
            } else { // QUADS
                if (s.qbuf == null) continue;
                const is_glyph = r.atlas == cc.TILE57_GPU_ATLAS_GLYPH or r.atlas == cc.TILE57_GPU_ATLAS_GLYPH_BOLD or r.atlas == cc.TILE57_GPU_ATLAS_GLYPH_ITALIC;
                const tex = switch (r.atlas) {
                    cc.TILE57_GPU_ATLAS_GLYPH => self.glyph_tex,
                    cc.TILE57_GPU_ATLAS_GLYPH_BOLD => self.glyph_bold_tex orelse self.glyph_tex,
                    cc.TILE57_GPU_ATLAS_GLYPH_ITALIC => self.glyph_italic_tex orelse self.glyph_tex,
                    else => self.sprite_tex,
                };
                const pipe = if (is_glyph) self.sdf_pipeline else self.sprite_pipeline;
                if (tex == null or pipe == null) continue;
                sdl.SDL_BindGPUGraphicsPipeline(pass, pipe);
                sdl.SDL_BindGPUVertexBuffers(pass, 0, &qbind, 1);
                const samp = [_]sdl.SDL_GPUTextureSamplerBinding{.{ .texture = tex, .sampler = self.sampler }};
                sdl.SDL_BindGPUFragmentSamplers(pass, 0, &samp, 1);
                sdl.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
                if (is_glyph) {
                    // SDF halo renders in the palette background colour (sdf.frag,
                    // fragment uniform set 3): a hardcoded white halo glared at night.
                    uu.color = .{ self.clear.r, self.clear.g, self.clear.b, 1 };
                    sdl.SDL_PushGPUFragmentUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
                }
                sdl.SDL_DrawGPUPrimitives(pass, r.count, 1, r.first, 0);
            }
        }
    }

    /// Render one frame to the window and present. Returns false if no window.
    pub fn renderWindow(self: *Gpu, u: Uniforms, text_on: bool, sound_on: bool) !bool {
        const window = self.window orelse return false;
        const cmd = try checkPtr(sdl.SDL_AcquireGPUCommandBuffer(self.device), "AcquireCmd");
        var swap: ?*sdl.SDL_GPUTexture = null;
        var w: u32 = 0;
        var h: u32 = 0;
        try check(sdl.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swap, &w, &h), "AcquireSwapchain");
        if (swap == null) {
            _ = sdl.SDL_SubmitGPUCommandBuffer(cmd);
            return true; // minimized etc.
        }
        if (w != self.width or h != self.height) {
            self.size_changed_ms = ticksMs();
            self.width = w;
            self.height = h;
            self.releaseTargets();
            self.ensureMsaa() catch {};
        }
        if (self.msaa_used) {
            self.recordDraws(cmd, self.msaa_tex.?, swap, u, text_on, sound_on);
        } else {
            self.recordDraws(cmd, swap.?, null, u, text_on, sound_on);
        }
        try check(sdl.SDL_SubmitGPUCommandBuffer(cmd), "submit frame");
        return true;
    }

    /// Render one frame offscreen and read the pixels back (RGBA8, top-down).
    pub fn renderOffscreen(self: *Gpu, alloc: std.mem.Allocator, u: Uniforms, text_on: bool, sound_on: bool) ![]u8 {
        try self.ensureOffscreenTargets();
        const resolve = self.resolve_tex orelse return error.NoOffscreenTarget;
        const cmd = try checkPtr(sdl.SDL_AcquireGPUCommandBuffer(self.device), "AcquireCmd");
        if (self.msaa_used) {
            self.recordDraws(cmd, self.msaa_tex.?, resolve, u, text_on, sound_on);
        } else {
            self.recordDraws(cmd, resolve, null, u, text_on, sound_on);
        }
        const cp = sdl.SDL_BeginGPUCopyPass(cmd);
        var region = std.mem.zeroes(sdl.SDL_GPUTextureRegion);
        region.texture = resolve;
        region.w = self.width;
        region.h = self.height;
        region.d = 1;
        var dst = std.mem.zeroes(sdl.SDL_GPUTextureTransferInfo);
        dst.transfer_buffer = self.download_tb.?;
        dst.pixels_per_row = self.width;
        dst.rows_per_layer = self.height;
        sdl.SDL_DownloadFromGPUTexture(cp, &region, &dst);
        sdl.SDL_EndGPUCopyPass(cp);
        const fence = sdl.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd);
        if (fence != null) {
            _ = sdl.SDL_WaitForGPUFences(self.device, true, @ptrCast(&fence), 1);
            sdl.SDL_ReleaseGPUFence(self.device, fence);
        }
        const map = sdl.SDL_MapGPUTransferBuffer(self.device, self.download_tb.?, false);
        const src: [*]const u8 = @ptrCast(map);
        const n = self.width * self.height * 4;
        const pixels = try alloc.dupe(u8, src[0..n]);
        sdl.SDL_UnmapGPUTransferBuffer(self.device, self.download_tb.?);
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
        self.releaseTargets();
        sdl.SDL_ReleaseGPUGraphicsPipeline(d, self.pipeline);
        if (self.sprite_pipeline) |p| sdl.SDL_ReleaseGPUGraphicsPipeline(d, p);
        if (self.sdf_pipeline) |p| sdl.SDL_ReleaseGPUGraphicsPipeline(d, p);
        if (self.pattern_pipeline) |p| sdl.SDL_ReleaseGPUGraphicsPipeline(d, p);
        if (self.sprite_tex) |t| sdl.SDL_ReleaseGPUTexture(d, t);
        if (self.glyph_tex) |t| sdl.SDL_ReleaseGPUTexture(d, t);
        if (self.glyph_bold_tex) |t| sdl.SDL_ReleaseGPUTexture(d, t);
        if (self.glyph_italic_tex) |t| sdl.SDL_ReleaseGPUTexture(d, t);
        if (self.sampler) |sm| sdl.SDL_ReleaseGPUSampler(d, sm);
        if (self.window) |w| {
            sdl.SDL_ReleaseWindowFromGPUDevice(d, w);
            sdl.SDL_DestroyWindow(w);
        }
        sdl.SDL_DestroyGPUDevice(d);
    }
};
