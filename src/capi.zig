//! C ABI for lookout-core (see include/lookout.h). A thin, 1:1 wrapper over the
//! Zig `Lookout` widget. Uses the C allocator so C hosts need no allocator.
const std = @import("std");
const builtin = @import("builtin");

const lk = @import("root.zig");
const cc = @import("c.zig").c;

/// The plugin host, for the install surface below. Present only when the
/// build has one; every entry point checks, so a build without plugins keeps
/// exporting the symbols and answers "no".
const plugins_enabled = @import("build_options").plugins;
const phost = if (plugins_enabled) @import("plugin/host.zig") else struct {};

const capi_io = std.Io.Threaded.global_single_threaded.io();

// On Android, native stderr goes nowhere — a Zig panic (Debug safety check,
// unreachable, …) would die as a bare SIGABRT with no message in logcat. Route
// the panic message through the android log first, then abort as usual.
extern "c" fn __android_log_print(prio: c_int, tag: [*:0]const u8, fmt: [*:0]const u8, ...) c_int;
fn androidPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = __android_log_print(6, "lookout", "PANIC: %.*s (ra=0x%zx)", @as(c_int, @intCast(@min(msg.len, 512))), msg.ptr, first_trace_addr orelse 0);
    std.process.abort();
}
pub const panic = if (builtin.abi.isAndroid())
    std.debug.FullPanic(androidPanic)
else
    std.debug.FullPanic(std.debug.defaultPanic);

const gpa = std.heap.c_allocator;

pub const lookout = opaque {};
pub const lookout_view = extern struct { lon: f64, lat: f64, zoom: f64, rotation_deg: f64 };

fn cast(h: ?*lookout) *lk.Lookout {
    return @ptrCast(@alignCast(h.?));
}
// Every handle-taking export holds the handle's API lock for its duration:
// with the host's render loop on a DEDICATED THREAD, gestures (main thread)
// and lookout_render (render thread) enter this ABI concurrently. close() is
// the exception — destroying a lock someone may be waiting on is UB, so the
// host must externally serialize close against all other calls (the app does:
// close hops through the render queue).
fn locked(h: ?*lookout) *lk.Lookout {
    const l = cast(h);
    l.apiLock();
    return l;
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
/// n may be 0: a library of raster charts alone opens with no vector chart,
/// and the host adds the pictures with lookout_raster_add afterwards.
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
/// Kinds beyond the Apple pair exist only in the superset enums of the
/// SDL/Vulkan backends — gate on the field so the Metal build still compiles.
/// The desktop kinds (win32/x11/wayland) each pass a struct lookout.h declares.
fn nativeKind(kind: c_int) ?lk.NativeKind {
    if (kind == 0) return .none;
    if (@hasField(lk.NativeKind, "metal_layer") and kind == 1) return .metal_layer;
    if (@hasField(lk.NativeKind, "win32_hwnd") and kind == 4) return .win32_hwnd;
    if (@hasField(lk.NativeKind, "x11_window") and kind == 5) return .x11_window;
    if (@hasField(lk.NativeKind, "android_window") and kind == 7) return .android_window;
    if (@hasField(lk.NativeKind, "wayland_surface") and kind == 8) return .wayland_surface;
    if (@hasField(lk.NativeKind, "d3d12_panel") and kind == 10) return .d3d12_panel;
    return null;
}

/// The core-owned IDXGISwapChain* for the host's SwapChainPanel
/// (LOOKOUT_NATIVE_D3D12_PANEL only; NULL on any other kind or backend).
export fn lookout_d3d12_swapchain(h: ?*lookout) ?*anyopaque {
    const l = locked(h orelse return null);
    defer l.apiUnlock();
    return l.ct.swapchainPtr();
}

/// Give up the host's surface WITHOUT closing the chart, for a shell whose
/// window comes and goes under it (an Android SurfaceView loses its surface
/// every time the app backgrounds). The GPU surface and its swapchain go; the
/// opened cells, the atlas bake, the scene and the plugin layer all stand, so
/// lookout_attach_surface restores the view in milliseconds where reopening
/// takes seconds. Also hands back the engine's reclaimable caches if a memory
/// warning had asked for them, there being no frame left to do it in.
///
/// The native handle is free the moment this returns. Externally serialized
/// like lookout_close: no other call may be in flight, and nothing may render
/// until a surface is attached again.
export fn lookout_detach_surface(h: ?*lookout) void {
    const l = locked(h orelse return);
    defer l.apiUnlock();
    l.detachSurface();
}

/// Present on a new native surface after a detach. `kind` and `native_handle`
/// are the pair lookout_open_in_window took; width and height are LOGICAL
/// points. 0 on success, -1 on failure, which leaves the chart detached.
export fn lookout_attach_surface(h: ?*lookout, kind: c_int, native_handle: ?*anyopaque, width: u32, height: u32) c_int {
    const l = locked(h orelse return -1);
    defer l.apiUnlock();
    const k = nativeKind(kind) orelse return -1;
    l.attachSurface(k, native_handle orelse return -1, width, height) catch return -1;
    return 0;
}

export fn lookout_close(h: ?*lookout) void {
    if (h) |x| cast(x).close();
}

/// Load and start the wasm plugins in `dir` — every `<id>.manifest.json` with
/// an `<id>.wasm` beside it. 0 on success, -1 if the directory is unreadable
/// or this build has no plugin host. A plugin that fails to load is logged and
/// skipped; the others still run, so 0 does not mean every module started.
///
/// Setting LOOKOUT_PLUGINS before opening does the same thing without a call.
export fn lookout_plugins_load(h: ?*lookout, dir: [*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    l.loadPlugins(std.mem.span(dir)) catch return -1;
    return 0;
}

/// 1 while a plugin layer is running. A render-on-demand shell needs this: a
/// plugin posts geometry from its own thread with no gesture behind it, so a
/// loop that only wakes on input must keep polling `lookout_needs_redraw` at a
/// low rate while plugins are up, instead of sleeping until the mariner
/// touches something.
export fn lookout_plugins_active(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.pluginsActive()) 1 else 0;
}

/// Every loaded plugin with its settings schema and the values in force, as
/// JSON. A shell renders a settings pane from this and needs to know nothing
/// about what any plugin does. Borrowed until the next plugin query; NULL when
/// no plugin layer is up.
export fn lookout_plugins_json(h: ?*lookout, out_len: ?*usize) ?[*]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const s = l.pluginsJson() orelse return null;
    if (out_len) |p| p.* = s.len;
    return s.ptr;
}

