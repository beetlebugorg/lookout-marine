#include "ui/window.h"
#include "ui/window-private.h"
#include "ui/dev-hooks.h"
#include "ui/open-dialogs.h"
#include "ui/startup-view.h"

#include "ui/chrome/about.h"
#include "ui/chrome/alerts.h"
#include "ui/chart/view.h"
#include "ui/hud/hud.h"
#include "ui/hud/pills.h"
#include "ui/hud/scale-bar.h"
#include "ui/chrome/licenses.h"
#include "ui/chart/overlay.h"
#include "plugins/install.h"
#include "ui/chart/pick-report.h"
#include "plugins/registry.h"
#include "util/tether.h"
#include "ui/chrome/search.h"
#include "ui/settings/window.h"
#include "ui/chrome/table-window.h"


static void
lk_window_free (gpointer data)
{
  LkWindow *self = data;

  g_clear_handle_id (&self->place_id, g_source_remove);
  g_clear_handle_id (&self->loader_pulse_id, g_source_remove);
  /* The weak pointer nulls this field when the settings window closes. If the
     field is still set, the settings window is still open and outlives the main
     window. Remove the registration first, or its teardown writes into this
     freed field. */
  if (self->settings_window != NULL)
    g_object_remove_weak_pointer (G_OBJECT (self->settings_window),
                                  (gpointer *) &self->settings_window);
  g_free (self);
}

/* ---- a file dropped on the window --------------------------------------- */

/* Every way in routes the same way, so a dropped weather file reaches the
 * plugin that reads it and a dropped folder of cells opens as a chart. */
static gboolean
lk_window_dropped (GtkDropTarget *target, const GValue *value, double x, double y,
                   gpointer user_data)
{
  LkWindow *self = user_data;

  if (!G_VALUE_HOLDS (value, G_TYPE_FILE))
    return FALSE;

  GFile *file = g_value_get_object (value);
  g_autofree char *path = file == NULL ? NULL : g_file_get_path (file);

  if (path == NULL)
    {
      lk_app_model_set_open_error (self->model,
                                   "That isn't a local file. The engine reads charts off "
                                   "the disk and needs a real path.");
      return FALSE;
    }

  lk_window_open_path (GTK_WINDOW (self->window), self->model, path);
  return TRUE;
}

/* ---- actions ------------------------------------------------------------ */

static void
lk_action_open (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_present_open_chart_dialog (GTK_WINDOW (self->window), self->model);
}

static void
lk_action_open_file (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;
  GtkFileDialog *dialog = gtk_file_dialog_new ();

  /* What the loaded plugins read goes in the title, so the mariner learns that
   * a weather file is openable here at all. GtkFileDialog carries no message
   * field, and the registry is read on demand because which plugins are live
   * changes with every chart open and every install. */
  g_autoptr (LkPlugins) plugins = lk_plugins_new (lk_app_model_get_controller (self->model));
  g_autofree char *types = lk_plugins_file_types (plugins);
  g_autofree char *title =
      types == NULL ? g_strdup ("Open a Chart or a Plugin")
                    : g_strdup_printf ("Open a Chart, a Plugin, or a Data File (%s)", types);

  gtk_file_dialog_set_title (dialog, title);
  gtk_file_dialog_set_modal (dialog, TRUE);
  gtk_file_dialog_set_accept_label (dialog, "Open");

  gtk_file_dialog_open (dialog, GTK_WINDOW (self->window), NULL, lk_open_file_chosen, self->model);
  g_object_unref (dialog);
}

static void
lk_action_open_archive (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_present_open_archive_dialog (GTK_WINDOW (self->window), self->model);
}

/* One set's toggle in the Charts submenu. Each set has its own boolean action,
   so GTK draws it as an independent checkbox. */
static void
lk_action_chart_set_toggle (GSimpleAction *action, GVariant *value, gpointer user_data)
{
  LkWindow *self = user_data;
  const char *path = g_object_get_data (G_OBJECT (action), "lk-set-path");

  g_simple_action_set_state (action, value);
  if (path != NULL)
    lk_app_model_set_chart_set_on (self->model, path, g_variant_get_boolean (value));
}

static void
lk_action_forget_raster (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  lk_app_model_forget_raster_charts (((LkWindow *) user_data)->model);
}

static void
lk_action_zoom_in (GSimpleAction *a, GVariant *p, gpointer d)  { lk_app_model_zoom_in (((LkWindow *) d)->model); }
static void
lk_action_zoom_out (GSimpleAction *a, GVariant *p, gpointer d) { lk_app_model_zoom_out (((LkWindow *) d)->model); }
static void
lk_action_zoom_fit (GSimpleAction *a, GVariant *p, gpointer d) { lk_app_model_zoom_to_fit (((LkWindow *) d)->model); }
static void
lk_action_north_up (GSimpleAction *a, GVariant *p, gpointer d) { lk_app_model_north_up (((LkWindow *) d)->model); }
static void
lk_action_cycle_scheme (GSimpleAction *a, GVariant *p, gpointer d) { lk_app_model_cycle_scheme (((LkWindow *) d)->model); }
static void
lk_action_toggle_text (GSimpleAction *a, GVariant *p, gpointer d) { lk_app_model_toggle_text (((LkWindow *) d)->model); }
static void
lk_action_toggle_soundings (GSimpleAction *a, GVariant *p, gpointer d) { lk_app_model_toggle_soundings (((LkWindow *) d)->model); }
static void
lk_action_toggle_other (GSimpleAction *a, GVariant *p, gpointer d) { lk_app_model_toggle_other_category (((LkWindow *) d)->model); }
/* The compass bubble's own click goes straight to the model; this is the
 * keyboard's way in to the same cycle. */
