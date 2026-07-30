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

/* Windows composition target (a WinUI/XAML SwapChainPanel host). The host owns
 * a D3D12 device + queue and shares render textures and one timeline fence
 * (NT handles from ID3D12Device::CreateSharedHandle). The core imports them,
 * renders into buffers[i] on lookout_render_dxgi, and signals the fence; the
 * host GPU-waits, copies to its swapchain back buffer, and presents. */
typedef struct {
    void    *buffers[4];       /* shared texture handles */
    uint32_t buffer_count;
    void    *fence;            /* shared D3D12 fence handle */
    uint32_t dxgi_format;      /* DXGI_FORMAT (87 = B8G8R8A8_UNORM) */
    uint32_t width, height;    /* pixels */
    uint32_t adapter_luid_low; /* the D3D12 adapter LUID; the core matches it */
    int32_t  adapter_luid_high;
} lookout_dxgi_target;

typedef enum {
    LOOKOUT_NATIVE_NONE = 0,           /* offscreen only (snapshot) */
    LOOKOUT_NATIVE_METAL_LAYER = 1,    /* CAMetalLayer* (macOS & iOS) */
    LOOKOUT_NATIVE_WIN32_HWND = 4,     /* lookout_win32_window*   (vk backend) */
    LOOKOUT_NATIVE_X11_WINDOW = 5,     /* lookout_x11_window*     (vk backend) */
    LOOKOUT_NATIVE_ANDROID_WINDOW = 7, /* ANativeWindow* (Android, vk backend) */
    LOOKOUT_NATIVE_WAYLAND_SURFACE = 8,/* lookout_wayland_surface* (vk backend) */
    LOOKOUT_NATIVE_DXGI_TARGET = 9     /* lookout_dxgi_target*    (vk backend) */
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

/* DXGI-target mode only. Render into buffers[index]: wait the shared fence at
 * wait_value (0 = none), signal it at signal_value. 1 = submitted. */
int lookout_render_dxgi(lookout *h, uint32_t index, uint64_t wait_value, uint64_t signal_value);
/* DXGI-target mode only. Swap to new shared textures after a host resize. */
int lookout_retarget_dxgi(lookout *h, const lookout_dxgi_target *target);

int lookout_snapshot_png(lookout *h, const char *path);
int lookout_snapshot_rgba(lookout *h, uint8_t *dst, size_t dst_len); /* w*h*4 */

/* ---- pick (S-52 cursor pick at a geo point) ---------------------------- */
void lookout_pick(lookout *h, double lon, double lat, const tile57_query_cb *cb);

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
