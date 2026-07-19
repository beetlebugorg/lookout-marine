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

/* ---- lifecycle --------------------------------------------------------- */
/* Open a baked chart (.pmtiles) and create the GPU device. want_window!=0 opens
 * a window (needs a display); else rendering is offscreen. NULL on error. */
lookout *lookout_open(const char *chart_path, uint32_t width, uint32_t height,
                      int want_window, int want_msaa);
void lookout_close(lookout *h);

/* ---- view -------------------------------------------------------------- */
void lookout_fit_chart(lookout *h, lookout_view *out); /* fit the whole cell */
void lookout_set_view(lookout *h, const lookout_view *v);
void lookout_get_view(lookout *h, lookout_view *out);
int  lookout_resize(lookout *h, uint32_t width, uint32_t height); /* points */
float lookout_pixel_density(lookout *h);                          /* HiDPI px/pt */

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

#ifdef __cplusplus
}
#endif
#endif /* LOOKOUT_H */