/// One plugin's settings object. Borrowed until the next plugin query; NULL
/// when the id is not loaded.
export fn lookout_plugin_config_get(h: ?*lookout, id: [*:0]const u8, out_len: ?*usize) ?[*]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const s = l.pluginConfig(std.mem.span(id)) orelse return null;
    if (out_len) |p| p.* = s.len;
    return s.ptr;
}

/// Change one plugin's settings, applied at once. `json` is an object of the
/// keys the schema declares; anything else in it is ignored and a number
/// outside its range is clamped. 0 on success, -1 when the id is unknown, the
/// plugin has no settings, or the JSON is not an object.
export fn lookout_plugin_config_set(h: ?*lookout, id: [*:0]const u8, json: [*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    l.setPluginConfig(std.mem.span(id), std.mem.span(json)) catch return -1;
    return 0;
}

/// Load the INSTALLED plugin set — what lookout_plugin_install put under the
/// per-user plugin directory — creating the plugin layer if nothing has yet.
/// Idempotent: an id already loaded is skipped, so the shell calls it once
/// after open and again whenever it likes. 0 when the layer is up afterwards.
export fn lookout_plugins_load_installed(h: ?*lookout) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    return if (ensureInstalledPlugins(l)) 0 else -1;
}

/// Name the per-user plugin directory, for platforms whose environment cannot
/// (Android: the app's files dir has no path in the environment; every other
/// platform resolves a default and never needs this). Call before any other
/// plugin call — the layer reads it once at creation. 0 on success, -1 once
/// the layer is already up.
export fn lookout_plugins_install_root(h: ?*lookout, path: [*:0]const u8) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    l.setPluginInstallRoot(std.mem.span(path)) catch return -1;
    return 0;
}

/// Read a .lkplug without installing it: everything the consent sheet shows,
/// as JSON. `{"id":..,"name":..,"version":..,"sentences":[..]}`, plus
/// `"installed":{"version":..,"origin":..,"adds":[..],"drops":[..],
/// "downgrade":bool}` when the id is already loaded, so the sheet calls out
/// the grant delta. A refused package answers `{"error":"<sentence>"}`.
/// Borrowed until the next plugin query; NULL only when no layer can come up.
export fn lookout_plugin_inspect(h: ?*lookout, path: [*:0]const u8, out_len: ?*usize) ?[*]const u8 {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    if (!ensureInstalledPlugins(l)) return null;
    const ps = l.plugins.?;
    ps.json.clearRetainingCapacity();
    ps.host.inspectPackage(std.mem.span(path), &ps.json) catch return null;
    if (out_len) |p| p.* = ps.json.items.len;
    return ps.json.items.ptr;
}

/// Install a .lkplug: unpack, validate — the zip must hold exactly
/// manifest.json and the manifest's <id>.wasm — place it under the per-user
/// plugin directory and load it hot. Call after the mariner consented on the
/// sheet lookout_plugin_inspect fed.
///
/// NULL on success. Otherwise one borrowed sentence saying why, ready to
/// show: "The package holds notes.txt; a plugin package holds only
/// manifest.json and its module." Valid until the next install or inspect.
export fn lookout_plugin_install(h: ?*lookout, path: [*:0]const u8) ?[*:0]const u8 {
    if (comptime !plugins_enabled) return "This build has no plugin host.";
    const l = locked(h);
    defer l.apiUnlock();
    if (!ensureInstalledPlugins(l)) return "The plugin layer could not start.";
    const ps = l.plugins.?;
    ps.host.installPackage(std.mem.span(path)) catch |e| return ps.host.installErrorText(e).ptr;
    return null;
}

