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
//! Threading: gestures call in on the main thread while the frame loop calls
//! nRender/nTickAnim on a dedicated render thread, and the C ABI's api lock
//! serializes them (its documented shape). nClose, nAttachSurface and
//! nDetachSurface are externally serialized: the shell runs them on the render
//! thread with the frame loop stopped.
const std = @import("std");

const j = @cImport({
    @cInclude("jni.h");
    @cInclude("android/native_window_jni.h");
});

// tile57's own types (mariner struct, pick callback) come from the SHARED
// cImport the rest of the core uses — never a hand-copied layout. The mariner
// struct's ABI has moved twice; a redeclaration here would rot silently.
const cc = @import("c.zig").c;

// The C ABI (capi.zig exports, same archive — resolved at link).
const lookout_view = extern struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 };
extern fn lookout_open_in_window(kind: c_int, native_handle: ?*anyopaque, chart_path: [*:0]const u8, width: u32, height: u32, want_msaa: c_int) ?*anyopaque;
extern fn lookout_open_charts_in_window(kind: c_int, native_handle: ?*anyopaque, paths: [*]const [*:0]const u8, n: usize, width: u32, height: u32, want_msaa: c_int) ?*anyopaque;
extern fn lookout_close(h: ?*anyopaque) void;
extern fn lookout_detach_surface(h: ?*anyopaque) void;
extern fn lookout_attach_surface(h: ?*anyopaque, kind: c_int, native_handle: ?*anyopaque, width: u32, height: u32) c_int;
extern fn lookout_set_cache_dir(path: [*:0]const u8) void;
extern fn lookout_resize(h: ?*anyopaque, width: u32, height: u32) c_int;
extern fn lookout_fit_chart(h: ?*anyopaque, v: *lookout_view) c_int;
extern fn lookout_default_view(h: ?*anyopaque, v: *lookout_view) void;
extern fn lookout_set_view(h: ?*anyopaque, v: *const lookout_view) void;
extern fn lookout_get_view(h: ?*anyopaque, v: *lookout_view) void;
extern fn lookout_pan_logical(h: ?*anyopaque, dx_pt: f32, dy_pt: f32) void;
extern fn lookout_zoom_at_logical(h: ?*anyopaque, dzoom: f64, x_pt: f32, y_pt: f32) void;
extern fn lookout_render(h: ?*anyopaque) c_int;
extern fn lookout_needs_redraw(h: ?*anyopaque) c_int;
extern fn lookout_animating(h: ?*anyopaque) c_int;
extern fn lookout_tick_anim(h: ?*anyopaque, dt: f64) void;
extern fn lookout_cycle_scheme(h: ?*anyopaque) void;
extern fn lookout_pixel_density(h: ?*anyopaque) f32;
extern fn lookout_set_pixel_density(h: ?*anyopaque, d: f32) void;
extern fn lookout_screen_to_geo(h: ?*anyopaque, x_px: f32, y_px: f32, lon: *f64, lat: *f64) void;
extern fn lookout_overscale(h: ?*anyopaque) f64;
extern fn lookout_scale_denominator(h: ?*anyopaque) f64;
extern fn lookout_is_building(h: ?*anyopaque) c_int;
extern fn lookout_reset_rotation(h: ?*anyopaque) void;
extern fn lookout_rotate_drag_logical(h: ?*anyopaque, x0_pt: f32, y0_pt: f32, x1_pt: f32, y1_pt: f32) void;
extern fn lookout_fling_start(h: ?*anyopaque, vx: f64, vy: f64) void;
extern fn lookout_memory_warning(h: ?*anyopaque) void;
extern fn lookout_get_mariner(h: ?*anyopaque, out: *cc.tile57_mariner) void;
extern fn lookout_set_mariner(h: ?*anyopaque, m: *const cc.tile57_mariner) void;
extern fn lookout_pick(h: ?*anyopaque, lon: f64, lat: f64, cb: *const cc.tile57_query_cb) void;
extern fn lookout_pick_ranked(h: ?*anyopaque, lon: f64, lat: f64, cb: *const cc.tile57_query_cb) void;

const LOOKOUT_NATIVE_ANDROID_WINDOW: c_int = 7;

/// One Java Lookout instance: the engine handle + the ANativeWindow we
/// acquired from its Surface. Null between nDetachSurface and nAttachSurface,
/// which is the whole time the app is in the background: the engine outlives
/// the window it draws into.
const Handle = struct {
    l: *anyopaque,
    win: ?*j.ANativeWindow,
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

/// void nSetCacheDir(String path) -- Context.getCacheDir(). Before any open:
/// the atlas cache has no other way to find a writable directory here.
export fn Java_org_beetlebug_lookout_Lookout_nSetCacheDir(env: [*c]j.JNIEnv, cls: j.jclass, path: j.jstring) void {
    _ = cls;
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse return;
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);
    lookout_set_cache_dir(@ptrCast(cpath));
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
    return finishOpen(l, win, w_pts, h_pts);
}

/// long nOpenCharts(String[] chartPaths, Surface surface, int widthPx,
///                  int heightPx, int widthPts, int heightPts, boolean msaa)
///
/// Open a chart LIBRARY: many baked cells composed into one view, the engine
/// picking the owner per tile from its band/tier partition. The host's whole job
/// is to enumerate the paths — the partition sidecar next to the archives is
/// found (or built in memory) by the engine, not named here.
///
/// The compose+partition build is slow for a big library, so the engine runs it
/// on a worker and shows its loader; the first cell renders immediately.
export fn Java_org_beetlebug_lookout_Lookout_nOpenCharts(env: [*c]j.JNIEnv, cls: j.jclass, paths: j.jobjectArray, surface: j.jobject, w_px: j.jint, h_px: j.jint, w_pts: j.jint, h_pts: j.jint, msaa: j.jboolean) j.jlong {
    _ = cls;
    const count = env_(env).GetArrayLength.?(env, paths);
    if (count <= 0) return 0;
    const n: usize = @intCast(count);
    // Each path is COPIED and its ref dropped inside the loop: a real library
    // is thousands of paths, and ART's local reference table holds 512.
    // Keeping a ref and a pinned string per element until the open returned
    // overflowed the table and aborted the process.
    const cs = gpa.alloc([*:0]const u8, n) catch return 0;
    defer gpa.free(cs);
    var got: usize = 0;
    defer for (0..got) |i| gpa.free(std.mem.span(cs[i]));
    while (got < n) : (got += 1) {
        const s: j.jstring = @ptrCast(env_(env).GetObjectArrayElement.?(env, paths, @intCast(got)));
        const c = env_(env).GetStringUTFChars.?(env, s, null) orelse return 0;
        const copy = gpa.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(c)))) catch {
            env_(env).ReleaseStringUTFChars.?(env, s, c);
            env_(env).DeleteLocalRef.?(env, s);
            return 0;
        };
        env_(env).ReleaseStringUTFChars.?(env, s, c);
        env_(env).DeleteLocalRef.?(env, s);
        cs[got] = copy.ptr;
    }
    const win = j.ANativeWindow_fromSurface(env, surface) orelse return 0;
    const l = lookout_open_charts_in_window(LOOKOUT_NATIVE_ANDROID_WINDOW, win, cs.ptr, n, @intCast(w_px), @intCast(h_px), if (msaa != 0) 1 else 0) orelse {
        j.ANativeWindow_release(win);
        return 0;
    };
    return finishOpen(l, win, w_pts, h_pts);
}

/// The tail both opens share: hand the camera its LOGICAL size (so the core can
/// derive density = px/pts), frame the data, and wrap it all in a Handle.
fn finishOpen(l: *anyopaque, win: *j.ANativeWindow, w_pts: j.jint, h_pts: j.jint) j.jlong {
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
    if (h.win) |w| j.ANativeWindow_release(w);
    gpa.destroy(h);
}

/// void nDetachSurface(long h) -- surfaceDestroyed. Drops the Vulkan surface
/// and swapchain and leaves the engine standing, so the return from background
/// costs a swapchain instead of a reopen of the whole library.
export fn Java_org_beetlebug_lookout_Lookout_nDetachSurface(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_detach_surface(h.l);
    // After the core, which held the window through its VkSurfaceKHR.
    if (h.win) |w| {
        j.ANativeWindow_release(w);
        h.win = null;
    }
}

/// boolean nAttachSurface(long h, Surface surface, int wPts, int hPts) --
/// surfaceChanged onto a standing engine. False when the surface cannot be
/// adopted, which leaves the engine detached for the caller to reopen.
export fn Java_org_beetlebug_lookout_Lookout_nAttachSurface(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, surface: j.jobject, w_pts: j.jint, h_pts: j.jint) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    if (h.win != null) return 0; // still holding one: detach first
    const win = j.ANativeWindow_fromSurface(env, surface) orelse return 0;
    if (lookout_attach_surface(h.l, LOOKOUT_NATIVE_ANDROID_WINDOW, win, @intCast(w_pts), @intCast(h_pts)) != 0) {
        j.ANativeWindow_release(win);
        return 0;
    }
    h.win = win;
    return 1;
}

/// Logical points (dp).
export fn Java_org_beetlebug_lookout_Lookout_nResize(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, w_pts: j.jint, h_pts: j.jint) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    _ = lookout_resize(h.l, @intCast(w_pts), @intCast(h_pts));
}

/// DisplayMetrics.density. The surface cannot be trusted for this on Android:
/// across a rotation its extent lags the new logical size by a frame.
export fn Java_org_beetlebug_lookout_Lookout_nSetDensity(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, d: j.jfloat) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_set_pixel_density(h.l, d);
}

