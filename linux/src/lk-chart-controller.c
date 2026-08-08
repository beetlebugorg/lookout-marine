#include "lk-chart-controller.h"

#include "lk-app-model.h"
#include "lk-chart-view.h"
#include "lk-plugins.h"
#include "lk-store.h"

struct _LkChartController {
  GObject parent_instance;

  lookout *handle;    /* NULL until a chart is opened */
  char    *chart_path; /* the path (or directory) currently open, for the title */

  GtkWidget  *view;  /* the chart widget we render for; not owned */
  LkAppModel *model; /* pushed live readouts; not owned */

  guint    tick_id;
  gint64   last_frame_us;
  int      idle_ticks;

  /* Kicks the tick loop back awake for the plugins (see the idle poll below). */
  guint    plugin_poll_id;

  gint64 last_readouts_us;
  gint64 last_view_saved_us;
};

G_DEFINE_FINAL_TYPE (LkChartController, lk_chart_controller, G_TYPE_OBJECT)

void
lk_pick_feature_free (LkPickFeature *feature)
{
  if (feature == NULL)
    return;
  g_free (feature->cls);
  g_free (feature->chart);
  g_free (feature->s57);
  g_free (feature);
}

static void
lk_chart_controller_dispose (GObject *object)
{
  LkChartController *self = LK_CHART_CONTROLLER (object);

  lk_chart_controller_close (self);
  g_clear_pointer (&self->chart_path, g_free);

  G_OBJECT_CLASS (lk_chart_controller_parent_class)->dispose (object);
}

static void
lk_chart_controller_class_init (LkChartControllerClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = lk_chart_controller_dispose;
}

static void
lk_chart_controller_init (LkChartController *self)
{
}

LkChartController *
lk_chart_controller_new (void)
{
  return g_object_new (LK_TYPE_CHART_CONTROLLER, NULL);
}

void
lk_chart_controller_set_model (LkChartController *self, LkAppModel *model)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));
  self->model = model;
}

gboolean
lk_chart_controller_is_open (LkChartController *self)
{
  return LK_IS_CHART_CONTROLLER (self) && self->handle != NULL;
}

const char *
lk_chart_controller_chart_path (LkChartController *self)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), NULL);
  return self->chart_path;
}

/* ---- readouts ----------------------------------------------------------- */

static void
lk_chart_controller_push_readouts (LkChartController *self)
{
  if (self->handle == NULL || self->model == NULL)
    return;

  /* Throttle to 10Hz: nobody reads these strings faster than that. */
  gint64 now = g_get_monotonic_time ();
  if (now - self->last_readouts_us < 100 * 1000)
    return;
  self->last_readouts_us = now;

  lookout_view view;
  lookout_get_view (self->handle, &view);

  tile57_mariner mariner;
  lookout_get_mariner (self->handle, &mariner);

  lk_app_model_push_readouts (self->model, view,
                              lookout_scale_denominator (self->handle),
                              lookout_overscale (self->handle),
                              (int) mariner.scheme);

  /* Which raster chart sets cover the view changes as the mariner sails, so
   * the pill is fed from the frame like every other readout. */
  lk_app_model_refresh_raster_state (self->model);

  /* Persist periodically: a crash or kill -9 never reaches close(). */
  if (now - self->last_view_saved_us >= 3 * G_USEC_PER_SEC)
    {
      self->last_view_saved_us = now;
      lk_store_save_view (&view);
    }
}

/* ---- the on-demand render loop ------------------------------------------ */