/// Remove an installed plugin: its instance, its overlay objects, its store
/// contributions, its saved storage and its directory. 0 on success; -1 for
/// an unknown id or a bundled/developer plugin, which install never wrote and
/// uninstall will not touch.
export fn lookout_plugin_uninstall(h: ?*lookout, id: [*:0]const u8) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return -1;
    ps.host.uninstall(std.mem.span(id)) catch return -1;
    return 0;
}

/// Switch one of a plugin's granted capabilities on or off, live: the broker
/// checks per call, so a revoked capability answers -1 to the plugin and
/// counts denied exactly as if the manifest never asked for it. The change
/// persists beside the plugin's wasm and is read back at every load. 0 on
/// success; -1 for an unknown id, an unknown capability name, or a
/// capability the manifest never asked for (a grant can never exceed the
/// manifest).
export fn lookout_plugin_grant_set(h: ?*lookout, id: [*:0]const u8, cap: [*:0]const u8, on: c_int) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return -1;
    ps.host.grantSet(std.mem.span(id), std.mem.span(cap), on != 0) catch return -1;
    return 0;
}

/// Every table the loaded plugins declare, as JSON. A shell builds the menu
/// item and the columns from this and knows nothing about what any plugin
/// does. Borrowed until the next plugin query; NULL when no layer is up.
export fn lookout_plugin_tables_json(h: ?*lookout, out_len: ?*usize) ?[*]const u8 {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return null;
    ps.json.clearRetainingCapacity();
    ps.br.tablesJson(&ps.json) catch return null;
    if (out_len) |p| p.* = ps.json.items.len;
    return ps.json.items.ptr;
}

/// One table's rows, already in the order they are to be shown: the plugin's
/// bands first, then `sort_key` within each band, then arrival. `sort_key`
/// NULL or empty takes the declared default sort. Borrowed until the next
/// plugin query; NULL when the plugin or the table is unknown.
export fn lookout_plugin_table_rows(
    h: ?*lookout,
    id: [*:0]const u8,
    key: [*:0]const u8,
    sort_key: ?[*:0]const u8,
    ascending: c_int,
    out_len: ?*usize,
) ?[*]const u8 {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return null;
    ps.json.clearRetainingCapacity();
    const want: []const u8 = if (sort_key) |s| std.mem.span(s) else "";
    const found = ps.br.tableRowsJson(
        std.mem.span(id),
        std.mem.span(key),
        want,
        ascending != 0,
        &ps.json,
    ) catch return null;
    if (!found) return null;
    if (out_len) |p| p.* = ps.json.items.len;
    return ps.json.items.ptr;
}

/// Tell the plugin its table is on screen, or is not. 0 on success, -1 when
/// the plugin or the table is unknown.
export fn lookout_plugin_table_open(h: ?*lookout, id: [*:0]const u8, key: [*:0]const u8, open: c_int) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return -1;
    return if (ps.br.setTableOpen(std.mem.span(id), std.mem.span(key), open != 0)) 0 else -1;
}

/// Every alert the plugins have raised and the mariner has not seen off, most
/// urgent first, as JSON. The shell shows them and sounds the alarms. Borrowed
/// until the next plugin query; NULL when no layer is up.
export fn lookout_plugin_alerts_json(h: ?*lookout, out_len: ?*usize) ?[*]const u8 {
    if (comptime !plugins_enabled) return null;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return null;
    ps.json.clearRetainingCapacity();
    ps.br.alertsJson(&ps.json) catch return null;
    if (out_len) |p| p.* = ps.json.items.len;
    return ps.json.items.ptr;
}

/// Acknowledge one alert: the alarm stops sounding and the alert stays listed
/// until the condition clears. One alert, not one class of them. 0 on success,
/// -1 when no alert holds that id.
export fn lookout_plugin_alert_ack(h: ?*lookout, id: u64) c_int {
    if (comptime !plugins_enabled) return -1;
    const l = locked(h);
    defer l.apiUnlock();
    const ps = l.plugins orelse return -1;
    return if (ps.br.ackAlert(id)) 0 else -1;
}

/// The plugin layer with the installed set loaded, created on first need.
/// True when the layer is up afterwards. The install root is created empty
/// rather than treated as an error: a first install has nothing yet.
fn ensureInstalledPlugins(l: *lk.Lookout) bool {
    if (comptime !plugins_enabled) return false;
    const root: []u8 = if (l.plugin_install_root) |r|
        gpa.dupe(u8, r) catch return l.plugins != null
    else
        phost.installRootAlloc(gpa) orelse return l.plugins != null;
    defer gpa.free(root);
    std.Io.Dir.cwd().createDirPath(capi_io, root) catch {};
    l.loadPlugins(root) catch return l.plugins != null;
    return l.plugins != null;
}

