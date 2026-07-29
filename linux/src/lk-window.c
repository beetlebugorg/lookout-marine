#include "lk-window.h"

#include "lk-chart-view.h"
#include "lk-hud.h"
#include "lk-search.h"
#include "lk-settings-window.h"

#include <math.h>

typedef struct {
  LkAppModel *model;
  GtkWidget  *window;
  GtkWidget  *chart_view;
  GtkWidget  *search_bar;
  GtkWidget  *north_button;
  GtkWidget  *recents_menu_button;
  GtkWidget  *loader;
  GtkWidget  *empty_state;
  GtkWidget  *settings_window;
} LkWindow;

static void
lk_window_free (gpointer data)
{
  g_free (data);
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

static void
lk_action_set_scheme (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;

  lk_app_model_set_scheme (self->model, (int) g_variant_get_int32 (parameter));
  g_simple_action_set_state (action, parameter);
}

static void
lk_action_use_dms (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;
  gboolean value = !lk_app_model_get_use_dms (self->model);

  lk_app_model_set_use_dms (self->model, value);
  g_simple_action_set_state (action, g_variant_new_boolean (value));
}

static void
lk_action_search (GSimpleAction *action, GVariant *parameter, gpointer user_data)
{
  LkWindow *self = user_data;
  gboolean open = !gtk_search_bar_get_search_mode (GTK_SEARCH_BAR (self->search_bar));

  gtk_search_bar_set_search_mode (GTK_SEARCH_BAR (self->search_bar), open);
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
  { "settings",         lk_action_settings },
  { "set-scheme",       lk_action_set_scheme, "i", "0" },
  { "use-dms",          lk_action_use_dms, NULL, "false" },
};

/* ---- model-driven chrome ------------------------------------------------ */

static void
lk_window_rebuild_recents (LkWindow *self)
{
  GMenu *menu = g_menu_new ();
  const char *const *recents = lk_app_model_get_recents (self->model);

  g_menu_append (menu, "Open Charts…", "win.open");

  if (recents != NULL && recents[0] != NULL)
    {
      GMenu *section = g_menu_new ();
      for (guint i = 0; recents[i] != NULL; i++)
        {
          g_autofree char *name = g_path_get_basename (recents[i]);
          g_autoptr (GMenuItem) item = g_menu_item_new (name, NULL);
          g_menu_item_set_action_and_target_value (item, "win.open-recent",
                                                   g_variant_new_string (recents[i]));
          g_menu_append_item (section, item);
        }
      g_menu_append_section (menu, "Recent", G_MENU_MODEL (section));
      g_object_unref (section);
    }

  gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (self->recents_menu_button),
                                  G_MENU_MODEL (menu));
  g_object_unref (menu);
}

static void
lk_window_update_title (LkWindow *self)
{
  const char *path = lk_app_model_get_chart_path (self->model);

  if (path != NULL)
    {
      g_autofree char *name = g_path_get_basename (path);
      gtk_window_set_title (GTK_WINDOW (self->window), name);
    }
  else
    {
      gtk_window_set_title (GTK_WINDOW (self->window), "Lookout Marine");
    }
}

