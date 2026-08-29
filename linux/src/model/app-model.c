#include "model/app-model.h"

#include "library/scan.h"
#include "library/sets.h"
#include "model/coord.h"
#include "model/store.h"

#include <math.h>
#include <string.h>

struct _LkAppModel {
  GObject parent_instance;

  LkChartController *controller;
  LkChartLinks      *chart_links;

  gboolean has_chart;
  char    *chart_path;
  char    *open_error;
  /* True while a scan worker is out. One at a time: the engine's two scan
     entry points share one non-reentrant buffer. */
  gboolean scanning;
  /* The set being prepared, and where it has got to. */
  LkChartBake   *bake;
  char          *pending_open_source;
  LkBakeProgress bake_progress;
  gboolean       baking;
  GStrv    recents;

  gboolean is_opening;
  gboolean preparing_symbols;
  gboolean first_build_done;
  guint    opening_cells; /* how many charts the open in flight covers, when known */

  double   center_lon, center_lat;
  double   zoom;
  double   rotation_deg;
  double   overscale;
  double   scale_denominator;
  int      scheme;
  gboolean building;

  int view_width, view_height; /* the chart view, in logical points */

  /* What the engine says follow and course up are doing, and what own ship's
   * position readout may say. The core turns both modes off itself, so these
   * are READ off it with the other readouts and never tracked from a click. */
  int      follow;    /* 0 off, 1 following, 2 waiting for a fix */
  int      course_up; /* 0 off, 1 turning, 2 waiting for a heading */
  int      fix_state;
  double   fix_lon, fix_lat;

  /* The chart library: the sets aboard, which are switched off, and what the
   * background metadata scans have learned about each. */
  LkChartSets *chart_sets; /* the library: what is aboard, and what is on */

  /* The raster charts the mariner installed, and the state the engine reports
   * for them over the water in view. */
  LkRasterCharts *raster_charts;
  GPtrArray      *raster_sets; /* LkRasterSet* */
  int             raster_active;
  char           *raster_available;
  gboolean        raster_over_chart;
  gboolean        chart_hidden;

  /* The overlay object the mariner pinned, by id. NULL while none is. */
  char *overlay_pin;

  GPtrArray *pick_results;
  gboolean   pick_valid;
  double     pick_x, pick_y; /* logical points in the chart view */
  /* The water the pick describes. The mark rides this under follow — the
     core moves the camera without the shell — while the report's frame stays
     where it opened. */
  double     pick_lon, pick_lat;
  gboolean   pick_has_geo;
  guint      pick_index;
};

enum {
  PROP_0,
  PROP_HAS_CHART,
  PROP_CHART_PATH,
  PROP_OPEN_ERROR,
  PROP_SHOW_STARTUP_LOADER,
  PROP_CENTER_LON,
  PROP_CENTER_LAT,
  PROP_ZOOM,
  PROP_ROTATION,
  PROP_OVERSCALE,
  PROP_SCALE_DENOMINATOR,
  PROP_SCHEME,
  PROP_BUILDING,
  PROP_BAKING,
  PROP_VIEW_WIDTH,
  PROP_VIEW_HEIGHT,
  PROP_FOLLOW,
  PROP_COURSE_UP,
  PROP_FIX_STATE,
  PROP_FIX_LON,
  PROP_FIX_LAT,
  PROP_OVERLAY_PIN,
  N_PROPS
};

enum {
  SIGNAL_PICK_RESULTS,
  SIGNAL_PICK_MOVED,
  SIGNAL_RASTER_CHANGED,
  SIGNAL_CHART_SETS_CHANGED,
  SIGNAL_PLUGINS_CHANGED,
  SIGNAL_CHROME_RETIRED,
  N_SIGNALS
};

static GParamSpec *properties[N_PROPS];
static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE (LkAppModel, lk_app_model, G_TYPE_OBJECT)

/* ---- GObject ------------------------------------------------------------ */

static void
lk_app_model_get_property (GObject *object, guint prop_id, GValue *value, GParamSpec *pspec)
{
  LkAppModel *self = LK_APP_MODEL (object);

  switch (prop_id)
    {
    case PROP_HAS_CHART:           g_value_set_boolean (value, self->has_chart); break;
    case PROP_CHART_PATH:          g_value_set_string (value, self->chart_path); break;
    case PROP_OPEN_ERROR:          g_value_set_string (value, self->open_error); break;
    case PROP_SHOW_STARTUP_LOADER: g_value_set_boolean (value, lk_app_model_get_show_startup_loader (self)); break;
    case PROP_CENTER_LON:          g_value_set_double (value, self->center_lon); break;
    case PROP_CENTER_LAT:          g_value_set_double (value, self->center_lat); break;
    case PROP_ZOOM:                g_value_set_double (value, self->zoom); break;
    case PROP_ROTATION:            g_value_set_double (value, self->rotation_deg); break;
    case PROP_OVERSCALE:           g_value_set_double (value, self->overscale); break;
    case PROP_SCALE_DENOMINATOR:   g_value_set_double (value, self->scale_denominator); break;
    case PROP_SCHEME:              g_value_set_int (value, self->scheme); break;
    case PROP_BUILDING:            g_value_set_boolean (value, self->building); break;
    case PROP_BAKING:              g_value_set_boolean (value, self->baking); break;
    case PROP_VIEW_WIDTH:          g_value_set_int (value, self->view_width); break;
    case PROP_VIEW_HEIGHT:         g_value_set_int (value, self->view_height); break;
    case PROP_FOLLOW:              g_value_set_int (value, self->follow); break;
    case PROP_COURSE_UP:           g_value_set_int (value, self->course_up); break;
    case PROP_FIX_STATE:           g_value_set_int (value, self->fix_state); break;
    case PROP_FIX_LON:             g_value_set_double (value, self->fix_lon); break;
    case PROP_FIX_LAT:             g_value_set_double (value, self->fix_lat); break;
    case PROP_OVERLAY_PIN:         g_value_set_string (value, self->overlay_pin); break;
    default: G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    }
}

