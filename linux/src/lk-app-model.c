#include "lk-app-model.h"

#include "lk-store.h"

#include <math.h>

struct _LkAppModel {
  GObject parent_instance;

  LkChartController *controller;

  gboolean has_chart;
  char    *chart_path;
  char    *open_error;
  GStrv    recents;

  gboolean is_opening;
  gboolean preparing_symbols;
  gboolean first_build_done;

  gboolean cursor_valid;
  double   cursor_lon, cursor_lat;
  double   center_lon, center_lat;
  double   zoom;
  double   rotation_deg;
  double   overscale;
  double   scale_denominator;
  int      scheme;
  gboolean building;

  int view_width, view_height; /* the chart view, in logical points */

  /* The raster charts the mariner installed, and the state the engine reports
   * for them over the water in view. */
  LkRasterCharts *raster_charts;
  GPtrArray      *raster_sets; /* LkRasterSet* */
  int             raster_active;
  char           *raster_available;
  gboolean        raster_over_chart;
  gboolean        chart_hidden;

  GPtrArray *pick_results;
  gboolean   pick_valid;
  double     pick_x, pick_y; /* logical points in the chart view */
  guint      pick_index;
};

enum {
  PROP_0,
  PROP_HAS_CHART,
  PROP_CHART_PATH,
  PROP_OPEN_ERROR,
  PROP_RECENTS,
  PROP_SHOW_STARTUP_LOADER,
  PROP_CURSOR_VALID,
  PROP_CURSOR_LON,
  PROP_CURSOR_LAT,
  PROP_CENTER_LON,
  PROP_CENTER_LAT,
  PROP_ZOOM,
  PROP_ROTATION,
  PROP_OVERSCALE,
  PROP_SCALE_DENOMINATOR,
  PROP_SCHEME,
  PROP_BUILDING,
  PROP_VIEW_WIDTH,
  PROP_VIEW_HEIGHT,
  N_PROPS
};

enum {
  SIGNAL_PICK_RESULTS,
  SIGNAL_RASTER_CHANGED,
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
    case PROP_RECENTS:             g_value_set_boxed (value, self->recents); break;
    case PROP_SHOW_STARTUP_LOADER: g_value_set_boolean (value, lk_app_model_get_show_startup_loader (self)); break;
    case PROP_CURSOR_VALID:        g_value_set_boolean (value, self->cursor_valid); break;
    case PROP_CURSOR_LON:          g_value_set_double (value, self->cursor_lon); break;
    case PROP_CURSOR_LAT:          g_value_set_double (value, self->cursor_lat); break;
    case PROP_CENTER_LON:          g_value_set_double (value, self->center_lon); break;
    case PROP_CENTER_LAT:          g_value_set_double (value, self->center_lat); break;
    case PROP_ZOOM:                g_value_set_double (value, self->zoom); break;
    case PROP_ROTATION:            g_value_set_double (value, self->rotation_deg); break;
    case PROP_OVERSCALE:           g_value_set_double (value, self->overscale); break;
    case PROP_SCALE_DENOMINATOR:   g_value_set_double (value, self->scale_denominator); break;
    case PROP_SCHEME:              g_value_set_int (value, self->scheme); break;
    case PROP_BUILDING:            g_value_set_boolean (value, self->building); break;
    case PROP_VIEW_WIDTH:          g_value_set_int (value, self->view_width); break;
    case PROP_VIEW_HEIGHT:         g_value_set_int (value, self->view_height); break;
    default: G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    }
}

static void
lk_app_model_set_property (GObject *object, guint prop_id, const GValue *value, GParamSpec *pspec)
{
  LkAppModel *self = LK_APP_MODEL (object);

  switch (prop_id)
    {
    default: G_OBJECT_WARN_INVALID_PROPERTY_ID (object, prop_id, pspec);
    }
}