static void
lk_action_follow (GSimpleAction *a, GVariant *p, gpointer d) { lk_app_model_cycle_orientation (((LkWindow *) d)->model); }

/* ---- raster charts ------------------------------------------------------ */

/* The cycle has nowhere to go with nothing installed, so the key press offers
 * the picker rather than doing nothing at all. */
static void
lk_action_raster_cycle (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  if (lk_app_model_get_raster_count (self->model) == 0)
    {
      lk_present_add_raster_dialog (GTK_WINDOW (self->window), self->model);
      return;
    }

  lk_app_model_cycle_raster (self->model);
}

static void
lk_action_raster_select (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_app_model_select_raster_set (self->model, g_variant_get_int32 (parameter));
}

static void
lk_action_raster_add (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_present_add_raster_dialog (GTK_WINDOW (self->window), self->model);
}

static void
lk_action_raster_add_folder (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_present_add_raster_folder_dialog (GTK_WINDOW (self->window), self->model);
}

static void
lk_action_toggle_chart (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_app_model_toggle_chart (self->model);
}

static void
lk_action_set_scheme (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_app_model_set_scheme (self->model, (int) g_variant_get_int32 (parameter));
  g_simple_action_set_state (action, parameter);
}

static void
lk_action_search (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_search_toggle (self->search);
}

/* Escape clears whatever the last click put on the chart, whichever it was. */
static void
lk_action_close_pick (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_app_model_clear_pick (self->model);
  lk_app_model_pin_overlay (self->model, NULL);
}

/* The reference's Escape cascade, one thing per press: the chart menu first
 * (its marker rename field goes with it), then a pinned bubble, then the pick
 * report. A picture viewer would sit between them; Linux has none yet. The
 * controller runs in the capture phase, ahead of the chart view, so the order
 * is fixed here rather than left to who happens to consume the key. */
static gboolean
lk_window_escape (GtkEventControllerKey *controller, guint keyval, guint keycode,
                  GdkModifierType state, gpointer user_data)
{
  LkWindow *self = user_data;
  double x, y;

  if (keyval != GDK_KEY_Escape)
    return GDK_EVENT_PROPAGATE;

  if (lk_search_is_open (self->search))
    {
      lk_search_close (self->search);
      return GDK_EVENT_STOP;
    }
  if (lk_chart_view_dismiss (LK_CHART_VIEW (self->chart_view)))
    return GDK_EVENT_STOP;
  if (lk_app_model_get_overlay_pin (self->model) != NULL)
    {
      lk_app_model_pin_overlay (self->model, NULL);
      return GDK_EVENT_STOP;
    }
  if (lk_app_model_get_pick_point (self->model, &x, &y))
    {
      lk_app_model_clear_pick (self->model);
      return GDK_EVENT_STOP;
    }
  return GDK_EVENT_PROPAGATE;
}

static void
lk_window_present_settings (LkWindow *self, const char *section)
{
  if (self->settings_window == NULL)
    {
      self->settings_window =
          lk_settings_window_new (self->model, GTK_WINDOW (self->window), section);
      g_object_add_weak_pointer (G_OBJECT (self->settings_window),
                                 (gpointer *) &self->settings_window);
    }

  gtk_window_present (GTK_WINDOW (self->settings_window));
}

/* The panel on its first section. The gear bubble, Ctrl+, and the screenshot
 * protocol all take this one, and it carries no parameter so all three can
 * activate it bare. */
static void
lk_action_settings (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  lk_window_present_settings (user_data, NULL);
}

/* The panel on one named section. A FIX-IT NAMES THE SECTION THAT FIXES IT:
 * the position readout's "Configure GPS" asks for Connections, because that is
 * where a position source is added. */
static void
lk_action_settings_at (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  lk_window_present_settings (user_data, g_variant_get_string (parameter, NULL));
}

/* What this build is, and the terms it carries. The licenses are a legal
 * obligation, so they are reachable from the commands bubble and from the
 * About window both, as they are on the Mac. */
static void
lk_action_about (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_about_window_present (GTK_WINDOW (self->window));
}

static void
lk_action_licenses (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_licenses_window_present (GTK_WINDOW (self->window), NULL);
}

/* The licenses on one component's entry, by the id the manifest gives it. */
static void
lk_action_licenses_at (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_licenses_window_present (GTK_WINDOW (self->window),
                              g_variant_get_string (parameter, NULL));
}

/* ---- the commands bubble ------------------------------------------------ */

/* One table a plugin declared, by "<plugin>/<key>". The declarations are read
 * when the menu is built, so a plugin installed a moment ago is in it. */
static void
lk_action_open_table (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;
  const char *id = g_variant_get_string (parameter, NULL);
  g_autoptr (GPtrArray) specs = lk_table_specs (self->model);

  for (guint i = 0; i < specs->len; i++)
    {
      const LkTableSpec *spec = g_ptr_array_index (specs, i);
      g_autofree char *key = g_strdup_printf ("%s/%s", spec->plugin, spec->key);

      if (g_strcmp0 (key, id) == 0)
        {
          lk_table_window_present (GTK_WINDOW (self->window), self->model, spec);
          return;
        }
    }
}

static void
lk_action_install_plugin (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_plugin_install_choose (GTK_WINDOW (self->window), self->model, NULL, NULL);
}

static void
lk_action_full_screen (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  if (gtk_window_is_fullscreen (GTK_WINDOW (self->window)))
    gtk_window_unfullscreen (GTK_WINDOW (self->window));
  else
    gtk_window_fullscreen (GTK_WINDOW (self->window));
}

