/* lookout.h — C ABI for lookout-core: render a baked tile57 chart on SDL_GPU.
 *
 * A minimal embedding surface over the Zig `Lookout` renderer. The build phase
 * (lookout_build_view) tessellates the tile57 Surface stream once; the toggles
 * below are frame-phase, uniform-only, and never re-tessellate (except
 * lookout_nudge_safety_contour, which changes geometry and rebuilds). */
#ifndef LOOKOUT_H
#define LOOKOUT_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct lookout lookout;

/* Open a baked chart (.pmtiles) and create the GPU device. want_window!=0 opens
 * a window (needs a display); otherwise rendering is offscreen. NULL on error. */
lookout *lookout_open(const char *chart_path, uint32_t width, uint32_t height,
                      int want_window, int want_msaa);

/* Center + fit-zoom for the whole chart, from its embedded metadata. */
void lookout_recommended_view(lookout *h, double *lon, double *lat, double *zoom);

/* Build phase: tessellate the view once, upload GPU buffers. 0 on success. */
int lookout_build_view(lookout *h, double lon, double lat, double zoom);

/* One frame to the window (returns 1 if a window exists, 0 headless, -1 error). */
int lookout_render_window_frame(lookout *h);
/* Render offscreen and write a PNG. 0 on success. */
int lookout_save_png(lookout *h, const char *path);

/* Frame-phase, uniform-only (no re-tessellation): */
void lookout_set_scheme(lookout *h, size_t k);   /* 0=day, 1=night (as opened) */
void lookout_toggle_scheme(lookout *h);
void lookout_toggle_text(lookout *h);
void lookout_toggle_soundings(lookout *h);
void lookout_toggle_other_category(lookout *h);
void lookout_pan_px(lookout *h, float dx, float dy);
void lookout_zoom_about(lookout *h, double dz, float px, float py);

/* Geometry-changing (rebuilds the scene). 0 on success. */
int lookout_nudge_safety_contour(lookout *h, double delta);

void lookout_close(lookout *h);

#ifdef __cplusplus
}
#endif
#endif /* LOOKOUT_H */
