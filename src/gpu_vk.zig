//! Raw Vulkan transport for Android: device, four pipelines, persistent
//! buffers, and a per-frame render (present into the Java shell's
//! ANativeWindow OR headless offscreen readback). Selected by src/gpu.zig via
//! `-Dbackend=vk`. All vector work happens in tile57; the frame phase only
//! pushes a uniform and issues draws in paint order.
//!
//! Mirrors gpu_sdl.zig's contract exactly — same SPIR-V (shaders/vk/*.spv),
//! same vertex layouts, same blend state, same de-indexed triangles — with the
//! SDL_GPU conveniences hand-rolled:
//!   * per-draw uniforms: one host-visible ring buffer + dynamic-offset UBO
//!     descriptor sets matching SDL_GPU's set numbering (vtx set 1, sampler
//!     set 2, frag set 3), so the shaders are untouched;
//!   * vertex/quad buffers: host-visible + coherent, written directly (UMA
//!     phones; no staging submit, so makeScene never touches the queue);
//!   * textures: staging upload + layout transitions on a one-shot command
//!     buffer, fence-waited (render-thread only — async_build is off here).
//! Single frame in flight: the chart renders on demand, not at a locked 60 fps,
//! so simplicity wins over frame overlap.
const std = @import("std");
const cc = @import("c.zig").c; // tile57 + stb (shared; matches root's scene types)
const vk = @import("c_vk.zig").c; // Vulkan + ANativeWindow + android log

// Precompiled SPIR-V (see build.zig: -Dbackend=vk embeds these), converted to
// u32 words at comptime: @embedFile data carries NO alignment guarantee, and
// vkCreateShaderModule wants 4-aligned pCode — an @alignCast there panics (or
// is UB in release) whenever the linker happens to place a blob unaligned.
fn spvWords(comptime raw: []const u8) []const u32 {
    if (raw.len % 4 != 0) @compileError("SPIR-V length not a multiple of 4");
    comptime var words: [raw.len / 4]u32 = undefined;
    comptime @memcpy(std.mem.sliceAsBytes(words[0..]), raw);
    const final = words;
    return &final;
}
const chart_vert_spv = spvWords(@embedFile("chart_vert_spv"));
const chart_frag_spv = spvWords(@embedFile("chart_frag_spv"));
const sprite_vert_spv = spvWords(@embedFile("sprite_vert_spv"));
const sprite_frag_spv = spvWords(@embedFile("sprite_frag_spv"));
const sdf_frag_spv = spvWords(@embedFile("sdf_frag_spv"));
const pattern_vert_spv = spvWords(@embedFile("pattern_vert_spv"));
const pattern_frag_spv = spvWords(@embedFile("pattern_frag_spv"));

/// Vertex/fragment uniform block (128 bytes), byte-identical to `struct U` in
/// shaders/vk/*. THE ENGINE OWNS THIS LAYOUT (tile57 render/gpu.zig Uniforms,
/// mirrored as tile57_gpu_uniforms) — all three backends declared their own
/// copy until they disagreed about what `color` was for. Field docs live there;
/// the ABI gate in root.zig catches a skew at open.
pub const Uniforms = cc.tile57_gpu_uniforms;

/// RGBA colour 0..1.
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

// Monotonic clock straight from libc (bionic): the backends' shared timing ABI.
const Timespec = extern struct { sec: c_long, nsec: c_long };
extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
const CLOCK_MONOTONIC: c_int = 1;
pub fn ticksUs() i64 {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}
pub fn ticksMs() i64 {
    return @divTrunc(ticksUs(), 1000);
}

fn logErr(comptime fmt: [*:0]const u8, args: anytype) void {
    _ = @call(.auto, vk.__android_log_print, .{ @as(c_int, vk.ANDROID_LOG_ERROR), @as([*:0]const u8, "lookout") } ++ .{fmt} ++ args);
}
fn logInfo(comptime fmt: [*:0]const u8, args: anytype) void {
    _ = @call(.auto, vk.__android_log_print, .{ @as(c_int, vk.ANDROID_LOG_INFO), @as([*:0]const u8, "lookout") } ++ .{fmt} ++ args);
}

/// How to interpret Options.native_handle. Superset across backends so
/// root/capi share one ABI; this backend only accepts android_window.
pub const NativeKind = enum(c_int) {
    none = 0,
    metal_layer = 1, // Apple CAMetalLayer* — capi/root ABI parity only
    cocoa_window = 2,
    cocoa_view = 3,
    win32_hwnd = 4,
    x11_window = 5,
    uikit_windowscene = 6,
    android_window = 7, // ANativeWindow* (from the Java Surface via JNI)
};

pub const Options = struct {
    width: u32,
    height: u32,
    want_window: bool,
    want_msaa: bool = true,
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,
};

fn check(r: vk.VkResult, comptime what: []const u8) !void {
    if (r != vk.VK_SUCCESS) {
        logErr("vk error %d at " ++ what, .{r});
        std.debug.print("vk error {d} at {s}\n", .{ r, what });
        return error.VulkanFailure;
    }
}

const UNIFORM_ALIGN_MAX = 256; // >= any minUniformBufferOffsetAlignment
const RING_BYTES: u32 = 1 << 20; // 1 MiB: ~4096 draws/frame at 256B stride
const MAX_SET2 = 512; // texture descriptor sets (atlases + pattern cells)

const Buffer = struct {
    buf: vk.VkBuffer = null,
    mem: vk.VkDeviceMemory = null,
    mapped: ?[*]u8 = null,
    size: u64 = 0,
};

const Tex = struct {
    img: vk.VkImage = null,
    mem: vk.VkDeviceMemory = null,
    view: vk.VkImageView = null,
    dset: vk.VkDescriptorSet = null, // set 2 (combined image sampler)
};