static void
lk_app_model_dispose (GObject *object)
{
  LkAppModel *self = LK_APP_MODEL (object);

  g_clear_object (&self->controller);
  g_clear_pointer (&self->chart_path, g_free);
  g_clear_pointer (&self->open_error, g_free);
  g_clear_pointer (&self->recents, g_strfreev);
  g_clear_pointer (&self->pick_results, g_ptr_array_unref);
  g_clear_pointer (&self->raster_sets, g_ptr_array_unref);
  g_clear_pointer (&self->raster_available, g_free);
  g_clear_pointer (&self->raster_charts, lk_raster_charts_free);

  G_OBJECT_CLASS (lk_app_model_parent_class)->dispose (object);
}

static void
lk_app_model_class_init (LkAppModelClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = lk_app_model_get_property;
  object_class->set_property = lk_app_model_set_property;
  object_class->dispose = lk_app_model_dispose;

#define RO  (G_PARAM_READABLE | G_PARAM_STATIC_STRINGS)
#define RW  (G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS)

  properties[PROP_HAS_CHART] = g_param_spec_boolean ("has-chart", NULL, NULL, FALSE, RO);
  properties[PROP_CHART_PATH] = g_param_spec_string ("chart-path", NULL, NULL, NULL, RO);
  properties[PROP_OPEN_ERROR] = g_param_spec_string ("open-error", NULL, NULL, NULL, RO);
  properties[PROP_RECENTS] = g_param_spec_boxed ("recents", NULL, NULL, G_TYPE_STRV, RO);
  properties[PROP_SHOW_STARTUP_LOADER] = g_param_spec_boolean ("show-startup-loader", NULL, NULL, FALSE, RO);
  properties[PROP_CURSOR_VALID] = g_param_spec_boolean ("cursor-valid", NULL, NULL, FALSE, RO);
  properties[PROP_CURSOR_LON] = g_param_spec_double ("cursor-lon", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_CURSOR_LAT] = g_param_spec_double ("cursor-lat", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_CENTER_LON] = g_param_spec_double ("center-lon", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_CENTER_LAT] = g_param_spec_double ("center-lat", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_ZOOM] = g_param_spec_double ("zoom", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_ROTATION] = g_param_spec_double ("rotation", NULL, NULL, -G_MAXDOUBLE, G_MAXDOUBLE, 0, RO);
  properties[PROP_OVERSCALE] = g_param_spec_double ("overscale", NULL, NULL, 0, G_MAXDOUBLE, 1.0, RO);
  properties[PROP_SCALE_DENOMINATOR] = g_param_spec_double ("scale-denominator", NULL, NULL, 0, G_MAXDOUBLE, 0, RO);
  properties[PROP_SCHEME] = g_param_spec_int ("scheme", NULL, NULL, 0, 2, 0, RO);
  properties[PROP_BUILDING] = g_param_spec_boolean ("building", NULL, NULL, FALSE, RO);
  properties[PROP_VIEW_WIDTH] = g_param_spec_int ("view-width", NULL, NULL, 0, G_MAXINT, 0, RO);
  properties[PROP_VIEW_HEIGHT] = g_param_spec_int ("view-height", NULL, NULL, 0, G_MAXINT, 0, RO);

#undef RO
#undef RW

  g_object_class_install_properties (object_class, N_PROPS, properties);

  /* Carries nothing; the panel reads results back via lk_app_model_get_pick_results. */
  signals[SIGNAL_PICK_RESULTS] =
      g_signal_new ("pick-results", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);

  /* The installed list, the sets in view, the drawn one, or the ENC switch
   * moved. One signal, not a property each: the pill reads all of them
   * together, and it is rebuilt as a whole. */
  signals[SIGNAL_RASTER_CHANGED] =
      g_signal_new ("raster-changed", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

static void
lk_app_model_init (LkAppModel *self)
{
  self->controller = lk_chart_controller_new ();
  lk_chart_controller_set_model (self->controller, self);

  self->recents = lk_store_load_recents ();
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

/* ---- opening charts ----------------------------------------------------- */

static void
lk_collect_cells (const char *dir, GPtrArray *out)
{
  g_autoptr (GDir) handle = g_dir_open (dir, 0, NULL);

  if (handle == NULL)
    return;

  const char *name;
  while ((name = g_dir_read_name (handle)) != NULL)
    {
      g_autofree char *path = g_build_filename (dir, name, NULL);

      if (g_file_test (path, G_FILE_TEST_IS_DIR))
        lk_collect_cells (path, out);
      else if (g_str_has_suffix (name, ".pmtiles"))
        g_ptr_array_add (out, g_steal_pointer (&path));
    }
}

static int
lk_strcmp_sort (gconstpointer a, gconstpointer b)
{
  return g_strcmp0 (*(const char *const *) a, *(const char *const *) b);
}

char **
lk_app_model_chart_paths_in_dir (const char *dir)
{
  g_autoptr (GPtrArray) paths = g_ptr_array_new_with_free_func (g_free);

  g_return_val_if_fail (dir != NULL, g_new0 (char *, 1));

  lk_collect_cells (dir, paths);
  g_ptr_array_sort (paths, lk_strcmp_sort);
  g_ptr_array_add (paths, NULL);
  return (char **) g_ptr_array_free (g_steal_pointer (&paths), FALSE);
}

/* Target to cell list: a folder expands to its cells, a file is itself, a
 * dangling path is empty (callers fall through to the next candidate). */
static char **
lk_cell_paths_for (const char *target)
{
  if (target == NULL || !g_file_test (target, G_FILE_TEST_EXISTS))
    return g_new0 (char *, 1);

  if (g_file_test (target, G_FILE_TEST_IS_DIR))
    return lk_app_model_chart_paths_in_dir (target);

  char **one = g_new0 (char *, 2);
  one[0] = g_strdup (target);
  return one;
}

char **
lk_app_model_initial_chart_paths (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), g_new0 (char *, 1));

  const char *env = g_getenv ("LOOKOUT_OPEN");
  if (env != NULL)
    {
      char **cells = lk_cell_paths_for (env);
      if (g_strv_length (cells) > 0)
        return cells;
      g_strfreev (cells);
    }

  if (self->recents != NULL && self->recents[0] != NULL)
    {
      char **cells = lk_cell_paths_for (self->recents[0]);
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

/* `recent` is what the USER opened (folder or single cell), not the expanded
 * cells — else the next launch would reopen one cell, not the whole library. */
static void
lk_app_model_request_open (LkAppModel *self, char **paths, const char *recent)
{
  if (paths == NULL || g_strv_length (paths) == 0)
    return;

  lk_store_note_recent (recent);
  g_clear_pointer (&self->recents, g_strfreev);
  self->recents = lk_store_load_recents ();
  g_object_notify_by_pspec (G_OBJECT (self), properties[PROP_RECENTS]);

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

  g_auto (GStrv) one = g_new0 (char *, 2);
  one[0] = g_strdup (path);
  lk_app_model_request_open (self, one, path);
}

void
lk_app_model_open_chart_directory (LkAppModel *self, const char *dir)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  g_auto (GStrv) paths = lk_app_model_chart_paths_in_dir (dir);
  if (g_strv_length (paths) > 0)
    lk_app_model_request_open (self, paths, dir);
  else
    lk_app_model_set_open_error (self, "That folder contains no baked .pmtiles cells.");
}

const char *const *
lk_app_model_get_recents (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);
  return (const char *const *) self->recents;
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

/* A menu scheme change must persist just like one from the settings form. */
void
lk_app_model_cycle_scheme (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  lk_chart_controller_cycle_scheme (self->controller);
  tile57_mariner mariner = lk_chart_controller_get_mariner (self->controller);
  lk_store_save_mariner (&mariner);
}

void
lk_app_model_set_scheme (LkAppModel *self, int scheme)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

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
          g_strcmp0 (one->name, other->name) != 0)
        return FALSE;
    }

  return TRUE;
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
  return TRUE;
}

