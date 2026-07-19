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

pub const Mariner = cc.tile57_mariner;
pub const Scheme = cc.tile57_scheme;

const vert_spv = @embedFile("chart_vert_spv");
const frag_spv = @embedFile("chart_frag_spv");

// shader-kind bits (match chart.vert / scene.zig class numbering)
const KIND_SOUNDING: u5 = 3;
const KIND_TEXT: u5 = 4;

/// A camera pose. rotation_deg is course-up rotation (0 = north-up).
pub const View = struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 = 0 };

pub const OpenOptions = struct {
    width: u32 = 1280,
    height: u32 = 960,
    want_window: bool = false,
    want_msaa: bool = true,
    /// palettes captured at build so scheme changes are instant. All three by
    /// default (day/dusk/night); index order defines the scheme<->buffer map.
    schemes: []const Scheme = &.{ cc.TILE57_SCHEME_DAY, cc.TILE57_SCHEME_DUSK, cc.TILE57_SCHEME_NIGHT },
    /// optional ownership-partition sidecar to skip the compositor's partition
    /// build (from tile57_compose_save_partition / the `tile57 bake` CLI).
    partition_path: ?[:0]const u8 = null,
};

pub const Lookout = struct {
    alloc: std.mem.Allocator,
    charts: std.ArrayList(*cc.tile57_chart) = .empty, // 1 (single) or many (composed)
    compose: ?*cc.tile57_compose = null, // set when >1 chart (ENC_ROOT / library)
    g: gpu.Gpu,
    sc: ?scene.Scene = null,
    cam: camera.Camera,
    schemes: [scene.MAX_SCHEMES]Scheme = undefined,
    n_schemes: usize = 0,

    /// The authoritative S-52 display state. Edit via get/setMariner.
    mariner: Mariner = undefined,
    dirty: bool = true, // scene needs a (re)build before the next render
    partition_path: ?[:0]const u8 = null,

    // derived live (uniform-only) state
    active_scheme: usize = 0,
    cat_mask: u32 = 0b111,
    kind_mask: u32 = 0b11111,
    render_size_scale: f32 = 1.0,

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
        for (paths) |p| self.addChartPath(p);
        try self.finishOpen();
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
            }, vert_spv, frag_spv),
            .cam = undefined,
        };
        self.n_schemes = @min(opts.schemes.len, scene.MAX_SCHEMES);
        for (0..self.n_schemes) |i| self.schemes[i] = opts.schemes[i];
        self.partition_path = opts.partition_path;
        cc.tile57_mariner_defaults(&self.mariner);
        return self;
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
        if (self.charts.items.len > 1) {
            var err: cc.tile57_error = undefined;
            var c: ?*cc.tile57_compose = null;
            const part: [*c]const u8 = if (self.partition_path) |p| p.ptr else null;
            if (cc.tile57_compose_open(self.charts.items.ptr, self.charts.items.len, part, &c, &err) != cc.TILE57_OK or c == null) {
                std.debug.print("compose_open failed: {s}\n", .{@as([*:0]const u8, @ptrCast(&err.message))});
                return error.ComposeFailed;
            }
            self.compose = c;
            std.debug.print("composed {d} charts\n", .{self.charts.items.len});
        }
        const v = self.fitChart();
        self.cam = viewToCamera(v, self.g.width, self.g.height);
        self.deriveLive();
    }

    pub fn close(self: *Lookout) void {
        if (self.sc) |*s| s.deinit();
        self.g.deinit();
        if (self.compose) |c| cc.tile57_compose_close(c); // BEFORE the charts
        for (self.charts.items) |ch| cc.tile57_chart_close(ch);
        self.charts.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    // A dispatch over the active surface source (single chart or compositor).
    fn callSurface(self: *Lookout, lon: f64, lat: f64, cb: *const cc.tile57_surface_cb, m: *cc.tile57_mariner, err: *cc.tile57_error) cc.tile57_status {
        if (self.compose) |c|
            return cc.tile57_compose_surface(c, lon, lat, self.cam.zoom, 0.0, self.g.width, self.g.height, m, cb, err);
        return cc.tile57_chart_surface(self.charts.items[0], lon, lat, self.cam.zoom, 0.0, self.g.width, self.g.height, m, cb, err);
    }

    // ---- view ---------------------------------------------------------------
    fn viewToCamera(v: View, w: u32, h: u32) camera.Camera {
        const o = camera.lonLatToWorld(v.lon, v.lat);
        return .{ .origin = o, .center = o, .zoom = v.zoom, .rotation = v.rotation_deg * std.math.pi / 180.0, .vw = @floatFromInt(w), .vh = @floatFromInt(h) };
    }

    /// Center + fit-zoom for the whole chart (or composed set), from metadata.
    pub fn fitChart(self: *Lookout) View {
        var west: f64 = 0;
        var south: f64 = 0;
        var east: f64 = 0;
        var north: f64 = 0;
        var has_bounds = false;
        var min_zoom: u8 = 0;
        var max_zoom: u8 = 22;
        if (self.compose) |c| {
            var meta: cc.tile57_compose_meta = undefined;
            cc.tile57_compose_get_meta(c, &meta);
            west = meta.west;
            south = meta.south;
            east = meta.east;
            north = meta.north;
            min_zoom = meta.min_zoom;
            max_zoom = meta.max_zoom;
            has_bounds = true;
        } else {
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
        const vw: f64 = @floatFromInt(self.g.width);
        const vh: f64 = @floatFromInt(self.g.height);
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
    }
    pub fn view(self: *Lookout) View {
        const ll = camera.worldToLonLat(self.cam.center);
        return .{ .lon = ll.x, .lat = ll.y, .zoom = self.cam.zoom, .rotation_deg = self.cam.rotation * 180.0 / std.math.pi };
    }

    /// Resize the render surface (points; HiDPI density is applied internally).
    pub fn resize(self: *Lookout, width: u32, height: u32) !void {
        try self.g.resize(width, height);
        self.cam.vw = @floatFromInt(self.g.width);
        self.cam.vh = @floatFromInt(self.g.height);
    }
    pub fn pixelDensity(self: *Lookout) f32 {
        return self.g.pixel_density;
    }

    // ---- interaction --------------------------------------------------------
    pub fn panPixels(self: *Lookout, dx: f32, dy: f32) void {
        self.cam.panPx(dx, dy);
    }
    pub fn zoomAt(self: *Lookout, dzoom: f64, x_px: f32, y_px: f32) void {
        self.cam.zoomAbout(dzoom, x_px, y_px);
    }
    pub fn screenToGeo(self: *Lookout, x_px: f32, y_px: f32) View {
        const ll = camera.worldToLonLat(self.cam.screenToWorld(x_px, y_px));
        return .{ .lon = ll.x, .lat = ll.y, .zoom = self.cam.zoom };
    }
    pub fn geoToScreen(self: *Lookout, lon: f64, lat: f64) [2]f32 {
        const s = self.cam.worldToScreen(camera.lonLatToWorld(lon, lat));
        return .{ @floatCast(s.x), @floatCast(s.y) };
    }
    // Mouse coords from a HiDPI window arrive in logical points; scale to pixels.
    pub fn panLogical(self: *Lookout, dx_pt: f32, dy_pt: f32) void {
        self.cam.panPx(dx_pt * self.g.pixel_density, dy_pt * self.g.pixel_density);
    }
    pub fn zoomAtLogical(self: *Lookout, dzoom: f64, x_pt: f32, y_pt: f32) void {
        const d = self.g.pixel_density;
        self.cam.zoomAbout(dzoom, x_pt * d, y_pt * d);
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
        if (needsRebuild(self.mariner, m)) self.dirty = true;
        self.mariner = m;
        self.deriveLive();
    }

    fn deriveLive(self: *Lookout) void {
        // scheme -> which captured color buffer
        self.active_scheme = 0;
        for (0..self.n_schemes) |i| {
            if (self.schemes[i] == self.mariner.scheme) self.active_scheme = i;
        }
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
    }

    // ---- build + render -----------------------------------------------------
    /// (Re)tessellate the current view + mariner. Normally called automatically
    /// by render/snapshot; call directly to force a rebuild (e.g. new detail).
    pub fn build(self: *Lookout) !void {
        const origin = self.cam.center;
        self.cam.origin = origin;
        if (self.sc) |*old| old.deinit();
        self.sc = try scene.Scene.init(self.alloc, origin);
        const s = &self.sc.?;
        const lon = camera.worldToLonLat(origin).x;
        const lat = camera.worldToLonLat(origin).y;

        var err: cc.tile57_error = undefined;
        s.scheme_k = 0;
        var m0 = self.buildMariner(self.schemes[0]);
        const full = scene.fullTable(s);
        // north-up build (rotation is applied per-frame in the MVP), so a
        // course-up spin never re-tessellates.
        if (self.callSurface(lon, lat, &full, &m0, &err) != cc.TILE57_OK) {
            std.debug.print("surface failed: {s}\n", .{@as([*:0]const u8, @ptrCast(&err.message))});
            return error.SurfaceFailed;
        }
        for (1..self.n_schemes) |k| {
            s.scheme_k = k;
            s.color_counter = 0;
            var mk = self.buildMariner(self.schemes[k]);
            const ct = scene.colorTable(s);
            _ = self.callSurface(lon, lat, &ct, &mk, &err);
            if (s.color_counter != s.items.items.len) {
                for (s.items.items) |*it| it.colors[k] = it.colors[0];
            }
        }
        try s.finish(self.n_schemes);
        try self.g.uploadScene(s);
        self.dirty = false;
    }

    fn ensureBuilt(self: *Lookout) !void {
        if (self.dirty or self.sc == null) try self.build();
    }

    /// Base mariner for the build: the user's state, but with the live-gated
    /// axes forced permissive so EVERY feature reaches the surface tagged, then
    /// gated per-frame in the shader (NOTES.md §3). Geometry-affecting fields
    /// (contours, units, dates, groups…) pass through unchanged.
    fn buildMariner(self: *Lookout, sch: Scheme) Mariner {
        var m = self.mariner;
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

    fn uniforms(self: *Lookout) gpu.Uniforms {
        const rsc = self.cam.rotSinCos();
        return .{
            .mvp = self.cam.mvp(),
            .px_to_clip = self.cam.pxToClip(),
            .size_scale = self.render_size_scale,
            .current_scale = self.cam.displayScale(),
            .cat_mask = self.cat_mask,
            .kind_mask = self.kind_mask,
            .rot_sin = rsc[0],
            .rot_cos = rsc[1],
        };
    }

    /// Render one frame to the window and present. false if there is no window.
    pub fn render(self: *Lookout) !bool {
        try self.ensureBuilt();
        return self.g.renderWindow(self.uniforms(), self.active_scheme);
    }
    /// Render offscreen and write a PNG.
    pub fn snapshotPng(self: *Lookout, path: []const u8) !void {
        try self.ensureBuilt();
        try self.g.savePng(self.alloc, path, self.uniforms(), self.active_scheme);
    }
    /// Render offscreen into a caller RGBA8 buffer (len must be width*height*4).
    pub fn snapshotRgba(self: *Lookout, dst: []u8) !void {
        try self.ensureBuilt();
        const px = try self.g.renderOffscreen(self.alloc, self.uniforms(), self.active_scheme);
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
        const cur = self.active_scheme;
        const next = (cur + 1) % self.n_schemes;
        self.mariner.scheme = self.schemes[next];
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
        self.dirty = true; // geometry-affecting -> lazy rebuild
    }
    pub fn adjustSize(self: *Lookout, factor: f32) void {
        self.render_size_scale *= factor;
    }
};

/// True if changing from `a` to `b` alters what the engine emits (needs a
/// rebuild). Visibility-only fields (scheme, categories, text, soundings, size)
/// are excluded — those apply live.
fn needsRebuild(a: Mariner, b: Mariner) bool {
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