/// Offer a file the mariner opened to the plugins: 1 when one claimed the file
/// type and now holds it, 0 when none does, -1 when the file was claimed and
/// could not be given. Charts always answer 0. See lookout.h.
export fn lookout_open_file(h: ?*lookout, path: [*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const taken = l.openFileForPlugins(std.mem.span(path)) catch return -1;
    return if (taken) 1 else 0;
}

/// What the plugin overlay says about the symbol nearest a LOGICAL point, as
/// JSON: `{"title":"...","rows":[["key","value"],...]}`. NULL when no symbol
/// with a payload is within about 14 pt of it.
///
/// Borrowed: valid until the next `lookout_overlay_at`. `*out_len` (NULL to
/// ignore) receives the length. The core copies the payload out from under the
/// plugin's own thread, so the pointer stays good even if the plugin redraws
/// that target in the meantime.
export fn lookout_overlay_at(h: ?*lookout, x_pt: f32, y_pt: f32, out_len: ?*usize) ?[*]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const s = l.overlayAt(x_pt, y_pt) orelse return null;
    if (out_len) |p| p.* = s.len;
    return s.ptr;
}

/// One overlay object, as a hit test or an id lookup answers. `id` is
/// NUL-terminated and can go straight back to `lookout_overlay_info`; `info`
/// is the pick payload, NULL when the object carries none. `lon`/`lat` are
/// where the object draws NOW. Every pointer is borrowed until the next
/// overlay call.
pub const lookout_overlay_obj = extern struct {
    id: ?[*:0]const u8,
    id_len: usize,
    info: ?[*]const u8,
    info_len: usize,
    lon: f64,
    lat: f64,
};

fn fillObj(out: *lookout_overlay_obj, hit: lk.OverlayHit) void {
    out.* = .{
        .id = hit.id.ptr,
        .id_len = hit.id.len,
        .info = if (hit.info.len > 0) hit.info.ptr else null,
        .info_len = hit.info.len,
        .lon = hit.at[0],
        .lat = hit.at[1],
    };
}

/// The overlay symbol nearest a LOGICAL point, with its id and anchor: 1 when
/// one answers, 0 when none is within about 14 pt. A shell pins an info bubble
/// to that id and follows it with lookout_overlay_info.
export fn lookout_overlay_hit(h: ?*lookout, x_pt: f32, y_pt: f32, out: *lookout_overlay_obj) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const hit = l.overlayHit(x_pt, y_pt) orelse return 0;
    fillObj(out, hit);
    return 1;
}

/// What that object says now: 1 while it exists, 0 once it is gone (the
/// target aged out, or its plugin stopped). The payload and the anchor are
/// current, so a pinned bubble re-reads both every render tick.
export fn lookout_overlay_info(h: ?*lookout, id: [*:0]const u8, out: *lookout_overlay_obj) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const hit = l.overlayInfo(std.mem.span(id)) orelse return 0;
    fillObj(out, hit);
    return 1;
}

/// 1 if the symbol/font atlas cache is already built — i.e. the NEXT open will
/// not need the one-time rasterize. A host can call this before opening to show
/// a "preparing chart symbols" message only on the first run. No handle needed.
export fn lookout_atlas_cache_ready() c_int {
    return if (lk.atlasCacheReady(gpa)) 1 else 0;
}

/// Point the atlas cache at a host-owned writable directory, before opening.
/// Desktop hosts can skip this (XDG_CACHE_HOME / the platform default under
/// HOME apply); Android MUST call it, having no cache path in the environment.
export fn lookout_set_cache_dir(path: [*:0]const u8) void {
    lk.setCacheRoot(std.mem.span(path));
}

// ---- the chart library ------------------------------------------------------

/// The last scan's JSON. Held so the pointer the shell reads stays good until
/// the next scan.
var scan_json: ?[:0]u8 = null;

/// Add baked charts to the open library. See lookout.h.
export fn lookout_charts_add(h: ?*lookout, paths: [*]const [*:0]const u8, n: usize) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const list = gpa.alloc([:0]const u8, n) catch return -1;
    defer gpa.free(list);
    for (0..n) |i| list[i] = std.mem.span(paths[i]);
    return @intCast(l.chartsAdd(list));
}

/// True while the library's ownership partition is being built. See lookout.h.
export fn lookout_composing(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.loading or l.recomposing) 1 else 0;
}

/// How many charts the library holds. See lookout.h.
export fn lookout_charts_count(h: ?*lookout) u32 {
    const l = locked(h);
    defer l.apiUnlock();
    return @intCast(l.charts.items.len);
}

/// Look through `path` for charts. See lookout.h.
export fn lookout_scan_charts(path: [*:0]const u8, out_len: ?*usize) ?[*]const u8 {
    if (scan_json) |old| gpa.free(old);
    scan_json = null;
    var s = lk.scanCharts(gpa, capi_io, std.mem.span(path)) catch return null;
    defer s.deinit();
    const json = lk.library.toJson(gpa, &s) catch return null;
    scan_json = json;
    if (out_len) |p| p.* = json.len;
    return json.ptr;
}