static gboolean
lk_chart_controller_tick (GtkWidget     *widget,
                          GdkFrameClock *clock,
                          gpointer       user_data)
{
  LkChartController *self = user_data;

  if (self->handle == NULL)
    {
      self->tick_id = 0;
      return G_SOURCE_REMOVE;
    }

  gint64 now = gdk_frame_clock_get_frame_time (clock);
  double dt = self->last_frame_us == 0 ? 0.0 : (now - self->last_frame_us) / (double) G_USEC_PER_SEC;
  self->last_frame_us = now;
  if (dt > 0.05)
    dt = 0.05; /* cap after an idle gap, so a resumed fling doesn't teleport */

  gboolean animating = lookout_animating (self->handle) != 0;
  if (animating)
    lookout_tick_anim (self->handle, dt);

  gboolean building = lookout_is_building (self->handle) != 0;
  if (self->model != NULL)
    lk_app_model_set_building (self->model, building);

  if (animating || lookout_needs_redraw (self->handle) != 0)
    {
      if (lookout_render (self->handle))
        {
          lk_chart_view_surface_ready (LK_CHART_VIEW (self->view));
          /* The chart is on the screen, so the loader has done its job. A
           * library of a thousand cells keeps tessellating for a while after
           * that, and the build pill carries it — a loader still up over a
           * drawn chart says the app is stuck when it is not. */
          if (self->model != NULL)
            lk_app_model_set_first_build_done (self->model, TRUE);
        }
      lk_chart_controller_push_readouts (self);
      self->idle_ticks = 0;
    }
  else if (building)
    {
      self->idle_ticks = 0; /* keep ticking while a background tessellation fills in */
    }
  else
    {
      /* Static — the first scene has rendered, which retires the spinner. */
      if (self->model != NULL)
        lk_app_model_set_first_build_done (self->model, TRUE);

      if (++self->idle_ticks > 2)
        {
          self->tick_id = 0;
          return G_SOURCE_REMOVE; /* idle costs nothing until something kicks us */
        }
    }

  return G_SOURCE_CONTINUE;
}

void
lk_chart_controller_kick (LkChartController *self)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  self->idle_ticks = 0;
  if (self->tick_id != 0 || self->view == NULL || self->handle == NULL)
    return;

  self->last_frame_us = 0;
  self->tick_id = gtk_widget_add_tick_callback (self->view, lk_chart_controller_tick,
                                                self, NULL);
}

static void
lk_chart_controller_stop_tick (LkChartController *self)
{
  if (self->tick_id != 0 && self->view != NULL)
    gtk_widget_remove_tick_callback (self->view, self->tick_id);
  self->tick_id = 0;
}

/* ---- the plugin idle poll ----------------------------------------------- */

/* The tick loop takes itself off the frame clock once the chart is static, and
 * only input puts it back. A plugin posts geometry from its own thread with no
 * gesture behind it, so while plugins are loaded a timer asks whether anything
 * moved and re-arms the loop when it did. Without it AIS traffic freezes until
 * the mariner touches the trackpad.
 *
 * 4 Hz: the AIS store coalesces to 2 Hz, and this is twice that. It costs one
 * cheap call per beat while nothing is happening. */
#define LK_PLUGIN_POLL_MS 250

static gboolean
lk_chart_controller_plugin_poll (gpointer user_data)
{
  LkChartController *self = user_data;

  if (self->handle == NULL)
    {
      self->plugin_poll_id = 0;
      return G_SOURCE_REMOVE;
    }

  if (lookout_needs_redraw (self->handle) != 0)
    lk_chart_controller_kick (self);
  return G_SOURCE_CONTINUE;
}

static void
lk_chart_controller_start_plugin_poll (LkChartController *self)
{
  if (self->plugin_poll_id != 0 || self->handle == NULL)
    return;
  if (lookout_plugins_active (self->handle) == 0)
    return;

  self->plugin_poll_id = g_timeout_add (LK_PLUGIN_POLL_MS,
                                        lk_chart_controller_plugin_poll, self);
}

static void
lk_chart_controller_stop_plugin_poll (LkChartController *self)
{
  g_clear_handle_id (&self->plugin_poll_id, g_source_remove);
}

/* ---- the plugin set ------------------------------------------------------ */

/* The plugin set that travels with the install.
 *
 * /proc/self/exe first: an AppImage or any other relocatable bundle is
 * unpacked wherever the mariner put it, and the path meson baked in at
 * configure time names a prefix that is not there. LK_PLUGIN_DIR is the
 * distro-package answer and stands behind it. NULL when the build carries
 * neither, which is a build with no plugins bundled rather than a fault.
 * Transfer full. */