/// void nSetDeviceScale(long h, float scale) -- the display's device pixels per
/// reference pixel.
///
/// It sizes the symbols and the text, and the collision box of each label with
/// them. The engine sizes for 1x until it is told otherwise, so a surface drawn
/// at any other density draws symbols the wrong size and decluttered a view for
/// glyphs it did not paint. It is a property of the DISPLAY, so it is set here
/// and not from the settings form.
export fn Java_org_beetlebug_lookout_Lookout_nSetDeviceScale(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, scale: j.jfloat) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    if (scale <= 0) return;
    var m: cc.tile57_mariner = undefined;
    lookout_get_mariner(h.l, &m);
    m.device_scale = scale;
    lookout_set_mariner(h.l, &m);
}

export fn Java_org_beetlebug_lookout_Lookout_nFitChart(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    var v: lookout_view = undefined;
    if (lookout_fit_chart(h.l, &v) == 0) lookout_set_view(h.l, &v);
}

/// Frame the library at overview zoom — the opening view when the host has no
/// saved pose. Computed and applied in one crossing, like nFitChart.
export fn Java_org_beetlebug_lookout_Lookout_nDefaultView(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    var v: lookout_view = undefined;
    lookout_default_view(h.l, &v);
    lookout_set_view(h.l, &v);
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

/// Cycle day -> dusk -> night. The full mariner struct crosses via
/// nGetMariner/nSetMariner; this is the one-tap convenience the toolbar uses.
export fn Java_org_beetlebug_lookout_Lookout_nCycleScheme(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_cycle_scheme(h.l);
}

// ---- HUD readouts ----------------------------------------------------------

/// Everything the readouts bar shows, in ONE crossing: the HUD refreshes off
/// the frame loop, and seven separate natives per update would be seven api-lock
/// round-trips a frame. The caller owns a reusable double[READOUTS_LEN], so a
/// steady HUD allocates nothing.
const READOUTS_LEN: j.jsize = 7;

/// void nReadouts(long h, double[] out) -- lon, lat, zoom, rotationDeg,
/// overscale, scaleDenominator, building(0/1).
export fn Java_org_beetlebug_lookout_Lookout_nReadouts(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, out: j.jdoubleArray) void {
    _ = cls;
    const h = fromLong(hl) orelse return;
    if (env_(env).GetArrayLength.?(env, out) < READOUTS_LEN) return;
    var v: lookout_view = undefined;
    lookout_get_view(h.l, &v);
    const buf = [_]f64{
        v.lon,
        v.lat,
        v.zoom,
        v.rotation_deg,
        lookout_overscale(h.l),
        lookout_scale_denominator(h.l),
        if (lookout_is_building(h.l) != 0) 1 else 0,
    };
    env_(env).SetDoubleArrayRegion.?(env, out, 0, READOUTS_LEN, &buf);
}

export fn Java_org_beetlebug_lookout_Lookout_nSetView(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, lon: j.jdouble, lat: j.jdouble, zoom: j.jdouble, rot_deg: j.jdouble) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    const v = lookout_view{ .lon = lon, .lat = lat, .zoom = zoom, .rotation_deg = rot_deg };
    lookout_set_view(h.l, &v);
}

/// void nScreenToGeo(long h, float xPt, float yPt, double[] out) -- lon, lat.
///
/// Takes LOGICAL points and passes them straight through. The camera is
/// logical-native: its viewport is the size lookout_resize was given, in
/// points. Scaling to pixels here moved every point away from the centre of
/// the view by the density, so a tap answered on the object that many points
/// down and to the right of the one under the finger.
export fn Java_org_beetlebug_lookout_Lookout_nScreenToGeo(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, x_pt: j.jfloat, y_pt: j.jfloat, out: j.jdoubleArray) void {
    _ = cls;
    const h = fromLong(hl) orelse return;
    if (env_(env).GetArrayLength.?(env, out) < 2) return;
    var buf: [2]f64 = undefined;
    lookout_screen_to_geo(h.l, x_pt, y_pt, &buf[0], &buf[1]);
    env_(env).SetDoubleArrayRegion.?(env, out, 0, 2, &buf);
}

export fn Java_org_beetlebug_lookout_Lookout_nResetRotation(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_reset_rotation(h.l);
}

/// Two-finger twist: rotate about the view centre by the angle swept from
/// (x0,y0) to (x1,y1), logical points.
export fn Java_org_beetlebug_lookout_Lookout_nRotateDrag(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, x0: j.jfloat, y0: j.jfloat, x1: j.jfloat, y1: j.jfloat) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_rotate_drag_logical(h.l, x0, y0, x1, y1);
}

/// Momentum pan in logical points/second; (0,0) stops a coast when a new grab
/// starts.
export fn Java_org_beetlebug_lookout_Lookout_nFlingStart(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, vx: j.jdouble, vy: j.jdouble) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_fling_start(h.l, vx, vy);
}

/// onTrimMemory: drop reclaimable engine caches at the next safe point.
export fn Java_org_beetlebug_lookout_Lookout_nMemoryWarning(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_memory_warning(h.l);
}

extern fn lookout_atlas_cache_ready() c_int;

/// boolean nAtlasCacheReady() -- whether the next open skips the one-time
/// symbol rasterize, so the loader says "preparing symbols" only on first run.
export fn Java_org_beetlebug_lookout_Lookout_nAtlasCacheReady(env: [*c]j.JNIEnv, cls: j.jclass) j.jboolean {
    _ = env;
    _ = cls;
    return if (lookout_atlas_cache_ready() != 0) 1 else 0;
}

// ---- mariner settings ------------------------------------------------------
//
// The mariner state crosses as a FLAT double[] of the fields the settings UI
// surfaces (bools as 0/1, enums as ordinals) plus date_view as a String —
// never as raw struct bytes. tile57_mariner's layout is an ABI detail that has
// already moved twice; a positional array whose indices are declared in one
// place survives that, and the Kotlin mirror (MarinerState.kt) is a
// line-for-line copy of the block below.
//
// nSetMariner reads the engine's CURRENT struct and overlays only these
// indices, so the fields the UI does not surface — device_scale,
// viewing_groups_off, ignore_scamin, scamin_filter_gate — survive a
// round-trip untouched. Same trick as MarinerSettings.swift's `raw`.

const MI = struct {
    const scheme = 0;
    const depth_unit = 1;
    const shallow_contour = 2;
    const safety_contour = 3;
    const deep_contour = 4;
    const safety_depth = 5;
    const four_shade_water = 6;
    const display_base = 7;
    const display_standard = 8;
    const display_other = 9;
    const soundings = 10;
    const text_names = 11;
    const show_light_descriptions = 12;
    const text_other = 13;
    const simplified_points = 14;
    const boundary_style = 15;
    const show_full_sector_lines = 16;
    const data_quality = 17;
    const show_isolated_dangers_shallow = 18;
    const show_inform_callouts = 19;
    const show_meta_bounds = 20;
    const show_overscale = 21;
    const size_scale = 22;
    const text_size_scale = 23;
    const sounding_size_scale = 24;
    const date_dependent = 25;
    const highlight_date_dependent = 26;
    const count: j.jsize = 27;
};

fn b2f(v: bool) f64 {
    return if (v) 1 else 0;
}

/// Round and clamp into an enum's valid range. NaN lands on `lo` (the `!(…)`
/// guard is deliberate: every NaN comparison is false).
fn enumFromF64(v: f64, hi: u32) u32 {
    if (!(v >= 0)) return 0;
    const r = @round(v);
    if (r >= @as(f64, @floatFromInt(hi))) return hi;
    return @intFromFloat(r);
}

/// A size multiplier the host never means to be zero: an unset (0) field reads
/// as 1.0, matching the header's ABI-append contract.
fn scaleOr1(v: f64) f64 {
    return if (v > 0) v else 1.0;
}

/// The NUL-terminated "YYYYMMDD" as a slice. Capped one short of the array:
/// the last byte is the terminator by contract, and trusting a malformed
/// struct to contain one would let the copy below run off its buffer.
fn dateViewSlice(m: *const cc.tile57_mariner) []const u8 {
    const max = m.date_view.len - 1;
    var n: usize = 0;
    while (n < max and m.date_view[n] != 0) n += 1;
    return m.date_view[0..n];
}

fn setDateView(m: *cc.tile57_mariner, s: []const u8) void {
    @memset(&m.date_view, 0);
    const n = @min(s.len, m.date_view.len - 1); // always leave the NUL
    for (s[0..n], 0..) |ch, i| m.date_view[i] = @bitCast(ch);
}