static void
lk_app_model_dispose (GObject *object)
{
  LkAppModel *self = LK_APP_MODEL (object);

  /* A bake still running holds this model as its callback data; its idles
     must not fire into a freed object. Blocks up to about one chart. */
  g_clear_pointer (&self->bake, lk_chart_bake_destroy);
  /* Break the links → controller chain first. An in-flight fetch holds the
   * links object, which holds the controller; without this the controller
   * would outlive its dispose and skip lookout_close and the final pose save.
   * This also detaches the tile provider from the handle. */
  if (self->chart_links != NULL)
    lk_chart_links_shutdown (self->chart_links);
  g_clear_object (&self->chart_links);
  g_clear_object (&self->controller);
  g_clear_pointer (&self->chart_path, g_free);
  g_clear_pointer (&self->open_error, g_free);
  g_clear_pointer (&self->pending_open_source, g_free);
  g_clear_pointer (&self->bake_progress.name, g_free);
  g_clear_pointer (&self->bake_progress.cell, g_free);
  g_clear_pointer (&self->recents, g_strfreev);
  g_clear_pointer (&self->overlay_pin, g_free);
  g_clear_pointer (&self->pick_results, g_ptr_array_unref);
  g_clear_pointer (&self->chart_sets, lk_chart_sets_free);
  g_clear_pointer (&self->raster_sets, g_ptr_array_unref);
  g_clear_pointer (&self->raster_available, g_free);
  g_clear_pointer (&self->raster_charts, lk_raster_charts_free);

  G_OBJECT_CLASS (lk_app_model_parent_class)->dispose (object);
}

static void
lk_app_model_class_init (LkAppModelClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  /* Every property is read-only, so there is no set_property. */
  object_class->get_property = lk_app_model_get_property;
  object_class->dispose = lk_app_model_dispose;

#define RO  (G_PARAM_READABLE | G_PARAM_STATIC_STRINGS)

  properties[PROP_HAS_CHART] = g_param_spec_boolean ("has-chart", NULL, NULL, FALSE, RO);
  properties[PROP_CHART_PATH] = g_param_spec_string ("chart-path", NULL, NULL, NULL, RO);
  properties[PROP_OPEN_ERROR] = g_param_spec_string ("open-error", NULL, NULL, NULL, RO);
  properties[PROP_SHOW_STARTUP_LOADER] = g_param_spec_boolean ("show-startup-loader", NULL, NULL, FALSE, RO);
  properties[PROP_CENTER_LON] = g_param_spec_double ("center-lon", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_CENTER_LAT] = g_param_spec_double ("center-lat", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_ZOOM] = g_param_spec_double ("zoom", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_ROTATION] = g_param_spec_double ("rotation", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_OVERSCALE] = g_param_spec_double ("overscale", NULL, NULL, 0, G_MAXDOUBLE, 1.0, RO);
  properties[PROP_SCALE_DENOMINATOR] = g_param_spec_double ("scale-denominator", NULL, NULL, 0, G_MAXDOUBLE, 0, RO);
  properties[PROP_SCHEME] = g_param_spec_int ("scheme", NULL, NULL, 0, 2, 0, RO);
  properties[PROP_BUILDING] = g_param_spec_boolean ("building", NULL, NULL, FALSE, RO);
  properties[PROP_BAKING] = g_param_spec_boolean ("baking", NULL, NULL, FALSE, RO);
  properties[PROP_VIEW_WIDTH] = g_param_spec_int ("view-width", NULL, NULL, 0, G_MAXINT, 0, RO);
  properties[PROP_VIEW_HEIGHT] = g_param_spec_int ("view-height", NULL, NULL, 0, G_MAXINT, 0, RO);
  properties[PROP_FOLLOW] = g_param_spec_int ("follow", NULL, NULL, 0, 2, 0, RO);
  properties[PROP_COURSE_UP] = g_param_spec_int ("course-up", NULL, NULL, 0, 2, 0, RO);
  properties[PROP_FIX_STATE] = g_param_spec_int ("fix-state", NULL, NULL, 0, 2, 0, RO);
  properties[PROP_FIX_LON] = g_param_spec_double ("fix-lon", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_FIX_LAT] = g_param_spec_double ("fix-lat", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_OVERLAY_PIN] = g_param_spec_string ("overlay-pin", NULL, NULL, NULL, RO);

#undef RO

  g_object_class_install_properties (object_class, N_PROPS, properties);

  /* Carries nothing; the panel reads results back via lk_app_model_get_pick_results. */
  signals[SIGNAL_PICK_RESULTS] =
      g_signal_new ("pick-results", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);

  /* The open pick's mark was re-projected: only the mark moves, so this is a
     separate, lighter signal than pick-results, which rebuilds the report. */
  signals[SIGNAL_PICK_MOVED] =
      g_signal_new ("pick-moved", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);

  /* The installed list, the sets in view, the drawn one, or the ENC switch
   * moved. One signal, not a property each: the pill reads all of them
   * together, and it is rebuilt as a whole. */
  signals[SIGNAL_RASTER_CHANGED] =
      g_signal_new ("raster-changed", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);

  /* The library moved: a set added, removed, switched, or a background scan
   * filled a title in. One signal; the list is rebuilt as a whole. */
  signals[SIGNAL_CHART_SETS_CHANGED] =
      g_signal_new ("chart-sets-changed", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);

  /* The plugin layer changed: a load after an open, a hot install, or an
     uninstall. The alert watch follows this to arm and disarm its poll. */
  signals[SIGNAL_PLUGINS_CHANGED] =
      g_signal_new ("plugins-changed", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);

  /* A camera move retired the chrome. The report follows the pick, which
     clears with it; the chart view follows this to close its menu as well. */
  signals[SIGNAL_CHROME_RETIRED] =
      g_signal_new ("chrome-retired", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

static void
lk_app_model_emit_chart_sets_changed (LkAppModel *self)
{
  g_signal_emit (self, signals[SIGNAL_CHART_SETS_CHANGED], 0);
}

/* A background scan landed. Nothing reopened, so this only tells the windows
 * to read the list again. */
static void
lk_app_model_sets_changed (gpointer user_data)
{
  lk_app_model_emit_chart_sets_changed (user_data);
}

/* Reopen the chart from the current library. If every set is off, close
 * the chart: an empty view that says so is better than a chart quietly
 * showing material that was switched off. */
static void
lk_app_model_recompose_library (LkAppModel *self)
{
  g_auto (GStrv) all = lk_chart_sets_compose (self->chart_sets);

  if (all != NULL && all[0] != NULL)
    lk_chart_controller_reopen (self->controller, (const char *const *) all);
  else
    {
      lk_chart_controller_close (self->controller);
      /* The readouts stop with the render loop, so the raster snapshot has
       * to be read back here — without this the pill keeps naming a set of
       * the chart that just closed. */
      lk_app_model_refresh_raster_state (self);
    }
}

static void
lk_app_model_init (LkAppModel *self)
{
  self->controller = lk_chart_controller_new ();
  lk_chart_controller_set_model (self->controller, self);
  self->chart_links = lk_chart_links_new (self->controller);

  self->recents = lk_store_load_recents ();

  /* The library. A background scan fills in each set's title and size, and
   * says so through this callback. */
  self->chart_sets = lk_chart_sets_new (lk_app_model_sets_changed, self);
  self->overscale = 1.0;
  self->pick_results = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_pick_feature_free);

  self->raster_charts = lk_raster_charts_new ();
  self->raster_sets = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_raster_set_free);
  self->raster_active = -1;
  self->raster_available = g_strdup ("");
}