/// lookout_scan_charts for a chart set that arrives as one .zip. See lookout.h.
export fn lookout_scan_zip(path: [*:0]const u8, out_len: ?*usize) ?[*]const u8 {
    if (scan_json) |old| gpa.free(old);
    scan_json = null;
    var s = lk.scanZip(gpa, std.mem.span(path)) catch return null;
    defer s.deinit();
    const json = lk.library.toJson(gpa, &s) catch return null;
    scan_json = json;
    if (out_len) |p| p.* = json.len;
    return json.ptr;
}

// ---- view ------------------------------------------------------------------
export fn lookout_fit_chart(h: ?*lookout, out: *lookout_view) void {
    const l = locked(h);
    defer l.apiUnlock();
    out.* = fromView(l.fitChart());
}
/// The view to open with when the host has NOTHING saved: the library framed,
/// pulled back to an overview zoom. Pair with lookout_set_view; a host that has
/// a saved pose should restore that instead.
export fn lookout_default_view(h: ?*lookout, out: *lookout_view) void {
    const l = locked(h);
    defer l.apiUnlock();
    out.* = fromView(l.defaultView());
}
export fn lookout_set_view(h: ?*lookout, v: *const lookout_view) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.setView(toView(v.*));
}
export fn lookout_get_view(h: ?*lookout, out: *lookout_view) void {
    const l = locked(h);
    defer l.apiUnlock();
    out.* = fromView(l.view());
}
export fn lookout_resize(h: ?*lookout, width: u32, height: u32) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    l.resize(width, height) catch return -1;
    return 0;
}
/// Declare the host's scale factor (Android DisplayMetrics.density, and any
/// host whose surface cannot be trusted to report it across a rotation).
/// Optional: without it the backend infers density from the surface.
export fn lookout_set_pixel_density(h: ?*lookout, d: f32) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.setPixelDensity(d);
}
export fn lookout_pixel_density(h: ?*lookout) f32 {
    const l = locked(h);
    defer l.apiUnlock();
    return l.pixelDensity();
}

// ---- interaction (pixel coords; *_logical scale by HiDPI density) ----------
export fn lookout_pan(h: ?*lookout, dx: f32, dy: f32) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.panPixels(dx, dy);
}
export fn lookout_zoom_at(h: ?*lookout, dzoom: f64, x_px: f32, y_px: f32) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.zoomAt(dzoom, x_px, y_px);
}
export fn lookout_pan_logical(h: ?*lookout, dx_pt: f32, dy_pt: f32) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.panLogical(dx_pt, dy_pt);
}
export fn lookout_zoom_at_logical(h: ?*lookout, dzoom: f64, x_pt: f32, y_pt: f32) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.zoomAtLogical(dzoom, x_pt, y_pt);
}
export fn lookout_screen_to_geo(h: ?*lookout, x_px: f32, y_px: f32, lon: *f64, lat: *f64) void {
    const l = locked(h);
    defer l.apiUnlock();
    const g = l.screenToGeo(x_px, y_px);
    lon.* = g.lon;
    lat.* = g.lat;
}
export fn lookout_geo_to_screen(h: ?*lookout, lon: f64, lat: f64, x_px: *f32, y_px: *f32) void {
    const l = locked(h);
    defer l.apiUnlock();
    const s = l.geoToScreen(lon, lat);
    x_px.* = s[0];
    y_px.* = s[1];
}

// ---- mariner (ALL S-52 settings) -------------------------------------------
export fn lookout_mariner_defaults(m: *cc.tile57_mariner) void {
    cc.tile57_mariner_defaults(m);
}
export fn lookout_get_mariner(h: ?*lookout, out: *cc.tile57_mariner) void {
    const l = locked(h);
    defer l.apiUnlock();
    out.* = l.getMariner();
}
export fn lookout_set_mariner(h: ?*lookout, m: *const cc.tile57_mariner) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.setMariner(m.*);
}

// ---- build + render --------------------------------------------------------
export fn lookout_build(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    l.build() catch return -1;
    return 0;
}
export fn lookout_render(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const ok = l.render() catch return -1;
    return if (ok) 1 else 0;
}
/// 1 if a redraw is needed (view/state changed, a build is filling in, or the
/// view left coverage). When 0 the chart is static — your loop can block on
/// events and use no CPU. Call lookout_render only when this is 1.
export fn lookout_needs_redraw(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.needsRedraw()) 1 else 0;
}
export fn lookout_snapshot_png(h: ?*lookout, path: [*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    l.snapshotPng(std.mem.span(path)) catch return -1;
    return 0;
}
export fn lookout_snapshot_rgba(h: ?*lookout, dst: [*]u8, dst_len: usize) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    l.snapshotRgba(dst[0..dst_len]) catch return -1;
    return 0;
}

