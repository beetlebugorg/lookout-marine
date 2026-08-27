#include "lk-window.h"

#include "lk-about.h"
#include "lk-alerts.h"
#include "lk-chart-view.h"
#include "lk-hud.h"
#include "lk-licenses.h"
#include "lk-overlay-pick.h"
#include "lk-plugin-install.h"
#include "lk-pick-report.h"
#include "lk-plugins.h"
#include "lk-tether.h"
#include "lk-search.h"
#include "lk-settings-window.h"
#include "lk-table-window.h"

#include <math.h>

typedef struct {
  LkAppModel *model;
  GtkWidget  *window;
  GtkWidget  *chart_view;
  GtkWidget  *overlay;
  GtkWidget  *search_bar;
  GtkWidget  *loader;
  GtkWidget  *empty_state;
  GtkWidget  *scale_bar;
  GtkWidget  *capsule;

  /* The pick: the mark on the chart and the report beside it, both rebuilt
   * per pick and both NULL while none is open. */
  GtkWidget *pick_marker;
  GtkWidget *pick_report;
  guint      place_id; /* re-places the report after a resize, off the layout */

  GtkWidget *settings_window;

  /* What the desktop preferred before the chart's scheme overrode it, so day
   * gives the preference back instead of forcing light on a dark desktop. */
  gboolean desktop_prefers_dark;
} LkWindow;

static void
lk_window_free (gpointer data)
{
  LkWindow *self = data;

  g_clear_handle_id (&self->place_id, g_source_remove);
  g_free (self);
}

/* ---- open dialog -------------------------------------------------------- */

static void
lk_open_finished (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkAppModel *model = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) file =
      gtk_file_dialog_select_folder_finish (GTK_FILE_DIALOG (source), result, &error);

  if (file == NULL)
    return; /* cancelled, or an error GTK already surfaced */

  g_autofree char *path = g_file_get_path (file);
  if (path != NULL)
    lk_app_model_open_chart (model, path);
  else
    lk_app_model_set_open_error (model,
                                 "That location isn't a local folder — the engine mmaps "
                                 "chart cells and needs a real path.");
}

/* Selects a FOLDER (a chart is a folder of baked cells). Starts at the open
 * chart's folder, else the baked-chart cache. */
static void
lk_open_chart_choice (GtkWindow *parent, LkAppModel *model)
{
  GtkFileDialog *dialog = gtk_file_dialog_new ();

  gtk_file_dialog_set_title (dialog, "Open Chart Folder");
  gtk_file_dialog_set_modal (dialog, TRUE);

  g_autofree char *initial = NULL;
  const char *current = lk_app_model_get_chart_path (model);
  if (current != NULL)
    initial = g_file_test (current, G_FILE_TEST_IS_DIR)
                  ? g_strdup (current)
                  : g_path_get_dirname (current);
  else
    {
      char *cache = g_build_filename (g_get_user_cache_dir (), "chartplotter", NULL);
      if (g_file_test (cache, G_FILE_TEST_IS_DIR))
        initial = cache;
      else
        g_free (cache);
    }
  if (initial != NULL)
    {
      g_autoptr (GFile) folder = g_file_new_for_path (initial);
      gtk_file_dialog_set_initial_folder (dialog, folder);
    }

  gtk_file_dialog_select_folder (dialog, parent, NULL, lk_open_finished, model);
  g_object_unref (dialog);
}

void
lk_present_open_chart_dialog (GtkWindow *parent, LkAppModel *model)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));

  lk_open_chart_choice (parent, model);
}

/* ---- one thing the mariner opened --------------------------------------- */

void
lk_window_open_path (GtkWindow *parent, LkAppModel *model, const char *path)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));

  if (path == NULL)
    return;

  /* A plugin package goes to consent and never to the chart engine. The
   * extension is the package's own, so this is routing, not sniffing. */
  if (lk_plugin_package_path (path))
    {
      lk_plugin_install_begin (parent, model, path, NULL, NULL);
      return;
    }

  /* A folder is a chart library. Anything else goes to lk_app_model_open_chart,
   * which offers it to the plugins first and opens it as a chart when none
   * claims it. */
  if (g_file_test (path, G_FILE_TEST_IS_DIR))
    lk_app_model_open_chart_directory (model, path);
  else
    lk_app_model_open_chart (model, path);
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