LkAppModel *
lk_app_model_new (void)
{
  return g_object_new (LK_TYPE_APP_MODEL, NULL);
}

LkChartController *
lk_app_model_get_controller (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);
  return self->controller;
}

LkChartLinks *
lk_app_model_get_chart_links (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);
  return self->chart_links;
}

void
lk_app_model_reapply_chart_link (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  lk_chart_links_reapply (self->chart_links);
}

void
lk_app_model_poll_chart_links (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  lk_chart_links_poll (self->chart_links);
}

/* ---- opening charts ----------------------------------------------------- */

static void lk_app_model_open_prepared (LkAppModel *self, const char *source);

/* ---- the library's public face ------------------------------------------- */

GPtrArray *
lk_app_model_get_chart_sets (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self),
                        g_ptr_array_new_with_free_func ((GDestroyNotify) lk_chart_set_row_free));

  return lk_chart_sets_rows (self->chart_sets);
}

void
lk_app_model_set_chart_set_on (LkAppModel *self, const char *path, gboolean on)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  g_return_if_fail (path != NULL);

  if (!lk_chart_sets_set_on (self->chart_sets, path, on))
    return;

  lk_app_model_recompose_library (self);
  lk_app_model_emit_chart_sets_changed (self);
}

void
lk_app_model_remove_chart_set (LkAppModel *self, const char *path)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  g_return_if_fail (path != NULL);

  if (!lk_chart_sets_remove (self->chart_sets, path))
    return;

  lk_app_model_recompose_library (self);
  lk_app_model_emit_chart_sets_changed (self);
}

/* The path the app would open on its own: what the mariner last had, or what
 * the environment points at. Returned whether or not anything in it can be
 * drawn yet, because a folder of raw cells is a perfectly good answer that
 * happens to need baking first. Free with g_free. */
char *
lk_app_model_initial_source (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);

  const char *env = g_getenv ("LOOKOUT_OPEN");
  if (env != NULL)
    return g_strdup (env);
  return NULL;
}

char **
lk_app_model_initial_chart_paths (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), g_new0 (char *, 1));

  const char *env = g_getenv ("LOOKOUT_OPEN");
  if (env != NULL)
    {
      char **cells = lk_chart_cell_paths_for (env);
      if (g_strv_length (cells) > 0)
        return cells;
      g_strfreev (cells);
    }

  /* The library: every set switched on, as one chart. */
  const char *const *aboard = lk_chart_sets_paths (self->chart_sets);
  if (aboard != NULL && aboard[0] != NULL)
    {
      char **cells = lk_chart_sets_compose (self->chart_sets);
      if (g_strv_length (cells) > 0)
        return cells;
      g_strfreev (cells);
    }

  /* The Zig demo's built-in default, if present. */
  g_autofree char *demo = g_build_filename (g_get_home_dir (), ".cache", "chartplotter",
                                            "NOAA", "tiles", "d5", "US5MD1MC.pmtiles", NULL);
  if (g_file_test (demo, G_FILE_TEST_EXISTS))
    {
      char **one = g_new0 (char *, 2);
      one[0] = g_steal_pointer (&demo);
      return one;
    }

  return g_new0 (char *, 1);
}

static void
lk_app_model_request_open (LkAppModel *self, char **paths)
{
  if (paths == NULL || g_strv_length (paths) == 0)
    return;

  lk_chart_controller_reopen (self->controller, (const char *const *) paths);
}

void
lk_app_model_open_chart (LkAppModel *self, const char *path)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (path == NULL || !g_file_test (path, G_FILE_TEST_EXISTS))
    return;

  if (g_file_test (path, G_FILE_TEST_IS_DIR))
    {
      lk_app_model_open_chart_directory (self, path);
      return;
    }

  /* THE PLUGINS GET FIRST REFUSAL. A manifest claims file types, and a weather
   * file the mariner opened belongs to the plugin that reads them. A CHART
   * always answers 0, whatever a manifest claims, and so does a build with no
   * plugin layer, so one code path serves both. */
  if (lk_chart_controller_open_file (self->controller, path) != 0)
    return;

  /* An exchange set as an agency publishes it is one .zip. It is a chart set
     the same as a folder is, so it takes the same road: scanned, baked, and
     opened. Nothing is unpacked on the way. */
  if (lk_chart_scan_is_archive (path))
    {
      lk_app_model_open_chart_directory (self, path);
      return;
    }

  /* A single cell is a set of one. It joins the library like a folder does,
   * so it survives a restart and composes with what is already aboard. */
  lk_app_model_open_prepared (self, path);
}

/* Open the LIBRARY with `source` aboard: the source goes on the set list,
 * switched on, and the chart opens as the union of every set switched on —
 * what is ready in each folder, plus anything a bake put in its prepared
 * directory. A second folder composes with the first instead of replacing
 * it. */
