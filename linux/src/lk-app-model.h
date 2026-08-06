/* lk-app-model.h — shared app state: chart open/recents, live readouts, and
 * headerbar actions. Holds the one LkChartController and funnels commands
 * through it. Readouts are GObject properties the HUD tracks via notify::. */
#pragma once

#include <gtk/gtk.h>

#include "lk-chart-controller.h"
#include "lk-raster.h"

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
/* Zoom until the view reads 1:`denominator`. The chart holds the nearest scale
 * it has. */
void lk_app_model_zoom_to_scale (LkAppModel *self, double denominator);
void lk_app_model_cycle_scheme (LkAppModel *self);
void lk_app_model_set_scheme (LkAppModel *self, int scheme);
void lk_app_model_toggle_text (LkAppModel *self);
void lk_app_model_toggle_soundings (LkAppModel *self);
void lk_app_model_toggle_other_category (LkAppModel *self);

/* ---- raster charts ------------------------------------------------------ */

/* Install the files the mariner chose, persist the list, and draw what was just
 * added when it covers this view. Files that will not open are reported
 * together through ::open-error, not one alert at a time — a folder of twenty
 * asking twenty times would be unusable. */
void lk_app_model_add_raster_charts (LkAppModel *self, const char *const *paths);

/* Replay the installed list into a chart the engine has just opened. */
void lk_app_model_reinstall_raster_charts (LkAppModel *self);

/* Forget one file. The engine cannot drop a chart from a live handle, so the
 * chart is switched off now and dropped the next time a chart opens. */
void lk_app_model_remove_raster_chart (LkAppModel *self, const char *path);

/* Turn one installed chart on or off. Off keeps the file. */
void     lk_app_model_set_raster_enabled (LkAppModel *self, const char *path, gboolean on);
gboolean lk_app_model_raster_enabled (LkAppModel *self, const char *path);

/* The installed files, and them grouped by set. The groups are transfer full. */
const char *const *lk_app_model_get_raster_paths (LkAppModel *self);
guint              lk_app_model_get_raster_count (LkAppModel *self);
GPtrArray         *lk_app_model_get_raster_groups (LkAppModel *self);

/* Step to the next set covering this water, draw one directly, and hide the ENC
 * where a picture covers it. */
void lk_app_model_cycle_raster (LkAppModel *self);
void lk_app_model_select_raster_set (LkAppModel *self, int index);
void lk_app_model_toggle_chart (LkAppModel *self);

/* Read every raster field off the engine at once. Anything that changes the set
 * list or the selection outside a frame must call this: the readouts only run
 * while the chart renders, and the settings window can be open over a chart
 * that is standing still. Emits ::raster-changed when something moved. */
void lk_app_model_refresh_raster_state (LkAppModel *self);

/* What the pill is built from. The sets are borrowed. */
GPtrArray  *lk_app_model_get_raster_sets (LkAppModel *self);
int         lk_app_model_get_raster_active (LkAppModel *self);
const char *lk_app_model_get_raster_available (LkAppModel *self);
gboolean    lk_app_model_get_raster_over_chart (LkAppModel *self);
gboolean    lk_app_model_get_chart_hidden (LkAppModel *self);

/* ---- search: coordinate go-to ------------------------------------------- */

/* Parse `text` as a coordinate and recentre. TRUE if it was recognisable. */
gboolean lk_app_model_go_to_coordinate (LkAppModel *self, const char *text);

/* Tolerant lat/lon parser: decimal pairs and DMS with hemispheres. */
gboolean lk_coordinate_parse (const char *text, double *out_lat, double *out_lon);

/* Tolerant scale parser: "25000", "25,000", "1:25000", "25k", "1:2.5M". */
gboolean lk_scale_parse (const char *text, double *out_denominator);

/* ---- readouts pushed by the controller ---------------------------------- */

void lk_app_model_set_cursor_geo (LkAppModel *self, gboolean valid, double lon, double lat);
void lk_app_model_push_readouts (LkAppModel *self,
                                 lookout_view view,
                                 double scale_denominator,
                                 double overscale,
                                 int scheme);
void lk_app_model_set_building (LkAppModel *self, gboolean building);
/* The chart view's size in logical points, pushed on every allocation. */
void lk_app_model_set_view_size (LkAppModel *self, int width, int height);
void lk_app_model_set_first_build_done (LkAppModel *self, gboolean done);
/* An open is in flight. `preparing_symbols` marks the first-ever run baking the
 * symbol/font atlases, which warrants a distinct (and slower) message. */
void lk_app_model_set_opening (LkAppModel *self, gboolean opening, gboolean preparing_symbols);
gboolean lk_app_model_get_show_startup_loader (LkAppModel *self);
gboolean lk_app_model_get_preparing_symbols (LkAppModel *self);
void lk_app_model_set_chart_open (LkAppModel *self, gboolean open, const char *path);
void lk_app_model_set_open_error (LkAppModel *self, const char *message);

/* The pick from the last tap, and where on the chart it landed (logical points
 * in the chart view — the report stands beside the mark there). Transfer full;
 * emits ::pick-results, which is what rebuilds the report. */
void       lk_app_model_set_pick (LkAppModel *self, GPtrArray *results, double x, double y);
void       lk_app_model_clear_pick (LkAppModel *self);
GPtrArray *lk_app_model_get_pick_results (LkAppModel *self);
gboolean   lk_app_model_get_pick_point (LkAppModel *self, double *out_x, double *out_y);

/* Which object of the pick the report is showing. */
guint lk_app_model_get_pick_index (LkAppModel *self);
void  lk_app_model_set_pick_index (LkAppModel *self, guint index);

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
int      lk_app_model_get_view_width (LkAppModel *self);
int      lk_app_model_get_view_height (LkAppModel *self);

G_END_DECLS