/// void nGetMariner(long h, double[] out)
export fn Java_org_beetlebug_lookout_Lookout_nGetMariner(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, out: j.jdoubleArray) void {
    _ = cls;
    const h = fromLong(hl) orelse return;
    if (env_(env).GetArrayLength.?(env, out) < MI.count) return;
    var m: cc.tile57_mariner = undefined;
    lookout_get_mariner(h.l, &m);
    var b: [@intCast(MI.count)]f64 = undefined;
    b[MI.scheme] = @floatFromInt(m.scheme);
    b[MI.depth_unit] = @floatFromInt(m.depth_unit);
    b[MI.shallow_contour] = m.shallow_contour;
    b[MI.safety_contour] = m.safety_contour;
    b[MI.deep_contour] = m.deep_contour;
    b[MI.safety_depth] = m.safety_depth;
    b[MI.four_shade_water] = b2f(m.four_shade_water);
    b[MI.display_base] = b2f(m.display_base);
    b[MI.display_standard] = b2f(m.display_standard);
    b[MI.display_other] = b2f(m.display_other);
    b[MI.soundings] = @floatFromInt(m.soundings);
    b[MI.text_names] = b2f(m.text_names);
    b[MI.show_light_descriptions] = b2f(m.show_light_descriptions);
    b[MI.text_other] = b2f(m.text_other);
    b[MI.simplified_points] = b2f(m.simplified_points);
    b[MI.boundary_style] = @floatFromInt(m.boundary_style);
    b[MI.show_full_sector_lines] = b2f(m.show_full_sector_lines);
    b[MI.data_quality] = b2f(m.data_quality);
    b[MI.show_isolated_dangers_shallow] = b2f(m.show_isolated_dangers_shallow);
    b[MI.show_inform_callouts] = b2f(m.show_inform_callouts);
    b[MI.show_meta_bounds] = b2f(m.show_meta_bounds);
    b[MI.show_overscale] = b2f(m.show_overscale);
    b[MI.size_scale] = scaleOr1(m.size_scale);
    b[MI.text_size_scale] = scaleOr1(m.text_size_scale);
    b[MI.sounding_size_scale] = scaleOr1(m.sounding_size_scale);
    b[MI.date_dependent] = b2f(m.date_dependent);
    b[MI.highlight_date_dependent] = b2f(m.highlight_date_dependent);
    env_(env).SetDoubleArrayRegion.?(env, out, 0, MI.count, &b);
}

/// String nGetMarinerDate(long h) -- "YYYYMMDD", or "" for today.
export fn Java_org_beetlebug_lookout_Lookout_nGetMarinerDate(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    var m: cc.tile57_mariner = undefined;
    lookout_get_mariner(h.l, &m);
    var z: [9]u8 = undefined;
    const s = dateViewSlice(&m);
    @memcpy(z[0..s.len], s);
    z[s.len] = 0;
    return env_(env).NewStringUTF.?(env, &z);
}

/// void nSetMariner(long h, double[] vals, String dateView)
export fn Java_org_beetlebug_lookout_Lookout_nSetMariner(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, vals: j.jdoubleArray, date: j.jstring) void {
    _ = cls;
    const h = fromLong(hl) orelse return;
    if (env_(env).GetArrayLength.?(env, vals) < MI.count) return;
    var b: [@intCast(MI.count)]f64 = undefined;
    env_(env).GetDoubleArrayRegion.?(env, vals, 0, MI.count, &b);

    // Start from the engine's own struct so unsurfaced fields survive.
    var m: cc.tile57_mariner = undefined;
    lookout_get_mariner(h.l, &m);

    m.scheme = @intCast(enumFromF64(b[MI.scheme], 2));
    m.depth_unit = @intCast(enumFromF64(b[MI.depth_unit], 1));
    m.shallow_contour = b[MI.shallow_contour];
    m.safety_contour = b[MI.safety_contour];
    m.deep_contour = b[MI.deep_contour];
    m.safety_depth = b[MI.safety_depth];
    m.four_shade_water = b[MI.four_shade_water] != 0;
    m.display_base = b[MI.display_base] != 0;
    m.display_standard = b[MI.display_standard] != 0;
    m.display_other = b[MI.display_other] != 0;
    m.soundings = @intCast(enumFromF64(b[MI.soundings], 2));
    m.text_names = b[MI.text_names] != 0;
    m.show_light_descriptions = b[MI.show_light_descriptions] != 0;
    m.text_other = b[MI.text_other] != 0;
    m.simplified_points = b[MI.simplified_points] != 0;
    m.boundary_style = @intCast(enumFromF64(b[MI.boundary_style], 1));
    m.show_full_sector_lines = b[MI.show_full_sector_lines] != 0;
    m.data_quality = b[MI.data_quality] != 0;
    m.show_isolated_dangers_shallow = b[MI.show_isolated_dangers_shallow] != 0;
    m.show_inform_callouts = b[MI.show_inform_callouts] != 0;
    m.show_meta_bounds = b[MI.show_meta_bounds] != 0;
    m.show_overscale = b[MI.show_overscale] != 0;
    m.size_scale = scaleOr1(b[MI.size_scale]);
    m.text_size_scale = scaleOr1(b[MI.text_size_scale]);
    m.sounding_size_scale = scaleOr1(b[MI.sounding_size_scale]);
    m.date_dependent = b[MI.date_dependent] != 0;
    m.highlight_date_dependent = b[MI.highlight_date_dependent] != 0;

    if (date != null) {
        if (env_(env).GetStringUTFChars.?(env, date, null)) |cs| {
            defer env_(env).ReleaseStringUTFChars.?(env, date, cs);
            setDateView(&m, std.mem.span(cs));
        }
    } else {
        setDateView(&m, "");
    }

    lookout_set_mariner(h.l, &m);
}

// ---- pick (tap to identify) ------------------------------------------------

/// Features are collected into plain Zig memory FIRST and turned into Java
/// strings only after lookout_pick returns: the callback fires from inside the
/// engine while it holds the api lock, and calling back into the JVM there
/// invites reentrancy for nothing.
const PickCtx = struct {
    items: std.ArrayList([]u8) = .empty,
    ok: bool = true,
};

fn pickAppend(p: *PickCtx, s: [*c]const u8, n: usize) void {
    const src: []const u8 = if (s != null and n > 0) s[0..n] else "";
    const dup = gpa.dupe(u8, src) catch {
        p.ok = false;
        return;
    };
    p.items.append(gpa, dup) catch {
        gpa.free(dup);
        p.ok = false;
    };
}

fn pickFeature(
    ctx: ?*anyopaque,
    cls: [*c]const u8,
    cls_len: usize,
    s57: [*c]const u8,
    s57_len: usize,
    chart: [*c]const u8,
    chart_len: usize,
) callconv(.c) void {
    const p: *PickCtx = @ptrCast(@alignCast(ctx orelse return));
    pickAppend(p, cls, cls_len);
    pickAppend(p, s57, s57_len);
    pickAppend(p, chart, chart_len);
}

/// String[] nPick(long h, double lon, double lat) -- flat (cls, s57, chart)
/// triples, one per feature under the point. null on failure.
export fn Java_org_beetlebug_lookout_Lookout_nPick(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, lon: j.jdouble, lat: j.jdouble) j.jobjectArray {
    _ = cls;
    const h = fromLong(hl) orelse return null;

    var ctx = PickCtx{};
    defer {
        for (ctx.items.items) |it| gpa.free(it);
        ctx.items.deinit(gpa);
    }
    const cb = cc.tile57_query_cb{ .ctx = &ctx, .feature = pickFeature };
    // The RANKED pick, as the other shells use: it drops the objects a report
    // must not lead with, ranks the rest, and composes the decoded report into
    // the payload. lookout_pick is the engine's own raw pick, which emits bare
    // attributes and no report.
    lookout_pick_ranked(h.l, lon, lat, &cb);
    if (!ctx.ok) return null;

    const string_cls = env_(env).FindClass.?(env, "java/lang/String") orelse return null;
    const arr = env_(env).NewObjectArray.?(env, @intCast(ctx.items.items.len), string_cls, null) orelse return null;
    for (ctx.items.items, 0..) |it, i| {
        // NewStringUTF needs a NUL terminator; the engine hands out ptr+len.
        const z = gpa.allocSentinel(u8, it.len, 0) catch return null;
        defer gpa.free(z);
        @memcpy(z, it);
        const js = env_(env).NewStringUTF.?(env, z.ptr) orelse return null;
        env_(env).SetObjectArrayElement.?(env, arr, @intCast(i), js);
        // The default local-ref table is small; a dense pick would exhaust it.
        env_(env).DeleteLocalRef.?(env, js);
    }
    return arr;
}

// ---- raster charts -------------------------------------------------------
//
// The mariner's own pictures under the ENC: satellite imagery as MBTiles, or
// another vendor's chart. See src/raster.zig for the layer and include/lookout.h
// for what each of these means.

extern fn lookout_raster_add(h: ?*anyopaque, path: [*:0]const u8) c_int;
extern fn lookout_raster_cycle(h: ?*anyopaque) void;
extern fn lookout_raster_active_name(h: ?*anyopaque, out_len: ?*usize) [*:0]const u8;
extern fn lookout_raster_available_name(h: ?*anyopaque, out_len: ?*usize) [*:0]const u8;
extern fn lookout_raster_over_chart(h: ?*anyopaque) c_int;
extern fn lookout_raster_set_count(h: ?*anyopaque) u32;
extern fn lookout_raster_set_name(h: ?*anyopaque, i: u32, out_len: ?*usize) [*:0]const u8;
extern fn lookout_raster_set_in_view(h: ?*anyopaque, i: u32) c_int;
extern fn lookout_raster_active_index(h: ?*anyopaque) i32;
extern fn lookout_raster_select(h: ?*anyopaque, i: i32) void;
extern fn lookout_raster_set_enabled(h: ?*anyopaque, path: [*:0]const u8, enabled: c_int) c_int;
extern fn lookout_raster_enabled(h: ?*anyopaque, path: [*:0]const u8) c_int;
extern fn lookout_toggle_chart(h: ?*anyopaque) void;
extern fn lookout_chart_hidden(h: ?*anyopaque) c_int;

/// boolean nRasterAdd(long h, String path)
export fn Java_org_beetlebug_lookout_Lookout_nRasterAdd(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, path: j.jstring) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);
    return if (lookout_raster_add(h.l, @ptrCast(cpath)) != 0) 1 else 0;
}

