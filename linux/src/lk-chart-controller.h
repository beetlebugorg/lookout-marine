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

/* ---- raster underlay ---------------------------------------------------- */

/* One set the engine reports: the charts of one provider, drawn as one
 * picture. `in_view` says whether it has enabled charts under this view, which
 * is what the pill and its list are built from. `shown` is the set's own state
 * rather than "drawn over this view": that is what gets saved, and a coast off
 * screen still has an answer. */
typedef struct {
  int      id;
  char    *name;
  gboolean in_view;
  gboolean shown;
} LkRasterSet;

void lk_raster_set_free (LkRasterSet *set);

/* Open one raster chart into the live handle. FALSE when the file will not
 * open: a bad chart never takes the app down. */
gboolean lk_chart_controller_raster_add (LkChartController *self, const char *path);

/* Step to the next set covering the water in view, then to no picture. The
 * camera does not move, so a mariner comparing two providers over a reef keeps
 * their fix. */
void lk_chart_controller_raster_cycle (LkChartController *self);

/* Draw set `index`, or none for -1. Off is off for the water in view only: the
 * sets covering other coasts stay as the mariner left them. */
void lk_chart_controller_raster_select (LkChartController *self, int index);

/* Draw set `index`, or stop drawing it, WITHOUT reference to the camera. Select
 * cannot do this: it answers for the view on screen, and the view a launch
 * opens into is often nowhere near the set being put back. Showing still turns
 * off the sets covering the same water, so the election holds. */
void lk_chart_controller_raster_set_shown (LkChartController *self, int index, gboolean shown);

/* Turn one installed chart on or off. It stays installed either way. */
gboolean lk_chart_controller_raster_set_enabled (LkChartController *self,
                                                 const char        *path,
                                                 gboolean           enabled);

/* Every set, with whether it covers this view. Transfer full: a GPtrArray of
 * LkRasterSet. */
GPtrArray *lk_chart_controller_raster_sets (LkChartController *self);

int      lk_chart_controller_raster_active_index (LkChartController *self);
/* The set drawn over this view, or "". Transfer full. */
char    *lk_chart_controller_raster_active_name (LkChartController *self);
/* A set covering this view, DRAWN OR NOT, or "". It is what tells a mariner
 * sailing into coverage that a picture is here while it is switched off.
 * Transfer full. */
char    *lk_chart_controller_raster_available_name (LkChartController *self);
/* TRUE while the chart draws without its opaque fills, because a picture is
 * beneath THIS view. */
gboolean lk_chart_controller_raster_over_chart (LkChartController *self);

/* Hide the vector chart where a picture covers it, and show it again. */
void     lk_chart_controller_toggle_chart (LkChartController *self);
void     lk_chart_controller_set_chart_hidden (LkChartController *self, gboolean hidden);
gboolean lk_chart_controller_chart_hidden (LkChartController *self);

/* ---- wasm plugins -------------------------------------------------------- */

/* TRUE while a plugin layer is running. Own ship, AIS, NMEA 0183, Signal K and
 * laylines all come from plugins, so without one the chart has no boat and no
 * traffic. */
gboolean lk_chart_controller_plugins_active (LkChartController *self);

/* Every loaded plugin with its settings schema and the values in force, as the
 * JSON lookout_plugins_json documents. NULL when no plugin layer is up, which
 * is NOT the same as a layer holding no plugins (that answers
 * {"plugins":[]}) — a caller with a registry already on screen must keep it
 * rather than empty the window. Transfer full. */
char *lk_chart_controller_plugins_json (LkChartController *self);

/* Push one plugin's settings, applied live. `json` is an object of the keys its
 * schema declares. TRUE when the plugin took them. */
gboolean lk_chart_controller_set_plugin_config (LkChartController *self,
                                                const char        *id,
                                                const char        *json);

/* Plugin alerts, as the JSON lookout_plugin_alerts_json documents. NULL when
 * the read failed, which is NOT "no alerts": a caller clears its strip and
 * silences its siren, then keeps watching. Transfer full. */
char *lk_chart_controller_alerts_json (LkChartController *self);

/* Acknowledge one alert. It stops sounding and stays listed until the condition
 * clears. It silences THAT alert only. */
gboolean lk_chart_controller_alert_ack (LkChartController *self, guint64 id);

/* The tables the plugins declare, and one table's rows already in order, as the
 * JSON lookout_plugin_tables_json and lookout_plugin_table_rows document.
 * `sort_key` NULL takes the declared sort. Transfer full. */
char *lk_chart_controller_tables_json (LkChartController *self);
char *lk_chart_controller_table_rows (LkChartController *self,
                                      const char        *plugin,
                                      const char        *key,
                                      const char        *sort_key,
                                      gboolean           ascending);

/* Tell the plugin its table is on screen, or is not. A plugin builds rows only
 * while a table is open, so a dialog nobody opened costs nothing. Call it with
 * TRUE when the dialog opens and FALSE when it closes. */
void lk_chart_controller_table_open (LkChartController *self,
                                     const char        *plugin,
                                     const char        *key,
                                     gboolean           open);

/* ---- installing a plugin ------------------------------------------------- */

/* Read a .lkplug without installing it: everything the consent sheet shows, as
 * the JSON lookout_plugin_inspect documents. A refused package answers
 * {"error":"…"}, which is a sentence ready to show. Transfer full. */
