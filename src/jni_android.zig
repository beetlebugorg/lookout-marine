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
//! Threading: gestures call in on the main thread while LookoutView's frame
//! loop calls nRender/nTickAnim on a dedicated render thread — the C ABI's
//! api lock serializes them (its documented shape). nClose is externally
//! serialized: the shell stops the render thread before closing.
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

/// DisplayMetrics.density. The surface cannot be trusted for this on Android:
/// across a rotation its extent lags the new logical size by a frame.
export fn Java_org_beetlebug_lookout_Lookout_nSetDensity(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, d: j.jfloat) void {
    _ = env;
    _ = cls;
    const h = fromLong(hl) orelse return;
    lookout_set_pixel_density(h.l, d);
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
/// Takes LOGICAL points like every other geometry native and scales to pixels
/// here, because the underlying C entry point is one of the few that is still
/// pixel-only.
export fn Java_org_beetlebug_lookout_Lookout_nScreenToGeo(env: [*c]j.JNIEnv, cls: j.jclass, hl: j.jlong, x_pt: j.jfloat, y_pt: j.jfloat, out: j.jdoubleArray) void {
    _ = cls;
    const h = fromLong(hl) orelse return;
    if (env_(env).GetArrayLength.?(env, out) < 2) return;
    const d = lookout_pixel_density(h.l);
    const s = if (d > 0) d else 1.0;
    var buf: [2]f64 = undefined;
    lookout_screen_to_geo(h.l, x_pt * s, y_pt * s, &buf[0], &buf[1]);
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
    lookout_pick(h.l, lon, lat, &cb);
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
