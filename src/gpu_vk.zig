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
const builtin = @import("builtin");
const cc = @import("c.zig").c; // tile57 + stb (shared; matches root's scene types)
const c_vk = @import("c_vk.zig");
const ov = @import("overlay.zig");
const vk = c_vk.c; // Vulkan (+ ANativeWindow and the android log sink on Android)

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

// Monotonic clock: the backends' shared timing ABI. Comptime-selected impl (as
// with root.zig's Lock) so only one platform's externs ever link —
// clock_gettime on Linux/Android (bionic), QueryPerformanceCounter on Windows
// (the MSVC CRT has no clock_gettime).
const clock = if (builtin.os.tag == .windows)
    struct {
        // WINAPI convention (stdcall on x86, C on x64/aarch64) for a correct x86 build.
        extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) c_int;
        extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) c_int;
        fn us() i64 {
            var ctr: i64 = 0;
            var freq: i64 = 0;
            _ = QueryPerformanceCounter(&ctr);
            _ = QueryPerformanceFrequency(&freq);
            if (freq == 0) return 0;
            // Split the divide so a large counter × 1e6 can't overflow i64.
            return @divTrunc(ctr, freq) * 1_000_000 + @divTrunc(@rem(ctr, freq) * 1_000_000, freq);
        }
    }
else
    struct {
        const Timespec = extern struct { sec: c_long, nsec: c_long };
        extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
        const CLOCK_MONOTONIC: c_int = 1;
        fn us() i64 {
            var ts: Timespec = .{ .sec = 0, .nsec = 0 };
            _ = clock_gettime(CLOCK_MONOTONIC, &ts);
            return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
        }
    };
pub fn ticksUs() i64 {
    return clock.us();
}
pub fn ticksMs() i64 {
    return @divTrunc(ticksUs(), 1000);
}

// Logging: logcat on Android, stderr elsewhere; both take a printf format.
extern "c" fn fprintf(stream: *anyopaque, fmt: [*:0]const u8, ...) c_int;
extern "c" fn fputc(ch: c_int, stream: *anyopaque) c_int;
// The stderr FILE*: a real exported symbol on glibc/bionic, but the MSVC UCRT
// has none — `stderr` is a macro over __acrt_iob_func(2). Comptime-selected so
// only the target's own accessor links.
const stderr_stream = if (builtin.os.tag == .windows)
    struct {
        extern "c" fn __acrt_iob_func(idx: c_uint) *anyopaque;
        fn get() *anyopaque {
            return __acrt_iob_func(2);
        }
    }
else
    struct {
        // A FILE* variable, so @extern gives its address — deref for the stream.
        const v: *const *anyopaque = @extern(*const *anyopaque, .{ .name = "stderr" });
        fn get() *anyopaque {
            return v.*;
        }
    };

fn logAt(comptime prio: c_int, comptime fmt: [*:0]const u8, args: anytype) void {
    if (c_vk.android) {
        _ = @call(.auto, vk.__android_log_print, .{ prio, @as([*:0]const u8, "lookout") } ++ .{fmt} ++ args);
    } else {
        const stream = stderr_stream.get();
        _ = @call(.auto, fprintf, .{ stream, fmt } ++ args);
        _ = fputc('\n', stream);
    }
}
fn logErr(comptime fmt: [*:0]const u8, args: anytype) void {
    logAt(if (c_vk.android) vk.ANDROID_LOG_ERROR else 0, fmt, args);
}
fn logInfo(comptime fmt: [*:0]const u8, args: anytype) void {
    logAt(if (c_vk.android) vk.ANDROID_LOG_INFO else 0, fmt, args);
}

/// True for _SRGB formats, whose write-time linear->sRGB encode would double up the already-sRGB palette.
fn isSrgbFormat(fmt: vk.VkFormat) bool {
    return fmt == vk.VK_FORMAT_R8G8B8A8_SRGB or
        fmt == vk.VK_FORMAT_B8G8R8A8_SRGB or
        fmt == vk.VK_FORMAT_A8B8G8R8_SRGB_PACK32;
}

/// How to interpret Options.native_handle. Superset across backends so
/// root/capi share one ABI.
pub const NativeKind = enum(c_int) {
    none = 0,
    metal_layer = 1, // Apple CAMetalLayer* — capi/root ABI parity only
    cocoa_window = 2,
    cocoa_view = 3,
    win32_hwnd = 4, // *const Win32Window
    x11_window = 5, // *const X11Window
    uikit_windowscene = 6,
    android_window = 7, // ANativeWindow* (from the Java Surface via JNI)
    wayland_surface = 8, // *const WaylandSurface
};

// ---- WSI, hand-declared ----------------------------------------------------
//
// Mirrors of the create-info structs from vulkan_win32.h / _xlib.h / _wayland.h,
// declared here so this core needs no X11/Wayland/Windows SDK (see c_vk.zig);
// their ABI is frozen and the sTypes come from the vendored vulkan_core.h. The
// functions load via vkGetInstanceProcAddr, so nothing links against them either.

