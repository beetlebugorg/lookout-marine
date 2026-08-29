/* lk-app-model.h — shared app state: chart open/recents, live readouts, and
 * headerbar actions. Holds the one LkChartController and funnels commands
 * through it. Readouts are GObject properties the HUD tracks via notify::. */
#pragma once

#include "lk-chart-bake.h"

#include <gtk/gtk.h>

#include "lk-chart-controller.h"
#include "lk-chart-links.h"
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

/* The path the app would open on its own, drawable or not. Free with g_free. */
char *lk_app_model_initial_source (LkAppModel *self);

/* Every baked cell under a directory, sorted. */
char **lk_app_model_chart_paths_in_dir (const char *dir);

/* Open a single .pmtiles file or a folder of cells (dispatches on what's on disk). */
void lk_app_model_open_chart (LkAppModel *self, const char *path);
void lk_app_model_open_chart_directory (LkAppModel *self, const char *dir);

/* ---- the chart library: sets aboard -------------------------------------- */

/* A SET is a folder the mariner added, or one .zip — how a chart agency
 * publishes them. The list answers what is aboard and what is being sailed
 * on: switching a set off keeps it aboard and takes it out of the chart, and
 * the chart is composed as the UNION of the sets switched on. */
typedef struct {
  char    *path;
  char    *title;  /* the agency when the charts agree on one, else the folder name */
  char    *detail; /* "512 charts · 3 pictures · Coastal to Harbor · 1.2 GB";
                    * "" until the background scan lands */
  guint    charts; /* prepared cells, 0 until the scan lands */
  gboolean on;
} LkChartSetRow;

void lk_chart_set_row_free (LkChartSetRow *row);

/* Every set aboard, in the order added. Transfer full: a GPtrArray of
 * LkChartSetRow. Titles and details fill in as the background scans land;
 * ::chart-sets-changed says when to ask again. */
GPtrArray *lk_app_model_get_chart_sets (LkAppModel *self);

/* Switch one set into or out of the chart. Persists, and recomposes the open
 * chart from the sets that remain on — all of them off closes it. */
void lk_app_model_set_chart_set_on (LkAppModel *self, const char *path, gboolean on);

/* Take a set off the list. What Lookout prepared from it is deleted — it can
 * be made again — and the mariner's own folder is never touched. */
void lk_app_model_remove_chart_set (LkAppModel *self, const char *path);

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

/* ---- how the chart is oriented ------------------------------------------ */

/* What the compass bubble shows. The core owns both parts of it: it drops
 * follow on a pan and course up on a rotate by hand, so this is READ off the
 * engine and never remembered from a click. */
typedef enum {
  LK_ORIENT_UNLOCKED,  /* the chart is the mariner's to move */
  LK_ORIENT_ARMED,     /* locked to own ship, waiting for a fix */
  LK_ORIENT_NORTH_UP,  /* locked to own ship, north at the top */
  LK_ORIENT_COURSE_UP, /* locked to own ship, turning with it */
} LkOrientation;

LkOrientation lk_app_model_get_orientation (LkAppModel *self);

/* The compass bubble's click. It always locks the chart to own ship, and once
 * locked it cycles north up and course up. */
void lk_app_model_cycle_orientation (LkAppModel *self);

/* Own ship's reported position, and how much to believe it. The readout shows
 * these numbers or it shows none: it never falls back to the view centre, and a
 * dead-reckoned position is never presented as a reported one. */
int      lk_app_model_get_fix_state (LkAppModel *self);
gboolean lk_app_model_get_fix (LkAppModel *self, double *out_lon, double *out_lat);

/* ---- raster charts ------------------------------------------------------ */

/* Install the files the mariner chose, persist the list, and draw what was just
 * added when it covers this view. Files that will not open are reported
 * together through ::open-error, not one alert at a time — a folder of twenty
 * asking twenty times would be unusable. */
void lk_app_model_add_raster_charts (LkAppModel *self, const char *const *paths);

/* Replay the installed list into a chart the engine has just opened, and put
 * back the choices the mariner made about it: the charts switched off, the sets
 * they stopped drawing, and whether the ENC is hidden where a picture covers.
 * Called before the first frame, so nothing they switched off flashes up. */
void lk_app_model_reinstall_raster_charts (LkAppModel *self);

/* Forget one file. The engine cannot drop a chart from a live handle, so the
 * chart is switched off now and dropped the next time a chart opens. */
void lk_app_model_remove_raster_chart (LkAppModel *self, const char *path);

/* Forget every installed raster chart. Takes effect at the next open, since the
 * engine holds live pictures until then. */
void lk_app_model_forget_raster_charts (LkAppModel *self);

/* Turn one installed chart on or off. Off keeps the file. */
void     lk_app_model_set_raster_enabled (LkAppModel *self, const char *path, gboolean on);
gboolean lk_app_model_raster_enabled (LkAppModel *self, const char *path);

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