/* An exchange set arrives as one .zip as often as a folder: that is the shape a
 * chart agency publishes. GtkFileDialog picks folders or files, never both, so
 * the two are separate ways in rather than one that does both. Nothing is
 * unpacked — the engine bakes each cell where it lies inside the archive. */
static void
lk_open_archive_finished (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkAppModel *model = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) file = gtk_file_dialog_open_finish (GTK_FILE_DIALOG (source), result, &error);

  if (file == NULL)
    return; /* cancelled, or an error GTK already surfaced */

  g_autofree char *path = g_file_get_path (file);
  if (path != NULL)
    lk_app_model_open_chart (model, path);
  else
    lk_app_model_set_open_error (model,
                                 "That isn't a local file. The engine reads charts off "
                                 "the disk and needs a real path.");
}

void
lk_present_open_archive_dialog (GtkWindow *parent, LkAppModel *model)
{
  GtkFileDialog *dialog = gtk_file_dialog_new ();
  g_autoptr (GListStore) filters = g_list_store_new (GTK_TYPE_FILE_FILTER);
  GtkFileFilter *filter = gtk_file_filter_new ();

  gtk_file_filter_set_name (filter, "Chart exchange set (.zip)");
  gtk_file_filter_add_pattern (filter, "*.zip");
  gtk_file_filter_add_pattern (filter, "*.ZIP");
  g_list_store_append (filters, filter);
  g_object_unref (filter);

  gtk_file_dialog_set_title (dialog, "Open Chart Archive");
  gtk_file_dialog_set_modal (dialog, TRUE);
  gtk_file_dialog_set_accept_label (dialog, "Open");
  gtk_file_dialog_set_filters (dialog, G_LIST_MODEL (filters));

  gtk_file_dialog_open (dialog, parent, NULL, lk_open_archive_finished, model);
  g_object_unref (dialog);
}

/* ---- the raster chart pickers ------------------------------------------- */

static void
lk_raster_files_chosen (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkAppModel *model = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GListModel) files =
      gtk_file_dialog_open_multiple_finish (GTK_FILE_DIALOG (source), result, &error);

  if (files == NULL)
    return; /* cancelled, or an error GTK already surfaced */

  g_autoptr (GPtrArray) paths = g_ptr_array_new_with_free_func (g_free);
  guint n = g_list_model_get_n_items (files);

  for (guint i = 0; i < n; i++)
    {
      g_autoptr (GFile) file = g_list_model_get_item (files, i);
      char *path = g_file_get_path (file);

      if (path != NULL)
        g_ptr_array_add (paths, path);
    }

  if (paths->len == 0)
    {
      lk_app_model_set_open_error (model,
                                   "Those aren't local files — the engine reads a raster "
                                   "chart off the disk and needs a real path.");
      return;
    }

  g_ptr_array_add (paths, NULL);
  lk_app_model_add_raster_charts (model, (const char *const *) paths->pdata);
}

void
lk_present_add_raster_dialog (GtkWindow *parent, LkAppModel *model)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));

  GtkFileDialog *dialog = gtk_file_dialog_new ();
  g_autoptr (GtkFileFilter) raster = gtk_file_filter_new ();
  g_autoptr (GListStore) filters = g_list_store_new (GTK_TYPE_FILE_FILTER);

  gtk_file_dialog_set_title (dialog, "Add Raster Charts");
  gtk_file_dialog_set_modal (dialog, TRUE);
  gtk_file_dialog_set_accept_label (dialog, "Add");

  /* The extension is a hint only: the engine decides by what the file IS. The
   * "All files" filter is there so a chart with an odd name is still reachable. */
  gtk_file_filter_set_name (raster, "Raster charts");
  gtk_file_filter_add_suffix (raster, "mbtiles"); /* a suffix rule ignores case */
  g_list_store_append (filters, raster);

  g_autoptr (GtkFileFilter) all = gtk_file_filter_new ();
  gtk_file_filter_set_name (all, "All files");
  gtk_file_filter_add_pattern (all, "*");
  g_list_store_append (filters, all);

  gtk_file_dialog_set_filters (dialog, G_LIST_MODEL (filters));
  gtk_file_dialog_set_default_filter (dialog, raster);

  gtk_file_dialog_open_multiple (dialog, parent, NULL, lk_raster_files_chosen, model);
  g_object_unref (dialog);
}

