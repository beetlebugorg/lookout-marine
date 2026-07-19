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

pub const Options = struct {
    width: u32,
    height: u32,
    want_window: bool,
    want_msaa: bool,
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

    pub fn init(opts: Options, vert_spv: []const u8, frag_spv: []const u8) !Gpu {
        try check(cc.SDL_Init(cc.SDL_INIT_VIDEO), "SDL_Init");
        const device = try checkPtr(cc.SDL_CreateGPUDevice(cc.SDL_GPU_SHADERFORMAT_SPIRV, true, null), "CreateGPUDevice");

        var window: ?*cc.SDL_Window = null;
        var color_format: cc.SDL_GPUTextureFormat = cc.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        if (opts.want_window) {
            window = cc.SDL_CreateWindow("lookout — tile57 SDL_GPU", @intCast(opts.width), @intCast(opts.height), 0);
            if (window != null) {
                try check(cc.SDL_ClaimWindowForGPUDevice(device, window), "ClaimWindow");
                color_format = cc.SDL_GetGPUSwapchainTextureFormat(device, window);
            } else {
                std.debug.print("no window ({s}); falling back to offscreen\n", .{cc.SDL_GetError()});
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

        var g = Gpu{
            .device = device,
            .window = window,
            .pipeline = pipeline,
            .color_format = color_format,
            .sample_count = sample_count,
            .msaa_used = msaa_used,
            .width = opts.width,
            .height = opts.height,
        };

        // offscreen targets when there is no window (headless), or always for PNG dumps
        if (window == null) try g.ensureOffscreenTargets();
        // an MSAA window still needs an intermediate multisample texture
        if (window != null and msaa_used) g.msaa_tex = try g.makeColorTex(sample_count, false);
        return g;
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

    fn ensureOffscreenTargets(self: *Gpu) !void {
        if (self.msaa_used) self.msaa_tex = try self.makeColorTex(self.sample_count, false);
        self.resolve_tex = try self.makeColorTex(cc.SDL_GPU_SAMPLECOUNT_1, false);
        var tb = std.mem.zeroes(cc.SDL_GPUTransferBufferCreateInfo);
        tb.usage = cc.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD;
        tb.size = self.width * self.height * 4;
        self.download_tb = try checkPtr(cc.SDL_CreateGPUTransferBuffer(self.device, &tb), "CreateDownloadTB");
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

    pub fn uploadScene(self: *Gpu, s: *scene.Scene) !void {
        const vbytes = std.mem.sliceAsBytes(s.verts.items);
        self.vbuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, vbytes);
        self.ibuf = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_INDEX, std.mem.sliceAsBytes(s.indices));
        self.index_count = @intCast(s.indices.len);
        self.n_schemes = s.n_schemes;
        for (0..s.n_schemes) |k| {
            self.color_bufs[k] = try self.uploadBuffer(cc.SDL_GPU_BUFFERUSAGE_VERTEX, std.mem.sliceAsBytes(s.scheme_colors[k]));
        }
    }

    // ---- record + issue one frame's draws into a target -----------------
    fn recordDraws(self: *Gpu, cmd: *cc.SDL_GPUCommandBuffer, target: *cc.SDL_GPUTexture, resolve: ?*cc.SDL_GPUTexture, u: Uniforms, scheme_k: usize) void {
        var cti = std.mem.zeroes(cc.SDL_GPUColorTargetInfo);
        cti.texture = target;
        cti.clear_color = .{ .r = 0.05, .g = 0.10, .b = 0.16, .a = 1.0 }; // deep water-ish clear
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
        if (self.msaa_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.resolve_tex) |t| cc.SDL_ReleaseGPUTexture(d, t);
        if (self.download_tb) |t| cc.SDL_ReleaseGPUTransferBuffer(d, t);
        cc.SDL_ReleaseGPUGraphicsPipeline(d, self.pipeline);
        if (self.window) |w| {
            cc.SDL_ReleaseWindowFromGPUDevice(d, w);
            cc.SDL_DestroyWindow(w);
        }
        cc.SDL_DestroyGPUDevice(d);
    }
};