static void
lk_app_model_open_prepared (LkAppModel *self, const char *source)
{
  if (lk_chart_sets_note (self->chart_sets, source))
    lk_app_model_emit_chart_sets_changed (self);

  g_auto (GStrv) all = lk_chart_sets_compose (self->chart_sets);
  if (all == NULL || all[0] == NULL)
    {
      lk_app_model_set_open_error (self, "That folder contains no charts this app can draw.");
      return;
    }

  lk_app_model_request_open (self, all);
}

static void
lk_app_model_bake_progress (const LkBakeProgress *progress, gpointer user_data)
{
  LkAppModel *self = user_data;

  g_free (self->bake_progress.name);
  g_free (self->bake_progress.cell);
  self->bake_progress = *progress;
  self->bake_progress.name = g_strdup (progress->name);
  self->bake_progress.cell = g_strdup (progress->cell);
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_BAKING]);
}

static void
lk_app_model_bake_done (const char *out_dir, guint baked, gpointer user_data)
{
  LkAppModel *self = user_data;

  /* The job leaked here for its whole life once: path arrays, labels, a
     mutex and the thread handle, per import. Destroy joins the worker (it
     has just returned) and frees the lot. */
  g_clear_pointer (&self->bake, lk_chart_bake_destroy);
  self->baking = FALSE;
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_BAKING]);

  if (out_dir == NULL && baked == 0)
    {
      /* A failed bake opens nothing; a stale source here would confuse the
       * next bake's open. */
      g_clear_pointer (&self->pending_open_source, g_free);
      lk_app_model_set_open_error (self, "Those charts could not be prepared.");
      return;
    }

  /* THE CHART OPENS ONCE, AT THE END. Handing each batch over as it finished
     put a chart on screen sooner and cost about half the machine: every batch
     rebuilt the ownership partition over a growing library and re-tessellated,
     against a bake that only gets half the cores to begin with. */
  if (self->pending_open_source != NULL)
    {
      g_autofree char *src = g_steal_pointer (&self->pending_open_source);
      lk_app_model_open_prepared (self, src);
    }
}

typedef struct {
  LkAppModel *model; /* strong ref, dropped on the main loop */
  char       *dir;
  LkChartSet *set;
} LkScanJob;

static gboolean
lk_scan_done_idle (gpointer data)
{
  LkScanJob *job = data;
  LkAppModel *self = job->model;
  g_autoptr (LkChartSet) set = g_steal_pointer (&job->set);
  const char *dir = job->dir;

  self->scanning = FALSE;

  /* Counted from the cells, not set->sources: that counter is the vector
     sources alone. A folder of BSB/KAP sheets, or an archive whose charts
     are already baked, still has to prepare before anything can draw. */
  guint to_prepare = 0;
  if (set != NULL)
    for (guint i = 0; i < set->cells->len; i++)
      if (lk_scanned_cell_needs_prepare (g_ptr_array_index (set->cells, i)))
        to_prepare++;

  if (set != NULL && to_prepare > 0)
    {
      /* One bake at a time — the engine's import is not reentrant. A set
       * that needs preparing while another is importing is refused with the
       * reason, never quietly added as an empty set nothing will fill. */
      if (self->baking)
        {
          g_autofree char *name = g_path_get_basename (dir);
          g_autofree char *message =
              g_strdup_printf ("Still working on %s. Wait for it to finish.",
                               self->bake_progress.name != NULL
                                   ? self->bake_progress.name : name);
          lk_app_model_set_open_error (self, message);
          goto out;
        }

      g_free (self->pending_open_source);
      self->pending_open_source = g_strdup (dir);

      self->bake = lk_chart_bake_start (dir, set,
                                        lk_app_model_bake_progress,
                                        lk_app_model_bake_done, self);
      if (self->bake != NULL)
        {
          self->baking = TRUE;
          lk_app_model_set_open_error (self, NULL);
          g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_BAKING]);
          goto out;
        }
      g_clear_pointer (&self->pending_open_source, g_free);
    }

  lk_app_model_open_prepared (self, dir);

out:
  g_object_unref (job->model);
  g_free (job->dir);
  g_free (job);
  return G_SOURCE_REMOVE;
}

static gpointer
lk_scan_worker (gpointer data)
{
  LkScanJob *job = data;
  job->set = lk_chart_scan (job->dir);
  g_idle_add (lk_scan_done_idle, job);
  return NULL;
}

void
lk_app_model_open_chart_directory (LkAppModel *self, const char *dir)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  /* Ask the engine what is actually there before offering it — off the main
     loop, because a folder scan opens every archive it finds and the whole
     UI stood still for it. One scan at a time: the engine's two scan entry
     points share one non-reentrant buffer. */
  if (self->scanning)
    {
      lk_app_model_set_open_error (self,
          "Still looking through the last pick. Try again in a moment.");
      return;
    }
  /* One import at a time, and the refusal says so — as the reference does.
   * A quiet fall-through here left the folder in the library as an empty
   * set that nothing would ever prepare. */
  if (self->baking)
    {
      g_autofree char *message =
          g_strdup_printf ("Still working on %s. Wait for it to finish.",
                           self->bake_progress.name != NULL
                               ? self->bake_progress.name : "the last import");
      lk_app_model_set_open_error (self, message);
      return;
    }

  self->scanning = TRUE;
  LkScanJob *job = g_new0 (LkScanJob, 1);
  job->model = g_object_ref (self);
  job->dir = g_strdup (dir);
  g_thread_unref (g_thread_new ("lk-scan", lk_scan_worker, job));
}

/* ---- commands ----------------------------------------------------------- */

void
lk_app_model_zoom_in (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  lk_chart_controller_zoom_centered (self->controller, 1.0);
}

void
lk_app_model_zoom_out (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  lk_chart_controller_zoom_centered (self->controller, -1.0);
}

void
lk_app_model_zoom_to_fit (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  lk_chart_controller_fit_chart (self->controller);
}

void
lk_app_model_north_up (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  lk_chart_controller_reset_rotation (self->controller);
}

/* Zoom to a 1:N scale. At one latitude the denominator is C·cos(lat)/2^zoom,
 * so a wanted scale is a zoom delta: the engine's own zoom does the work and
 * keeps its limits and its easing. It agrees with zoomDeltaForScale (Android)
 * and AppModel.zoomToScale (macOS, iOS). */
