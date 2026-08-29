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
}
