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

/* Free a string the API handed over. lookout and the shell need not share a
 * malloc, so bytes lookout allocates only lookout can free. */
void lookout_string_free(char *s);

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

/* The rest of the surface. Including lookout.h includes all four headers. */
#include "lookout-library.h"
#include "lookout-plugins.h"
#include "lookout-shell.h"

#ifdef __cplusplus
}
#endif
#endif /* LOOKOUT_H */