static void
lk_raster_folder_chosen (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkAppModel *model = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) folder =
      gtk_file_dialog_select_folder_finish (GTK_FILE_DIALOG (source), result, &error);

  if (folder == NULL)
    return;

  g_autofree char *path = g_file_get_path (folder);
  if (path == NULL)
    return;

  g_auto (GStrv) paths = lk_raster_charts_in_dir (path);
  if (g_strv_length (paths) == 0)
    {
      lk_app_model_set_open_error (model, "That folder holds no .mbtiles raster charts.");
      return;
    }

  lk_app_model_add_raster_charts (model, (const char *const *) paths);
}

void
lk_present_add_raster_folder_dialog (GtkWindow *parent, LkAppModel *model)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));

  GtkFileDialog *dialog = gtk_file_dialog_new ();

  gtk_file_dialog_set_title (dialog, "Add a Folder of Raster Charts");
  gtk_file_dialog_set_modal (dialog, TRUE);
  gtk_file_dialog_set_accept_label (dialog, "Add");
  gtk_file_dialog_select_folder (dialog, parent, NULL, lk_raster_folder_chosen, model);
  g_object_unref (dialog);
}

/* ---- actions ------------------------------------------------------------ */

static void
lk_action_open (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_present_open_chart_dialog (GTK_WINDOW (self->window), self->model);
}

/* One FILE, rather than a folder of cells: a single baked chart, a data file a
 * plugin reads, or a plugin package. GtkFileDialog takes files or folders and
 * never both, so the two live on separate items, as the two raster pickers do.
 *
 * No content-type filter. Naming types would grey out the mariner's own charts
 * where the system does not know the extension, and the core decides what a
 * file is anyway. */
static void
lk_open_file_chosen (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkWindow *self = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) file = gtk_file_dialog_open_finish (GTK_FILE_DIALOG (source), result, &error);

  if (file == NULL)
    return; /* cancelled, or an error GTK already surfaced */

  g_autofree char *path = g_file_get_path (file);
  if (path != NULL)
    lk_window_open_path (GTK_WINDOW (self->window), self->model, path);
  else
    lk_app_model_set_open_error (self->model, "That isn't a local file.");
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

  gtk_file_dialog_open (dialog, GTK_WINDOW (self->window), NULL, lk_open_file_chosen, self);
  g_object_unref (dialog);
}

static void
lk_action_open_archive (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_present_open_archive_dialog (GTK_WINDOW (self->window), self->model);
}

static void
lk_action_open_recent (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_app_model_open_chart (self->model, g_variant_get_string (parameter, NULL));
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
  gboolean open = !gtk_search_bar_get_search_mode (GTK_SEARCH_BAR (self->search_bar));

  gtk_search_bar_set_search_mode (GTK_SEARCH_BAR (self->search_bar), open);
}