// ---- pick (tap-to-identify) ------------------------------------------------
export fn lookout_pick(h: ?*lookout, lon: f64, lat: f64, cb: *const cc.tile57_query_cb) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.pick(lon, lat, cb);
}

/// The cursor pick a shell should show: the objects worth reporting, best
/// first, with their depths in the mariner's unit. Same callback as
/// lookout_pick; the core decides what is reported, in what order and in which
/// unit, so every shell shows the same thing. See lookout.h.
export fn lookout_pick_ranked(h: ?*lookout, lon: f64, lat: f64, cb: *const cc.tile57_query_cb) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.pickRanked(lon, lat, cb);
}

/// A file a picked feature points at, by the cell it came from and the name it
/// carries (TXTDSC, NTXTDS, PICREP, or an S-101 fileReference). *bytes is NULL
/// with 0 length when the chart carries no such file. The bytes belong to the
/// handle and stay valid until lookout_close.
export fn lookout_aux_file(h: ?*lookout, cell: [*:0]const u8, name: [*:0]const u8, bytes: *?[*]const u8, len: *usize, mime: *?[*:0]const u8) void {
    bytes.* = null;
    len.* = 0;
    mime.* = null;
    const l = locked(h);
    defer l.apiUnlock();
    const found = l.auxFile(std.mem.span(cell), std.mem.span(name)) orelse return;
    bytes.* = found.bytes.ptr;
    len.* = found.bytes.len;
    mime.* = found.mime;
}

// ---- convenience live toggles ----------------------------------------------
/// Draw a host-supplied style instead of lookout's portrayal. See lookout.h.
export fn lookout_alt_chart_style_json(h: ?*lookout, json: ?[*]const u8, len: usize) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const bytes: ?[]const u8 = if (json != null and len != 0) json.?[0..len] else null;
    l.setAltStyle(bytes) catch return 0;
    return 1;
}

export fn lookout_alt_chart_style_active(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.altStyleActive()) 1 else 0;
}

/// Where an alt style's tiles are asked for. See lookout.h.
export fn lookout_set_tile_provider(h: ?*lookout, cb: ?lk.Lookout.TileRequestFn, user: ?*anyopaque) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.setTileProvider(cb, user);
}

/// Answer one tile request, from any thread. See lookout.h.
///
/// The ONLY handle-taking export that does not hold the api lock, and
/// deliberately: the host answers from whatever thread its networking
/// finished on, and that thread must not queue behind a frame in flight. The
/// switchboard underneath has its own lock and is written for it — and it is
/// also why this is the one call a tile-request callback may make re-entrantly,
/// since that callback runs with the api lock already held.
export fn lookout_tile_respond(h: ?*lookout, req_id: u64, bytes: ?[*]const u8, len: usize, status: c_int) void {
    if (h == null) return;
    const st: lk.Lookout.TileStatus = switch (status) {
        0 => .ok,
        1 => .empty,
        else => .failed,
    };
    const slice: []const u8 = if (st == .ok and bytes != null) bytes.?[0..len] else &.{};
    cast(h).respondTile(req_id, slice, st);
}

/// Open a raster chart (satellite imagery or another picture chart the mariner
/// supplied) and add it beneath the vector chart. See lookout.h.
export fn lookout_raster_add(h: ?*lookout, path: ?[*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const p = path orelse return 0;
    return if (l.addRaster(std.mem.span(p))) 1 else 0;
}

/// Step to the next raster chart set, with "no picture" as one position. See lookout.h.
export fn lookout_raster_cycle(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.cycleRaster();
}

/// The active set's name (borrowed, valid until the next raster call), or "".
export fn lookout_raster_active_name(h: ?*lookout, out_len: ?*usize) [*:0]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    // The layer terminates its set names where it dupes them, so this borrows
    // with no copy. Valid until the set list changes.
    const n = l.rasterName();
    if (out_len) |o| o.* = n.len;
    return n.ptr;
}

/// 1 while the chart is drawing WITHOUT its opaque water and land fills because
/// a picture is beneath THIS view. See lookout.h.
export fn lookout_raster_over_chart(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.rasterOverChart()) 1 else 0;
}

/// The name of set `i`. Borrowed; valid until the set list changes. See lookout.h.
export fn lookout_raster_set_name(h: ?*lookout, i: u32, out_len: ?*usize) [*:0]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const n = l.rasterSetName(i);
    if (out_len) |o| o.* = n.len;
    return n.ptr;
}

/// 1 when set `i` has enabled charts in view. See lookout.h.
export fn lookout_raster_set_in_view(h: ?*lookout, i: u32) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.rasterSetInView(i)) 1 else 0;
}

/// The drawn set's index, or -1 when none is drawn. See lookout.h.
export fn lookout_raster_active_index(h: ?*lookout) i32 {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.rasterActiveIndex()) |i| @intCast(i) else -1;
}

/// Draw set `i`, or nothing when `i` is negative. See lookout.h.
export fn lookout_raster_select(h: ?*lookout, i: i32) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.rasterSelect(if (i < 0) null else @intCast(i));
}

