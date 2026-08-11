/* lookout.h — C ABI for lookout-core: a chart-rendering widget over tile57 +
 * SDL_GPU. Open a baked chart, drive the view, set the full S-52 mariner state,
 * and render (window or offscreen). Build (tessellation) is lazy: set state,
 * then render; the widget re-tessellates only when it must.
 *
 * A minimal, orthogonal surface meant to carry a chartplotter (boat marker,
 * routes, tap-to-identify) on top:
 *   open/close · fit/set/get view · resize · pan/zoom · screen<->geo ·
 *   get/set mariner (ALL S-52 settings) · build/render/snapshot · pick.
 */
#ifndef LOOKOUT_H
#define LOOKOUT_H
#include <stdint.h>
#include <stddef.h>
#include "tile57.h"   /* tile57_mariner, tile57_query_cb */
#ifdef __cplusplus
extern "C" {
#endif

typedef struct lookout lookout;

/* A camera pose. rotation_deg is course-up rotation (0 = north-up). */
typedef struct { double lon, lat, zoom, rotation_deg; } lookout_view;

/* Native handle kinds for lookout_open_in_window. The host hands lookout its
 * native drawing surface and keeps its own toolkit + event loop; lookout
 * renders and presents straight into it:
 *   - Apple: a CAMetalLayer (an NSView's backing layer on macOS, a UIView's
 *     layerClass on iOS), rendered via Metal.
 *   - Android: an ANativeWindow* (ANativeWindow_fromSurface of a SurfaceView's
 *     Surface), rendered via Vulkan. Builds with -Dbackend=vk only.
 *   - Windows / Linux: one of the small structs below, rendered via Vulkan
 *     (-Dbackend=vk). They exist because these window systems need TWO values
 *     to identify a surface, and native_handle is one pointer: fill one in and
 *     pass its address. It is read during the open call and not retained.
 * Values 2, 3 and 6 are reserved (SDL-hosted desktop windows; see gpu_sdl.zig). */

/* HWND to present on. `hinstance` may be NULL — the loader then uses the module
 * the window belongs to. */
typedef struct { void *hinstance; void *hwnd; } lookout_win32_window;

/* Xlib Display* and the Window XID to present on. For a toolkit host, this is
 * the CHILD window created for the chart, not the toplevel. */
typedef struct { void *display; unsigned long window; } lookout_x11_window;

/* wl_display* and the wl_surface* to present on. For a toolkit host, this is
 * the subsurface created for the chart, not the toplevel's surface. */
typedef struct { void *display; void *surface; } lookout_wayland_surface;

typedef enum {
    LOOKOUT_NATIVE_NONE = 0,           /* offscreen only (snapshot) */
    LOOKOUT_NATIVE_METAL_LAYER = 1,    /* CAMetalLayer* (macOS & iOS) */
    LOOKOUT_NATIVE_WIN32_HWND = 4,     /* lookout_win32_window*   (vk backend) */
    LOOKOUT_NATIVE_X11_WINDOW = 5,     /* lookout_x11_window*     (vk backend) */
    LOOKOUT_NATIVE_ANDROID_WINDOW = 7, /* ANativeWindow* (Android, vk backend) */
    LOOKOUT_NATIVE_WAYLAND_SURFACE = 8,/* lookout_wayland_surface* (vk backend) */
    LOOKOUT_NATIVE_D3D12_PANEL = 10    /* no handle (d3d12 backend): the core
                                        * makes a composition swapchain; fetch
                                        * it with lookout_d3d12_swapchain */
} lookout_native_kind;

/* ---- lifecycle --------------------------------------------------------- */
/* Open a baked chart (.pmtiles) and create the GPU device. want_window!=0 opens
 * a window (needs a display); else rendering is offscreen. NULL on error. */
lookout *lookout_open(const char *chart_path, uint32_t width, uint32_t height,
                      int want_window, int want_msaa);
/* Open MANY baked charts and compose them (a chart library / ENC_ROOT cache).
 * tile57 mmaps each path — the set is never fully resident. Enumerate the
 * directory host-side and pass the paths. */
lookout *lookout_open_charts(const char *const *paths, size_t n,
                             uint32_t width, uint32_t height,
                             int want_window, int want_msaa);

/* Embed into your app's view: pass its CAMetalLayer and lookout renders and
 * presents straight into it — your app keeps its own toolkit and event loop.
 * Drive it with lookout_render() each frame; forward input via lookout_pan/
 * zoom/set_view and lookout_resize on native resize. (For hosts that only want
 * pixels, use lookout_snapshot_rgba instead — no layer needed.) */
lookout *lookout_open_in_window(lookout_native_kind kind, void *native_handle,
                                const char *chart_path,
                                uint32_t width, uint32_t height, int want_msaa);
/* Embed a composed chart LIBRARY (a directory of cells) into your native window —
 * like lookout_open_in_window but for many baked charts at once. NULL on error. */
lookout *lookout_open_charts_in_window(lookout_native_kind kind, void *native_handle,
                                       const char *const *paths, size_t n,
                                       uint32_t width, uint32_t height, int want_msaa);
void lookout_close(lookout *h);

/* Give up the host's surface WITHOUT closing the chart, for a shell whose
 * window comes and goes under it: an Android SurfaceView loses its surface
 * every time the app backgrounds, and closing there throws away a library that
 * takes seconds to reopen. The GPU surface and its swapchain go; the opened
 * cells, the atlas bake, the scene and the plugin layer with its alerts all
 * stand. The native handle is free the moment this returns.
 *
 * Also hands back the engine's reclaimable caches when a memory warning has
 * asked for them, because there is no frame left to do it in.
 *
 * Externally serialized like lookout_close: no other call may be in flight,
 * and nothing may render until a surface is attached again. */
void lookout_detach_surface(lookout *h);

/* Present on a new native surface after a detach: `kind` and `native_handle`
 * are the pair lookout_open_in_window took, width and height are LOGICAL
 * points. Only the surface and the swapchain are rebuilt. Returns 0, or -1
 * when the new surface cannot be adopted, which leaves the chart detached so a
 * host that must have a view can fall back to reopening. */
int  lookout_attach_surface(lookout *h, lookout_native_kind kind,
                            void *native_handle,
                            uint32_t width, uint32_t height);

/* ---- wasm plugins (prototype) ------------------------------------------ */
/* Load and start the plugins in `dir`: every "<id>.manifest.json" with an
 * "<id>.wasm" beside it, which is the layout `zig build plugins` installs into
 * zig-out/plugins. Plugins publish vessel and AIS data and draw chart
 * overlays; the core renders whatever they draw, so a shell needs no other
 * call. Returns 0 on success, -1 when the directory cannot be read or this
 * build has no plugin host (macOS only in the prototype). A plugin that fails
 * to load is logged and skipped, so 0 does not mean every module started.
 *
 * This is also how a shell loads the BUNDLED set: the core plugins that
 * travel inside the application (macOS: LookoutMarine.app/Contents/Resources/
 * Plugins). Any directory that is not the one LOOKOUT_PLUGINS names loads with
 * origin "bundled", so call it with the shell's own directory before
 * lookout_plugins_load_installed() and the precedence comes out right:
 * developer override, then bundled, then installed.
 *
 * Setting LOOKOUT_PLUGINS=<dir> before opening does the same thing with no
 * call at all; LOOKOUT_NMEA=host:port configures the NMEA 0183 plugin. */
int lookout_plugins_load(lookout *h, const char *dir);

/* 1 while a plugin layer is running.
 *
 * A render-on-demand shell needs this. A plugin posts geometry from its own
 * thread with no gesture behind it, so a loop that only wakes on input never
 * shows moving traffic. While this returns 1, keep polling
 * lookout_needs_redraw() at a low rate (a few Hz is enough) instead of
 * sleeping until the mariner touches something. */
int lookout_plugins_active(lookout *h);

/* Every loaded plugin with its settings schema and the values in force:
 *
 *   {"plugins":[{"id":"org.beetlebug.ais","name":"AIS targets",
 *                "version":"1.2","origin":"installed","live":true,
 *                "status":"{\"state\":\"running\",...}",
 *                "capabilities":[
 *                  {"cap":"ais.read","sentence":"Read AIS traffic.",
 *                   "granted":true}],
 *                "settings":[
 *                  {"key":"cpa_limit","label":"CPA limit","kind":"number",
 *                   "unit":"m","min":93,"max":9260,"default":926,"value":926},
 *                  {"key":"cpa_alarm","label":"Collision alarm",
 *                   "kind":"toggle","default":true,"value":true}]}]}
 *
 * A shell draws a control per field — a number field with its unit and range,
 * a toggle as a switch — and needs to know nothing about what a plugin does.
 * "origin" is "bundled", "installed" or "developer": only an installed row
 * offers Uninstall, and a developer row says "developer copy" by its status.
 * "capabilities" is the manifest's asked-for set in consent-sheet wording,
 * with "hosts":[...] on the net.http/net.ws entries and "granted" tracking
 * lookout_plugin_grant_set(). Borrowed until the next plugin query; NULL when
 * no plugin layer is up. *out_len (NULL to ignore) receives the length. */
const char *lookout_plugins_json(lookout *h, size_t *out_len);

/* ---- plugin install and consent ------------------------------------------ */

/* Load the INSTALLED plugin set — what lookout_plugin_install() put under the
 * per-user plugin directory (macOS: ~/Library/Application Support/Lookout
 * Marine/Plugins/<id>/) — creating the plugin layer if nothing has yet. Call
 * once after open, and after the bundled set: on an id collision the first
 * copy loaded wins, and the order that gives the documented precedence is
 * LOOKOUT_PLUGINS (loads at open), then bundled, then installed. Idempotent.
 * Returns 0 while the layer is up afterwards, -1 otherwise. */
int lookout_plugins_load_installed(lookout *h);

/* Read a .lkplug without installing it: everything the consent sheet shows.
 *
 *   {"id":"org.example.downwind","name":"Downwind line","version":"1.0",
 *    "sentences":["Read your instruments: position, heading, depth, wind.",
 *                 "Draw on the chart."]}
 *
 * When the id is already loaded, an "installed" object rides beside it so the
 * sheet can call out the delta: {"version":..,"origin":..,"adds":[..],
 * "drops":[..],"downgrade":true|false} — adds/drops are consent sentences the
 * new package gains/loses against the running copy. A refused package answers
 * {"error":"<one sentence, ready to show>"}. Borrowed until the next plugin
 * query; NULL only when no plugin layer can come up. */
const char *lookout_plugin_inspect(lookout *h, const char *path, size_t *out_len);

/* Install a .lkplug the mariner consented to: unpack (the zip must hold
 * exactly manifest.json and the manifest's <id>.wasm; anything else refuses
 * by name), place under the per-user plugin directory, and load hot — the
 * plugin draws without a restart. Reinstalling an id replaces the running
 * copy and resets its grants to the consented set; while LOOKOUT_PLUGINS
 * carries the same id, the files land but the developer copy keeps running. A
 * package claiming the id of a BUNDLED plugin is refused outright, because
 * those ids belong to the application, and the sentence names the plugin it
 * collided with. lookout_plugin_inspect() refuses it the same way, so the
 * sheet shows the reason instead of offering Install.
 *
 * Returns NULL on success, else one borrowed sentence saying why, ready for
 * the shell to show. Valid until the next install or inspect. */
const char *lookout_plugin_install(lookout *h, const char *path);

/* Remove an installed plugin: instance, overlay objects, published values,
 * saved storage, directory — everything it owns. 0 on success; -1 for an
 * unknown id or a bundled/developer plugin (install never wrote those, so
 * uninstall will not touch them). */
int lookout_plugin_uninstall(lookout *h, const char *id);

/* Switch one granted capability on or off, live. The broker checks every
 * mediated call, so a revoked capability answers the plugin -1 and counts
 * denied exactly as if the manifest never asked for it — the plugin keeps
 * running. The state persists beside the plugin's wasm (grants.json) and is
 * read back at every load; absent means everything the manifest asked for.
 * `cap` is the manifest capability name ("ais.read", "net.http", ...).
 * Returns 0, or -1 for an unknown id/capability or one the manifest never
 * asked for — a grant can never exceed the manifest. */
int lookout_plugin_grant_set(lookout *h, const char *id, const char *cap, int on);

/* One plugin's settings, as a JSON object of key to value. Every key its
 * schema declares is present. Borrowed until the next plugin query; NULL when
 * `id` names no loaded plugin. */
const char *lookout_plugin_config_get(lookout *h, const char *id, size_t *out_len);

/* Change one plugin's settings. `json` is an object of the keys the schema
 * declares; a key it does not declare is ignored and a number outside its
 * range is clamped. The plugin receives the WHOLE config at once and applies
 * it live — no restart, and the AIS alarm gate re-evaluates immediately.
 *
 * Returns 0, or -1 when the id is unknown, the plugin declares no settings, or
 * the JSON is not an object. Persisting the values is the shell's job. */
int lookout_plugin_config_set(lookout *h, const char *id, const char *json);

/* ---- plugin tables -------------------------------------------------------- */

/* Every table the loaded plugins declare:
 *
 *   {"tables":[{"plugin":"org.beetlebug.ais","key":"targets",
 *               "title":"AIS Targets","menu":"Vessels",
 *               "columns":[{"key":"name","label":"Vessel","type":"text"},
 *                          {"key":"cpa","label":"CPA","type":"distance"}],
 *               "sort":{"key":"cpa","ascending":true},
 *               "at":{"lat":"lat","lon":"lon"},
 *               "open":false,"rows":0,"seq":0}]}
 *
 * A shell puts one item per table in the menu the declaration names ("Vessels
 * > AIS Targets…") and builds the columns from "columns". A COLUMN TYPE is
 * what makes sorting honest: distance is METRES, speed METRES PER SECOND,
 * bearing DEGREES TRUE, duration SECONDS, and number/text/flag are what they
 * say. The plugin sends SI and the shell formats for the mariner's units:
 * the reverse of the pick report, because a table sorts and converts where a
 * pick shows one formatted line. A "flag" cell is "alarm", "warning" or null,
 * and the shell colours the row by it.
 *
 * "at" names two row keys carrying a position; a row that has them is
 * locatable, and activating it centres the chart and pins its bubble, which
 * is shell-side work. "seq" bumps on every accepted batch: reload the rows
 * when it changes and leave the table alone when it has not.
 *
 * Borrowed until the next plugin query; NULL when no plugin layer is up. */
const char *lookout_plugin_tables_json(lookout *h, size_t *out_len);

/* One table's rows, ALREADY IN ORDER:
 *
 *   {"key":"targets","seq":42,"open":true,
 *    "sort":{"key":"cpa","ascending":true},
 *    "rows":[{"id":"899000101","band":0,"at":[-76.46,38.97],
 *             "cells":["ANNE","899000101",1852,45,6.2,124,585,"alarm"]}]}
 *
 * "cells" is one value per declared column, in declaration order: a number, a
 * string, or null for a cell the plugin did not send, which renders as a
 * dash, because never heard and heard as zero are different values.
 *
 * THE ORDER IS THE PLUGIN'S POLICY FIRST. Every row carries a "band" (0
 * first); `sort_key` sorts WITHIN a band and never across one, so a plugin
 * that puts its alarmed rows in band 0 keeps them at the top of the table
 * whatever column the mariner sorted by. Rows equal on the sorted column keep
 * the order they arrived in, and an empty cell sorts last in both directions.
 * A "flag" column is the exception: an empty flag is not a value nobody has
 * heard, it is a row with nothing wrong with it, so a flag column sorts by
 * severity (alarm, warning, then nothing) and reverses like any other.
 *
 * `sort_key` NULL or empty takes the declared default sort. Borrowed until
 * the next plugin query; NULL when the plugin or the table is unknown. */
const char *lookout_plugin_table_rows(lookout *h, const char *id, const char *key,
                                      const char *sort_key, int ascending,
                                      size_t *out_len);

/* Tell the plugin its table is on screen, or is not. Call it when the dialog
 * opens and when it closes. A plugin builds rows only while a table is open,
 * so a dialog nobody opened costs nothing, and a closed table keeps no rows.
 * Returns 0, or -1 when the plugin or the table is unknown. */
int lookout_plugin_table_open(lookout *h, const char *id, const char *key, int open);

/* ---- plugin alerts -------------------------------------------------------- */

/* Every alert the plugins have raised and the mariner has not seen off:
 *
 *   {"seq":7,"alerts":[
 *     {"id":3,"plugin":"org.beetlebug.ais","severity":"alarm",
 *      "title":"AIS CPA alarm","body":"ANNE: CPA 124 m in 585 s",
 *      "raised":1754700000000,"acknowledged":false}]}
 *
 * SEVERITY IS THE CONTRACT WITH THE SHELL. An "alarm" is audible and repeats
 * until it is acknowledged; a "warning" and a "notice" are visible only. A
 * marine alarm does not time out, and looking at it is not acknowledging it.
 *
 * "raised" is the wall clock in milliseconds since the epoch. "seq" bumps on
 * every change to the set: re-read when it moves and leave the list alone when
 * it has not. The order is fixed here: what nobody has answered first, then the
 * loudest, then the oldest, so an alert on screen does not jump when another
 * arrives beneath it.
 *
 * ONE CONDITION IS ONE ALERT. The host keys them on the plugin, the title and
 * the body, so a plugin restating the same danger updates its alert instead of
 * stacking another, and two vessels closing stay two alarms. An alert whose
 * plugin unloads, or loses the alerts.raise grant, is withdrawn with it.
 *
 * Borrowed until the next plugin query; NULL when no plugin layer is up. */
const char *lookout_plugin_alerts_json(lookout *h, size_t *out_len);

/* Acknowledge one alert by its id: the alarm stops sounding, and the alert
 * stays listed (as "acknowledged") until the condition clears. It silences THAT
 * alert and no other: a mariner who has seen the vessel crossing ahead has not
 * seen the one coming up astern. Once the condition clears and returns, the
 * plugin raises it again and it sounds again. Returns 0, or -1 when no alert
 * holds that id. */
int lookout_plugin_alert_ack(lookout *h, uint64_t id);

/* Offer a file the mariner opened to the plugins.
 *
 * A manifest claims file types — "file_types":[".grib2",".grb"] — and this
 * gives the file to the plugin that claimed the extension of `path`, with read
 * access to it. The mariner opens a weather file the way they open a chart and
 * never learns a plugin was involved; the plugin declares the types it reads
 * and never learns there was a file picker.
 *
 * Call it from every place your shell opens a file — the Open item, a drop on
 * the window, a file the OS hands you at launch. lookout_plugins_json() carries
 * each plugin's "file_types", which is what a picker names in its prompt.
 *
 * Returns 1 when a plugin took the file, 0 when no plugin claims that type, and
 * -1 when one does and the file could not be given to it (two plugins claim the
 * type, or the file cannot be read; the log line says which).
 *
 * A CHART ALWAYS ANSWERS 0, whatever a manifest claims, so charts keep the path
 * they already take. On 0, do with the file what your shell did before there
 * were plugins — a build with no plugin layer also answers 0, so one code path
 * serves both. */
int lookout_open_file(lookout *h, const char *path);

/* What the plugin overlay says about the symbol nearest a LOGICAL point, as
 * JSON: {"title":"...","rows":[["key","value"],...]}. NULL when no symbol
 * carrying a payload is within about 14 pt of it. Use it for hover on a
 * pointer platform; a tap can use it too.
 *
 * Borrowed: valid until the next lookout_overlay_at(). *out_len (NULL to
 * ignore) receives the length. The payload is copied out from under the
 * plugin's own thread, so the pointer stays good even if the plugin redraws
 * that target meanwhile. */
const char *lookout_overlay_at(lookout *h, float x_pt, float y_pt, size_t *out_len);

/* One overlay object, as a hit test or an id lookup answers.
 *
 * `id` is NUL-terminated and goes straight back to lookout_overlay_info().
 * `info` is the pick payload (the same JSON lookout_overlay_at returns), NULL
 * when the object carries none. `lon`/`lat` are where the object draws NOW.
 * Every pointer is borrowed until the next overlay call. */
typedef struct {
    const char *id;
    size_t      id_len;
    const char *info;
    size_t      info_len;
    double      lon, lat;
} lookout_overlay_obj;

/* The overlay symbol nearest a LOGICAL point: 1 when one answers, 0 when none
 * is within about 14 pt. Use it on a tap: pin an info bubble to the id it
 * returns, and follow the object with lookout_overlay_info(). A tap that hits
 * an overlay symbol should not also open the chart pick report. */
int lookout_overlay_hit(lookout *h, float x_pt, float y_pt, lookout_overlay_obj *out);

/* What that object says now: 1 while it exists, 0 once it is gone (the target
 * aged out, or its plugin stopped). Payload and anchor are both current, so a
 * pinned bubble re-reads them every render tick to move itself and refresh its
 * values, and closes itself when this returns 0. */
int lookout_overlay_info(lookout *h, const char *id, lookout_overlay_obj *out);

/* 1 if the symbol/font atlas cache is already built — the next open won't need
 * the one-time rasterize (~1.3s at 1x, more at HiDPI). Call before opening to
 * show a "preparing chart symbols" indicator only on the first run. */
int lookout_atlas_cache_ready(void);

/* Point the atlas cache at a host-owned writable directory, BEFORE opening.
 * Desktop hosts can skip this (XDG_CACHE_HOME / the platform default under HOME
 * apply); Android must call it, having no cache path in its environment. */
void lookout_set_cache_dir(const char *path);

/* ---- the chart library --------------------------------------------------- */

/* Add baked charts to the OPEN library and compose again. Answers how many
 * opened, or -1 on error; a chart that will not open is skipped, as at open.
 *
 * This is how charts arrive into a running app: a bake finishing, a download
 * landing, a drive plugged in. The mariner keeps the chart on screen and the
 * view they were looking at. The composition is rebuilt on a worker thread and
 * swapped in when it is ready, so the charts already drawn keep drawing until
 * then; lookout_needs_redraw goes true when the new one lands.
 *
 * Adding a chart already in the library opens it twice. The caller knows what
 * it has; the core does not deduplicate. */
int lookout_charts_add(lookout *h, const char *const *paths, size_t n);

/* How many charts the library holds. */
uint32_t lookout_charts_count(lookout *h);

/* 1 while the library's ownership partition is being built, on a worker.
 *
 * This is the long wait when a library is large: opening 7,000 archives is
 * quick, because they are mmap'd rather than read, and then the compositor has
 * to work out which chart owns each piece of water. A host that shows one
 * "loading" state for the whole open tells the mariner nothing about which of
 * the two it is waiting in. */
int lookout_composing(lookout *h);

/* Look through `path` for charts, and report what is there. `path` is one file
 * or a directory; a directory is walked to the bottom, because a bake mirrors
 * the exchange set's tree.
 *
 * Call this BEFORE offering a path to the mariner. A chart folder also holds
 * files that are not charts (CATALOG.031, partition.tpart, the text files a
 * cell references), and a .pmtiles archive may hold pictures rather than a
 * chart. Both open in a file panel and neither draws.
 *
 * The answer is JSON. `cells` is what this build draws, in path order:
 *
 *   {"root":"/Users/x/Charts/ENC_ROOT",
 *    "sources":12,          cells that must bake before they draw
 *    "bytes":3691843584,    the bytes of every cell
 *    "updates":2129,        S-57 update files; each bakes with its base cell
 *    "other":15623,         files that are not charts
 *    "refused":1,           archives with a chart name that the engine refused
 *    "cells":[{"path":"...","name":"US5MD1MC","kind":"baked","band":5,
 *              "bandName":"Harbor","bytes":1331200,"scale":12000,
 *              "west":-76.6,"south":38.9,"east":-76.4,"north":39.0}],
 *    "raster":[{"path":"...","name":"ncds_08.mbtiles","kind":"raster",...}]}
 *
 * `kind` is "baked" (draws now) or "source" (an S-57 cell that bakes first).
 * A cell in `raster` is a picture chart: it belongs to lookout_raster_add, not
 * here. `scale` and the bounds appear only when the archive carries them.
 *
 * Borrowed: valid until the next lookout_scan_charts. *out_len (NULL to
 * ignore) receives the length. NULL when the path cannot be read. No handle
 * needed: this runs before anything is open.
 *
 * NOT REENTRANT. The answer lives in one buffer that the next call frees, so
 * two threads scanning at once free each other's answer and both read rubbish.
 * A host that scans off its main thread must serialize the calls. */
const char *lookout_scan_charts(const char *path, size_t *out_len);

/* lookout_scan_charts for a chart set that arrives as ONE .zip — the shape a
 * chart agency publishes: NOAA's All_ENCs.zip is 788 MB holding 2.0 GiB across
 * 27,680 entries. Only the archive's central directory is read (about 8 ms for
 * that one); nothing is inflated and nothing is written.
 *
 * Same JSON, so a host reads a folder and an archive the same way, with two
 * differences that follow from there being no files yet:
 *
 *   - Each `path` is the ENTRY NAME inside the archive, not a filesystem path.
 *     That is what the engine's zip bake takes back.
 *   - Nothing is verified, so "refused" is always 0. Verifying means opening an
 *     archive and asking the engine what it holds, and an entry cannot be
 *     opened; inside a .zip the name is the whole answer.
 *
 * Shares the one buffer with lookout_scan_charts, and is NOT REENTRANT for the
 * same reason. */
const char *lookout_scan_zip(const char *path, size_t *out_len);

/* ---- view -------------------------------------------------------------- */
void lookout_fit_chart(lookout *h, lookout_view *out); /* fit the whole cell */
void lookout_default_view(lookout *h, lookout_view *out); /* opening view, no saved pose */
void lookout_set_view(lookout *h, const lookout_view *v);
void lookout_get_view(lookout *h, lookout_view *out);
int  lookout_resize(lookout *h, uint32_t width, uint32_t height); /* points */
float lookout_pixel_density(lookout *h);                          /* HiDPI px/pt */
/* Declare the host's scale factor (Android DisplayMetrics.density, GTK's
 * gtk_widget_get_scale_factor, …) instead of letting the backend infer it from
 * surface pixels / declared points. Optional, but state it whenever the host
 * knows: inference is a division that a mid-resize or mid-rotation frame can
 * catch between the two values. */
void lookout_set_pixel_density(lookout *h, float density);

/* ---- raster underlay ---------------------------------------------------
 *
 * Satellite imagery and other picture charts the MARINER supplies, drawn
 * beneath the vector chart. The app offers no catalogue and no download: it
 * opens files that are already on the device.
 *
 * Sources group into SETS by provider, because the same water ships from
 * several — ArcGIS, Bing, Google, Navionics side by side — and finding the one
 * that shows the bottom today means flipping between them over the spot that
 * matters. One set is drawn at a time; the cycle includes "no picture", so a
 * single control also reaches the full chart.
 *
 * A step never moves the camera and never rebuilds the chart scene. That is the
 * point: a mariner comparing two providers over a reef must not lose their fix
 * to a flicker.
 *
 * Tiles stream on a worker with their own memory ceiling, so nothing here
 * blocks a frame. Where a source has no tile — the ordinary case, since these
 * pyramids are clipped to a coastline — the chart simply draws alone. */

/* Open a raster chart (.mbtiles today) and add it to its set. 1 on success, 0
 * when the file will not open — a bad chart never takes the app down, so a host
 * importing a folder keeps going. */
int lookout_raster_add(lookout *h, const char *path);

/* Step to the next raster chart set COVERING THE SAME WATER, or to "no picture"
 * after the last one.
 *
 * Sets that cover different water are not steps in the cycle. They are drawn
 * together (see below), so there is nothing to choose between them. */
void lookout_raster_cycle(lookout *h);

/* The name of the set drawn over THIS view, or "" for no picture.
 *
 * Sets that cover different water draw at the same time: San Francisco and the
 * Atlantic are not a mode a mariner should have to switch. Only sets whose
 * coverage meets are a choice, and the cycle settles it. So one name describes
 * one view, not the whole selection.
 *
 * Borrowed: valid until the set list changes. *out_len (NULL to ignore)
 * receives the length. */
const char *lookout_raster_active_name(lookout *h, size_t *out_len);

/* 1 while the chart is drawing WITHOUT its opaque water and land fills, because
 * a picture is beneath THIS view. NOT the same as "a set is selected": the mode
 * engages only where imagery actually covers, so a mariner carrying a Croatian
 * set still gets a full chart in Chesapeake Bay. A host showing "the chart is
 * reduced" must key off THIS, not off the set name. */
int lookout_raster_over_chart(lookout *h);

/* Name set `i`, ask whether it has enabled charts in view, read which set is
 * drawn, and draw one directly.
 *
 * A mariner carrying four providers for one coast has to SEE what they carry
 * and pick one. A cycle alone cannot report what is installed. Build a menu
 * from these: walk 0..lookout_raster_set_count, keep the sets in view, and mark
 * the one lookout_raster_active_index reports — which is the set drawn over
 * this view, so the mark agrees with the picture.
 *
 * Each set carries its own on/off. Selecting one turns off the sets covering
 * the same water and leaves the other coasts alone, so a mariner switching the
 * Atlantic on does not switch the Pacific on with it.
 *
 * lookout_raster_select(h, -1) turns off what is drawn over THIS view, not
 * every set. Names are borrowed and valid until the set list changes. */
const char *lookout_raster_set_name(lookout *h, uint32_t i, size_t *out_len);
int lookout_raster_set_in_view(lookout *h, uint32_t i);
int32_t lookout_raster_active_index(lookout *h);
void lookout_raster_select(lookout *h, int32_t i);

/* Read and write one set's DRAWN state by index, with no camera in it.
 *
 * A host has to save which sets the mariner chose and put them back at the next
 * launch, because lookout_raster_add draws a set it has just opened — right for
 * a chart the mariner is adding now, wrong for one being re-installed after
 * they switched it off. The pair above cannot do it: lookout_raster_active_index
 * describes one view, and lookout_raster_select(-1) turns off whatever is drawn
 * over that view rather than a set you name. Both fail on the ordinary case of a
 * set covering water the opening view is nowhere near.
 *
 * The election still holds. Showing a set turns off the sets covering the same
 * water, so a restore can never put two competing pictures on at once, and a set
 * whose every chart is switched off (lookout_raster_set_enabled) stays off.
 *
 * Restore in two passes: turn off everything the mariner had off, then turn on
 * everything they had on. One pass in either direction loses a set whose rival
 * was drawn first when the sources were added. */
int  lookout_raster_shown(lookout *h, uint32_t i);
void lookout_raster_set_shown(lookout *h, uint32_t i, int shown);

/* Turn one raster chart on or off WITHOUT removing it, by the path it was added
 * with. A mariner who carries four providers for one coast wants three of them
 * quiet, not deleted — they are half-gigabyte downloads. Takes effect at once;
 * every cached tile is dropped, because a change here changes which picture a
 * given address answers with. 0 when no installed chart has that path. */
int lookout_raster_set_enabled(lookout *h, const char *path, int enabled);
int lookout_raster_enabled(lookout *h, const char *path);

/* The name of a set that covers this view, DRAWN OR NOT, or "". Use it to tell
 * the mariner a picture is available here while it is switched off — otherwise
 * a mariner sailing into coverage sees no reason to turn it on, and never
 * learns the raster chart they installed is under them. Borrowed; valid until the
 * set list changes. */
const char *lookout_raster_available_name(lookout *h, size_t *out_len);

/* Hide the vector chart WHERE A PICTURE COVERS IT. The chart stays everywhere
 * else, so the mariner never gives up the chart to look at the picture. The
 * scene stays built, so this is instant and never rebuilds.
 *
 * Use it to compare. Hide the chart and show it again over a feature; anything
 * that moves is a real disagreement between the chart and the picture. Your eye
 * finds that motion far better than it finds a small offset in a blend. */
void lookout_set_chart_hidden(lookout *h, int hidden);
void lookout_toggle_chart(lookout *h);
int  lookout_chart_hidden(lookout *h);

/* How many sets are installed. The cycle has this many positions, plus one for
 * "no picture". */
uint32_t lookout_raster_set_count(lookout *h);

/* ---- interaction (pixel coords; *_logical scale by pixel density) ------- */
void lookout_pan(lookout *h, float dx_px, float dy_px);
void lookout_zoom_at(lookout *h, double dzoom, float x_px, float y_px);
void lookout_pan_logical(lookout *h, float dx_pt, float dy_pt);
void lookout_zoom_at_logical(lookout *h, double dzoom, float x_pt, float y_pt);
void lookout_screen_to_geo(lookout *h, float x_px, float y_px, double *lon, double *lat);
void lookout_geo_to_screen(lookout *h, double lon, double lat, float *x_px, float *y_px);

/* ---- follow mode -------------------------------------------------------- */
/* Hold own ship at a fixed point on screen — the horizontal centre, three
 * quarters down the view, so the water ahead fills it — and move the chart
 * under the ship as the fix updates. Turning it on moves the chart at once
 * when a fresh fix exists. With no fix, or one past the 5 s staleness window,
 * the camera holds and follow waits for one.
 *
 * The core turns follow off itself on lookout_pan and lookout_pan_logical: a
 * pan hands the chart back to the mariner. Zoom and rotation leave it on, and
 * a zoom while following pivots on own ship whatever point you pass.
 *
 * The position comes from the plugin layer, so follow needs plugins running to
 * do anything. */
void lookout_follow_set(lookout *h, int on);

/* What follow mode is doing: 0 off, 1 following own ship, 2 on but waiting for
 * a fix. Non-zero means follow is on, so `!= 0` is enough for a control that
 * draws two states. Poll it on your render tick: the core turns follow off on
 * a pan, so a button that tracks only its own taps goes wrong. */
int lookout_follow_active(lookout *h);

/* Course up: turn the chart so own ship's heading points up the screen, and
 * keep turning it as the ship turns. Heading when the compass is fresh, else
 * course over ground; with neither the chart holds and the control waits.
 * Independent of follow — either mode works alone.
 *
 * The core turns course up off itself when the mariner rotates the chart by
 * hand or asks for north up. */
void lookout_course_up_set(lookout *h, int on);

/* 0 off, 1 turning with own ship, 2 on but waiting for a heading. */
int lookout_course_up_active(lookout *h);

/* Own ship does not step from fix to fix. The core carries the newest fix
 * forward along COG at SOG (stopping at the 5 s staleness window) and both the
 * camera and the own-ship overlay ride that display position, so the boat sits
 * still on screen and the chart slides. While it moves, lookout_needs_redraw
 * answers 1 every frame. */

/* ---- own ship's position ------------------------------------------------ */
/* What a position readout may say. A stale fix is never presented as a live
 * one, which is why the middle state exists: "the fix dropped" and "you never
 * set one up" are different problems and want different answers from the
 * mariner. */
typedef enum {
    LOOKOUT_FIX_NONE = 0, /* no source of position at all */
    LOOKOUT_FIX_LOST = 1, /* a source exists, its fix aged out or was lost */
    LOOKOUT_FIX_LIVE = 2  /* a fix inside its freshness window */
} lookout_fix_state;

/* Own ship's REPORTED position, and how much to believe it. Returns a
 * lookout_fix_state; *lon and *lat (either may be NULL) are written ONLY for
 * LOOKOUT_FIX_LIVE.
 *
 * A READOUT SHOWS THESE NUMBERS OR IT SHOWS NONE. It never falls back to the
 * map centre or the cursor: a coordinate with no boat behind it is exactly the
 * ambiguity this removes, and panning away from own ship is when a mistaken
 * value is dangerous. The coordinates of a PLACE come from the chart menu,
 * on demand, at the point the mariner asked about.
 *
 * The reported fix, not the display position own ship draws at: that one is
 * carried forward along COG between fixes, and a dead-reckoned number must
 * never be shown as a reported value. Staleness is the vessel store's own account,
 * so there is no second clock to disagree with it.
 *
 * LOOKOUT_FIX_NONE is the state that carries a fix-it: no plugin has ever
 * published a position, so the mariner has no source configured (desktop:
 * offer Settings > Connections) or the device's own receiver has not been
 * asked for permission (phones and tablets). */
int lookout_own_ship(lookout *h, double *lon, double *lat);

/* ---- markers ------------------------------------------------------------- */
/*
 * The mariner's own mark on the water: a rock they were told about, a crab
 * pot, an anchorage to come back to. Not a route and not a waypoint in a
 * navigation sense.
 *
 * The core owns them, because every shell shows the same ones and they must
 * survive a restart, and they are CHART-INDEPENDENT: a marker belongs to the
 * boat, not to the cell that happened to be open, so it survives changing
 * chart libraries. The core writes them under the per-user directory beside
 * the installed plugins (macOS: ~/Library/Application Support/Lookout Marine/
 * markers.json) and reads them back at every open. A shell stores nothing.
 *
 * They draw themselves, in the S-52 mariner magenta reserved for the mariner's
 * own additions, with their names beside them. A shell adds no drawing code.
 */

/* One marker. `name` is NUL-terminated and BORROWED: valid until the next call
 * that changes the markers (add, rename, remove). Copy it if you keep it. */
typedef struct {
    uint64_t    id;
    double      lon, lat;
    const char *name;
    size_t      name_len;
    int64_t     dropped_ms; /* when it was dropped, Unix epoch milliseconds */
} lookout_marker;

/* Drop a marker at a geographic point. Returns its id, or 0 when nothing could
 * be stored.
 *
 * THE DROP NEVER WAITS FOR TYPING. A mariner drops a mark one-handed on a
 * moving boat, so this places it AND names it in one call: "Mark 1", "Mark 2",
 * counting up from the highest number in use, so two marks are never called
 * the same thing and a mariner who never renames one still has something to
 * say on the radio. Renaming is a separate, unhurried action. */
uint64_t lookout_marker_add(lookout *h, double lon, double lat);

/* Walk the markers in drop order. lookout_marker_get answers 1 while `i` is in
 * range, 0 past the end; lookout_marker_by_id answers 0 once a marker is
 * gone. */
uint32_t lookout_marker_count(lookout *h);
int lookout_marker_get(lookout *h, uint32_t i, lookout_marker *out);
int lookout_marker_by_id(lookout *h, uint64_t id, lookout_marker *out);

/* The marker nearest a LOGICAL point: 1 when one is within about 14 pt of it,
 * 0 when none is. This is what decides a chart menu's items: over a marker it
 * offers Rename and Remove in place of Drop. */
int lookout_marker_at(lookout *h, float x_pt, float y_pt, lookout_marker *out);

/* Rename one marker, up to 32 characters; longer is cut on a character
 * boundary. An EMPTY name keeps the old one, because a field the mariner
 * cleared and left is not a request for a nameless mark. Returns 0, or -1 for
 * an unknown id. */
int lookout_marker_rename(lookout *h, uint64_t id, const char *name);

/* Remove one marker. Returns 0, or -1 for an unknown id. */
int lookout_marker_remove(lookout *h, uint64_t id);

/* ---- mariner (ALL S-52 display settings) ------------------------------- */
/* Fill *m with tile57's canonical defaults, then edit and set. */
void lookout_mariner_defaults(tile57_mariner *m);
void lookout_get_mariner(lookout *h, tile57_mariner *out);
/* Apply the full state. Visibility-only changes (scheme, categories, text,
 * soundings, size) apply live; emission-changing ones (contours, units, dates,
 * viewing groups, point/boundary style, overscale, extra size scales) mark a
 * rebuild, done lazily on the next render. */
void lookout_set_mariner(lookout *h, const tile57_mariner *m);

/* ---- build + render ---------------------------------------------------- */
int lookout_build(lookout *h);                 /* force (re)tessellation */
int lookout_render(lookout *h);                /* one window frame (1=drawn, 0=headless) */
/* 1 if a redraw is needed (view/state changed, a build is filling in, or the
 * view left coverage). When 0 the chart is static — block on events, no CPU.
 * Render on demand: call lookout_render only when this returns 1. */
int lookout_needs_redraw(lookout *h);

/* D3D12-panel mode only. The core-owned IDXGISwapChain* for
 * ISwapChainPanelNative::SetSwapChain; NULL on any other kind or backend.
 * The core keeps ownership and resizes it on lookout_resize. */
void *lookout_d3d12_swapchain(lookout *h);

int lookout_snapshot_png(lookout *h, const char *path);
int lookout_snapshot_rgba(lookout *h, uint8_t *dst, size_t dst_len); /* w*h*4 */

/* ---- pick (S-52 cursor pick at a geo point) ---------------------------- */
void lookout_pick(lookout *h, double lon, double lat, const tile57_query_cb *cb);

/* The pick a chartplotter should SHOW, through the same callback: the features
 * worth reporting, best first. The engine reports in draw order, which puts the
 * land area before the light that was tapped, so the core applies three rules
 * every shell would otherwise re-invent:
 *
 *   - a meta object stays only when it carries something to read (M_NPUB holds
 *     the chart's cautions; M_QUAL answers every pick and says nothing),
 *   - a feature the cell gave no attributes never leads,
 *   - the most specific object wins: point, then line, then area, and what the
 *     object is decides within that.
 *
 * It also states depths in the mariner's unit and prints that unit, because a
 * cell holds only metres: VALSOU, VALDCO, DRVAL1 and DRVAL2 read "17 ft" or
 * "5.4 m", matching the chart label digit for digit. Feet are whole feet,
 * truncated down. Heights (VERCLR, HEIGHT, ELEVAT) stay metric — a height is a
 * unit the mariner does not carry.
 *
 * Use this for a pick report; use lookout_pick when you want the engine's own
 * list untouched, in metres. */
void lookout_pick_ranked(lookout *h, double lon, double lat, const tile57_query_cb *cb);

/* A file a picked feature points at, rather than carries: TXTDSC and NTXTDS name
 * a text file, PICREP names a picture, and S-101 puts the same in a
 * fileReference. `cell` is the chart name the pick reported; `name` is the value
 * of the attribute. The bake stores those files beside the chart, and the match
 * ignores case.
 *
 * *bytes is NULL and *len is 0 when the chart carries no such file. The bytes
 * belong to the handle and stay valid until lookout_close; *mime is static. */
void lookout_aux_file(lookout *h, const char *cell, const char *name,
                      const uint8_t **bytes, size_t *len, const char **mime);

/* ---- convenience live toggles ------------------------------------------ */
void lookout_cycle_scheme(lookout *h);
void lookout_toggle_text(lookout *h);
void lookout_toggle_soundings(lookout *h);
void lookout_toggle_other_category(lookout *h);
void lookout_nudge_safety_contour(lookout *h, double delta);
void lookout_adjust_size(lookout *h, float factor);

/* ---- smooth interaction ------------------------------------------------ */
/* Shift-drag course-up rotation: rotate about the view centre by the angle the
 * cursor swept from (x0,y0) to (x1,y1), both logical points. */
void lookout_rotate_drag_logical(lookout *h, float x0_pt, float y0_pt, float x1_pt, float y1_pt);
/* Snap the view back to north-up. */
void lookout_reset_rotation(lookout *h);
/* OS memory warning: trim reclaimable engine caches at the next safe point. */
void lookout_memory_warning(lookout *h);
/* Start a momentum pan with a logical-px/sec velocity (0,0 stops any coast when
 * a grab starts). */
void lookout_fling_start(lookout *h, double vx, double vy);
/* 1 while an eased zoom or fling is in progress — render every frame while true. */
int  lookout_animating(lookout *h);
/* Advance the eased zoom / fling by dt seconds; call each frame while animating. */
void lookout_tick_anim(lookout *h, double dt);
/* 1 while a background tessellation is filling in — use a short idle timeout. */
int  lookout_is_building(lookout *h);
/* The current view's 1:N scale denominator (for the HUD), from the camera math. */
/* Live overscale factor (>=1); indicate when > ~1.05. */
double lookout_overscale(lookout *h);
double lookout_scale_denominator(lookout *h);

#ifdef __cplusplus
}
#endif
#endif /* LOOKOUT_H */
