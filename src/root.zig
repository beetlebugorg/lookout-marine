//! lookout-core: a chart-rendering widget. Open a baked tile57 chart, drive the
//! view (pan/zoom/rotate), set the full S-52 mariner state, and render — to a
//! window or offscreen. Build (tessellation) is lazy and automatic: you set
//! state and render; the widget re-tessellates only when it must.
//!
//! The API is deliberately small and orthogonal so a chartplotter (boat marker,
//! routes, tap-to-identify) can be built on top:
//!   open/close · fitChart/setView/view/resize · pan/zoom/screen<->geo ·
//!   getMariner/setMariner (ALL S-52 settings) · render/snapshot · pick.
const std = @import("std");
const builtin = @import("builtin");
const cc = @import("c.zig").c;
const gpu = @import("gpu.zig");
const camera = @import("camera.zig");
const atlas = @import("atlas.zig");
const png = @import("png.zig");

pub const Mariner = cc.tile57_mariner;
pub const Scheme = cc.tile57_scheme;

// The async build's WORKER runs tessellation (runJob — pure engine, no GPU) on
// every backend: a rebuild takes ~1s on a phone and must never sit inside
// render(), where it would hold the api lock against the gesture thread.
// STAGING (GPU buffer creation + upload submit) is backend-dependent: Metal
// tolerates it on the worker thread; the Vulkan-flavoured backends do not —
// queue submission is externally synchronized, a worker-thread submit races
// the render thread's and the rebuilt scene swaps in blank. There the worker
// hands the C scene back and pollBuild stages it on the render thread, ordered
// before the draw that reads it.
const async_stage = !(@import("build_options").gpu_sdl or @import("build_options").gpu_vk);

const MAX_SCHEMES = 3; // day / dusk / night

/// A camera pose. rotation_deg is course-up rotation (0 = north-up).
pub const View = struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 = 0 };

/// Base mariner for a build: the user's state, but with the live-gated axes
/// forced permissive so EVERY feature reaches the surface tagged, then gated
/// per-frame in the shader. Geometry-affecting fields (contours,
/// units, dates, groups…) pass through unchanged.
fn buildMarinerFrom(base: cc.tile57_mariner, sch: cc.tile57_scheme) cc.tile57_mariner {
    var m = base;
    m.scheme = sch;
    m.display_base = true;
    m.display_standard = true;
    m.display_other = true;
    m.text_names = true;
    m.show_light_descriptions = true;
    m.text_other = true;
    m.soundings = 1;
    m.size_scale = 1.0; // runtime size lives in the shader uniform
    return m;
}

/// A cache root the host handed us. Android exports neither HOME nor
/// XDG_CACHE_HOME, so there this is the ONLY way to a writable cache — the path
/// exists solely as Context.getCacheDir(). Owned here; set before opening.
var cache_root: ?[]u8 = null;

/// Adopt `path` as the cache root, replacing any previous one.
pub fn setCacheRoot(path: []const u8) void {
    const a = std.heap.c_allocator;
    const dup = a.dupe(u8, path) catch return;
    if (cache_root) |old| a.free(old);
    cache_root = dup;
}

