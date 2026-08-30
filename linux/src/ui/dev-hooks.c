/* ui/dev-hooks.c — the LOOKOUT_* hooks the screenshot script drives.
 *
 * Each one names a change to make once the window is up, optionally after a
 * delay, so a recording stages a change mid-take without a hand on the mouse.
 * They act through the same actions and model calls the mariner reaches, so
 * what a screenshot shows is what the app does.
 */
#include "ui/dev-hooks.h"

#include "library/links.h"

#include <stdio.h>
#include <string.h>

/* One deferred hook: the object it acts on and the value it carries. */
typedef struct {
  GObject *target; /* strong: the model, or the window */
  char    *value;
} LkDevHook;

static void
lk_dev_hook_free (gpointer data)
{
  LkDevHook *hook = data;

  g_object_unref (hook->target);
  g_free (hook->value);
  g_free (hook);
}

static gboolean
lk_dev_hook_add (gpointer data)
{
  LkDevHook *hook = data;
  const char *paths[] = { hook->value, NULL };

  lk_app_model_add_raster_charts (LK_APP_MODEL (hook->target), paths);
  return G_SOURCE_REMOVE;
}

static gboolean
lk_dev_hook_remove (gpointer data)
{
  LkDevHook *hook = data;

  lk_app_model_remove_raster_chart (LK_APP_MODEL (hook->target), hook->value);
  return G_SOURCE_REMOVE;
}

static gboolean
lk_dev_hook_chart_link (gpointer data)
{
  LkDevHook *hook = data;

  lk_chart_links_add (lk_app_model_get_chart_links (LK_APP_MODEL (hook->target)),
                      hook->value);
  return G_SOURCE_REMOVE;
}

static gboolean
lk_dev_hook_show (gpointer data)
{
  LkDevHook *hook = data;
  GActionGroup *actions = G_ACTION_GROUP (hook->target);
  const char *spec = hook->value;

  if (g_str_equal (spec, "settings"))
    g_action_group_activate_action (actions, "settings", NULL);
  else if (g_str_has_prefix (spec, "settings:"))
    g_action_group_activate_action (actions, "settings-at",
                                    g_variant_new_string (spec + strlen ("settings:")));
  else if (g_str_has_prefix (spec, "table:"))
    g_action_group_activate_action (actions, "open-table",
                                    g_variant_new_string (spec + strlen ("table:")));
  else if (g_str_equal (spec, "about"))
    g_action_group_activate_action (actions, "about", NULL);
  else if (g_str_equal (spec, "licenses"))
    g_action_group_activate_action (actions, "licenses", NULL);
  else if (g_str_has_prefix (spec, "licenses:"))
    g_action_group_activate_action (actions, "licenses-at",
                                    g_variant_new_string (spec + strlen ("licenses:")));
  else
    g_warning ("ignoring LOOKOUT_SHOW '%s' (want settings, settings:<tab>, "
               "table:<plugin>/<key>, about, licenses or licenses:<id>)", spec);
  return G_SOURCE_REMOVE;
}

/* "value[@seconds]": fire now, or that long after launch — which is how a
 * recording stages a change mid-take, and how table: waits for the plugins a
 * chart open loads. */
static void
lk_dev_hook_schedule (gpointer target, const char *spec, GSourceFunc fire)
{
  char *value = g_strdup (spec);
  char *at = strrchr (value, '@');
  guint delay_ms = 0;

  if (at != NULL)
    {
      char *end = NULL;
      double seconds = g_ascii_strtod (at + 1, &end);
      if (end != at + 1 && *end == '\0' && seconds >= 0)
        {
          *at = '\0';
          delay_ms = (guint) (seconds * 1000.0);
        }
    }
  if (value[0] == '\0')
    {
      g_free (value);
      return;
    }

  LkDevHook *hook = g_new0 (LkDevHook, 1);
  hook->target = g_object_ref (target);
  hook->value = value;
  g_timeout_add_full (G_PRIORITY_DEFAULT, delay_ms, fire, hook, lk_dev_hook_free);
}

/* ---- the pan and zoom stress run --------------------------------------- */

/* LOOKOUT_STRESS drives the camera the way a hand does, but without one, so a
 * run puts the renderer under sustained pan and zoom and says whether it came
 * out the other side. It exists because "I panned a bunch and it locked up" is
 * not a thing a widget suite can catch: the shell only forwards deltas, and
 * everything that can seize lives below it, in the chart engine and the driver.
 *
 * The verdict is the run itself. Every operation goes through the main loop, so
 * a renderer that stops answering stops this timer with it and the completion
 * line never comes. tests/stress.sh reads exactly that.
 *
 * The sequence is fixed, never random: a lock-up nobody can reproduce is a
 * lock-up nobody can fix. */
typedef struct {
  LkAppModel *model;
  GtkWindow  *window;  /* for the full-screen toggle; the swapchain rebuilds on it */
  int         total;
  int         done;
  int         fs_every; /* toggle full screen this often; 0 never */
  gint64      started_us;
} LkStress;

static void
lk_stress_free (gpointer data)
{
  LkStress *run = data;

  g_object_unref (run->model);
  g_clear_object (&run->window);
  g_free (run);
}

/* One step of the cycle. Eight directions so the camera never settles into one
 * axis, two magnitudes so it crosses tile boundaries at different rates, and a
 * zoom often enough to keep the tile set turning over — which is what a pan
 * around a chart actually costs the renderer. */