/// void nRasterCycle(long h)
export fn Java_org_beetlebug_lookout_Lookout_nRasterCycle(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    lookout_raster_cycle(h.l);
}

/// String nRasterActiveName(long h) -- the set drawn over this view, or "".
export fn Java_org_beetlebug_lookout_Lookout_nRasterActiveName(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return env_(env).NewStringUTF.?(env, "");
    return env_(env).NewStringUTF.?(env, lookout_raster_active_name(h.l, null));
}

/// String nRasterAvailableName(long h) -- a set in view, drawn or not, or "".
export fn Java_org_beetlebug_lookout_Lookout_nRasterAvailableName(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return env_(env).NewStringUTF.?(env, "");
    return env_(env).NewStringUTF.?(env, lookout_raster_available_name(h.l, null));
}

/// boolean nRasterOverChart(long h)
export fn Java_org_beetlebug_lookout_Lookout_nRasterOverChart(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jboolean {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_raster_over_chart(h.l) != 0) 1 else 0;
}

/// int nRasterSetCount(long h)
export fn Java_org_beetlebug_lookout_Lookout_nRasterSetCount(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jint {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return @intCast(lookout_raster_set_count(h.l));
}

/// String nRasterSetName(long h, int i)
export fn Java_org_beetlebug_lookout_Lookout_nRasterSetName(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, i: j.jint) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return env_(env).NewStringUTF.?(env, "");
    if (i < 0) return env_(env).NewStringUTF.?(env, "");
    return env_(env).NewStringUTF.?(env, lookout_raster_set_name(h.l, @intCast(i), null));
}

/// boolean nRasterSetInView(long h, int i)
export fn Java_org_beetlebug_lookout_Lookout_nRasterSetInView(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, i: j.jint) j.jboolean {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    if (i < 0) return 0;
    return if (lookout_raster_set_in_view(h.l, @intCast(i)) != 0) 1 else 0;
}

/// int nRasterActiveIndex(long h) -- -1 for "no picture here".
export fn Java_org_beetlebug_lookout_Lookout_nRasterActiveIndex(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jint {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return -1;
    return lookout_raster_active_index(h.l);
}

/// void nRasterSelect(long h, int i) -- -1 turns off what is drawn here.
export fn Java_org_beetlebug_lookout_Lookout_nRasterSelect(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, i: j.jint) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    lookout_raster_select(h.l, i);
}

/// boolean nRasterSetEnabled(long h, String path, boolean on)
export fn Java_org_beetlebug_lookout_Lookout_nRasterSetEnabled(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, path: j.jstring, on: j.jboolean) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);
    return if (lookout_raster_set_enabled(h.l, @ptrCast(cpath), if (on != 0) 1 else 0) != 0) 1 else 0;
}

/// boolean nRasterEnabled(long h, String path)
export fn Java_org_beetlebug_lookout_Lookout_nRasterEnabled(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, path: j.jstring) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);
    return if (lookout_raster_enabled(h.l, @ptrCast(cpath)) != 0) 1 else 0;
}

/// void nToggleChart(long h) -- hide/show the ENC where a raster chart covers.
export fn Java_org_beetlebug_lookout_Lookout_nToggleChart(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    lookout_toggle_chart(h.l);
}

/// boolean nChartHidden(long h)
export fn Java_org_beetlebug_lookout_Lookout_nChartHidden(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jboolean {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_chart_hidden(h.l) != 0) 1 else 0;
}

// ---- wasm plugins ----------------------------------------------------------
//
// The Android analogue of ChartController.swift's plugin calls. Android has no
// bundle Resources dir, so the shell extracts the plugin set out of the APK's
// assets into filesDir/plugins and names THAT directory here — the ordinary
// directory load every host uses, so origin comes out `bundled` (nothing sets
// LOOKOUT_PLUGINS on Android) and the ids belong to the application.
//
// Every one of these is a no-op returning the failure value when the core was
// built without -Dplugins: capi.zig's entry points check at comptime, so the
// natives link and answer -1/false either way.

extern fn lookout_plugins_load(h: ?*anyopaque, dir: [*:0]const u8) c_int;
extern fn lookout_plugins_active(h: ?*anyopaque) c_int;
extern fn lookout_plugins_json(h: ?*anyopaque, out_len: ?*usize) ?[*]const u8;
extern fn lookout_plugin_config_get(h: ?*anyopaque, id: [*:0]const u8, out_len: ?*usize) ?[*]const u8;
extern fn lookout_plugin_config_set(h: ?*anyopaque, id: [*:0]const u8, json: [*:0]const u8) c_int;

/// The plugin queries hand back a BORROWED slice that carries its own length
/// and no terminator, while NewStringUTF wants a C string — so copy through a
/// NUL-terminated buffer rather than reading one byte past the borrow.
fn jstringFromSlice(env: [*c]j.JNIEnv, ptr: ?[*]const u8, len: usize) j.jstring {
    const p = ptr orelse return null;
    const buf = gpa.allocSentinel(u8, len, 0) catch return null;
    defer gpa.free(buf);
    @memcpy(buf, p[0..len]);
    return env_(env).NewStringUTF.?(env, buf.ptr);
}

/// boolean nPluginsLoad(long h, String dir) -- load and start every
/// `<id>.manifest.json` + `<id>.wasm` pair in `dir`.
export fn Java_org_beetlebug_lookout_Lookout_nPluginsLoad(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, dir: j.jstring) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cdir = env_(env).GetStringUTFChars.?(env, dir, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, dir, cdir);
    return if (lookout_plugins_load(h.l, @ptrCast(cdir)) == 0) 1 else 0;
}

/// boolean nPluginsActive(long h) -- true while a plugin layer is running.
export fn Java_org_beetlebug_lookout_Lookout_nPluginsActive(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jboolean {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_plugins_active(h.l) != 0) 1 else 0;
}

/// String nPluginsJson(long h) -- every loaded plugin with its settings schema
/// and the values in force. null when no layer is up.
export fn Java_org_beetlebug_lookout_Lookout_nPluginsJson(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    var len: usize = 0;
    return jstringFromSlice(env, lookout_plugins_json(h.l, &len), len);
}

/// String nPluginConfigGet(long h, String id) -- one plugin's settings object.
export fn Java_org_beetlebug_lookout_Lookout_nPluginConfigGet(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jstring) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    const cid = env_(env).GetStringUTFChars.?(env, id, null) orelse return null;
    defer env_(env).ReleaseStringUTFChars.?(env, id, cid);
    var len: usize = 0;
    return jstringFromSlice(env, lookout_plugin_config_get(h.l, @ptrCast(cid), &len), len);
}

// ---- plugin alerts ---------------------------------------------------------
//
// A plugin raises an alert with a severity, a title and a body. The core holds
// the set, orders it (what nobody has answered first, then the loudest, then
// the oldest) and hands it over as JSON; the shell shows it, sounds the alarms
// and acknowledges one when the mariner silences it. include/lookout.h carries
// the JSON shape, PluginAlerts.kt what severity means on screen.
//
// The whole set crosses in one string rather than a call per field. It is
// small, and the shell samples it on a schedule of its own with nothing else to
// batch it with.

extern fn lookout_plugin_alerts_json(h: ?*anyopaque, out_len: ?*usize) ?[*]const u8;
extern fn lookout_plugin_alert_ack(h: ?*anyopaque, id: u64) c_int;

/// String nPluginAlertsJson(long h) -- every live alert with its severity,
/// title, body and acknowledged flag, under the `seq` that moves whenever the
/// set does. null when no plugin layer is up.
export fn Java_org_beetlebug_lookout_Lookout_nPluginAlertsJson(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    var len: usize = 0;
    return jstringFromSlice(env, lookout_plugin_alerts_json(h.l, &len), len);
}

/// boolean nPluginAlertAck(long h, long id) -- silence ONE alert.
///
/// The core keys an alert on a u64 and Java has no unsigned long, so the id
/// crosses as a BIT PATTERN, the same round-trip the handle takes above. Ids
/// count up from 1, so the sign bit is out of reach in practice; a value cast
/// would panic on the day it were not.
export fn Java_org_beetlebug_lookout_Lookout_nPluginAlertAck(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jlong) j.jboolean {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_plugin_alert_ack(h.l, @bitCast(id)) == 0) 1 else 0;
}

// ---- overlay pick (tap an AIS target) --------------------------------------
//
// A plugin's symbol can carry a pick payload, and a tap on one pins a bubble to
// it — the Android side of what the macOS shell does with the same three calls.
// `nOverlayHit` answers the object under the finger; `nOverlayInfo` re-reads
// that object by id every frame so the bubble follows it and closes itself when
// the target ages out; `nGeoToScreen` projects its anchor.
//
// Both hit and info answer a String[2] {id, infoJson} and fill a double[2] with
// the anchor, so one crossing carries the whole object. Every pointer in the
// struct is borrowed until the next overlay call, so both strings are copied
// out before anything else runs.

const lookout_overlay_obj = extern struct {
    id: ?[*]const u8,
    id_len: usize,
    info: ?[*]const u8,
    info_len: usize,
    lon: f64,
    lat: f64,
};
extern fn lookout_overlay_hit(h: ?*anyopaque, x_pt: f32, y_pt: f32, out: *lookout_overlay_obj) c_int;
extern fn lookout_overlay_info(h: ?*anyopaque, id: [*:0]const u8, out: *lookout_overlay_obj) c_int;
extern fn lookout_geo_to_screen(h: ?*anyopaque, lon: f64, lat: f64, x_pt: *f32, y_pt: *f32) void;