void
lk_app_model_zoom_to_scale (LkAppModel *self, double denominator)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (denominator <= 0 || self->scale_denominator <= 0)
    return;

  lk_chart_controller_zoom_centered (self->controller,
                                     log2 (self->scale_denominator / denominator));
}

/* A menu scheme change must persist just like one from the settings form.
 * Both guard on an open chart, as the reference does: with no handle there is
 * nothing to cycle, and nothing read back may be saved. */
void
lk_app_model_cycle_scheme (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (!lk_chart_controller_is_open (self->controller))
    return;

  lk_chart_controller_cycle_scheme (self->controller);
  tile57_mariner mariner = lk_chart_controller_get_mariner (self->controller);
  lk_store_save_mariner (&mariner);
}

void
lk_app_model_set_scheme (LkAppModel *self, int scheme)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (!lk_chart_controller_is_open (self->controller))
    return;

  tile57_mariner mariner = lk_chart_controller_get_mariner (self->controller);
  mariner.scheme = (tile57_scheme) scheme;
  lk_chart_controller_set_mariner (self->controller, mariner);
  lk_store_save_mariner (&mariner);
}

void
lk_app_model_toggle_text (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  lk_chart_controller_toggle_text (self->controller);
}

void
lk_app_model_toggle_soundings (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  lk_chart_controller_toggle_soundings (self->controller);
}

void
lk_app_model_toggle_other_category (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  lk_chart_controller_toggle_other_category (self->controller);
}

/* ---- raster charts ------------------------------------------------------ */

static gboolean
lk_raster_sets_equal (GPtrArray *a, GPtrArray *b)
{
  if (a->len != b->len)
    return FALSE;

  for (guint i = 0; i < a->len; i++)
    {
      const LkRasterSet *one = g_ptr_array_index (a, i);
      const LkRasterSet *other = g_ptr_array_index (b, i);

      if (one->id != other->id || one->in_view != other->in_view ||
          one->shown != other->shown || g_strcmp0 (one->name, other->name) != 0)
        return FALSE;
    }

  return TRUE;
}

/* Write down which sets are drawn. Everything that can move the selection comes
 * through the sync below, so this is the one place it is saved: the pill's
 * menu, the Chart menu, the cycle key, and switching a chart off in the
 * settings, which can move the selection on its own.
 *
 * Read back from the engine rather than tracked here. The engine owns the
 * election — showing one set turns off the sets covering the same water — so
 * what it says after the change is the only account that can be right. */
static void
lk_app_model_save_raster_shown (LkAppModel *self)
{
  if (self->raster_sets->len == 0)
    return; /* no chart open, or no raster charts in it: nothing to say */

  g_autoptr (GPtrArray) shown = g_ptr_array_new ();
  g_autoptr (GPtrArray) hidden = g_ptr_array_new ();

  for (guint i = 0; i < self->raster_sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (self->raster_sets, i);
      g_ptr_array_add (set->shown ? shown : hidden, set->name);
    }

  g_ptr_array_add (shown, NULL);
  g_ptr_array_add (hidden, NULL);
  lk_raster_charts_note_shown (self->raster_charts,
                               (const char *const *) shown->pdata,
                               (const char *const *) hidden->pdata);
}

/* Read the engine's raster state into the model. TRUE when something moved —
 * the caller decides whether that alone warrants rebuilding the chrome. */
static gboolean
lk_app_model_sync_raster (LkAppModel *self)
{
  int active = lk_chart_controller_raster_active_index (self->controller);
  gboolean over = lk_chart_controller_raster_over_chart (self->controller);
  gboolean hidden = lk_chart_controller_chart_hidden (self->controller);
  g_autofree char *available = lk_chart_controller_raster_available_name (self->controller);
  g_autoptr (GPtrArray) sets = lk_chart_controller_raster_sets (self->controller);

  gboolean changed = active != self->raster_active ||
                     over != self->raster_over_chart ||
                     hidden != self->chart_hidden ||
                     g_strcmp0 (available, self->raster_available) != 0 ||
                     !lk_raster_sets_equal (sets, self->raster_sets);

  if (!changed)
    return FALSE;

  self->raster_active = active;
  self->raster_over_chart = over;
  self->chart_hidden = hidden;
  g_free (self->raster_available);
  self->raster_available = g_steal_pointer (&available);
  g_clear_pointer (&self->raster_sets, g_ptr_array_unref);
  self->raster_sets = g_ptr_array_ref (sets);
  lk_app_model_save_raster_shown (self);
  return TRUE;
}

void
lk_app_model_refresh_raster_state (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (lk_app_model_sync_raster (self))
    g_signal_emit (self, signals[SIGNAL_RASTER_CHANGED], 0);
}

/* The controller calls this after the plugin layer changes: a load on open, a
   hot install, or an uninstall. The alert watch arms or disarms on it. */
void
lk_app_model_notify_plugins_changed (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  g_signal_emit (self, signals[SIGNAL_PLUGINS_CHANGED], 0);
}

/* The controller calls this when a camera move retires the chrome. The chart
   view closes its menu on it, the way the report clears with the pick. */
void
lk_app_model_retire_chrome (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  g_signal_emit (self, signals[SIGNAL_CHROME_RETIRED], 0);
}

/* Put back which sets the mariner had drawn. Adding a source draws its set,
 * which is right for a chart just picked and wrong for one being re-installed
 * at launch, so every open has to correct it — after every source is in,
 * because switching one chart off can move which set is drawn, and before the
 * first frame, or a set the mariner switched off flashes on screen.
 *
 * Two passes. Hiding first and showing second is what keeps the election: where
 * two providers cover one coast, the sources were added in an order that drew
 * the first of them, so showing the mariner's pick before hiding its rival
 * would leave the rival to turn the pick straight back off. */
static void
lk_app_model_restore_raster_shown (LkAppModel *self)
{
  g_autoptr (GPtrArray) sets = lk_chart_controller_raster_sets (self->controller);

  for (guint i = 0; i < sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (sets, i);

      if (!lk_raster_charts_shown (self->raster_charts, set->name))
        lk_chart_controller_raster_set_shown (self->controller, set->id, FALSE);
    }

  for (guint i = 0; i < sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (sets, i);

      if (lk_raster_charts_shown (self->raster_charts, set->name))
        lk_chart_controller_raster_set_shown (self->controller, set->id, TRUE);
    }
}