/// `<root>/lookout/v<version>`: the host's root if it gave one, else
/// XDG_CACHE_HOME, else the platform default under HOME.
fn cacheDirPath(alloc: std.mem.Allocator, ver: []const u8) ?[]u8 {
    if (cache_root) |root| return std.fmt.allocPrint(alloc, "{s}/lookout/v{s}", .{ root, ver }) catch null;
    if (std.c.getenv("XDG_CACHE_HOME")) |x| {
        const s = std.mem.span(x);
        if (s.len > 0) return std.fmt.allocPrint(alloc, "{s}/lookout/v{s}", .{ s, ver }) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    if (home.len == 0) return null;
    return switch (builtin.os.tag) {
        .macos, .ios => std.fmt.allocPrint(alloc, "{s}/Library/Caches/lookout/v{s}", .{ home, ver }) catch null,
        else => std.fmt.allocPrint(alloc, "{s}/.cache/lookout/v{s}", .{ home, ver }) catch null,
    };
}

/// The app's atlas cache directory — purgeable by the OS (it's a rebuildable
/// cache). Created here; owned by `alloc`. Null if no root can be resolved.
/// Keyed by tile57 version so a catalogue/engine change invalidates old atlases.
pub fn atlasCacheDir(alloc: std.mem.Allocator) ?[]u8 {
    const ver = std.mem.span(cc.tile57_version());
    const dir = cacheDirPath(alloc, ver) orelse return null;
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return dir;
}

/// True when the atlas cache is already populated (the density-independent glyph
/// atlas is present) — i.e. the next open will NOT need the one-time bake. The
/// host queries this to show a "preparing symbols" message only on first run.
pub fn atlasCacheReady(alloc: std.mem.Allocator) bool {
    const dir = atlasCacheDir(alloc) orelse return false;
    defer alloc.free(dir);
    const path = std.fmt.allocPrint(alloc, "{s}/glyph.png", .{dir}) catch return false;
    defer alloc.free(path);
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn hexColor(s: []const u8) ?gpu.Color {
    var t = s;
    if (t.len > 0 and t[0] == '#') t = t[1..];
    if (t.len < 6) return null;
    const r = std.fmt.parseInt(u8, t[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, t[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, t[4..6], 16) catch return null;
    return .{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = 1.0,
    };
}

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub const OpenOptions = struct {
    width: u32 = 1280,
    height: u32 = 960,
    want_window: bool = false,
    want_msaa: bool = true,
    /// palettes captured at build so scheme changes are instant. All three by
    /// default (day/dusk/night); index order defines the scheme<->buffer map.
    schemes: []const Scheme = &.{ cc.TILE57_SCHEME_DAY, cc.TILE57_SCHEME_DUSK, cc.TILE57_SCHEME_NIGHT },
    /// here for next time. Point this somewhere per chart-library.
    /// EMBED into a host view: hand over its CAMetalLayer (kind .metal_layer)
    /// and lookout renders/presents straight into it — the host keeps its own
    /// toolkit and event loop. Then just call render() each frame and feed
    /// input via pan/zoom/setView/resize.
    native_handle: ?*anyopaque = null,
    native_kind: gpu.NativeKind = .none,
};

pub const NativeKind = gpu.NativeKind;

// A kernel-blocking lock for api_mu / engine_mu (NOT a spin). On Darwin that's
// os_unfair_lock — Zig 0.16's std.Thread.Mutex spins there, and this layer takes
// no Io. Everywhere else (Android/Linux/Windows) std.Thread.Mutex is the futex
// path, which is also kernel-blocking. os_unfair_lock is Apple-only, so it must
// not reach a non-Apple link.
const Lock = if (@import("builtin").os.tag.isDarwin())
    struct {
        const Handle = extern struct { v: u32 = 0 };
        extern "c" fn os_unfair_lock_lock(l: *Handle) void;
        extern "c" fn os_unfair_lock_unlock(l: *Handle) void;
        h: Handle = .{},
        fn lock(self: *@This()) void {
            os_unfair_lock_lock(&self.h);
        }
        fn unlock(self: *@This()) void {
            os_unfair_lock_unlock(&self.h);
        }
    }
else if (builtin.os.tag == .windows)
    struct {
        // No pthread in the MSVC CRT. SRWLOCK is the direct analog: a single
        // pointer that zero-inits to SRWLOCK_INIT (no init call, like the zeroed
        // pthread_mutex_t below), kernel-blocking, non-recursive.
        // WINAPI convention (stdcall on x86, C on x64/aarch64) — required for a
        // correct x86 build.
        extern "kernel32" fn AcquireSRWLockExclusive(srw: *?*anyopaque) callconv(.winapi) void;
        extern "kernel32" fn ReleaseSRWLockExclusive(srw: *?*anyopaque) callconv(.winapi) void;
        m: ?*anyopaque = null, // SRWLOCK; null == SRWLOCK_INIT
        fn lock(self: *@This()) void {
            AcquireSRWLockExclusive(&self.m);
        }
        fn unlock(self: *@This()) void {
            ReleaseSRWLockExclusive(&self.m);
        }
    }
else
    struct {
        // Zig 0.16 has no std.Thread.Mutex (it moved behind an Io this layer
        // doesn't take), so use pthread directly. A zeroed pthread_mutex_t is
        // PTHREAD_MUTEX_INITIALIZER on Linux/bionic — kernel-blocking, no init call.
        extern "c" fn pthread_mutex_lock(m: *std.c.pthread_mutex_t) c_int;
        extern "c" fn pthread_mutex_unlock(m: *std.c.pthread_mutex_t) c_int;
        m: std.c.pthread_mutex_t = std.mem.zeroes(std.c.pthread_mutex_t),
        fn lock(self: *@This()) void {
            _ = pthread_mutex_lock(&self.m);
        }
        fn unlock(self: *@This()) void {
            _ = pthread_mutex_unlock(&self.m);
        }
    };

pub const Lookout = struct {
    alloc: std.mem.Allocator,
    charts: std.ArrayList(*cc.tile57_chart) = .empty, // 1 (single) or many (composed)
    compose: ?*cc.tile57_compose = null, // set when >1 chart (ENC_ROOT / library)
    g: gpu.Gpu,
    built: bool = false, // GPU holds a current scene

    // The ownership-partition build (compose_open over the whole library) is slow
    // — run it on a worker thread and show a loader so the window isn't frozen.
    loading: bool = false,
    compose_thread: ?std.Thread = null,
    compose_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    compose_result: ?*cc.tile57_compose = null,

    // Coverage of the currently-built (overscanned) scene: rebuild only when the
    // view pans/zooms out of it, so panning within the margin never re-portrays.
    cov_origin: camera.Vec2 = .{ .x = 0, .y = 0 },
    cov_zoom: f64 = 0,
    cov_hw: f64 = 0, // half-width / half-height of coverage, world units
    cov_hh: f64 = 0,
    view_dirty: bool = true, // camera/state changed since the last render (on-demand)
    last_change_ms: i64 = 0, // when the view last moved

    // Async rebuild: the engine call (portray + assemble) runs on a worker so a
    // pan/zoom gesture never blocks; the current scene keeps drawing (the MVP just
    // scales it — low-res but live) until the new one is uploaded, which lands
    // mid-gesture. A PREDICTIVE prefetch warms the engine's per-tile cache for the
    // zoom level we're heading toward, so crossing that boundary is a cache hit,
    // not a fresh portray.
    build_thread: ?std.Thread = null,
    // API-entry lock (see capi.locked): serializes the C ABI between the
    // host's input thread and its render thread. Distinct from engine_mu,
    // which serializes ENGINE access between API calls and the build worker;
    // api_mu is always the OUTER lock of the two.
    api_mu: Lock = .{},
    // Serializes ENGINE entry from other threads against the build worker: the
    // engine mutates shared state on any access (reader directory caches decode
    // lazily, the geometry cache inserts/evicts), so a main-thread pick during
    // an in-flight worker build is a data race without this. Held for the whole
    // engine call; a tap during a slow build waits rather than corrupting.
    // os_unfair_lock (kernel-blocking, not a spin) because Zig 0.16 puts
    // std's mutex behind an Io, which this layer does not take.
    engine_mu: Lock = .{},
    build_active: bool = false, // a worker is in flight (main-thread only)
    build_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    build_job: BuildJob = .{},
    pending_ok: bool = false,
    // viewMaxZoom cache (see there).
    zl_valid: bool = false,
    zl_center: camera.Vec2 = .{ .x = 0, .y = 0 },
    zl_zoom: f64 = 0,
    zl_max: f64 = 22,
    // GPU scene STAGED by the worker (buffers already created off-thread; the
    // render thread only swaps pointers in applyStaged). Null when the build
    // failed, was a prefetch, or staging itself failed (retried via dirty).
    pending_scene: ?gpu.Gpu.Scene = null,
    // !async_stage backends: the worker's raw C scene, staged by pollBuild on
    // the render thread instead (Vulkan queue submits are render-thread-only).
    pending_cs: cc.tile57_gpu_scene = std.mem.zeroes(cc.tile57_gpu_scene),
    pending_cs_valid: bool = false,
    last_zoom: f64 = -1, // for zoom-velocity prediction
    last_zoom_ms: i64 = 0,
    /// Wall-clock of the last engine build (worker-written, main-read): the
    /// prefetch gate — on hardware where a build takes seconds, the single
    /// worker is too precious to spend on a speculative warm.
    last_build_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// Set by the host on an OS memory warning; tickBuild trims the engine's
    /// reclaimable caches at the next safe point (no build in flight).
    trim_requested: bool = false,
    /// When the last build FAILED (0 = never): tickBuild backs off rather than
    /// respawning the identical failing build every frame — a hot loop that
    /// keeps the exact pressure that made it fail.
    last_fail_ms: i64 = 0,
    prefetched_level: i32 = -1, // the round-zoom level last prefetched (fire once per approach)
    cam: camera.Camera,
    /// The host's declared logical viewport, and authoritative over anything
    /// derived from the surface: across a rotation a swapchain keeps reporting
    /// the OLD extent, which inverts the aspect and skews every rotated frame.
    host_pt_w: f32 = 0,
    host_pt_h: f32 = 0,
    schemes: [MAX_SCHEMES]Scheme = undefined,
    n_schemes: usize = 0,

    /// The authoritative S-52 display state. Edit via get/setMariner.
    mariner: Mariner = undefined,
    dirty: bool = true, // scene needs a (re)build before the next render
    sprite_atlas: ?atlas.SpriteAtlas = null, // shared S-52 symbol atlas
    /// The app's atlas cache dir ($HOME/Library/Caches/lookout/...), or null.
    assets_root: ?[]u8 = null,
    /// The density the sprite atlas was actually baked at. Usually the display
    /// pixel density, but reduced when the full-density atlas would exceed the
    /// device's max texture dimension (loadSpriteAtlas). Scene builds must pass
    /// THIS ratio so sprite UVs index the atlas we uploaded.
    atlas_scale: f32 = 1.0,
    atlases_ready: bool = false, // see ensureAtlases: loaded at first use, not at open
    glyph_atlas: ?atlas.GlyphAtlas = null, // shared SDF label-font atlas
    engine_max_zoom: f64 = 24, // deepest zoom the chart/compositor serves; beyond
    //                            it we overscale (build stays here, camera scales up)
    // Deepest zoom a build actually produced geometry for. A chart's declared
    // max_zoom can overreport: a tile exists there in metadata but carries no
    // features under the view, so building at that level returns OK-but-empty.
    // Adopting that blanks a good scene. Capping engine_max_zoom to the last
    // level that DID draw keeps buildTargetZoom on servable data, so a zoom-in
    // overscales the good scene (the intended behaviour) instead of going blank.
    // Reset on a new view (setView/fitChart) so a different area re-probes.
    served_max_zoom: f64 = 1e9,

    // derived live (uniform-only) state
    cat_mask: u32 = 0b111,
    text_on: bool = true, // draw text ranges (labels)
    sound_on: bool = true, // draw sounding ranges
    render_size_scale: f32 = 1.0,
    nodata: [MAX_SCHEMES]gpu.Color = [_]gpu.Color{.{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 }} ** MAX_SCHEMES,

    // ---- lifecycle ----------------------------------------------------------
    /// Open ONE baked chart (.pmtiles).
    pub fn open(alloc: std.mem.Allocator, chart_path: [:0]const u8, opts: OpenOptions) !*Lookout {
        return openCharts(alloc, &.{chart_path}, opts);
    }

    /// Open MANY baked charts and compose them (a chart library). Bad charts are
    /// skipped; composing kicks in automatically when more than one loads.
    pub fn openCharts(alloc: std.mem.Allocator, paths: []const [:0]const u8, opts: OpenOptions) !*Lookout {
        const self = try create(alloc, opts);
        errdefer self.close();
        const t0 = gpu.ticksMs();
        self.openChartPaths(paths);
        const t1 = gpu.ticksMs();
        try self.finishOpen();
        const t2 = gpu.ticksMs();
        std.debug.print("open: {d} charts opened in {d} ms, compose+partition in {d} ms\n", .{ self.charts.items.len, t1 - t0, t2 - t1 });
        return self;
    }

    fn create(alloc: std.mem.Allocator, opts: OpenOptions) !*Lookout {
        const dbg = std.c.getenv("LOOKOUT_TIMING") != null;
        var t = gpu.ticksMs();
        // ABI gate: a header/library skew in the GPU structs renders GARBAGE
        // (a sheared vertex stream — wrong colours everywhere, junk triangles,
        // single-digit fps), not an error. Refuse loudly instead. A tile57 too
        // old to export this fails at LINK time, which is better still.
        const want: u32 = @as(u32, @sizeOf(cc.tile57_gpu_vertex)) |
            (@as(u32, @sizeOf(cc.tile57_gpu_quad)) << 8) |
            (@as(u32, @sizeOf(cc.tile57_gpu_range)) << 16) |
            (@as(u32, @sizeOf(cc.tile57_gpu_uniforms)) << 24);
        const got = cc.tile57_abi_gpu_layout();
        if (got != want) {
            std.debug.print("FATAL: tile57 GPU ABI mismatch — header says vertex/quad/range/uniforms = {d}/{d}/{d}/{d} B, linked engine says {d}/{d}/{d}/{d} B. Rebuild BOTH repos at matching commits.\n", .{
                @sizeOf(cc.tile57_gpu_vertex), @sizeOf(cc.tile57_gpu_quad), @sizeOf(cc.tile57_gpu_range), @sizeOf(cc.tile57_gpu_uniforms),
                got & 0xff,                    (got >> 8) & 0xff,           (got >> 16) & 0xff,           (got >> 24) & 0xff,
            });
            return error.EngineAbiMismatch;
        }
        cc.tile57_warmup();
        if (dbg) {
            std.debug.print("  warmup {d} ms\n", .{gpu.ticksMs() - t});
            t = gpu.ticksMs();
        }
        const self = try alloc.create(Lookout);
        self.* = .{
            .alloc = alloc,
            .g = try gpu.Gpu.init(.{
                .width = opts.width,
                .height = opts.height,
                .want_window = opts.want_window,
                .want_msaa = opts.want_msaa,
                .native_handle = opts.native_handle,
                .native_kind = opts.native_kind,
            }),
            .cam = undefined,
        };
        if (dbg) {
            std.debug.print("  gpu.init (Metal device+shaders+pipelines) {d} ms\n", .{gpu.ticksMs() - t});
            t = gpu.ticksMs();
        }
        self.n_schemes = @min(opts.schemes.len, MAX_SCHEMES);
        for (0..self.n_schemes) |i| self.schemes[i] = opts.schemes[i];
        cc.tile57_mariner_defaults(&self.mariner);
        // Default to the look of a traditional paper chart, using only mariner
        // settings. tile57's defaults are already half-way there (day scheme,
        // four-shade graduated-blue water, symbolized boundaries, full point
        // symbols — none of the "simplified" ECDIS symbology). What's left is
        // the *content*: a paper chart has no display categories and no ECDIS
        // overscale indicator, so —
        self.mariner.display_other = true; // show seabed, cables, contour labels — the OTHER content paper always carries
        self.mariner.soundings = 1; // paper is covered in spot soundings; show them regardless of category
        self.mariner.show_overscale = false; // AP(OVERSC01) hatch is an ECDIS-only artifact, never on paper
        // The ECDIS-only OTHER overlays (info callouts, meta boundaries, data
        // quality) stay off in tile57's defaults, so display_other brings the
        // paper content without the ECDIS clutter. finishOpen -> applyZoomAndView
        // derives the live gates (cat_mask/sound_on/clear) from this before the
        // first render.
        self.assets_root = atlasCacheDir(self.alloc);
        self.loadNodataColors();
        // NOT the atlases: they bake at the display density, and nothing has
        // told us what that is yet — the host cannot call resize() or
        // setPixelDensity() until this returns a handle. Baking here pinned
        // every symbol and glyph at 1.00x and then sampled it upscaled. See
        // ensureAtlases, which runs once the density is known.
        return self;
    }

    /// Load the symbol + glyph atlases, once, at the first build or draw — by
    /// which point the host has declared its density. Both are keyed on that
    /// density, so loading any earlier bakes the wrong sheet.
    fn ensureAtlases(self: *Lookout) void {
        if (self.atlases_ready) return;
        self.atlases_ready = true;
        const dbg = std.c.getenv("LOOKOUT_TIMING") != null;
        var t = gpu.ticksMs();
        self.loadSpriteAtlas();
        if (dbg) {
            std.debug.print("  loadSpriteAtlas {d} ms\n", .{gpu.ticksMs() - t});
            t = gpu.ticksMs();
        }
        self.loadGlyphAtlas();
        if (dbg) std.debug.print("  loadGlyphAtlas {d} ms\n", .{gpu.ticksMs() - t});
    }

    /// Read `<cache>/<name>` (the app's own atlas cache), or null on any miss.
    fn readCache(self: *Lookout, name: []const u8) ?[]u8 {
        const root = self.assets_root orelse return null;
        const path = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ root, name }) catch return null;
        defer self.alloc.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        return std.Io.Dir.cwd().readFileAlloc(io, path, self.alloc, .limited(256 * 1024 * 1024)) catch null;
    }

    /// Write `<cache>/<name>`. Best-effort: the atlas is already uploaded, so a
    /// failure just means the next open re-bakes.
    fn writeCache(self: *Lookout, name: []const u8, bytes: []const u8) void {
        const root = self.assets_root orelse return;
        const path = std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ root, name }) catch return;
        defer self.alloc.free(path);
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch {};
    }

    // Load the SDF label-glyph atlas: from the app cache if present, else bake
    // it once (from the embedded catalogue) and cache it. Text then draws as SDF
    // quads (crisp at any zoom) instead of tessellated glyph outlines. The SDF
    // atlas is resolution-independent, so one cached copy serves every density.
    fn loadGlyphAtlas(self: *Lookout) void {
        if (self.readCache("glyph.png")) |png_b| {
            defer self.alloc.free(png_b);
            if (self.readCache("glyph.json")) |json| {
                defer self.alloc.free(json);
                if (self.uploadGlyphRegular(png_b, json)) {
                    self.loadGlyphFace(1, true);
                    self.loadGlyphFace(2, false);
                    return;
                }
            }
        }
        // Bake + cache.
        var assets: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
        var err: cc.tile57_error = undefined;
        if (cc.tile57_bake_glyph_sdf(&assets, &err) != cc.TILE57_OK) return;
        defer cc.tile57_assets_free(&assets);
        if (assets.sprite_png == null or assets.sprite_json == null) return;
        const png_b = assets.sprite_png[0..assets.sprite_png_len];
        const json = assets.sprite_json[0..assets.sprite_json_len];
        if (self.uploadGlyphRegular(png_b, json)) {
            self.writeCache("glyph.png", png_b);
            self.writeCache("glyph.json", json);
        }
        self.loadGlyphFace(1, true);
        self.loadGlyphFace(2, false);
    }

    fn uploadGlyphRegular(self: *Lookout, png_b: []const u8, json: []const u8) bool {
        const a = atlas.loadGlyph(self.alloc, png_b, json) catch return false;
        self.glyph_atlas = a;
        self.g.uploadGlyphAtlas(a.rgba(), a.width, a.height) catch {
            self.glyph_atlas.?.deinit();
            self.glyph_atlas = null;
            return false;
        };
        self.glyph_atlas.?.freePixels(); // GPU has its copy
        std.debug.print("glyph atlas: {d}x{d}, {d} glyphs, em {d:.0}\n", .{ a.width, a.height, a.glyphs.count(), a.em_px });
        return true;
    }

    /// Load one label-tier face atlas (1 bold, 2 italic) — sidecar or live bake —
    /// decode, upload its texture. Metrics ride the GPU-scene quad UVs, so only
    /// the texture is kept.
    fn loadGlyphFace(self: *Lookout, face: i32, bold: bool) void {
        const png_name = if (bold) "glyph-bold.png" else "glyph-italic.png";
        const json_name = if (bold) "glyph-bold.json" else "glyph-italic.json";
        if (self.readCache(png_name)) |png_b| {
            defer self.alloc.free(png_b);
            if (self.readCache(json_name)) |json| {
                defer self.alloc.free(json);
                if (self.uploadGlyphFace(png_b, json, bold)) return;
            }
        }
        var assets: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
        var err: cc.tile57_error = undefined;
        if (cc.tile57_bake_glyph_sdf_face(&assets, face, &err) != cc.TILE57_OK) return;
        defer cc.tile57_assets_free(&assets);
        if (assets.sprite_png == null or assets.sprite_json == null) return;
        const png_b = assets.sprite_png[0..assets.sprite_png_len];
        const json = assets.sprite_json[0..assets.sprite_json_len];
        if (self.uploadGlyphFace(png_b, json, bold)) {
            self.writeCache(png_name, png_b);
            self.writeCache(json_name, json);
        }
    }

    fn uploadGlyphFace(self: *Lookout, png_b: []const u8, json: []const u8, bold: bool) bool {
        var a = atlas.loadGlyph(self.alloc, png_b, json) catch return false;
        defer a.deinit();
        if (bold)
            self.g.uploadGlyphAtlasBold(a.rgba(), a.width, a.height) catch return false
        else
            self.g.uploadGlyphAtlasItalic(a.rgba(), a.width, a.height) catch return false;
        return true;
    }

    // Load the S-52 sprite-symbol atlas: from the app cache if present, else
    // bake it once at the display density and cache it. The cache key includes
    // the density (a Retina 2x bake differs from 1x); the scale that actually
    // fit (see below) rides a small sidecar so the load matches the scene UVs.
    fn loadSpriteAtlas(self: *Lookout) void {
        var keybuf: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&keybuf, "sprite@{d:.2}", .{self.g.pixel_density}) catch "sprite@x";
        var pn: [32]u8 = undefined;
        var jn: [32]u8 = undefined;
        var sn: [32]u8 = undefined;
        const png_name = std.fmt.bufPrint(&pn, "{s}.png", .{key}) catch return;
        const json_name = std.fmt.bufPrint(&jn, "{s}.json", .{key}) catch return;
        const scale_name = std.fmt.bufPrint(&sn, "{s}.scale", .{key}) catch return;

        if (self.readCache(png_name)) |png_b| {
            defer self.alloc.free(png_b);
            if (self.readCache(json_name)) |json| {
                defer self.alloc.free(json);
                var scale: f32 = self.g.pixel_density;
                if (self.readCache(scale_name)) |sb| {
                    defer self.alloc.free(sb);
                    scale = std.fmt.parseFloat(f32, std.mem.trim(u8, sb, " \n\r\t")) catch scale;
                }
                if (self.uploadSprite(png_b, json, scale, false)) {
                    std.debug.print("sprite atlas @ {d:.2}x (cache)\n", .{scale});
                    return;
                }
            }
        }
        self.bakeAndCacheSprite(png_name, json_name, scale_name);
    }

    /// The largest sprite-atlas texture dimension this platform can hold as ONE
    /// texture. Real iOS devices report 16384, but a 3x symbol atlas is ~10.9k px
    /// tall (~268 MB RGBA) and such a texture UPLOADS ONLY PARTIALLY on device —
    /// the un-populated rows sample black, so symbols and line-style patterns
    /// packed low in the sheet render as solid-black blobs. Cap iOS (device AND
    /// simulator) at 8192 so the bake reduces its scale to fit; macOS is fine.
    fn spriteMaxDim() u32 {
        const bi = @import("builtin");
        if (std.c.getenv("LOOKOUT_MAXDIM")) |m| {
            if (std.fmt.parseInt(u32, std.mem.sliceTo(m, 0), 10) catch null) |v| return v;
        }
        return if (bi.os.tag == .ios or bi.os.tag == .tvos) 8192 else 16384;
    }

    /// Decode a sprite atlas PNG+JSON and upload it. `atlas_scale := scale` (the
    /// bake ratio) so the scene's sprite UVs match. Rejects an atlas larger than
    /// this platform can upload as one texture (a stale oversized CACHE entry) so
    /// the caller falls through to a fresh, fit-to-size bake.
    fn uploadSprite(self: *Lookout, png_b: []const u8, json: []const u8, scale: f32, note: bool) bool {
        _ = note;
        const a = atlas.loadSprite(self.alloc, png_b, json) catch return false;
        if (@max(a.width, a.height) > spriteMaxDim()) {
            var m = a;
            m.deinit();
            std.debug.print("cached sprite atlas {d}x{d} exceeds max {d}; rebaking\n", .{ a.width, a.height, spriteMaxDim() });
            return false;
        }
        self.sprite_atlas = a;
        self.g.uploadSpriteAtlas(a.rgba(), a.width, a.height) catch {
            self.sprite_atlas.?.deinit();
            self.sprite_atlas = null;
            return false;
        };
        self.sprite_atlas.?.freePixels(); // GPU has its copy; ~150 MB back
        self.atlas_scale = scale;
        return true;
    }

    // Bake the S-52 sprite-symbol atlas at the display density, upload it, and
    // write it to the app cache so later opens skip the (slow) rasterize. iOS
    // can't take the full-density result as one texture (a 3x bake is ~10.9k px
    // tall / ~268 MB and uploads only partially on device — the rest samples
    // black), so shrink the bake scale until it fits spriteMaxDim() and remember
    // it (atlas_scale) so scene UVs stay in step.
    fn bakeAndCacheSprite(self: *Lookout, png_name: []const u8, json_name: []const u8, scale_name: []const u8) void {
        const max_dim: u32 = spriteMaxDim();
        var scale: f32 = self.g.pixel_density;
        self.atlas_scale = scale;
        var attempts: u8 = 0;
        while (attempts < 4) : (attempts += 1) {
            var assets: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
            var err: cc.tile57_error = undefined;
            if (cc.tile57_bake_sprite_mln(null, @floatCast(scale), &assets, &err) != cc.TILE57_OK) return;
            defer cc.tile57_assets_free(&assets);
            if (assets.sprite_png == null or assets.sprite_json == null) return;
            const png_bytes = assets.sprite_png[0..assets.sprite_png_len];
            const json = assets.sprite_json[0..assets.sprite_json_len];
            var a = atlas.loadSprite(self.alloc, png_bytes, json) catch return;
            const largest = @max(a.width, a.height);
            if (largest > max_dim) {
                a.deinit();
                const fit = @as(f32, @floatFromInt(max_dim)) / @as(f32, @floatFromInt(largest));
                scale = @max(1.0, scale * fit * 0.98); // 2% slack for packer variance
                std.debug.print("sprite atlas {d}x{d} exceeds max texture {d}; rebaking at {d:.2}x\n", .{ a.width, a.height, max_dim, scale });
                continue;
            }
            self.sprite_atlas = a;
            self.g.uploadSpriteAtlas(a.rgba(), a.width, a.height) catch {
                self.sprite_atlas.?.deinit();
                self.sprite_atlas = null;
                return;
            };
            self.sprite_atlas.?.freePixels(); // GPU has its copy
            self.atlas_scale = scale;
            std.debug.print("sprite atlas: {d}x{d} @ {d:.2}x, {d} cells (baked)\n", .{ a.width, a.height, scale, a.cells.count() });
            // Cache the fit result (the on-disk PNG/JSON are the baked bytes).
            self.writeCache(png_name, png_bytes);
            self.writeCache(json_name, json);
            var sbuf: [16]u8 = undefined;
            if (std.fmt.bufPrint(&sbuf, "{d:.4}", .{scale})) |s| self.writeCache(scale_name, s) else |_| {}
            return;
        }
    }

    // Pull the S-52 NODATA (NODTA) color per captured scheme from tile57's
    // colortables, so the uncovered background matches the palette.
    fn loadNodataColors(self: *Lookout) void {
        var out: [*c]u8 = null;
        var len: usize = 0;
        var err: cc.tile57_error = undefined;
        if (cc.tile57_colortables_default(&out, &len, &err) != cc.TILE57_OK or out == null) return;
        defer cc.tile57_free(out);
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, out[0..len], .{}) catch return;
        defer parsed.deinit();
        const root_obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        for (0..self.n_schemes) |i| {
            const name = switch (self.schemes[i]) {
                cc.TILE57_SCHEME_DUSK => "dusk",
                cc.TILE57_SCHEME_NIGHT => "night",
                else => "day",
            };
            const scheme_obj = (root_obj.get(name) orelse continue).object;
            const hex = (scheme_obj.get("NODTA") orelse continue).string;
            if (hexColor(hex)) |c| self.nodata[i] = c;
        }
    }

    /// Open every path, in parallel. A real library is thousands of cells and
    /// each open is an openat + stat + mmap and a metadata/coverage decode —
    /// mostly waiting on the filesystem (charts usually sit on Android's
    /// FUSE-backed storage), so serially this dominates the whole open.
    /// Charts land in their path's slot, so the composed order is the caller's
    /// regardless of which worker got there first.
    fn openChartPaths(self: *Lookout, paths: []const [:0]const u8) void {
        if (paths.len <= 1) {
            for (paths) |p| self.addChartPath(p);
            return;
        }
        const slots = self.alloc.alloc(?*cc.tile57_chart, paths.len) catch {
            for (paths) |p| self.addChartPath(p); // no room for the slots: serial
            return;
        };
        defer self.alloc.free(slots);
        @memset(slots, null);

        const W = struct {
            fn run(ps: []const [:0]const u8, out: []?*cc.tile57_chart, next: *std.atomic.Value(usize)) void {
                while (true) {
                    const i = next.fetchAdd(1, .monotonic); // claim, don't partition: cells vary in size
                    if (i >= ps.len) return;
                    var err: cc.tile57_error = undefined;
                    var chart: ?*cc.tile57_chart = null;
                    if (cc.tile57_chart_open(ps[i].ptr, &chart, &err) == cc.TILE57_OK) out[i] = chart;
                }
            }
        };

        var next = std.atomic.Value(usize).init(0);
        const cpus = std.Thread.getCpuCount() catch 1;
        var threads: [8]std.Thread = undefined;
        const want = @min(@max(cpus, 1), threads.len + 1) - 1; // this thread works too
        var spawned: usize = 0;
        while (spawned < want) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, W.run, .{ paths, slots, &next }) catch break;
        }
        W.run(paths, slots, &next);
        for (threads[0..spawned]) |t| t.join();

        for (slots, paths) |c, p| {
            if (c) |ch| self.charts.append(self.alloc, ch) catch {} else std.debug.print("skip '{s}'\n", .{p});
        }
    }

    fn addChartPath(self: *Lookout, path: [:0]const u8) void {
        var err: cc.tile57_error = undefined;
        var chart: ?*cc.tile57_chart = null;
        if (cc.tile57_chart_open(path.ptr, &chart, &err) != cc.TILE57_OK or chart == null) {
            std.debug.print("skip '{s}': {s}\n", .{ path, @as([*:0]const u8, @ptrCast(&err.message)) });
            return;
        }
        self.charts.append(self.alloc, chart.?) catch {};
    }
    fn finishOpen(self: *Lookout) !void {
        if (self.charts.items.len == 0) return error.NoCharts;
        // Set an immediate view + zoom clamps from the FIRST cell — no compositor
        // needed — so the window can render right away.
        self.applyZoomAndView();
        // Compose over the whole library (the slow ownership-partition build) on a
        // worker thread; the window shows a loader until it lands (see tick).
        if (self.charts.items.len > 1) {
            self.loading = true;
            self.compose_done.store(false, .release);
            self.compose_thread = std.Thread.spawn(.{}, composeWorker, .{self}) catch blk: {
                self.composeWorker(); // fallback: synchronous
                break :blk null;
            };
            self.pollCompose(self.compose_thread == null); // apply immediately if it ran sync
        }
    }

    fn composeWorker(self: *Lookout) void {
        var err: cc.tile57_error = undefined;
        var c: ?*cc.tile57_compose = null;
        // No partition path: the engine finds the sidecar its own bake wrote next
        // to the archives, and builds one in memory if there is none. Where that
        // file lives, and whether it is reusable, is the engine's business.
        if (cc.tile57_compose_open(self.charts.items.ptr, self.charts.items.len, &c, &err) == cc.TILE57_OK and c != null) {
            self.compose_result = c;
        } else {
            std.debug.print("compose_open failed: {s}\n", .{@as([*:0]const u8, @ptrCast(&err.message))});
        }
        self.compose_done.store(true, .release);
    }

    // Adopt the composed set once its partition build finishes. `block` waits.
    fn pollCompose(self: *Lookout, block: bool) void {
        if (!self.loading) return;
        if (!block and !self.compose_done.load(.acquire)) return;
        if (self.compose_thread) |t| {
            t.join();
            self.compose_thread = null;
        }
        self.loading = false;
        if (self.compose_result) |c| {
            self.compose = c;
            self.zl_valid = false; // new partition — the cached per-view max is stale
            self.updateZoomLimits(); // refresh the zoom band; DON'T touch the view
            std.debug.print("composed {d} charts\n", .{self.charts.items.len});
        }
        // The loader animated self.g.clear to a dark pulse (see render()); now that
        // we're drawing the chart again, re-derive the live state so the clear goes
        // back to the scheme's NODATA. Without this the composed view keeps the last
        // dark pulse colour as its background.
        self.deriveLive();
    }

    // Zoom-out floor: never coarser than z4 (nor below the coarsest band's data).
    // Zoom-in cap: the deepest SERVED zoom (compose_meta.max_zoom) — already native
    // + one fill-up overscale level. buildZoom clamps the scene to this, so letting
    // cam.zoom run past it only MVP-magnifies that scene into nodata-ish blur; cap
    // exactly there so cam.zoom == buildZoom at the limit and the chart stays crisp.
    const MIN_ZOOM_FLOOR = 4.0;
    fn updateZoomLimits(self: *Lookout) void {
        const zr = self.zoomRange();
        self.engine_max_zoom = @min(zr[1], self.served_max_zoom);
        self.cam.min_zoom = @max(MIN_ZOOM_FLOOR, zr[0]);
        // Per-view cap: the deepest zoom the chart UNDER THE VIEW CENTRE can serve.
        // Over a coarse-only area every covering cell's reach is low, so the
        // library-wide max (zr[1], set by a distant deep chart) would zoom straight
        // into nodata; this caps at what's actually there.
        // Allow zooming PAST the deepest data by a bounded margin: the scene
        // stays built at the data's max zoom and the MVP magnifies it (same
        // path as a pinch between rebuilds), with the HUD showing an overscale
        // badge (lookout_overscale). S-52 permits overscale WITH indication.
        self.cam.max_zoom = self.viewMaxZoom() + OVERSCALE_ALLOW;
        self.cam.target_zoom = std.math.clamp(self.cam.target_zoom, self.cam.min_zoom, self.cam.max_zoom);
    }

    /// Deepest servable zoom at the current view centre (tile57_compose_max_zoom_at),
    /// falling back to the library max for a single chart or an off-coverage point.
    /// CACHED by view position: updateZoomLimits runs every frame, and the
    /// engine query walks the partition — it measured 14% of active CPU in a
    /// gesture profile. Recomputed after ~32 screen px of pan or half a zoom
    /// level; compose adoption invalidates (zl_valid).
    fn viewMaxZoom(self: *Lookout) f64 {
        const c = self.compose orelse return self.zoomRange()[1];
        const thresh = 32.0 / (std.math.exp2(self.cam.zoom) * 256.0);
        if (self.zl_valid and
            @abs(self.cam.center.x - self.zl_center.x) <= thresh and
            @abs(self.cam.center.y - self.zl_center.y) <= thresh and
            @abs(self.cam.zoom - self.zl_zoom) <= 0.5)
            return self.zl_max;
        const ll = camera.worldToLonLat(self.cam.center);
        const mz = cc.tile57_compose_max_zoom_at(c, ll.x, ll.y);
        self.zl_max = if (mz > 0) @floatFromInt(mz) else self.zoomRange()[1];
        self.zl_center = self.cam.center;
        self.zl_zoom = self.cam.zoom;
        self.zl_valid = true;
        return self.zl_max;
    }

    fn applyZoomAndView(self: *Lookout) void {
        const v = self.fitChart();
        const lw, const lh = self.logicalSize();
        self.cam = viewToCamera(v, lw, lh);
        self.updateZoomLimits();
        self.deriveLive();
    }

    fn zoomRange(self: *Lookout) [2]f64 {
        if (self.compose) |c| {
            var m: cc.tile57_compose_meta = undefined;
            cc.tile57_compose_get_meta(c, &m);
            return .{ @floatFromInt(m.min_zoom), @floatFromInt(m.max_zoom) };
        }
        var info: cc.tile57_info = undefined;
        cc.tile57_chart_get_info(self.charts.items[0], &info);
        return .{ @floatFromInt(info.min_zoom), @floatFromInt(info.max_zoom) };
    }

    pub fn close(self: *Lookout) void {
        self.pollCompose(true); // finish any in-flight partition build first
        self.joinBuild(); // and any in-flight async rebuild (it touches the engine)
        if (self.sprite_atlas) |*sa| sa.deinit();
        if (self.glyph_atlas) |*ga| ga.deinit();
        if (self.assets_root) |r| self.alloc.free(r);
        self.g.deinit();
        if (self.compose) |c| cc.tile57_compose_close(c); // BEFORE the charts
        for (self.charts.items) |ch| cc.tile57_chart_close(ch);
        self.charts.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    // ---- view ---------------------------------------------------------------
    fn viewToCamera(v: View, w: f32, h: f32) camera.Camera {
        const o = camera.lonLatToWorld(v.lon, v.lat);
        return .{ .origin = o, .center = o, .zoom = v.zoom, .target_zoom = v.zoom, .rotation = v.rotation_deg * std.math.pi / 180.0, .vw = w, .vh = h };
    }

    /// A BOUNDED opening view. Deliberately ONE cell's own bounds, NOT the union
    /// of a whole library — fitting a big composite would tessellate the entire
    /// library into one gigantic scene. Pan/zoom reaches the rest.
    ///
    /// For a library we fit the MOST DETAILED cell (smallest bounds area), not
    /// the first alphabetically: a US ENC's first cell is usually a tiny-scale
    /// EEZ overview (e.g. US1EEZ1M) that opens as an empty ocean rectangle. A
    /// harbour/approach cell lands the user on actual chart content instead.
    /// The pose a host should open with when it has nothing saved. fitChart
    /// alone lands on the smallest bounded CELL, which in a 2500-cell library
    /// is an arbitrary harbour; keep that centre but pull back to an overview.
    /// Hosts persist the pose themselves (each has its own store) — this is
    /// the one piece of the policy worth having in a single place.
    const DEFAULT_VIEW_ZOOM = 5.0;
    pub fn defaultView(self: *Lookout) View {
        var v = self.fitChart();
        v.zoom = std.math.clamp(DEFAULT_VIEW_ZOOM, self.cam.min_zoom, self.cam.max_zoom);
        v.rotation_deg = 0;
        return v;
    }

    pub fn fitChart(self: *Lookout) View {
        var west: f64 = 0;
        var south: f64 = 0;
        var east: f64 = 0;
        var north: f64 = 0;
        var has_bounds = false;
        var min_zoom: u8 = 0;
        var max_zoom: u8 = 22;
        {
            // Pick the smallest-area bounded cell as the opening view. Falls back
            // to the first cell's anchor (or the first cell) when none is bounded.
            var best_area: f64 = std.math.floatMax(f64);
            var anchor: ?View = null;
            for (self.charts.items) |ch| {
                var info: cc.tile57_info = undefined;
                cc.tile57_chart_get_info(ch, &info);
                if (info.has_bounds) {
                    const area = @abs(info.east - info.west) * @abs(info.north - info.south);
                    if (area < best_area) {
                        best_area = area;
                        west = info.west;
                        south = info.south;
                        east = info.east;
                        north = info.north;
                        min_zoom = info.min_zoom;
                        max_zoom = info.max_zoom;
                        has_bounds = true;
                    }
                } else if (anchor == null and info.has_anchor) {
                    anchor = .{ .lon = info.anchor_lon, .lat = info.anchor_lat, .zoom = info.anchor_zoom };
                }
            }
            if (!has_bounds) {
                if (anchor) |a| return a;
            }
        }
        if (!has_bounds) return .{ .lon = 0, .lat = 0, .zoom = 2 };
        const wl = camera.lonLatToWorld(west, north);
        const wr = camera.lonLatToWorld(east, south);
        const lw, const lh = self.logicalSize();
        const vw: f64 = lw;
        const vh: f64 = lh;
        const zx = std.math.log2(vw / (256.0 * @max(@abs(wr.x - wl.x), 1e-12)));
        const zy = std.math.log2(vh / (256.0 * @max(@abs(wr.y - wl.y), 1e-12)));
        var z = @min(zx, zy) - 0.15;
        z = std.math.clamp(z, @as(f64, @floatFromInt(min_zoom)), @as(f64, @floatFromInt(max_zoom)) + 1.0);
        return .{ .lon = (west + east) * 0.5, .lat = (south + north) * 0.5, .zoom = z };
    }

    /// Move the camera. Pan/zoom/rotate never re-tessellate; a big jump to new
    /// ground may want build() for fresh detail.
    pub fn setView(self: *Lookout, v: View) void {
        self.cam.center = camera.lonLatToWorld(v.lon, v.lat);
        self.cam.zoom = v.zoom;
        self.cam.rotation = v.rotation_deg * std.math.pi / 180.0;
        self.served_max_zoom = 1e9; // new ground: re-probe how deep it serves
        // Pin the animation target to the new pose: otherwise the zoom easer
        // still aims at the PREVIOUS target and drags the view back (about a
        // stale cursor pivot) on the next frames.
        self.cam.setTarget();
        self.cam.clampY();
        self.markDirty();
    }
    pub fn view(self: *Lookout) View {
        const ll = camera.worldToLonLat(self.cam.center);
        return .{ .lon = ll.x, .lat = ll.y, .zoom = self.cam.zoom, .rotation_deg = self.cam.rotation * 180.0 / std.math.pi };
    }

    /// Resize the render surface (points; HiDPI density is applied internally).
    pub fn resize(self: *Lookout, width: u32, height: u32) !void {
        self.host_pt_w = @floatFromInt(width);
        self.host_pt_h = @floatFromInt(height);
        try self.g.resize(width, height);
        const lw, const lh = self.logicalSize();
        self.cam.vw = lw;
        self.cam.vh = lh;
        self.markDirty();
    }

    /// The viewport in LOGICAL (device-independent) px — the single unit the
    /// camera, the portrayal and every mark size are expressed in. The
    /// framebuffer may be 2x that on a HiDPI display; pxToClip maps logical px
    /// across the whole framebuffer, so density is handled ONCE, in the
    /// projection, and never multiplied into a size again.
    fn logicalSize(self: *const Lookout) struct { f32, f32 } {
        if (self.host_pt_w > 0 and self.host_pt_h > 0) return .{ self.host_pt_w, self.host_pt_h };
        const d = if (self.g.pixel_density > 0) self.g.pixel_density else 1.0;
        return .{ @as(f32, @floatFromInt(self.g.width)) / d, @as(f32, @floatFromInt(self.g.height)) / d };
    }
    pub fn pixelDensity(self: *Lookout) f32 {
        return self.g.pixel_density;
    }

    /// Declare the host's scale factor instead of letting the backend infer it
    /// from the surface. Set before the first build.
    pub fn setPixelDensity(self: *Lookout, d: f32) void {
        // Density-baked sprite atlas must rebake on a late density change (else it aliases).
        if (self.atlases_ready and d != self.g.pixel_density) self.atlases_ready = false;
        self.g.setPixelDensity(d);
    }

    // ---- interaction --------------------------------------------------------
    pub fn panPixels(self: *Lookout, dx: f32, dy: f32) void {
        self.cam.panPx(dx, dy);
        self.markDirty();
    }
    pub fn zoomAt(self: *Lookout, dzoom: f64, x_px: f32, y_px: f32) void {
        self.cam.zoomAbout(dzoom, x_px, y_px);
        self.markDirty();
    }
    pub fn screenToGeo(self: *Lookout, x_px: f32, y_px: f32) View {
        const ll = camera.worldToLonLat(self.cam.screenToWorld(x_px, y_px));
        return .{ .lon = ll.x, .lat = ll.y, .zoom = self.cam.zoom };
    }
    pub fn geoToScreen(self: *Lookout, lon: f64, lat: f64) [2]f32 {
        const s = self.cam.worldToScreen(camera.lonLatToWorld(lon, lat));
        return .{ @floatCast(s.x), @floatCast(s.y) };
    }
    // Mouse coords from a HiDPI window arrive in logical points — which is the
    // camera's own unit now, so they pass straight through.
    pub fn panLogical(self: *Lookout, dx_pt: f32, dy_pt: f32) void {
        self.cam.panPx(dx_pt, dy_pt);
        self.markDirty();
    }
    pub fn zoomAtLogical(self: *Lookout, dzoom: f64, x_pt: f32, y_pt: f32) void {
        self.cam.zoomToward(dzoom, x_pt, y_pt); // eases in tickAnim, not an instant snap
        self.markDirty();
    }

    /// Rotate the view about its centre by the angle the cursor swept from
    /// (prev) to (cur), both logical points — a grab-and-spin (course-up)
    /// gesture. Rotation is a shader uniform, so this only redraws: markDirty
    /// sets view_dirty, and needsRebuild ignores rotation, so no scene rebuild.
    pub fn rotateDragLogical(self: *Lookout, prev_x: f32, prev_y: f32, cur_x: f32, cur_y: f32) void {
        const sz = self.logicalSize();
        const cx = sz[0] * 0.5;
        const cy = sz[1] * 0.5;
        const a0 = std.math.atan2(@as(f64, prev_y - cy), @as(f64, prev_x - cx));
        const a1 = std.math.atan2(@as(f64, cur_y - cy), @as(f64, cur_x - cx));
        self.cam.rotation += a1 - a0;
        self.markDirty();
    }

    /// Snap the view back to north-up.
    pub fn resetRotation(self: *Lookout) void {
        if (self.cam.rotation == 0) return;
        self.cam.rotation = 0;
        self.markDirty();
    }

    /// Start a fling (momentum pan) with a logical-px/sec velocity.
    pub fn flingStart(self: *Lookout, vx: f64, vy: f64) void {
        self.cam.flingStart(vx, vy);
    }

    /// True while the camera is easing a zoom or coasting a fling.
    pub fn animating(self: *Lookout) bool {
        return self.cam.animating();
    }

    /// Advance camera animations by `dt` seconds; call each frame while animating.
    pub fn tickAnim(self: *Lookout, dt: f64) void {
        self.cam.tick(dt);
        self.deriveLive(); // zoom moved: refresh SCAMIN / display-scale gates
        self.markDirty();
    }

    /// The current view's S-52 display-scale denominator (the N in 1:N), from the
    /// authoritative camera math (center latitude + zoom). For the HUD readout.
    pub fn scaleDenominator(self: *Lookout) f64 {
        return self.cam.displayScale();
    }

    // ---- mariner (ALL S-52 settings) ---------------------------------------
    pub fn getMariner(self: *Lookout) Mariner {
        return self.mariner;
    }
    /// Apply the full S-52 state. Visibility-only changes (scheme, display
    /// categories, text, soundings, size) apply live; anything that changes what
    /// the engine emits (contours, units, dates, viewing groups, point/boundary
    /// style, overscale, extra size scales…) marks the scene for a rebuild, done
    /// lazily on the next render.
    pub fn setMariner(self: *Lookout, m: Mariner) void {
        // A scheme change or any geometry-affecting field needs a fresh scene;
        // category / text / sounding / size changes apply live (see deriveLive).
        // `dirty` forces the rebuild even though the view didn't move.
        if (self.mariner.scheme != m.scheme or marinerNeedsRebuild(self.mariner, m)) self.dirty = true;
        self.mariner = m;
        self.deriveLive();
    }

    fn deriveLive(self: *Lookout) void {
        self.cat_mask = (@as(u32, @intFromBool(self.mariner.display_base)) << 0) |
            (@as(u32, @intFromBool(self.mariner.display_standard)) << 1) |
            (@as(u32, @intFromBool(self.mariner.display_other)) << 2);
        // Text + soundings gate live by SKIPPING their ranges — the scene carries
        // them (permissive build) so a toggle needs no rebuild.
        self.text_on = self.mariner.text_names or self.mariner.show_light_descriptions or self.mariner.text_other;
        self.sound_on = self.mariner.soundings == 1 or (self.mariner.soundings == 0 and self.mariner.display_other);
        self.render_size_scale = if (self.mariner.size_scale == 0) 1.0 else @floatCast(self.mariner.size_scale);
        const si: usize = @min(@as(usize, @intCast(self.mariner.scheme)), MAX_SCHEMES - 1);
        self.g.clear = self.nodata[si]; // background NODATA follows the palette
        self.markDirty();
    }

    // ---- build + render -----------------------------------------------------
    // The engine (tile57) portrays + tessellates the whole view into ONE
    // draw-ready scene that OVERSCANS the viewport; the host uploads it and only
    // rebuilds when the view pans/zooms out of that coverage, so panning within
    // the margin just re-transforms the same buffers (a uniform change).
    const OVERSCAN = 1.25;
    const ZOOM_REBUILD = 0.3; // zoom drift that forces a fresh build (2^0.3 < OVERSCAN)

    // The zoom to BUILD at — the camera zoom clamped to the deepest band the
    // engine serves; zooming past it keeps this fixed (overscale) and the camera
    // scales the deepest-band geometry up.
    fn buildZoom(self: *Lookout) f64 {
        return @min(self.cam.zoom, self.engine_max_zoom);
    }

    // The zoom the NEXT scene should be built FOR: where the camera is HEADING
    // (target_zoom — a pinch/wheel moves it ahead of the eased zoom), clamped
    // like buildZoom. A build takes seconds on a phone; building for the zoom
    // the user is LEAVING guarantees the scene lands already stale, and during
    // a continuous zoom-out the stale coverage shrinks to a patch in NODATA
    // until the next build lands. Building for the target lands on (or much
    // nearer) the settle zoom. Idle or panning, target == zoom, so this is
    // exactly buildZoom.
    fn buildTargetZoom(self: *Lookout) f64 {
        return @min(self.cam.target_zoom, self.engine_max_zoom);
    }

    fn markDirty(self: *Lookout) void {
        self.view_dirty = true;
        self.last_change_ms = gpu.ticksMs();
    }

    // Record the coverage of the scene just built, so needsRebuild can tell when
    // the view has left it.
    fn recordCoverage(self: *Lookout, origin: camera.Vec2, zoom: f64, w_px: f64, h_px: f64) void {
        const wp = camera.Camera.worldToPx(.{ .origin = origin, .center = origin, .zoom = zoom, .vw = 1, .vh = 1 });
        self.cov_origin = origin;
        self.cov_zoom = zoom;
        self.cov_hw = w_px * 0.5 / wp;
        self.cov_hh = h_px * 0.5 / wp;
    }

    // True when the current view has panned/zoomed out of the built coverage.
    // The x distance wraps: panning across the antimeridian is a short hop, not
    // a world-width jump. The zoom test compares the coverage against the zoom
    // the next build WOULD use (the target) — comparing against the still-easing
    // camera zoom would re-spawn identical builds all the way through the ease.
    fn needsRebuild(self: *Lookout) bool {
        if (!self.built) return true;
        if (@abs(self.buildTargetZoom() - self.cov_zoom) > ZOOM_REBUILD) return true;
        const he = self.cam.halfExtents();
        return @abs(camera.wrapDx(self.cam.center.x, self.cov_origin.x)) + he.x > self.cov_hw or
            @abs(self.cam.center.y - self.cov_origin.y) + he.y > self.cov_hh;
    }

    /// The immutable inputs a build needs, captured up front so a worker never
    /// races the live camera / mariner.
    pub const BuildJob = struct {
        origin: camera.Vec2 = .{ .x = 0, .y = 0 },
        zoom: f64 = 0,
        ow: u32 = 0,
        oh: u32 = 0,
        mariner: cc.tile57_mariner = std.mem.zeroes(cc.tile57_mariner),
        prefetch: bool = false, // warm the engine's tile cache only; don't upload/swap
    };

    fn jobFor(self: *Lookout, origin: camera.Vec2, zoom: f64, prefetch: bool) BuildJob {
        const lw, const lh = self.logicalSize();
        var m0 = buildMarinerFrom(self.mariner, self.mariner.scheme);
        m0.size_scale = self.render_size_scale;
        m0.device_scale = 1.0; // camera is in LOGICAL px; density lives in the projection
        return .{
            .origin = origin,
            .zoom = zoom,
            .ow = @intFromFloat(@max(1.0, lw * OVERSCAN)),
            .oh = @intFromFloat(@max(1.0, lh * OVERSCAN)),
            .mariner = m0,
            .prefetch = prefetch,
        };
    }

    // The pure engine call: portray the job's view into a draw-ready scene. No
    // `self` mutation and no GPU — safe on a worker thread. A library (many
    // cells) goes through the compositor so seams stitch; a single chart to its
    // own archive.
    pub fn apiLock(self: *Lookout) void {
        self.api_mu.lock();
    }
    pub fn apiUnlock(self: *Lookout) void {
        self.api_mu.unlock();
    }

    fn runJob(self: *Lookout, job: BuildJob, out: *cc.tile57_gpu_scene) bool {
        self.engine_mu.lock();
        defer self.engine_mu.unlock();
        const t0 = gpu.ticksMs();
        const ll = camera.worldToLonLat(job.origin);
        var m0 = job.mariner;
        var err: cc.tile57_error = undefined;
        // The sprite quads' UVs must match the atlas texture we actually baked —
        // atlas_scale is the display density unless the atlas had to shrink to
        // fit the device's max texture dimension (loadSpriteAtlas).
        const ratio: f64 = @floatCast(self.atlas_scale);
        const st = if (self.compose) |c|
            cc.tile57_compose_gpu_scene(c, ll.x, ll.y, job.zoom, job.ow, job.oh, &m0, ratio, out, &err)
        else
            cc.tile57_chart_gpu_scene(self.charts.items[0], ll.x, ll.y, job.zoom, job.ow, job.oh, &m0, ratio, out, &err);
        if (st != cc.TILE57_OK) std.debug.print("build ERROR: {s}\n", .{@as([*:0]const u8, @ptrCast(&err.message))});
        const dt = gpu.ticksMs() - t0;
        self.last_build_ms.store(dt, .monotonic);
        // tri= is a content hash of the triangle geometry — density- and
        // atlas-independent, so a device build of a view is directly comparable
        // against a Mac build of the same ll/zoom/ow/oh.
        var th: u64 = 0;
        if (st == cc.TILE57_OK) {
            var h = std.hash.Wyhash.init(0);
            if (out.vertex_count > 0) h.update(std.mem.sliceAsBytes(out.vertices[0..out.vertex_count]));
            if (out.index_count > 0) h.update(std.mem.sliceAsBytes(out.indices[0..out.index_count]));
            th = h.final();
        }
        const ll2 = camera.worldToLonLat(job.origin);
        std.debug.print("build z{d:.2} {s} {d} ms ok={} verts={d} quads={d} ranges={d} ow={d} oh={d} density={d:.2} ll=({d:.5},{d:.5}) tri={x} mset={x}\n", .{ job.zoom, if (job.prefetch) "prefetch" else "scene", dt, st == cc.TILE57_OK, out.vertex_count, out.quad_count, out.range_count, job.ow, job.oh, self.g.pixel_density, ll2.x, ll2.y, th, marinerGeomHash(&job.mariner) });
        return st == cc.TILE57_OK;
    }

    /// Hash of every geometry-affecting mariner field a build depends on (the
    /// marinerNeedsRebuild list + scheme + size scale). Two builds with the same
    /// mset and view are comparable across machines; differing msets explain a
    /// scene difference before anything else is suspected.
    fn marinerGeomHash(m: *const cc.tile57_mariner) u64 {
        var h = std.hash.Wyhash.init(0);
        inline for (.{
            "scheme",                   "size_scale",           "shallow_contour",        "safety_contour",
            "deep_contour",             "safety_depth",         "four_shade_water",       "depth_unit",
            "data_quality",             "show_inform_callouts", "show_meta_bounds",       "show_isolated_dangers_shallow",
            "boundary_style",           "simplified_points",    "show_full_sector_lines", "date_dependent",
            "highlight_date_dependent", "ignore_scamin",        "scamin_filter_gate",     "show_overscale",
            "text_size_scale",          "sounding_size_scale",
        }) |f| h.update(std.mem.asBytes(&@field(m.*, f)));
        h.update(&m.date_view);
        if (m.viewing_groups_off_len > 0 and m.viewing_groups_off != null)
            h.update(std.mem.sliceAsBytes(m.viewing_groups_off[0..m.viewing_groups_off_len]));
        return h.final();
    }

    // Adopt a STAGED scene on the render thread: a prefetch only warmed the
    // engine cache (nothing staged); a real rebuild swaps the staged buffers in
    // and records coverage. The engine C scene was already freed by whoever
    // staged (worker or sync path) — this touches only host state.
    fn applyStaged(self: *Lookout, job: BuildJob, ok: bool, staged: ?gpu.Gpu.Scene) void {
        self.last_fail_ms = if (!ok and !job.prefetch) gpu.ticksMs() else 0;
        if (!ok or job.prefetch) {
            if (staged) |sc| {
                var v = sc;
                self.g.freeStagedScene(&v);
            }
            return;
        }
        const sc = staged orelse {
            // Staging can fail transiently (e.g. buffer pool during a window
            // transition). Do NOT record coverage or clear dirty: with a null
            // scene but satisfied coverage the chart would stay blank forever.
            // Leaving dirty set retries the build next frame.
            std.debug.print("scene upload failed; retrying\n", .{});
            self.dirty = true;
            return;
        };
        // A zoom-in that built empty: the chart's declared max_zoom overreports
        // and there is no geometry this deep under the view. Don't blank the good
        // scene — keep it, cap the servable max here so buildTargetZoom stops
        // chasing the empty level, and let cam.zoom overscale (MVP-magnify) it.
        if (self.built and sc.ranges.len == 0 and job.zoom > self.cov_zoom + ZOOM_REBUILD) {
            var v = sc;
            self.g.freeStagedScene(&v);
            self.served_max_zoom = self.cov_zoom;
            self.updateZoomLimits(); // re-clamp target/max to the corrected max
            self.dirty = false; // don't respin the same empty build
            return;
        }
        self.g.adoptScene(sc);
        self.recordCoverage(job.origin, job.zoom, @floatFromInt(job.ow), @floatFromInt(job.oh));
        self.built = true;
        self.dirty = false;
        // The fresh scene must actually be DRAWN: without this an async rebuild
        // that lands after the host's loop went idle (e.g. at the end of a
        // full-screen transition) sits uploaded but never presented.
        self.markDirty();
    }

    // Stage a finished engine scene into GPU buffers + free the engine scene.
    // Runs on WHICHEVER thread ran the build (worker or sync) — resource
    // creation is thread-safe; only applyStaged's swap belongs to the render
    // thread. Also home of the LOOKOUT_SCENE_DEBUG hash line, which needs the
    // C scene alive.
    fn stageJob(self: *Lookout, job: BuildJob, cs: *cc.tile57_gpu_scene, ok: bool) ?gpu.Gpu.Scene {
        defer cc.tile57_gpu_scene_free(cs);
        if (std.c.getenv("LOOKOUT_SCENE_DEBUG") != null) {
            const ll = camera.worldToLonLat(job.origin);
            // Content hashes: compare a device's scene against a Mac build of the
            // SAME view (lon/lat/integer zoom via go-to-coordinate + zoom buttons,
            // --width/--height for ow/oh, LOOKOUT_DENSITY/LOOKOUT_MAXDIM to match
            // density + atlas scale). Identical hashes with different pictures
            // convict the draw layer; different hashes convict the engine build.
            var th: u64 = 0;
            var qh: u64 = 0;
            if (ok) {
                var h = std.hash.Wyhash.init(0);
                if (cs.vertex_count > 0) h.update(std.mem.sliceAsBytes(cs.vertices[0..cs.vertex_count]));
                if (cs.index_count > 0) h.update(std.mem.sliceAsBytes(cs.indices[0..cs.index_count]));
                th = h.final();
                var h2 = std.hash.Wyhash.init(0);
                if (cs.quad_count > 0) h2.update(std.mem.sliceAsBytes(cs.quads[0..cs.quad_count]));
                qh = h2.final();
            }
            std.debug.print("applyJob ok={} prefetch={} ll=({d:.4},{d:.4}) z={d:.2} ow={d} oh={d} verts={d} ranges={d} tri_hash={x} quad_hash={x}\n", .{ ok, job.prefetch, ll.x, ll.y, job.zoom, job.ow, job.oh, cs.vertex_count, cs.range_count, th, qh });
        }
        if (!ok or job.prefetch) return null;
        return self.g.makeScene(self.alloc, cs) catch null;
    }

    // Synchronous build (snapshots, and the very first frame so there is
    // something to draw immediately).
    fn buildGpuScene(self: *Lookout) void {
        self.ensureAtlases(); // runJob reads atlas_scale for the sprite UVs
        const job = self.jobFor(self.cam.center, self.buildZoom(), false);
        var cs: cc.tile57_gpu_scene = std.mem.zeroes(cc.tile57_gpu_scene);
        const ok = self.runJob(job, &cs);
        self.applyStaged(job, ok, self.stageJob(job, &cs, ok));
    }

    /// Force a build now (snapshots have no frame loop).
    pub fn build(self: *Lookout) !void {
        self.pollCompose(true);
        self.buildGpuScene();
    }

    // ---- async build --------------------------------------------------------
    fn buildWorker(self: *Lookout) void {
        var cs: cc.tile57_gpu_scene = std.mem.zeroes(cc.tile57_gpu_scene);
        self.pending_ok = self.runJob(self.build_job, &cs);
        if (async_stage) {
            // Stage the GPU buffers HERE, off the render thread: creating them
            // copies the whole scene (tens of MB — ~40% of active CPU in a
            // gesture profile when it ran on the render thread). Frees the
            // engine scene.
            self.pending_scene = self.stageJob(self.build_job, &cs, self.pending_ok);
        } else {
            // Vulkan backends: GPU work is render-thread-only. Hand the raw C
            // scene over; pollBuild stages it there.
            self.pending_cs = cs;
            self.pending_cs_valid = true;
        }
        self.build_done.store(true, .release); // publishes pending_* to the main thread
    }

    fn spawnBuild(self: *Lookout, job: BuildJob) void {
        self.build_job = job;
        self.build_active = true;
        self.build_done.store(false, .release);
        self.build_thread = std.Thread.spawn(.{}, buildWorker, .{self}) catch {
            // No thread: fall back to a blocking build so we never stall forever.
            self.build_active = false;
            var cs: cc.tile57_gpu_scene = std.mem.zeroes(cc.tile57_gpu_scene);
            const ok = self.runJob(job, &cs);
            self.applyStaged(job, ok, self.stageJob(job, &cs, ok));
            return;
        };
    }

    // Advance the async build (render thread). Adopts a finished worker's
    // scene — staging it here first on backends where the worker couldn't.
    fn pollBuild(self: *Lookout) void {
        if (!self.build_active or !self.build_done.load(.acquire)) return;
        if (self.build_thread) |t| {
            t.join();
            self.build_thread = null;
        }
        if (!async_stage and self.pending_cs_valid) {
            self.pending_scene = self.stageJob(self.build_job, &self.pending_cs, self.pending_ok);
            self.pending_cs_valid = false; // stageJob freed the C scene
        }
        self.applyStaged(self.build_job, self.pending_ok, self.pending_scene);
        self.pending_scene = null;
        self.build_active = false;
    }

    fn joinBuild(self: *Lookout) void {
        if (self.build_thread) |t| {
            t.join();
            self.build_thread = null;
            if (self.pending_scene) |sc| {
                var v = sc;
                self.g.freeStagedScene(&v);
                self.pending_scene = null;
            }
            if (!async_stage and self.pending_cs_valid) {
                cc.tile57_gpu_scene_free(&self.pending_cs);
                self.pending_cs_valid = false;
            }
        }
        self.build_active = false;
    }

    // Kick off whatever build the current view needs, async. A geometry-affecting
    // change (`dirty`) or a coverage-exit rebuilds the current view; otherwise, if
    // a zoom is heading toward a level boundary, PREFETCH that level so the
    // crossing is a cache hit. Rebuilds target the camera's TARGET zoom (where
    // the gesture is heading), not the eased position — on hardware where a
    // build takes seconds, building for the zoom being left behind lands stale
    // and the view outruns its coverage into NODATA. The prefetch is skipped on
    // such hardware too: it occupies the one worker for seconds exactly when a
    // real rebuild is about to be needed.
    /// Zoom levels the camera may run past the deepest servable data.
    const OVERSCALE_ALLOW = 2.0;
    const PREFETCH_MAX_BUILD_MS = 600;
    const FAIL_BACKOFF_MS = 400;
    /// OS memory warning: drop what can be rebuilt. Engine caches go at the
    /// next safe point (between builds); the CPU-side scene copy stays (it IS
    /// the picture).
    pub fn memoryWarning(self: *Lookout) void {
        self.trim_requested = true;
    }

    fn tickBuild(self: *Lookout) void {
        self.ensureAtlases(); // before any worker reads atlas_scale
        self.pollBuild();
        if (self.build_active) return;
        if (self.trim_requested) {
            self.trim_requested = false;
            cc.tile57_trim_caches(); // safe: no build in flight
            std.debug.print("memory warning: engine caches trimmed\n", .{});
        }
        if (self.last_fail_ms != 0 and gpu.ticksMs() - self.last_fail_ms < FAIL_BACKOFF_MS) return;
        if (self.dirty or self.needsRebuild()) {
            self.spawnBuild(self.jobFor(self.cam.center, self.buildTargetZoom(), false));
        } else if (self.last_build_ms.load(.monotonic) < PREFETCH_MAX_BUILD_MS) {
            if (self.predictPrefetchLevel()) |lvl| {
                if (lvl != self.prefetched_level) {
                    self.prefetched_level = lvl;
                    self.spawnBuild(self.jobFor(self.cam.center, @floatFromInt(lvl), true));
                }
            }
        }
    }

    // Zoom-velocity heuristic: if zooming and within ~0.35 of the boundary where
    // round(zoom) changes, return the level being approached (clamped to what the
    // engine serves) so it can be prefetched. Null when not zooming toward one.
    fn predictPrefetchLevel(self: *Lookout) ?i32 {
        const now: i64 = gpu.ticksMs();
        const dz = self.cam.zoom - self.last_zoom;
        const recent = self.last_zoom >= 0 and now - self.last_zoom_ms < 250;
        if (!recent or @abs(dz) < 0.01) return null;
        // The next integer level in the zoom direction, and how far the boundary
        // (X.5) is. round() flips at .5, so distance to the flip:
        const bz = self.buildZoom();
        const frac = bz - @floor(bz);
        const to_boundary = if (dz > 0) 0.5 - frac else frac - 0.5;
        if (to_boundary <= 0 or to_boundary > 0.35) return null;
        const next: f64 = @round(bz) + (if (dz > 0) @as(f64, 1) else -1);
        const lvl = std.math.clamp(next, self.cam.min_zoom, self.engine_max_zoom);
        return @intFromFloat(lvl);
    }

    fn ensureBuilt(self: *Lookout) void {
        if (self.dirty or self.needsRebuild()) self.buildGpuScene();
    }

    // The frame uniform: absolute-world MVP (the engine hands world [0,1]), the
    // live gates, and the pattern phase anchor (framebuffer px of the coverage
    // origin, a world-fixed point between rebuilds so patterns don't swim).
    fn uniforms(self: *Lookout) gpu.Uniforms {
        const rsc = self.cam.rotSinCos();
        const d = self.g.pixel_density;
        const a = self.cam.worldToScreen(self.cov_origin);
        // Every field spelled out: the block is the engine's C type now, and a C
        // struct carries no Zig defaults — an omitted field would be undefined,
        // not the zero it used to be.
        return .{
            .mvp = self.cam.mvpOrigin(.{ .x = 0, .y = 0 }),
            .px_to_clip = self.cam.pxToClip(),
            .size_scale = self.render_size_scale,
            .current_scale = self.cam.displayScale(),
            .cat_mask = self.cat_mask,
            .wrap_x = @floatCast(self.cam.center.x),
            .rot_sin = rsc[0],
            .rot_cos = rsc[1],
            .color = .{ 0, 0, 0, 1 }, // per-SDF-range; the backends overwrite it
            .anchor_px = .{ @as(f32, @floatCast(a.x)) * d, @as(f32, @floatCast(a.y)) * d },
            .cell_px = .{ 1, 1 }, // per-pattern-range, likewise
        };
    }

    /// Render one frame to the window and present.
    /// The pulse drawn while a chart library is opening; true means still loading.
    fn loadingPulse(self: *Lookout) bool {
        if (!self.loading) return false;
        self.pollCompose(false);
        if (!self.loading) return false;
        const ph = @as(f32, @floatFromInt(@mod(gpu.ticksMs(), 1600))) / 1600.0;
        const p = 0.14 + 0.10 * @abs(1.0 - 2.0 * ph);
        self.g.clear = .{ .r = p * 0.6, .g = p * 0.8, .b = p, .a = 1.0 };
        self.g.freeScene();
        return true;
    }

    /// Per-frame setup before the draw (drawable size, zoom clamps, scene,
    /// pattern scale). Shared by the surface and texture paths.
    fn prepareFrame(self: *Lookout) void {
        // The GPU layer adopts the real swapchain drawable size at acquire (a
        // wrapped native view can be laid out or rescaled behind our back) —
        // follow it here so the camera's logical viewport always matches what
        // is actually on screen. Force a full REBUILD, not just a redraw: a
        // scene uploaded while the drawable was mid-transition (full screen)
        // can be lost with the old swapchain, and its coverage would otherwise
        // satisfy the settled view forever, leaving a blank chart.
        const lw, const lh = self.logicalSize();
        if (self.cam.vw != lw or self.cam.vh != lh) {
            self.cam.vw = lw;
            self.cam.vh = lh;
            self.dirty = true;
            self.markDirty();
        }
        // Draw state around a swapchain recreation is unreliable on the macOS
        // stack (a scene built/uploaded then can verify byte-perfect on the GPU
        // yet rasterize nothing) — keep rebuilding until safely past it; the
        // first post-window build displays and ends the churn.
        if (gpu.ticksMs() - self.g.size_changed_ms < 1500) {
            self.dirty = true;
            self.markDirty();
        }
        // Refresh the zoom clamps for the current view centre each frame (cheap):
        // panning into a coarser area lowers the per-view max and eases the zoom in.
        self.updateZoomLimits();
        if (@abs(self.cam.zoom - self.last_zoom) > 1e-6) self.last_zoom_ms = gpu.ticksMs();
        if (!self.built) {
            self.buildGpuScene(); // first frame: synchronous, so there is something to draw now
        } else {
            self.tickBuild(); // subsequent rebuilds run on the worker; prefetch warms the next level
        }
        self.last_zoom = self.cam.zoom;
        // Pattern cells track the geometry through a zoom (the scene is tessellated
        // at cov_zoom; the MVP renders it at cam.zoom): scale the cell by the same
        // factor so a constant-screen fill doesn't swim mid-zoom.
        self.g.pattern_scale = @floatCast(std.math.pow(f64, 2.0, self.cam.zoom - self.cov_zoom));
    }

    pub fn render(self: *Lookout) !bool {
        self.ensureAtlases();
        if (self.loadingPulse()) return self.g.renderWindow(self.uniforms(), false, false);
        self.prepareFrame();
        const ok = try self.g.renderWindow(self.uniforms(), self.text_on, self.sound_on);
        // A SKIPPED frame (swapchain saturated) must not clear the flag: the
        // pending content still needs a successful present.
        if (ok) self.view_dirty = false;
        return ok;
    }

    /// The core-owned composition swapchain (d3d12 backend; null elsewhere).
    pub fn d3d12Swapchain(self: *Lookout) ?*anyopaque {
        if (!@hasDecl(gpu.Gpu, "swapchainPtr")) return null;
        return self.g.swapchainPtr();
    }

    /// True while the view needs another frame (state changed, building, loading).
    pub fn needsRedraw(self: *Lookout) bool {
        // The camera lagging the (just-adopted) drawable size counts as dirty:
        // the adopt lands mid-render, AFTER that frame's camera sync, and the
        // host loop may go idle before the next one — without this the resync
        // (and the rebuild it forces) would never run.
        const lw, const lh = self.logicalSize();
        if (self.cam.vw != lw or self.cam.vh != lh) return true;
        return self.loading or self.view_dirty or !self.built or self.build_active or self.dirty or self.needsRebuild();
    }
    pub fn isBuilding(self: *Lookout) bool {
        return self.loading or self.build_active;
    }

    /// Render offscreen and write a PNG.
    pub fn snapshotPng(self: *Lookout, path: []const u8) !void {
        self.pollCompose(true);
        self.buildGpuScene();
        const px = try self.g.renderOffscreen(self.alloc, self.uniforms(), self.text_on, self.sound_on);
        defer self.alloc.free(px);
        try png.write(self.alloc, path, px, self.g.width, self.g.height);
    }
    /// Render offscreen into a caller RGBA8 buffer (len must be width*height*4).
    pub fn snapshotRgba(self: *Lookout, dst: []u8) !void {
        self.pollCompose(true);
        self.buildGpuScene();
        const px = try self.g.renderOffscreen(self.alloc, self.uniforms(), self.text_on, self.sound_on);
        defer self.alloc.free(px);
        if (dst.len < px.len) return error.BufferTooSmall;
        @memcpy(dst[0..px.len], px);
    }

    // ---- pick (tap-to-identify) --------------------------------------------
    /// S-52 §10.8 cursor pick at a geographic point: `cb.feature` fires once per
    /// feature under it (class acronym + full S-57 attribute JSON + source cell).
    /// Live overscale factor: 2^(zoom - deepest servable zoom at the centre),
    /// clamped to >= 1. 1.0 = at or under the data's scale.
    pub fn overscale(self: *Lookout) f64 {
        const over = self.cam.zoom - self.viewMaxZoom();
        return if (over <= 0) 1.0 else std.math.exp2(over);
    }

    pub fn pick(self: *Lookout, lon: f64, lat: f64, cb: *const cc.tile57_query_cb) void {
        self.engine_mu.lock();
        defer self.engine_mu.unlock();
        var err: cc.tile57_error = undefined;
        if (self.compose) |c| {
            _ = cc.tile57_compose_query(c, lon, lat, self.cam.zoom, cb, &err);
        } else {
            _ = cc.tile57_chart_query(self.charts.items[0], lon, lat, self.cam.zoom, cb, &err);
        }
    }

    // ---- convenience live toggles (mutate mariner, apply live) --------------
    pub fn cycleScheme(self: *Lookout) void {
        const order = [_]Scheme{ cc.TILE57_SCHEME_DAY, cc.TILE57_SCHEME_DUSK, cc.TILE57_SCHEME_NIGHT };
        var idx: usize = 0;
        for (order, 0..) |s, i| if (s == self.mariner.scheme) {
            idx = i;
        };
        self.mariner.scheme = order[(idx + 1) % order.len];
        self.dirty = true; // a new palette is a fresh scene (colours are per-range)
        self.deriveLive();
    }
    pub fn toggleText(self: *Lookout) void {
        const on = self.mariner.text_names or self.mariner.show_light_descriptions or self.mariner.text_other;
        self.mariner.text_names = !on;
        self.mariner.show_light_descriptions = !on;
        self.mariner.text_other = !on;
        self.deriveLive();
    }
    pub fn toggleSoundings(self: *Lookout) void {
        self.mariner.soundings = if (self.sound_on) 2 else 1;
        self.deriveLive();
    }
    pub fn toggleOtherCategory(self: *Lookout) void {
        self.mariner.display_other = !self.mariner.display_other;
        self.deriveLive();
    }
    /// Flip depth labels/soundings between metres and feet. Portrayal-affecting
    /// (the engine swaps the sounding glyph + SAFCON01 unit), so it re-portrays.
    pub fn toggleDepthUnit(self: *Lookout) void {
        self.mariner.depth_unit = if (self.mariner.depth_unit == cc.TILE57_DEPTH_FEET)
            cc.TILE57_DEPTH_METERS
        else
            cc.TILE57_DEPTH_FEET;
        self.dirty = true; // sym_s vs sym_s_ft, metres vs feet contour labels
        self.markDirty();
    }
    pub fn nudgeSafetyContour(self: *Lookout, delta: f64) void {
        self.mariner.safety_contour = std.math.clamp(self.mariner.safety_contour + delta, 0, 200);
        self.dirty = true; // geometry-affecting -> fresh scene
        self.markDirty();
    }
    pub fn adjustSize(self: *Lookout, factor: f32) void {
        self.render_size_scale *= factor;
        self.dirty = true; // sizes are baked into the geometry
        self.markDirty();
    }
};