/// A host's Win32 window. `hinstance` may be null — the loader falls back to
/// the module the window belongs to.
pub const Win32Window = extern struct { hinstance: ?*anyopaque, hwnd: ?*anyopaque };
/// A host's X11 window: an Xlib `Display*` and the `Window` XID.
pub const X11Window = extern struct { display: ?*anyopaque, window: c_ulong };
/// A host's Wayland surface: `wl_display*` and the `wl_surface*` to present on
/// — for a GTK4 host, the subsurface it created for the chart, not the toplevel.
pub const WaylandSurface = extern struct { display: ?*anyopaque, surface: ?*anyopaque };

const VkWin32SurfaceCreateInfoKHR = extern struct {
    sType: c_int,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    hinstance: ?*anyopaque,
    hwnd: ?*anyopaque,
};
const VkXlibSurfaceCreateInfoKHR = extern struct {
    sType: c_int,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    dpy: ?*anyopaque,
    window: c_ulong,
};
const VkWaylandSurfaceCreateInfoKHR = extern struct {
    sType: c_int,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    display: ?*anyopaque,
    surface: ?*anyopaque,
};
/// The instance extension each surface kind needs alongside VK_KHR_surface, and
/// the entry point that creates it. Null kind = no window (offscreen only).
fn surfaceExtension(kind: NativeKind) ?[*:0]const u8 {
    return switch (kind) {
        .android_window => "VK_KHR_android_surface",
        .win32_hwnd => "VK_KHR_win32_surface",
        .x11_window => "VK_KHR_xlib_surface",
        .wayland_surface => "VK_KHR_wayland_surface",
        else => null,
    };
}

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