void
lk_app_model_reinstall_raster_charts (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  const char *const *paths = lk_raster_charts_paths (self->raster_charts);
  guint installed = 0;

  for (guint i = 0; paths[i] != NULL; i++)
    {
      if (!lk_chart_controller_raster_add (self->controller, paths[i]))
        continue;

      installed++;
      if (!lk_raster_charts_enabled (self->raster_charts, paths[i]))
        lk_chart_controller_raster_set_enabled (self->controller, paths[i], FALSE);
    }

  if (lk_raster_charts_count (self->raster_charts) > 0)
    {
      lk_app_model_restore_raster_shown (self);
      g_message ("raster: %u/%u chart(s) re-installed", installed,
                 lk_raster_charts_count (self->raster_charts));
    }

  /* The ENC-over-picture state belongs to the mariner too, and it only does
   * anything where a picture covers, so it is safe to put back before knowing
   * whether one does. */
  if (lk_store_load_chart_hidden ())
    lk_chart_controller_set_chart_hidden (self->controller, TRUE);
}

/* Draw the set the last added file belongs to, when it covers this view. The
 * mariner picked these files while looking at this water, so showing them is
 * the obvious answer — and the pill takes it back in one click. */
static void
lk_app_model_draw_added_raster (LkAppModel *self, const char *path)
{
  g_autofree char *name = lk_raster_set_name_for (path);

  for (guint i = 0; i < self->raster_sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (self->raster_sets, i);

      if (set->in_view && g_strcmp0 (set->name, name) == 0)
        {
          lk_chart_controller_raster_select (self->controller, set->id);
          lk_app_model_sync_raster (self);
          return;
        }
    }
}

void
lk_app_model_add_raster_charts (LkAppModel *self, const char *const *paths)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (paths == NULL)
    return;

  /* With no chart open there is no engine to ask, so the files are taken on
   * trust and installed at the next open, which is where a bad one is caught. */
  gboolean open = lk_chart_controller_is_open (self->controller);
  g_autoptr (GPtrArray) failed = g_ptr_array_new_with_free_func (g_free);
  const char *last_added = NULL;

  for (guint i = 0; paths[i] != NULL; i++)
    {
      if (open && !lk_chart_controller_raster_add (self->controller, paths[i]))
        {
          g_ptr_array_add (failed, g_path_get_basename (paths[i]));
          continue;
        }

      if (lk_raster_charts_add (self->raster_charts, paths[i]))
        last_added = paths[i];
    }

  /* Read the whole state back rather than waiting for a frame: the chart sits
   * idle behind the picker, so without this a chart added over the water in
   * view appears to do nothing at all. */
  lk_app_model_sync_raster (self);
  if (last_added != NULL)
    lk_app_model_draw_added_raster (self, last_added);
  g_signal_emit (self, signals[SIGNAL_RASTER_CHANGED], 0);

  if (failed->len == 1)
    {
      g_autofree char *message =
          g_strdup_printf ("Couldn't open %s.\nIt may not be a raster chart tile57 reads.",
                           (const char *) g_ptr_array_index (failed, 0));
      lk_app_model_set_open_error (self, message);
    }
  else if (failed->len > 1)
    {
      g_ptr_array_add (failed, NULL);
      g_autofree char *list = g_strjoinv ("\n", (char **) failed->pdata);
      g_autofree char *message = g_strdup_printf ("Couldn't open %u files:\n%s",
                                                  failed->len - 1, list);
      lk_app_model_set_open_error (self, message);
    }
}

void
lk_app_model_forget_raster_charts (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  lk_raster_charts_clear (self->raster_charts);
  lk_app_model_sync_raster (self);
  g_signal_emit (self, signals[SIGNAL_RASTER_CHANGED], 0);
}

void
lk_app_model_remove_raster_chart (LkAppModel *self, const char *path)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  /* The caller may hold the list's own copy, which the remove frees. */
  g_autofree char *kept = g_strdup (path);

  lk_raster_charts_remove (self->raster_charts, kept);
  path = kept;
  /* The engine cannot drop a chart from a live handle, so the picture stays up
   * until the next open. Switch it off, so what the mariner sees agrees with
   * the list they just edited. */
  lk_chart_controller_raster_set_enabled (self->controller, path, FALSE);
  lk_app_model_sync_raster (self);
  g_signal_emit (self, signals[SIGNAL_RASTER_CHANGED], 0);
}

void
lk_app_model_set_raster_enabled (LkAppModel *self, const char *path, gboolean on)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  lk_raster_charts_set_enabled (self->raster_charts, path, on);
  lk_chart_controller_raster_set_enabled (self->controller, path, on);
  /* Switching off the last chart of the drawn set moves the selection, and the
   * pill must not keep naming a chart that is off. */
  lk_app_model_sync_raster (self);
  g_signal_emit (self, signals[SIGNAL_RASTER_CHANGED], 0);
}

gboolean
lk_app_model_raster_enabled (LkAppModel *self, const char *path)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), TRUE);
  return lk_raster_charts_enabled (self->raster_charts, path);
}

guint
lk_app_model_get_raster_count (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), 0);
  return lk_raster_charts_count (self->raster_charts);
}

GPtrArray *
lk_app_model_get_raster_groups (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);
  return lk_raster_charts_groups (self->raster_charts);
}

void
lk_app_model_cycle_raster (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  lk_chart_controller_raster_cycle (self->controller);
  lk_app_model_refresh_raster_state (self);
}

void
lk_app_model_select_raster_set (LkAppModel *self, int index)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  lk_chart_controller_raster_select (self->controller, index);
  lk_app_model_refresh_raster_state (self);
}

void
lk_app_model_toggle_chart (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  /* Nothing to hide without a chart — and a chartless toggle must not clear
   * the saved choice, which the next open replays. */
  if (!lk_chart_controller_is_open (self->controller))
    return;

  lk_chart_controller_toggle_chart (self->controller);
  lk_app_model_refresh_raster_state (self);
  /* From the engine, not from what was asked for: the saved flag has to agree
   * with the picture. */
  lk_store_save_chart_hidden (lk_chart_controller_chart_hidden (self->controller));
}