static const GActionEntry lk_window_actions[] = {
  { "open",             lk_action_open },
  { "open-archive",     lk_action_open_archive },
  { "open-file",        lk_action_open_file },
  { "forget-raster",    lk_action_forget_raster },
  { "zoom-in",          lk_action_zoom_in },
  { "zoom-out",         lk_action_zoom_out },
  { "zoom-fit",         lk_action_zoom_fit },
  { "north-up",         lk_action_north_up },
  { "cycle-scheme",     lk_action_cycle_scheme },
  { "toggle-text",      lk_action_toggle_text },
  { "toggle-soundings", lk_action_toggle_soundings },
  { "toggle-other",     lk_action_toggle_other },
  { "follow",           lk_action_follow },
  { "search",           lk_action_search },
  { "close-pick",       lk_action_close_pick },
  { "settings",         lk_action_settings },
  { "settings-at",      lk_action_settings_at, "s" },
  { "about",            lk_action_about },
  { "licenses",         lk_action_licenses },
  { "licenses-at",      lk_action_licenses_at, "s" },
  { "set-scheme",       lk_action_set_scheme, "i", "0" },
  { "raster-cycle",     lk_action_raster_cycle },
  /* Stateful, so the pill's list marks the set that is drawn. The state is the
   * index the engine reports, pushed back on every raster change. */
  { "raster-select",    lk_action_raster_select, "i", "-1" },
  { "raster-add",       lk_action_raster_add },
  { "raster-add-folder", lk_action_raster_add_folder },
  { "toggle-chart",     lk_action_toggle_chart },
  { "open-table",       lk_action_open_table, "s" },
  { "install-plugin",   lk_action_install_plugin },
  { "full-screen",      lk_action_full_screen },
};

/* ---- the commands menu -------------------------------------------------- */

/* The Mac takes its menus from the system bar, which stands outside the window.
 * Linux has no such bar, and a menu bar inside the window would take a strip of
 * water on every screen of an app whose whole point is the chart. So the
 * commands hang off a bubble in the same chrome the zoom and the compass live
 * in, which is the shape the WinUI shell wears and the one the phone shells can
 * wear too.
 *
 * The items are the Mac's, in the Mac's order, saying the Mac's words
 * (macos/LookoutMarine/Commands.swift).
 *
 * The list is BUILT FRESH on every press, because most of it names things that
 * come and go: the charts opened lately, the raster sets covering THIS view,
 * and the tables the plugins declare. */
static GMenuModel *
lk_window_build_chart_menu (LkWindow *self)
{
  GMenu *chart = g_menu_new ();
  GMenu *scheme = g_menu_new ();

  g_menu_append (scheme, "Day", "win.set-scheme(0)");
  g_menu_append (scheme, "Dusk", "win.set-scheme(1)");
  g_menu_append (scheme, "Night", "win.set-scheme(2)");
  g_menu_append (scheme, "Cycle", "win.cycle-scheme");
  /* "Color Scheme" in the menu, the reference's American spelling, while the
     settings header keeps "Colour scheme" — each mirrors macOS as it is. */
  g_menu_append_submenu (chart, "Color Scheme", G_MENU_MODEL (scheme));

  /* Charts: a toggle per set, disabled when the library is empty. Each set gets
     its own boolean action, rebuilt with the menu, so GTK draws independent
     checkboxes rather than a radio group. The old actions are removed first, so
     a shrunk library leaves none behind. */
  for (guint i = 0; i < self->chart_set_actions; i++)
    {
      g_autofree char *old = g_strdup_printf ("chart-set-%u", i);
      g_action_map_remove_action (G_ACTION_MAP (self->window), old);
    }
  GMenu *charts = g_menu_new ();
  g_autoptr (GPtrArray) csets = lk_app_model_get_chart_sets (self->model);
  for (guint i = 0; i < csets->len; i++)
    {
      const LkChartSetRow *set = g_ptr_array_index (csets, i);
      g_autofree char *name = g_strdup_printf ("chart-set-%u", i);
      g_autofree char *full = g_strdup_printf ("win.chart-set-%u", i);
      GSimpleAction *act =
          g_simple_action_new_stateful (name, NULL, g_variant_new_boolean (set->on));

      g_object_set_data_full (G_OBJECT (act), "lk-set-path", g_strdup (set->path), g_free);
      g_signal_connect (act, "change-state", G_CALLBACK (lk_action_chart_set_toggle), self);
      g_action_map_add_action (G_ACTION_MAP (self->window), G_ACTION (act));
      g_object_unref (act);
      g_menu_append (charts, set->title, full);
    }
  self->chart_set_actions = csets->len;
  if (csets->len == 0)
    g_menu_append (charts, "No chart sets", "win.none"); /* absent action → insensitive */
  g_menu_append_submenu (chart, "Charts", G_MENU_MODEL (charts));
  g_object_unref (charts);

  /* The raster sets covering THIS view, the drawn one marked, then the way back
   * to no picture at all. It is the same list the pill opens. */
  GMenu *raster = g_menu_new ();
  GPtrArray *sets = lk_app_model_get_raster_sets (self->model);
  for (guint i = 0; sets != NULL && i < sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (sets, i);

      if (!set->in_view)
        continue;

      g_autofree char *action = g_strdup_printf ("win.raster-select(%d)", set->id);
      g_menu_append (raster, set->name, action);
    }
  g_menu_append (raster, "None", "win.raster-select(-1)");

  GMenu *raster_section = g_menu_new ();
  g_menu_append_submenu (raster_section, "Raster Chart", G_MENU_MODEL (raster));
  g_menu_append (raster_section, "Next Raster Chart", "win.raster-cycle");
  g_menu_append (raster_section, "Add Raster Charts…", "win.raster-add");
  g_menu_append (raster_section, "Add a Folder of Raster Charts…", "win.raster-add-folder");
  g_menu_append (raster_section,
                 lk_app_model_get_chart_hidden (self->model) ? "Show ENC Over Raster"
                                                             : "Hide ENC Over Raster",
                 "win.toggle-chart");
  /* Forget every installed raster chart. The count says whether there is
     anything to forget; with none the item is left out. */
  guint raster_count = lk_app_model_get_raster_count (self->model);
  if (raster_count > 0)
    {
      g_autofree char *label = g_strdup_printf ("Forget Raster Charts (%u)", raster_count);
      g_autoptr (GMenuItem) forget = g_menu_item_new (label, "win.forget-raster");
      /* GMenu carries no tooltip, so the effect is stated in the label's own
         section rather than lost. */
      g_menu_append_item (raster_section, forget);
    }
  g_menu_append_section (chart, NULL, G_MENU_MODEL (raster_section));

  GMenu *view = g_menu_new ();
  g_menu_append (view, "Zoom In", "win.zoom-in");
  g_menu_append (view, "Zoom Out", "win.zoom-out");
  g_menu_append (view, "Zoom to Fit", "win.zoom-fit");
  g_menu_append (view, "Rotate to North-Up", "win.north-up");
  g_menu_append_section (chart, NULL, G_MENU_MODEL (view));

  GMenu *toggles = g_menu_new ();
  g_menu_append (toggles, "Toggle Text", "win.toggle-text");
  g_menu_append (toggles, "Toggle Soundings", "win.toggle-soundings");
  g_menu_append (toggles, "Toggle Other Category", "win.toggle-other");
  g_menu_append_section (chart, NULL, G_MENU_MODEL (toggles));

  g_object_unref (scheme);
  g_object_unref (raster);
  g_object_unref (raster_section);
  g_object_unref (view);
  g_object_unref (toggles);
  return G_MENU_MODEL (chart);
}

