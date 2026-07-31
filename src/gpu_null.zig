//! The no-GPU transport: the backend for a host that rasterizes the chart
//! itself. Selected by `-Dbackend=none` (see src/gpu.zig).
//!
//! The other three backends hand tile57's draw-ready GPU scene to a device.
//! Some hosts have no device to hand it to: the reMarkable's e-ink panel has no
//! Vulkan driver, and a printer or a PDF export has no device at all. Those
//! hosts draw the chart through `lookout_render_view_canvas`, which asks the
//! engine for the view as pixel-space draw calls and lets the host's own
//! rasterizer paint them. That path needs the chart set, the composition, the
//! camera and the mariner state — everything in root.zig — and none of the
//! scene upload below it.
//!
//! So this file is the whole `Gpu` API with nothing behind it: init makes no
//! device, the scene calls hold no memory, and the render calls report that
//! there was no frame. A build that selects it links no graphics library, which
//! is what makes the core cross-compile for a device that has none. Every
//! render entry point stays callable and simply draws nothing, so a host that
//! mixes the two paths gets a false or an error rather than a crash.
const std = @import("std");
const builtin = @import("builtin");
const cc = @import("c.zig").c; // tile57 (the scene types root stages through)

/// Vertex/fragment uniform block. The engine owns the layout; a host-side
/// rasterizer never sees it, but root builds one per frame, so the type has to
/// exist. Same source as every other backend — see gpu_sdl.zig.
pub const Uniforms = cc.tile57_gpu_uniforms;

/// RGBA colour 0..1.
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// Monotonic milliseconds / microseconds. SDL's timer is what that backend
/// uses; with no graphics library linked, this is the same clock underneath —
/// the POSIX one, as in gpu_vk.zig. The id differs by OS, and this backend is
/// the one hosts build on a Mac to develop against, so name both.
const CLOCK_MONOTONIC: c_int = if (builtin.os.tag.isDarwin()) 6 else 1;
const Timespec = extern struct { sec: c_long, nsec: c_long };
extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
pub fn ticksUs() i64 {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
}
pub fn ticksMs() i64 {
    return @divTrunc(ticksUs(), 1000);
}

/// How to interpret Options.native_handle. Declared in full so root and capi
/// share one ABI across backends; this one accepts only `none`, since a host
/// with a native surface has a device to present to and should select the
/// backend that drives it.
pub const NativeKind = enum(c_int) {
    none = 0,
    metal_layer = 1,
    cocoa_window = 2,
    cocoa_view = 3,
    win32_hwnd = 4,
    x11_window = 5,
    uikit_windowscene = 6,
    android_window = 7,
};

pub const Options = struct {
    width: u32,
    height: u32,
    want_window: bool,
    want_msaa: bool = true,
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,
};

pub const Gpu = struct {
    width: u32,
    height: u32,
    size_changed_ms: i64 = -100000,
    pixel_density: f32 = 1.0,
    /// Non-zero once the host DECLARED its scale factor (setPixelDensity).
    host_density: f32 = 0,
    pattern_scale: f32 = 1,
    clear: Color = .{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 },

    /// A staged scene with nothing staged. root moves these between its build
    /// worker and the draw, so the type has to exist and has to be safe to free
    /// twice; holding no resource makes both trivially true. `ranges` is what
    /// root reads to tell a scene that built empty from one that built chart —
    /// always empty here, which is the truth: this backend uploads nothing.
    pub const Scene = struct {
        ranges: []cc.tile57_gpu_range = &.{},
        alloc: std.mem.Allocator,
    };

    pub fn init(opts: Options) !Gpu {
        // A window here would have nothing to present into. The host owns its
        // own window and its own rasterizer on this path; refuse rather than
        // hand back a handle that silently never draws.
        if (opts.want_window or opts.native_kind != .none) return error.NoGpuBackend;
        return .{ .width = opts.width, .height = opts.height };
    }

    pub fn setPixelDensity(self: *Gpu, d: f32) void {
        if (d > 0.2 and d < 8.0) {
            self.host_density = d;
            self.pixel_density = d;
        }
    }

    /// Record the surface size. width/height are logical points; with no
    /// swapchain to resize, the pixel size is just the host's declared density
    /// applied to them.
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) !void {
        const d = if (self.host_density > 0) self.host_density else 1.0;
        const w: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(width_pts)) * d));
        const h: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(height_pts)) * d));
        if (w != self.width or h != self.height) self.size_changed_ms = ticksMs();
        self.width = @max(w, 1);
        self.height = @max(h, 1);
    }

    // ---- atlases: nothing samples them here ---------------------------------
    pub fn uploadSpriteAtlas(_: *Gpu, _: []const u8, _: u32, _: u32) !void {}
    pub fn uploadGlyphAtlas(_: *Gpu, _: []const u8, _: u32, _: u32) !void {}
    pub fn uploadGlyphAtlasBold(_: *Gpu, _: []const u8, _: u32, _: u32) !void {}
    pub fn uploadGlyphAtlasItalic(_: *Gpu, _: []const u8, _: u32, _: u32) !void {}

    // ---- scenes: staged and dropped -----------------------------------------
    pub fn makeScene(_: *Gpu, alloc: std.mem.Allocator, _: *const cc.tile57_gpu_scene) !Scene {
        return .{ .alloc = alloc };
    }
    pub fn adoptScene(_: *Gpu, _: Scene) void {}
    pub fn uploadGpuScene(_: *Gpu, _: std.mem.Allocator, _: *const cc.tile57_gpu_scene) !void {}
    pub fn freeStagedScene(_: *Gpu, _: *Scene) void {}
    pub fn freeScene(_: *Gpu) void {}

    // ---- frames: there is no device to draw one -----------------------------
    /// False, the same answer a windowless device gives: no frame was presented.
    /// A host on this backend draws through lookout_render_view_canvas instead.
    pub fn renderWindow(_: *Gpu, _: Uniforms, _: bool, _: bool) !bool {
        return false;
    }
    pub fn renderOffscreen(_: *Gpu, _: std.mem.Allocator, _: Uniforms, _: bool, _: bool) ![]u8 {
        return error.NoGpuBackend;
    }
    pub fn savePng(_: *Gpu, _: std.mem.Allocator, _: []const u8, _: Uniforms, _: bool, _: bool) !void {
        return error.NoGpuBackend;
    }

    pub fn deinit(_: *Gpu) void {}
};