static char *
lk_bundled_plugin_dir (void)
{
  g_autofree char *exe = g_file_read_link ("/proc/self/exe", NULL);

  if (exe != NULL)
    {
      g_autofree char *bindir = g_path_get_dirname (exe);
      char *relative = g_build_filename (bindir, "..", "share", "lookout-marine",
                                         "plugins", NULL);

      if (g_file_test (relative, G_FILE_TEST_IS_DIR))
        return relative;
      g_free (relative);
    }

#ifdef LK_PLUGIN_DIR
  if (g_file_test (LK_PLUGIN_DIR, G_FILE_TEST_IS_DIR))
    return g_strdup (LK_PLUGIN_DIR);
#endif

  return NULL;
}

/* Bundled first, then installed. The order is the precedence the core
 * documents: $LOOKOUT_PLUGINS (which loads at open, before this runs), then
 * bundled, then installed — on an id collision the first copy loaded wins, so
 * a developer override beats the shipped copy and the shipped copy beats one
 * the mariner installed under the same id.
 *
 * Neither call failing is a mariner's problem: a build that bundles nothing
 * still runs the installed set, and a core built with no plugin host answers
 * -1 to both and leaves a chart with no boat on it, which the log says once. */
static void
lk_chart_controller_load_plugins (LkChartController *self)
{
  g_autofree char *bundled = lk_bundled_plugin_dir ();

  if (bundled != NULL)
    {
      if (lookout_plugins_load (self->handle, bundled) != 0)
        g_warning ("bundled plugins in %s did not load", bundled);
    }
  else
    {
      g_message ("no bundled plugins in this build");
    }

  lookout_plugins_load_installed (self->handle);

  if (lookout_plugins_active (self->handle) == 0)
    g_message ("no plugin layer: this chart has no own ship, no AIS and no instrument input");
}

gboolean
lk_chart_controller_plugins_active (LkChartController *self)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), FALSE);

  return self->handle != NULL && lookout_plugins_active (self->handle) != 0;
}

char *
lk_chart_controller_plugins_json (LkChartController *self)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), NULL);

  if (self->handle == NULL)
    return NULL;

  gsize length = 0;
  const char *json = lookout_plugins_json (self->handle, &length);

  /* Borrowed until the next plugin query, so it is copied out here. */
  return json == NULL || length == 0 ? NULL : g_strndup (json, length);
}

gboolean
lk_chart_controller_set_plugin_config (LkChartController *self,
                                       const char        *id,
                                       const char        *json)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), FALSE);

  if (self->handle == NULL || id == NULL || json == NULL)
    return FALSE;

  if (lookout_plugin_config_set (self->handle, id, json) != 0)
    return FALSE;

  /* The plugin redraws inside the call, so the chart is kicked to show it. */
  lk_chart_controller_kick (self);
  return TRUE;
}

/* ---- lifecycle ---------------------------------------------------------- */

void
lk_chart_controller_attach_view (LkChartController *self, GtkWidget *view)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->view == NULL)
    self->view = view;
}

/* One open call, given the native surface kind + handle. */
static lookout *
lk_chart_controller_open_handle (const char *const *paths, guint n,
                                 int kind, void *native, int width, int height)
{
  if (n == 1)
    return lookout_open_in_window (kind, native, paths[0], width, height, 1);
  return lookout_open_charts_in_window (kind, native, paths, n, width, height, 1);
}

