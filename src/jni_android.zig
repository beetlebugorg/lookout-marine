//! JNI bindings for the Android Java shell (org.beetlebug.lookout.Lookout).
//! Compiled into liblookout_marine.a on `-Dbackend=vk` builds only (see
//! capi.zig's comptime include). The Java side owns the Activity, the
//! SurfaceView and all gestures; these natives are the bridge to the C ABI —
//! the exact Android analogue of the iOS app driving lookout from Swift.
//!
//! Units: every geometry-taking native works in LOGICAL points (Android dp) —
//! the camera's own unit. Java divides pixels by DisplayMetrics.density before
//! crossing; the ml host derives pixel_density from surface px / resize() points.
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
extern fn lookout_alt_chart_style(h: ?*anyopaque, url: ?[*:0]const u8) void;
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
    // Both arrays are needed to RELEASE: ReleaseStringUTFChars wants the
    // jstring its chars came from, so the local refs are kept alongside.
    const strs = gpa.alloc(j.jstring, n) catch return 0;
    defer gpa.free(strs);
    const cs = gpa.alloc([*:0]const u8, n) catch return 0;
    defer gpa.free(cs);
    var got: usize = 0;
    defer for (0..got) |i| env_(env).ReleaseStringUTFChars.?(env, strs[i], @ptrCast(cs[i]));
    while (got < n) : (got += 1) {
        const s: j.jstring = @ptrCast(env_(env).GetObjectArrayElement.?(env, paths, @intCast(got)));
        const c = env_(env).GetStringUTFChars.?(env, s, null) orelse return 0;
        strs[got] = s;
        cs[got] = @ptrCast(c);
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
/// void nAltChartStyle(long h, String url) — choose the chart: a MapLibre
/// style url (or the style document itself) renders INSTEAD of the built-in
/// chart; null or empty returns to it. Mirrors the Apple shell's chart links.
export fn Java_org_beetlebug_lookout_Lookout_nAltChartStyle(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, url: j.jstring) void {
    _ = cls;
    const h = fromLong(hl) orelse return;
    if (url == null) {
        lookout_alt_chart_style(h.l, null);
        return;
    }
    const cs = env_(env).GetStringUTFChars.?(env, url, null) orelse return;
    defer env_(env).ReleaseStringUTFChars.?(env, url, cs);
    lookout_alt_chart_style(h.l, @ptrCast(cs));
}

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
