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
const cc = @import("c.zig").c;
const scene = @import("scene.zig");
const gpu = @import("gpu.zig");
const camera = @import("camera.zig");
const atlas = @import("atlas.zig");
const png = @import("png.zig");

pub const Mariner = cc.tile57_mariner;
pub const Scheme = cc.tile57_scheme;

const vert_spv = @embedFile("chart_vert_spv");
const frag_spv = @embedFile("chart_frag_spv");
const sprite_vert_spv = @embedFile("sprite_vert_spv");
const sprite_frag_spv = @embedFile("sprite_frag_spv");
const sdf_frag_spv = @embedFile("sdf_frag_spv");

// shader-kind bits (match chart.vert / scene.zig class numbering)
const KIND_SOUNDING: u5 = 3;
const KIND_TEXT: u5 = 4;

/// A camera pose. rotation_deg is course-up rotation (0 = north-up).
pub const View = struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 = 0 };

const TileEntry = struct { bufs: gpu.Gpu.TileBuffers, origin: camera.Vec2, last_used: u64 };
const TILE_CAP = 512; // resident tile ceiling (LRU-evicted)
const TILE_BUDGET = 6; // new tiles tessellated per frame (progressive fill)
const MAX_TILE_SPAN = 40; // clamp visible grid so an extreme zoom-out can't explode

/// Base mariner for a build: the user's state, but with the live-gated axes
/// forced permissive so EVERY feature reaches the surface tagged, then gated
/// per-frame in the shader (NOTES.md §3). Geometry-affecting fields (contours,
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

fn hexColor(s: []const u8) ?cc.SDL_FColor {
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
    /// optional ownership-partition sidecar. If it exists, compose loads it
    /// (skips the O(charts) partition build); if not, lookout builds and SAVES it
    /// here for next time. Point this somewhere per chart-library.
    partition_path: ?[:0]const u8 = null,
    /// EMBED into a host's native window (NSWindow / HWND / X11 …). lookout
    /// wraps it with SDL internally and renders/presents into it — the host uses
    /// its own toolkit (Swift/Cocoa, Win32, GTK) and never links SDL. Then just
    /// call render() each frame and feed input via pan/zoom/setView/resize.
    native_handle: ?*anyopaque = null,
    native_kind: gpu.NativeKind = .none,
};

pub const NativeKind = gpu.NativeKind;