gboolean
lk_chart_controller_open (LkChartController *self,
                          const char *const *paths,
                          GtkWidget         *view)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), FALSE);
  g_return_val_if_fail (LK_IS_CHART_VIEW (view), FALSE);

  guint n = paths == NULL ? 0 : g_strv_length ((char **) paths);
  if (n == 0)
    return FALSE;

  lk_chart_controller_close (self);
  self->view = view;

  if (self->model != NULL)
    lk_app_model_set_first_build_done (self->model, FALSE);

  int width, height;
  lk_chart_view_get_point_size (LK_CHART_VIEW (view), &width, &height);

  /* The chart presents into a native subsurface placed BELOW a transparent hole
   * in the window, so the compositor draws it crisply and the chrome floats over. */
  if (!lk_chart_view_ensure_native_surface (LK_CHART_VIEW (view)))
    {
      g_warning ("open FAILED — no native surface");
      if (self->model != NULL)
        lk_app_model_set_open_error (self->model, "The chart view has no drawing surface.");
      return FALSE;
    }

  LkNativeSurface *surface = lk_chart_view_get_native_surface (LK_CHART_VIEW (view));
  g_message ("opening %u chart(s) into a %d×%d pt %s surface: %s",
             n, width, height, lk_native_surface_backend (surface), paths[0]);
  lookout *handle = lk_chart_controller_open_handle (paths, n,
                                                     lk_native_surface_kind (surface),
                                                     lk_native_surface_handle (surface),
                                                     width, height);

  if (handle == NULL)
    {
      g_warning ("open FAILED (lookout_open_in_window returned NULL — Vulkan device or chart file?)");
      if (self->model != NULL)
        lk_app_model_set_open_error (self->model,
                                     "Couldn't open the chart.\n"
                                     "The file may be unreadable, or no Vulkan device could be created.");
      return FALSE;
    }

  self->handle = handle;
  if (self->model != NULL)
    lk_app_model_set_open_error (self->model, NULL);

  g_free (self->chart_path);
  self->chart_path = n == 1 ? g_strdup (paths[0]) : g_path_get_dirname (paths[0]);

  /* Re-install the mariner's raster charts. A raster chart belongs to a lookout
   * handle, and the close above destroyed the old one, so every open replays
   * them — that is what makes a raster chart survive both a change of ENC and a
   * restart. */
  if (self->model != NULL)
    lk_app_model_reinstall_raster_charts (self->model);

  lookout_set_pixel_density (handle, (float) gtk_widget_get_scale_factor (view));
  lookout_resize (handle, width, height);

  /* Reopen where we left off, or the engine's default view when nothing is saved. */
  lookout_view view_pose;
  if (!lk_store_load_view (&view_pose))
    lookout_default_view (handle, &view_pose);
  lookout_set_view (handle, &view_pose);

  /* $LOOKOUT_VIEW="lon,lat,zoom[,rot]" pins the opening camera (screenshots). */
  const char *spec = g_getenv ("LOOKOUT_VIEW");
  if (spec != NULL)
    {
      g_auto (GStrv) parts = g_strsplit (spec, ",", -1);
      if (g_strv_length (parts) >= 3)
        {
          lookout_view v = {
            .lon = g_ascii_strtod (parts[0], NULL),
            .lat = g_ascii_strtod (parts[1], NULL),
            .zoom = g_ascii_strtod (parts[2], NULL),
            .rotation_deg = g_strv_length (parts) > 3 ? g_ascii_strtod (parts[3], NULL) : 0.0,
          };
          lookout_set_view (handle, &v);
        }
      else
        {
          g_warning ("ignoring malformed LOOKOUT_VIEW '%s' (want lon,lat,zoom[,rot])", spec);
        }
    }

  /* device_scale (physical symbol/text size) is the host's to state. */
  lk_chart_controller_sync_device_scale (self);

  /* Saved settings overlay the defaults, so the chart reopens as left. */
  tile57_mariner mariner = lk_chart_controller_get_mariner (self);
  lk_store_apply_saved_mariner (&mariner);
  lk_chart_controller_set_mariner (self, mariner);

  /* The plugins belong to the handle the open just made, so they are loaded
   * per open and the poll that keeps their geometry moving starts with them. */
  lk_chart_controller_load_plugins (self);
  lk_plugins_apply_saved (self);
  lk_chart_controller_start_plugin_poll (self);

  lk_chart_controller_kick (self);
  self->last_readouts_us = 0;
  lk_chart_controller_push_readouts (self);

  if (self->model != NULL)
    lk_app_model_set_chart_open (self->model, TRUE, self->chart_path);

  return TRUE;
}

gboolean
lk_chart_controller_reopen (LkChartController *self, const char *const *paths)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), FALSE);

  if (self->view == NULL)
    return FALSE;
  return lk_chart_controller_open (self, paths, self->view);
}

