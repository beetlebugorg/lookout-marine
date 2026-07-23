//! C ABI for lookout-core (see include/lookout.h). A thin, 1:1 wrapper over the
//! Zig `Lookout` widget. Uses the C allocator so C hosts need no allocator.
const std = @import("std");

const lk = @import("root.zig");
const cc = @import("c.zig").c;

const gpa = std.heap.c_allocator;

pub const lookout = opaque {};
pub const lookout_view = extern struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 };

fn cast(h: ?*lookout) *lk.Lookout {
    return @ptrCast(@alignCast(h.?));
}
fn toView(v: lookout_view) lk.View {
    return .{ .lon = v.lon, .lat = v.lat, .zoom = v.zoom, .rotation_deg = v.rotation_deg };
}
fn fromView(v: lk.View) lookout_view {
    return .{ .lon = v.lon, .lat = v.lat, .zoom = v.zoom, .rotation_deg = v.rotation_deg };
}

// ---- lifecycle -------------------------------------------------------------
export fn lookout_open(chart_path: [*:0]const u8, width: u32, height: u32, want_window: c_int, want_msaa: c_int) ?*lookout {
    const path_z = gpa.dupeZ(u8, std.mem.span(chart_path)) catch return null;
    defer gpa.free(path_z);
    const l = lk.Lookout.open(gpa, path_z, .{
        .width = width,
        .height = height,
        .want_window = want_window != 0,
        .want_msaa = want_msaa != 0,
    }) catch return null;
    return @ptrCast(l);
}
/// Open MANY baked charts and compose them (a chart library / ENC_ROOT cache).
/// Each path is mmap'd by tile57 — the set is never fully resident. Enumerate
/// the directory host-side and pass the paths.
export fn lookout_open_charts(paths: [*]const [*:0]const u8, n: usize, width: u32, height: u32, want_window: c_int, want_msaa: c_int) ?*lookout {
    const list = gpa.alloc([:0]const u8, n) catch return null;
    defer gpa.free(list);
    for (0..n) |i| list[i] = std.mem.span(paths[i]);
    const l = lk.Lookout.openCharts(gpa, list, .{
        .width = width,
        .height = height,
        .want_window = want_window != 0,
        .want_msaa = want_msaa != 0,
    }) catch return null;
    return @ptrCast(l);
}
/// EMBED into your app's view. `kind` is a lookout_native_kind (1 =
/// CAMetalLayer*); lookout renders and presents straight into the layer — your
/// app keeps its own toolkit + event loop. Then call lookout_render() each
/// frame and feed input via lookout_pan/zoom/set_view/resize. NULL on error.
export fn lookout_open_in_window(kind: c_int, native_handle: ?*anyopaque, chart_path: [*:0]const u8, width: u32, height: u32, want_msaa: c_int) ?*lookout {
    const path_z = gpa.dupeZ(u8, std.mem.span(chart_path)) catch return null;
    defer gpa.free(path_z);
    const l = lk.Lookout.open(gpa, path_z, .{
        .width = width,
        .height = height,
        .want_window = false,
        .want_msaa = want_msaa != 0,
        .native_handle = native_handle,
        .native_kind = nativeKind(kind) orelse return null,
    }) catch return null;
    return @ptrCast(l);
}

/// EMBED a composed chart LIBRARY into your app's view: like
/// lookout_open_in_window, but takes MANY baked charts (a directory of cells)
/// and composes them, presenting into your CAMetalLayer. NULL on error.
export fn lookout_open_charts_in_window(kind: c_int, native_handle: ?*anyopaque, paths: [*]const [*:0]const u8, n: usize, width: u32, height: u32, want_msaa: c_int) ?*lookout {
    const list = gpa.alloc([:0]const u8, n) catch return null;
    defer gpa.free(list);
    for (0..n) |i| list[i] = std.mem.span(paths[i]);
    const l = lk.Lookout.openCharts(gpa, list, .{
        .width = width,
        .height = height,
        .want_window = false,
        .want_msaa = want_msaa != 0,
        .native_handle = native_handle,
        .native_kind = nativeKind(kind) orelse return null,
    }) catch return null;
    return @ptrCast(l);
}

/// Reject unknown kind values from stale hosts instead of trusting the int.
fn nativeKind(kind: c_int) ?lk.NativeKind {
    return switch (kind) {
        0 => .none,
        1 => .metal_layer,
        else => null,
    };
}

export fn lookout_close(h: ?*lookout) void {
    if (h) |x| cast(x).close();
}

/// 1 if the symbol/font atlas cache is already built — i.e. the NEXT open will
/// not need the one-time rasterize. A host can call this before opening to show
/// a "preparing chart symbols" message only on the first run. No handle needed.
export fn lookout_atlas_cache_ready() c_int {
    return if (lk.atlasCacheReady(gpa)) 1 else 0;
}

// ---- view ------------------------------------------------------------------
export fn lookout_fit_chart(h: ?*lookout, out: *lookout_view) void {
    out.* = fromView(cast(h).fitChart());
}
export fn lookout_set_view(h: ?*lookout, v: *const lookout_view) void {
    cast(h).setView(toView(v.*));
}
export fn lookout_get_view(h: ?*lookout, out: *lookout_view) void {
    out.* = fromView(cast(h).view());
}
export fn lookout_resize(h: ?*lookout, width: u32, height: u32) c_int {
    cast(h).resize(width, height) catch return -1;
    return 0;
}
export fn lookout_pixel_density(h: ?*lookout) f32 {
    return cast(h).pixelDensity();
}