GPtrArray *
lk_app_model_get_raster_sets (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);
  return self->raster_sets;
}

int
lk_app_model_get_raster_active (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), -1);
  return self->raster_active;
}

const char *
lk_app_model_get_raster_available (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), "");
  return self->raster_available;
}

gboolean
lk_app_model_get_raster_over_chart (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), FALSE);
  return self->raster_over_chart;
}

gboolean
lk_app_model_get_chart_hidden (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), FALSE);
  return self->chart_hidden;
}

/* ---- search: coordinate go-to ------------------------------------------- */

gboolean
lk_app_model_go_to_coordinate (LkAppModel *self, const char *text)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), FALSE);

  double lat, lon;
  if (!lk_coordinate_parse (text, &lat, &lon))
    return FALSE;

  lookout_view current = lk_chart_controller_get_view (self->controller);
  lookout_view target = {
    .lon = lon,
    .lat = lat,
    /* Keep current zoom/rotation; a chart-less view gets a harbour-ish default. */
    .zoom = current.zoom > 0 ? current.zoom : 12.0,
    .rotation_deg = current.rotation_deg,
  };
  lk_chart_controller_set_view (self->controller, target);
  return TRUE;
}

/* ---- readouts ----------------------------------------------------------- */

#define NOTIFY_IF_CHANGED(field, value, prop)                     \
  G_STMT_START {                                                   \
    if ((field) != (value))                                        \
      {                                                            \
        (field) = (value);                                         \
        g_object_notify_by_pspec (G_OBJECT (self), properties[prop]); \
      }                                                            \
  } G_STMT_END


void
lk_app_model_push_readouts (LkAppModel *self,
                            lookout_view view,
                            double scale_denominator,
                            double overscale,
                            int scheme)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  NOTIFY_IF_CHANGED (self->center_lon, view.lon, PROP_CENTER_LON);
  NOTIFY_IF_CHANGED (self->center_lat, view.lat, PROP_CENTER_LAT);
  NOTIFY_IF_CHANGED (self->zoom, view.zoom, PROP_ZOOM);
  NOTIFY_IF_CHANGED (self->rotation_deg, view.rotation_deg, PROP_ROTATION);
  NOTIFY_IF_CHANGED (self->scale_denominator, scale_denominator, PROP_SCALE_DENOMINATOR);
  NOTIFY_IF_CHANGED (self->overscale, overscale, PROP_OVERSCALE);
  NOTIFY_IF_CHANGED (self->scheme, scheme, PROP_SCHEME);

  /* Follow and course up are read off the engine, never remembered from a
   * click: the core turns follow off on a pan and course up off on a rotate by
   * hand, and a control that tracked only its own clicks would lie. */
  NOTIFY_IF_CHANGED (self->follow, lk_chart_controller_follow_active (self->controller),
                     PROP_FOLLOW);
  NOTIFY_IF_CHANGED (self->course_up, lk_chart_controller_course_up_active (self->controller),
                     PROP_COURSE_UP);

  double lon = 0, lat = 0;
  int fix = lk_chart_controller_own_ship (self->controller, &lon, &lat);
  NOTIFY_IF_CHANGED (self->fix_state, fix, PROP_FIX_STATE);
  /* The coordinates are written only for a live fix, so a lost fix leaves the
   * last good numbers alone rather than reading zero. */
  if (fix == LK_FIX_LIVE)
    {
      NOTIFY_IF_CHANGED (self->fix_lon, lon, PROP_FIX_LON);
      NOTIFY_IF_CHANGED (self->fix_lat, lat, PROP_FIX_LAT);
    }
}

/* ---- how the chart is oriented ------------------------------------------- */

LkOrientation
lk_app_model_get_orientation (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), LK_ORIENT_UNLOCKED);

  if (self->follow == 0)
    return LK_ORIENT_UNLOCKED;
  if (self->follow == 2)
    return LK_ORIENT_ARMED; /* on, with no fix to follow yet */
  return self->course_up == 0 ? LK_ORIENT_NORTH_UP : LK_ORIENT_COURSE_UP;
}

void
lk_app_model_cycle_orientation (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (self->follow == 0)
    lk_chart_controller_follow_set (self->controller, TRUE); /* lock, chart as it lies */
  else if (self->course_up == 0)
    lk_chart_controller_course_up_set (self->controller, TRUE); /* turn with own ship */
  else
    lk_chart_controller_reset_rotation (self->controller); /* north up, still locked */
}

int
lk_app_model_get_fix_state (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), LK_FIX_NONE);
  return self->fix_state;
}

gboolean
lk_app_model_get_fix (LkAppModel *self, double *out_lon, double *out_lat)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), FALSE);

  if (self->fix_state != LK_FIX_LIVE)
    return FALSE;
  if (out_lon != NULL)
    *out_lon = self->fix_lon;
  if (out_lat != NULL)
    *out_lat = self->fix_lat;
  return TRUE;
}

void
lk_app_model_set_building (LkAppModel *self, gboolean building)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  NOTIFY_IF_CHANGED (self->building, building, PROP_BUILDING);
}

/* The chart view's size, in logical points. The capsule reads it to decide
 * whether it is in a narrow window, and the pick report is placed inside it. */
void
lk_app_model_set_view_size (LkAppModel *self, int width, int height)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  NOTIFY_IF_CHANGED (self->view_width, width, PROP_VIEW_WIDTH);
  NOTIFY_IF_CHANGED (self->view_height, height, PROP_VIEW_HEIGHT);
}

void
lk_app_model_set_first_build_done (LkAppModel *self, gboolean done)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (self->first_build_done == done)
    return;
  self->first_build_done = done;
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_SHOW_STARTUP_LOADER]);
}

void
lk_app_model_set_opening (LkAppModel *self, gboolean opening, gboolean preparing_symbols)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  self->preparing_symbols = preparing_symbols;
  if (self->is_opening == opening)
    return;
  self->is_opening = opening;
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_SHOW_STARTUP_LOADER]);
}