void
lk_chart_controller_close (LkChartController *self)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  lk_chart_controller_stop_tick (self);
  lk_chart_controller_stop_plugin_poll (self);

  if (self->handle == NULL)
    return;

  lookout_view view;
  lookout_get_view (self->handle, &view); /* the pose to reopen on, before the handle dies */
  lk_store_save_view (&view);

  lookout_close (self->handle);
  self->handle = NULL;

  if (self->model != NULL)
    lk_app_model_set_chart_open (self->model, FALSE, NULL);
}

/* ---- view --------------------------------------------------------------- */

lookout_view
lk_chart_controller_get_view (LkChartController *self)
{
  lookout_view view = { 0, 0, 0, 0 };

  if (LK_IS_CHART_CONTROLLER (self) && self->handle != NULL)
    lookout_get_view (self->handle, &view);
  return view;
}

/* A pick report belongs to the view it was taken in. Any camera move retires
 * it, so the report never floats over water it does not describe. */
static void
lk_chart_controller_retire_pick (LkChartController *self)
{
  if (self->model != NULL)
    lk_app_model_clear_pick (self->model);
}

void
lk_chart_controller_set_view (LkChartController *self, lookout_view view)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;
  lookout_set_view (self->handle, &view);
  lk_chart_controller_retire_pick (self);
  lk_chart_controller_kick (self);
  self->last_readouts_us = 0;
  lk_chart_controller_push_readouts (self);
}

void
lk_chart_controller_fit_chart (LkChartController *self)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;

  lookout_view view;
  lookout_fit_chart (self->handle, &view);
  lk_chart_controller_set_view (self, view);
}

void
lk_chart_controller_resize (LkChartController *self, int width, int height)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL || width <= 0 || height <= 0)
    return;
  lookout_resize (self->handle, width, height);
  lk_chart_controller_kick (self);
}

void
lk_chart_controller_set_scale (LkChartController *self, int scale)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL || scale <= 0)
    return;
  lookout_set_pixel_density (self->handle, (float) scale);
  lk_chart_controller_sync_device_scale (self);
  lk_chart_controller_kick (self);
}

/* ---- interaction -------------------------------------------------------- */

void
lk_chart_controller_pan (LkChartController *self, double dx, double dy)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;
  lookout_pan_logical (self->handle, (float) dx, (float) dy);
  lk_chart_controller_retire_pick (self);
  lk_chart_controller_kick (self);
}

void
lk_chart_controller_zoom_at (LkChartController *self, double dzoom, double x, double y)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;
  lookout_zoom_at_logical (self->handle, dzoom, (float) x, (float) y);
  lk_chart_controller_retire_pick (self);
  lk_chart_controller_kick (self);
}

void
lk_chart_controller_zoom_centered (LkChartController *self, double dzoom)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL || self->view == NULL)
    return;

  int width, height;
  lk_chart_view_get_point_size (LK_CHART_VIEW (self->view), &width, &height);
  lk_chart_controller_zoom_at (self, dzoom, width / 2.0, height / 2.0);
}

void
lk_chart_controller_rotate_drag (LkChartController *self,
                                 double x0, double y0, double x1, double y1)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;
  lookout_rotate_drag_logical (self->handle, (float) x0, (float) y0, (float) x1, (float) y1);
  lk_chart_controller_retire_pick (self);
  lk_chart_controller_kick (self);
  self->last_readouts_us = 0;
  lk_chart_controller_push_readouts (self);
}

void
lk_chart_controller_reset_rotation (LkChartController *self)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;
  lookout_reset_rotation (self->handle);
  lk_chart_controller_retire_pick (self);
  lk_chart_controller_kick (self);
  self->last_readouts_us = 0;
  lk_chart_controller_push_readouts (self);
}

void
lk_chart_controller_fling_start (LkChartController *self, double vx, double vy)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;
  lookout_fling_start (self->handle, vx, vy);
  /* (0,0) is a grab stopping a coast, not a move: a tap must not retire the
   * report the same tap is about to open. */
  if (vx != 0 || vy != 0)
    lk_chart_controller_retire_pick (self);
  lk_chart_controller_kick (self);
}

gboolean
lk_chart_controller_geo_at (LkChartController *self,
                            double x, double y,
                            double *out_lon, double *out_lat)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), FALSE);

  if (self->handle == NULL)
    return FALSE;
  lookout_screen_to_geo (self->handle, (float) x, (float) y, out_lon, out_lat);
  return TRUE;
}