/* Escape clears whatever the last click put on the chart, whichever it was. */
static void
lk_action_close_pick (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_app_model_clear_pick (self->model);
  lk_app_model_pin_overlay (self->model, NULL);
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

/* ---- dev/screenshot hooks ------------------------------------------------ */

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
static void
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

static const GActionEntry lk_window_actions[] = {
  { "open",             lk_action_open },
  { "open-archive",     lk_action_open_archive },
  { "open-file",        lk_action_open_file },
  { "open-recent",      lk_action_open_recent, "s" },
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
  g_menu_append_submenu (chart, "Colour Scheme", G_MENU_MODEL (scheme));

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

  GMenu *recents = g_menu_new ();
  const char *const *paths = lk_app_model_get_recents (self->model);
  for (gsize i = 0; paths != NULL && paths[i] != NULL; i++)
    {
      g_autofree char *name = g_path_get_basename (paths[i]);
      g_autoptr (GVariant) target = g_variant_new_string (paths[i]);
      g_autoptr (GMenuItem) item = g_menu_item_new (name, NULL);

      g_menu_item_set_action_and_target_value (item, "win.open-recent",
                                               g_steal_pointer (&target));
      g_menu_append_item (recents, item);
    }
  g_menu_append_submenu (files, "Open Recent", G_MENU_MODEL (recents));
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

  g_object_unref (recents);
  g_object_unref (files);
  g_object_unref (app);
  g_object_unref (info);
  g_object_unref (menu);
}

/* ---- model-driven chrome ------------------------------------------------ */

/* Defined with the loader below. */
static char *lk_group_number (guint value);
static void  lk_loader_step_set (GtkWidget *row, int state,
                                 const char *text, const char *detail_text);

static void
lk_window_update_overlays (LkWindow *self)
{
  gboolean loading = lk_app_model_get_show_startup_loader (self->model);
  gboolean has_chart = lk_app_model_get_has_chart (self->model);
  gboolean baking = lk_app_model_get_baking (self->model);

  gtk_widget_set_visible (self->loader, loading && !baking);
  /* Nothing is open DURING a bake either, but "No chart open" beside a card
     offering to open one is the wrong thing to say while the app is already
     busy preparing the charts the mariner just picked. The import pill is the
     status; this stays out of its way until there is a decision to make. */
  gtk_widget_set_visible (self->empty_state, !loading && !has_chart && !baking);
  /* No chart, no readouts: a capsule reading 1:— over an empty view is chrome
   * with nothing to report. */
  gtk_widget_set_visible (self->capsule, has_chart);
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

/* The mark on the object, and the report standing beside it. Both are rebuilt
 * for each pick: a pick is a new set of objects, and how many there are is
 * what decides the card's shape. */
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

  GPtrArray *results = lk_app_model_get_pick_results (self->model);

  self->pick_marker = lk_pick_marker_new ();
  gtk_widget_set_margin_start (self->pick_marker, MAX (0, (int) (x - LK_PICK_MARKER_SIZE / 2)));
  gtk_widget_set_margin_top (self->pick_marker, MAX (0, (int) (y - LK_PICK_MARKER_SIZE / 2)));
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->pick_marker);

  /* A narrow window takes the report as a SHEET across the bottom rather
   * than a callout beside the mark: a callout squeezed into a phone-shaped
   * window covers the very water it describes. The same rule the compact
   * capsule follows, at the same width. */
  if (view_width < LK_CHROME_COMPACT_WIDTH)
    {
      int width = view_width - 2 * LK_CHROME_MARGIN;
      int room = (int) (view_height * 0.45);

      self->pick_report = lk_pick_report_new (self->model, width, room);
      gtk_widget_set_halign (self->pick_report, GTK_ALIGN_CENTER);
      gtk_widget_set_valign (self->pick_report, GTK_ALIGN_END);
      gtk_widget_set_margin_bottom (self->pick_report, LK_HUD_BAND);
      gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->pick_report);
      return;
    }

  int width = lk_pick_report_width (results->len, view_width);
  LkCalloutPlace place = lk_callout_place (x, y, width, view_width, view_height, LK_HUD_BAND);

  /* The card holds one edge against the mark and the layout places the
   * opposite edge, so nothing here has to measure the card's height. */
  self->pick_report = lk_pick_report_new (self->model, width, (int) place.room);
  gtk_widget_set_halign (self->pick_report, GTK_ALIGN_START);
  gtk_widget_set_margin_start (self->pick_report, MAX (0, (int) place.x));

  if (place.edge == LK_CALLOUT_ABOVE)
    {
      gtk_widget_set_valign (self->pick_report, GTK_ALIGN_END);
      gtk_widget_set_margin_bottom (self->pick_report, MAX (0, (int) (view_height - place.y)));
    }
  else
    {
      gtk_widget_set_valign (self->pick_report, GTK_ALIGN_START);
      gtk_widget_set_margin_top (self->pick_report, MAX (0, (int) place.y));
    }

  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->pick_report);
}