/// True if changing from `a` to `b` alters what the engine emits (needs a
/// rebuild). Visibility-only fields (scheme, categories, text, soundings, size)
/// are excluded — those apply live.
fn marinerNeedsRebuild(a: Mariner, b: Mariner) bool {
    return a.shallow_contour != b.shallow_contour or a.safety_contour != b.safety_contour or
        a.deep_contour != b.deep_contour or a.safety_depth != b.safety_depth or
        a.four_shade_water != b.four_shade_water or a.depth_unit != b.depth_unit or
        a.data_quality != b.data_quality or a.show_inform_callouts != b.show_inform_callouts or
        a.show_meta_bounds != b.show_meta_bounds or a.show_isolated_dangers_shallow != b.show_isolated_dangers_shallow or
        a.boundary_style != b.boundary_style or a.simplified_points != b.simplified_points or
        a.show_full_sector_lines != b.show_full_sector_lines or a.date_dependent != b.date_dependent or
        a.highlight_date_dependent != b.highlight_date_dependent or
        !std.mem.eql(u8, &a.date_view, &b.date_view) or a.ignore_scamin != b.ignore_scamin or
        a.viewing_groups_off != b.viewing_groups_off or a.viewing_groups_off_len != b.viewing_groups_off_len or
        a.scamin_filter_gate != b.scamin_filter_gate or a.show_overscale != b.show_overscale or
        a.text_size_scale != b.text_size_scale or a.sounding_size_scale != b.sounding_size_scale;
}

test "camera roundtrip" {
    const w = camera.lonLatToWorld(-76.48, 38.98);
    const ll = camera.worldToLonLat(w);
    try std.testing.expectApproxEqAbs(@as(f64, -76.48), ll.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 38.98), ll.y, 1e-9);
}