/* The controller calls this after the plugin layer changes. Emits
 * ::plugins-changed, which the alert watch follows to arm and disarm. */
void lk_app_model_notify_plugins_changed (LkAppModel *self);

/* The controller calls this when a camera move retires the chrome. Emits
 * ::chrome-retired, which the chart view follows to close its menu. */
void lk_app_model_retire_chrome (LkAppModel *self);

/* ---- charts by link ------------------------------------------------------ */

/* The mariner's linked charts (an online map AS the chart). Owned here so the
 * settings section and the HUD credit read one object. */
LkChartLinks *lk_app_model_get_chart_links (LkAppModel *self);

/* Re-push the active link into a chart the engine has just opened. Called
 * beside lk_app_model_reinstall_raster_charts, for the same reason: an alt
 * style belongs to a lookout handle, and every open replaces the handle. */
void lk_app_model_reapply_chart_link (LkAppModel *self);

/* Take lookout's chart-link snapshot if it changed. Called once per render
 * tick: the changed flag has ONE consumer. */
void lk_app_model_poll_chart_links (LkAppModel *self);

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

void lk_app_model_push_readouts (LkAppModel *self,
                                 lookout_view view,
                                 double scale_denominator,
                                 double overscale,
                                 int scheme);
void lk_app_model_set_building (LkAppModel *self, gboolean building);

/* ---- preparing charts ---------------------------------------------------- */
/* A folder or a .zip of raw S-57 cells has to be baked before it can be drawn.
 * The open path does that itself, so a mariner picks the charts an agency
 * published and the app deals with what that means. */

/* Where the bake has got to, or NULL when nothing is being prepared. */
const LkBakeProgress *lk_app_model_get_bake_progress (LkAppModel *self);

/* True while a set is being prepared. */
gboolean lk_app_model_get_baking (LkAppModel *self);

/* Ask the running bake to stop. What already landed stays: it is a usable
 * library, just a smaller one. */
void lk_app_model_cancel_bake (LkAppModel *self);
/* The chart view's size in logical points, pushed on every allocation. */
void lk_app_model_set_view_size (LkAppModel *self, int width, int height);
void lk_app_model_set_first_build_done (LkAppModel *self, gboolean done);
/* An open is in flight. `preparing_symbols` marks the first-ever run baking the
 * symbol/font atlases, which warrants a distinct (and slower) message. */
void lk_app_model_set_opening (LkAppModel *self, gboolean opening, gboolean preparing_symbols);
gboolean lk_app_model_get_show_startup_loader (LkAppModel *self);
gboolean lk_app_model_get_preparing_symbols (LkAppModel *self);
gboolean lk_app_model_get_opening (LkAppModel *self);
/* How many charts that open covers, when known; 0 otherwise. The loader page
 * says "Opening 7,217 charts" from it. */
void  lk_app_model_set_opening_cells (LkAppModel *self, guint cells);
guint lk_app_model_get_opening_cells (LkAppModel *self);
void lk_app_model_set_chart_open (LkAppModel *self, gboolean open, const char *path);
void lk_app_model_set_open_error (LkAppModel *self, const char *message);

/* The pick from the last tap, and where on the chart it landed (logical points
 * in the chart view — the report stands beside the mark there). Transfer full;
 * emits ::pick-results, which is what rebuilds the report. */
void       lk_app_model_set_pick (LkAppModel *self, GPtrArray *results, double x, double y,
                                  double lon, double lat);
/* The water the open pick describes; FALSE when no pick is open. */
gboolean   lk_app_model_get_pick_geo (LkAppModel *self, double *out_lon, double *out_lat);
/* Re-place the open pick's mark. Emits "pick-moved" (the mark alone; the
 * report's frame never moves) and only when it moved at least half a point. */
void       lk_app_model_move_pick (LkAppModel *self, double x, double y);
void       lk_app_model_clear_pick (LkAppModel *self);
GPtrArray *lk_app_model_get_pick_results (LkAppModel *self);
gboolean   lk_app_model_get_pick_point (LkAppModel *self, double *out_x, double *out_y);

/* ---- the plugin overlay -------------------------------------------------- */

/* The overlay object the mariner clicked, by id, or NULL while none is pinned.
 * A click that lands on a plugin's symbol pins it and does NOT open the chart
 * pick report: one thing under the finger at a time. */
void        lk_app_model_pin_overlay (LkAppModel *self, const char *id);
const char *lk_app_model_get_overlay_pin (LkAppModel *self);

/* Which object of the pick the report is showing. */
guint lk_app_model_get_pick_index (LkAppModel *self);
void  lk_app_model_set_pick_index (LkAppModel *self, guint index);

/* ---- accessors the chrome reads ----------------------------------------- */

gboolean lk_app_model_get_has_chart (LkAppModel *self);
const char *lk_app_model_get_chart_path (LkAppModel *self);
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
