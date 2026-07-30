/* lk-app-model.h — shared app state: chart open/recents, live readouts, and
 * headerbar actions. Holds the one LkChartController and funnels commands
 * through it. Readouts are GObject properties the HUD tracks via notify::. */
#pragma once

#include <gtk/gtk.h>

#include "lk-chart-controller.h"

G_BEGIN_DECLS

#define LK_TYPE_APP_MODEL (lk_app_model_get_type ())
G_DECLARE_FINAL_TYPE (LkAppModel, lk_app_model, LK, APP_MODEL, GObject)

LkAppModel        *lk_app_model_new (void);
LkChartController *lk_app_model_get_controller (LkAppModel *self);

/* ---- opening charts ----------------------------------------------------- */

/* Paths to open on first appearance: $LOOKOUT_OPEN, else last recent, else the
 * demo default. Transfer full strv; empty when nothing is available. */
char **lk_app_model_initial_chart_paths (LkAppModel *self);

/* Every baked cell under a directory, sorted. */
char **lk_app_model_chart_paths_in_dir (const char *dir);

/* Open a single .pmtiles file or a folder of cells (dispatches on what's on disk). */
void lk_app_model_open_chart (LkAppModel *self, const char *path);
void lk_app_model_open_chart_directory (LkAppModel *self, const char *dir);

const char *const *lk_app_model_get_recents (LkAppModel *self);

/* ---- commands (headerbar / menu) ---------------------------------------- */

void lk_app_model_zoom_in (LkAppModel *self);
void lk_app_model_zoom_out (LkAppModel *self);
void lk_app_model_zoom_to_fit (LkAppModel *self);
void lk_app_model_north_up (LkAppModel *self);
void lk_app_model_cycle_scheme (LkAppModel *self);
void lk_app_model_set_scheme (LkAppModel *self, int scheme);
void lk_app_model_toggle_text (LkAppModel *self);
void lk_app_model_toggle_soundings (LkAppModel *self);
void lk_app_model_toggle_other_category (LkAppModel *self);

/* ---- search: coordinate go-to ------------------------------------------- */

/* Parse `text` as a coordinate and recentre. TRUE if it was recognisable. */
gboolean lk_app_model_go_to_coordinate (LkAppModel *self, const char *text);

/* Tolerant lat/lon parser: decimal pairs and DMS with hemispheres. */
gboolean lk_coordinate_parse (const char *text, double *out_lat, double *out_lon);

/* ---- readouts pushed by the controller ---------------------------------- */

void lk_app_model_set_cursor_geo (LkAppModel *self, gboolean valid, double lon, double lat);
void lk_app_model_push_readouts (LkAppModel *self,
                                 lookout_view view,
                                 double scale_denominator,
                                 double overscale,
                                 int scheme);
void lk_app_model_set_building (LkAppModel *self, gboolean building);
void lk_app_model_set_first_build_done (LkAppModel *self, gboolean done);
/* An open is in flight. `preparing_symbols` marks the first-ever run baking the
 * symbol/font atlases, which warrants a distinct (and slower) message. */
void lk_app_model_set_opening (LkAppModel *self, gboolean opening, gboolean preparing_symbols);
gboolean lk_app_model_get_show_startup_loader (LkAppModel *self);
gboolean lk_app_model_get_preparing_symbols (LkAppModel *self);
void lk_app_model_set_chart_open (LkAppModel *self, gboolean open, const char *path);
void lk_app_model_set_open_error (LkAppModel *self, const char *message);

/* Identify results from the last tap. Transfer full; emits ::pick-results. */
void       lk_app_model_set_pick_results (LkAppModel *self, GPtrArray *results);
GPtrArray *lk_app_model_get_pick_results (LkAppModel *self);

/* ---- accessors the chrome reads ----------------------------------------- */

gboolean lk_app_model_get_has_chart (LkAppModel *self);
const char *lk_app_model_get_chart_path (LkAppModel *self);
gboolean lk_app_model_get_cursor_valid (LkAppModel *self);
double   lk_app_model_get_cursor_lon (LkAppModel *self);
double   lk_app_model_get_cursor_lat (LkAppModel *self);
double   lk_app_model_get_center_lon (LkAppModel *self);
double   lk_app_model_get_center_lat (LkAppModel *self);
double   lk_app_model_get_zoom (LkAppModel *self);
double   lk_app_model_get_rotation (LkAppModel *self);
double   lk_app_model_get_overscale (LkAppModel *self);
double   lk_app_model_get_scale_denominator (LkAppModel *self);
int      lk_app_model_get_scheme (LkAppModel *self);
const char *lk_app_model_get_scheme_name (LkAppModel *self);
gboolean lk_app_model_get_building (LkAppModel *self);

G_END_DECLS
