/* lk_controller — the one lookout* handle and the on-demand render loop.
 *
 * Host-agnostic C (no WinUI, no GTK): the C++/WinRT shell owns the window, the
 * SwapChainPanel, the per-frame pacemaker and input; it drives this each frame
 * with lk_controller_tick() and forwards gestures to the lk_controller_* calls.
 * Mirrors linux/src/lk-chart-controller.c, minus GObject/GTK. */
#ifndef LK_CONTROLLER_H
#define LK_CONTROLLER_H

#include <lookout.h> /* lookout, lookout_view, tile57_mariner */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lk_controller lk_controller;

/* Live HUD values, polled by the host each tick (see lk_controller_readout). */
typedef struct {
    double lon, lat;       /* view centre */
    double zoom;           /* fractional web-mercator zoom */
    double rotation_deg;   /* course-up rotation (0 = north-up) */
    double scale_denom;    /* 1:N */
    double overscale;      /* >=1; indicate when > ~1.05 */
    int    scheme;         /* 0 day, 1 dusk, 2 night */
    int    building;       /* 1 while a background tessellation fills in */
} lk_readout;

/* One identified feature from a pick (class / S-57 acronym / chart id). */
typedef struct {
    char cls[128];
    char s57[64];
    char chart[128];
} lk_pick_feature;

lk_controller *lk_controller_new(void);
void           lk_controller_free(lk_controller *self);

/* Open n baked cells (1 = single, >1 = composed library). The core makes its
 * own D3D12 device and composition swapchain (lk_controller_swapchain).
 * width/height are logical points; density is the DPI scale (dpi/96). 1 on ok. */
int  lk_controller_open(lk_controller *self, const char *const *paths, int n,
                        unsigned width_pt, unsigned height_pt, float density);
/* The core-owned IDXGISwapChain* for ISwapChainPanelNative::SetSwapChain. */
void *lk_controller_swapchain(lk_controller *self);
/* Mark the view dirty so the next tick renders (window newly visible, etc.). */
void lk_controller_invalidate(lk_controller *self);
void lk_controller_close(lk_controller *self);
int  lk_controller_is_open(lk_controller *self);

/* Per-frame. Advances animation, renders when needed, persists the pose every
 * few seconds. Returns 1 if a frame was drawn this tick. */
int  lk_controller_tick(lk_controller *self, double dt);
/* 1 while the host should keep ticking (animating / needs redraw / building). */
int  lk_controller_needs_tick(lk_controller *self);

void lk_controller_resize(lk_controller *self, unsigned width_pt, unsigned height_pt);
void lk_controller_set_density(lk_controller *self, float density);

/* Interaction — logical points, origin top-left (see lookout.h). */
void lk_controller_pan(lk_controller *self, double dx, double dy);
void lk_controller_zoom_at(lk_controller *self, double dzoom, double x, double y);
void lk_controller_zoom_centered(lk_controller *self, double dzoom, unsigned w_px, unsigned h_px);
void lk_controller_rotate_drag(lk_controller *self, double x0, double y0, double x1, double y1);
void lk_controller_reset_rotation(lk_controller *self);
void lk_controller_fling_start(lk_controller *self, double vx, double vy);
int  lk_controller_geo_at(lk_controller *self, double x, double y, double *lon, double *lat);

/* View. */
void lk_controller_fit_chart(lk_controller *self);
void lk_controller_set_center(lk_controller *self, double lon, double lat); /* keep zoom/rot */

/* Mariner. */
void lk_controller_get_mariner(lk_controller *self, tile57_mariner *out);
void lk_controller_set_mariner(lk_controller *self, const tile57_mariner *m);
void lk_controller_set_scheme(lk_controller *self, int scheme); /* persists */
void lk_controller_cycle_scheme(lk_controller *self);           /* persists */
void lk_controller_toggle_text(lk_controller *self);
void lk_controller_toggle_soundings(lk_controller *self);
void lk_controller_toggle_other_category(lk_controller *self);

/* Pick at a screen point; writes up to max features, returns the count. */
int  lk_controller_pick_at(lk_controller *self, double x, double y,
                           lk_pick_feature *out, int max);

void lk_controller_readout(lk_controller *self, lk_readout *out);

#ifdef __cplusplus
}
#endif
#endif /* LK_CONTROLLER_H */
