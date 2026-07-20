//! SDL_GPU transport: device, one flat-color pipeline, persistent buffers, and a
//! per-frame render (window present OR headless offscreen readback). SDL is the
//! window + GPU transport only — all vector work happened in scene.zig. The
//! frame phase here only updates a uniform and issues draws (spec §6).
const std = @import("std");
const cc = @import("c.zig").c;
const scene = @import("scene.zig");
const png = @import("png.zig");

/// Vertex-shader uniform block (std140-compatible; 96 bytes). Matches chart.vert.
pub const Uniforms = extern struct {
    mvp: [16]f32,
    px_to_clip: [2]f32,
    size_scale: f32,
    current_scale: f32,
    cat_mask: u32,
    kind_mask: u32,
    rot_sin: f32,
    rot_cos: f32,
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
    /// pixels per logical point (Retina/HiDPI = 2.0). SDL mouse events are in
    /// logical points; multiply by this to reach the pixel-space viewport.
    pixel_density: f32 = 1.0,

    // offscreen targets (headless path)
    msaa_tex: ?*cc.SDL_GPUTexture = null, // multisample color (if MSAA)
    resolve_tex: ?*cc.SDL_GPUTexture = null, // single-sample readback target
    download_tb: ?*cc.SDL_GPUTransferBuffer = null,

    // scene buffers
    vbuf: ?*cc.SDL_GPUBuffer = null,
    ibuf: ?*cc.SDL_GPUBuffer = null,
    color_bufs: [scene.MAX_SCHEMES]?*cc.SDL_GPUBuffer = .{ null, null, null },
    index_count: u32 = 0,
    n_schemes: usize = 0,
    /// background = S-52 NODATA for the active palette (set by Lookout).
    clear: cc.SDL_FColor = .{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 },

    // sprite symbols: textured-quad pipeline + shared atlas texture
    sprite_pipeline: ?*cc.SDL_GPUGraphicsPipeline = null,
    sprite_tex: ?*cc.SDL_GPUTexture = null,
    sampler: ?*cc.SDL_GPUSampler = null,
    qbuf: ?*cc.SDL_GPUBuffer = null,
    quad_count: u32 = 0,
    // SDF text: its own pipeline (sprite.vert + sdf.frag) + glyph atlas texture
    sdf_pipeline: ?*cc.SDL_GPUGraphicsPipeline = null,
    pattern_pipeline: ?*cc.SDL_GPUGraphicsPipeline = null,
    glyph_tex: ?*cc.SDL_GPUTexture = null,
    // Labels are NOT per-tile: one decluttered set for the whole view, in one
    // buffer, drawn last (see scene.labelTable).
    label_buf: ?*cc.SDL_GPUBuffer = null,
    label_count: u32 = 0,

    pub fn init(opts: Options, vert_spv: []const u8, frag_spv: []const u8, sprite_vert_spv: []const u8, sprite_frag_spv: []const u8, sdf_frag_spv: []const u8, pattern_vert_spv: []const u8, pattern_frag_spv: []const u8) !Gpu {
        // lookout always owns SDL + the GPU device; the host never sees them.
        try check(cc.SDL_Init(cc.SDL_INIT_VIDEO), "SDL_Init");
        const device = try checkPtr(cc.SDL_CreateGPUDevice(cc.SDL_GPU_SHADERFORMAT_SPIRV, true, null), "CreateGPUDevice");

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
        if (opts.want_msaa and cc.SDL_GPUTextureSupportsSampleCount(device, color_format, cc.SDL_GPU_SAMPLECOUNT_4)) {
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

        const vbufs = [_]cc.SDL_GPUVertexBufferDescription{
            .{ .slot = 0, .pitch = @sizeOf(scene.Vertex), .input_rate = cc.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
            .{ .slot = 1, .pitch = @sizeOf(scene.Color), .input_rate = cc.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
        };
        const vattrs = [_]cc.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 },
            .{ .location = 1, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 },
            .{ .location = 2, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 16 },
            .{ .location = 3, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_UINT, .offset = 20 },
            .{ .location = 4, .buffer_slot = 1, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 0 },
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
            .num_vertex_buffers = 2,
            .vertex_attributes = &vattrs,
            .num_vertex_attributes = 5,
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

        const vbufs = [_]cc.SDL_GPUVertexBufferDescription{
            .{ .slot = 0, .pitch = @sizeOf(scene.PatternVertex), .input_rate = cc.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
        };
        const vattrs = [_]cc.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 }, // world
            .{ .location = 1, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = 8 }, // cell rect
            .{ .location = 2, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 24 }, // cell px
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
            .num_vertex_attributes = 3,
        };
        p.primitive_type = cc.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        p.rasterizer_state.fill_mode = cc.SDL_GPU_FILLMODE_FILL;
        p.rasterizer_state.cull_mode = cc.SDL_GPU_CULLMODE_NONE;
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

        const vbufs = [_]cc.SDL_GPUVertexBufferDescription{
            .{ .slot = 0, .pitch = @sizeOf(scene.QuadVertex), .input_rate = cc.SDL_GPU_VERTEXINPUTRATE_VERTEX, .instance_step_rate = 0 },
        };
        const vattrs = [_]cc.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 }, // world
            .{ .location = 1, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 8 }, // local
            .{ .location = 2, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 16 }, // uv
            .{ .location = 3, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM, .offset = 24 }, // color
            .{ .location = 4, .buffer_slot = 0, .format = cc.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT, .offset = 28 }, // SDF weight
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
            .num_vertex_attributes = 5,
        };
        p.primitive_type = cc.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
        p.rasterizer_state.fill_mode = cc.SDL_GPU_FILLMODE_FILL;
        p.rasterizer_state.cull_mode = cc.SDL_GPU_CULLMODE_NONE;
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
        const map = cc.SDL_MapGPUTransferBuffer(self.device, tb, false);
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

    pub fn uploadQuads(self: *Gpu, quads: []const scene.QuadVertex) !void {
        if (self.qbuf) |b| {
            cc.SDL_ReleaseGPUBuffer(self.device, b);
            self.qbuf = null;
        }
        self.quad_count = @intCast(quads.len);
        if (quads.len == 0) return;
        self.qbuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(quads));
    }

    // ---- upload the built scene into persistent GPU buffers (once) ----------
    fn uploadBuffer(self: *Gpu, usage: cc.SDL_GPUBufferUsageFlags, bytes: []const u8) !*cc.SDL_GPUBuffer {
        var bi = std.mem.zeroes(cc.SDL_GPUBufferCreateInfo);
        bi.usage = usage;
        bi.size = @intCast(bytes.len);
        const buf = try checkPtr(cc.SDL_CreateGPUBuffer(self.device, &bi), "CreateGPUBuffer");

        var ti = std.mem.zeroes(cc.SDL_GPUTransferBufferCreateInfo);
        ti.usage = cc.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
        ti.size = @intCast(bytes.len);
        const tb = try checkPtr(cc.SDL_CreateGPUTransferBuffer(self.device, &ti), "CreateUploadTB");
        defer cc.SDL_ReleaseGPUTransferBuffer(self.device, tb);

        const map = cc.SDL_MapGPUTransferBuffer(self.device, tb, false);
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
        return buf;
    }

    // ---- per-tile buffers (the tile cache) ---------------------------------
    pub const TileBuffers = struct {
        vbuf: ?*cc.SDL_GPUBuffer = null,
        ibuf: ?*cc.SDL_GPUBuffer = null,
        cbuf: [scene.MAX_SCHEMES]?*cc.SDL_GPUBuffer = .{ null, null, null },
        index_count: u32 = 0,
        qbuf: ?*cc.SDL_GPUBuffer = null,
        quad_count: u32 = 0,
        /// Start of each paint band in each buffer. Bands come from the engine's
        /// paint_key — see scene.zig. Index into qbuf/ibuf/pbuf respectively.
        quad_band_off: [scene.BANDS + 1]u32 = @splat(0),
        geom_band_off: [scene.BANDS + 1]u32 = @splat(0),
        pattern_band_off: [scene.BANDS + 1]u32 = @splat(0),
        pbuf: ?*cc.SDL_GPUBuffer = null, // area fill patterns (tiled atlas cells)
        pattern_count: u32 = 0,
    };

    /// Replace the view's decluttered label quads (one buffer for the whole view).
    pub fn uploadLabels(self: *Gpu, quads: []const scene.QuadVertex) !void {
        if (self.label_buf) |b| cc.SDL_ReleaseGPUBuffer(self.device, b);
        self.label_buf = null;
        self.label_count = 0;
        if (quads.len == 0) return;
        self.label_buf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(quads));
        self.label_count = @intCast(quads.len);
    }

    /// Upload one tile's tessellation to its own GPU buffers.
    pub fn uploadTileScene(self: *Gpu, s: *scene.Scene) !TileBuffers {
        var tb = TileBuffers{};
        if (s.quads.items.len > 0) tb.qbuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(s.quads.items));
        tb.quad_count = @intCast(s.quads.items.len);
        tb.quad_band_off = s.quad_band_off;
        tb.geom_band_off = s.geom_band_off;
        tb.pattern_band_off = s.pattern_band_off;
        if (s.pattern_verts.items.len > 0) tb.pbuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(s.pattern_verts.items));
        tb.pattern_count = @intCast(s.pattern_verts.items.len);
        if (s.verts.items.len != 0 and s.indices.len != 0) {
            tb.vbuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(s.verts.items));
            tb.ibuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_INDEX, std.mem.sliceAsBytes(s.indices));
            tb.index_count = @intCast(s.indices.len);
            for (0..s.n_schemes) |k| {
                if (s.scheme_colors[k].len == 0) continue;
                tb.cbuf[k] = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(s.scheme_colors[k]));
            }
        }
        return tb;
    }
    pub fn freeTileBuffers(self: *Gpu, tb: *TileBuffers) void {
        const d = self.device;
        if (tb.vbuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        if (tb.ibuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        for (tb.cbuf) |c| if (c) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        if (tb.qbuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        if (tb.pbuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        tb.* = .{};
    }

    /// One tile to draw: its buffers + the per-tile uniform (mvp folds the tile origin).
    pub const TileDraw = struct { bufs: *const TileBuffers, uniform: Uniforms };

    fn recordTiles(self: *Gpu, cmd: *cc.SDL_GPUCommandBuffer, target: *cc.SDL_GPUTexture, resolve: ?*cc.SDL_GPUTexture, tiles: []const TileDraw, scheme_k: usize, text_on: bool, label_u: ?Uniforms) void {
        var cti = std.mem.zeroes(cc.SDL_GPUColorTargetInfo);
        cti.texture = target;
        cti.clear_color = self.clear;
        cti.load_op = cc.SDL_GPU_LOADOP_CLEAR;
        if (resolve) |rt| {
            cti.store_op = cc.SDL_GPU_STOREOP_RESOLVE;
            cti.resolve_texture = rt;
        } else cti.store_op = cc.SDL_GPU_STOREOP_STORE;
        const pass = cc.SDL_BeginGPURenderPass(cmd, &cti, 1, null);
        const vp = cc.SDL_GPUViewport{ .x = 0, .y = 0, .w = @floatFromInt(self.width), .h = @floatFromInt(self.height), .min_depth = 0, .max_depth = 1 };
        // PAINT ORDER ACROSS PIPELINES.
        //
        // The engine hands us the scene already in S-52 order (PresLib
        // §10.3.4.1: DisplayPlane, display priority, geometry class, emission
        // order). We split it into three GPU buffers by draw type, and drawing
        // those buffers whole — all geometry, then all patterns, then all
        // sprites — silently re-imposes draw type as the dominant key. That is
        // how a light sector arc (a stroke at priority 24) ended up under every
        // wreck sprite (priority 12).
        //
        // So walk the BANDS on the outside and the buffers within, which is the
        // only arrangement that keeps priority dominant while still batching.
        // Within one band the class order is areas -> patterns -> lines and the
        // rest -> sprites; geom_band_area_end is the split point in the index
        // buffer that lets the pattern pipeline sit between the first two.
        //
        // Cost is ~(non-empty bands x visible tiles) draws per pipeline. Empty
        // bands are skipped, and most of the 62 are empty on any real chart.
        const have_pat = self.sprite_tex != null and self.pattern_pipeline != null;
        const have_spr = self.sprite_tex != null and self.sprite_pipeline != null;
        const atlas_samp = [_]cc.SDL_GPUTextureSamplerBinding{.{ .texture = self.sprite_tex, .sampler = self.sampler }};

        for (0..scene.BANDS) |b| {
            // One band = one paint key = one class, so each buffer needs at most
            // one draw. Ordering between the buffers inside a band is therefore
            // moot; ordering BETWEEN bands is the engine's and we just ascend.
            for (tiles) |t| {
                if (t.bufs.index_count == 0 or t.bufs.cbuf[scheme_k] == null) continue;
                const first = t.bufs.geom_band_off[b];
                const count = t.bufs.geom_band_off[b + 1] - first;
                if (count == 0) continue;
                cc.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
                cc.SDL_SetGPUViewport(pass, &vp);
                const binds = [_]cc.SDL_GPUBufferBinding{ .{ .buffer = t.bufs.vbuf, .offset = 0 }, .{ .buffer = t.bufs.cbuf[scheme_k], .offset = 0 } };
                cc.SDL_BindGPUVertexBuffers(pass, 0, &binds, 2);
                const ib = cc.SDL_GPUBufferBinding{ .buffer = t.bufs.ibuf, .offset = 0 };
                cc.SDL_BindGPUIndexBuffer(pass, &ib, cc.SDL_GPU_INDEXELEMENTSIZE_32BIT);
                var uu = t.uniform;
                cc.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
                cc.SDL_DrawGPUIndexedPrimitives(pass, count, 1, first, 0, 0);
            }
            if (have_pat) {
                for (tiles) |t| {
                    if (t.bufs.pattern_count == 0) continue;
                    const first = t.bufs.pattern_band_off[b];
                    const count = t.bufs.pattern_band_off[b + 1] - first;
                    if (count == 0) continue;
                    cc.SDL_BindGPUGraphicsPipeline(pass, self.pattern_pipeline);
                    cc.SDL_SetGPUViewport(pass, &vp);
                    cc.SDL_BindGPUFragmentSamplers(pass, 0, &atlas_samp, 1);
                    const pb = [_]cc.SDL_GPUBufferBinding{.{ .buffer = t.bufs.pbuf, .offset = 0 }};
                    cc.SDL_BindGPUVertexBuffers(pass, 0, &pb, 1);
                    var uu = t.uniform;
                    cc.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
                    cc.SDL_DrawGPUPrimitives(pass, count, 1, first, 0);
                }
            }
            if (have_spr) {
                for (tiles) |t| {
                    if (t.bufs.quad_count == 0) continue;
                    const first = t.bufs.quad_band_off[b];
                    const count = t.bufs.quad_band_off[b + 1] - first;
                    if (count == 0) continue;
                    cc.SDL_BindGPUGraphicsPipeline(pass, self.sprite_pipeline);
                    cc.SDL_SetGPUViewport(pass, &vp);
                    cc.SDL_BindGPUFragmentSamplers(pass, 0, &atlas_samp, 1);
                    const qb = [_]cc.SDL_GPUBufferBinding{.{ .buffer = t.bufs.qbuf, .offset = 0 }};
                    cc.SDL_BindGPUVertexBuffers(pass, 0, &qb, 1);
                    var uu = t.uniform;
                    cc.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
                    cc.SDL_DrawGPUPrimitives(pass, count, 1, first, 0);
                }
            }
        }
        // Decluttered labels last, on top of everything (S-52 paint order): ONE
        // view-wide buffer with one uniform, not a per-tile loop.
        if (text_on and label_u != null and self.label_count > 0 and self.glyph_tex != null and self.sdf_pipeline != null) {
            cc.SDL_BindGPUGraphicsPipeline(pass, self.sdf_pipeline);
            cc.SDL_SetGPUViewport(pass, &vp);
            const samp = [_]cc.SDL_GPUTextureSamplerBinding{.{ .texture = self.glyph_tex, .sampler = self.sampler }};
            cc.SDL_BindGPUFragmentSamplers(pass, 0, &samp, 1);
            const tbind = [_]cc.SDL_GPUBufferBinding{.{ .buffer = self.label_buf, .offset = 0 }};
            cc.SDL_BindGPUVertexBuffers(pass, 0, &tbind, 1);
            var uu = label_u.?;
            cc.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
            cc.SDL_DrawGPUPrimitives(pass, self.label_count, 1, 0, 0);
        }
        cc.SDL_EndGPURenderPass(pass);
    }

    pub fn renderWindowTiles(self: *Gpu, tiles: []const TileDraw, scheme_k: usize, text_on: bool, label_u: ?Uniforms) !bool {
        const window = self.window orelse return false;
        const cmd = try checkPtr(cc.SDL_AcquireGPUCommandBuffer(self.device), "AcquireCmd");
        var swap: ?*cc.SDL_GPUTexture = null;
        var w: u32 = 0;
        var h: u32 = 0;
        try check(cc.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &swap, &w, &h), "AcquireSwapchain");
        if (swap == null) {
            _ = cc.SDL_SubmitGPUCommandBuffer(cmd);
            return true;
        }
        if (self.msaa_used) self.recordTiles(cmd, self.msaa_tex.?, swap, tiles, scheme_k, text_on, label_u) else self.recordTiles(cmd, swap.?, null, tiles, scheme_k, text_on, label_u);
        try check(cc.SDL_SubmitGPUCommandBuffer(cmd), "submit frame");
        return true;
    }

    pub fn renderOffscreenTiles(self: *Gpu, alloc: std.mem.Allocator, tiles: []const TileDraw, scheme_k: usize, text_on: bool, label_u: ?Uniforms) ![]u8 {
        try self.ensureOffscreenTargets();
        const resolve = self.resolve_tex.?;
        const cmd = try checkPtr(cc.SDL_AcquireGPUCommandBuffer(self.device), "AcquireCmd");
        if (self.msaa_used) self.recordTiles(cmd, self.msaa_tex.?, resolve, tiles, scheme_k, text_on, label_u) else self.recordTiles(cmd, resolve, null, tiles, scheme_k, text_on, label_u);
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
        const n = self.width * self.height * 4;
        const pixels = try alloc.dupe(u8, @as([*]const u8, @ptrCast(map))[0..n]);
        cc.SDL_UnmapGPUTransferBuffer(self.device, self.download_tb.?);
        return pixels;
    }

    pub fn uploadScene(self: *Gpu, s: *scene.Scene) !void {
        // An empty view (open ocean / no coverage / a zoom that composes nothing)
        // yields zero geometry — leave the buffers null and render only the
        // NODATA clear. (SDL_GPU rejects a 0-byte buffer.)
        self.index_count = 0;
        self.n_schemes = s.n_schemes;
        try self.uploadQuads(s.quads.items); // sprite symbols (may exist even with no fills)
        if (s.verts.items.len == 0 or s.indices.len == 0) return;
        self.vbuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(s.verts.items));
        self.ibuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_INDEX, std.mem.sliceAsBytes(s.indices));
        self.index_count = @intCast(s.indices.len);
        for (0..s.n_schemes) |k| {
            if (s.scheme_colors[k].len == 0) continue;
            self.color_bufs[k] = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(s.scheme_colors[k]));
        }
    }

    // ---- record + issue one frame's draws into a target -----------------
    fn recordDraws(self: *Gpu, cmd: *cc.SDL_GPUCommandBuffer, target: *cc.SDL_GPUTexture, resolve: ?*cc.SDL_GPUTexture, u: Uniforms, scheme_k: usize) void {
        var cti = std.mem.zeroes(cc.SDL_GPUColorTargetInfo);
        cti.texture = target;
        cti.clear_color = self.clear; // S-52 NODATA for the active palette
        cti.load_op = cc.SDL_GPU_LOADOP_CLEAR;
        if (resolve) |rt| {
            cti.store_op = cc.SDL_GPU_STOREOP_RESOLVE;
            cti.resolve_texture = rt;
        } else {
            cti.store_op = cc.SDL_GPU_STOREOP_STORE;
        }
        const pass = cc.SDL_BeginGPURenderPass(cmd, &cti, 1, null);
        cc.SDL_BindGPUGraphicsPipeline(pass, self.pipeline);
        const vp = cc.SDL_GPUViewport{ .x = 0, .y = 0, .w = @floatFromInt(self.width), .h = @floatFromInt(self.height), .min_depth = 0, .max_depth = 1 };
        cc.SDL_SetGPUViewport(pass, &vp);
        if (self.index_count > 0) {
            const binds = [_]cc.SDL_GPUBufferBinding{
                .{ .buffer = self.vbuf, .offset = 0 },
                .{ .buffer = self.color_bufs[scheme_k], .offset = 0 },
            };
            cc.SDL_BindGPUVertexBuffers(pass, 0, &binds, 2);
            const ib = cc.SDL_GPUBufferBinding{ .buffer = self.ibuf, .offset = 0 };
            cc.SDL_BindGPUIndexBuffer(pass, &ib, cc.SDL_GPU_INDEXELEMENTSIZE_32BIT);
            var uu = u;
            cc.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
            cc.SDL_DrawGPUIndexedPrimitives(pass, self.index_count, 1, 0, 0, 0);
        }
        // sprite symbols on top (textured quads sampling the shared atlas)
        if (self.quad_count > 0 and self.sprite_tex != null and self.sprite_pipeline != null) {
            cc.SDL_BindGPUGraphicsPipeline(pass, self.sprite_pipeline);
            cc.SDL_SetGPUViewport(pass, &vp);
            const qb = [_]cc.SDL_GPUBufferBinding{.{ .buffer = self.qbuf, .offset = 0 }};
            cc.SDL_BindGPUVertexBuffers(pass, 0, &qb, 1);
            const atlas_samp = [_]cc.SDL_GPUTextureSamplerBinding{.{ .texture = self.sprite_tex, .sampler = self.sampler }};
            cc.SDL_BindGPUFragmentSamplers(pass, 0, &atlas_samp, 1);
            var uu = u;
            cc.SDL_PushGPUVertexUniformData(cmd, 0, &uu, @sizeOf(Uniforms));
            cc.SDL_DrawGPUPrimitives(pass, self.quad_count, 1, 0, 0);
        }
        cc.SDL_EndGPURenderPass(pass);
    }

    /// Render one frame to the window and present. Returns false if no window.
    pub fn renderWindow(self: *Gpu, u: Uniforms, scheme_k: usize) !bool {
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
        if (self.msaa_used) {
            self.recordDraws(cmd, self.msaa_tex.?, swap, u, scheme_k);
        } else {
            self.recordDraws(cmd, swap.?, null, u, scheme_k);
        }
        try check(cc.SDL_SubmitGPUCommandBuffer(cmd), "submit frame");
        return true;
    }

    /// Render one frame offscreen and read the pixels back (RGBA8, top-down).
    pub fn renderOffscreen(self: *Gpu, alloc: std.mem.Allocator, u: Uniforms, scheme_k: usize) ![]u8 {
        try self.ensureOffscreenTargets(); // lazy (embed mode makes these on first snapshot)
        const resolve = self.resolve_tex orelse return error.NoOffscreenTarget;
        const cmd = try checkPtr(cc.SDL_AcquireGPUCommandBuffer(self.device), "AcquireCmd");
        if (self.msaa_used) {
            self.recordDraws(cmd, self.msaa_tex.?, resolve, u, scheme_k);
        } else {
            self.recordDraws(cmd, resolve, null, u, scheme_k);
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

    pub fn savePng(self: *Gpu, alloc: std.mem.Allocator, path: []const u8, u: Uniforms, scheme_k: usize) !void {
        const pixels = try self.renderOffscreen(alloc, u, scheme_k);
        defer alloc.free(pixels);
        try png.write(alloc, path, pixels, self.width, self.height);
    }

    pub fn deinit(self: *Gpu) void {
        const d = self.device;
        if (self.vbuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        if (self.ibuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        for (self.color_bufs) |cb| if (cb) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        if (self.label_buf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        if (self.msaa_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.resolve_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.download_tb) |t| cc.SDL_ReleaseGPUTransferBuffer(d, t);
        cc.SDL_ReleaseGPUGraphicsPipeline(d, self.pipeline);
        if (self.sprite_pipeline) |p| cc.SDL_ReleaseGPUGraphicsPipeline(d, p);
        if (self.sprite_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.glyph_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.sdf_pipeline) |p| cc.SDL_ReleaseGPUGraphicsPipeline(d, p);
        if (self.pattern_pipeline) |p| cc.SDL_ReleaseGPUGraphicsPipeline(d, p);
        if (self.sampler) |sm| cc.SDL_ReleaseGPUSampler(d, sm);
        if (self.qbuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        if (self.window) |w| {
            cc.SDL_ReleaseWindowFromGPUDevice(d, w);
            cc.SDL_DestroyWindow(w);
        }
        cc.SDL_DestroyGPUDevice(d);
    }

    /// Release just the scene GPU buffers (before uploading a rebuilt scene).
    pub fn releaseSceneBuffers(self: *Gpu) void {
        const d = self.device;
        if (self.vbuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        if (self.ibuf) |b| cc.SDL_ReleaseGPUBuffer(d, b);
        for (&self.color_bufs) |*cb| if (cb.*) |b| {
            cc.SDL_ReleaseGPUBuffer(d, b);
            cb.* = null;
        };
        self.vbuf = null;
        self.ibuf = null;
        self.index_count = 0;
    }
};