/* One item per table a plugin declared. Every declaration lands here whatever
 * its own `menu` field says, until there is a second place to put one. */
static GMenuModel *
lk_window_build_vessels_menu (LkWindow *self)
{
  GMenu *vessels = g_menu_new ();
  g_autoptr (GPtrArray) specs = lk_table_specs (self->model);

  for (guint i = 0; i < specs->len; i++)
    {
      const LkTableSpec *spec = g_ptr_array_index (specs, i);
      g_autofree char *title = g_strdup_printf ("%s…", spec->title);
      g_autofree char *id = g_strdup_printf ("%s/%s", spec->plugin, spec->key);
      g_autoptr (GVariant) target = g_variant_new_string (id);
      g_autoptr (GMenuItem) item = g_menu_item_new (title, NULL);

      g_menu_item_set_action_and_target_value (item, "win.open-table",
                                               g_steal_pointer (&target));
      g_menu_append_item (vessels, item);
    }

  if (specs->len == 0)
    {
      /* A disabled item still says what the menu is for, which an empty menu
       * does not. There is no action, so it never fires. */
      g_menu_append (vessels, "No Vessel Tables", NULL);
    }

  return G_MENU_MODEL (vessels);
}

static void
lk_window_fill_menu (GtkMenuButton *button, gpointer user_data)
{
  LkWindow *self = user_data;
  GMenu *menu = g_menu_new ();
  g_autoptr (GMenuModel) chart = lk_window_build_chart_menu (self);
  g_autoptr (GMenuModel) vessels = lk_window_build_vessels_menu (self);

  g_menu_append_submenu (menu, "Chart", chart);
  g_menu_append_submenu (menu, "Vessels", vessels);

  GMenu *files = g_menu_new ();
  g_menu_append (files, "Open Chart Folder…", "win.open");
  g_menu_append (files, "Open Chart Archive…", "win.open-archive");
  g_menu_append (files, "Open a File…", "win.open-file");
  g_menu_append (files, "Install Plugin…", "win.install-plugin");
  g_menu_append_section (menu, NULL, G_MENU_MODEL (files));

  GMenu *app = g_menu_new ();
  g_menu_append (app,
                 gtk_window_is_fullscreen (GTK_WINDOW (self->window)) ? "Leave Full Screen"
                                                                     : "Full Screen",
                 "win.full-screen");
  g_menu_append (app, "Settings…", "win.settings");
  g_menu_append_section (menu, NULL, G_MENU_MODEL (app));

  /* What this build is, and its terms. The Mac's words, in the place a GNOME
   * menu carries them: last, in their own section. */
  GMenu *info = g_menu_new ();
  g_menu_append (info, "About Lookout Marine", "win.about");
  g_menu_append (info, "Licenses…", "win.licenses");
  g_menu_append_section (menu, NULL, G_MENU_MODEL (info));

  gtk_menu_button_set_menu_model (button, G_MENU_MODEL (menu));

  g_object_unref (files);
  g_object_unref (app);
  g_object_unref (info);
  g_object_unref (menu);
}

/* ---- model-driven chrome ------------------------------------------------ */

/* 7217 → "7,217", the same grouping the scale readout uses. */
static char *
lk_group_number (guint value)
{
  g_autofree char *plain = g_strdup_printf ("%u", value);
  GString *grouped = g_string_new (NULL);

  lk_append_grouped (grouped, plain);
  return g_string_free (grouped, FALSE);
}

static void
lk_window_chart_sets_changed (LkAppModel *model, gpointer user_data)
{
  LkWindow *self = user_data;

  if (gtk_widget_in_destruction (self->window))
    return;
  lk_window_refresh_switched_off (self);
}

