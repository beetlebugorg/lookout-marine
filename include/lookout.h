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

/* ---- wasm plugins (prototype) ------------------------------------------ */
/* Load and start the plugins in `dir`: every "<id>.manifest.json" with an
 * "<id>.wasm" beside it, which is the layout `zig build plugins` installs into
 * zig-out/plugins. Plugins publish vessel and AIS data and draw chart
 * overlays; the core renders whatever they draw, so a shell needs no other
 * call. Returns 0 on success, -1 when the directory cannot be read or this
 * build has no plugin host (macOS only in the prototype). A plugin that fails
 * to load is logged and skipped, so 0 does not mean every module started.
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
 *   {"plugins":[{"id":"org.beetlebug.ais","name":"AIS targets","live":true,
 *                "status":"{\"state\":\"running\",...}",
 *                "settings":[
 *                  {"key":"cpa_limit","label":"CPA limit","kind":"number",
 *                   "unit":"m","min":93,"max":9260,"default":926,"value":926},
 *                  {"key":"cpa_alarm","label":"Collision alarm",
 *                   "kind":"toggle","default":true,"value":true}]}]}
 *
 * A shell draws a control per field — a number field with its unit and range,
 * a toggle as a switch — and needs to know nothing about what a plugin does.
 * Borrowed until the next plugin query; NULL when no plugin layer is up.
 * *out_len (NULL to ignore) receives the length. */
const char *lookout_plugins_json(lookout *h, size_t *out_len);

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