/// One raster tile's texture, and one tile's draw in the underlay
/// (src/raster.zig). Opaque to the layer, which only holds them.
pub const RasterTex = Tex;
pub const RasterDraw = struct { tex: RasterTex, first: u32, count: u32 };

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

    /// The depth target. It exists for ONE job: the raster underlay writes
    /// depth in front of the chart's opaque area fills, so those fills fail the
    /// depth test exactly where a picture covers them and pass everywhere else.
    /// That is how a mariner keeps the chart's depth shading outside the
    /// coverage, and across every hole in a pyramid clipped to a coastline,
    /// while seeing the picture under it — per pixel, with no scene rebuild.
    ///
    /// Transient: it is written and tested within one render pass and never
    /// read afterwards, so a tiler keeps the samples in tile memory.
    depth_img: vk.VkImage = null,
    depth_mem: vk.VkDeviceMemory = null,
    depth_view: vk.VkImageView = null,
    depth_format: vk.VkFormat = vk.VK_FORMAT_D32_SFLOAT,

    set_layout_empty: vk.VkDescriptorSetLayout = null, // set 0
    set_layout_ubo: vk.VkDescriptorSetLayout = null, // sets 1 & 3 (dynamic UBO)
    set_layout_tex: vk.VkDescriptorSetLayout = null, // set 2
    /// The raster underlay: world-space textured quads drawn BEFORE the chart,
    /// one texture per tile, through the sprite pipeline (a raster tile IS a
    /// textured world-space quad with a tint). Replaced when the visible tile
    /// set changes, which is far less often than once per frame.
    raster_buf: Buffer = .{},
    raster_draws: []RasterDraw = &.{},
    raster_alloc: ?std.mem.Allocator = null,
    pipe_layout: vk.VkPipelineLayout = null,
    pipeline: vk.VkPipeline = null, // chart
    sprite_pipeline: vk.VkPipeline = null,
    raster_pipeline: vk.VkPipeline = null, // sprite program, depth-write on
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

    /// The ANativeWindow we present on — Android only; every other window
    /// system's handle is consumed by createSurface and never held.
    window: if (c_vk.android) ?*vk.ANativeWindow else ?*anyopaque = null,
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
        var ici = std.mem.zeroes(vk.VkInstanceCreateInfo);
        ici.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        ici.pApplicationInfo = &app;
        const platform_ext = if (opts.native_handle != null) surfaceExtension(opts.native_kind) else null;
        const want_surface = platform_ext != null;

        var inst_ext_buf: [4][*:0]const u8 = undefined;
        var inst_ext_n: u32 = 0;
        if (want_surface) {
            inst_ext_buf[inst_ext_n] = "VK_KHR_surface";
            inst_ext_n += 1;
            inst_ext_buf[inst_ext_n] = platform_ext.?;
            inst_ext_n += 1;
        }
        if (inst_ext_n > 0) {
            ici.enabledExtensionCount = inst_ext_n;
            ici.ppEnabledExtensionNames = &inst_ext_buf;
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
        // Prefer a discrete GPU for the offscreen (snapshot) path; the surface
        // path keeps devs[0] (the presentable GPU).
        var phys = devs[0];
        if (!want_surface) {
            for (devs[0..ndev]) |cand| {
                if (cand == null) continue;
                var cp: vk.VkPhysicalDeviceProperties = undefined;
                vk.vkGetPhysicalDeviceProperties(cand, &cp);
                if (cp.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                    phys = cand;
                    break;
                }
            }
        }
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
        var dev_ext_buf: [8][*:0]const u8 = undefined;
        var dev_ext_n: u32 = 0;
        dev_ext_buf[dev_ext_n] = "VK_KHR_maintenance1";
        dev_ext_n += 1;
        if (want_surface) {
            dev_ext_buf[dev_ext_n] = "VK_KHR_swapchain";
            dev_ext_n += 1;
        }
        var dci = std.mem.zeroes(vk.VkDeviceCreateInfo);
        dci.sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        dci.queueCreateInfoCount = 1;
        dci.pQueueCreateInfos = &qci;
        dci.enabledExtensionCount = dev_ext_n;
        dci.ppEnabledExtensionNames = &dev_ext_buf;
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
            try g.createSurface(instance, opts);
            // Pick the surface's colour format + ITS colorspace. It MUST be a
            // UNORM one: the palette hands the shader colours that are already
            // sRGB, and an _SRGB swapchain would encode them a second time on
            // write — every colour comes out pale (measured: S-52 NODATA
            // 147,174,187 presenting as 200,215,222). Prefer either 8-bit UNORM
            // ordering, then anything that isn't _SRGB, and only take an _SRGB
            // format if the surface offers nothing else — saying so, because
            // the chart will be visibly washed out.
            var nfmt: u32 = 0;
            _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(phys, g.surface, &nfmt, null);
            var fmts: [32]vk.VkSurfaceFormatKHR = undefined;
            if (nfmt > fmts.len) nfmt = fmts.len;
            _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(phys, g.surface, &nfmt, &fmts);
            if (nfmt > 0) {
                g.color_format = fmts[0].format;
                g.color_space = fmts[0].colorSpace;
                var picked = false;
                for (fmts[0..nfmt]) |f| {
                    if (f.format == vk.VK_FORMAT_R8G8B8A8_UNORM or
                        f.format == vk.VK_FORMAT_B8G8R8A8_UNORM)
                    {
                        g.color_format = f.format;
                        g.color_space = f.colorSpace;
                        picked = true;
                        break;
                    }
                }
                if (!picked) for (fmts[0..nfmt]) |f| {
                    if (!isSrgbFormat(f.format)) {
                        g.color_format = f.format;
                        g.color_space = f.colorSpace;
                        picked = true;
                        break;
                    }
                };
                if (!picked)
                    logErr("vk: surface offers only sRGB formats (fmt=%d) — colours will be over-bright", .{@as(c_int, @intCast(g.color_format))});
            }
        }

        // With no surface, nothing dictates a colour format; the default RGBA
        // UNORM is what the snapshot readback expects.

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
        if (g.surface != null)
            try g.createSwapchain()
        else
            try g.ensureOffscreenTargets();
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
        var atts: [3]vk.VkAttachmentDescription = undefined;
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
        // The depth attachment always comes last, so the colour indices above
        // are untouched. Never stored: it is written and tested inside the pass
        // and nothing reads it after.
        const depth_index = natt;
        atts[depth_index] = std.mem.zeroes(vk.VkAttachmentDescription);
        atts[depth_index].format = self.depth_format;
        atts[depth_index].samples = samples;
        atts[depth_index].loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR;
        atts[depth_index].storeOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        atts[depth_index].stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        atts[depth_index].stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        atts[depth_index].initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
        atts[depth_index].finalLayout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        var depth_ref = vk.VkAttachmentReference{
            .attachment = depth_index,
            .layout = vk.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };
        natt += 1;

        var sub = std.mem.zeroes(vk.VkSubpassDescription);
        sub.pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS;
        sub.colorAttachmentCount = 1;
        sub.pColorAttachments = &color_ref;
        if (self.msaa_used) sub.pResolveAttachments = &resolve_ref;
        sub.pDepthStencilAttachment = &depth_ref;
        var dep = std.mem.zeroes(vk.VkSubpassDependency);
        dep.srcSubpass = vk.VK_SUBPASS_EXTERNAL;
        dep.dstSubpass = 0;
        dep.srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
            vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dep.srcAccessMask = 0;
        dep.dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
            vk.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dep.dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
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
        // PRESENT_SRC needs VK_KHR_swapchain.
        if (self.surface != null)
            self.render_pass = try self.makePass(vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
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

    /// `depth_write` is for the raster underlay alone. Everything else TESTS
    /// depth and never writes it, which is what leaves the chart in painter's
    /// order among its own ranges while still losing the fills the underlay
    /// covered.
    fn buildPipeline(self: *Gpu, vspv: []const u32, fspv: []const u32, stride: u32, attrs: []const VAttr, depth_write: bool) !vk.VkPipeline {
        const vmod = try self.makeShaderModule(vspv);
        defer vk.vkDestroyShaderModule(self.device, vmod, null);
        const fmod = try self.makeShaderModule(fspv);
        defer vk.vkDestroyShaderModule(self.device, fmod, null);
        var stages: [2]vk.VkPipelineShaderStageCreateInfo = undefined;
        for (&stages, [_]vk.VkShaderModule{ vmod, fmod }, [_]c_uint{ vk.VK_SHADER_STAGE_VERTEX_BIT, vk.VK_SHADER_STAGE_FRAGMENT_BIT }) |*s, m, st| {
            s.* = std.mem.zeroes(vk.VkPipelineShaderStageCreateInfo);
            s.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            s.stage = @intCast(st);
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
        var ds = std.mem.zeroes(vk.VkPipelineDepthStencilStateCreateInfo);
        ds.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        ds.depthTestEnable = vk.VK_TRUE;
        ds.depthWriteEnable = if (depth_write) vk.VK_TRUE else vk.VK_FALSE;
        // LESS, matching the Metal backend: the engine gives a nearer range a
        // SMALLER depth, so a fill behind the underlay's plane fails.
        ds.depthCompareOp = vk.VK_COMPARE_OP_LESS;
        ds.depthBoundsTestEnable = vk.VK_FALSE;
        ds.stencilTestEnable = vk.VK_FALSE;
        ds.minDepthBounds = 0;
        ds.maxDepthBounds = 1;
        pci.pMultisampleState = &ms;
        pci.pDepthStencilState = &ds;
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
        self.pipeline = try self.buildPipeline(chart_vert_spv, chart_frag_spv, @sizeOf(cc.tile57_gpu_vertex), &tri_attrs, false);
        self.pattern_pipeline = try self.buildPipeline(pattern_vert_spv, pattern_frag_spv, @sizeOf(cc.tile57_gpu_vertex), &tri_attrs, false);
        self.sprite_pipeline = try self.buildPipeline(sprite_vert_spv, sprite_frag_spv, @sizeOf(cc.tile57_gpu_quad), &quad_attrs, false);
        self.sdf_pipeline = try self.buildPipeline(sprite_vert_spv, sdf_frag_spv, @sizeOf(cc.tile57_gpu_quad), &quad_attrs, false);
        // The same sprite program, writing depth: the underlay, and nothing
        // else, puts a plane in front of the chart's opaque fills.
        self.raster_pipeline = try self.buildPipeline(sprite_vert_spv, sprite_frag_spv, @sizeOf(cc.tile57_gpu_quad), &quad_attrs, true);
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
        if (extent.width == 0xFFFFFFFF) {
            // Wayland: the surface has no size of its own — the client names one.
            // The host's declared viewport is the authority here, exactly as in
            // extentStale(). Reusing self.width instead would pin the swapchain
            // to whatever it was first created at: every later resize would find
            // it stale, recreate it at the SAME extent, and find it stale again.
            extent = if (self.host_pt_w > 0 and self.host_pt_h > 0 and self.pixel_density > 0)
                .{
                    .width = @intFromFloat(@round(self.host_pt_w * self.pixel_density)),
                    .height = @intFromFloat(@round(self.host_pt_h * self.pixel_density)),
                }
            else
                .{ .width = self.width, .height = self.height };
            extent.width = std.math.clamp(extent.width, caps.minImageExtent.width, caps.maxImageExtent.width);
            extent.height = std.math.clamp(extent.height, caps.minImageExtent.height, caps.maxImageExtent.height);
        }
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
        try self.ensureDepth();
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
                [3]vk.VkImageView{ self.msaa_view, self.sc_views[i], self.depth_view }
            else
                [3]vk.VkImageView{ self.sc_views[i], self.depth_view, null };
            var fb = std.mem.zeroes(vk.VkFramebufferCreateInfo);
            fb.sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb.renderPass = self.render_pass;
            fb.attachmentCount = if (self.msaa_used) 3 else 2;
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
        self.releaseDepth();
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

    /// The depth target, at the colour target's size and sample count. Both
    /// passes share it: only one is ever recording.
    fn ensureDepth(self: *Gpu) !void {
        if (self.depth_img != null) return;
        const samples: vk.VkSampleCountFlagBits =
            if (self.msaa_used) vk.VK_SAMPLE_COUNT_4_BIT else vk.VK_SAMPLE_COUNT_1_BIT;
        try self.createDepthImage(self.width, self.height, samples);
    }

    fn releaseDepth(self: *Gpu) void {
        if (self.depth_view != null) vk.vkDestroyImageView(self.device, self.depth_view, null);
        if (self.depth_img != null) vk.vkDestroyImage(self.device, self.depth_img, null);
        if (self.depth_mem != null) vk.vkFreeMemory(self.device, self.depth_mem, null);
        self.depth_view = null;
        self.depth_img = null;
        self.depth_mem = null;
    }

    /// Like createImage, but a depth aspect and a depth usage. Kept separate
    /// rather than adding an aspect parameter to createImage, which every other
    /// caller would have to pass and none of them wants.
    fn createDepthImage(self: *Gpu, w: u32, h: u32, samples: vk.VkSampleCountFlagBits) !void {
        var ii = std.mem.zeroes(vk.VkImageCreateInfo);
        ii.sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ii.imageType = vk.VK_IMAGE_TYPE_2D;
        ii.format = self.depth_format;
        ii.extent = .{ .width = w, .height = h, .depth = 1 };
        ii.mipLevels = 1;
        ii.arrayLayers = 1;
        ii.samples = samples;
        ii.tiling = vk.VK_IMAGE_TILING_OPTIMAL;
        ii.usage = vk.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT |
            vk.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT;
        ii.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
        ii.initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
        try check(vk.vkCreateImage(self.device, &ii, null, &self.depth_img), "vkCreateImage depth");
        var req: vk.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(self.device, self.depth_img, &req);
        var ai = std.mem.zeroes(vk.VkMemoryAllocateInfo);
        ai.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        ai.allocationSize = req.size;
        // LAZILY_ALLOCATED first: a tiler backs a transient attachment with no
        // real memory at all. Not every driver offers it, so fall back.
        ai.memoryTypeIndex = self.memType(req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT) catch
            try self.memType(req.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try check(vk.vkAllocateMemory(self.device, &ai, null, &self.depth_mem), "vkAllocateMemory depth");
        try check(vk.vkBindImageMemory(self.device, self.depth_img, self.depth_mem, 0), "vkBindImageMemory depth");
        var vi = std.mem.zeroes(vk.VkImageViewCreateInfo);
        vi.sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vi.image = self.depth_img;
        vi.viewType = vk.VK_IMAGE_VIEW_TYPE_2D;
        vi.format = self.depth_format;
        vi.subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_DEPTH_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try check(vk.vkCreateImageView(self.device, &vi, null, &self.depth_view), "vkCreateImageView depth");
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
        try self.ensureDepth();
        if (self.off_img == null) {
            try self.createImage(self.width, self.height, self.color_format, vk.VK_SAMPLE_COUNT_1_BIT, vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &self.off_img, &self.off_mem, &self.off_view);
            const atts = if (self.msaa_used)
                [3]vk.VkImageView{ self.msaa_view, self.off_view, self.depth_view }
            else
                [3]vk.VkImageView{ self.off_view, self.depth_view, null };
            var fb = std.mem.zeroes(vk.VkFramebufferCreateInfo);
            fb.sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb.renderPass = self.off_pass;
            fb.attachmentCount = if (self.msaa_used) 3 else 2;
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

    /// Create the presentation surface from the host's native handle, and adopt
    /// whatever size that handle already has. Android reads it off the
    /// ANativeWindow; the desktop window systems do not carry one on the handle,
    /// so the size stays as the host declared it and the swapchain's
    /// currentExtent settles it at createSwapchain.
    fn createSurface(self: *Gpu, instance: vk.VkInstance, opts: Options) !void {
        const handle = opts.native_handle.?;
        switch (opts.native_kind) {
            .android_window => {
                if (!c_vk.android) return error.VulkanFailure;
                self.window = @ptrCast(handle);
                var sci = std.mem.zeroes(vk.VkAndroidSurfaceCreateInfoKHR);
                sci.sType = vk.VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR;
                sci.window = self.window;
                try check(vk.vkCreateAndroidSurfaceKHR(instance, &sci, null, &self.surface), "vkCreateAndroidSurfaceKHR");
                const ww = vk.ANativeWindow_getWidth(self.window);
                const wh = vk.ANativeWindow_getHeight(self.window);
                if (ww > 0 and wh > 0) {
                    self.width = @intCast(ww);
                    self.height = @intCast(wh);
                }
            },
            .win32_hwnd => {
                const w: *const Win32Window = @ptrCast(@alignCast(handle));
                const ci = VkWin32SurfaceCreateInfoKHR{
                    .sType = vk.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                    .hinstance = w.hinstance,
                    .hwnd = w.hwnd,
                };
                try self.createSurfaceVia(instance, "vkCreateWin32SurfaceKHR", VkWin32SurfaceCreateInfoKHR, &ci);
            },
            .x11_window => {
                const w: *const X11Window = @ptrCast(@alignCast(handle));
                const ci = VkXlibSurfaceCreateInfoKHR{
                    .sType = vk.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,
                    .dpy = w.display,
                    .window = w.window,
                };
                try self.createSurfaceVia(instance, "vkCreateXlibSurfaceKHR", VkXlibSurfaceCreateInfoKHR, &ci);
            },
            .wayland_surface => {
                const w: *const WaylandSurface = @ptrCast(@alignCast(handle));
                const ci = VkWaylandSurfaceCreateInfoKHR{
                    .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
                    .display = w.display,
                    .surface = w.surface,
                };
                try self.createSurfaceVia(instance, "vkCreateWaylandSurfaceKHR", VkWaylandSurfaceCreateInfoKHR, &ci);
            },
            else => return error.VulkanFailure,
        }
    }

    /// Load a vkCreate*SurfaceKHR by name and call it. Loading rather than
    /// linking is what lets this file know about four window systems while
    /// depending on none of their headers or libraries — a driver missing the
    /// extension returns null here and fails with a name, not a link error.
    fn createSurfaceVia(self: *Gpu, instance: vk.VkInstance, comptime name: [*:0]const u8, comptime CI: type, ci: *const CI) !void {
        const Fn = *const fn (vk.VkInstance, *const CI, ?*const vk.VkAllocationCallbacks, *vk.VkSurfaceKHR) callconv(.c) vk.VkResult;
        const raw = vk.vkGetInstanceProcAddr(instance, name) orelse {
            logErr("vk: %s unavailable (driver lacks the surface extension)", .{name});
            return error.VulkanFailure;
        };
        const create: Fn = @ptrCast(raw);
        try check(create(instance, ci, null, &self.surface), std.mem.span(name));
    }

    /// Resize the render surface. width/height are logical points from the host
    /// (Java) view; the pixel size follows the swapchain. Their ratio is the
    /// pixel density (the camera's HiDPI denominator).
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) !void {
        self.host_pt_w = @floatFromInt(width_pts);
        self.host_pt_h = @floatFromInt(height_pts);
        if (self.surface == null) {
            // No swapchain to adopt a size from, so the target IS the host's
            // declared viewport scaled by the density it declared. resize()
            // means POINTS on every path, offscreen included — the texture host
            // wants a pixel-exact frame and would otherwise have to know that
            // this one path counted differently.
            const d = if (self.pixel_density > 0) self.pixel_density else 1.0;
            const w: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(width_pts)) * d));
            const h: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(height_pts)) * d));
            if (w != self.width or h != self.height) {
                _ = vk.vkDeviceWaitIdle(self.device);
                self.releaseOffscreen();
                self.releaseMsaa();
                self.releaseDepth();
                self.width = w;
                self.height = h;
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

    // ---- the raster underlay ------------------------------------------------

    pub fn newRasterTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !RasterTex {
        return self.makeTexture(rgba, w, h);
    }

    pub fn freeRasterTexture(self: *Gpu, t: RasterTex) void {
        // The frame in flight may still sample it — the same wait freeSceneValue
        // takes before dropping a scene's buffers.
        _ = vk.vkWaitForFences(self.device, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64));
        var v = t;
        self.destroyTexture(&v);
    }

    /// Adopt this frame's raster quads + per-tile draws.
    pub fn setRasterFrame(self: *Gpu, quads: []const cc.tile57_gpu_quad, draws: []const RasterDraw) !void {
        self.clearRasterFrame();
        if (quads.len == 0 or draws.len == 0) return;
        const bytes = std.mem.sliceAsBytes(quads);
        self.raster_buf = try self.createBuffer(bytes.len, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, true);
        @memcpy(self.raster_buf.mapped.?[0..bytes.len], bytes);
        const a = self.raster_alloc orelse std.heap.c_allocator;
        self.raster_alloc = a;
        self.raster_draws = try a.dupe(RasterDraw, draws);
    }

    /// The depth that puts the underlay immediately IN FRONT OF the chart's
    /// opaque area fills, so those fills fail the depth test exactly where a
    /// tile covers them and pass everywhere else. Per pixel: the chart keeps
    /// its depth shading across a coverage edge and around every hole in a
    /// pyramid clipped to a coastline.
    ///
    /// The engine gives range i of N the depth (N-i)/(N+1), so a later range is
    /// nearer. This is that formula evaluated one step past the last opaque
    /// area range. 0.999 with no scene: behind everything, which is right when
    /// there is no chart to sit in front of.
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
        const d = @as(f64, @floatFromInt(nr - last - 1)) / @as(f64, @floatFromInt(nr + 1));
        return @floatCast(d);
    }

    /// The depth that puts the underlay in front of the WHOLE chart, so the
    /// chart falls out exactly where a picture covers and stays everywhere
    /// else. Half the closest range's depth, so nothing the engine emits can be
    /// nearer.
    pub fn rasterDepthFront(self: *const Gpu) f32 {
        const s = self.scene orelse return 0.5;
        const nr = s.ranges.len;
        if (nr == 0) return 0.5;
        return @floatCast(0.5 / @as(f64, @floatFromInt(nr + 1)));
    }

    pub fn clearRasterFrame(self: *Gpu) void {
        if (self.raster_buf.buf != null) {
            _ = vk.vkWaitForFences(self.device, 1, &self.fence, vk.VK_TRUE, std.math.maxInt(u64));
            self.destroyBuffer(&self.raster_buf);
        }
        if (self.raster_draws.len > 0) {
            if (self.raster_alloc) |a| a.free(self.raster_draws);
            self.raster_draws = &.{};
        }
    }

    // ---- chart overlays (not on this backend) -------------------------------

    /// Overlay drawing is Metal-only in the plugin prototype (PROTOTYPE.md's
    /// scope fence). The hook exists so the core's per-frame call site is
    /// backend-independent: take the frame, say so once, draw nothing.
    var overlay_told = false;
    pub fn setOverlay(self: *Gpu, fr: ov.Frame, u: Uniforms) !void {
        _ = self;
        _ = fr;
        _ = u;
        if (!overlay_told) {
            overlay_told = true;
            std.debug.print("overlay: not implemented on this backend\n", .{});
        }
    }

    pub fn clearOverlay(self: *Gpu) void {
        _ = self;
    }

    /// Draw the underlay: sprite pipeline, one draw per tile (each carries its
    /// own texture). Runs BEFORE the chart, so the chart's own fills paint over
    /// it — which is correct, and is what chart-over-picture undoes.
    fn recordRaster(self: *Gpu, cmd: vk.VkCommandBuffer, u: Uniforms) void {
        if (self.raster_draws.len == 0 or self.raster_buf.buf == null) return;
        const pipe = self.raster_pipeline orelse return;
        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
        const zero: u64 = 0;
        vk.vkCmdBindVertexBuffers(cmd, 0, 1, &self.raster_buf.buf, &zero);
        var uu = u;
        // The underlay is BASE and never scale-gated: it is the only thing on
        // screen where the chart has nothing, so a category filter must not take
        // it away.
        uu.cat_mask = 0xFFFFFFFF;
        const voff = self.pushUniform(&uu) orelse return;
        vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipe_layout, 1, 1, &self.vtx_uni_set, 1, &voff);
        for (self.raster_draws) |d| {
            var ds = d.tex.dset;
            if (ds == null) continue;
            vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipe_layout, 2, 1, &ds, 0, null);
            vk.vkCmdDraw(cmd, d.count, 1, d.first, 0);
        }
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

    fn atlasTexture(self: *const Gpu, atlas: u8) ?Tex {
        return switch (atlas) {
            cc.TILE57_GPU_ATLAS_GLYPH => self.glyph_tex,
            cc.TILE57_GPU_ATLAS_GLYPH_BOLD => self.glyph_bold_tex,
            cc.TILE57_GPU_ATLAS_GLYPH_ITALIC => self.glyph_italic_tex,
            else => self.sprite_tex,
        };
    }

    /// Ask the engine which draws this scene needs. Returns an empty slice if
    /// the batch somehow exceeds the buffer, since a truncated batch is missing
    /// chart rather than merely slow.
    fn batchScene(self: *const Gpu, s: *const Scene, text_on: bool, sound_on: bool) []const cc.tile57_gpu_draw {
        if (s.ranges.len == 0 or s.draws.len == 0) return &.{};
        const opts = cc.tile57_gpu_batch_opts{
            .text_on = text_on,
            .sound_on = sound_on,
            .exclude_opaque_tris = false,
            .atlas_have = self.atlasHave(),
            .halo = .{ self.clear.r, self.clear.g, self.clear.b, 1 },
        };
        const n = cc.tile57_gpu_batch(s.ranges.ptr, s.ranges.len, &opts, s.draws.ptr, s.draws.len);
        return if (n > s.draws.len) &.{} else s.draws[0..n];
    }

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
        if (s.range_count > 0) {
            out.ranges = try alloc.dupe(cc.tile57_gpu_range, s.ranges[0..s.range_count]);
            out.draws = try alloc.alloc(cc.tile57_gpu_draw, s.range_count);
        }
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
        // The depth clear is FARTHEST (1.0), so every range passes until the
        // underlay puts its plane in front of the fills. It is the last
        // attachment, so it sits after the colour ones however many there are.
        var dclear = std.mem.zeroes(vk.VkClearValue);
        dclear.depthStencil = .{ .depth = 1.0, .stencil = 0 };
        const clears = if (self.msaa_used)
            [3]vk.VkClearValue{ clear, clear, dclear }
        else
            [3]vk.VkClearValue{ clear, dclear, dclear };
        var rbi = std.mem.zeroes(vk.VkRenderPassBeginInfo);
        rbi.sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        rbi.renderPass = pass;
        rbi.framebuffer = fb;
        rbi.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } };
        rbi.clearValueCount = if (self.msaa_used) 3 else 2;
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

        // Before the chart, and before the early return below: where the chart
        // has no data is exactly where the mariner most needs the picture, so a
        // missing scene must not take the underlay away.
        self.recordRaster(cmd, u);

        const s = if (self.scene) |*sc| sc else return; // no scene: clear only
        var bound_pipe: vk.VkPipeline = null;
        var bound_tex: vk.VkDescriptorSet = null;
        const zero: u64 = 0;

        // The engine decides what each range draws and folds contiguous ranges
        // sharing a spec into one call (tile57_gpu_batch). That matters here: a
        // coastal view carries ~5,000 ranges, i.e. ~10,000 command calls a frame
        // unmerged, and recordDraws was 21% of native time on device. This loop
        // binds and draws what it is handed, and nothing else.
        for (self.batchScene(s, text_on, sound_on)) |d| {
            const tri = d.prim == cc.TILE57_GPU_TRIANGLES;
            var uu = u;
            uu.cat_mask |= d.cat_mask_or;
            var pipe: vk.VkPipeline = null;
            var tex_set: vk.VkDescriptorSet = null;
            const halo = d.pipeline == cc.TILE57_GPU_PIPE_SDF;
            if (tri) {
                if (s.vbuf.buf == null) continue;
                pipe = self.pipeline;
                if (d.pipeline == cc.TILE57_GPU_PIPE_PATTERN) {
                    // Whether a cell rasterized is ours to know; without one the
                    // fill under it already drew, so this draws nothing.
                    if (d.pattern >= s.patterns.len) continue;
                    const pt = s.patterns[d.pattern];
                    const t = pt.tex orelse continue;
                    // Scale the cell with the zoom so it tracks the geometry (which
                    // the MVP scales) rather than swimming during a zoom animation.
                    const cs = self.pixel_density * self.pattern_scale;
                    uu.cell_px = .{ pt.w * cs, pt.h * cs };
                    pipe = self.pattern_pipeline;
                    tex_set = t.dset;
                }
            } else {
                if (s.qbuf.buf == null) continue;
                const tex = self.atlasTexture(d.atlas) orelse continue;
                pipe = if (halo) self.sdf_pipeline else self.sprite_pipeline;
                if (pipe == null) continue;
                tex_set = tex.dset;
            }
            if (pipe != bound_pipe) {
                vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
                bound_pipe = pipe;
                const vb = if (tri) &s.vbuf.buf else &s.qbuf.buf;
                vk.vkCmdBindVertexBuffers(cmd, 0, 1, vb, &zero);
            }
            if (tex_set != null and tex_set != bound_tex) {
                var ds = tex_set;
                vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipe_layout, 2, 1, &ds, 0, null);
                bound_tex = tex_set;
            }
            const voff = self.pushUniform(&uu) orelse continue;
            vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipe_layout, 1, 1, &self.vtx_uni_set, 1, &voff);
            if (halo) {
                // The SDF halo renders in the palette background colour (sdf.frag,
                // set 3): a hardcoded white halo glared at night.
                uu.color = d.color;
                const foff = self.pushUniform(&uu) orelse continue;
                vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipe_layout, 3, 1, &self.frag_uni_set, 1, &foff);
            }
            vk.vkCmdDraw(cmd, d.count, 1, d.first, 0);
        }
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
        self.clearRasterFrame();
        self.freeScene();
        if (self.sprite_tex) |*t| self.destroyTexture(t);
        if (self.glyph_tex) |*t| self.destroyTexture(t);
        if (self.glyph_bold_tex) |*t| self.destroyTexture(t);
        if (self.glyph_italic_tex) |*t| self.destroyTexture(t);
        self.releaseOffscreen();
        self.destroySwapchainViews();
        if (self.swapchain != null) vk.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.releaseMsaa();
        self.releaseDepth();
        self.destroyBuffer(&self.ring);
        if (self.acquire_sem != null) vk.vkDestroySemaphore(self.device, self.acquire_sem, null);
        if (self.render_sem != null) vk.vkDestroySemaphore(self.device, self.render_sem, null);
        if (self.fence != null) vk.vkDestroyFence(self.device, self.fence, null);
        if (self.up_fence != null) vk.vkDestroyFence(self.device, self.up_fence, null);
        if (self.cmd_pool != null) vk.vkDestroyCommandPool(self.device, self.cmd_pool, null);
        if (self.pipeline != null) vk.vkDestroyPipeline(self.device, self.pipeline, null);
        if (self.sprite_pipeline != null) vk.vkDestroyPipeline(self.device, self.sprite_pipeline, null);
        if (self.raster_pipeline != null) vk.vkDestroyPipeline(self.device, self.raster_pipeline, null);
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
