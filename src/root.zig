//! lookout-core: a library that opens a baked tile57 chart and renders it through
//! the Surface interface on SDL_GPU. Public Zig API (a thin C ABI wraps this in
//! capi.zig). Build phase tessellates once; frame phase only updates uniforms.
const std = @import("std");
const cc = @import("c.zig").c;
const scene = @import("scene.zig");
const gpu = @import("gpu.zig");
const camera = @import("camera.zig");

pub const Vertex = scene.Vertex;
pub const Camera = camera.Camera;

const vert_spv = @embedFile("chart_vert_spv");
const frag_spv = @embedFile("chart_frag_spv");

// shader-kind bits (must match chart.vert / scene.zig class numbering)
const KIND_AREA: u5 = 0;
const KIND_LINE: u5 = 1;
const KIND_SYMBOL: u5 = 2;
const KIND_SOUNDING: u5 = 3;
const KIND_TEXT: u5 = 4;

pub const OpenOptions = struct {
    width: u32 = 1280,
    height: u32 = 960,
    want_window: bool = false,
    want_msaa: bool = true,
    /// palettes to capture at build (day is index 0, the render default).
    schemes: []const cc.tile57_scheme = &.{ cc.TILE57_SCHEME_DAY, cc.TILE57_SCHEME_NIGHT },
};