static void
lk_window_update_overlays (LkWindow *self)
{
  gboolean loading = lk_app_model_get_show_startup_loader (self->model);
  gboolean has_chart = lk_app_model_get_has_chart (self->model);

  gtk_widget_set_visible (self->loader, loading);
  gtk_widget_set_visible (self->empty_state, !loading && !has_chart);

  GtkWidget *label = g_object_get_data (G_OBJECT (self->loader), "lk-label");
  gtk_label_set_text (GTK_LABEL (label),
                      lk_app_model_get_preparing_symbols (self->model)
                          ? "Preparing chart symbols…"
                          : "Loading charts…");

  GtkWidget *hint = g_object_get_data (G_OBJECT (self->loader), "lk-hint");
  gtk_widget_set_visible (hint, lk_app_model_get_preparing_symbols (self->model));
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

  if (g_str_equal (name, "recents"))
    lk_window_rebuild_recents (self);
  else if (g_str_equal (name, "chart-path"))
    lk_window_update_title (self);
  else if (g_str_equal (name, "rotation"))
    gtk_widget_set_visible (self->north_button,
                            fabs (lk_app_model_get_rotation (self->model)) >= 0.5);
  else if (g_str_equal (name, "show-startup-loader") || g_str_equal (name, "has-chart"))
    lk_window_update_overlays (self);
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

/* ---- headerbar ---------------------------------------------------------- */

static GtkWidget *
lk_header_button (const char *icon_name, const char *tooltip, const char *action)
{
  GtkWidget *button = gtk_button_new_from_icon_name (icon_name);

  gtk_widget_set_tooltip_text (button, tooltip);
  gtk_actionable_set_action_name (GTK_ACTIONABLE (button), action);
  return button;
}

static GtkWidget *
lk_window_build_header (LkWindow *self)
{
  GtkWidget *header = gtk_header_bar_new ();

  self->recents_menu_button = gtk_menu_button_new ();
  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (self->recents_menu_button), "document-open-symbolic");
  gtk_widget_set_tooltip_text (self->recents_menu_button, "Open chart");
  gtk_header_bar_pack_start (GTK_HEADER_BAR (header), self->recents_menu_button);

  /* Linked zoom +/− pair. */
  GtkWidget *zoom = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_add_css_class (zoom, "linked");
  gtk_box_append (GTK_BOX (zoom), lk_header_button ("zoom-out-symbolic", "Zoom out", "win.zoom-out"));
  gtk_box_append (GTK_BOX (zoom), lk_header_button ("zoom-in-symbolic", "Zoom in", "win.zoom-in"));
  gtk_header_bar_pack_start (GTK_HEADER_BAR (header), zoom);

  gtk_header_bar_pack_start (GTK_HEADER_BAR (header),
                             lk_header_button ("zoom-fit-best-symbolic", "Zoom to fit", "win.zoom-fit"));

  self->north_button = lk_header_button ("go-up-symbolic", "Reset to north-up", "win.north-up");
  gtk_widget_set_visible (self->north_button, FALSE);
  gtk_header_bar_pack_start (GTK_HEADER_BAR (header), self->north_button);

  /* Scheme + view toggles, as in the macOS Chart menu. */
  GMenu *menu = g_menu_new ();
  GMenu *scheme = g_menu_new ();
  g_menu_append (scheme, "Day", "win.set-scheme(0)");
  g_menu_append (scheme, "Dusk", "win.set-scheme(1)");
  g_menu_append (scheme, "Night", "win.set-scheme(2)");
  g_menu_append (scheme, "Cycle", "win.cycle-scheme");
  g_menu_append_section (menu, "Color Scheme", G_MENU_MODEL (scheme));
  g_object_unref (scheme);

  GMenu *toggles = g_menu_new ();
  g_menu_append (toggles, "Text", "win.toggle-text");
  g_menu_append (toggles, "Soundings", "win.toggle-soundings");
  g_menu_append (toggles, "Other Category", "win.toggle-other");
  g_menu_append (toggles, "Coordinates as DMS", "win.use-dms");
  g_menu_append_section (menu, "Show", G_MENU_MODEL (toggles));
  g_object_unref (toggles);

  GtkWidget *view_button = gtk_menu_button_new ();
  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (view_button), "display-brightness-symbolic");
  gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (view_button), G_MENU_MODEL (menu));
  gtk_widget_set_tooltip_text (view_button, "Chart display");
  g_object_unref (menu);

  gtk_header_bar_pack_end (GTK_HEADER_BAR (header),
                           lk_header_button ("preferences-system-symbolic",
                                             "Mariner settings", "win.settings"));
  gtk_header_bar_pack_end (GTK_HEADER_BAR (header), view_button);
  gtk_header_bar_pack_end (GTK_HEADER_BAR (header),
                           lk_header_button ("system-search-symbolic",
                                             "Go to coordinate", "win.search"));
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

  gtk_window_set_default_size (GTK_WINDOW (self->window), 1280, 800);
  gtk_widget_set_size_request (self->window, 720, 520);
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

  GtkWidget *overlay = gtk_overlay_new ();
  gtk_overlay_set_child (GTK_OVERLAY (overlay), self->chart_view);
  gtk_overlay_add_overlay (GTK_OVERLAY (overlay), self->loader);
  gtk_overlay_add_overlay (GTK_OVERLAY (overlay), self->empty_state);
  gtk_widget_set_vexpand (overlay, TRUE);

  /* Texture path: chart is a scene-graph node, so chrome floats over it.
   * Fallback path: chart is a native surface above all widgets, so the HUD
   * moves below it as a status bar (zoom bubbles are already in the headerbar). */
  gboolean floating = lk_chart_view_can_overlay (LK_CHART_VIEW (self->chart_view));

  /* Zoom bubbles, bottom-right, clear of the HUD bar. */
  GtkWidget *zoom = lk_zoom_controls_new (model);
  gtk_widget_set_halign (zoom, GTK_ALIGN_END);
  gtk_widget_set_valign (zoom, GTK_ALIGN_END);
  gtk_widget_set_margin_end (zoom, 12);
  gtk_widget_set_margin_bottom (zoom, 52);
  gtk_widget_set_visible (zoom, floating);
  gtk_overlay_add_overlay (GTK_OVERLAY (overlay), zoom);

  /* Compass, top-right, shown only once the view is turned. */
  GtkWidget *compass = lk_compass_new (model);
  gtk_widget_set_halign (compass, GTK_ALIGN_END);
  gtk_widget_set_valign (compass, GTK_ALIGN_START);
  gtk_widget_set_margin_end (compass, 12);
  gtk_widget_set_margin_top (compass, 12);
  gtk_overlay_add_overlay (GTK_OVERLAY (overlay), compass);

  if (floating)
    gtk_overlay_add_overlay (GTK_OVERLAY (overlay), lk_hud_bar_new (model, TRUE));

  gtk_box_append (GTK_BOX (root), overlay);

  if (!floating)
    {
      gtk_box_append (GTK_BOX (root), gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
      gtk_box_append (GTK_BOX (root), lk_hud_bar_new (model, FALSE));
    }

  gtk_window_set_child (GTK_WINDOW (self->window), root);

  g_signal_connect (model, "notify", G_CALLBACK (lk_window_notify), self);

  lk_window_rebuild_recents (self);
  lk_window_update_title (self);
  lk_window_update_overlays (self);

  return self->window;
}