static void
lk_window_update_overlays (LkWindow *self)
{
  gboolean loading = lk_app_model_get_show_startup_loader (self->model);
  gboolean has_chart = lk_app_model_get_has_chart (self->model);
  gboolean baking = lk_app_model_get_baking (self->model);

  /* Without a chart these commands have nothing to act on, so their bubbles
   * and menu items grey out — as the reference's do. Search stays: the go-to
   * works from an empty view. */
  static const char *chart_actions[] = {
    "zoom-in", "zoom-out", "zoom-fit", "north-up", "follow",
    "cycle-scheme", "set-scheme", "toggle-text", "toggle-soundings",
    "toggle-other", "toggle-chart",
  };
  for (gsize i = 0; i < G_N_ELEMENTS (chart_actions); i++)
    {
      GAction *action = g_action_map_lookup_action (G_ACTION_MAP (self->window),
                                                    chart_actions[i]);
      if (action != NULL)
        g_simple_action_set_enabled (G_SIMPLE_ACTION (action), has_chart);
    }

  gboolean loader_up = loading && !baking;
  gtk_widget_set_visible (self->loader, loader_up);
  /* Pulse the indeterminate bar while the loader is up, and stop when it goes.
     Idle means idle: no timer runs once the chart is open. */
  if (loader_up && self->loader_pulse_id == 0)
    self->loader_pulse_id = g_timeout_add (120, lk_window_loader_pulse, self);
  else if (!loader_up)
    g_clear_handle_id (&self->loader_pulse_id, g_source_remove);
  /* Nothing is open DURING a bake either, but "No chart open" beside a card
     offering to open one is the wrong thing to say while the app is already
     busy preparing the charts the mariner just picked. The import pill is the
     status; this stays out of its way until there is a decision to make. */
  gtk_widget_set_visible (self->empty_state, !loading && !has_chart && !baking);
  /* No chart, no readouts: a capsule reading 1:— over an empty view is chrome
   * with nothing to report. */
  gtk_widget_set_visible (self->capsule, has_chart);
  /* The scale bar also hides itself when the denominator is not positive (see
     lk_scale_bar_update), so this is the coarse gate and that is the fine one.
     They agree: no chart means no denominator. */
  gtk_widget_set_visible (self->scale_bar, has_chart);

  /* A hidden empty state drops its inline error with it: the sentence
   * belonged to the press that raised it. */
  if (loading || has_chart || baking)
    gtk_widget_set_visible (g_object_get_data (G_OBJECT (self->empty_state), "lk-error"),
                            FALSE);

  if (loading && !baking)
    {
      /* Which of the three waits this is. The atlas bake happens on the first
       * run only, so on every other run it reads done rather than skipped. */
      guint cells = lk_app_model_get_opening_cells (self->model);
      int step = lk_app_model_get_preparing_symbols (self->model) ? 0
                 : lk_app_model_get_opening (self->model)         ? 1
                                                                  : 2;
      g_autofree char *count = lk_group_number (cells);
      g_autofree char *opening = cells > 1 ? g_strdup_printf ("Opening %s charts", count)
                                           : g_strdup ("Opening the chart");
      g_autofree char *mapping = cells > 1 ? g_strdup_printf ("Mapping %s cells", count)
                                           : g_strdup ("Mapping the chart");

      GtkWidget *title = g_object_get_data (G_OBJECT (self->loader), "lk-title");
      gtk_label_set_text (GTK_LABEL (title), opening);
      lk_loader_step_set (g_object_get_data (G_OBJECT (self->loader), "lk-step0"),
                          step > 0 ? 2 : 1, "Preparing chart symbols",
                          step > 0 ? "" : "first run only");
      lk_loader_step_set (g_object_get_data (G_OBJECT (self->loader), "lk-step1"),
                          step > 1 ? 2 : (step == 1 ? 1 : 0), mapping,
                          step == 1 ? "not loading them, so this is quick" : "");
      lk_loader_step_set (g_object_get_data (G_OBJECT (self->loader), "lk-step2"),
                          step == 2 ? 1 : 0, "Drawing the first scene", "");
    }
}

/* ---- the pick ----------------------------------------------------------- */

static void
lk_window_drop_pick_widgets (LkWindow *self)
{
  if (self->pick_marker != NULL)
    {
      gtk_overlay_remove_overlay (GTK_OVERLAY (self->overlay), self->pick_marker);
      self->pick_marker = NULL;
    }
  if (self->pick_report != NULL)
    {
      gtk_overlay_remove_overlay (GTK_OVERLAY (self->overlay), self->pick_report);
      self->pick_report = NULL;
    }
}

/* Places the mark and the report against the pick point in the current view.
 * The report widget must already exist; this sets only margins and alignment,
 * so a resize re-runs it without rebuilding the card. The mark sits at the
 * pick point; the report stands beside it as a callout, or across the bottom
 * as a sheet when the report is compact. */
static void
lk_window_place_pick_widgets (LkWindow *self, double x, double y,
                              int view_width, int view_height)
{
  gtk_widget_set_margin_start (self->pick_marker, MAX (0, (int) (x - LK_PICK_MARKER_SIZE / 2)));
  gtk_widget_set_margin_top (self->pick_marker, MAX (0, (int) (y - LK_PICK_MARKER_SIZE / 2)));

  if (self->pick_compact)
    {
      gtk_widget_set_halign (self->pick_report, GTK_ALIGN_CENTER);
      gtk_widget_set_valign (self->pick_report, GTK_ALIGN_END);
      gtk_widget_set_margin_start (self->pick_report, 0);
      gtk_widget_set_margin_top (self->pick_report, 0);
      gtk_widget_set_margin_bottom (self->pick_report, LK_HUD_BAND);
      return;
    }

  LkCalloutPlace place =
      lk_callout_place (x, y, self->pick_width, view_width, view_height, LK_HUD_BAND);

  /* The card holds one edge against the mark and the layout places the
   * opposite edge, so nothing here has to measure the card's height. The
   * callout can flip sides on a resize, so clear the margin it is not using. */
  gtk_widget_set_halign (self->pick_report, GTK_ALIGN_START);
  gtk_widget_set_margin_start (self->pick_report, MAX (0, (int) place.x));

  if (place.edge == LK_CALLOUT_ABOVE)
    {
      gtk_widget_set_valign (self->pick_report, GTK_ALIGN_END);
      gtk_widget_set_margin_top (self->pick_report, 0);
      gtk_widget_set_margin_bottom (self->pick_report, MAX (0, (int) (view_height - place.y)));
    }
  else
    {
      gtk_widget_set_valign (self->pick_report, GTK_ALIGN_START);
      gtk_widget_set_margin_top (self->pick_report, MAX (0, (int) place.y));
      gtk_widget_set_margin_bottom (self->pick_report, 0);
    }
}