pub const Lookout = struct {
    alloc: std.mem.Allocator,
    chart: *cc.tile57_chart,
    g: gpu.Gpu,
    sc: ?scene.Scene = null,
    cam: camera.Camera,
    schemes: [scene.MAX_SCHEMES]cc.tile57_scheme = undefined,
    n_schemes: usize = 0,
    active_scheme: usize = 0,

    // build view (for rebuilds on safety-contour change)
    view_lon: f64 = 0,
    view_lat: f64 = 0,
    view_zoom: f64 = 0,

    // live frame-phase state (uniform-only)
    cat_mask: u32 = 0b111, // all display categories
    kind_mask: u32 = 0b11111, // all kinds
    render_size_scale: f32 = 1.0,
    safety_contour: f64 = 10.0,

    pub fn open(alloc: std.mem.Allocator, chart_path: [:0]const u8, opts: OpenOptions) !*Lookout {
        cc.tile57_warmup();
        var err: cc.tile57_error = undefined;
        var chart: ?*cc.tile57_chart = null;
        if (cc.tile57_chart_open(chart_path.ptr, &chart, &err) != cc.TILE57_OK or chart == null) {
            std.debug.print("tile57_chart_open failed: {s}\n", .{@as([*:0]const u8, @ptrCast(&err.message))});
            return error.ChartOpenFailed;
        }
        const self = try alloc.create(Lookout);
        self.* = .{
            .alloc = alloc,
            .chart = chart.?,
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
        return self;
    }

    fn buildMariner(self: *Lookout, sch: cc.tile57_scheme) cc.tile57_mariner {
        var m: cc.tile57_mariner = undefined;
        cc.tile57_mariner_defaults(&m);
        m.scheme = sch;
        // maximally permissive so EVERY feature reaches the surface, tagged; we
        // gate category/scamin/text/soundings live in the shader (NOTES.md §3).
        m.display_base = true;
        m.display_standard = true;
        m.display_other = true;
        m.text_names = true;
        m.show_light_descriptions = true;
        m.text_other = true;
        m.soundings = 1;
        m.size_scale = 1.0; // runtime size lives in the shader uniform
        m.safety_contour = self.safety_contour;
        return m;
    }

    /// Build phase: drive the Surface once per palette, tessellate, upload.
    pub fn buildView(self: *Lookout, lon: f64, lat: f64, zoom: f64) !void {
        self.view_lon = lon;
        self.view_lat = lat;
        self.view_zoom = zoom;
        const origin = camera.lonLatToWorld(lon, lat);
        self.cam = .{
            .origin = origin,
            .center = origin,
            .zoom = zoom,
            .vw = @floatFromInt(self.g.width),
            .vh = @floatFromInt(self.g.height),
        };

        if (self.sc) |*old| old.deinit();
        self.sc = try scene.Scene.init(self.alloc, origin);
        const s = &self.sc.?;

        var err: cc.tile57_error = undefined;
        // pass 0: full geometry + scheme-0 colors
        s.mode_full = true;
        s.scheme_k = 0;
        var m0 = self.buildMariner(self.schemes[0]);
        const full = scene.fullTable(s);
        if (cc.tile57_chart_surface(self.chart, lon, lat, zoom, 0.0, self.g.width, self.g.height, &m0, &full, &err) != cc.TILE57_OK) {
            std.debug.print("surface(day) failed: {s}\n", .{@as([*:0]const u8, @ptrCast(&err.message))});
            return error.SurfaceFailed;
        }
        // passes 1..n: colors only (geometry identical across schemes)
        for (1..self.n_schemes) |k| {
            s.scheme_k = k;
            s.color_counter = 0;
            var mk = self.buildMariner(self.schemes[k]);
            const ct = scene.colorTable(s);
            _ = cc.tile57_chart_surface(self.chart, lon, lat, zoom, 0.0, self.g.width, self.g.height, &mk, &ct, &err);
            if (s.color_counter != s.items.items.len) {
                std.debug.print("WARN scheme {d}: color parity {d} != {d}; using day colors\n", .{ k, s.color_counter, s.items.items.len });
                for (s.items.items) |*it| it.colors[k] = it.colors[0];
            }
        }
        try s.finish(self.n_schemes);
        try self.g.uploadScene(s);
        std.debug.print("built: {d} draw-calls, {d} verts, {d} tris (tessellated ONCE)\n", .{ s.items.items.len, s.verts.items.len, s.triangleCount() });
    }

    pub const View = struct { lon: f64, lat: f64, zoom: f64 };

    /// Center + fit-zoom for the whole chart, from its embedded metadata.
    pub fn recommendedView(self: *Lookout) View {
        var info: cc.tile57_info = undefined;
        cc.tile57_chart_get_info(self.chart, &info);
        if (info.has_bounds) {
            const lon = (info.west + info.east) * 0.5;
            const lat = (info.south + info.north) * 0.5;
            const wl = camera.lonLatToWorld(info.west, info.north);
            const wr = camera.lonLatToWorld(info.east, info.south);
            const ww = @abs(wr.x - wl.x);
            const wh = @abs(wr.y - wl.y);
            const vw: f64 = @floatFromInt(self.g.width);
            const vh: f64 = @floatFromInt(self.g.height);
            const zx = std.math.log2(vw / (256.0 * @max(ww, 1e-12)));
            const zy = std.math.log2(vh / (256.0 * @max(wh, 1e-12)));
            var z = @min(zx, zy) - 0.15; // small margin
            z = std.math.clamp(z, @as(f64, @floatFromInt(info.min_zoom)), @as(f64, @floatFromInt(info.max_zoom)) + 1.0);
            return .{ .lon = lon, .lat = lat, .zoom = z };
        }
        if (info.has_anchor) return .{ .lon = info.anchor_lon, .lat = info.anchor_lat, .zoom = info.anchor_zoom };
        return .{ .lon = 0, .lat = 0, .zoom = 2 };
    }

    pub fn uniforms(self: *Lookout) gpu.Uniforms {
        return .{
            .mvp = self.cam.mvp(),
            .px_to_clip = self.cam.pxToClip(),
            .size_scale = self.render_size_scale,
            .current_scale = self.cam.displayScale(),
            .cat_mask = self.cat_mask,
            .kind_mask = self.kind_mask,
            .rot_sin = 0,
            .rot_cos = 1,
        };
    }

    pub fn savePng(self: *Lookout, path: []const u8) !void {
        try self.g.savePng(self.alloc, path, self.uniforms(), self.active_scheme);
    }
    pub fn renderWindowFrame(self: *Lookout) !bool {
        return self.g.renderWindow(self.uniforms(), self.active_scheme);
    }

    // ---- live toggles (uniform-only; NO rebuild) ----------------------------
    pub fn setScheme(self: *Lookout, k: usize) void {
        if (k < self.n_schemes) self.active_scheme = k;
    }
    pub fn toggleScheme(self: *Lookout) void {
        self.active_scheme = (self.active_scheme + 1) % self.n_schemes;
    }
    pub fn toggleKind(self: *Lookout, kind: u5) void {
        self.kind_mask ^= (@as(u32, 1) << kind);
    }
    pub fn toggleText(self: *Lookout) void {
        self.toggleKind(KIND_TEXT);
    }
    pub fn toggleSoundings(self: *Lookout) void {
        self.toggleKind(KIND_SOUNDING);
    }
    pub fn toggleOtherCategory(self: *Lookout) void {
        self.cat_mask ^= (@as(u32, 1) << @intCast(cc.TILE57_DISP_OTHER));
    }

    // ---- rebuilds (geometry changes) ----------------------------------------
    pub fn nudgeSafetyContour(self: *Lookout, delta: f64) !void {
        self.safety_contour = std.math.clamp(self.safety_contour + delta, 0, 200);
        try self.buildView(self.view_lon, self.view_lat, self.view_zoom);
    }

    pub fn close(self: *Lookout) void {
        if (self.sc) |*s| s.deinit();
        self.g.deinit();
        cc.tile57_chart_close(self.chart);
        const a = self.alloc;
        a.destroy(self);
    }
};

test "camera roundtrip" {
    const w = camera.lonLatToWorld(-76.48, 38.98);
    const ll = camera.worldToLonLat(w);
    try std.testing.expectApproxEqAbs(@as(f64, -76.48), ll.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 38.98), ll.y, 1e-9);
}