/// Read and write one set's drawn state by index, no camera. See lookout.h.
export fn lookout_raster_shown(h: ?*lookout, i: u32) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.rasterShown(i)) 1 else 0;
}

export fn lookout_raster_set_shown(h: ?*lookout, i: u32, shown: c_int) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.rasterSetShown(i, shown != 0);
}

/// Turn one raster chart on or off without removing it. See lookout.h.
export fn lookout_raster_set_enabled(h: ?*lookout, path: ?[*:0]const u8, enabled: c_int) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const p = path orelse return 0;
    return if (l.setRasterEnabled(std.mem.span(p), enabled != 0)) 1 else 0;
}

export fn lookout_raster_enabled(h: ?*lookout, path: ?[*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const p = path orelse return 0;
    return if (l.rasterEnabled(std.mem.span(p))) 1 else 0;
}

/// The set that covers this view, DRAWN OR NOT. See lookout.h.
export fn lookout_raster_available_name(h: ?*lookout, out_len: ?*usize) [*:0]const u8 {
    const l = locked(h);
    defer l.apiUnlock();
    const n = l.rasterAvailableName();
    if (out_len) |o| o.* = n.len;
    return n.ptr;
}

/// Show or hide the vector chart; the picture beneath it stays. See lookout.h.
export fn lookout_set_chart_hidden(h: ?*lookout, hidden: c_int) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.setChartHidden(hidden != 0);
}

export fn lookout_toggle_chart(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.toggleChart();
}

export fn lookout_chart_hidden(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.chartHidden()) 1 else 0;
}

/// How many raster chart sets are installed. The cycle has this many positions plus
/// one for "no picture". See lookout.h.
export fn lookout_raster_set_count(h: ?*lookout) u32 {
    const l = locked(h);
    defer l.apiUnlock();
    return @intCast(l.rasterSetCount());
}

export fn lookout_cycle_scheme(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.cycleScheme();
}
export fn lookout_toggle_text(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.toggleText();
}
export fn lookout_toggle_soundings(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.toggleSoundings();
}
export fn lookout_toggle_other_category(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.toggleOtherCategory();
}
export fn lookout_nudge_safety_contour(h: ?*lookout, delta: f64) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.nudgeSafetyContour(delta);
}
export fn lookout_adjust_size(h: ?*lookout, factor: f32) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.adjustSize(factor);
}

// ---- smooth interaction (see include/lookout.h, §5 of the app spec) ---------
/// Shift-drag course-up rotation: rotate about the view centre by the angle the
/// cursor swept from (x0,y0) to (x1,y1), both logical points.
export fn lookout_rotate_drag_logical(h: ?*lookout, x0_pt: f32, y0_pt: f32, x1_pt: f32, y1_pt: f32) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.rotateDragLogical(x0_pt, y0_pt, x1_pt, y1_pt);
}
/// OS memory warning: trim reclaimable caches at the next safe point.
export fn lookout_memory_warning(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.memoryWarning();
}

/// Snap the view back to north-up.
export fn lookout_reset_rotation(h: ?*lookout) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.resetRotation();
}
/// Start a momentum pan with a logical-px/sec velocity (pass 0,0 to stop coasting
/// when a grab starts).
export fn lookout_fling_start(h: ?*lookout, vx: f64, vy: f64) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.flingStart(vx, vy);
}
/// 1 while an eased zoom or fling is in progress — render every frame while true.
export fn lookout_animating(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.animating()) 1 else 0;
}
/// Advance the eased zoom / fling by `dt` seconds; call each frame while animating.
export fn lookout_tick_anim(h: ?*lookout, dt: f64) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.tickAnim(dt);
}
/// 1 while a background tessellation is filling in — use a short idle timeout so
/// progressive builds appear.
export fn lookout_is_building(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.isBuilding()) 1 else 0;
}
/// Live overscale factor (>= 1): how far the view is zoomed past the deepest
/// data at the centre. Show an overscale indication when > ~1.05 (S-52 wants
/// overscale INDICATED, not forbidden).
export fn lookout_overscale(h: ?*lookout) f64 {
    const l = locked(h);
    defer l.apiUnlock();
    return l.overscale();
}

// ---- follow mode -----------------------------------------------------------
/// Hold own ship at a fixed point on screen — the horizontal centre, three
/// quarters down the view — and move the chart under it as the fix updates.
/// Turning it on moves the chart at once when a fresh fix exists. With no fix,
/// or one past the 5 s staleness window, the camera holds and follow waits.
///
/// The core turns follow off itself on lookout_pan and lookout_pan_logical: a
/// pan hands the chart back to the mariner. Zoom and rotation leave it on, and
/// a zoom while following pivots on own ship whatever point you pass.
export fn lookout_follow_set(h: ?*lookout, on: c_int) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.setFollow(on != 0);
}

