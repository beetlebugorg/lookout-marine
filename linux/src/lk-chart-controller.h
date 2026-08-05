/* lk-chart-controller.h — the single owner of the `lookout*` handle.
 *
 * Every lookout_* call funnels through here, on the main thread only (the
 * engine wants one thread, GTK wants the main one). Drives the on-demand render
 * loop: a frame-clock tick that runs only while animating or dirty and removes
 * itself once static; mutating calls re-arm it via lk_chart_controller_kick.
 *
 * All geometry is in LOGICAL POINTS, matching include/lookout.h; lookout
 * applies pixel density itself.
 */
#pragma once

#include <gtk/gtk.h>
#include <lookout.h>

G_BEGIN_DECLS

#define LK_TYPE_CHART_CONTROLLER (lk_chart_controller_get_type ())
G_DECLARE_FINAL_TYPE (LkChartController, lk_chart_controller, LK, CHART_CONTROLLER, GObject)

typedef struct _LkAppModel LkAppModel;

/* One S-57 feature returned by a cursor pick (mirrors PickFeature). */
typedef struct {
  char *cls;   /* S-57 object-class acronym, e.g. "LIGHTS", "DEPARE" */
  char *chart; /* source cell name */
  char *s57;   /* the full S-57 attribute JSON */
} LkPickFeature;

void lk_pick_feature_free (LkPickFeature *feature);

LkChartController *lk_chart_controller_new (void);

/* The model live readouts are pushed to. Not owned. */
void lk_chart_controller_set_model (LkChartController *self, LkAppModel *model);

/* ---- lifecycle ---------------------------------------------------------- */

/* Open baked charts into `view`, composing multiple into one library.
 * Recreates the handle if one exists. `paths` is a NULL-terminated strv. */
gboolean lk_chart_controller_open (LkChartController *self,
                                   const char *const *paths,
                                   GtkWidget         *view);

/* Re-open into the view already attached (menu / search / settings opens). */
gboolean lk_chart_controller_reopen (LkChartController *self, const char *const *paths);

/* Attach the render surface without opening, so a later open has a view. */
void lk_chart_controller_attach_view (LkChartController *self, GtkWidget *view);

void     lk_chart_controller_close    (LkChartController *self);
gboolean lk_chart_controller_is_open  (LkChartController *self);
const char *lk_chart_controller_chart_path (LkChartController *self);

/* ---- view --------------------------------------------------------------- */

lookout_view lk_chart_controller_get_view (LkChartController *self);
void         lk_chart_controller_set_view (LkChartController *self, lookout_view view);
void         lk_chart_controller_fit_chart (LkChartController *self);
/* Logical points. */
void         lk_chart_controller_resize (LkChartController *self, int width, int height);
void         lk_chart_controller_set_scale (LkChartController *self, int scale);

/* ---- interaction (logical points in) ------------------------------------ */

void lk_chart_controller_pan (LkChartController *self, double dx, double dy);
void lk_chart_controller_zoom_at (LkChartController *self, double dzoom, double x, double y);
void lk_chart_controller_zoom_centered (LkChartController *self, double dzoom);
void lk_chart_controller_rotate_drag (LkChartController *self,
                                      double x0, double y0, double x1, double y1);
void lk_chart_controller_reset_rotation (LkChartController *self);
void lk_chart_controller_fling_start (LkChartController *self, double vx, double vy);

gboolean lk_chart_controller_geo_at (LkChartController *self,
                                     double x, double y,
                                     double *out_lon, double *out_lat);

/* ---- mariner ------------------------------------------------------------ */

tile57_mariner lk_chart_controller_get_mariner (LkChartController *self);
void           lk_chart_controller_set_mariner (LkChartController *self, tile57_mariner mariner);
void           lk_chart_controller_sync_device_scale (LkChartController *self);

void lk_chart_controller_cycle_scheme (LkChartController *self);
void lk_chart_controller_toggle_text (LkChartController *self);
void lk_chart_controller_toggle_soundings (LkChartController *self);
void lk_chart_controller_toggle_other_category (LkChartController *self);

/* ---- pick --------------------------------------------------------------- */

/* The features a chartplotter should SHOW under a geo point, best first — the
 * engine's ranked pick, not its draw-order list. Transfer full: a GPtrArray of
 * LkPickFeature. */
GPtrArray *lk_chart_controller_pick (LkChartController *self, double lon, double lat);

/* A file a picked feature points at rather than carries: a caution note
 * (TXTDSC, NTXTDS) or a chart picture (PICREP), stored beside the chart at
 * bake time. *out_bytes is NULL when the chart carries no such file; the bytes
 * belong to the handle and stay valid until the chart closes. */
void lk_chart_controller_aux_file (LkChartController *self,
                                   const char        *cell,
                                   const char        *name,
                                   const guint8     **out_bytes,
                                   gsize             *out_length,
                                   const char       **out_mime);

/* Re-arm the render loop after a state change made outside this file. */
void lk_chart_controller_kick (LkChartController *self);

G_END_DECLS
