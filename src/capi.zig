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
/// EMBED into your app's native window. `kind` is a lookout_native_kind:
///   1 NSWindow*  2 NSView*  3 HWND  4 X11 Window (XID cast to a pointer).
/// lookout wraps it with SDL internally and renders/presents into it — your app
/// keeps its own toolkit + event loop and never links SDL. Then call
/// lookout_render() each frame and feed input via lookout_pan/zoom/set_view/
/// resize. NULL on error.
export fn lookout_open_in_window(kind: c_int, native_handle: ?*anyopaque, chart_path: [*:0]const u8, width: u32, height: u32, want_msaa: c_int) ?*lookout {
    const path_z = gpa.dupeZ(u8, std.mem.span(chart_path)) catch return null;
    defer gpa.free(path_z);
    const l = lk.Lookout.open(gpa, path_z, .{
        .width = width,
        .height = height,
        .want_window = false,
        .want_msaa = want_msaa != 0,
        .native_handle = native_handle,
        .native_kind = @enumFromInt(kind),
    }) catch return null;
    return @ptrCast(l);
}

export fn lookout_close(h: ?*lookout) void {
    if (h) |x| cast(x).close();
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

comptime {
    _ = lookout_open;
}