/* The width the report needs for the current pick and view. Compact mode is
 * reported through out_compact. */
static int
lk_window_pick_width (LkWindow *self, int view_width, int view_height, gboolean *out_compact)
{
  /* A narrow window takes the report as a SHEET across the bottom rather than a
   * callout beside the mark: a callout squeezed into a phone-shaped window
   * covers the very water it describes. The same rule the compact capsule
   * follows, at the same width. */
  if (view_width < LK_CHROME_COMPACT_WIDTH)
    {
      *out_compact = TRUE;
      return view_width - 2 * LK_CHROME_MARGIN;
    }

  GPtrArray *results = lk_app_model_get_pick_results (self->model);
  *out_compact = FALSE;
  return lk_pick_report_width (results->len, view_width);
}

/* The mark on the object, and the report beside it, built for the pick. A pick
 * is a new set of objects, and how many there are decides the card's shape, so
 * the widgets are new. A later resize re-places them without this rebuild. */
static void
lk_window_update_pick (LkWindow *self)
{
  double x, y;
  int view_width = lk_app_model_get_view_width (self->model);
  int view_height = lk_app_model_get_view_height (self->model);

  lk_window_drop_pick_widgets (self);

  if (!lk_app_model_get_pick_point (self->model, &x, &y))
    return;
  if (view_width <= 1 || view_height <= 1)
    return;

  gboolean compact = FALSE;
  int width = lk_window_pick_width (self, view_width, view_height, &compact);
  int room = compact ? (int) (view_height * 0.45)
                     : (int) lk_callout_place (x, y, width, view_width, view_height,
                                               LK_HUD_BAND).room;

  self->pick_marker = lk_pick_marker_new ();
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->pick_marker);

  self->pick_report = lk_pick_report_new (self->model, width, room);
  self->pick_width = width;
  self->pick_compact = compact;
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->pick_report);

  lk_window_place_pick_widgets (self, x, y, view_width, view_height);
}

/* The resize path. The report keeps its built width and its height cap, so a
 * resize that does not change the width re-places the existing card. A width or
 * mode change falls back to a full rebuild. */
static gboolean
lk_window_place_pick_idle (gpointer user_data)
{
  LkWindow *self = user_data;
  double x, y;
  int view_width = lk_app_model_get_view_width (self->model);
  int view_height = lk_app_model_get_view_height (self->model);

  self->place_id = 0;

  if (self->pick_report == NULL || !lk_app_model_get_pick_point (self->model, &x, &y) ||
      view_width <= 1 || view_height <= 1)
    return G_SOURCE_REMOVE;

  gboolean compact = FALSE;
  int width = lk_window_pick_width (self, view_width, view_height, &compact);
  if (width != self->pick_width || compact != self->pick_compact)
    lk_window_update_pick (self);
  else
    lk_window_place_pick_widgets (self, x, y, view_width, view_height);

  return G_SOURCE_REMOVE;
}

/* The view size arrives during the chart view's allocation, and adding an
 * overlay child there would resize a widget mid-layout. Re-place on the next
 * idle instead. */
static void
lk_window_queue_place_pick (LkWindow *self)
{
  if (self->pick_report == NULL || self->place_id != 0)
    return;
  self->place_id = g_idle_add (lk_window_place_pick_idle, self);
}

static void
lk_window_pick_changed (LkAppModel *model, gpointer user_data)
{
  LkWindow *self = user_data;

  if (gtk_widget_in_destruction (self->window))
    return;
  lk_window_update_pick (self);
}

/* Follow re-projected the open pick's mark. The mark alone: the report's
 * frame is fixed for the report's life, so a moving boat can still read it. */
static void
lk_window_pick_moved (LkAppModel *model, gpointer user_data)
{
  LkWindow *self = user_data;
  double x, y;

  if (gtk_widget_in_destruction (self->window) || self->pick_marker == NULL)
    return;
  if (!lk_app_model_get_pick_point (model, &x, &y))
    return;
  gtk_widget_set_margin_start (self->pick_marker, MAX (0, (int) (x - LK_PICK_MARKER_SIZE / 2)));
  gtk_widget_set_margin_top (self->pick_marker, MAX (0, (int) (y - LK_PICK_MARKER_SIZE / 2)));
}

/* The engine owns which set is drawn: the cycle key, a chart opening and a
 * chart switched off all move it. Push it back into the action, so the list the
 * pill opens marks the picture actually on the screen. */
static void
lk_window_raster_changed (LkAppModel *model, gpointer user_data)
{
  LkWindow *self = user_data;
  GAction *action = NULL;

  if (gtk_widget_in_destruction (self->window))
    return;
  action = g_action_map_lookup_action (G_ACTION_MAP (self->window), "raster-select");

  if (action != NULL)
    {
      g_simple_action_set_state (G_SIMPLE_ACTION (action),
                                 g_variant_new_int32 (lk_app_model_get_raster_active (model)));
      /* The picker offers nothing until a raster chart is installed. The
       * cycle stays enabled: with nothing installed it opens the Add picker
       * instead, which lk_action_raster_cycle explains. */
      g_simple_action_set_enabled (G_SIMPLE_ACTION (action),
                                   lk_app_model_get_raster_count (model) > 0);
    }
}