/* ---- mariner ------------------------------------------------------------ */

tile57_mariner
lk_chart_controller_get_mariner (LkChartController *self)
{
  tile57_mariner mariner;
  memset (&mariner, 0, sizeof mariner);

  if (LK_IS_CHART_CONTROLLER (self) && self->handle != NULL)
    lookout_get_mariner (self->handle, &mariner);
  else
    lookout_mariner_defaults (&mariner);

  return mariner;
}

void
lk_chart_controller_set_mariner (LkChartController *self, tile57_mariner mariner)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;
  lookout_set_mariner (self->handle, &mariner);
  lk_chart_controller_kick (self);
  self->last_readouts_us = 0;
  lk_chart_controller_push_readouts (self);
}

void
lk_chart_controller_sync_device_scale (LkChartController *self)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL || self->view == NULL)
    return;

  tile57_mariner mariner = lk_chart_controller_get_mariner (self);
  mariner.device_scale = gtk_widget_get_scale_factor (self->view);
  lookout_set_mariner (self->handle, &mariner);
  lk_chart_controller_kick (self);
}

#define LK_CONTROLLER_TOGGLE(name, call)                       \
  void                                                          \
  name (LkChartController *self)                                \
  {                                                             \
    g_return_if_fail (LK_IS_CHART_CONTROLLER (self));           \
    if (self->handle == NULL)                                   \
      return;                                                   \
    call (self->handle);                                        \
    lk_chart_controller_kick (self);                            \
    self->last_readouts_us = 0;                                 \
    lk_chart_controller_push_readouts (self);                   \
  }

LK_CONTROLLER_TOGGLE (lk_chart_controller_cycle_scheme, lookout_cycle_scheme)
LK_CONTROLLER_TOGGLE (lk_chart_controller_toggle_text, lookout_toggle_text)
LK_CONTROLLER_TOGGLE (lk_chart_controller_toggle_soundings, lookout_toggle_soundings)
LK_CONTROLLER_TOGGLE (lk_chart_controller_toggle_other_category, lookout_toggle_other_category)
LK_CONTROLLER_TOGGLE (lk_chart_controller_raster_cycle, lookout_raster_cycle)
LK_CONTROLLER_TOGGLE (lk_chart_controller_toggle_chart, lookout_toggle_chart)

#undef LK_CONTROLLER_TOGGLE

/* ---- raster underlay ---------------------------------------------------- */

void
lk_raster_set_free (LkRasterSet *set)
{
  if (set == NULL)
    return;
  g_free (set->name);
  g_free (set);
}

/* The engine's strings are borrowed and valid until the set list changes, so
 * every one of them is copied out here. */
static char *
lk_raster_dup (const char *text, size_t length)
{
  return g_strndup (text != NULL ? text : "", length);
}

gboolean
lk_chart_controller_raster_add (LkChartController *self, const char *path)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), FALSE);

  if (self->handle == NULL || path == NULL)
    return FALSE;

  gboolean added = lookout_raster_add (self->handle, path) != 0;
  if (added)
    lk_chart_controller_kick (self);
  return added;
}

void
lk_chart_controller_raster_select (LkChartController *self, int index)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;
  lookout_raster_select (self->handle, (int32_t) index);
  lk_chart_controller_kick (self);
}

void
lk_chart_controller_raster_set_shown (LkChartController *self, int index, gboolean shown)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL || index < 0)
    return;
  lookout_raster_set_shown (self->handle, (uint32_t) index, shown ? 1 : 0);
  lk_chart_controller_kick (self);
}

gboolean
lk_chart_controller_raster_set_enabled (LkChartController *self,
                                        const char        *path,
                                        gboolean           enabled)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), FALSE);

  if (self->handle == NULL || path == NULL)
    return FALSE;

  gboolean known = lookout_raster_set_enabled (self->handle, path, enabled ? 1 : 0) != 0;
  lk_chart_controller_kick (self);
  return known;
}