/// The {id, info} pair as a Java String[2], with the anchor written into
/// `out_lonlat`. null when the object carries no payload — a symbol with
/// nothing to say is not something a bubble can be pinned to.
fn overlayPair(env: [*c]j.JNIEnv, o: *const lookout_overlay_obj, out_lonlat: j.jdoubleArray) j.jobjectArray {
    if (o.info == null or o.info_len == 0) return null;
    const string_cls = env_(env).FindClass.?(env, "java/lang/String") orelse return null;
    const arr = env_(env).NewObjectArray.?(env, 2, string_cls, null) orelse return null;
    const id = jstringFromSlice(env, o.id, o.id_len) orelse return null;
    env_(env).SetObjectArrayElement.?(env, arr, 0, id);
    env_(env).DeleteLocalRef.?(env, id);
    const info = jstringFromSlice(env, o.info, o.info_len) orelse return null;
    env_(env).SetObjectArrayElement.?(env, arr, 1, info);
    env_(env).DeleteLocalRef.?(env, info);
    if (out_lonlat != null) {
        var ll = [2]f64{ o.lon, o.lat };
        env_(env).SetDoubleArrayRegion.?(env, out_lonlat, 0, 2, &ll);
    }
    return arr;
}

/// String[] nOverlayHit(long h, float xPt, float yPt, double[] outLonLat)
export fn Java_org_beetlebug_lookout_Lookout_nOverlayHit(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, x_pt: j.jfloat, y_pt: j.jfloat, out_lonlat: j.jdoubleArray) j.jobjectArray {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    var o: lookout_overlay_obj = undefined;
    if (lookout_overlay_hit(h.l, x_pt, y_pt, &o) == 0) return null;
    return overlayPair(env, &o, out_lonlat);
}

/// String[] nOverlayInfo(long h, String id, double[] outLonLat) -- null once
/// the object is gone, which is how a pinned bubble learns to close.
export fn Java_org_beetlebug_lookout_Lookout_nOverlayInfo(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jstring, out_lonlat: j.jdoubleArray) j.jobjectArray {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    const cid = env_(env).GetStringUTFChars.?(env, id, null) orelse return null;
    defer env_(env).ReleaseStringUTFChars.?(env, id, cid);
    var o: lookout_overlay_obj = undefined;
    if (lookout_overlay_info(h.l, @ptrCast(cid), &o) == 0) return null;
    return overlayPair(env, &o, out_lonlat);
}

/// void nGeoToScreen(long h, double lon, double lat, float[] out) -- LOGICAL
/// points, the inverse of nScreenToGeo and in the same unit.
export fn Java_org_beetlebug_lookout_Lookout_nGeoToScreen(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, lon: j.jdouble, lat: j.jdouble, out: j.jfloatArray) void {
    _ = cls;
    const h = fromLong(hl) orelse return;
    var xy = [2]f32{ 0, 0 };
    lookout_geo_to_screen(h.l, lon, lat, &xy[0], &xy[1]);
    env_(env).SetFloatArrayRegion.?(env, out, 0, 2, &xy);
}

/// boolean nPluginConfigSet(long h, String id, String json)
export fn Java_org_beetlebug_lookout_Lookout_nPluginConfigSet(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jstring, json: j.jstring) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cid = env_(env).GetStringUTFChars.?(env, id, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, id, cid);
    const cjson = env_(env).GetStringUTFChars.?(env, json, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, json, cjson);
    return if (lookout_plugin_config_set(h.l, @ptrCast(cid), @ptrCast(cjson)) == 0) 1 else 0;
}

// ---- follow mode and own ship ----------------------------------------------
//
// The engine owns follow: a pan drops it, so the shell POLLS the state per
// readout tick and never remembers a tap (ChartController.swift does the
// same). Own ship's numbers are published only while the fix is live.

extern fn lookout_follow_set(h: ?*anyopaque, on: c_int) void;
extern fn lookout_follow_active(h: ?*anyopaque) c_int;
extern fn lookout_course_up_set(h: ?*anyopaque, on: c_int) void;
extern fn lookout_course_up_active(h: ?*anyopaque) c_int;
extern fn lookout_own_ship(h: ?*anyopaque, lon: *f64, lat: *f64) c_int;

/// void nFollowSet(long h, boolean on)
export fn Java_org_beetlebug_lookout_Lookout_nFollowSet(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, on: j.jboolean) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    lookout_follow_set(h.l, if (on != 0) 1 else 0);
}

/// int nFollowActive(long h) -- 0 off, 1 following, 2 armed and waiting.
export fn Java_org_beetlebug_lookout_Lookout_nFollowActive(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jint {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return lookout_follow_active(h.l);
}

/// void nCourseUpSet(long h, boolean on)
export fn Java_org_beetlebug_lookout_Lookout_nCourseUpSet(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, on: j.jboolean) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    lookout_course_up_set(h.l, if (on != 0) 1 else 0);
}

/// int nCourseUpActive(long h)
export fn Java_org_beetlebug_lookout_Lookout_nCourseUpActive(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jint {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return lookout_course_up_active(h.l);
}

/// int nOwnShip(long h, double[] out) -- fix state; out[0]=lon, out[1]=lat.
export fn Java_org_beetlebug_lookout_Lookout_nOwnShip(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, out: j.jdoubleArray) j.jint {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    if (env_(env).GetArrayLength.?(env, out) < 2) return 0;
    var buf: [2]f64 = .{ 0, 0 };
    const state = lookout_own_ship(h.l, &buf[0], &buf[1]);
    env_(env).SetDoubleArrayRegion.?(env, out, 0, 2, &buf);
    return state;
}

// ---- raster shown state and the ENC switch ---------------------------------
//
// The election is the engine's; these let the shell SAVE a choice by set and
// put it back at the next open (AppModel.restoreRasterShown's two passes).

extern fn lookout_raster_shown(h: ?*anyopaque, i: u32) c_int;
extern fn lookout_raster_set_shown(h: ?*anyopaque, i: u32, shown: c_int) void;
extern fn lookout_set_chart_hidden(h: ?*anyopaque, hidden: c_int) void;
extern fn lookout_charts_count(h: ?*anyopaque) u32;

/// boolean nRasterShown(long h, int i)
export fn Java_org_beetlebug_lookout_Lookout_nRasterShown(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, i: j.jint) j.jboolean {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    if (i < 0) return 0;
    return if (lookout_raster_shown(h.l, @intCast(i)) != 0) 1 else 0;
}

/// void nRasterSetShown(long h, int i, boolean shown)
export fn Java_org_beetlebug_lookout_Lookout_nRasterSetShown(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, i: j.jint, shown: j.jboolean) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    if (i < 0) return;
    lookout_raster_set_shown(h.l, @intCast(i), if (shown != 0) 1 else 0);
}

/// void nSetChartHidden(long h, boolean hidden)
export fn Java_org_beetlebug_lookout_Lookout_nSetChartHidden(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, hidden: j.jboolean) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    lookout_set_chart_hidden(h.l, if (hidden != 0) 1 else 0);
}

/// int nChartsCount(long h) -- 0 means no survey: "hidden" loses its meaning.
export fn Java_org_beetlebug_lookout_Lookout_nChartsCount(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jint {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return @intCast(lookout_charts_count(h.l));
}

// ---- markers ----------------------------------------------------------------
//
// Core-owned and chart-independent; the shell stores nothing and draws
// nothing. THE DROP NEVER WAITS FOR TYPING: the core names the mark.

const lookout_marker = extern struct {
    id: u64,
    lon: f64,
    lat: f64,
    name: [*:0]const u8,
    name_len: usize,
    dropped_ms: i64,
};

extern fn lookout_marker_add(h: ?*anyopaque, lon: f64, lat: f64) u64;
extern fn lookout_marker_by_id(h: ?*anyopaque, id: u64, out: *lookout_marker) c_int;
extern fn lookout_marker_at(h: ?*anyopaque, x_pt: f32, y_pt: f32, out: *lookout_marker) c_int;
extern fn lookout_marker_rename(h: ?*anyopaque, id: u64, name: [*:0]const u8) c_int;
extern fn lookout_marker_remove(h: ?*anyopaque, id: u64) c_int;

/// long nMarkerAdd(long h, double lon, double lat) -- the id, 0 refused.
export fn Java_org_beetlebug_lookout_Lookout_nMarkerAdd(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, lon: j.jdouble, lat: j.jdouble) j.jlong {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return @bitCast(lookout_marker_add(h.l, lon, lat));
}

/// String nMarkerName(long h, long id) -- null once the marker is gone. The
/// name is borrowed from the core and copied by NewStringUTF before return.
export fn Java_org_beetlebug_lookout_Lookout_nMarkerName(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jlong) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    var m: lookout_marker = undefined;
    if (lookout_marker_by_id(h.l, @bitCast(id), &m) == 0) return null;
    return env_(env).NewStringUTF.?(env, m.name);
}

/// long nMarkerAt(long h, float xPt, float yPt) -- the marker within reach of
/// a LOGICAL point (about 14 pt), or 0. Decides the chart menu's items.
export fn Java_org_beetlebug_lookout_Lookout_nMarkerAt(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, x_pt: j.jfloat, y_pt: j.jfloat) j.jlong {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    var m: lookout_marker = undefined;
    if (lookout_marker_at(h.l, x_pt, y_pt, &m) == 0) return 0;
    return @bitCast(m.id);
}