static void
lk_window_show_open_error (LkWindow *self)
{
  g_autofree char *message = NULL;

  g_object_get (self->model, "open-error", &message, NULL);
  if (message == NULL)
    return;

  if (gtk_widget_get_visible (self->empty_state))
    {
      /* The mariner pressed the button on the first-run page; the sentence
       * belongs there, not in an alert floating over an empty window. */
      GtkWidget *error = g_object_get_data (G_OBJECT (self->empty_state), "lk-error");
      gtk_label_set_text (GTK_LABEL (error), message);
      gtk_widget_set_visible (error, TRUE);
    }
  else
    {
      GtkAlertDialog *dialog = gtk_alert_dialog_new ("Couldn't open chart");
      gtk_alert_dialog_set_detail (dialog, message);
      gtk_alert_dialog_show (dialog, GTK_WINDOW (self->window));
      g_object_unref (dialog);
    }

  lk_app_model_set_open_error (self->model, NULL);
}

/* The chrome follows the chart into dusk and night. The chart dims itself to
 * protect night vision, and a bright theme floating over it would undo that:
 * dusk and night take the dark theme (every chrome fill rides
 * @theme_bg_color, so the flip carries the capsule and the bubbles), and
 * night stamps a class the stylesheet quiets further. Day gives back
 * whatever the desktop preferred. */
static void
lk_window_apply_scheme (LkWindow *self)
{
  int scheme = lk_app_model_get_scheme (self->model);
  GtkSettings *settings = gtk_widget_get_settings (self->window);

  g_object_set (settings, "gtk-application-prefer-dark-theme",
                scheme != 0 || self->desktop_prefers_dark, NULL);
  if (scheme == 2)
    gtk_widget_add_css_class (self->window, "lk-night");
  else
    gtk_widget_remove_css_class (self->window, "lk-night");

  /* The menu radio tracks the chart's scheme. A cycle (Ctrl+L) or a load
     changes the scheme without touching the action, so push the state back
     here — the same way raster-select follows the active set. */
  GAction *action = g_action_map_lookup_action (G_ACTION_MAP (self->window),
                                                "set-scheme");
  if (action != NULL)
    g_simple_action_set_state (G_SIMPLE_ACTION (action),
                               g_variant_new_int32 (scheme));
}

static void
lk_window_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  LkWindow *self = user_data;
  const char *name = g_param_spec_get_name (pspec);

  /* The close path fires notifies from inside the widget teardown (unrealize
     closes the controller, which drops has-chart); touching half-disposed
     children from here is the crash this guards. */
  if (gtk_widget_in_destruction (self->window))
    return;

  if (g_str_equal (name, "show-startup-loader") || g_str_equal (name, "has-chart") ||
      g_str_equal (name, "baking"))
    lk_window_update_overlays (self);
  else if (g_str_equal (name, "view-width") || g_str_equal (name, "view-height"))
    lk_window_queue_place_pick (self);
  else if (g_str_equal (name, "open-error"))
    lk_window_show_open_error (self);
  else if (g_str_equal (name, "scheme"))
    lk_window_apply_scheme (self);
}

/* ---- titlebar ----------------------------------------------------------- */

/* The titlebar carries the chart's name and the window controls, and nothing
 * else. Every control that acts on the chart is a bubble over the chart, where
 * the SwiftUI, WinUI and Compose shells put it — so no control stands in two
 * places, and the chart gets the whole window. */
static GtkWidget *
lk_window_build_header (void)
{
  GtkWidget *header = gtk_header_bar_new ();

  gtk_widget_add_css_class (header, "flat");
  return header;
}

/* ---- construction ------------------------------------------------------- */