static gboolean
lk_window_place_pick_idle (gpointer user_data)
{
  LkWindow *self = user_data;

  self->place_id = 0;
  lk_window_update_pick (self);
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
    g_simple_action_set_state (G_SIMPLE_ACTION (action),
                               g_variant_new_int32 (lk_app_model_get_raster_active (model)));
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

/* ---- overlays ----------------------------------------------------------- */

/* 7217 → "7,217". The separator is a comma on every shell, as it is in the
 * scale readout. */
static char *
lk_group_number (guint value)
{
  g_autofree char *plain = g_strdup_printf ("%u", value);
  gsize length = strlen (plain);
  GString *grouped = g_string_new (NULL);

  for (gsize i = 0; i < length; i++)
    {
      if (i > 0 && (length - i) % 3 == 0)
        g_string_append_c (grouped, ',');
      g_string_append_c (grouped, plain[i]);
    }
  return g_string_free (grouped, FALSE);
}

/* The compass rose of the loader. Drawn, not an icon, so the shape is the
 * same on each platform (CompassMark on macOS and iOS). */
static void
lk_compass_mark_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
                      gpointer user_data)
{
  double r = MIN (width, height) / 2.0;
  double cx = width / 2.0, cy = height / 2.0;

  /* The pinned accent (#0a5bb5) at the reference's 35%. */
  cairo_set_source_rgba (cr, 0.039, 0.357, 0.710, 0.35);
  cairo_set_line_width (cr, 2.0);
  cairo_arc (cr, cx, cy, r - 1.0, 0, 2 * G_PI);
  cairo_stroke (cr);
  for (int i = 0; i < 4; i++)
    {
      cairo_save (cr);
      cairo_translate (cr, cx, cy);
      cairo_rotate (cr, i * G_PI / 2.0);
      cairo_rectangle (cr, -0.75, -r * 0.86, 1.5, r * 0.28);
      cairo_fill (cr);
      cairo_restore (cr);
    }
  /* The north needle, in the red a chart compass rose uses. */
  cairo_save (cr);
  cairo_translate (cr, cx - r, cy - r);
  cairo_set_source_rgb (cr, 0.831, 0.180, 0.180);
  cairo_move_to (cr, r, r * 0.28);
  cairo_line_to (cr, r * 0.7, r * 1.32);
  cairo_line_to (cr, r * 1.3, r * 1.32);
  cairo_close_path (cr);
  cairo_fill (cr);
  cairo_restore (cr);
}

/* One step of the opening page: what it says, and whether it is waiting,
 * running or done. */
static GtkWidget *
lk_loader_step_new (GtkWidget *box)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *mark = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  GtkWidget *spinner = gtk_spinner_new ();
  GtkWidget *check = gtk_image_new_from_icon_name ("object-select-symbolic");
  GtkWidget *label = gtk_label_new ("");
  GtkWidget *detail = gtk_label_new ("");

  gtk_widget_set_size_request (mark, 16, 16);
  gtk_widget_set_valign (mark, GTK_ALIGN_CENTER);
  gtk_widget_set_size_request (spinner, 14, 14);
  gtk_image_set_pixel_size (GTK_IMAGE (check), 14);
  gtk_box_append (GTK_BOX (mark), spinner);
  gtk_box_append (GTK_BOX (mark), check);

  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_widget_add_css_class (detail, "dim-label");
  gtk_widget_add_css_class (detail, "caption");

  gtk_box_append (GTK_BOX (row), mark);
  gtk_box_append (GTK_BOX (row), label);
  gtk_box_append (GTK_BOX (row), detail);
  gtk_box_append (GTK_BOX (box), row);

  g_object_set_data (G_OBJECT (row), "lk-spinner", spinner);
  g_object_set_data (G_OBJECT (row), "lk-check", check);
  g_object_set_data (G_OBJECT (row), "lk-label", label);
  g_object_set_data (G_OBJECT (row), "lk-detail", detail);
  return row;
}