/// What follow mode is doing: 0 off, 1 following own ship, 2 on but waiting
/// for a fix. Non-zero means follow is on, so `!= 0` is enough for a control
/// that draws two states. Poll it on your render tick: the core turns follow
/// off on a pan, so a button that tracks only its own taps goes wrong.
export fn lookout_follow_active(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return @intFromEnum(l.followState());
}

/// Course up: turn the chart so own ship's heading points up the screen, and
/// keep turning it as the ship turns. Heading when the compass is fresh, else
/// course over ground; with neither the chart holds and the control waits.
/// Independent of follow — either mode works alone.
///
/// The core turns course up off itself when the mariner rotates the chart by
/// hand or asks for north up.
export fn lookout_course_up_set(h: ?*lookout, on: c_int) void {
    const l = locked(h);
    defer l.apiUnlock();
    l.setCourseUp(on != 0);
}

/// 0 off, 1 turning with own ship, 2 on but waiting for a heading.
export fn lookout_course_up_active(h: ?*lookout) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return @intFromEnum(l.courseUpState());
}

/// The current view's 1:N scale denominator, from the authoritative camera math.
export fn lookout_scale_denominator(h: ?*lookout) f64 {
    const l = locked(h);
    defer l.apiUnlock();
    return l.scaleDenominator();
}

// ---- own ship's position ----------------------------------------------------
/// Own ship's REPORTED position and how much to believe it: 0 no source of
/// position at all, 1 a source exists but its fix aged out or was lost, 2 a
/// fix inside its freshness window. `lon`/`lat` are written only for 2, so a
/// readout that shows numbers on any other answer is showing numbers with no
/// boat behind them. See lookout.h.
export fn lookout_own_ship(h: ?*lookout, lon: ?*f64, lat: ?*f64) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    var p: [2]f64 = .{ 0, 0 };
    const state = l.ownShip(&p);
    if (state == .live) {
        if (lon) |o| o.* = p[0];
        if (lat) |o| o.* = p[1];
    }
    return @intFromEnum(state);
}

// ---- markers ----------------------------------------------------------------
/// One marker as the core holds it. `name` is NUL-terminated and borrowed
/// until the next call that changes the markers.
pub const lookout_marker = extern struct {
    id: u64,
    lon: f64,
    lat: f64,
    name: ?[*:0]const u8,
    name_len: usize,
    dropped_ms: i64,
};

fn fillMarker(out: *lookout_marker, m: *const @import("markers.zig").Marker) void {
    out.* = .{
        .id = m.id,
        .lon = m.lon,
        .lat = m.lat,
        .name = m.name.ptr,
        .name_len = m.name.len,
        .dropped_ms = m.dropped_ms,
    };
}

/// Drop a marker at a geographic point, named at once. Returns its id, or 0
/// when nothing could be stored. See lookout.h.
export fn lookout_marker_add(h: ?*lookout, lon: f64, lat: f64) u64 {
    const l = locked(h);
    defer l.apiUnlock();
    return l.markerAdd(lon, lat);
}

export fn lookout_marker_count(h: ?*lookout) u32 {
    const l = locked(h);
    defer l.apiUnlock();
    return @intCast(l.markerCount());
}

/// Marker `i`, in drop order: 1 when it exists, 0 past the end.
export fn lookout_marker_get(h: ?*lookout, i: u32, out: *lookout_marker) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const m = l.markerAtIndex(i) orelse return 0;
    fillMarker(out, m);
    return 1;
}

/// The marker with this id: 1 when it exists, 0 once it is gone.
export fn lookout_marker_by_id(h: ?*lookout, id: u64, out: *lookout_marker) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const m = l.markerById(id) orelse return 0;
    fillMarker(out, m);
    return 1;
}

/// The marker nearest a LOGICAL point: 1 when one is within about 14 pt of it,
/// 0 when none is.
export fn lookout_marker_at(h: ?*lookout, x_pt: f32, y_pt: f32, out: *lookout_marker) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    const m = l.markerAt(x_pt, y_pt) orelse return 0;
    fillMarker(out, m);
    return 1;
}

/// Rename one marker. An empty name keeps the old one. 0 on success, -1 for an
/// unknown id.
export fn lookout_marker_rename(h: ?*lookout, id: u64, name: [*:0]const u8) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.markerRename(id, std.mem.span(name))) 0 else -1;
}

/// Remove one marker. 0 on success, -1 for an unknown id.
export fn lookout_marker_remove(h: ?*lookout, id: u64) c_int {
    const l = locked(h);
    defer l.apiUnlock();
    return if (l.markerRemove(id)) 0 else -1;
}

comptime {
    _ = lookout_open;
    // The Android Java shell's JNI natives ride in the same archive (they
    // wrap this C ABI for org.beetlebug.lookout.Lookout). Only an android
    // target analyzes the file: it @cImports the NDK's jni.h, which only the
    // NDK sysroot holds.
    if (builtin.abi.isAndroid()) {
        _ = @import("jni_android.zig");
    }
}