char *lk_chart_controller_plugin_inspect (LkChartController *self, const char *path);

/* Install a package the mariner consented to. It loads hot, so the plugin draws
 * without a restart. NULL on SUCCESS; otherwise one sentence saying why not,
 * transfer full. */
char *lk_chart_controller_plugin_install (LkChartController *self, const char *path);

/* Remove an installed plugin and everything it owns. FALSE for an unknown id,
 * or for a bundled or developer copy, which install never wrote. */
gboolean lk_chart_controller_plugin_uninstall (LkChartController *self, const char *id);

/* Switch one granted capability on or off while the plugin runs. The broker
 * answers the plugin -1 for a revoked capability and the plugin keeps running.
 * FALSE for a capability the manifest never asked for. */
gboolean lk_chart_controller_plugin_grant_set (LkChartController *self,
                                               const char        *id,
                                               const char        *cap,
                                               gboolean           on);

/* Offer a file to the plugins before the shell treats it as a chart. 1 when a
 * plugin took it, 0 when none claims the type, -1 when one claims it and the
 * file could not be given over. A chart always answers 0, so one code path
 * serves both. */
int lk_chart_controller_open_file (LkChartController *self, const char *path);

/* ---- own ship, follow and course up -------------------------------------- */

/* Own ship's REPORTED position, and how much to believe it. *out_lon and
 * *out_lat are written only for LK_FIX_LIVE. A readout shows these numbers or
 * it shows none: it never falls back to the view centre. */
typedef enum {
  LK_FIX_NONE = 0, /* no source of position at all */
  LK_FIX_LOST = 1, /* a source exists, its fix aged out */
  LK_FIX_LIVE = 2, /* a fix inside its freshness window */
} LkFixState;

LkFixState lk_chart_controller_own_ship (LkChartController *self,
                                         double            *out_lon,
                                         double            *out_lat);

/* Follow mode and course up: 0 off, 1 working, 2 on and waiting for a fix.
 *
 * THE CORE TURNS THESE OFF ITSELF. A pan hands the chart back to the mariner
 * and cancels follow; a rotate by hand cancels course up. A control that
 * tracked only its own clicks would go wrong, so the chrome polls the active
 * state with the other readouts. */
void lk_chart_controller_follow_set (LkChartController *self, gboolean on);
int  lk_chart_controller_follow_active (LkChartController *self);
void lk_chart_controller_course_up_set (LkChartController *self, gboolean on);
int  lk_chart_controller_course_up_active (LkChartController *self);

/* ---- the plugin overlay -------------------------------------------------- */

/* One object a plugin drew: a vessel, a layline end, anything it gave a
 * payload. `info` is the pick payload JSON, or NULL when it carries none.
 * `lon` and `lat` are where the object draws NOW. */
typedef struct {
  char  *id;
  char  *info;
  double lon, lat;
} LkOverlayObject;

void lk_overlay_object_free (LkOverlayObject *object);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (LkOverlayObject, lk_overlay_object_free)

/* The overlay symbol nearest a logical point, or NULL when none is within about
 * 14 pt. A click that hits one must NOT also open the chart pick report.
 * Transfer full. */
LkOverlayObject *lk_chart_controller_overlay_hit (LkChartController *self,
                                                  double             x,
                                                  double             y);

/* What that object says now, or NULL once it is gone: the target aged out, or
 * its plugin stopped. A pinned bubble re-reads this every tick to move itself
 * and refresh its values, and closes itself on NULL. Transfer full. */
LkOverlayObject *lk_chart_controller_overlay_info (LkChartController *self,
                                                   const char        *id);

/* Where a geographic point falls on the screen, in logical points. It is the
 * inverse of lk_chart_controller_geo_at, and it is what pins a bubble to an
 * object as the chart moves under it. */
gboolean lk_chart_controller_screen_of (LkChartController *self,
                                        double lon, double lat,
                                        double *out_x, double *out_y);

/* ---- the mariner's own marks --------------------------------------------- */

/* A mark on the water: a rock somebody reported, a crab pot, an anchorage to
 * come back to. The CORE owns them. It draws them, names them, writes them
 * under the per-user directory, and reads them back at every open, so they
 * survive a restart and a change of chart library. This shell stores nothing.
 *
 * `name` is owned by the struct. */
typedef struct {
  guint64 id;
  double  lon, lat;
  char   *name;
} LkMarker;

void lk_marker_free (LkMarker *marker);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (LkMarker, lk_marker_free)

/* Drop a mark at a geographic point. It is placed AND named in one call, so a
 * mariner on a moving boat never waits to type. 0 when nothing was stored. */
guint64 lk_chart_controller_marker_add (LkChartController *self, double lon, double lat);

/* The mark nearest a logical point, or NULL when none is within about 14 pt.
 * This is what decides whether the chart menu offers Drop, or Rename and
 * Remove. Transfer full. */
LkMarker *lk_chart_controller_marker_at (LkChartController *self, double x, double y);

/* Rename one mark, up to 32 characters. An EMPTY name keeps the old one: a
 * field the mariner cleared and left is not a request for a nameless mark. */
gboolean lk_chart_controller_marker_rename (LkChartController *self,
                                            guint64            id,
                                            const char        *name);
gboolean lk_chart_controller_marker_remove (LkChartController *self, guint64 id);

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
