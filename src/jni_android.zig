//! JNI bindings for the Android Java shell (org.beetlebug.lookout.Lookout).
//! Compiled into liblookout_marine.a on `-Dbackend=vk` builds only (see
//! capi.zig's comptime include). The Java side owns the Activity, the
//! SurfaceView and all gestures; these natives are the bridge to the C ABI —
//! the exact Android analogue of the iOS app driving lookout from Swift.
//!
//! Units: every geometry-taking native works in LOGICAL points (Android dp) —
//! the camera's own unit. Java divides pixels by DisplayMetrics.density before
//! crossing; gpu_vk derives pixel_density from surface px / resize() points.
//!
//! Threading: the Java shell calls every native on the main thread (gestures +
//! Choreographer frame callbacks), and the C ABI additionally holds its own
//! api lock, so there is no JNI-side synchronization.
const std = @import("std");

const j = @cImport({
    @cInclude("jni.h");
    @cInclude("android/native_window_jni.h");
});

// The C ABI (capi.zig exports, same archive — resolved at link).
const lookout_view = extern struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 };
extern fn lookout_open_in_window(kind: c_int, native_handle: ?*anyopaque, chart_path: [*:0]const u8, width: u32, height: u32, want_msaa: c_int) ?*anyopaque;
extern fn lookout_close(h: ?*anyopaque) void;
extern fn lookout_resize(h: ?*anyopaque, width: u32, height: u32) c_int;
extern fn lookout_fit_chart(h: ?*anyopaque, v: *lookout_view) c_int;
extern fn lookout_set_view(h: ?*anyopaque, v: *const lookout_view) void;
extern fn lookout_get_view(h: ?*anyopaque, v: *lookout_view) void;
extern fn lookout_pan_logical(h: ?*anyopaque, dx_pt: f32, dy_pt: f32) void;
extern fn lookout_zoom_at_logical(h: ?*anyopaque, dzoom: f64, x_pt: f32, y_pt: f32) void;
extern fn lookout_render(h: ?*anyopaque) c_int;
extern fn lookout_needs_redraw(h: ?*anyopaque) c_int;
extern fn lookout_animating(h: ?*anyopaque) c_int;
extern fn lookout_tick_anim(h: ?*anyopaque, dt: f64) void;
extern fn lookout_cycle_scheme(h: ?*anyopaque) void;

const LOOKOUT_NATIVE_ANDROID_WINDOW: c_int = 7;

/// One Java Lookout instance: the engine handle + the ANativeWindow we
/// acquired from its Surface (released on close).
const Handle = struct {
    l: *anyopaque,
    win: *j.ANativeWindow,
};
const gpa = std.heap.c_allocator;

inline fn env_(env: [*c]j.JNIEnv) *const j.JNINativeInterface {
    return env.*; // JNIEnv is already `const JNINativeInterface*`
}
// jlong <-> pointer is a BIT-pattern round-trip, not a value cast: Android's
// scudo returns TAGGED pointers (top byte 0xb4 under TBI/MTE), which read as
// >= 2^63 unsigned — @intCast into signed jlong panics on the tag bit.
fn fromLong(h: j.jlong) ?*Handle {
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(h)));
}
fn toLong(h: *Handle) j.jlong {
    return @bitCast(@as(u64, @intFromPtr(h)));
}

/// long nOpen(String chartPath, Surface surface, int widthPx, int heightPx,
///            int widthPts, int heightPts, boolean msaa)
export fn Java_org_beetlebug_lookout_Lookout_nOpen(env: [*c]j.JNIEnv, cls: j.jclass, path: j.jstring, surface: j.jobject, w_px: j.jint, h_px: j.jint, w_pts: j.jint, h_pts: j.jint, msaa: j.jboolean) j.jlong {
    _ = cls;
    const win = j.ANativeWindow_fromSurface(env, surface) orelse return 0;
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse {
        j.ANativeWindow_release(win);
        return 0;
    };
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);
    const l = lookout_open_in_window(LOOKOUT_NATIVE_ANDROID_WINDOW, win, @ptrCast(cpath), @intCast(w_px), @intCast(h_px), if (msaa != 0) 1 else 0) orelse {
        j.ANativeWindow_release(win);
        return 0;
    };
    // Tell the camera its logical size straight away (density = px/pts).
    _ = lookout_resize(l, @intCast(w_pts), @intCast(h_pts));
    var v: lookout_view = undefined;
    if (lookout_fit_chart(l, &v) == 0) lookout_set_view(l, &v);
    const h = gpa.create(Handle) catch {
        lookout_close(l);
        j.ANativeWindow_release(win);
        return 0;
    };
    h.* = .{ .l = l, .win = win };
    return toLong(h);
}

export fn Java_org_beetlebug_lookout_Lookout_nClose(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_close(h.l);
    j.ANativeWindow_release(h.win);
    gpa.destroy(h);
}

/// Logical points (dp).
export fn Java_org_beetlebug_lookout_Lookout_nResize(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, w_pts: j.jint, h_pts: j.jint) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    _ = lookout_resize(h.l, @intCast(w_pts), @intCast(h_pts));
}

export fn Java_org_beetlebug_lookout_Lookout_nFitChart(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    var v: lookout_view = undefined;
    if (lookout_fit_chart(h.l, &v) == 0) lookout_set_view(h.l, &v);
}

export fn Java_org_beetlebug_lookout_Lookout_nPan(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, dx_pt: j.jfloat, dy_pt: j.jfloat) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_pan_logical(h.l, dx_pt, dy_pt);
}

export fn Java_org_beetlebug_lookout_Lookout_nZoomAt(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, dz: j.jdouble, x_pt: j.jfloat, y_pt: j.jfloat) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_zoom_at_logical(h.l, dz, x_pt, y_pt);
}

export fn Java_org_beetlebug_lookout_Lookout_nRender(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jboolean {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_render(h.l) == 0) 1 else 0;
}

export fn Java_org_beetlebug_lookout_Lookout_nNeedsRedraw(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jboolean {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_needs_redraw(h.l) != 0) 1 else 0;
}

export fn Java_org_beetlebug_lookout_Lookout_nAnimating(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jboolean {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_animating(h.l) != 0) 1 else 0;
}

export fn Java_org_beetlebug_lookout_Lookout_nTickAnim(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, dt: j.jdouble) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_tick_anim(h.l, dt);
}

/// Cycle day -> dusk -> night (the full mariner struct crosses later).
export fn Java_org_beetlebug_lookout_Lookout_nCycleScheme(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_cycle_scheme(h.l);
}