void
lk_app_model_set_opening_cells (LkAppModel *self, guint cells)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  self->opening_cells = cells;
}

guint
lk_app_model_get_opening_cells (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), 0);
  return self->opening_cells;
}

gboolean
lk_app_model_get_opening (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), FALSE);
  return self->is_opening;
}

gboolean
lk_app_model_get_show_startup_loader (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), FALSE);
  return self->is_opening || (self->has_chart && !self->first_build_done);
}

gboolean
lk_app_model_get_preparing_symbols (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), FALSE);
  return self->preparing_symbols;
}

void
lk_app_model_set_chart_open (LkAppModel *self, gboolean open, const char *path)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (g_strcmp0 (self->chart_path, path) != 0)
    {
      g_free (self->chart_path);
      self->chart_path = g_strdup (path);
      g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_CHART_PATH]);
    }

  if (self->has_chart != open)
    {
      self->has_chart = open;
      g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_HAS_CHART]);
      g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_SHOW_STARTUP_LOADER]);
    }
}

void
lk_app_model_set_open_error (LkAppModel *self, const char *message)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (g_strcmp0 (self->open_error, message) == 0)
    return;
  g_free (self->open_error);
  self->open_error = g_strdup (message);
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_OPEN_ERROR]);
}

void
lk_app_model_set_pick (LkAppModel *self, GPtrArray *results, double x, double y,
                       double lon, double lat)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  g_clear_pointer (&self->pick_results, g_ptr_array_unref);
  self->pick_results = results;
  self->pick_valid = results != NULL && results->len > 0;
  self->pick_x = x;
  self->pick_y = y;
  self->pick_lon = lon;
  self->pick_lat = lat;
  self->pick_has_geo = self->pick_valid;
  /* A new pick is a new set of objects: the report opens on the best one, as
   * the engine ranked them. */
  self->pick_index = 0;
  g_signal_emit (self, signals[SIGNAL_PICK_RESULTS], 0);
}

gboolean
lk_app_model_get_pick_geo (LkAppModel *self, double *out_lon, double *out_lat)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), FALSE);

  if (!self->pick_valid || !self->pick_has_geo)
    return FALSE;
  if (out_lon != NULL)
    *out_lon = self->pick_lon;
  if (out_lat != NULL)
    *out_lat = self->pick_lat;
  return TRUE;
}

void
lk_app_model_move_pick (LkAppModel *self, double x, double y)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (!self->pick_valid)
    return;
  /* Below half a point the mark would shimmer, not move. */
  if (ABS (x - self->pick_x) < 0.5 && ABS (y - self->pick_y) < 0.5)
    return;
  self->pick_x = x;
  self->pick_y = y;
  g_signal_emit (self, signals[SIGNAL_PICK_MOVED], 0);
}

void
lk_app_model_clear_pick (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (!self->pick_valid)
    return;

  g_clear_pointer (&self->pick_results, g_ptr_array_unref);
  self->pick_results = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_pick_feature_free);
  self->pick_valid = FALSE;
  self->pick_index = 0;
  g_signal_emit (self, signals[SIGNAL_PICK_RESULTS], 0);
}

GPtrArray *
lk_app_model_get_pick_results (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);
  return self->pick_results;
}

/* ---- the plugin overlay -------------------------------------------------- */

void
lk_app_model_pin_overlay (LkAppModel *self, const char *id)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (g_strcmp0 (self->overlay_pin, id) == 0)
    return;

  g_free (self->overlay_pin);
  self->overlay_pin = g_strdup (id);

  /* One thing under the finger at a time: pinning a plugin's symbol retires
   * the chart pick report, and the chart pick clears the pin. */
  if (id != NULL)
    lk_app_model_clear_pick (self);

  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_OVERLAY_PIN]);
}

const char *
lk_app_model_get_overlay_pin (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);
  return self->overlay_pin;
}

gboolean
lk_app_model_get_pick_point (LkAppModel *self, double *out_x, double *out_y)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), FALSE);

  if (!self->pick_valid)
    return FALSE;

  if (out_x != NULL)
    *out_x = self->pick_x;
  if (out_y != NULL)
    *out_y = self->pick_y;
  return TRUE;
}

guint
lk_app_model_get_pick_index (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), 0);
  return self->pick_index;
}

void
lk_app_model_set_pick_index (LkAppModel *self, guint index)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  /* No signal: the card moves its own selection, and re-emitting would rebuild
   * the card underneath the click that moved it. */
  self->pick_index = index;
}

/* ---- accessors ---------------------------------------------------------- */

gboolean    lk_app_model_get_has_chart (LkAppModel *self)         { return self->has_chart; }
const char *lk_app_model_get_chart_path (LkAppModel *self)        { return self->chart_path; }
double      lk_app_model_get_center_lon (LkAppModel *self)        { return self->center_lon; }
double      lk_app_model_get_center_lat (LkAppModel *self)        { return self->center_lat; }
double      lk_app_model_get_zoom (LkAppModel *self)              { return self->zoom; }
double      lk_app_model_get_rotation (LkAppModel *self)          { return self->rotation_deg; }
double      lk_app_model_get_overscale (LkAppModel *self)         { return self->overscale; }
double      lk_app_model_get_scale_denominator (LkAppModel *self) { return self->scale_denominator; }
int         lk_app_model_get_scheme (LkAppModel *self)            { return self->scheme; }
gboolean    lk_app_model_get_building (LkAppModel *self)          { return self->building; }
gboolean    lk_app_model_get_baking (LkAppModel *self)            { return self->baking; }

const LkBakeProgress *
lk_app_model_get_bake_progress (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);
  return self->baking ? &self->bake_progress : NULL;
}

void
lk_app_model_cancel_bake (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));
  if (self->bake != NULL)
    lk_chart_bake_cancel (self->bake);
}
int         lk_app_model_get_view_width (LkAppModel *self)        { return self->view_width; }
int         lk_app_model_get_view_height (LkAppModel *self)       { return self->view_height; }

const char *
lk_app_model_get_scheme_name (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), "Day");

  switch (self->scheme)
    {
    case 1:  return "Dusk";
    case 2:  return "Night";
    default: return "Day";
    }
}

#undef NOTIFY_IF_CHANGED