/* `state`: 0 waiting, 1 running, 2 done. */
static void
lk_loader_step_set (GtkWidget *row, int state, const char *text, const char *detail_text)
{
  GtkWidget *spinner = g_object_get_data (G_OBJECT (row), "lk-spinner");
  GtkWidget *check = g_object_get_data (G_OBJECT (row), "lk-check");
  GtkWidget *label = g_object_get_data (G_OBJECT (row), "lk-label");
  GtkWidget *detail = g_object_get_data (G_OBJECT (row), "lk-detail");

  gtk_widget_set_visible (spinner, state == 1);
  gtk_spinner_set_spinning (GTK_SPINNER (spinner), state == 1);
  gtk_widget_set_visible (check, state == 2);
  gtk_label_set_text (GTK_LABEL (label), text);
  if (state == 0)
    gtk_widget_add_css_class (label, "dim-label");
  else
    gtk_widget_remove_css_class (label, "dim-label");
  gtk_label_set_text (GTK_LABEL (detail), detail_text);
  gtk_widget_set_visible (detail, detail_text[0] != '\0');
}

/* Opening, as a page. The three waits are different work and the mariner
 * should be able to see which one they are in: the one-time symbol bake,
 * mapping the library, and tessellating the first scene. A single spinner
 * that vanishes says only that something happened. The twin of StartupLoader
 * (macOS) and the WinUI loader page. */
static GtkWidget *
lk_window_build_loader (void)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *compass = gtk_drawing_area_new ();
  GtkWidget *title = gtk_label_new ("Opening the chart");

  gtk_widget_set_size_request (compass, 24, 24);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (compass),
                                  lk_compass_mark_draw, NULL, NULL);
  gtk_widget_add_css_class (title, "title-4");
  gtk_box_append (GTK_BOX (header), compass);
  gtk_box_append (GTK_BOX (header), title);
  gtk_box_append (GTK_BOX (box), header);

  g_object_set_data (G_OBJECT (box), "lk-title", title);
  g_object_set_data (G_OBJECT (box), "lk-step0", lk_loader_step_new (box));
  g_object_set_data (G_OBJECT (box), "lk-step1", lk_loader_step_new (box));
  g_object_set_data (G_OBJECT (box), "lk-step2", lk_loader_step_new (box));

  gtk_widget_add_css_class (box, "lk-card");
  gtk_widget_set_halign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_visible (box, FALSE);
  return box;
}

/* One fact under the first-run panel's buttons: an icon and a line. */
static void
lk_empty_state_note (GtkWidget *box, const char *icon_name, const char *markup)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *icon = gtk_image_new_from_icon_name (icon_name);
  GtkWidget *text = gtk_label_new (NULL);

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 13);
  gtk_widget_add_css_class (icon, "dim-label");
  gtk_widget_set_valign (icon, GTK_ALIGN_START);
  gtk_widget_set_margin_top (icon, 2);
  gtk_label_set_markup (GTK_LABEL (text), markup);
  gtk_widget_add_css_class (text, "dim-label");
  gtk_widget_add_css_class (text, "caption");
  gtk_label_set_wrap (GTK_LABEL (text), TRUE);
  gtk_label_set_xalign (GTK_LABEL (text), 0.0);
  gtk_widget_set_hexpand (text, TRUE);

  gtk_box_append (GTK_BOX (row), icon);
  gtk_box_append (GTK_BOX (row), text);
  gtk_box_append (GTK_BOX (box), row);
}

/* The first thing a mariner sees, before any chart is aboard.
 *
 * It answers three questions in the order they are asked: what is this
 * program for, why is it empty, what do I do now — and it closes with the one
 * block that is not about getting started, which a mariner must not skim.
 * The twin of EmptyChartState (macOS); the words are the reference's. */