pub const Lookout = struct {
    alloc: std.mem.Allocator,
    charts: std.ArrayList(*cc.tile57_chart) = .empty, // 1 (single) or many (composed)
    compose: ?*cc.tile57_compose = null, // set when >1 chart (ENC_ROOT / library)
    g: gpu.Gpu,
    built: bool = false, // GPU buffers hold a current scene (CPU geometry freed)

    // The ownership-partition build (compose_open over the whole library) is slow
    // — run it on a worker thread and show a loader so the window isn't frozen.
    loading: bool = false,
    compose_thread: ?std.Thread = null,
    compose_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    compose_result: ?*cc.tile57_compose = null,

    // async build: tessellation (CPU) runs on a worker thread so the window
    // stays responsive; the main thread uploads the result. The OLD scene keeps
    // rendering until the new one is ready (only the first build shows blank).
    build_thread: ?std.Thread = null,
    building: bool = false,
    build_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pending: ?scene.Scene = null,
    pending_origin: camera.Vec2 = .{ .x = 0, .y = 0 },
    job: BuildJob = undefined,
    // coverage of the currently-built (overscanned) scene: rebuild only when the
    // view pans/zooms out of this, so panning within the margin never re-tessellates.
    cov_origin: camera.Vec2 = .{ .x = 0, .y = 0 },
    cov_zoom: f64 = 0,
    cov_hw: f64 = 0, // half-width / half-height of coverage, world units
    cov_hh: f64 = 0,
    view_dirty: bool = true, // camera/state changed since the last render (on-demand)
    labels_dirty: bool = true, // view moved: the decluttered label set is stale
    label_origin: camera.Vec2 = .{ .x = 0, .y = 0 }, // world origin the label quads are relative to
    label_zoom: f64 = -1, // camera zoom the label set was decluttered for
    last_change_ms: i64 = 0, // when the view last moved (debounce rebuilds during a gesture)
    cam: camera.Camera,
    schemes: [scene.MAX_SCHEMES]Scheme = undefined,
    n_schemes: usize = 0,

    /// The authoritative S-52 display state. Edit via get/setMariner.
    mariner: Mariner = undefined,
    dirty: bool = true, // scene needs a (re)build before the next render
    partition_path: ?[:0]const u8 = null,
    sprite_atlas: ?atlas.SpriteAtlas = null, // shared S-52 symbol atlas
    glyph_atlas: ?atlas.GlyphAtlas = null, // shared SDF label-font atlas
    engine_max_zoom: f64 = 24, // deepest zoom the chart/compositor serves; beyond
    //                            it we overscale (build stays here, camera scales up)

    // Tile cache: each (z,x,y) tile is composed + tessellated ONCE and cached, so
    // pan/zoom only builds newly-exposed tiles (tile57 memoizes the compose).
    tiles: std.AutoHashMapUnmanaged(u64, TileEntry) = .empty,
    frame_ctr: u64 = 0,

    // derived live (uniform-only) state
    active_scheme: usize = 0,
    cat_mask: u32 = 0b111,
    kind_mask: u32 = 0b11111,
    render_size_scale: f32 = 1.0,
    nodata: [scene.MAX_SCHEMES]cc.SDL_FColor = [_]cc.SDL_FColor{.{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 }} ** scene.MAX_SCHEMES,

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
        const t0 = cc.SDL_GetPerformanceCounter();
        for (paths) |p| self.addChartPath(p);
        const t1 = cc.SDL_GetPerformanceCounter();
        try self.finishOpen();
        const t2 = cc.SDL_GetPerformanceCounter();
        const f: f64 = @floatFromInt(cc.SDL_GetPerformanceFrequency());
        std.debug.print("open: {d} charts opened in {d:.0} ms, compose+partition in {d:.0} ms\n", .{ self.charts.items.len, @as(f64, @floatFromInt(t1 - t0)) * 1000 / f, @as(f64, @floatFromInt(t2 - t1)) * 1000 / f });
        return self;
    }

    fn create(alloc: std.mem.Allocator, opts: OpenOptions) !*Lookout {
        cc.tile57_warmup();
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
            }, vert_spv, frag_spv, sprite_vert_spv, sprite_frag_spv, sdf_frag_spv),
            .cam = undefined,
        };
        self.n_schemes = @min(opts.schemes.len, scene.MAX_SCHEMES);
        for (0..self.n_schemes) |i| self.schemes[i] = opts.schemes[i];
        self.partition_path = opts.partition_path;
        cc.tile57_mariner_defaults(&self.mariner);
        self.loadNodataColors();
        self.loadSpriteAtlas();
        self.loadGlyphAtlas();
        return self;
    }

    // Bake the SDF label-glyph atlas, decode, upload once. Text then draws as SDF
    // quads (crisp at any zoom) instead of tessellated glyph outlines.
    fn loadGlyphAtlas(self: *Lookout) void {
        var assets: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
        var err: cc.tile57_error = undefined;
        if (cc.tile57_bake_glyph_sdf(&assets, &err) != cc.TILE57_OK) return;
        defer cc.tile57_assets_free(&assets);
        if (assets.sprite_png == null or assets.sprite_json == null) return;
        const a = atlas.loadGlyph(self.alloc, assets.sprite_png[0..assets.sprite_png_len], assets.sprite_json[0..assets.sprite_json_len]) catch return;
        self.glyph_atlas = a;
        self.g.uploadGlyphAtlas(a.rgba(), a.width, a.height) catch {
            self.glyph_atlas.?.deinit();
            self.glyph_atlas = null;
            return;
        };
        std.debug.print("glyph atlas: {d}x{d}, {d} glyphs, em {d:.0}\n", .{ a.width, a.height, a.glyphs.count(), a.em_px });
    }

    // Bake the S-52 sprite-symbol atlas (from the embedded catalogue), decode it,
    // and upload it once. Symbols/soundings then draw as textured quads.
    fn loadSpriteAtlas(self: *Lookout) void {
        var assets: cc.tile57_assets = std.mem.zeroes(cc.tile57_assets);
        var err: cc.tile57_error = undefined;
        if (cc.tile57_bake_sprite_mln(null, &assets, &err) != cc.TILE57_OK) return;
        defer cc.tile57_assets_free(&assets);
        if (assets.sprite_png == null or assets.sprite_json == null) return;
        const png_bytes = assets.sprite_png[0..assets.sprite_png_len];
        const json = assets.sprite_json[0..assets.sprite_json_len];
        const a = atlas.loadSprite(self.alloc, png_bytes, json) catch return;
        self.sprite_atlas = a;
        self.g.uploadSpriteAtlas(a.rgba(), a.width, a.height) catch {
            self.sprite_atlas.?.deinit();
            self.sprite_atlas = null;
            return;
        };
        std.debug.print("sprite atlas: {d}x{d}, {d} cells\n", .{ a.width, a.height, a.cells.count() });
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
        const had_partition = if (self.partition_path) |p| fileExists(p) else false;
        const part: [*c]const u8 = if (self.partition_path) |p| p.ptr else null;
        if (cc.tile57_compose_open(self.charts.items.ptr, self.charts.items.len, part, &c, &err) == cc.TILE57_OK and c != null) {
            self.compose_result = c;
            if (self.partition_path) |p| {
                if (!had_partition) _ = cc.tile57_compose_save_partition(c.?, p.ptr, &err);
            }
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
            self.updateZoomLimits(); // refresh the zoom band; DON'T touch the view
            std.debug.print("composed {d} charts\n", .{self.charts.items.len});
        }
    }

    // No zooming out below the coarsest band (bounds tessellation); allow zoom-in
    // past the deepest band as overscale.
    fn updateZoomLimits(self: *Lookout) void {
        const OVERSCALE_LEVELS = 4.0;
        const zr = self.zoomRange();
        self.engine_max_zoom = zr[1];
        self.cam.min_zoom = zr[0];
        self.cam.max_zoom = zr[1] + OVERSCALE_LEVELS;
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
        self.dropTiles();
        self.tiles.deinit(self.alloc);
        if (self.sprite_atlas) |*sa| sa.deinit();
        if (self.glyph_atlas) |*ga| ga.deinit();
        self.g.deinit();
        if (self.compose) |c| cc.tile57_compose_close(c); // BEFORE the charts
        for (self.charts.items) |ch| cc.tile57_chart_close(ch);
        self.charts.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    // Dispatch over the active surface source (single chart or compositor) for an
    // explicit view — no cam/g reads, so the worker thread can call it.
    fn callSurfaceAt(self: *Lookout, lon: f64, lat: f64, zoom: f64, w: u32, h: u32, cb: *const cc.tile57_surface_cb, m: *cc.tile57_mariner, err: *cc.tile57_error) cc.tile57_status {
        if (self.compose) |c|
            return cc.tile57_compose_surface(c, lon, lat, zoom, 0.0, w, h, m, cb, err);
        return cc.tile57_chart_surface(self.charts.items[0], lon, lat, zoom, 0.0, w, h, m, cb, err);
    }

    // ---- view ---------------------------------------------------------------
    fn viewToCamera(v: View, w: f32, h: f32) camera.Camera {
        const o = camera.lonLatToWorld(v.lon, v.lat);
        return .{ .origin = o, .center = o, .zoom = v.zoom, .rotation = v.rotation_deg * std.math.pi / 180.0, .vw = w, .vh = h };
    }

    /// A BOUNDED opening view. Deliberately the first cell's own bounds, NOT the
    /// union of a whole library — fitting a big composite would tessellate the
    /// entire library into one gigantic scene. Pan/zoom reaches the rest.
    pub fn fitChart(self: *Lookout) View {
        var west: f64 = 0;
        var south: f64 = 0;
        var east: f64 = 0;
        var north: f64 = 0;
        var has_bounds = false;
        var min_zoom: u8 = 0;
        var max_zoom: u8 = 22;
        {
            var info: cc.tile57_info = undefined;
            cc.tile57_chart_get_info(self.charts.items[0], &info);
            if (info.has_bounds) {
                west = info.west;
                south = info.south;
                east = info.east;
                north = info.north;
                min_zoom = info.min_zoom;
                max_zoom = info.max_zoom;
                has_bounds = true;
            } else if (info.has_anchor) {
                return .{ .lon = info.anchor_lon, .lat = info.anchor_lat, .zoom = info.anchor_zoom };
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
        self.markDirty();
    }
    pub fn view(self: *Lookout) View {
        const ll = camera.worldToLonLat(self.cam.center);
        return .{ .lon = ll.x, .lat = ll.y, .zoom = self.cam.zoom, .rotation_deg = self.cam.rotation * 180.0 / std.math.pi };
    }

    /// Resize the render surface (points; HiDPI density is applied internally).
    pub fn resize(self: *Lookout, width: u32, height: u32) !void {
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
        const d = if (self.g.pixel_density > 0) self.g.pixel_density else 1.0;
        return .{ @as(f32, @floatFromInt(self.g.width)) / d, @as(f32, @floatFromInt(self.g.height)) / d };
    }
    pub fn pixelDensity(self: *Lookout) f32 {
        return self.g.pixel_density;
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
        self.cam.zoomAbout(dzoom, x_pt, y_pt);
        self.markDirty();
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
        // Tiles capture only the active palette now, so a scheme change also
        // needs a rebuild (not just geometry-affecting fields).
        if (self.mariner.scheme != m.scheme or marinerNeedsRebuild(self.mariner, m)) self.dropTiles();
        self.mariner = m;
        self.deriveLive();
    }

    fn deriveLive(self: *Lookout) void {
        self.active_scheme = 0; // tiles hold only the active palette at index 0
        // display categories -> cat_mask
        self.cat_mask = (@as(u32, @intFromBool(self.mariner.display_base)) << 0) |
            (@as(u32, @intFromBool(self.mariner.display_standard)) << 1) |
            (@as(u32, @intFromBool(self.mariner.display_other)) << 2);
        // kinds: area/line/symbol always on; text + soundings gated
        const text_on = self.mariner.text_names or self.mariner.show_light_descriptions or self.mariner.text_other;
        const sound_on = self.mariner.soundings == 1 or (self.mariner.soundings == 0 and self.mariner.display_other);
        self.kind_mask = 0b111 |
            (@as(u32, @intFromBool(text_on)) << KIND_TEXT) |
            (@as(u32, @intFromBool(sound_on)) << KIND_SOUNDING);
        self.render_size_scale = if (self.mariner.size_scale == 0) 1.0 else @floatCast(self.mariner.size_scale);
        const si: usize = @min(@as(usize, @intCast(self.mariner.scheme)), scene.MAX_SCHEMES - 1);
        self.g.clear = self.nodata[si]; // background NODATA follows the palette
        self.markDirty();
    }

    // ---- build + render -----------------------------------------------------
    // Mirror chartplotter-fyne's model: tessellate a scene that OVERSCANS the
    // viewport, then only re-tessellate when the view pans/zooms out of that
    // coverage. Panning within the margin re-transforms the same buffers.
    // Overscan must exceed 2^ZOOM_REBUILD (a zoom-out of ZOOM_REBUILD grows the
    // view by that factor) so the margin still covers the view when the rebuild
    // is due — otherwise the edges go NODATA before it lands.
    const OVERSCAN = 1.25; // scene covers 1.25x the viewport (interim; tile cache supersedes)
    const ZOOM_REBUILD = 0.3; // zoom drift that forces a fresh build (2^0.3 < OVERSCAN)
    const SETTLE_MS = 120; // debounce ZOOM rebuilds (pan rebuilds are prompt)

    // The immutable inputs a build needs — captured at spawn so the worker never
    // races the main thread's live camera / mariner edits.
    pub const BuildJob = struct {
        origin: camera.Vec2 = .{ .x = 0, .y = 0 },
        zoom: f64 = 0,
        width: u32 = 0, // OVERSCANNED pixel size the surface is emitted for
        height: u32 = 0,
        base: Mariner = undefined,
    };

    // Pure-CPU tessellation into `s` for the given job — no GPU, no cam/g reads,
    // so it is safe to run on a worker thread.
    fn tessellateInto(self: *Lookout, s: *scene.Scene, job: BuildJob) !void {
        const t_start = cc.SDL_GetPerformanceCounter();
        const lon = camera.worldToLonLat(job.origin).x;
        const lat = camera.worldToLonLat(job.origin).y;
        // Only tessellate features that SCAMIN-show at this zoom — a zoomed-out
        // build then tessellates coarse features, not the whole library's detail.
        s.cull_scale = camera.displayScaleAt(job.zoom, lat);
        s.sprite_atlas = if (self.sprite_atlas) |*sa| sa else null;
        var err: cc.tile57_error = undefined;
        s.scheme_k = 0;
        var m0 = buildMarinerFrom(job.base, self.schemes[0]);
        const full = scene.fullTable(s);
        if (self.callSurfaceAt(lon, lat, job.zoom, job.width, job.height, &full, &m0, &err) != cc.TILE57_OK)
            return error.SurfaceFailed;
        for (1..self.n_schemes) |k| {
            s.scheme_k = k;
            s.color_counter = 0;
            var mk = buildMarinerFrom(job.base, self.schemes[k]);
            const ct = scene.colorTable(s);
            _ = self.callSurfaceAt(lon, lat, job.zoom, job.width, job.height, &ct, &mk, &err);
            if (s.color_counter != s.items.items.len) {
                for (s.items.items) |*it| it.colors[k] = it.colors[0];
            }
        }
        try s.finish(self.n_schemes);
        const total = cc.SDL_GetPerformanceCounter() - t_start;
        const freq: f64 = @floatFromInt(cc.SDL_GetPerformanceFrequency());
        const total_ms = @as(f64, @floatFromInt(total)) * 1000.0 / freq;
        const tess_ms = @as(f64, @floatFromInt(s.tess_ns)) * 1000.0 / freq;
        std.debug.print("build z{d:.1}: {d} tris, {d:.0} ms total ({d:.0} ms libtess2 / {d:.0} ms engine+other)\n", .{ job.zoom, s.triangleCount(), total_ms, tess_ms, total_ms - tess_ms });
    }

    // The zoom to BUILD at — the camera zoom, clamped to the deepest band the
    // engine serves. Zooming in past that keeps this fixed (overscale): the
    // camera scales the deepest-band geometry up, and the engine's overscale
    // hatch (mariner.show_overscale) shows.
    fn buildZoom(self: *Lookout) f64 {
        return @min(self.cam.zoom, self.engine_max_zoom);
    }

    fn jobFromCurrent(self: *Lookout) BuildJob {
        const ow: u32 = @intFromFloat(@as(f64, @floatFromInt(self.g.width)) * OVERSCAN);
        const oh: u32 = @intFromFloat(@as(f64, @floatFromInt(self.g.height)) * OVERSCAN);
        return .{ .origin = self.cam.center, .zoom = self.buildZoom(), .width = ow, .height = oh, .base = self.mariner };
    }

    // Record the coverage of the scene just built, so needsRebuild can tell when
    // the view has left it.
    fn recordCoverage(self: *Lookout, job: BuildJob) void {
        const wp = camera.Camera.worldToPx(.{ .origin = job.origin, .center = job.origin, .zoom = job.zoom, .vw = 1, .vh = 1 });
        self.cov_origin = job.origin;
        self.cov_zoom = job.zoom;
        self.cov_hw = @as(f64, @floatFromInt(job.width)) * 0.5 / wp;
        self.cov_hh = @as(f64, @floatFromInt(job.height)) * 0.5 / wp;
    }

    // Mark the view/state changed (for on-demand rendering) and stamp the time so
    // rebuilds debounce until the gesture stops.
    fn markDirty(self: *Lookout) void {
        self.view_dirty = true;
        self.labels_dirty = true;
        self.last_change_ms = @as(i64, @intCast(cc.SDL_GetTicks()));
    }

    // True when the current view has panned/zoomed out of the built coverage.
    fn needsRebuild(self: *Lookout) bool {
        if (!self.built) return true;
        // compare the BUILD zoom (clamped for overscale) so overzooming past the
        // deepest band doesn't churn rebuilds.
        if (@abs(self.buildZoom() - self.cov_zoom) > ZOOM_REBUILD) return true;
        const he = self.cam.halfExtents();
        return @abs(self.cam.center.x - self.cov_origin.x) + he.x > self.cov_hw or
            @abs(self.cam.center.y - self.cov_origin.y) + he.y > self.cov_hh;
    }

    /// Force all currently-visible tiles to be built now (synchronous).
    pub fn build(self: *Lookout) !void {
        self.pollCompose(true);
        self.buildAllVisible();
        self.buildLabels();
    }
    /// Drop all cached tiles (e.g. after a mariner change that alters geometry).
    fn dropTiles(self: *Lookout) void {
        var it = self.tiles.iterator();
        while (it.next()) |e| self.g.freeTileBuffers(&e.value_ptr.bufs);
        self.tiles.clearRetainingCapacity();
    }

    fn buildWorker(self: *Lookout) void {
        var s = scene.Scene.init(self.alloc, self.job.origin) catch {
            self.build_done.store(true, .release);
            return;
        };
        self.tessellateInto(&s, self.job) catch {
            s.deinit();
            self.pending = null;
            self.build_done.store(true, .release);
            return;
        };
        self.pending = s;
        self.build_done.store(true, .release); // publishes `pending` to the main thread
    }

    fn spawnBuild(self: *Lookout) void {
        self.job = self.jobFromCurrent();
        self.pending_origin = self.job.origin;
        self.building = true;
        self.build_done.store(false, .release);
        self.build_thread = std.Thread.spawn(.{}, buildWorker, .{self}) catch {
            self.building = false;
            self.build() catch {}; // fall back to a synchronous build
            return;
        };
    }

    fn joinBuild(self: *Lookout) void {
        if (self.build_thread) |t| {
            t.join();
            self.build_thread = null;
        }
        self.building = false;
        if (self.pending) |*ps| {
            ps.deinit();
            self.pending = null;
        }
    }

    // Advance the async build (call once per frame). Non-blocking.
    fn tick(self: *Lookout) void {
        if (self.loading) {
            self.pollCompose(false);
            if (self.loading) return; // still building the partition — show loader
        }
        if (self.building) {
            if (!self.build_done.load(.acquire)) return; // still tessellating
            if (self.build_thread) |t| {
                t.join();
                self.build_thread = null;
            }
            self.building = false;
            if (self.pending) |*ps| {
                self.cam.origin = self.pending_origin;
                self.g.releaseSceneBuffers();
                self.g.uploadScene(ps) catch {};
                ps.deinit();
                self.pending = null;
                self.built = true;
                self.dirty = false;
                self.recordCoverage(self.job);
            }
            return;
        }
        // Rebuild promptly whenever the view leaves coverage (pan OR zoom) — the
        // old scene keeps rendering (stretched) until the async build lands, so
        // there's no freeze, and the blank leading edge fills as fast as a build.
        if (!self.built or self.dirty or self.needsRebuild()) self.spawnBuild();
    }

    fn ensureBuilt(self: *Lookout) !void {
        if (self.dirty or self.needsRebuild()) try self.build();
    }

    fn uniformsForOrigin(self: *Lookout, origin: camera.Vec2) gpu.Uniforms {
        const rsc = self.cam.rotSinCos();
        return .{
            .mvp = self.cam.mvpOrigin(origin),
            .px_to_clip = self.cam.pxToClip(),
            // NO density factor: the camera is in logical px and pxToClip spreads
            // those across the full framebuffer, so a 10 logical-px mark already
            // lands on 20 physical px at 2x. Multiplying here too would double it
            // and leave marks oversized against the chart they sit on.
            .size_scale = self.render_size_scale,
            .current_scale = self.cam.displayScale(),
            .cat_mask = self.cat_mask,
            .kind_mask = self.kind_mask,
            .rot_sin = rsc[0],
            .rot_cos = rsc[1],
        };
    }

    // ---- tile cache ---------------------------------------------------------
    const TileRange = struct { z: u8, x0: i64, y0: i64, x1: i64, y1: i64 };

    fn tileZoomInt(self: *Lookout) u8 {
        const z = @round(@min(self.cam.zoom, self.engine_max_zoom));
        return @intFromFloat(std.math.clamp(z, self.cam.min_zoom, self.engine_max_zoom));
    }
    fn visibleRange(self: *Lookout) TileRange {
        const z = self.tileZoomInt();
        const n: f64 = std.math.pow(f64, 2.0, @floatFromInt(z));
        const c = [_]camera.Vec2{ self.cam.screenToWorld(0, 0), self.cam.screenToWorld(self.cam.vw, 0), self.cam.screenToWorld(0, self.cam.vh), self.cam.screenToWorld(self.cam.vw, self.cam.vh) };
        var minx = c[0].x;
        var maxx = c[0].x;
        var miny = c[0].y;
        var maxy = c[0].y;
        for (c[1..]) |p| {
            minx = @min(minx, p.x);
            maxx = @max(maxx, p.x);
            miny = @min(miny, p.y);
            maxy = @max(maxy, p.y);
        }
        const lim = n - 1;
        var r = TileRange{
            .z = z,
            .x0 = @intFromFloat(std.math.clamp(@floor(minx * n), 0, lim)),
            .y0 = @intFromFloat(std.math.clamp(@floor(miny * n), 0, lim)),
            .x1 = @intFromFloat(std.math.clamp(@floor(maxx * n), 0, lim)),
            .y1 = @intFromFloat(std.math.clamp(@floor(maxy * n), 0, lim)),
        };
        if (r.x1 - r.x0 + 1 > MAX_TILE_SPAN) r.x1 = r.x0 + MAX_TILE_SPAN - 1;
        if (r.y1 - r.y0 + 1 > MAX_TILE_SPAN) r.y1 = r.y0 + MAX_TILE_SPAN - 1;
        return r;
    }
    fn keyFor(z: u8, x: i64, y: i64) u64 {
        return (@as(u64, z) << 48) | (@as(u64, @intCast(x)) << 24) | @as(u64, @intCast(y));
    }
    fn tileOriginOf(z: u8, x: i64, y: i64) camera.Vec2 {
        const n = std.math.pow(f64, 2.0, @floatFromInt(z));
        return .{ .x = @as(f64, @floatFromInt(x)) / n, .y = @as(f64, @floatFromInt(y)) / n };
    }

    // Portray ONE tile through the surface callbacks (compose_tile -> render_mlt,
    // or chart_tile_surface). tile57 memoizes the composed/decoded tile.
    fn tileSurface(self: *Lookout, z: u8, x: i64, y: i64, cb: *const cc.tile57_surface_cb, m: *cc.tile57_mariner, err: *cc.tile57_error) void {
        if (self.compose) |c| {
            var mlt: [*c]u8 = null;
            var len: usize = 0;
            var owned = false;
            if (cc.tile57_compose_tile(c, z, @intCast(x), @intCast(y), &mlt, &len, &owned, err) == cc.TILE57_OK and mlt != null and len > 0) {
                _ = cc.tile57_render_mlt_tile(mlt, len, z, @intCast(x), @intCast(y), m, cb, err);
                cc.tile57_free(mlt);
            }
        } else {
            _ = cc.tile57_chart_tile_surface(self.charts.items[0], z, @intCast(x), @intCast(y), m, cb, err);
        }
    }

    fn buildTile(self: *Lookout, z: u8, x: i64, y: i64) TileEntry {
        const origin = tileOriginOf(z, x, y);
        var s = scene.Scene.init(self.alloc, origin) catch return .{ .bufs = .{}, .origin = origin, .last_used = self.frame_ctr };
        defer s.deinit();
        const half = 0.5 / std.math.pow(f64, 2.0, @floatFromInt(z));
        s.cull_scale = camera.displayScaleAt(@floatFromInt(z), camera.worldToLonLat(.{ .x = origin.x + half, .y = origin.y + half }).y);
        s.sprite_atlas = if (self.sprite_atlas) |*sa| sa else null;
        s.glyph_atlas = if (self.glyph_atlas) |*ga| ga else null;
        var err: cc.tile57_error = undefined;
        // Portray ONCE, in the ACTIVE palette (colors captured at index 0). A
        // day/night change drops the cache and rebuilds — 3x cheaper per tile
        // than capturing all three palettes up front.
        s.scheme_k = 0;
        var m0 = buildMarinerFrom(self.mariner, self.mariner.scheme);
        // Tiles carry NO text (it comes from the view-level pass), so tell the
        // engine that: otherwise it shapes and declutters hundreds of labels per
        // tile that we then drop on the floor.
        m0.text_names = false;
        m0.show_light_descriptions = false;
        m0.text_other = false;
        const tbl = scene.tileTable(&s);
        self.tileSurface(z, x, y, &tbl, &m0, &err);
        s.finish(1) catch {};
        const bufs = self.g.uploadTileScene(&s) catch gpu.Gpu.TileBuffers{};
        return .{ .bufs = bufs, .origin = origin, .last_used = self.frame_ctr };
    }

    // Build up to `budget` missing visible tiles; returns how many are still missing.
    fn ensureTiles(self: *Lookout, budget: usize) usize {
        self.frame_ctr += 1;
        const r = self.visibleRange();
        var built: usize = 0;
        var missing: usize = 0;
        var y = r.y0;
        while (y <= r.y1) : (y += 1) {
            var x = r.x0;
            while (x <= r.x1) : (x += 1) {
                const k = keyFor(r.z, x, y);
                if (self.tiles.getPtr(k)) |e| {
                    e.last_used = self.frame_ctr;
                } else if (built < budget) {
                    const e = self.buildTile(r.z, x, y);
                    self.tiles.put(self.alloc, k, e) catch continue;
                    built += 1;
                } else missing += 1;
            }
        }
        self.evictTiles();
        return missing;
    }

    fn evictTiles(self: *Lookout) void {
        while (self.tiles.count() > TILE_CAP) {
            var oldest: u64 = std.math.maxInt(u64);
            var oldest_key: ?u64 = null;
            var it = self.tiles.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.last_used < oldest and e.value_ptr.last_used != self.frame_ctr) {
                    oldest = e.value_ptr.last_used;
                    oldest_key = e.key_ptr.*;
                }
            }
            const k = oldest_key orelse break;
            if (self.tiles.getPtr(k)) |e| self.g.freeTileBuffers(&e.bufs);
            _ = self.tiles.remove(k);
        }
    }

    // ---- view-level labels (S-52 declutter, done by tile57) -----------------
    // A label on a feature that spans tiles would be re-anchored in every tile
    // the feature is clipped into, so per-tile text repeats across seams. The
    // engine resolves the WHOLE view against one collision pool and emits only
    // the survivors, which we lay out here as SDF quads — one buffer, one draw.
    // Labels are world-anchored, so a stale set still renders in the right place
    // while a gesture is in flight; we only re-declutter once the view settles.
    const LABEL_SETTLE_MS = 90;

    fn buildLabels(self: *Lookout) void {
        // Clear FIRST: needsRedraw() keys off labels_dirty, so any early return
        // below would otherwise spin the render loop re-running this every frame.
        self.labels_dirty = false;
        if (self.glyph_atlas == null) return; // no SDF atlas -> no text at all
        const t0 = cc.SDL_GetPerformanceCounter();
        var s = scene.Scene.init(self.alloc, self.cam.center) catch return;
        defer s.deinit();
        s.glyph_atlas = &self.glyph_atlas.?;
        const ll = camera.worldToLonLat(self.cam.center);
        // Clamp like the tiles do: past the deepest band the engine serves we are
        // overscaling, and asking for labels beyond it returns nothing at all.
        const z = self.buildZoom();
        s.cull_scale = camera.displayScaleAt(z, ll.y);
        // Labels are rebuilt on every view change, so they gate at BUILD time --
        // unlike geometry, which is captured permissively and gated live in the
        // shader. That means the mariner's own text and display-category axes
        // must be honoured here verbatim: forcing them permissive (as the tile
        // build does) silently ignores the mariner's text switches and emits
        // every label the catalogue has, which is most of what makes a wide view
        // unreadable. size_scale stays 1.0 -- the runtime size lives in the
        // shader uniform, and letting the engine scale too would double it.
        const lw, const lh = self.logicalSize();
        const vw: u32 = @intFromFloat(@max(1.0, lw));
        const vh: u32 = @intFromFloat(@max(1.0, lh));
        var m0 = self.mariner;
        // Declutter at the size the labels are ACTUALLY DRAWN. The engine sizes a
        // label and its collision box from size_scale (vector.zig textDev), so on
        // a 2x framebuffer, laying out at 1.0 and then drawing at 2.0 throws the
        // pool's spacing away -- every label comes out twice the size of the room
        // reserved for it, and a correctly decluttered view still reads as a mess.
        // The text pass then draws these 1:1 (see labelUniform).
        m0.size_scale = self.render_size_scale;
        const tbl = scene.labelTable(&s);
        var err: cc.tile57_error = undefined;
        const st = if (self.compose) |c|
            cc.tile57_compose_labels(c, ll.x, ll.y, z, self.cam.rotation, vw, vh, &m0, &tbl, &err)
        else if (self.charts.items.len > 0)
            cc.tile57_chart_labels(self.charts.items[0], ll.x, ll.y, z, self.cam.rotation, vw, vh, &m0, &tbl, &err)
        else
            cc.TILE57_OK;
        if (st != cc.TILE57_OK) return; // keep the previous labels rather than blank out
        self.g.uploadLabels(s.text_quads.items) catch return;
        self.label_origin = self.cam.center;
        self.label_zoom = self.cam.zoom;
        const ms = @as(f64, @floatFromInt(cc.SDL_GetPerformanceCounter() - t0)) * 1000.0 / @as(f64, @floatFromInt(cc.SDL_GetPerformanceFrequency()));
        // The trailing args reproduce this exact view on the demo CLI — paste
        // them straight back when a view looks wrong.
        std.debug.print("labels: {d} glyph quads in {d:.0} ms  [--lon {d:.5} --lat {d:.5} --zoom {d:.2} --width {d} --height {d}{s}]\n", .{
            s.text_quads.items.len / 6,
            ms,
            ll.x,
            ll.y,
            z,
            self.g.width,
            self.g.height,
            if (self.cam.rotation != 0) " (rotated)" else "",
        });
    }

    // The uniform the label buffer was built against (its own origin, current camera).
    fn labelUniform(self: *Lookout) ?gpu.Uniforms {
        if (self.g.label_count == 0) return null;
        var u = self.uniformsForOrigin(self.label_origin);
        u.size_scale = 1.0; // already laid out at final size by the label pass
        return u;
    }

    // Labels are world-anchored, so a small nudge leaves them correctly placed —
    // only re-declutter once the view has moved enough that the label DENSITY is
    // wrong or newly-exposed area has none. (A stopgap: the pass is expensive
    // because the engine re-portrays every covering tile per call.)
    const LABEL_ZOOM_STEP = 0.25; // zoom drift that forces a re-declutter
    const LABEL_PAN_FRAC = 0.30; // pan, as a fraction of the viewport half-extent

    fn labelsStale(self: *Lookout) bool {
        if (self.g.label_count == 0) return true;
        if (@abs(self.cam.zoom - self.label_zoom) > LABEL_ZOOM_STEP) return true;
        const he = self.cam.halfExtents();
        return @abs(self.cam.center.x - self.label_origin.x) > he.x * LABEL_PAN_FRAC or
            @abs(self.cam.center.y - self.label_origin.y) > he.y * LABEL_PAN_FRAC;
    }

    // Re-declutter once the gesture has stopped (see LABEL_SETTLE_MS).
    fn labelsSettled(self: *Lookout) bool {
        return @as(i64, @intCast(cc.SDL_GetTicks())) - self.last_change_ms >= LABEL_SETTLE_MS;
    }

    fn collectDraws(self: *Lookout, list: *std.ArrayList(gpu.Gpu.TileDraw)) void {
        list.clearRetainingCapacity();
        const r = self.visibleRange();
        var y = r.y0;
        while (y <= r.y1) : (y += 1) {
            var x = r.x0;
            while (x <= r.x1) : (x += 1) {
                if (self.tiles.getPtr(keyFor(r.z, x, y))) |e| {
                    if (e.bufs.index_count == 0 and e.bufs.quad_count == 0) continue;
                    list.append(self.alloc, .{ .bufs = &e.bufs, .uniform = self.uniformsForOrigin(e.origin) }) catch {};
                }
            }
        }
    }

    fn anyVisibleMissing(self: *Lookout) bool {
        const r = self.visibleRange();
        var y = r.y0;
        while (y <= r.y1) : (y += 1) {
            var x = r.x0;
            while (x <= r.x1) : (x += 1) if (!self.tiles.contains(keyFor(r.z, x, y))) return true;
        }
        return false;
    }

    /// Render one frame to the window. Non-blocking: only newly-exposed tiles are
    /// tessellated (a few per frame); cached tiles just re-transform.
    pub fn render(self: *Lookout) !bool {
        if (self.loading) {
            self.pollCompose(false);
            if (self.loading) {
                const ph = @as(f32, @floatFromInt(cc.SDL_GetTicks() % 1600)) / 1600.0;
                const p = 0.14 + 0.10 * @abs(1.0 - 2.0 * ph);
                self.g.clear = .{ .r = p * 0.6, .g = p * 0.8, .b = p, .a = 1.0 };
                return self.g.renderWindowTiles(&.{}, self.active_scheme, (self.kind_mask & (@as(u32, 1) << KIND_TEXT)) != 0, null);
            }
        }
        _ = self.ensureTiles(TILE_BUDGET);
        // Re-declutter only once the view stops moving; until then the previous
        // (world-anchored) labels keep drawing in the right place.
        if (self.labels_dirty and self.labelsSettled()) {
            self.labels_dirty = false;
            if (self.labelsStale()) self.buildLabels();
        }
        var list: std.ArrayList(gpu.Gpu.TileDraw) = .empty;
        defer list.deinit(self.alloc);
        self.collectDraws(&list);
        const ok = try self.g.renderWindowTiles(list.items, self.active_scheme, (self.kind_mask & (@as(u32, 1) << KIND_TEXT)) != 0, self.labelUniform());
        self.view_dirty = false;
        return ok;
    }

    /// True while the view still has tiles to fill in, or state changed — the host
    /// renders while this is true and blocks on events (idle CPU) when it's false.
    pub fn needsRedraw(self: *Lookout) bool {
        return self.loading or self.view_dirty or self.labels_dirty or self.anyVisibleMissing();
    }
    pub fn isBuilding(self: *Lookout) bool {
        return self.needsRedraw();
    }

    // Build every visible tile at once (snapshots have no frame loop).
    fn buildAllVisible(self: *Lookout) void {
        var guard: usize = 0;
        while (self.anyVisibleMissing() and guard < 128) : (guard += 1) _ = self.ensureTiles(9999);
    }
    /// Render offscreen and write a PNG.
    pub fn snapshotPng(self: *Lookout, path: []const u8) !void {
        self.pollCompose(true);
        self.buildAllVisible();
        self.buildLabels();
        var list: std.ArrayList(gpu.Gpu.TileDraw) = .empty;
        defer list.deinit(self.alloc);
        self.collectDraws(&list);
        const px = try self.g.renderOffscreenTiles(self.alloc, list.items, self.active_scheme, (self.kind_mask & (@as(u32, 1) << KIND_TEXT)) != 0, self.labelUniform());
        defer self.alloc.free(px);
        try png.write(self.alloc, path, px, self.g.width, self.g.height);
    }
    /// Render offscreen into a caller RGBA8 buffer (len must be width*height*4).
    pub fn snapshotRgba(self: *Lookout, dst: []u8) !void {
        self.pollCompose(true);
        self.buildAllVisible();
        self.buildLabels();
        var list: std.ArrayList(gpu.Gpu.TileDraw) = .empty;
        defer list.deinit(self.alloc);
        self.collectDraws(&list);
        const px = try self.g.renderOffscreenTiles(self.alloc, list.items, self.active_scheme, (self.kind_mask & (@as(u32, 1) << KIND_TEXT)) != 0, self.labelUniform());
        defer self.alloc.free(px);
        if (dst.len < px.len) return error.BufferTooSmall;
        @memcpy(dst[0..px.len], px);
    }

    // ---- pick (tap-to-identify) --------------------------------------------
    /// S-52 §10.8 cursor pick at a geographic point: `cb.feature` fires once per
    /// feature under it (class acronym + full S-57 attribute JSON + source cell).
    pub fn pick(self: *Lookout, lon: f64, lat: f64, cb: *const cc.tile57_query_cb) void {
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
        self.dropTiles(); // palette is baked into tiles — rebuild
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
        self.mariner.soundings = if (self.kind_mask & (@as(u32, 1) << KIND_SOUNDING) != 0) 2 else 1;
        self.deriveLive();
    }
    pub fn toggleOtherCategory(self: *Lookout) void {
        self.mariner.display_other = !self.mariner.display_other;
        self.deriveLive();
    }
    pub fn nudgeSafetyContour(self: *Lookout, delta: f64) void {
        self.mariner.safety_contour = std.math.clamp(self.mariner.safety_contour + delta, 0, 200);
        self.dropTiles(); // geometry-affecting -> rebuild visible tiles
        self.markDirty();
    }
    pub fn adjustSize(self: *Lookout, factor: f32) void {
        self.render_size_scale *= factor;
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