void
lk_app_model_refresh_raster_state (LkAppModel *self)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  if (lk_app_model_sync_raster (self))
    g_signal_emit (self, signals[SIGNAL_RASTER_CHANGED], 0);
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
    g_message ("raster: %u/%u chart(s) re-installed", installed,
               lk_raster_charts_count (self->raster_charts));
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

const char *const *
lk_app_model_get_raster_paths (LkAppModel *self)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (self), NULL);
  return lk_raster_charts_paths (self->raster_charts);
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

  lk_chart_controller_toggle_chart (self->controller);
  lk_app_model_refresh_raster_state (self);
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

static gboolean
lk_parse_hemispheres (const char *text, double *out_lat, double *out_lon)
{
  /* deg [min [sec]] hemisphere — minutes and seconds both optional. */
  static const char *pattern =
      "(\\d+(?:\\.\\d+)?)\\s*[°\\s]\\s*"
      "(?:(\\d+(?:\\.\\d+)?)\\s*['′\\s]\\s*)?"
      "(?:(\\d+(?:\\.\\d+)?)\\s*[\"″\\s]\\s*)?"
      "([NSEWnsew])";

  g_autoptr (GRegex) regex = g_regex_new (pattern, G_REGEX_CASELESS, 0, NULL);
  if (regex == NULL)
    return FALSE;

  g_autoptr (GMatchInfo) match = NULL;
  if (!g_regex_match (regex, text, 0, &match))
    return FALSE;

  gboolean have_lat = FALSE, have_lon = FALSE;

  while (g_match_info_matches (match))
    {
      g_autofree char *deg_s = g_match_info_fetch (match, 1);
      g_autofree char *min_s = g_match_info_fetch (match, 2);
      g_autofree char *sec_s = g_match_info_fetch (match, 3);
      g_autofree char *hemi_s = g_match_info_fetch (match, 4);

      if (deg_s != NULL && deg_s[0] != '\0' && hemi_s != NULL && hemi_s[0] != '\0')
        {
          double value = g_ascii_strtod (deg_s, NULL);
          if (min_s != NULL && min_s[0] != '\0')
            value += g_ascii_strtod (min_s, NULL) / 60.0;
          if (sec_s != NULL && sec_s[0] != '\0')
            value += g_ascii_strtod (sec_s, NULL) / 3600.0;

          char hemi = g_ascii_toupper (hemi_s[0]);
          if (hemi == 'S' || hemi == 'W')
            value = -value;

          if (hemi == 'N' || hemi == 'S')
            {
              *out_lat = value;
              have_lat = TRUE;
            }
          else
            {
              *out_lon = value;
              have_lon = TRUE;
            }
        }

      g_match_info_next (match, NULL);
    }

  return have_lat && have_lon;
}