static GtkWidget *
lk_window_build_empty_state (void)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *icon = gtk_image_new_from_icon_name ("mark-location-symbolic");
  GtkWidget *title = gtk_label_new ("No charts yet");
  GtkWidget *body = gtk_label_new ("Lookout draws official S-57 and S-101 ENC charts. "
                                   "It does not come with any, so point it at yours.");
  GtkWidget *error = gtk_label_new ("");
  GtkWidget *buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *button = gtk_button_new_with_label ("Choose Charts…");
  GtkWidget *archive = gtk_button_new_with_label ("Choose an Archive…");
  GtkWidget *drop_hint = gtk_label_new ("or drop them anywhere in this window");

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 26);
  gtk_widget_add_css_class (icon, "lk-accent");
  gtk_widget_set_halign (icon, GTK_ALIGN_START);
  gtk_widget_set_margin_bottom (icon, 12);

  gtk_widget_add_css_class (title, "title-2");
  gtk_label_set_xalign (GTK_LABEL (title), 0.0);
  gtk_widget_set_margin_bottom (title, 6);

  gtk_widget_add_css_class (body, "dim-label");
  gtk_label_set_wrap (GTK_LABEL (body), TRUE);
  gtk_label_set_xalign (GTK_LABEL (body), 0.0);
  gtk_widget_set_margin_bottom (body, 16);

  /* A folder that held nothing has to say so HERE. This page is where the
   * mariner pressed the button, and an alert over an empty page is ceremony. */
  gtk_widget_add_css_class (error, "warning");
  gtk_label_set_wrap (GTK_LABEL (error), TRUE);
  gtk_label_set_xalign (GTK_LABEL (error), 0.0);
  gtk_widget_set_margin_bottom (error, 10);
  gtk_widget_set_visible (error, FALSE);

  gtk_widget_add_css_class (button, "suggested-action");
  gtk_widget_add_css_class (button, "pill");
  gtk_actionable_set_action_name (GTK_ACTIONABLE (button), "win.open");
  gtk_widget_add_css_class (archive, "pill");
  gtk_actionable_set_action_name (GTK_ACTIONABLE (archive), "win.open-archive");
  gtk_widget_add_css_class (drop_hint, "dim-label");
  gtk_widget_add_css_class (drop_hint, "caption");
  gtk_box_append (GTK_BOX (buttons), button);
  gtk_box_append (GTK_BOX (buttons), archive);
  gtk_box_append (GTK_BOX (buttons), drop_hint);
  gtk_widget_set_halign (buttons, GTK_ALIGN_START);
  gtk_widget_set_margin_bottom (buttons, 14);

  gtk_box_append (GTK_BOX (box), icon);
  gtk_box_append (GTK_BOX (box), title);
  gtk_box_append (GTK_BOX (box), body);
  gtk_box_append (GTK_BOX (box), error);
  gtk_box_append (GTK_BOX (box), buttons);

  /* What actually works, in the words of what the mariner has in hand. Where
   * the charts come from goes first: a mariner with none needs that before a
   * list of file extensions. */
  lk_empty_state_note (box, "web-browser-symbolic",
                       "NOAA publishes every United States chart at no cost, at "
                       "<a href=\"https://www.charts.noaa.gov/ENCs/ENCs.shtml\">"
                       "charts.noaa.gov</a>. Most other offices sell theirs.");
  lk_empty_state_note (box, "folder-open-symbolic",
                       "A folder of cells (.000), prepared charts (.pmtiles), imagery "
                       "(.mbtiles) or BSB/KAP sheets. Cells and sheets are converted "
                       "once on the way in, a few seconds each.");

  /* Last, and set apart. */
  GtkWidget *warn = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);
  GtkWidget *warn_title = gtk_label_new ("NOT FOR NAVIGATION");
  GtkWidget *warn_body = gtk_label_new (
      "By importing charts you accept that Lookout is a prototype and not a "
      "certified navigation system, and that the charts it prepares are processed "
      "for display and are not the official ENC. They do not meet chart carriage "
      "regulations. You remain responsible for the safe navigation of your vessel "
      "and for keeping clear of every danger. Verify everything shown here against "
      "official, up-to-date charts and publications, and keep a paper backup.");
  GtkWidget *warn_noaa = gtk_label_new (NULL);

  gtk_widget_add_css_class (warn, "lk-not-nav");
  gtk_widget_add_css_class (warn_title, "lk-not-nav-title");
  gtk_label_set_xalign (GTK_LABEL (warn_title), 0.0);
  gtk_label_set_wrap (GTK_LABEL (warn_body), TRUE);
  gtk_label_set_xalign (GTK_LABEL (warn_body), 0.0);
  gtk_widget_add_css_class (warn_body, "caption");
  /* NOAA's own terms, in their words. They apply to their charts whoever
   * prepared them. */
  gtk_label_set_markup (GTK_LABEL (warn_noaa),
                        "NOAA ENC\xC2\xAE charts come from the NOAA Office of Coast "
                        "Survey and are updated weekly on a best-efforts basis; you "
                        "are responsible for holding the current edition and the "
                        "latest updates. NOAA makes no warranty and assumes no "
                        "liability for their use. See the <a href=\""
                        "https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml\">"
                        "NOAA ENC User Agreement</a>.");
  gtk_label_set_wrap (GTK_LABEL (warn_noaa), TRUE);
  gtk_label_set_xalign (GTK_LABEL (warn_noaa), 0.0);
  gtk_widget_add_css_class (warn_noaa, "caption");
  gtk_widget_add_css_class (warn_noaa, "dim-label");
  gtk_box_append (GTK_BOX (warn), warn_title);
  gtk_box_append (GTK_BOX (warn), warn_body);
  gtk_box_append (GTK_BOX (warn), warn_noaa);
  gtk_widget_set_margin_top (warn, 10);
  gtk_box_append (GTK_BOX (box), warn);

  gtk_widget_add_css_class (box, "lk-card");
  gtk_widget_set_size_request (box, 430, -1);

  /* A page this tall must still fit a short window, so it scrolls. */
  GtkWidget *scroller = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), box);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_propagate_natural_width (GTK_SCROLLED_WINDOW (scroller), TRUE);
  gtk_scrolled_window_set_propagate_natural_height (GTK_SCROLLED_WINDOW (scroller), TRUE);
  gtk_widget_set_halign (scroller, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (scroller, GTK_ALIGN_CENTER);
  gtk_widget_set_visible (scroller, FALSE);

  g_object_set_data (G_OBJECT (scroller), "lk-error", error);
  return scroller;
}