static gboolean
lk_stress_step (gpointer data)
{
  static const double dirs[8][2] = {
    { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 },
    { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 },
  };
  LkStress *run = data;
  LkChartController *c = lk_app_model_get_controller (run->model);

  if (c == NULL)
    return G_SOURCE_CONTINUE; /* no chart yet; the run has not started */

  const int i = run->done;
  const double *d = dirs[i % 8];
  const double step = (i % 16 < 8) ? 24.0 : 71.0;

  lk_chart_controller_pan (c, d[0] * step, d[1] * step);

  /* A fling every 32 steps: it coasts on the engine's own clock, so it keeps
     the camera moving between this timer's ticks rather than only on them. */
  if (i % 32 == 31)
    lk_chart_controller_fling_start (c, d[0] * 900.0, d[1] * 900.0);
  /* Zoom on the eighths, alternating, so the run does not walk off the chart
     and never comes back to any detail. */
  else if (i % 8 == 7)
    {
      if ((i / 8) % 2 == 0)
        lk_app_model_zoom_in (run->model);
      else
        lk_app_model_zoom_out (run->model);
    }
  /* Back to the whole chart now and then, which rebuilds the scene wholesale. */
  if (i % 256 == 255)
    lk_app_model_zoom_to_fit (run->model);

  /* Full screen resizes the surface, which rebuilds the swapchain under a
     camera that is still moving. That is the one moment a renderer has to get
     right and the hardest to reach by hand. */
  if (run->fs_every > 0 && i % run->fs_every == run->fs_every - 1 && run->window != NULL)
    {
      if (gtk_window_is_fullscreen (run->window))
        gtk_window_unfullscreen (run->window);
      else
        gtk_window_fullscreen (run->window);
    }

  run->done++;
  if (run->done % 100 == 0)
    g_message ("stress: %d of %d ops, zoom %.2f", run->done, run->total,
               lk_app_model_get_zoom (run->model));

  if (run->done < run->total)
    return G_SOURCE_CONTINUE;

  g_message ("stress: completed %d ops in %.1f s", run->done,
             (g_get_monotonic_time () - run->started_us) / 1e6);
  return G_SOURCE_REMOVE;
}

static gboolean
lk_dev_hook_stress (gpointer data)
{
  LkDevHook *hook = data;
  int ops = 0, interval_ms = 0, fs_every = 0;

  if (sscanf (hook->value, "%d,%d,%d", &ops, &interval_ms, &fs_every) < 1 || ops <= 0)
    {
      g_warning ("ignoring malformed LOOKOUT_STRESS '%s'"
                 " (want OPS[,INTERVAL_MS[,FULLSCREEN_EVERY]])", hook->value);
      return G_SOURCE_REMOVE;
    }
  if (interval_ms < 0)
    interval_ms = 0;
  if (fs_every < 0)
    fs_every = 0;

  LkStress *run = g_new0 (LkStress, 1);
  GtkWindow *window = g_object_get_data (hook->target, "lk-stress-window");

  run->model = g_object_ref (LK_APP_MODEL (hook->target));
  run->window = window != NULL ? g_object_ref (window) : NULL;
  run->total = ops;
  run->fs_every = fs_every;
  run->started_us = g_get_monotonic_time ();
  g_message ("stress: %d ops every %d ms, full screen every %d", ops, interval_ms, fs_every);
  g_timeout_add_full (G_PRIORITY_DEFAULT, (guint) interval_ms, lk_stress_step,
                      run, lk_stress_free);
  return G_SOURCE_REMOVE;
}

/* The screenshot/development hooks the other shells answer, as environment
 * variables so a script can stage a scene: size the window, open a settings
 * page or a plugin table, add or remove a raster chart mid-recording, or sail
 * on a chart link. LOOKOUT_OPEN and LOOKOUT_VIEW are read where they act;
 * LOOKOUT_MULTI and LOOKOUT_CLEAN where the app and the plugins come up. */
void
lk_window_apply_dev_hooks (LkWindow *self)
{
  const char *spec;

  if ((spec = g_getenv ("LOOKOUT_WINDOW")) != NULL)
    {
      int width = 0, height = 0;
      if (sscanf (spec, "%dx%d", &width, &height) == 2 && width >= 320 && height >= 240)
        gtk_window_set_default_size (GTK_WINDOW (self->window), width, height);
      else
        g_warning ("ignoring malformed LOOKOUT_WINDOW '%s' (want WxH)", spec);
    }

  if ((spec = g_getenv ("LOOKOUT_SHOW")) != NULL)
    lk_dev_hook_schedule (self->window, spec, lk_dev_hook_show);
  if ((spec = g_getenv ("LOOKOUT_ADD")) != NULL)
    lk_dev_hook_schedule (self->model, spec, lk_dev_hook_add);
  if ((spec = g_getenv ("LOOKOUT_REMOVE")) != NULL)
    lk_dev_hook_schedule (self->model, spec, lk_dev_hook_remove);
  if ((spec = g_getenv ("LOOKOUT_CHART_LINK")) != NULL)
    lk_dev_hook_schedule (self->model, spec, lk_dev_hook_chart_link);
  if ((spec = g_getenv ("LOOKOUT_STRESS")) != NULL)
    {
      /* The run acts on the model, and full screen acts on the window; the
         hook carries one target, so the window rides along on it. */
      g_object_set_data (G_OBJECT (self->model), "lk-stress-window", self->window);
      lk_dev_hook_schedule (self->model, spec, lk_dev_hook_stress);
    }
}