gboolean
lk_coordinate_parse (const char *text, double *out_lat, double *out_lon)
{
  g_return_val_if_fail (out_lat != NULL && out_lon != NULL, FALSE);

  if (text == NULL)
    return FALSE;

  g_autofree char *trimmed = g_strstrip (g_strdup (text));
  if (trimmed[0] == '\0')
    return FALSE;

  if (strpbrk (trimmed, "NSEWnsew") != NULL)
    return lk_parse_hemispheres (trimmed, out_lat, out_lon);

  /* A decimal pair, comma- or whitespace-separated, latitude first. */
  g_auto (GStrv) parts = g_strsplit_set (trimmed, ", \t", -1);
  g_autoptr (GPtrArray) numbers = g_ptr_array_new ();
  for (guint i = 0; parts[i] != NULL; i++)
    {
      if (parts[i][0] != '\0')
        g_ptr_array_add (numbers, parts[i]);
    }

  if (numbers->len < 2)
    return FALSE;

  char *end_lat = NULL, *end_lon = NULL;
  double lat = g_ascii_strtod (g_ptr_array_index (numbers, 0), &end_lat);
  double lon = g_ascii_strtod (g_ptr_array_index (numbers, 1), &end_lon);

  if (end_lat == g_ptr_array_index (numbers, 0) || *end_lat != '\0')
    return FALSE;
  if (end_lon == g_ptr_array_index (numbers, 1) || *end_lon != '\0')
    return FALSE;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180)
    return FALSE;

  *out_lat = lat;
  *out_lon = lon;
  return TRUE;
}