/// boolean nMarkerRename(long h, long id, String name) -- empty keeps the old
/// name; the core clips at 32 characters, so shells agree.
export fn Java_org_beetlebug_lookout_Lookout_nMarkerRename(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jlong, name: j.jstring) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cname = env_(env).GetStringUTFChars.?(env, name, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, name, cname);
    return if (lookout_marker_rename(h.l, @bitCast(id), @ptrCast(cname)) == 0) 1 else 0;
}

/// boolean nMarkerRemove(long h, long id)
export fn Java_org_beetlebug_lookout_Lookout_nMarkerRemove(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jlong) j.jboolean {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_marker_remove(h.l, @bitCast(id)) == 0) 1 else 0;
}

// ---- the chart's own files and the library ---------------------------------

extern fn lookout_aux_file(h: ?*anyopaque, cell: [*:0]const u8, name: [*:0]const u8, bytes: *[*c]const u8, len: *usize, mime: *[*c]const u8) void;
extern fn lookout_scan_charts(path: [*:0]const u8, out_len: ?*usize) [*c]const u8;
extern fn lookout_scan_zip(path: [*:0]const u8, out_len: ?*usize) [*c]const u8;

/// byte[] nAuxFile(long h, String cell, String name, String[] mimeOut) --
/// null when the chart does not carry the file. The bytes are borrowed from
/// the engine's scratch and copied into the array before return.
export fn Java_org_beetlebug_lookout_Lookout_nAuxFile(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, cell: j.jstring, name: j.jstring, mime_out: j.jobjectArray) j.jbyteArray {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    const ccell = env_(env).GetStringUTFChars.?(env, cell, null) orelse return null;
    defer env_(env).ReleaseStringUTFChars.?(env, cell, ccell);
    const cname = env_(env).GetStringUTFChars.?(env, name, null) orelse return null;
    defer env_(env).ReleaseStringUTFChars.?(env, name, cname);

    var bytes: [*c]const u8 = null;
    var len: usize = 0;
    var mime: [*c]const u8 = null;
    lookout_aux_file(h.l, @ptrCast(ccell), @ptrCast(cname), &bytes, &len, &mime);
    if (bytes == null or len == 0) return null;

    const arr = env_(env).NewByteArray.?(env, @intCast(len)) orelse return null;
    env_(env).SetByteArrayRegion.?(env, arr, 0, @intCast(len), @ptrCast(bytes));
    if (mime != null and mime_out != null and env_(env).GetArrayLength.?(env, mime_out) >= 1) {
        const ms = env_(env).NewStringUTF.?(env, mime);
        env_(env).SetObjectArrayElement.?(env, mime_out, 0, ms);
    }
    return arr;
}

/// String nScanCharts(String path) -- the scan JSON, or null. NOT REENTRANT:
/// the two scan calls share one buffer in the core; the shell serializes.
export fn Java_org_beetlebug_lookout_Lookout_nScanCharts(env: [*c]j.JNIEnv, cls: j.jclass, path: j.jstring, zip: j.jboolean) j.jstring {
    _ = cls;
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse return null;
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);

    var len: usize = 0;
    const json = if (zip != 0)
        lookout_scan_zip(@ptrCast(cpath), &len)
    else
        lookout_scan_charts(@ptrCast(cpath), &len);
    if (json == null or len == 0) return null;

    // A COUNTED buffer, decoded by length, never as a C string — but
    // NewStringUTF wants a terminator, so copy through one.
    const copy = gpa.allocSentinel(u8, len, 0) catch return null;
    defer gpa.free(copy);
    @memcpy(copy[0..len], json[0..len]);
    return env_(env).NewStringUTF.?(env, copy.ptr);
}

// ---- portrayal quick toggles ------------------------------------------------

extern fn lookout_toggle_text(h: ?*anyopaque) void;
extern fn lookout_toggle_soundings(h: ?*anyopaque) void;
extern fn lookout_toggle_other_category(h: ?*anyopaque) void;

/// void nToggleText(long h)
export fn Java_org_beetlebug_lookout_Lookout_nToggleText(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    lookout_toggle_text(h.l);
}

/// void nToggleSoundings(long h)
export fn Java_org_beetlebug_lookout_Lookout_nToggleSoundings(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    lookout_toggle_soundings(h.l);
}

/// void nToggleOtherCategory(long h)
export fn Java_org_beetlebug_lookout_Lookout_nToggleOtherCategory(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) void {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return;
    lookout_toggle_other_category(h.l);
}

// ---- the bake ---------------------------------------------------------------
//
// The import pipeline's engine half: run the phased bake — cells, then
// sheets, then the lift — on a thread of its own and let Java POLL a
// snapshot, the way the Windows shell's BakeJob does. No callback ever
// crosses into the JVM: a bake worker is not an attached thread and must
// not become one just to move a progress bar.

const BakeJob = struct {
    thread: ?std.Thread = null,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    baked: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    phase_offset: u32 = 0,
    total: u32 = 0,

    source: [:0]u8,
    ins: [][:0]u8,
    outs: [][:0]u8,
    cells: usize,
    sheets: usize,
    lifts: usize,
    archive: bool,

    fn free(self: *BakeJob) void {
        for (self.ins) |s| gpa.free(s);
        for (self.outs) |s| gpa.free(s);
        gpa.free(self.ins);
        gpa.free(self.outs);
        gpa.free(self.source);
        gpa.destroy(self);
    }
};

fn bakeProgress(ctx: ?*anyopaque, done: u32, total: u32) callconv(.c) bool {
    _ = total;
    const job: *BakeJob = @ptrCast(@alignCast(ctx.?));
    job.done.store(job.phase_offset + done, .release);
    return !job.cancelled.load(.acquire);
}

fn bakeWorker(job: *BakeJob) void {
    const cpus = std.Thread.getCpuCount() catch 4;
    // A MEMORY bound, not a speed dial: each worker holds a whole cell.
    const workers: u32 = @intCast(@max(1, @min(8, cpus)));

    const ins_c = gpa.alloc([*c]const u8, job.ins.len) catch {
        job.running.store(false, .release);
        return;
    };
    defer gpa.free(ins_c);
    const outs_c = gpa.alloc([*c]const u8, job.outs.len) catch {
        job.running.store(false, .release);
        return;
    };
    defer gpa.free(outs_c);
    for (job.ins, 0..) |s, i| ins_c[i] = s.ptr;
    for (job.outs, 0..) |s, i| outs_c[i] = s.ptr;

    var st: cc.tile57_status = cc.TILE57_OK;
    var err: cc.tile57_error = undefined;
    var total_baked: u32 = 0;

    // Sorted by kind upstream, so each phase is one contiguous run.
    if (job.cells > 0 and !job.cancelled.load(.acquire)) {
        job.phase_offset = 0;
        var n: u32 = 0;
        st = if (job.archive)
            cc.tile57_bake_zip_charts(job.source.ptr, ins_c.ptr, outs_c.ptr, job.cells, workers, bakeProgress, null, job, &n, &err)
        else
            cc.tile57_bake_files(ins_c.ptr, outs_c.ptr, job.cells, workers, bakeProgress, null, job, &n, &err);
        total_baked += n;
    }
    if (st == cc.TILE57_OK and job.sheets > 0 and !job.cancelled.load(.acquire)) {
        job.phase_offset = @intCast(job.cells);
        var n: u32 = 0;
        st = if (job.archive)
            cc.tile57_bake_zip_rasters(job.source.ptr, ins_c.ptr + job.cells, outs_c.ptr + job.cells, job.sheets, workers, bakeProgress, null, job, &n, &err)
        else
            cc.tile57_bake_rasters(ins_c.ptr + job.cells, outs_c.ptr + job.cells, job.sheets, workers, bakeProgress, null, job, &n, &err);
        total_baked += n;
    }
    // Only an archive holds anything to lift; in a folder those files are
    // already where the engine can read them.
    if (st == cc.TILE57_OK and job.archive and job.lifts > 0 and !job.cancelled.load(.acquire)) {
        job.phase_offset = @intCast(job.cells + job.sheets);
        const off = job.cells + job.sheets;
        var n: u32 = 0;
        st = cc.tile57_zip_extract(job.source.ptr, ins_c.ptr + off, outs_c.ptr + off, job.lifts, bakeProgress, job, &n, &err);
        total_baked += n;
    }

    job.baked.store(total_baked, .release);
    // A cancelled bake is not a failure: whatever landed is a usable library.
    job.ok.store(st == cc.TILE57_OK, .release);
    job.running.store(false, .release);
}

