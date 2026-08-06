#include "lk-window.h"

#include "lk-chart-view.h"
#include "lk-hud.h"
#include "lk-pick-report.h"
#include "lk-search.h"
#include "lk-settings-window.h"

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

static void
lk_action_close_pick (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_app_model_clear_pick (self->model);
}

static void
lk_action_settings (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  if (self->settings_window == NULL)
    {
      self->settings_window = lk_settings_window_new (self->model, GTK_WINDOW (self->window));
      g_object_add_weak_pointer (G_OBJECT (self->settings_window),
                                 (gpointer *) &self->settings_window);
    }

  gtk_window_present (GTK_WINDOW (self->settings_window));
}

static const GActionEntry lk_window_actions[] = {
  { "open",             lk_action_open },
  { "open-recent",      lk_action_open_recent, "s" },
  { "zoom-in",          lk_action_zoom_in },
  { "zoom-out",         lk_action_zoom_out },
  { "zoom-fit",         lk_action_zoom_fit },
  { "north-up",         lk_action_north_up },
  { "cycle-scheme",     lk_action_cycle_scheme },
  { "toggle-text",      lk_action_toggle_text },
  { "toggle-soundings", lk_action_toggle_soundings },
  { "toggle-other",     lk_action_toggle_other },
  { "search",           lk_action_search },
  { "close-pick",       lk_action_close_pick },
  { "settings",         lk_action_settings },
  { "set-scheme",       lk_action_set_scheme, "i", "0" },
  { "raster-cycle",     lk_action_raster_cycle },
  /* Stateful, so the pill's list marks the set that is drawn. The state is the
   * index the engine reports, pushed back on every raster change. */
  { "raster-select",    lk_action_raster_select, "i", "-1" },
  { "raster-add",       lk_action_raster_add },
  { "raster-add-folder", lk_action_raster_add_folder },
  { "toggle-chart",     lk_action_toggle_chart },
};

/* ---- model-driven chrome ------------------------------------------------ */

static void
lk_window_update_overlays (LkWindow *self)
{
  gboolean loading = lk_app_model_get_show_startup_loader (self->model);
  gboolean has_chart = lk_app_model_get_has_chart (self->model);

  gtk_widget_set_visible (self->loader, loading);
  gtk_widget_set_visible (self->empty_state, !loading && !has_chart);
  /* No chart, no readouts: a capsule reading 1:— over an empty view is chrome
   * with nothing to report. */
  gtk_widget_set_visible (self->capsule, has_chart);
  gtk_widget_set_visible (self->scale_bar, has_chart);

  GtkWidget *label = g_object_get_data (G_OBJECT (self->loader), "lk-label");
  gtk_label_set_text (GTK_LABEL (label),
                      lk_app_model_get_preparing_symbols (self->model)
                          ? "Preparing chart symbols…"
                          : "Loading charts…");

  GtkWidget *hint = g_object_get_data (G_OBJECT (self->loader), "lk-hint");
  gtk_widget_set_visible (hint, lk_app_model_get_preparing_symbols (self->model));
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
  int width = lk_pick_report_width (results->len, view_width);
  LkCalloutPlace place = lk_callout_place (x, y, width, view_width, view_height, LK_HUD_BAND);

  self->pick_marker = lk_pick_marker_new ();
  gtk_widget_set_margin_start (self->pick_marker, MAX (0, (int) (x - LK_PICK_MARKER_SIZE / 2)));
  gtk_widget_set_margin_top (self->pick_marker, MAX (0, (int) (y - LK_PICK_MARKER_SIZE / 2)));
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->pick_marker);

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
  lk_window_update_pick (user_data);
}

/* The engine owns which set is drawn: the cycle key, a chart opening and a
 * chart switched off all move it. Push it back into the action, so the list the
 * pill opens marks the picture actually on the screen. */
static void
lk_window_raster_changed (LkAppModel *model, gpointer user_data)
{
  LkWindow *self = user_data;
  GAction *action = g_action_map_lookup_action (G_ACTION_MAP (self->window), "raster-select");

  if (action != NULL)
    g_simple_action_set_state (G_SIMPLE_ACTION (action),
                               g_variant_new_int32 (lk_app_model_get_raster_active (model)));
}

static void
lk_window_show_open_error (LkWindow *self)
{
  const char *message = NULL;

  g_object_get (self->model, "open-error", &message, NULL);
  if (message == NULL)
    return;

  GtkAlertDialog *dialog = gtk_alert_dialog_new ("Couldn't open chart");
  gtk_alert_dialog_set_detail (dialog, message);
  gtk_alert_dialog_show (dialog, GTK_WINDOW (self->window));
  g_object_unref (dialog);

  lk_app_model_set_open_error (self->model, NULL);
}