// ---- interaction (pixel coords; *_logical scale by HiDPI density) ----------
export fn lookout_pan(h: ?*lookout, dx: f32, dy: f32) void {
    cast(h).panPixels(dx, dy);
}
export fn lookout_zoom_at(h: ?*lookout, dzoom: f64, x_px: f32, y_px: f32) void {
    cast(h).zoomAt(dzoom, x_px, y_px);
}
export fn lookout_pan_logical(h: ?*lookout, dx_pt: f32, dy_pt: f32) void {
    cast(h).panLogical(dx_pt, dy_pt);
}
export fn lookout_zoom_at_logical(h: ?*lookout, dzoom: f64, x_pt: f32, y_pt: f32) void {
    cast(h).zoomAtLogical(dzoom, x_pt, y_pt);
}
export fn lookout_screen_to_geo(h: ?*lookout, x_px: f32, y_px: f32, lon: *f64, lat: *f64) void {
    const g = cast(h).screenToGeo(x_px, y_px);
    lon.* = g.lon;
    lat.* = g.lat;
}
export fn lookout_geo_to_screen(h: ?*lookout, lon: f64, lat: f64, x_px: *f32, y_px: *f32) void {
    const s = cast(h).geoToScreen(lon, lat);
    x_px.* = s[0];
    y_px.* = s[1];
}

// ---- mariner (ALL S-52 settings) -------------------------------------------
export fn lookout_mariner_defaults(m: *cc.tile57_mariner) void {
    cc.tile57_mariner_defaults(m);
}
export fn lookout_get_mariner(h: ?*lookout, out: *cc.tile57_mariner) void {
    out.* = cast(h).getMariner();
}
export fn lookout_set_mariner(h: ?*lookout, m: *const cc.tile57_mariner) void {
    cast(h).setMariner(m.*);
}

// ---- build + render --------------------------------------------------------
export fn lookout_build(h: ?*lookout) c_int {
    cast(h).build() catch return -1;
    return 0;
}
export fn lookout_render(h: ?*lookout) c_int {
    const ok = cast(h).render() catch return -1;
    return if (ok) 1 else 0;
}
/// 1 if a redraw is needed (view/state changed, a build is filling in, or the
/// view left coverage). When 0 the chart is static — your loop can block on
/// events and use no CPU. Call lookout_render only when this is 1.
export fn lookout_needs_redraw(h: ?*lookout) c_int {
    return if (cast(h).needsRedraw()) 1 else 0;
}
export fn lookout_snapshot_png(h: ?*lookout, path: [*:0]const u8) c_int {
    cast(h).snapshotPng(std.mem.span(path)) catch return -1;
    return 0;
}
export fn lookout_snapshot_rgba(h: ?*lookout, dst: [*]u8, dst_len: usize) c_int {
    cast(h).snapshotRgba(dst[0..dst_len]) catch return -1;
    return 0;
}

// ---- pick (tap-to-identify) ------------------------------------------------
export fn lookout_pick(h: ?*lookout, lon: f64, lat: f64, cb: *const cc.tile57_query_cb) void {
    cast(h).pick(lon, lat, cb);
}

// ---- convenience live toggles ----------------------------------------------
export fn lookout_cycle_scheme(h: ?*lookout) void {
    cast(h).cycleScheme();
}
export fn lookout_toggle_text(h: ?*lookout) void {
    cast(h).toggleText();
}
export fn lookout_toggle_soundings(h: ?*lookout) void {
    cast(h).toggleSoundings();
}
export fn lookout_toggle_other_category(h: ?*lookout) void {
    cast(h).toggleOtherCategory();
}
export fn lookout_nudge_safety_contour(h: ?*lookout, delta: f64) void {
    cast(h).nudgeSafetyContour(delta);
}
export fn lookout_adjust_size(h: ?*lookout, factor: f32) void {
    cast(h).adjustSize(factor);
}

// ---- smooth interaction (see include/lookout.h, §5 of the app spec) ---------
/// Shift-drag course-up rotation: rotate about the view centre by the angle the
/// cursor swept from (x0,y0) to (x1,y1), both logical points.
export fn lookout_rotate_drag_logical(h: ?*lookout, x0_pt: f32, y0_pt: f32, x1_pt: f32, y1_pt: f32) void {
    cast(h).rotateDragLogical(x0_pt, y0_pt, x1_pt, y1_pt);
}
/// Snap the view back to north-up.
export fn lookout_reset_rotation(h: ?*lookout) void {
    cast(h).resetRotation();
}
/// Start a momentum pan with a logical-px/sec velocity (pass 0,0 to stop coasting
/// when a grab starts).
export fn lookout_fling_start(h: ?*lookout, vx: f64, vy: f64) void {
    cast(h).flingStart(vx, vy);
}
/// 1 while an eased zoom or fling is in progress — render every frame while true.
export fn lookout_animating(h: ?*lookout) c_int {
    return if (cast(h).animating()) 1 else 0;
}
/// Advance the eased zoom / fling by `dt` seconds; call each frame while animating.
export fn lookout_tick_anim(h: ?*lookout, dt: f64) void {
    cast(h).tickAnim(dt);
}
/// 1 while a background tessellation is filling in — use a short idle timeout so
/// progressive builds appear.
export fn lookout_is_building(h: ?*lookout) c_int {
    return if (cast(h).isBuilding()) 1 else 0;
}
/// The current view's 1:N scale denominator, from the authoritative camera math.
export fn lookout_scale_denominator(h: ?*lookout) f64 {
    return cast(h).scaleDenominator();
}

comptime {
    _ = lookout_open;
}