/// long nBakeStart(String source, String[] ins, String[] outs, int cells,
///                 int sheets, int lifts, boolean zip) -- 0 when nothing
/// starts. `ins`/`outs` are kind-contiguous: cells, then sheets, then lifts.
export fn Java_org_beetlebug_lookout_Lookout_nBakeStart(env: [*c]j.JNIEnv, cls: j.jclass, source: j.jstring, ins: j.jobjectArray, outs: j.jobjectArray, cells: j.jint, sheets: j.jint, lifts: j.jint, zip: j.jboolean) j.jlong {
    _ = cls;
    const n_ins: usize = @intCast(env_(env).GetArrayLength.?(env, ins));
    const n_outs: usize = @intCast(env_(env).GetArrayLength.?(env, outs));
    const want: usize = @intCast(cells + sheets + lifts);
    if (n_ins != want or n_outs != want or want == 0) return 0;

    const csrc = env_(env).GetStringUTFChars.?(env, source, null) orelse return 0;
    const src_copy = gpa.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(csrc)))) catch {
        env_(env).ReleaseStringUTFChars.?(env, source, csrc);
        return 0;
    };
    env_(env).ReleaseStringUTFChars.?(env, source, csrc);

    // Copy-and-release per element, the nOpenCharts lesson: ART's local
    // reference table holds 512 and an archive holds thousands of entries.
    const takeAll = struct {
        fn take(e: [*c]j.JNIEnv, arr: j.jobjectArray, n: usize) ?[][:0]u8 {
            const out = gpa.alloc([:0]u8, n) catch return null;
            var got: usize = 0;
            while (got < n) : (got += 1) {
                const s: j.jstring = @ptrCast(env_(e).GetObjectArrayElement.?(e, arr, @intCast(got)));
                const c = env_(e).GetStringUTFChars.?(e, s, null) orelse {
                    for (out[0..got]) |x| gpa.free(x);
                    gpa.free(out);
                    return null;
                };
                const copy = gpa.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(c)))) catch {
                    env_(e).ReleaseStringUTFChars.?(e, s, c);
                    env_(e).DeleteLocalRef.?(e, s);
                    for (out[0..got]) |x| gpa.free(x);
                    gpa.free(out);
                    return null;
                };
                env_(e).ReleaseStringUTFChars.?(e, s, c);
                env_(e).DeleteLocalRef.?(e, s);
                out[got] = copy;
            }
            return out;
        }
    }.take;

    const ins_z = takeAll(env, ins, want) orelse {
        gpa.free(src_copy);
        return 0;
    };
    const outs_z = takeAll(env, outs, want) orelse {
        for (ins_z) |s| gpa.free(s);
        gpa.free(ins_z);
        gpa.free(src_copy);
        return 0;
    };

    const job = gpa.create(BakeJob) catch {
        for (ins_z) |s| gpa.free(s);
        gpa.free(ins_z);
        for (outs_z) |s| gpa.free(s);
        gpa.free(outs_z);
        gpa.free(src_copy);
        return 0;
    };
    job.* = .{
        .source = src_copy,
        .ins = ins_z,
        .outs = outs_z,
        .cells = @intCast(cells),
        .sheets = @intCast(sheets),
        .lifts = @intCast(lifts),
        .archive = zip != 0,
        .total = @intCast(want),
    };
    job.thread = std.Thread.spawn(.{}, bakeWorker, .{job}) catch {
        job.free();
        return 0;
    };
    return @bitCast(@intFromPtr(job));
}

/// boolean nBakePoll(long job, int[] out) -- true while running;
/// out[0] = done, out[1] = total, out[2] = baked, out[3] = ok.
export fn Java_org_beetlebug_lookout_Lookout_nBakePoll(env: [*c]j.JNIEnv, cls: j.jclass, jl: j.jlong, out: j.jintArray) j.jboolean {
    _ = cls;
    if (jl == 0) return 0;
    const job: *BakeJob = @ptrFromInt(@as(usize, @bitCast(jl)));
    if (env_(env).GetArrayLength.?(env, out) >= 4) {
        var buf: [4]j.jint = .{
            @intCast(job.done.load(.acquire)),
            @intCast(job.total),
            @intCast(job.baked.load(.acquire)),
            if (job.ok.load(.acquire)) 1 else 0,
        };
        env_(env).SetIntArrayRegion.?(env, out, 0, 4, &buf);
    }
    return if (job.running.load(.acquire)) 1 else 0;
}

/// void nBakeCancel(long job) -- tile57 stops at the next chart boundary.
export fn Java_org_beetlebug_lookout_Lookout_nBakeCancel(env: [*c]j.JNIEnv, cls: j.jclass, jl: j.jlong) void {
    _ = env;
    _ = cls;
    if (jl == 0) return;
    const job: *BakeJob = @ptrFromInt(@as(usize, @bitCast(jl)));
    job.cancelled.store(true, .release);
}

/// void nBakeFree(long job) -- joins the worker; cancel a running bake first
/// or this blocks about one chart's bake time.
export fn Java_org_beetlebug_lookout_Lookout_nBakeFree(env: [*c]j.JNIEnv, cls: j.jclass, jl: j.jlong) void {
    _ = env;
    _ = cls;
    if (jl == 0) return;
    const job: *BakeJob = @ptrFromInt(@as(usize, @bitCast(jl)));
    if (job.thread) |t| t.join();
    job.free();
}

// ---- plugin install and consent ---------------------------------------------
//
// NOTHING IS INSTALLED BEFORE ITS PERMISSIONS ARE SHOWN. The consent
// sentences come from the core (lookout_plugin_inspect), so every shell
// shows the same words. Also lookout_plugins_load_installed, so the set a
// mariner installed comes back at every open like the other shells' does.

extern fn lookout_plugins_install_root(h: ?*anyopaque, path: [*:0]const u8) c_int;
extern fn lookout_plugin_tables_json(h: ?*anyopaque, out_len: ?*usize) [*c]const u8;
extern fn lookout_plugin_table_rows(h: ?*anyopaque, id: [*:0]const u8, key: [*:0]const u8, sort_key: ?[*:0]const u8, ascending: c_int, out_len: ?*usize) [*c]const u8;
extern fn lookout_plugin_table_open(h: ?*anyopaque, id: [*:0]const u8, key: [*:0]const u8, open: c_int) c_int;
extern fn lookout_plugins_load_installed(h: ?*anyopaque) c_int;
extern fn lookout_plugin_inspect(h: ?*anyopaque, path: [*:0]const u8, out_len: ?*usize) [*c]const u8;
extern fn lookout_plugin_install(h: ?*anyopaque, path: [*:0]const u8) [*c]const u8;
extern fn lookout_plugin_uninstall(h: ?*anyopaque, id: [*:0]const u8) c_int;
extern fn lookout_plugin_grant_set(h: ?*anyopaque, id: [*:0]const u8, cap: [*:0]const u8, on: c_int) c_int;

/// boolean nPluginsInstallRoot(long h, String path) -- Android's files dir
/// has no path in the environment, so the shell names the install root here,
/// before any other plugin call.
export fn Java_org_beetlebug_lookout_Lookout_nPluginsInstallRoot(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, path: j.jstring) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);
    return if (lookout_plugins_install_root(h.l, @ptrCast(cpath)) == 0) 1 else 0;
}

/// boolean nPluginsLoadInstalled(long h)
export fn Java_org_beetlebug_lookout_Lookout_nPluginsLoadInstalled(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jboolean {
    _ = cls;
    _ = env;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_plugins_load_installed(h.l) == 0) 1 else 0;
}

/// String nPluginInspect(long h, String path) -- the consent JSON, or null
/// when no plugin layer can come up. Borrowed, so copied out here.
export fn Java_org_beetlebug_lookout_Lookout_nPluginInspect(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, path: j.jstring) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse return null;
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);
    var len: usize = 0;
    const json = lookout_plugin_inspect(h.l, @ptrCast(cpath), &len);
    if (json == null or len == 0) return null;
    const copy = gpa.allocSentinel(u8, len, 0) catch return null;
    defer gpa.free(copy);
    @memcpy(copy[0..len], json[0..len]);
    return env_(env).NewStringUTF.?(env, copy.ptr);
}

/// String nPluginInstall(long h, String path) -- null on success, else one
/// sentence saying why, ready to show.
export fn Java_org_beetlebug_lookout_Lookout_nPluginInstall(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, path: j.jstring) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return env_(env).NewStringUTF.?(env, "The plugin layer could not start.");
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse return null;
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);
    const msg = lookout_plugin_install(h.l, @ptrCast(cpath));
    if (msg == null) return null;
    return env_(env).NewStringUTF.?(env, msg);
}

/// String nPluginTables(long h) -- every table the loaded plugins declare,
/// or null when no layer is up. Borrowed, so copied out here.
export fn Java_org_beetlebug_lookout_Lookout_nPluginTables(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    var len: usize = 0;
    const json = lookout_plugin_tables_json(h.l, &len);
    if (json == null or len == 0) return null;
    const copy = gpa.allocSentinel(u8, len, 0) catch return null;
    defer gpa.free(copy);
    @memcpy(copy[0..len], json[0..len]);
    return env_(env).NewStringUTF.?(env, copy.ptr);
}

/// String nPluginTableRows(long h, String id, String key, String sortKey,
/// boolean ascending) -- one table's rows, already in shown order; null when
/// the plugin or the table is unknown.
export fn Java_org_beetlebug_lookout_Lookout_nPluginTableRows(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jstring, key: j.jstring, sort_key: j.jstring, ascending: j.jboolean) j.jstring {
    _ = cls;
    const h = fromLong(hl) orelse return null;
    const cid = env_(env).GetStringUTFChars.?(env, id, null) orelse return null;
    defer env_(env).ReleaseStringUTFChars.?(env, id, cid);
    const ckey = env_(env).GetStringUTFChars.?(env, key, null) orelse return null;
    defer env_(env).ReleaseStringUTFChars.?(env, key, ckey);
    const csort = if (sort_key != null) env_(env).GetStringUTFChars.?(env, sort_key, null) else null;
    defer if (csort) |s| env_(env).ReleaseStringUTFChars.?(env, sort_key, s);
    var len: usize = 0;
    const json = lookout_plugin_table_rows(h.l, @ptrCast(cid), @ptrCast(ckey), @ptrCast(csort), if (ascending != 0) 1 else 0, &len);
    if (json == null or len == 0) return null;
    const copy = gpa.allocSentinel(u8, len, 0) catch return null;
    defer gpa.free(copy);
    @memcpy(copy[0..len], json[0..len]);
    return env_(env).NewStringUTF.?(env, copy.ptr);
}