static void
lk_window_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  LkWindow *self = user_data;
  const char *name = g_param_spec_get_name (pspec);

  if (g_str_equal (name, "show-startup-loader") || g_str_equal (name, "has-chart"))
    lk_window_update_overlays (self);
  else if (g_str_equal (name, "view-width") || g_str_equal (name, "view-height"))
    lk_window_queue_place_pick (self);
  else if (g_str_equal (name, "open-error"))
    lk_window_show_open_error (self);
}

/* ---- overlays ----------------------------------------------------------- */

static GtkWidget *
lk_window_build_loader (void)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);
  GtkWidget *spinner = gtk_spinner_new ();
  GtkWidget *label = gtk_label_new ("Loading charts…");
  GtkWidget *hint = gtk_label_new ("First launch only — this is cached for next time.");

  gtk_widget_set_size_request (spinner, 32, 32);
  gtk_spinner_start (GTK_SPINNER (spinner));
  gtk_widget_add_css_class (label, "title-4");
  gtk_widget_add_css_class (hint, "dim-label");
  gtk_widget_add_css_class (hint, "caption");
  gtk_widget_set_visible (hint, FALSE);

  gtk_box_append (GTK_BOX (box), spinner);
  gtk_box_append (GTK_BOX (box), label);
  gtk_box_append (GTK_BOX (box), hint);

  gtk_widget_add_css_class (box, "lk-card");
  gtk_widget_set_halign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_visible (box, FALSE);

  g_object_set_data (G_OBJECT (box), "lk-label", label);
  g_object_set_data (G_OBJECT (box), "lk-hint", hint);
  return box;
}

static GtkWidget *
lk_window_build_empty_state (void)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);
  GtkWidget *icon = gtk_image_new_from_icon_name ("mark-location-symbolic");
  GtkWidget *title = gtk_label_new ("No chart open");
  GtkWidget *body = gtk_label_new ("Open a folder of baked chart cells to get started.");
  GtkWidget *button = gtk_button_new_with_label ("Open Charts…");

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 48);
  gtk_widget_add_css_class (icon, "dim-label");
  gtk_widget_add_css_class (title, "title-2");
  gtk_widget_add_css_class (body, "dim-label");
  gtk_label_set_wrap (GTK_LABEL (body), TRUE);
  gtk_label_set_justify (GTK_LABEL (body), GTK_JUSTIFY_CENTER);
  gtk_widget_set_size_request (body, 320, -1);

  gtk_widget_add_css_class (button, "suggested-action");
  gtk_widget_add_css_class (button, "pill");
  gtk_widget_set_halign (button, GTK_ALIGN_CENTER);
  gtk_actionable_set_action_name (GTK_ACTIONABLE (button), "win.open");

  gtk_box_append (GTK_BOX (box), icon);
  gtk_box_append (GTK_BOX (box), title);
  gtk_box_append (GTK_BOX (box), body);
  gtk_box_append (GTK_BOX (box), button);

  gtk_widget_add_css_class (box, "lk-card");
  gtk_widget_set_halign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_visible (box, FALSE);
  return box;
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

  /* Top left: the search bubble reveals the coordinate go-to. */
  GtkWidget *search = lk_bubble_new ("system-search-symbolic", "Go to coordinate", "win.search");
  gtk_widget_set_halign (search, GTK_ALIGN_START);
  gtk_widget_set_valign (search, GTK_ALIGN_START);
  gtk_widget_set_margin_start (search, LK_CHROME_MARGIN);
  gtk_widget_set_margin_top (search, LK_CHROME_MARGIN);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), search);

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
  gtk_widget_set_margin_top (building, LK_CHROME_MARGIN);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), building);

  self->capsule = lk_hud_capsule_new (model);
  gtk_widget_set_margin_bottom (self->capsule, LK_CHROME_MARGIN);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->capsule);

  /* The loader and the empty state stand over all of it. */
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->loader);
  gtk_overlay_add_overlay (GTK_OVERLAY (self->overlay), self->empty_state);

  gtk_box_append (GTK_BOX (root), self->overlay);
  gtk_window_set_child (GTK_WINDOW (self->window), root);

  g_signal_connect (model, "notify", G_CALLBACK (lk_window_notify), self);
  g_signal_connect (model, "pick-results", G_CALLBACK (lk_window_pick_changed), self);
  g_signal_connect (model, "raster-changed", G_CALLBACK (lk_window_raster_changed), self);

  lk_window_update_overlays (self);

  return self->window;
}