pub const Gpu = struct {
    instance: vk.VkInstance,
    phys: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    qfam: u32,

    surface: vk.VkSurfaceKHR = null, // null => offscreen-only (snapshot)
    swapchain: vk.VkSwapchainKHR = null,
    sc_images: [8]vk.VkImage = @splat(null),
    sc_views: [8]vk.VkImageView = @splat(null),
    sc_fbs: [8]vk.VkFramebuffer = @splat(null),
    sc_count: u32 = 0,
    color_format: vk.VkFormat = vk.VK_FORMAT_R8G8B8A8_UNORM,
    color_space: vk.VkColorSpaceKHR = vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,

    render_pass: vk.VkRenderPass = null, // -> PRESENT (window)
    off_pass: vk.VkRenderPass = null, // -> TRANSFER_SRC (offscreen)

    set_layout_empty: vk.VkDescriptorSetLayout = null, // set 0
    set_layout_ubo: vk.VkDescriptorSetLayout = null, // sets 1 & 3 (dynamic UBO)
    set_layout_tex: vk.VkDescriptorSetLayout = null, // set 2
    pipe_layout: vk.VkPipelineLayout = null,
    pipeline: vk.VkPipeline = null, // chart
    sprite_pipeline: vk.VkPipeline = null,
    sdf_pipeline: vk.VkPipeline = null,
    pattern_pipeline: vk.VkPipeline = null,

    dpool: vk.VkDescriptorPool = null,
    vtx_uni_set: vk.VkDescriptorSet = null, // set 1 -> ring (dynamic)
    frag_uni_set: vk.VkDescriptorSet = null, // set 3 -> ring (dynamic)
    ring: Buffer = .{},
    ring_off: u32 = 0,
    uni_align: u32 = UNIFORM_ALIGN_MAX,
    sampler: vk.VkSampler = null,

    cmd_pool: vk.VkCommandPool = null,
    cmd: vk.VkCommandBuffer = null, // frame commands
    up_cmd: vk.VkCommandBuffer = null, // one-shot uploads
    fence: vk.VkFence = null, // frame fence
    up_fence: vk.VkFence = null,
    acquire_sem: vk.VkSemaphore = null,
    render_sem: vk.VkSemaphore = null,

    msaa_used: bool,
    msaa_img: vk.VkImage = null,
    msaa_mem: vk.VkDeviceMemory = null,
    msaa_view: vk.VkImageView = null,
    // offscreen (snapshot) target + readback
    off_img: vk.VkImage = null,
    off_mem: vk.VkDeviceMemory = null,
    off_view: vk.VkImageView = null,
    off_fb: vk.VkFramebuffer = null,
    download: Buffer = .{},

    window: ?*vk.ANativeWindow = null,
    width: u32,
    height: u32,
    external_window: bool = false,
    host_pt_w: f32 = 0,
    host_pt_h: f32 = 0,
    size_changed_ms: i64 = -100000,
    sc_retry_ms: i64 = -100000, // rate-limits the stale-extent rebuild below
    pixel_density: f32 = 1.0,
    host_density: f32 = 0, // host-declared scale; 0 = derive from the swapchain
    pattern_scale: f32 = 1,

    clear: Color = .{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 },
    scene: ?Scene = null,

    sprite_tex: ?Tex = null,
    glyph_tex: ?Tex = null,
    glyph_bold_tex: ?Tex = null,
    glyph_italic_tex: ?Tex = null,

    pub fn init(opts: Options) !Gpu {
        // ---- instance ------------------------------------------------------
        var app = std.mem.zeroes(vk.VkApplicationInfo);
        app.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app.pApplicationName = "lookout marine";
        app.apiVersion = vk.VK_API_VERSION_1_0;
        const inst_exts = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_android_surface" };
        var ici = std.mem.zeroes(vk.VkInstanceCreateInfo);
        ici.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        ici.pApplicationInfo = &app;
        const want_surface = opts.native_kind == .android_window and opts.native_handle != null;
        if (want_surface) {
            ici.enabledExtensionCount = inst_exts.len;
            ici.ppEnabledExtensionNames = @ptrCast(&inst_exts);
        }
        var instance: vk.VkInstance = null;
        try check(vk.vkCreateInstance(&ici, null, &instance), "vkCreateInstance");
        logInfo("vk: instance up (surface=%d)", .{@as(c_int, @intFromBool(want_surface))});

        // ---- physical device + queue family --------------------------------
        var ndev: u32 = 0;
        _ = vk.vkEnumeratePhysicalDevices(instance, &ndev, null);
        if (ndev == 0) return error.VulkanFailure;
        var devs: [8]vk.VkPhysicalDevice = @splat(null);
        if (ndev > devs.len) ndev = devs.len;
        _ = vk.vkEnumeratePhysicalDevices(instance, &ndev, &devs);
        const phys = devs[0];
        var nq: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, null);
        var qprops: [16]vk.VkQueueFamilyProperties = undefined;
        if (nq > qprops.len) nq = qprops.len;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, &qprops);
        var qfam: u32 = 0;
        var found = false;
        for (qprops[0..nq], 0..) |qp, i| {
            if (qp.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) {
                qfam = @intCast(i);
                found = true;
                break;
            }
        }
        if (!found) return error.VulkanFailure;

        var lim: vk.VkPhysicalDeviceProperties = undefined;
        vk.vkGetPhysicalDeviceProperties(phys, &lim);
        var uni_align: u32 = @intCast(lim.limits.minUniformBufferOffsetAlignment);
        if (uni_align == 0) uni_align = 4;
        // draw stride: sizeof(Uniforms)=128 rounded to the alignment
        if (uni_align < @sizeOf(Uniforms)) uni_align = std.mem.alignForward(u32, @sizeOf(Uniforms), uni_align);

        // ---- logical device -------------------------------------------------
        const prio: f32 = 1.0;
        var qci = std.mem.zeroes(vk.VkDeviceQueueCreateInfo);
        qci.sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        qci.queueFamilyIndex = qfam;
        qci.queueCount = 1;
        qci.pQueuePriorities = &prio;
        // maintenance1: negative-height viewport for the Y flip (see
        // recordDraws). Core since 1.1; universally shipped on 1.0 drivers.
        // swapchain only when presenting.
        const dev_exts = [_][*:0]const u8{ "VK_KHR_maintenance1", "VK_KHR_swapchain" };
        var dci = std.mem.zeroes(vk.VkDeviceCreateInfo);
        dci.sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        dci.queueCreateInfoCount = 1;
        dci.pQueueCreateInfos = &qci;
        dci.enabledExtensionCount = if (want_surface) dev_exts.len else 1;
        dci.ppEnabledExtensionNames = @ptrCast(&dev_exts);
        var device: vk.VkDevice = null;
        try check(vk.vkCreateDevice(phys, &dci, null, &device), "vkCreateDevice");
        var queue: vk.VkQueue = null;
        vk.vkGetDeviceQueue(device, qfam, 0, &queue);
        logInfo("vk: device up (%s), qfam=%u align=%u", .{ @as([*:0]const u8, @ptrCast(&lim.deviceName)), qfam, uni_align });

        var g = Gpu{
            .instance = instance,
            .phys = phys,
            .device = device,
            .queue = queue,
            .qfam = qfam,
            .msaa_used = false,
            .width = opts.width,
            .height = opts.height,
            .external_window = want_surface,
            .uni_align = uni_align,
        };

        // ---- surface + real size -------------------------------------------
        if (want_surface) {
            g.window = @ptrCast(opts.native_handle);
            var sci = std.mem.zeroes(vk.VkAndroidSurfaceCreateInfoKHR);
            sci.sType = vk.VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR;
            sci.window = g.window;
            try check(vk.vkCreateAndroidSurfaceKHR(instance, &sci, null, &g.surface), "vkCreateAndroidSurfaceKHR");
            const ww = vk.ANativeWindow_getWidth(g.window);
            const wh = vk.ANativeWindow_getHeight(g.window);
            if (ww > 0 and wh > 0) {
                g.width = @intCast(ww);
                g.height = @intCast(wh);
            }
            // pick the surface's colour format (prefer RGBA8) + ITS colorspace
            var nfmt: u32 = 0;
            _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(phys, g.surface, &nfmt, null);
            var fmts: [32]vk.VkSurfaceFormatKHR = undefined;
            if (nfmt > fmts.len) nfmt = fmts.len;
            _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(phys, g.surface, &nfmt, &fmts);
            if (nfmt > 0) {
                g.color_format = fmts[0].format;
                g.color_space = fmts[0].colorSpace;
                for (fmts[0..nfmt]) |f| {
                    if (f.format == vk.VK_FORMAT_R8G8B8A8_UNORM) {
                        g.color_format = f.format;
                        g.color_space = f.colorSpace;
                        break;
                    }
                }
            }
        }

        // ---- MSAA 4x if the format supports it ------------------------------
        if (opts.want_msaa and std.c.getenv("LOOKOUT_NO_MSAA") == null) {
            const counts = lim.limits.framebufferColorSampleCounts;
            if (counts & vk.VK_SAMPLE_COUNT_4_BIT != 0) g.msaa_used = true;
        }

        // ---- fixed objects ---------------------------------------------------
        try g.createDescriptorInfra();
        logInfo("vk: descriptors up", .{});
        try g.createRenderPasses();
        try g.createPipelines();
        logInfo("vk: pipelines up (fmt=%d msaa=%d)", .{ @as(c_int, @intCast(g.color_format)), @as(c_int, @intFromBool(g.msaa_used)) });
        try g.createCommandInfra();
        if (g.surface != null) try g.createSwapchain() else try g.ensureOffscreenTargets();
        logInfo("vk: ready %ux%u (sc=%u)", .{ g.width, g.height, g.sc_count });
        return g;
    }

    // ---- memory helpers ------------------------------------------------------
    fn memType(self: *Gpu, type_bits: u32, props: vk.VkMemoryPropertyFlags) !u32 {
        var mp: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.vkGetPhysicalDeviceMemoryProperties(self.phys, &mp);
        var i: u32 = 0;
        while (i < mp.memoryTypeCount) : (i += 1) {
            if (type_bits & (@as(u32, 1) << @intCast(i)) != 0 and
                mp.memoryTypes[i].propertyFlags & props == props) return i;
        }
        return error.VulkanFailure;
    }

    fn createBuffer(self: *Gpu, size: u64, usage: vk.VkBufferUsageFlags, host: bool) !Buffer {
        var bi = std.mem.zeroes(vk.VkBufferCreateInfo);
        bi.sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bi.size = size;
        bi.usage = usage;
        bi.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
        var out = Buffer{ .size = size };
        try check(vk.vkCreateBuffer(self.device, &bi, null, &out.buf), "vkCreateBuffer");
        errdefer vk.vkDestroyBuffer(self.device, out.buf, null);
        var req: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(self.device, out.buf, &req);
        var ai = std.mem.zeroes(vk.VkMemoryAllocateInfo);
        ai.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        ai.allocationSize = req.size;
        const props: vk.VkMemoryPropertyFlags = if (host)
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
        else
            vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
        ai.memoryTypeIndex = try self.memType(req.memoryTypeBits, props);
        try check(vk.vkAllocateMemory(self.device, &ai, null, &out.mem), "vkAllocateMemory buf");
        errdefer vk.vkFreeMemory(self.device, out.mem, null);
        try check(vk.vkBindBufferMemory(self.device, out.buf, out.mem, 0), "vkBindBufferMemory");
        if (host) {
            var p: ?*anyopaque = null;
            try check(vk.vkMapMemory(self.device, out.mem, 0, vk.VK_WHOLE_SIZE, 0, &p), "vkMapMemory");
            out.mapped = @ptrCast(p);
        }
        return out;
    }

    fn destroyBuffer(self: *Gpu, b: *Buffer) void {
        if (b.mapped != null) vk.vkUnmapMemory(self.device, b.mem);
        if (b.buf != null) vk.vkDestroyBuffer(self.device, b.buf, null);
        if (b.mem != null) vk.vkFreeMemory(self.device, b.mem, null);
        b.* = .{};
    }

    fn createImage(self: *Gpu, w: u32, h: u32, format: vk.VkFormat, samples: vk.VkSampleCountFlagBits, usage: vk.VkImageUsageFlags, img: *vk.VkImage, mem: *vk.VkDeviceMemory, view: *vk.VkImageView) !void {
        var ii = std.mem.zeroes(vk.VkImageCreateInfo);
        ii.sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ii.imageType = vk.VK_IMAGE_TYPE_2D;
        ii.format = format;
        ii.extent = .{ .width = w, .height = h, .depth = 1 };
        ii.mipLevels = 1;
        ii.arrayLayers = 1;
        ii.samples = samples;
        ii.tiling = vk.VK_IMAGE_TILING_OPTIMAL;
        ii.usage = usage;
        ii.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
        ii.initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
        try check(vk.vkCreateImage(self.device, &ii, null, img), "vkCreateImage");
        var req: vk.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(self.device, img.*, &req);
        var ai = std.mem.zeroes(vk.VkMemoryAllocateInfo);
        ai.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        ai.allocationSize = req.size;
        ai.memoryTypeIndex = try self.memType(req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try check(vk.vkAllocateMemory(self.device, &ai, null, mem), "vkAllocateMemory img");
        try check(vk.vkBindImageMemory(self.device, img.*, mem.*, 0), "vkBindImageMemory");
        var vi = std.mem.zeroes(vk.VkImageViewCreateInfo);
        vi.sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vi.image = img.*;
        vi.viewType = vk.VK_IMAGE_VIEW_TYPE_2D;
        vi.format = format;
        vi.subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try check(vk.vkCreateImageView(self.device, &vi, null, view), "vkCreateImageView");
    }

    // ---- descriptors / uniform ring -------------------------------------------
    fn createDescriptorInfra(self: *Gpu) !void {
        // set 0: empty (glslang numbers our sets 1..3; Vulkan wants a layout per slot)
        var e = std.mem.zeroes(vk.VkDescriptorSetLayoutCreateInfo);
        e.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        try check(vk.vkCreateDescriptorSetLayout(self.device, &e, null, &self.set_layout_empty), "empty set layout");
        // sets 1/3: one dynamic UBO visible to both stages (set 1 is read by the
        // vertex stage, set 3 by the sdf fragment stage; one layout serves both)
        var ub = std.mem.zeroes(vk.VkDescriptorSetLayoutBinding);
        ub.binding = 0;
        ub.descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
        ub.descriptorCount = 1;
        ub.stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT;
        var ul = std.mem.zeroes(vk.VkDescriptorSetLayoutCreateInfo);
        ul.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        ul.bindingCount = 1;
        ul.pBindings = &ub;
        try check(vk.vkCreateDescriptorSetLayout(self.device, &ul, null, &self.set_layout_ubo), "ubo set layout");
        // set 2: combined image sampler (fragment)
        var tb = std.mem.zeroes(vk.VkDescriptorSetLayoutBinding);
        tb.binding = 0;
        tb.descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        tb.descriptorCount = 1;
        tb.stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT;
        var tl = std.mem.zeroes(vk.VkDescriptorSetLayoutCreateInfo);
        tl.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        tl.bindingCount = 1;
        tl.pBindings = &tb;
        try check(vk.vkCreateDescriptorSetLayout(self.device, &tl, null, &self.set_layout_tex), "tex set layout");
        // one pipeline layout for all four pipelines (sets 0..3)
        const layouts = [_]vk.VkDescriptorSetLayout{ self.set_layout_empty, self.set_layout_ubo, self.set_layout_tex, self.set_layout_ubo };
        var pl = std.mem.zeroes(vk.VkPipelineLayoutCreateInfo);
        pl.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pl.setLayoutCount = layouts.len;
        pl.pSetLayouts = &layouts;
        try check(vk.vkCreatePipelineLayout(self.device, &pl, null, &self.pipe_layout), "pipeline layout");

        // pool: 2 dynamic-UBO sets + MAX_SET2 sampler sets, individually freeable
        const sizes = [_]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, .descriptorCount = 4 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = MAX_SET2 },
        };
        var pi = std.mem.zeroes(vk.VkDescriptorPoolCreateInfo);
        pi.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pi.flags = vk.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        pi.maxSets = MAX_SET2 + 4;
        pi.poolSizeCount = sizes.len;
        pi.pPoolSizes = &sizes;
        try check(vk.vkCreateDescriptorPool(self.device, &pi, null, &self.dpool), "descriptor pool");

        // the ring + its two dynamic sets
        self.ring = try self.createBuffer(RING_BYTES, vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, true);
        var alloc_l = [_]vk.VkDescriptorSetLayout{ self.set_layout_ubo, self.set_layout_ubo };
        var sets = [_]vk.VkDescriptorSet{ null, null };
        var asi = std.mem.zeroes(vk.VkDescriptorSetAllocateInfo);
        asi.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        asi.descriptorPool = self.dpool;
        asi.descriptorSetCount = 2;
        asi.pSetLayouts = &alloc_l;
        try check(vk.vkAllocateDescriptorSets(self.device, &asi, &sets), "uniform sets");
        self.vtx_uni_set = sets[0];
        self.frag_uni_set = sets[1];
        var dbi = vk.VkDescriptorBufferInfo{ .buffer = self.ring.buf, .offset = 0, .range = @sizeOf(Uniforms) };
        var writes: [2]vk.VkWriteDescriptorSet = undefined;
        for (&writes, sets) |*w, s| {
            w.* = std.mem.zeroes(vk.VkWriteDescriptorSet);
            w.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            w.dstSet = s;
            w.dstBinding = 0;
            w.descriptorCount = 1;
            w.descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
            w.pBufferInfo = &dbi;
        }
        vk.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);

        // shared linear clamp sampler
        var si = std.mem.zeroes(vk.VkSamplerCreateInfo);
        si.sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        si.magFilter = vk.VK_FILTER_LINEAR;
        si.minFilter = vk.VK_FILTER_LINEAR;
        si.mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_LINEAR;
        si.addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        si.addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        si.addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        si.maxLod = vk.VK_LOD_CLAMP_NONE;
        try check(vk.vkCreateSampler(self.device, &si, null, &self.sampler), "vkCreateSampler");
    }

    // ---- render passes ---------------------------------------------------------
    fn makePass(self: *Gpu, final_layout: vk.VkImageLayout) !vk.VkRenderPass {
        const samples: vk.VkSampleCountFlagBits = if (self.msaa_used) vk.VK_SAMPLE_COUNT_4_BIT else vk.VK_SAMPLE_COUNT_1_BIT;
        var atts: [2]vk.VkAttachmentDescription = undefined;
        var natt: u32 = 1;
        atts[0] = std.mem.zeroes(vk.VkAttachmentDescription);
        atts[0].format = self.color_format;
        atts[0].samples = samples;
        atts[0].loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR;
        atts[0].storeOp = if (self.msaa_used) vk.VK_ATTACHMENT_STORE_OP_DONT_CARE else vk.VK_ATTACHMENT_STORE_OP_STORE;
        atts[0].stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        atts[0].stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        atts[0].initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
        atts[0].finalLayout = if (self.msaa_used) vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL else final_layout;
        var color_ref = vk.VkAttachmentReference{ .attachment = 0, .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var resolve_ref = vk.VkAttachmentReference{ .attachment = 1, .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        if (self.msaa_used) {
            natt = 2;
            atts[1] = std.mem.zeroes(vk.VkAttachmentDescription);
            atts[1].format = self.color_format;
            atts[1].samples = vk.VK_SAMPLE_COUNT_1_BIT;
            atts[1].loadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            atts[1].storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE;
            atts[1].stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
            atts[1].stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            atts[1].initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
            atts[1].finalLayout = final_layout;
        }
        var sub = std.mem.zeroes(vk.VkSubpassDescription);
        sub.pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS;
        sub.colorAttachmentCount = 1;
        sub.pColorAttachments = &color_ref;
        if (self.msaa_used) sub.pResolveAttachments = &resolve_ref;
        var dep = std.mem.zeroes(vk.VkSubpassDependency);
        dep.srcSubpass = vk.VK_SUBPASS_EXTERNAL;
        dep.dstSubpass = 0;
        dep.srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.srcAccessMask = 0;
        dep.dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dep.dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        var rp = std.mem.zeroes(vk.VkRenderPassCreateInfo);
        rp.sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        rp.attachmentCount = natt;
        rp.pAttachments = &atts;
        rp.subpassCount = 1;
        rp.pSubpasses = &sub;
        rp.dependencyCount = 1;
        rp.pDependencies = &dep;
        var pass: vk.VkRenderPass = null;
        try check(vk.vkCreateRenderPass(self.device, &rp, null, &pass), "vkCreateRenderPass");
        return pass;
    }

    fn createRenderPasses(self: *Gpu) !void {
        if (self.surface != null) self.render_pass = try self.makePass(vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
        self.off_pass = try self.makePass(vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
    }

    // ---- pipelines ---------------------------------------------------------------
    fn makeShaderModule(self: *Gpu, spv: []const u32) !vk.VkShaderModule {
        var ci = std.mem.zeroes(vk.VkShaderModuleCreateInfo);
        ci.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        ci.codeSize = spv.len * 4;
        ci.pCode = spv.ptr;
        var m: vk.VkShaderModule = null;
        try check(vk.vkCreateShaderModule(self.device, &ci, null, &m), "vkCreateShaderModule");
        return m;
    }

    const VAttr = struct { loc: u32, format: vk.VkFormat, offset: u32 };
    // chart + pattern: tile57_gpu_vertex (32B) — world f2@0, local f2@8,
    // scamin f@16, packed u32@20, colour ubyte4@24, depth f@28.
    const tri_attrs = [_]VAttr{
        .{ .loc = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
        .{ .loc = 1, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 8 },
        .{ .loc = 2, .format = vk.VK_FORMAT_R32_SFLOAT, .offset = 16 },
        .{ .loc = 3, .format = vk.VK_FORMAT_R32_UINT, .offset = 20 },
        .{ .loc = 4, .format = vk.VK_FORMAT_R8G8B8A8_UNORM, .offset = 24 },
        .{ .loc = 5, .format = vk.VK_FORMAT_R32_SFLOAT, .offset = 28 },
    };
    // sprite + SDF: tile57_gpu_quad (44B) — world f2@0, local f2@8, uv f2@16,
    // colour ubyte4@24, weight f@28, scamin f@32, packed u32@36, depth f@40.
    const quad_attrs = [_]VAttr{
        .{ .loc = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
        .{ .loc = 1, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 8 },
        .{ .loc = 2, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 16 },
        .{ .loc = 3, .format = vk.VK_FORMAT_R8G8B8A8_UNORM, .offset = 24 },
        .{ .loc = 4, .format = vk.VK_FORMAT_R32_SFLOAT, .offset = 28 },
        .{ .loc = 5, .format = vk.VK_FORMAT_R32_SFLOAT, .offset = 32 },
        .{ .loc = 6, .format = vk.VK_FORMAT_R32_UINT, .offset = 36 },
        .{ .loc = 7, .format = vk.VK_FORMAT_R32_SFLOAT, .offset = 40 },
    };

    fn buildPipeline(self: *Gpu, vspv: []const u32, fspv: []const u32, stride: u32, attrs: []const VAttr) !vk.VkPipeline {
        const vmod = try self.makeShaderModule(vspv);
        defer vk.vkDestroyShaderModule(self.device, vmod, null);
        const fmod = try self.makeShaderModule(fspv);
        defer vk.vkDestroyShaderModule(self.device, fmod, null);
        var stages: [2]vk.VkPipelineShaderStageCreateInfo = undefined;
        for (&stages, [_]vk.VkShaderModule{ vmod, fmod }, [_]c_uint{ vk.VK_SHADER_STAGE_VERTEX_BIT, vk.VK_SHADER_STAGE_FRAGMENT_BIT }) |*s, m, st| {
            s.* = std.mem.zeroes(vk.VkPipelineShaderStageCreateInfo);
            s.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            s.stage = st;
            s.module = m;
            s.pName = "main";
        }
        const bind = vk.VkVertexInputBindingDescription{ .binding = 0, .stride = stride, .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX };
        var vat: [8]vk.VkVertexInputAttributeDescription = undefined;
        for (attrs, 0..) |a, i| vat[i] = .{ .location = a.loc, .binding = 0, .format = a.format, .offset = a.offset };
        var vi = std.mem.zeroes(vk.VkPipelineVertexInputStateCreateInfo);
        vi.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vi.vertexBindingDescriptionCount = 1;
        vi.pVertexBindingDescriptions = &bind;
        vi.vertexAttributeDescriptionCount = @intCast(attrs.len);
        vi.pVertexAttributeDescriptions = &vat;
        var ia = std.mem.zeroes(vk.VkPipelineInputAssemblyStateCreateInfo);
        ia.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        ia.topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        var vp = std.mem.zeroes(vk.VkPipelineViewportStateCreateInfo);
        vp.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        vp.viewportCount = 1;
        vp.scissorCount = 1;
        var rs = std.mem.zeroes(vk.VkPipelineRasterizationStateCreateInfo);
        rs.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        rs.polygonMode = vk.VK_POLYGON_MODE_FILL;
        rs.cullMode = vk.VK_CULL_MODE_NONE;
        rs.frontFace = vk.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        rs.lineWidth = 1.0;
        var ms = std.mem.zeroes(vk.VkPipelineMultisampleStateCreateInfo);
        ms.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        ms.rasterizationSamples = if (self.msaa_used) vk.VK_SAMPLE_COUNT_4_BIT else vk.VK_SAMPLE_COUNT_1_BIT;
        var blend_att = std.mem.zeroes(vk.VkPipelineColorBlendAttachmentState);
        blend_att.blendEnable = vk.VK_TRUE;
        blend_att.srcColorBlendFactor = vk.VK_BLEND_FACTOR_SRC_ALPHA;
        blend_att.dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend_att.colorBlendOp = vk.VK_BLEND_OP_ADD;
        blend_att.srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE;
        blend_att.dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend_att.alphaBlendOp = vk.VK_BLEND_OP_ADD;
        blend_att.colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT;
        var cb = std.mem.zeroes(vk.VkPipelineColorBlendStateCreateInfo);
        cb.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        cb.attachmentCount = 1;
        cb.pAttachments = &blend_att;
        const dyn = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        var dy = std.mem.zeroes(vk.VkPipelineDynamicStateCreateInfo);
        dy.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dy.dynamicStateCount = dyn.len;
        dy.pDynamicStates = &dyn;
        var pci = std.mem.zeroes(vk.VkGraphicsPipelineCreateInfo);
        pci.sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pci.stageCount = 2;
        pci.pStages = &stages;
        pci.pVertexInputState = &vi;
        pci.pInputAssemblyState = &ia;
        pci.pViewportState = &vp;
        pci.pRasterizationState = &rs;
        pci.pMultisampleState = &ms;
        pci.pColorBlendState = &cb;
        pci.pDynamicState = &dy;
        pci.layout = self.pipe_layout;
        // window pass when there is a surface, else the offscreen pass — both
        // have identical attachment topology, so pipelines are compatible.
        pci.renderPass = if (self.render_pass != null) self.render_pass else self.off_pass;
        pci.subpass = 0;
        var p: vk.VkPipeline = null;
        try check(vk.vkCreateGraphicsPipelines(self.device, null, 1, &pci, null, &p), "vkCreateGraphicsPipelines");
        return p;
    }

    fn createPipelines(self: *Gpu) !void {
        self.pipeline = try self.buildPipeline(chart_vert_spv, chart_frag_spv, @sizeOf(cc.tile57_gpu_vertex), &tri_attrs);
        self.pattern_pipeline = try self.buildPipeline(pattern_vert_spv, pattern_frag_spv, @sizeOf(cc.tile57_gpu_vertex), &tri_attrs);
        self.sprite_pipeline = try self.buildPipeline(sprite_vert_spv, sprite_frag_spv, @sizeOf(cc.tile57_gpu_quad), &quad_attrs);
        self.sdf_pipeline = try self.buildPipeline(sprite_vert_spv, sdf_frag_spv, @sizeOf(cc.tile57_gpu_quad), &quad_attrs);
    }

    // ---- commands / sync ----------------------------------------------------------
    fn createCommandInfra(self: *Gpu) !void {
        var cp = std.mem.zeroes(vk.VkCommandPoolCreateInfo);
        cp.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        cp.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        cp.queueFamilyIndex = self.qfam;
        try check(vk.vkCreateCommandPool(self.device, &cp, null, &self.cmd_pool), "vkCreateCommandPool");
        var cai = std.mem.zeroes(vk.VkCommandBufferAllocateInfo);
        cai.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cai.commandPool = self.cmd_pool;
        cai.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cai.commandBufferCount = 2;
        var bufs = [_]vk.VkCommandBuffer{ null, null };
        try check(vk.vkAllocateCommandBuffers(self.device, &cai, &bufs), "vkAllocateCommandBuffers");
        self.cmd = bufs[0];
        self.up_cmd = bufs[1];
        var fi = std.mem.zeroes(vk.VkFenceCreateInfo);
        fi.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fi.flags = vk.VK_FENCE_CREATE_SIGNALED_BIT;
        try check(vk.vkCreateFence(self.device, &fi, null, &self.fence), "frame fence");
        var fi2 = std.mem.zeroes(vk.VkFenceCreateInfo);
        fi2.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        try check(vk.vkCreateFence(self.device, &fi2, null, &self.up_fence), "upload fence");
        var si = std.mem.zeroes(vk.VkSemaphoreCreateInfo);
        si.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        try check(vk.vkCreateSemaphore(self.device, &si, null, &self.acquire_sem), "acquire sem");
        try check(vk.vkCreateSemaphore(self.device, &si, null, &self.render_sem), "render sem");
    }

    /// One-shot upload commands: record via the callback, submit, fence-wait.
    /// Render-thread only (async_build is disabled on this backend).
    fn oneShot(self: *Gpu, ctx: anytype, comptime record: fn (@TypeOf(ctx), vk.VkCommandBuffer) void) !void {
        try check(vk.vkResetCommandBuffer(self.up_cmd, 0), "reset up cmd");
        var bi = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        bi.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(vk.vkBeginCommandBuffer(self.up_cmd, &bi), "begin up cmd");
        record(ctx, self.up_cmd);
        try check(vk.vkEndCommandBuffer(self.up_cmd), "end up cmd");
        var si = std.mem.zeroes(vk.VkSubmitInfo);
        si.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &self.up_cmd;
        try check(vk.vkQueueSubmit(self.queue, 1, &si, self.up_fence), "submit upload");
        _ = vk.vkWaitForFences(self.device, 1, &self.up_fence, vk.VK_TRUE, std.math.maxInt(u64));
        _ = vk.vkResetFences(self.device, 1, &self.up_fence);
    }

    // ---- swapchain -------------------------------------------------------------
    fn createSwapchain(self: *Gpu) !void {
        var caps: vk.VkSurfaceCapabilitiesKHR = undefined;
        try check(vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.phys, self.surface, &caps), "surface caps");
        var extent = caps.currentExtent;
        if (extent.width == 0xFFFFFFFF) extent = .{ .width = self.width, .height = self.height };
        if (extent.width == 0 or extent.height == 0) return; // minimized; retry later
        self.width = extent.width;
        self.height = extent.height;
        var count: u32 = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and count > caps.maxImageCount) count = caps.maxImageCount;
        if (count > self.sc_images.len) count = self.sc_images.len;
        var sci = std.mem.zeroes(vk.VkSwapchainCreateInfoKHR);
        sci.sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        sci.surface = self.surface;
        sci.minImageCount = count;
        sci.imageFormat = self.color_format;
        sci.imageColorSpace = self.color_space;
        sci.imageExtent = extent;
        sci.imageArrayLayers = 1;
        sci.imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        sci.imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
        // Declaring currentTransform promises the presentation engine that the
        // frame is ALREADY rotated into the display's orientation. We never
        // pre-rotate, so on a device reporting ROTATE_90 the map stays put
        // while the screen turns and lands squeezed into the new aspect. Ask
        // for identity and let the compositor rotate.
        sci.preTransform = if (caps.supportedTransforms & vk.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR != 0)
            @as(u32, vk.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR)
        else
            caps.currentTransform;
        sci.compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        sci.presentMode = vk.VK_PRESENT_MODE_FIFO_KHR; // vsync; always available
        sci.clipped = vk.VK_TRUE;
        sci.oldSwapchain = self.swapchain;
        var newsc: vk.VkSwapchainKHR = null;
        try check(vk.vkCreateSwapchainKHR(self.device, &sci, null, &newsc), "vkCreateSwapchainKHR");
        if (self.swapchain != null) vk.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = newsc;

        var n: u32 = 0;
        _ = vk.vkGetSwapchainImagesKHR(self.device, self.swapchain, &n, null);
        if (n > self.sc_images.len) n = self.sc_images.len;
        _ = vk.vkGetSwapchainImagesKHR(self.device, self.swapchain, &n, &self.sc_images);
        self.sc_count = n;
        try self.ensureMsaa();
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            var vi = std.mem.zeroes(vk.VkImageViewCreateInfo);
            vi.sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            vi.image = self.sc_images[i];
            vi.viewType = vk.VK_IMAGE_VIEW_TYPE_2D;
            vi.format = self.color_format;
            vi.subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            try check(vk.vkCreateImageView(self.device, &vi, null, &self.sc_views[i]), "swapchain view");
            const atts = if (self.msaa_used)
                [2]vk.VkImageView{ self.msaa_view, self.sc_views[i] }
            else
                [2]vk.VkImageView{ self.sc_views[i], null };
            var fb = std.mem.zeroes(vk.VkFramebufferCreateInfo);
            fb.sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb.renderPass = self.render_pass;
            fb.attachmentCount = if (self.msaa_used) 2 else 1;
            fb.pAttachments = &atts;
            fb.width = self.width;
            fb.height = self.height;
            fb.layers = 1;
            try check(vk.vkCreateFramebuffer(self.device, &fb, null, &self.sc_fbs[i]), "swapchain fb");
        }
    }

    fn destroySwapchainViews(self: *Gpu) void {
        var i: u32 = 0;
        while (i < self.sc_count) : (i += 1) {
            if (self.sc_fbs[i] != null) vk.vkDestroyFramebuffer(self.device, self.sc_fbs[i], null);
            if (self.sc_views[i] != null) vk.vkDestroyImageView(self.device, self.sc_views[i], null);
            self.sc_fbs[i] = null;
            self.sc_views[i] = null;
        }
        self.sc_count = 0;
    }

    /// True when the swapchain no longer matches the host's declared viewport
    /// (a rotation): host points x density is the pixel extent we should have.
    fn extentStale(self: *const Gpu) bool {
        if (self.host_pt_w <= 0 or self.host_pt_h <= 0 or self.pixel_density <= 0) return false;
        const w: u32 = @intFromFloat(@round(self.host_pt_w * self.pixel_density));
        const h: u32 = @intFromFloat(@round(self.host_pt_h * self.pixel_density));
        const dw = if (w > self.width) w - self.width else self.width - w;
        const dh = if (h > self.height) h - self.height else self.height - h;
        return dw > 2 or dh > 2; // slack for the points->pixels rounding
    }

    fn recreateSwapchain(self: *Gpu) void {
        _ = vk.vkDeviceWaitIdle(self.device);
        self.destroySwapchainViews();
        self.releaseMsaa();
        self.createSwapchain() catch |e| {
            logErr("swapchain recreate failed: %d", .{@as(c_int, @intFromError(e))});
            return;
        };
        logInfo("vk: swapchain now %ux%u (host pts %ux%u)", .{ self.width, self.height, @as(u32, @intFromFloat(self.host_pt_w)), @as(u32, @intFromFloat(self.host_pt_h)) });
        self.size_changed_ms = ticksMs();
    }

    fn ensureMsaa(self: *Gpu) !void {
        if (self.msaa_used and self.msaa_img == null) {
            try self.createImage(self.width, self.height, self.color_format, vk.VK_SAMPLE_COUNT_4_BIT, vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT, &self.msaa_img, &self.msaa_mem, &self.msaa_view);
        }
    }
    fn releaseMsaa(self: *Gpu) void {
        if (self.msaa_view != null) vk.vkDestroyImageView(self.device, self.msaa_view, null);
        if (self.msaa_img != null) vk.vkDestroyImage(self.device, self.msaa_img, null);
        if (self.msaa_mem != null) vk.vkFreeMemory(self.device, self.msaa_mem, null);
        self.msaa_view = null;
        self.msaa_img = null;
        self.msaa_mem = null;
    }

    fn ensureOffscreenTargets(self: *Gpu) !void {
        try self.ensureMsaa();
        if (self.off_img == null) {
            try self.createImage(self.width, self.height, self.color_format, vk.VK_SAMPLE_COUNT_1_BIT, vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &self.off_img, &self.off_mem, &self.off_view);
            const atts = if (self.msaa_used)
                [2]vk.VkImageView{ self.msaa_view, self.off_view }
            else
                [2]vk.VkImageView{ self.off_view, null };
            var fb = std.mem.zeroes(vk.VkFramebufferCreateInfo);
            fb.sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb.renderPass = self.off_pass;
            fb.attachmentCount = if (self.msaa_used) 2 else 1;
            fb.pAttachments = &atts;
            fb.width = self.width;
            fb.height = self.height;
            fb.layers = 1;
            try check(vk.vkCreateFramebuffer(self.device, &fb, null, &self.off_fb), "offscreen fb");
        }
        if (self.download.buf == null)
            self.download = try self.createBuffer(@as(u64, self.width) * self.height * 4, vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT, true);
    }
    fn releaseOffscreen(self: *Gpu) void {
        if (self.off_fb != null) vk.vkDestroyFramebuffer(self.device, self.off_fb, null);
        if (self.off_view != null) vk.vkDestroyImageView(self.device, self.off_view, null);
        if (self.off_img != null) vk.vkDestroyImage(self.device, self.off_img, null);
        if (self.off_mem != null) vk.vkFreeMemory(self.device, self.off_mem, null);
        self.off_fb = null;
        self.off_view = null;
        self.off_img = null;
        self.off_mem = null;
        self.destroyBuffer(&self.download);
    }

    /// Resize the render surface. width/height are logical points from the host
    /// (Java) view; the pixel size follows the swapchain. Their ratio is the
    /// pixel density (the camera's HiDPI denominator).
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) !void {
        self.host_pt_w = @floatFromInt(width_pts);
        self.host_pt_h = @floatFromInt(height_pts);
        if (self.surface == null) {
            // offscreen-only: logical == pixel
            if (width_pts != self.width or height_pts != self.height) {
                _ = vk.vkDeviceWaitIdle(self.device);
                self.releaseOffscreen();
                self.releaseMsaa();
                self.width = width_pts;
                self.height = height_pts;
                try self.ensureOffscreenTargets();
            }
        }
        // Only when the host hasn't told us outright. Across a rotation the
        // swapchain extent lags the new logical size — the surface keeps
        // reporting the OLD currentExtent until an acquire returns OUT_OF_DATE
        // — so this pairs a stale pixel width with a fresh point width and
        // lands ~0.67 where the display's real scale is 1.125.
        if (self.host_density == 0 and self.host_pt_w > 0 and self.width > 0) {
            const d = @as(f32, @floatFromInt(self.width)) / self.host_pt_w;
            if (d > 0.2 and d < 8.0) self.pixel_density = d;
        }
        // A rotation is a resize the DRIVER may never complain about: Android is
        // happy to scale a portrait-shaped swapchain into a landscape surface, so
        // acquire/present keep returning SUCCESS while SurfaceFlinger resamples
        // every pixel (measured after one rotation round trip: an 1340x800 layer
        // squeezed into an 800x1340 display, the whole chart soft while the
        // Compose HUD above it stayed sharp). The host's declared viewport is the
        // authority, so rebuild on it rather than waiting to be told.
        if (self.surface != null and self.swapchain != null and self.extentStale()) self.recreateSwapchain();
    }

    /// The host's own scale factor (Android's DisplayMetrics.density), which is
    /// constant across rotations — unlike anything derivable from the swapchain.
    /// Set once at open; it then wins over the derived value above.
    pub fn setPixelDensity(self: *Gpu, d: f32) void {
        if (d > 0.2 and d < 8.0) {
            self.host_density = d;
            self.pixel_density = d;
        }
    }

    // ---- atlases / textures --------------------------------------------------------
    pub fn uploadSpriteAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.sprite_tex = try self.makeTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.glyph_tex = try self.makeTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlasBold(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.glyph_bold_tex = try self.makeTexture(rgba, w, h);
    }
    pub fn uploadGlyphAtlasItalic(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        self.glyph_italic_tex = try self.makeTexture(rgba, w, h);
    }

    fn makeTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !Tex {
        var t = Tex{};
        try self.createImage(w, h, vk.VK_FORMAT_R8G8B8A8_UNORM, vk.VK_SAMPLE_COUNT_1_BIT, vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT, &t.img, &t.mem, &t.view);
        var staging = try self.createBuffer(rgba.len, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, true);
        defer self.destroyBuffer(&staging);
        @memcpy(staging.mapped.?[0..rgba.len], rgba);
        const Ctx = struct { img: vk.VkImage, w: u32, h: u32, buf: vk.VkBuffer };
        try self.oneShot(Ctx{ .img = t.img, .w = w, .h = h, .buf = staging.buf }, struct {
            fn rec(ctx: Ctx, cmd: vk.VkCommandBuffer) void {
                var bar = std.mem.zeroes(vk.VkImageMemoryBarrier);
                bar.sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
                bar.srcAccessMask = 0;
                bar.dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
                bar.oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
                bar.newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                bar.srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
                bar.dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
                bar.image = ctx.img;
                bar.subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
                vk.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &bar);
                var region = std.mem.zeroes(vk.VkBufferImageCopy);
                region.imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
                region.imageExtent = .{ .width = ctx.w, .height = ctx.h, .depth = 1 };
                vk.vkCmdCopyBufferToImage(cmd, ctx.buf, ctx.img, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
                bar.srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
                bar.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
                bar.oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                bar.newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                vk.vkCmdPipelineBarrier(cmd, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &bar);
            }
        }.rec);
        // set 2 descriptor for this texture
        var asi = std.mem.zeroes(vk.VkDescriptorSetAllocateInfo);
        asi.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        asi.descriptorPool = self.dpool;
        asi.descriptorSetCount = 1;
        asi.pSetLayouts = &self.set_layout_tex;
        try check(vk.vkAllocateDescriptorSets(self.device, &asi, &t.dset), "tex dset");
        var dii = vk.VkDescriptorImageInfo{ .sampler = self.sampler, .imageView = t.view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        var w0 = std.mem.zeroes(vk.VkWriteDescriptorSet);
        w0.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        w0.dstSet = t.dset;
        w0.dstBinding = 0;
        w0.descriptorCount = 1;
        w0.descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        w0.pImageInfo = &dii;
        vk.vkUpdateDescriptorSets(self.device, 1, &w0, 0, null);
        return t;
    }

    fn destroyTexture(self: *Gpu, t: *Tex) void {
        if (t.dset != null) _ = vk.vkFreeDescriptorSets(self.device, self.dpool, 1, &t.dset);
        if (t.view != null) vk.vkDestroyImageView(self.device, t.view, null);
        if (t.img != null) vk.vkDestroyImage(self.device, t.img, null);
        if (t.mem != null) vk.vkFreeMemory(self.device, t.mem, null);
        t.* = .{};
    }

    // ---- scene ------------------------------------------------------------------
    const PatternTex = struct { tex: ?Tex = null, w: f32 = 1, h: f32 = 1 };

    /// GPU-resident whole-view scene. Triangles are DE-INDEXED (flat,
    /// non-indexed) at upload — matches the SDL backend so the two Vulkan
    /// flavours stay byte-comparable.
    pub const Scene = struct {
        vbuf: Buffer = .{}, // de-indexed triangle vertices (tile57_gpu_vertex)
        qbuf: Buffer = .{}, // sprite/SDF quads (tile57_gpu_quad)
        index_count: u32 = 0, // vertices in vbuf (== the engine's index count)
        ranges: []cc.tile57_gpu_range = &.{},
        patterns: []PatternTex = &.{},
        alloc: std.mem.Allocator,
    };

    pub fn makeScene(self: *Gpu, alloc: std.mem.Allocator, s: *const cc.tile57_gpu_scene) !Scene {
        var out = Scene{ .alloc = alloc };
        errdefer self.freeSceneValue(&out);
        if (s.vertex_count > 0 and s.index_count > 0) {
            const verts = s.vertices[0..s.vertex_count];
            const idx = s.indices[0..s.index_count];
            out.vbuf = try self.createBuffer(@as(u64, s.index_count) * @sizeOf(cc.tile57_gpu_vertex), vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, true);
            const dst: [*]cc.tile57_gpu_vertex = @ptrCast(@alignCast(out.vbuf.mapped.?));
            for (idx, 0..) |ii, k| dst[k] = verts[ii];
            out.index_count = @intCast(s.index_count);
        }
        if (s.quad_count > 0) {
            const bytes = std.mem.sliceAsBytes(s.quads[0..s.quad_count]);
            out.qbuf = try self.createBuffer(bytes.len, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, true);
            @memcpy(out.qbuf.mapped.?[0..bytes.len], bytes);
        }
        if (s.range_count > 0) out.ranges = try alloc.dupe(cc.tile57_gpu_range, s.ranges[0..s.range_count]);
        if (s.pattern_count > 0) {
            out.patterns = try alloc.alloc(PatternTex, s.pattern_count);
            for (out.patterns) |*p| p.* = .{};
            for (s.patterns[0..s.pattern_count], out.patterns) |cell, *p| {
                p.w = @floatFromInt(cell.w);
                p.h = @floatFromInt(cell.h);
                const need = @as(usize, cell.w) * cell.h * 4;
                if (cell.w > 0 and cell.h > 0 and cell.w <= 4096 and cell.h <= 4096 and cell.rgba != null and cell.rgba_len >= need)
                    p.tex = self.makeTexture(cell.rgba[0..need], cell.w, cell.h) catch null;
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
        // The scene being freed may still be referenced by the frame in flight.
        _ = vk.vkWaitForFences(self.device, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64));
        self.destroyBuffer(&s.vbuf);
        self.destroyBuffer(&s.qbuf);
        for (s.patterns) |*p| if (p.tex) |*t| {
            var v = t.*;
            self.destroyTexture(&v);
        };
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

    // ---- frame ---------------------------------------------------------------------
    /// Copy a Uniforms into the ring; returns its dynamic offset.
    fn pushUniform(self: *Gpu, u: *const Uniforms) ?u32 {
        if (self.ring_off + self.uni_align > RING_BYTES) return null; // ring full: skip draw
        const off = self.ring_off;
        @memcpy(self.ring.mapped.?[off .. off + @sizeOf(Uniforms)], std.mem.asBytes(u));
        self.ring_off = off + self.uni_align;
        return off;
    }

    fn recordDraws(self: *Gpu, cmd: vk.VkCommandBuffer, pass: vk.VkRenderPass, fb: vk.VkFramebuffer, u: Uniforms, text_on: bool, sound_on: bool) void {
        self.ring_off = 0;
        var clear = std.mem.zeroes(vk.VkClearValue);
        clear.color.float32 = .{ self.clear.r, self.clear.g, self.clear.b, self.clear.a };
        const clears = [2]vk.VkClearValue{ clear, clear };
        var rbi = std.mem.zeroes(vk.VkRenderPassBeginInfo);
        rbi.sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rbi.renderPass = pass;
        rbi.framebuffer = fb;
        rbi.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } };
        rbi.clearValueCount = if (self.msaa_used) 2 else 1;
        rbi.pClearValues = &clears;
        vk.vkCmdBeginRenderPass(cmd, &rbi, vk.VK_SUBPASS_CONTENTS_INLINE);
        defer vk.vkCmdEndRenderPass(cmd);
        // NEGATIVE-height viewport (VK_KHR_maintenance1): Vulkan NDC is Y-down,
        // but the shaders/uniforms are shared with the Metal and SDL_GPU
        // backends, whose NDC is Y-up (SDL_GPU does this same flip internally
        // on its Vulkan path). Without it the chart renders upside down.
        const fh: f32 = @floatFromInt(self.height);
        const vp = vk.VkViewport{ .x = 0, .y = fh, .width = @floatFromInt(self.width), .height = -fh, .minDepth = 0, .maxDepth = 1 };
        vk.vkCmdSetViewport(cmd, 0, 1, &vp);
        const scis = vk.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } };
        vk.vkCmdSetScissor(cmd, 0, 1, &scis);

        const s = if (self.scene) |*sc| sc else return; // no scene: clear only
        var bound_pipe: vk.VkPipeline = null;
        var bound_tex: vk.VkDescriptorSet = null;
        const zero: u64 = 0;

        // CONTIGUOUS ranges with the same draw spec (pipeline, texture, uniform
        // payload) collapse into ONE vkCmdDraw, exactly as the Metal backend does.
        // Colour rides in the vertices, so a whole paint band of differently
        // coloured fills is one spec; assemble() already re-lays the vertex and
        // quad streams in sorted range order precisely so a host can do this. A
        // coastal view carries ~5,000 ranges, i.e. ~10,000 command calls a frame
        // before merging — recordDraws was 21% of native time on device. A skipped
        // range breaks contiguity, so merging can never draw gated-off content,
        // and merged primitives rasterize in the same order they would have.
        const Run = struct {
            active: bool = false,
            tri: bool = false,
            pipe: vk.VkPipeline = null,
            tex: vk.VkDescriptorSet = null,
            first: u32 = 0,
            count: u32 = 0,
            uu: Uniforms = undefined,
            halo: bool = false, // glyph run: also push the frag (halo) uniform
        };
        var run = Run{};
        var draws: u32 = 0;
        const flush = struct {
            fn go(g: *Gpu, cmd2: vk.VkCommandBuffer, sc: *const Scene, rn: *Run, bp: *vk.VkPipeline, bt: *vk.VkDescriptorSet, z0: *const u64, n: *u32) void {
                if (!rn.active or rn.count == 0) return;
                rn.active = false;
                if (rn.pipe != bp.*) {
                    vk.vkCmdBindPipeline(cmd2, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, rn.pipe);
                    bp.* = rn.pipe;
                    const vb = if (rn.tri) &sc.vbuf.buf else &sc.qbuf.buf;
                    vk.vkCmdBindVertexBuffers(cmd2, 0, 1, vb, z0);
                }
                if (rn.tex != null and rn.tex != bt.*) {
                    var ds = rn.tex;
                    vk.vkCmdBindDescriptorSets(cmd2, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, g.pipe_layout, 2, 1, &ds, 0, null);
                    bt.* = rn.tex;
                }
                var uu2 = rn.uu;
                const voff = g.pushUniform(&uu2) orelse return;
                vk.vkCmdBindDescriptorSets(cmd2, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, g.pipe_layout, 1, 1, &g.vtx_uni_set, 1, &voff);
                if (rn.halo) {
                    // SDF halo renders in the palette background colour (sdf.frag,
                    // set 3): a hardcoded white halo glared at night.
                    uu2.color = .{ g.clear.r, g.clear.g, g.clear.b, 1 };
                    const foff = g.pushUniform(&uu2) orelse return;
                    vk.vkCmdBindDescriptorSets(cmd2, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, g.pipe_layout, 3, 1, &g.frag_uni_set, 1, &foff);
                }
                vk.vkCmdDraw(cmd2, rn.count, 1, rn.first, 0);
                n.* += 1;
            }
        }.go;
        // A run only extends when EVERY bit of its draw spec matches and the
        // primitives abut; otherwise the pending run is flushed and a new one opens.
        const emit = struct {
            fn go(g: *Gpu, cmd2: vk.VkCommandBuffer, sc: *const Scene, rn: *Run, bp: *vk.VkPipeline, bt: *vk.VkDescriptorSet, z0: *const u64, n: *u32, fl: anytype, tri: bool, pipe: vk.VkPipeline, tex: vk.VkDescriptorSet, first: u32, count: u32, uu: Uniforms, halo: bool) void {
                if (rn.active and rn.tri == tri and rn.pipe == pipe and rn.tex == tex and rn.halo == halo and
                    rn.first + rn.count == first and
                    std.mem.eql(u8, std.mem.asBytes(&rn.uu), std.mem.asBytes(&uu)))
                {
                    rn.count += count;
                    return;
                }
                fl(g, cmd2, sc, rn, bp, bt, z0, n);
                rn.* = .{ .active = true, .tri = tri, .pipe = pipe, .tex = tex, .first = first, .count = count, .uu = uu, .halo = halo };
            }
        }.go;

        for (s.ranges) |r| {
            switch (r.kind) {
                cc.TILE57_GPU_TEXT => if (!text_on) continue,
                cc.TILE57_GPU_SOUNDING => if (!sound_on) continue,
                else => {},
            }
            var uu = u;
            if (r.kind == cc.TILE57_GPU_SOUNDING) uu.cat_mask |= @as(u32, 1) << 2;
            if (r.prim == cc.TILE57_GPU_TRIANGLES) {
                if (s.vbuf.buf == null) continue;
                var pipe = self.pipeline;
                var tex_set: vk.VkDescriptorSet = null;
                if (r.pattern != cc.TILE57_GPU_NO_PATTERN and r.pattern < s.patterns.len and s.patterns[r.pattern].tex != null) {
                    const pt = s.patterns[r.pattern];
                    const cs = self.pixel_density * self.pattern_scale;
                    uu.cell_px = .{ pt.w * cs, pt.h * cs };
                    pipe = self.pattern_pipeline;
                    tex_set = pt.tex.?.dset;
                } else if (r.pattern != cc.TILE57_GPU_NO_PATTERN) {
                    continue; // pattern with no cell texture: the fill under it already drew
                }
                emit(self, cmd, s, &run, &bound_pipe, &bound_tex, &zero, &draws, flush, true, pipe, tex_set, r.first, r.count, uu, false);
            } else { // QUADS
                if (s.qbuf.buf == null) continue;
                const is_glyph = r.atlas == cc.TILE57_GPU_ATLAS_GLYPH or r.atlas == cc.TILE57_GPU_ATLAS_GLYPH_BOLD or r.atlas == cc.TILE57_GPU_ATLAS_GLYPH_ITALIC;
                const tex: ?Tex = switch (r.atlas) {
                    cc.TILE57_GPU_ATLAS_GLYPH => self.glyph_tex,
                    cc.TILE57_GPU_ATLAS_GLYPH_BOLD => self.glyph_bold_tex orelse self.glyph_tex,
                    cc.TILE57_GPU_ATLAS_GLYPH_ITALIC => self.glyph_italic_tex orelse self.glyph_tex,
                    else => self.sprite_tex,
                };
                const pipe = if (is_glyph) self.sdf_pipeline else self.sprite_pipeline;
                if (tex == null or pipe == null) continue;
                emit(self, cmd, s, &run, &bound_pipe, &bound_tex, &zero, &draws, flush, false, pipe, tex.?.dset, r.first, r.count, uu, is_glyph);
            }
        }
        flush(self, cmd, s, &run, &bound_pipe, &bound_tex, &zero, &draws);
    }

    /// Render one frame to the window and present. Returns false if no window.
    pub fn renderWindow(self: *Gpu, u: Uniforms, text_on: bool, sound_on: bool) !bool {
        if (self.surface == null) return false;
        if (self.swapchain == null) {
            self.recreateSwapchain(); // was minimized at init
            if (self.swapchain == null) return true;
        }
        // The surface can still report its OLD currentExtent when resize() runs,
        // in which case that rebuild picked the stale size — so re-check here and
        // try again, rate-limited so a mismatch we can never satisfy costs a few
        // rebuilds a second instead of one per frame.
        if (self.extentStale() and ticksMs() - self.sc_retry_ms > 250) {
            self.sc_retry_ms = ticksMs();
            self.recreateSwapchain();
            if (self.swapchain == null) return true;
        }
        _ = vk.vkWaitForFences(self.device, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64));
        var image_index: u32 = 0;
        const ar = vk.vkAcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.acquire_sem, null, &image_index);
        if (ar == vk.VK_ERROR_OUT_OF_DATE_KHR) {
            self.recreateSwapchain();
            return true; // present skipped; content still pending (view_dirty stays)
        }
        if (ar != vk.VK_SUCCESS and ar != vk.VK_SUBOPTIMAL_KHR) {
            try check(ar, "vkAcquireNextImageKHR");
        }
        _ = vk.vkResetFences(self.device, 1, &self.fence);
        try check(vk.vkResetCommandBuffer(self.cmd, 0), "reset cmd");
        var bi = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        bi.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(vk.vkBeginCommandBuffer(self.cmd, &bi), "begin cmd");
        self.recordDraws(self.cmd, self.render_pass, self.sc_fbs[image_index], u, text_on, sound_on);
        try check(vk.vkEndCommandBuffer(self.cmd), "end cmd");

        const wait_stage: vk.VkPipelineStageFlags = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        var si = std.mem.zeroes(vk.VkSubmitInfo);
        si.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.waitSemaphoreCount = 1;
        si.pWaitSemaphores = &self.acquire_sem;
        si.pWaitDstStageMask = &wait_stage;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &self.cmd;
        si.signalSemaphoreCount = 1;
        si.pSignalSemaphores = &self.render_sem;
        try check(vk.vkQueueSubmit(self.queue, 1, &si, self.fence), "submit frame");

        var pi = std.mem.zeroes(vk.VkPresentInfoKHR);
        pi.sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        pi.waitSemaphoreCount = 1;
        pi.pWaitSemaphores = &self.render_sem;
        pi.swapchainCount = 1;
        pi.pSwapchains = &self.swapchain;
        pi.pImageIndices = &image_index;
        const pr = vk.vkQueuePresentKHR(self.queue, &pi);
        // Asking for an identity preTransform on a display whose
        // currentTransform is a rotation makes SUBOPTIMAL the PERMANENT steady
        // state, so it alone is no reason to rebuild — that recreates the
        // swapchain every frame. Rebuild on it only when the extent actually
        // disagrees with the viewport the host declared.
        if (pr == vk.VK_ERROR_OUT_OF_DATE_KHR or (pr == vk.VK_SUBOPTIMAL_KHR and self.extentStale())) {
            self.recreateSwapchain();
        }
        return true;
    }

    /// Render one frame offscreen and read the pixels back (RGBA8, top-down).
    pub fn renderOffscreen(self: *Gpu, alloc: std.mem.Allocator, u: Uniforms, text_on: bool, sound_on: bool) ![]u8 {
        try self.ensureOffscreenTargets();
        _ = vk.vkWaitForFences(self.device, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64));
        _ = vk.vkResetFences(self.device, 1, &self.fence);
        try check(vk.vkResetCommandBuffer(self.cmd, 0), "reset cmd");
        var bi = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
        bi.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(vk.vkBeginCommandBuffer(self.cmd, &bi), "begin cmd");
        self.recordDraws(self.cmd, self.off_pass, self.off_fb, u, text_on, sound_on);
        // off_pass leaves the resolve image TRANSFER_SRC_OPTIMAL: copy it out
        var region = std.mem.zeroes(vk.VkBufferImageCopy);
        region.imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
        region.imageExtent = .{ .width = self.width, .height = self.height, .depth = 1 };
        vk.vkCmdCopyImageToBuffer(self.cmd, self.off_img, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.download.buf, 1, &region);
        try check(vk.vkEndCommandBuffer(self.cmd), "end cmd");
        var si = std.mem.zeroes(vk.VkSubmitInfo);
        si.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.commandBufferCount = 1;
        si.pCommandBuffers = &self.cmd;
        try check(vk.vkQueueSubmit(self.queue, 1, &si, self.fence), "submit offscreen");
        _ = vk.vkWaitForFences(self.device, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64));
        const n = @as(usize, self.width) * self.height * 4;
        return try alloc.dupe(u8, self.download.mapped.?[0..n]);
    }

    pub fn savePng(self: *Gpu, alloc: std.mem.Allocator, path: []const u8, u: Uniforms, text_on: bool, sound_on: bool) !void {
        const pixels = try self.renderOffscreen(alloc, u, text_on, sound_on);
        defer alloc.free(pixels);
        try @import("png.zig").write(alloc, path, pixels, self.width, self.height);
    }

    pub fn deinit(self: *Gpu) void {
        _ = vk.vkDeviceWaitIdle(self.device);
        self.freeScene();
        if (self.sprite_tex) |*t| self.destroyTexture(t);
        if (self.glyph_tex) |*t| self.destroyTexture(t);
        if (self.glyph_bold_tex) |*t| self.destroyTexture(t);
        if (self.glyph_italic_tex) |*t| self.destroyTexture(t);
        self.releaseOffscreen();
        self.destroySwapchainViews();
        if (self.swapchain != null) vk.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.releaseMsaa();
        self.destroyBuffer(&self.ring);
        if (self.acquire_sem != null) vk.vkDestroySemaphore(self.device, self.acquire_sem, null);
        if (self.render_sem != null) vk.vkDestroySemaphore(self.device, self.render_sem, null);
        if (self.fence != null) vk.vkDestroyFence(self.device, self.fence, null);
        if (self.up_fence != null) vk.vkDestroyFence(self.device, self.up_fence, null);
        if (self.cmd_pool != null) vk.vkDestroyCommandPool(self.device, self.cmd_pool, null);
        if (self.pipeline != null) vk.vkDestroyPipeline(self.device, self.pipeline, null);
        if (self.sprite_pipeline != null) vk.vkDestroyPipeline(self.device, self.sprite_pipeline, null);
        if (self.sdf_pipeline != null) vk.vkDestroyPipeline(self.device, self.sdf_pipeline, null);
        if (self.pattern_pipeline != null) vk.vkDestroyPipeline(self.device, self.pattern_pipeline, null);
        if (self.pipe_layout != null) vk.vkDestroyPipelineLayout(self.device, self.pipe_layout, null);
        if (self.dpool != null) vk.vkDestroyDescriptorPool(self.device, self.dpool, null);
        if (self.set_layout_empty != null) vk.vkDestroyDescriptorSetLayout(self.device, self.set_layout_empty, null);
        if (self.set_layout_ubo != null) vk.vkDestroyDescriptorSetLayout(self.device, self.set_layout_ubo, null);
        if (self.set_layout_tex != null) vk.vkDestroyDescriptorSetLayout(self.device, self.set_layout_tex, null);
        if (self.sampler != null) vk.vkDestroySampler(self.device, self.sampler, null);
        if (self.render_pass != null) vk.vkDestroyRenderPass(self.device, self.render_pass, null);
        if (self.off_pass != null) vk.vkDestroyRenderPass(self.device, self.off_pass, null);
        if (self.surface != null) vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        vk.vkDestroyDevice(self.device, null);
        vk.vkDestroyInstance(self.instance, null);
    }
};