GtkWidget *
lk_window_new (GtkApplication *app, LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkWindow *self = g_new0 (LkWindow, 1);
  self->model = model;
  self->window = gtk_application_window_new (app);
  gtk_widget_add_css_class (self->window, "lk-chart-window");
  g_object_set_data_full (G_OBJECT (self->window), "lk-window", self, lk_window_free);

  /* The name of the app, always. The chart is in the window, and the mariner
   * reads which one it is from the readouts. */
  gtk_window_set_title (GTK_WINDOW (self->window), "Lookout Marine");
  gtk_window_set_default_size (GTK_WINDOW (self->window), 1280, 800);
  /* Narrow enough that the capsule's compact form is reachable: below
   * LK_CHROME_COMPACT_WIDTH it drops the band and takes a smaller type, which
   * is the same rule the phone shells follow. */
  gtk_widget_set_size_request (self->window, 640, 480);
  gtk_application_window_set_show_menubar (GTK_APPLICATION_WINDOW (self->window), FALSE);

  g_action_map_add_action_entries (G_ACTION_MAP (self->window), lk_window_actions,
                                   G_N_ELEMENTS (lk_window_actions), self);

  gtk_window_set_titlebar (GTK_WINDOW (self->window), lk_window_build_header ());

  /* The chart fills the window; the chrome floats over it. */
  GtkWidget *root = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  self->chart_view = lk_chart_view_new (model);
  self->loader = lk_window_build_loader ();
  self->empty_state = lk_window_build_empty_state ();

  self->overlay = gtk_overlay_new ();
  gtk_overlay_set_child (GTK_OVERLAY (self->overlay), self->chart_view);
  gtk_widget_set_vexpand (self->overlay, TRUE);

  /* The chart is a subsurface below a transparent hole in the window, so the
   * chrome composites over it — the layout every shell uses: north at the top
   * right, zoom at the bottom right, the distance bar at the bottom left, the
   * readouts at the bottom centre, the build indicator at the top centre. */

  /* Top left: the search bubble reveals the coordinate go-to, and the commands
   * hang off the bubble beside it. */
  GtkWidget *top_left = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, LK_CHROME_GAP);
  gtk_box_append (GTK_BOX (top_left),
                  lk_bubble_new ("system-search-symbolic", "Go to coordinate", "win.search"));

  GtkWidget *commands = lk_bubble_menu_new ("open-menu-symbolic", "Commands", NULL);
  gtk_menu_button_set_direction (GTK_MENU_BUTTON (commands), GTK_ARROW_DOWN);
  gtk_menu_button_set_create_popup_func (GTK_MENU_BUTTON (commands), lk_window_fill_menu,
                                         self, NULL);
  gtk_box_append (GTK_BOX (top_left), commands);

  gtk_widget_set_halign (top_left, GTK_ALIGN_START);
  gtk_widget_set_valign (top_left, GTK_ALIGN_START);
  gtk_widget_set_margin_start (top_left, LK_CHROME_MARGIN);
  gtk_widget_set_margin_top (top_left, LK_CHROME_MARGIN);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), top_left);

  /* The search capsule drops from under the top-left bubbles when opened. */
  self->search = lk_search_new (model);
  gtk_widget_set_margin_start (self->search, LK_CHROME_MARGIN);
  gtk_widget_set_margin_top (self->search, LK_CHROME_MARGIN + LK_CHROME_BUBBLE + LK_CHROME_GAP);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->search);

  /* Top right: the compass, which is also the follow lock. */
  GtkWidget *north = lk_north_bubble_new (model);
  gtk_widget_set_margin_end (north, LK_CHROME_MARGIN);
  gtk_widget_set_margin_top (north, LK_CHROME_MARGIN);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), north);

  /* Bottom right: zoom above the settings, the whole column clear of the band
   * the capsule owns. The scheme and the view toggles are the mariner panel's
   * alone; they kept their accelerators. */
  GtkWidget *zoom = lk_zoom_controls_new (model);
  gtk_box_append (GTK_BOX (zoom),
                  lk_bubble_new ("preferences-system-symbolic", "Mariner settings",
                                 "win.settings"));
  gtk_widget_set_margin_end (zoom, LK_CHROME_MARGIN);
  gtk_widget_set_margin_bottom (zoom, LK_HUD_BAND);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), zoom);

  self->scale_bar = lk_scale_bar_new (model);
  gtk_widget_set_margin_start (self->scale_bar, LK_CHROME_MARGIN);
  gtk_widget_set_margin_bottom (self->scale_bar, LK_HUD_BAND);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->scale_bar);

  GtkWidget *building = lk_building_pill_new (model);
  GtkWidget *baking = lk_bake_pill_new (model);
  gtk_widget_set_margin_top (building, LK_CHROME_MARGIN);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), building);
  /* Preparing charts stands where the build indicator does. The two never run
     at once: nothing is drawn until the bake it is waiting on has finished. */
  gtk_widget_set_margin_top (baking, LK_CHROME_MARGIN);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), baking);

  /* Top centre, over the build indicator: what the plugins are alarming about.
   * It is added after the pill, so an alarm is never underneath it. */
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), lk_alerts_new (model));

  /* The bubble a click on a plugin's symbol pins. It is placed by margins over
   * the chart, like the pick mark, and it follows its object. */
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), lk_overlay_bubble_new (model));

  self->capsule = lk_hud_capsule_new (model);
  gtk_widget_set_margin_bottom (self->capsule, LK_CHROME_MARGIN);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->capsule);

  /* The loader and the empty state stand over all of it. */
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->loader);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->empty_state);

  gtk_box_append (GTK_BOX (root), self->overlay);
  gtk_window_set_child (GTK_WINDOW (self->window), root);

  /* A chart, a data file a plugin reads, or a plugin package: dropping any of
   * them on the window does what opening it does. */
  GtkDropTarget *drop = gtk_drop_target_new (G_TYPE_FILE, GDK_ACTION_COPY);
  g_signal_connect (drop, "drop", G_CALLBACK (lk_window_dropped), self);
  gtk_widget_add_controller (self->overlay, GTK_EVENT_CONTROLLER (drop));

  /* Escape runs the cascade in lk_window_escape, in the capture phase so the
     order is fixed here rather than left to who consumes the key first. */
  GtkEventController *keys = gtk_event_controller_key_new ();
  gtk_event_controller_set_propagation_phase (keys, GTK_PHASE_CAPTURE);
  g_signal_connect (keys, "key-pressed", G_CALLBACK (lk_window_escape), self);
  gtk_widget_add_controller (self->window, keys);

  lk_tether (model, g_signal_connect (model, "notify",
                                      G_CALLBACK (lk_window_notify), self), self->window);
  lk_tether (model, g_signal_connect (model, "pick-results",
                                      G_CALLBACK (lk_window_pick_changed), self), self->window);
  lk_tether (model, g_signal_connect (model, "raster-changed",
                                      G_CALLBACK (lk_window_raster_changed), self), self->window);
  lk_tether (model, g_signal_connect (model, "pick-moved",
                                      G_CALLBACK (lk_window_pick_moved), self), self->window);
  lk_tether (model, g_signal_connect (model, "chart-sets-changed",
                                      G_CALLBACK (lk_window_chart_sets_changed), self), self->window);

  g_object_get (gtk_widget_get_settings (self->window),
                "gtk-application-prefer-dark-theme", &self->desktop_prefers_dark, NULL);

  lk_window_update_overlays (self);
  lk_window_refresh_switched_off (self);
  lk_window_raster_changed (model, self);
  lk_window_apply_scheme (self);
  lk_window_apply_dev_hooks (self);

  return self->window;
}