/* ---- titlebar ----------------------------------------------------------- */

/* The titlebar carries the chart's name and the window controls, and nothing
 * else. Every control that acts on the chart is a bubble over the chart, where
 * the SwiftUI, WinUI and Compose shells put it — so no control stands in two
 * places, and the chart gets the whole window. */
static GtkWidget *
lk_window_build_header (LkWindow *self)
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

  gtk_window_set_titlebar (GTK_WINDOW (self->window), lk_window_build_header (self));

  /* Search above, chart in the middle, readouts below. */
  GtkWidget *root = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  self->search_bar = lk_search_bar_new (model);
  gtk_box_append (GTK_BOX (root), self->search_bar);

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

  lk_tether (model, g_signal_connect (model, "notify",
                                      G_CALLBACK (lk_window_notify), self), self->window);
  lk_tether (model, g_signal_connect (model, "pick-results",
                                      G_CALLBACK (lk_window_pick_changed), self), self->window);
  lk_tether (model, g_signal_connect (model, "raster-changed",
                                      G_CALLBACK (lk_window_raster_changed), self), self->window);
  lk_tether (model, g_signal_connect (model, "pick-moved",
                                      G_CALLBACK (lk_window_pick_moved), self), self->window);

  g_object_get (gtk_widget_get_settings (self->window),
                "gtk-application-prefer-dark-theme", &self->desktop_prefers_dark, NULL);

  lk_window_update_overlays (self);
  lk_window_apply_scheme (self);
  lk_window_apply_dev_hooks (self);

  return self->window;
}