GPtrArray *
lk_chart_controller_raster_sets (LkChartController *self)
{
  GPtrArray *sets = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_raster_set_free);

  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), sets);

  if (self->handle == NULL)
    return sets;

  uint32_t count = lookout_raster_set_count (self->handle);
  for (uint32_t i = 0; i < count; i++)
    {
      size_t length = 0;
      const char *name = lookout_raster_set_name (self->handle, i, &length);
      LkRasterSet *set = g_new0 (LkRasterSet, 1);

      set->id = (int) i;
      set->name = lk_raster_dup (name, length);
      set->in_view = lookout_raster_set_in_view (self->handle, i) != 0;
      set->shown = lookout_raster_shown (self->handle, i) != 0;
      g_ptr_array_add (sets, set);
    }

  return sets;
}

int
lk_chart_controller_raster_active_index (LkChartController *self)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), -1);

  if (self->handle == NULL)
    return -1;
  return (int) lookout_raster_active_index (self->handle);
}

char *
lk_chart_controller_raster_active_name (LkChartController *self)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), g_strdup (""));

  if (self->handle == NULL)
    return g_strdup ("");

  size_t length = 0;
  const char *name = lookout_raster_active_name (self->handle, &length);
  return lk_raster_dup (name, length);
}

char *
lk_chart_controller_raster_available_name (LkChartController *self)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), g_strdup (""));

  if (self->handle == NULL)
    return g_strdup ("");

  size_t length = 0;
  const char *name = lookout_raster_available_name (self->handle, &length);
  return lk_raster_dup (name, length);
}

gboolean
lk_chart_controller_raster_over_chart (LkChartController *self)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), FALSE);

  if (self->handle == NULL)
    return FALSE;
  return lookout_raster_over_chart (self->handle) != 0;
}

void
lk_chart_controller_set_chart_hidden (LkChartController *self, gboolean hidden)
{
  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL)
    return;
  lookout_set_chart_hidden (self->handle, hidden ? 1 : 0);
  lk_chart_controller_kick (self);
}

gboolean
lk_chart_controller_chart_hidden (LkChartController *self)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), FALSE);

  if (self->handle == NULL)
    return FALSE;
  return lookout_chart_hidden (self->handle) != 0;
}

/* ---- pick --------------------------------------------------------------- */

static void
lk_pick_feature_cb (void       *ctx,
                    const char *cls, size_t cls_len,
                    const char *s57, size_t s57_len,
                    const char *chart, size_t chart_len)
{
  GPtrArray *results = ctx;
  LkPickFeature *feature = g_new0 (LkPickFeature, 1);

  feature->cls = g_strndup (cls != NULL ? cls : "", cls_len);
  feature->s57 = g_strndup (s57 != NULL ? s57 : "", s57_len);
  feature->chart = g_strndup (chart != NULL ? chart : "", chart_len);
  g_ptr_array_add (results, feature);
}

GPtrArray *
lk_chart_controller_pick (LkChartController *self, double lon, double lat)
{
  GPtrArray *results = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_pick_feature_free);

  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (self), results);

  if (self->handle == NULL)
    return results;

  tile57_query_cb cb = { .ctx = results, .feature = lk_pick_feature_cb };
  /* The ranked pick, not the raw one: the engine's own list is in draw order,
   * which puts the land area before the light that was tapped. The core drops
   * the meta objects that say nothing, demotes a feature the cell gave no
   * attributes, and states depths in the mariner's unit — once, for every
   * shell. */
  lookout_pick_ranked (self->handle, lon, lat, &cb);
  return results;
}

void
lk_chart_controller_aux_file (LkChartController *self,
                              const char        *cell,
                              const char        *name,
                              const guint8     **out_bytes,
                              gsize             *out_length,
                              const char       **out_mime)
{
  g_return_if_fail (out_bytes != NULL && out_length != NULL && out_mime != NULL);

  *out_bytes = NULL;
  *out_length = 0;
  *out_mime = NULL;

  g_return_if_fail (LK_IS_CHART_CONTROLLER (self));

  if (self->handle == NULL || cell == NULL || name == NULL)
    return;

  /* The bytes belong to the handle and stay valid until lookout_close. */
  lookout_aux_file (self->handle, cell, name, out_bytes, out_length, out_mime);
}