/* A typed scale: "25000", "25,000", "1:25000", "25k" and "1:2.5M" all mean the
 * same thing. It accepts what ScaleParser accepts on the other shells, so a
 * scale read off one app types into another. */
gboolean
lk_scale_parse (const char *text, double *out_denominator)
{
  g_return_val_if_fail (out_denominator != NULL, FALSE);

  if (text == NULL)
    return FALSE;

  g_autofree char *lower = g_ascii_strdown (text, -1);
  const char *body = strrchr (lower, ':'); /* in "1:25k" the 1 is before it */
  body = body != NULL ? body + 1 : lower;

  /* Group separators and spaces are how a scale is written, not part of it. */
  g_autoptr (GString) digits = g_string_new (NULL);
  double multiplier = 1.0;
  for (const char *p = body; *p != '\0'; p++)
    {
      if (*p == ',' || g_ascii_isspace (*p))
        continue;
      g_string_append_c (digits, *p);
    }

  if (digits->len == 0)
    return FALSE;

  char last = digits->str[digits->len - 1];
  if (last == 'k' || last == 'm')
    {
      multiplier = last == 'k' ? 1000.0 : 1000000.0;
      g_string_truncate (digits, digits->len - 1);
    }

  char *end = NULL;
  double value = g_ascii_strtod (digits->str, &end);
  if (end == digits->str || *end != '\0')
    return FALSE;

  double denominator = value * multiplier;
  if (!isfinite (denominator) || denominator <= 0)
    return FALSE;

  *out_denominator = denominator;
  return TRUE;
}

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
lk_app_model_set_cursor_geo (LkAppModel *self, gboolean valid, double lon, double lat)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  NOTIFY_IF_CHANGED (self->cursor_valid, valid, PROP_CURSOR_VALID);
  NOTIFY_IF_CHANGED (self->cursor_lon, lon, PROP_CURSOR_LON);
  NOTIFY_IF_CHANGED (self->cursor_lat, lat, PROP_CURSOR_LAT);
}

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
lk_app_model_set_pick (LkAppModel *self, GPtrArray *results, double x, double y)
{
  g_return_if_fail (LK_IS_APP_MODEL (self));

  g_clear_pointer (&self->pick_results, g_ptr_array_unref);
  self->pick_results = results;
  self->pick_valid = results != NULL && results->len > 0;
  self->pick_x = x;
  self->pick_y = y;
  /* A new pick is a new set of objects: the report opens on the best one, as
   * the engine ranked them. */
  self->pick_index = 0;
  g_signal_emit (self, signals[SIGNAL_PICK_RESULTS], 0);
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
gboolean    lk_app_model_get_cursor_valid (LkAppModel *self)      { return self->cursor_valid; }
double      lk_app_model_get_cursor_lon (LkAppModel *self)        { return self->cursor_lon; }
double      lk_app_model_get_cursor_lat (LkAppModel *self)        { return self->cursor_lat; }
double      lk_app_model_get_center_lon (LkAppModel *self)        { return self->center_lon; }
double      lk_app_model_get_center_lat (LkAppModel *self)        { return self->center_lat; }
double      lk_app_model_get_zoom (LkAppModel *self)              { return self->zoom; }
double      lk_app_model_get_rotation (LkAppModel *self)          { return self->rotation_deg; }
double      lk_app_model_get_overscale (LkAppModel *self)         { return self->overscale; }
double      lk_app_model_get_scale_denominator (LkAppModel *self) { return self->scale_denominator; }
int         lk_app_model_get_scheme (LkAppModel *self)            { return self->scheme; }
gboolean    lk_app_model_get_building (LkAppModel *self)          { return self->building; }
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
