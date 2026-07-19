//! C ABI for lookout-core, so a C/C++ host can embed the renderer. Mirrors the
//! Zig `Lookout` API. See include/lookout.h. This file is the static library's
//! root; it pulls in the whole renderer.
const std = @import("std");
const lk = @import("root.zig");
const cc = @import("c.zig").c;

const gpa = std.heap.c_allocator;

pub const lookout = opaque {};

fn cast(h: ?*lookout) *lk.Lookout {
    return @ptrCast(@alignCast(h.?));
}

/// Open a baked chart and create the GPU device (+ window if want_window != 0).
export fn lookout_open(chart_path: [*:0]const u8, width: u32, height: u32, want_window: c_int, want_msaa: c_int) ?*lookout {
    const path = std.mem.span(chart_path);
    const path_z = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(path_z);
    const l = lk.Lookout.open(gpa, path_z, .{
        .width = width,
        .height = height,
        .want_window = want_window != 0,
        .want_msaa = want_msaa != 0,
    }) catch return null;
    return @ptrCast(l);
}

/// Fill *lon/*lat/*zoom with a center + fit-zoom for the whole chart.
export fn lookout_recommended_view(h: ?*lookout, lon: *f64, lat: *f64, zoom: *f64) void {
    const v = cast(h).recommendedView();
    lon.* = v.lon;
    lat.* = v.lat;
    zoom.* = v.zoom;
}

/// Build phase: tessellate the view once and upload GPU buffers.
export fn lookout_build_view(h: ?*lookout, lon: f64, lat: f64, zoom: f64) c_int {
    cast(h).buildView(lon, lat, zoom) catch return -1;
    return 0;
}

/// Render one frame to the window and present. Returns 1 if a window exists.
export fn lookout_render_window_frame(h: ?*lookout) c_int {
    const ok = cast(h).renderWindowFrame() catch return -1;
    return if (ok) 1 else 0;
}

/// Render offscreen and write a PNG. Returns 0 on success.
export fn lookout_save_png(h: ?*lookout, path: [*:0]const u8) c_int {
    cast(h).savePng(std.mem.span(path)) catch return -1;
    return 0;
}

// live, uniform-only toggles (no re-tessellation)
export fn lookout_set_scheme(h: ?*lookout, k: usize) void {
    cast(h).setScheme(k);
}
export fn lookout_toggle_scheme(h: ?*lookout) void {
    cast(h).toggleScheme();
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
export fn lookout_pan_px(h: ?*lookout, dx: f32, dy: f32) void {
    cast(h).cam.panPx(dx, dy);
}
export fn lookout_zoom_about(h: ?*lookout, dz: f64, px: f32, py: f32) void {
    cast(h).cam.zoomAbout(dz, px, py);
}

// rebuilds (geometry changes)
export fn lookout_nudge_safety_contour(h: ?*lookout, delta: f64) c_int {
    cast(h).nudgeSafetyContour(delta) catch return -1;
    return 0;
}

export fn lookout_close(h: ?*lookout) void {
    if (h) |x| cast(x).close();
}

// keep the C ABI symbols alive in the archive
comptime {
    _ = lookout_open;
}