/// boolean nPluginTableOpen(long h, String id, String key, boolean open) --
/// tell the plugin its table is on screen: it builds no rows until then.
export fn Java_org_beetlebug_lookout_Lookout_nPluginTableOpen(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jstring, key: j.jstring, open: j.jboolean) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cid = env_(env).GetStringUTFChars.?(env, id, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, id, cid);
    const ckey = env_(env).GetStringUTFChars.?(env, key, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, key, ckey);
    return if (lookout_plugin_table_open(h.l, @ptrCast(cid), @ptrCast(ckey), if (open != 0) 1 else 0) == 0) 1 else 0;
}

/// boolean nPluginUninstall(long h, String id)
export fn Java_org_beetlebug_lookout_Lookout_nPluginUninstall(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jstring) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cid = env_(env).GetStringUTFChars.?(env, id, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, id, cid);
    return if (lookout_plugin_uninstall(h.l, @ptrCast(cid)) == 0) 1 else 0;
}

/// boolean nPluginGrantSet(long h, String id, String cap, boolean on) -- a
/// live revoke; the plugin keeps running and the lost call answers -1.
export fn Java_org_beetlebug_lookout_Lookout_nPluginGrantSet(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jstring, cap: j.jstring, on: j.jboolean) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cid = env_(env).GetStringUTFChars.?(env, id, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, id, cid);
    const ccap = env_(env).GetStringUTFChars.?(env, cap, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, cap, ccap);
    return if (lookout_plugin_grant_set(h.l, @ptrCast(cid), @ptrCast(ccap), if (on != 0) 1 else 0) == 0) 1 else 0;
}

// ---- alt chart styles (an online map AS the chart) --------------------------
//
// The core takes a MapLibre style as JSON and asks back for every tile the
// style's sources name (lookout does no networking). The ask lands on the
// render thread with the api lock held, so nothing here may touch the JVM:
// requests are parked in a ring the Java side drains through nTilePoll — the
// same no-upcall pattern as the bake job — and answered from any thread with
// nTileRespond, which the C ABI documents as lock-free.

extern fn lookout_alt_chart_style_json(h: ?*anyopaque, json: ?[*]const u8, len: usize) c_int;
extern fn lookout_alt_chart_style_active(h: ?*anyopaque) c_int;
const TileRequestFn = *const fn (user: ?*anyopaque, source: [*c]const u8, req_id: u64, z: c_int, x: c_int, y: c_int) callconv(.c) void;
extern fn lookout_set_tile_provider(h: ?*anyopaque, cb: ?TileRequestFn, user: ?*anyopaque) void;
extern fn lookout_tile_respond(h: ?*anyopaque, req_id: u64, bytes: ?*const anyopaque, len: usize, status: c_int) void;

const TileAsk = struct {
    id: u64,
    z: i32,
    x: i32,
    y: i32,
    /// Style source names are short ("sat", "openmaptiles"); a name that does
    /// not fit is truncated, which at worst mis-keys one source's template.
    source: [64]u8,
    slen: u8,
};

/// One engine at a time on Android, so the ring is a global. Guarded by a
/// spinlock: both sides hold it for a few loads and stores.
var tile_lock = std.atomic.Value(bool).init(false);
var tile_ring: [256]TileAsk = undefined;
var tile_count: usize = 0;

fn tileLockAcquire() void {
    while (tile_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn tileLockRelease() void {
    tile_lock.store(false, .release);
}

fn tileRequestCb(user: ?*anyopaque, source: [*c]const u8, req_id: u64, z: c_int, x: c_int, y: c_int) callconv(.c) void {
    tileLockAcquire();
    if (tile_count >= tile_ring.len) {
        tileLockRelease();
        // Answered, not dropped: a tile nobody answers is a hole in the chart
        // that never fills. tile_respond is the one call allowed from here.
        lookout_tile_respond(user, req_id, null, 0, 2);
        return;
    }
    const ask = &tile_ring[tile_count];
    ask.id = req_id;
    ask.z = z;
    ask.x = x;
    ask.y = y;
    ask.slen = 0;
    if (source) |s| {
        var i: usize = 0;
        while (s[i] != 0 and i < ask.source.len) : (i += 1) ask.source[i] = s[i];
        ask.slen = @intCast(i);
    }
    tile_count += 1;
    tileLockRelease();
}

/// boolean nAltStyleSet(long h, String json) -- draw the host's style instead
/// of the portrayal; null or empty restores lookout's chart. Setting a style
/// installs the tile provider; clearing it uninstalls it and drops what was
/// queued (the core fails unanswered tiles itself once the provider is gone).
export fn Java_org_beetlebug_lookout_Lookout_nAltStyleSet(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, json: j.jstring) j.jboolean {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    if (json == null) {
        lookout_set_tile_provider(h.l, null, null);
        tileLockAcquire();
        tile_count = 0;
        tileLockRelease();
        // This entry answers 1 on success, unlike most of the C ABI.
        return if (lookout_alt_chart_style_json(h.l, null, 0) != 0) 1 else 0;
    }
    const cjson = env_(env).GetStringUTFChars.?(env, json, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, json, cjson);
    const len = std.mem.len(@as([*:0]const u8, @ptrCast(cjson)));
    lookout_set_tile_provider(h.l, tileRequestCb, h.l);
    return if (lookout_alt_chart_style_json(h.l, @ptrCast(cjson), len) != 0) 1 else 0;
}

/// boolean nAltStyleActive(long h)
export fn Java_org_beetlebug_lookout_Lookout_nAltStyleActive(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong) j.jboolean {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    return if (lookout_alt_chart_style_active(h.l) != 0) 1 else 0;
}

/// int nTilePoll(long h, long[] ids, int[] zxy, String[] sources) -- drain up
/// to ids.length parked tile asks. zxy carries z,x,y per ask, packed in
/// triples. Returns how many were taken.
export fn Java_org_beetlebug_lookout_Lookout_nTilePoll(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, ids: j.jlongArray, zxy: j.jintArray, sources: j.jobjectArray) j.jint {
    _ = cls;
    if (fromLong(hl) == null) return 0;
    const cap: usize = @intCast(env_(env).GetArrayLength.?(env, ids));
    if (cap == 0) return 0;

    // Copy out under the lock, release, THEN touch the JVM: NewStringUTF can
    // trigger a GC pause, and the render thread must never spin behind one.
    var taken: [64]TileAsk = undefined;
    var n: usize = 0;
    tileLockAcquire();
    while (n < tile_count and n < cap and n < taken.len) : (n += 1) taken[n] = tile_ring[n];
    const left = tile_count - n;
    var i: usize = 0;
    while (i < left) : (i += 1) tile_ring[i] = tile_ring[i + n];
    tile_count = left;
    tileLockRelease();
    if (n == 0) return 0;

    var jids: [64]j.jlong = undefined;
    var jzxy: [192]j.jint = undefined;
    for (taken[0..n], 0..) |ask, k| {
        jids[k] = @bitCast(ask.id);
        jzxy[k * 3 + 0] = ask.z;
        jzxy[k * 3 + 1] = ask.x;
        jzxy[k * 3 + 2] = ask.y;
        var name: [65:0]u8 = undefined;
        @memcpy(name[0..ask.slen], ask.source[0..ask.slen]);
        name[ask.slen] = 0;
        const s = env_(env).NewStringUTF.?(env, &name);
        env_(env).SetObjectArrayElement.?(env, sources, @intCast(k), s);
        env_(env).DeleteLocalRef.?(env, s);
    }
    env_(env).SetLongArrayRegion.?(env, ids, 0, @intCast(n), &jids);
    env_(env).SetIntArrayRegion.?(env, zxy, 0, @intCast(n * 3), &jzxy);
    return @intCast(n);
}

/// void nTileRespond(long h, long id, byte[] bytes, int status) -- answer one
/// ask from any thread. status 0 takes bytes; 1 is "no tile there"; 2 is
/// "tried and failed".
export fn Java_org_beetlebug_lookout_Lookout_nTileRespond(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, id: j.jlong, bytes: j.jbyteArray, status: j.jint) void {
    _ = cls;
    const h = fromLong(hl) orelse return;
    const req: u64 = @bitCast(id);
    if (status != 0 or bytes == null) {
        lookout_tile_respond(h.l, req, null, 0, status);
        return;
    }
    const len: usize = @intCast(env_(env).GetArrayLength.?(env, bytes));
    const p = env_(env).GetByteArrayElements.?(env, bytes, null) orelse {
        lookout_tile_respond(h.l, req, null, 0, 2);
        return;
    };
    defer env_(env).ReleaseByteArrayElements.?(env, bytes, p, j.JNI_ABORT);
    lookout_tile_respond(h.l, req, p, len, 0);
}

extern fn lookout_open_file(h: ?*anyopaque, path: [*:0]const u8) c_int;

/// int nOpenFile(long h, String path) -- offer a file the mariner opened to
/// the plugins: 1 claimed, 0 none does, -1 claimed but could not be given.
export fn Java_org_beetlebug_lookout_Lookout_nOpenFile(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, path: j.jstring) j.jint {
    _ = cls;
    const h = fromLong(hl) orelse return 0;
    const cpath = env_(env).GetStringUTFChars.?(env, path, null) orelse return 0;
    defer env_(env).ReleaseStringUTFChars.?(env, path, cpath);
    return lookout_open_file(h.l, @ptrCast(cpath));
}
