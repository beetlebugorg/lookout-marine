/* ui/settings/charts.c — the Charts page.
 *
 * Three lists, and what fills each of them: the chart by link that replaces
 * the portrayal, the library of sets aboard, and the raster charts the mariner
 * installed. All three rebuild off an idle, because a control in a list
 * changes the model and the model signals straight back.
 */
#include "ui/settings/charts.h"
#include "ui/settings/widgets.h"

#include "ui/open-dialogs.h"

static void
lk_charts_archive_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_present_open_archive_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                  settings->model);
}

static void
lk_charts_open_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_present_open_chart_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                settings->model);
}

/* ---- the raster chart list ---------------------------------------------- */

static void
lk_raster_group_toggled (GtkSwitch *widget, GParamSpec *pspec, gpointer user_data)
{
  LkSettings *settings = user_data;
  gboolean on = gtk_switch_get_active (widget);

  if (settings->updating)
    return;

  /* The rebuild this starts frees the switch, and the switch owns the list. */
  g_autoptr (GPtrArray) paths = g_ptr_array_ref (g_object_get_data (G_OBJECT (widget), "lk-paths"));

  /* A mariner turns off Navionics, not four files that happen to be Navionics. */
  for (guint i = 0; i < paths->len; i++)
    lk_app_model_set_raster_enabled (settings->model, g_ptr_array_index (paths, i), on);
}

static void
lk_raster_file_toggled (GtkSwitch *widget, GParamSpec *pspec, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *path = g_object_get_data (G_OBJECT (widget), "lk-path");

  if (settings->updating)
    return;

  lk_app_model_set_raster_enabled (settings->model, path, gtk_switch_get_active (widget));
}

static void
lk_raster_remove_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *path = g_object_get_data (G_OBJECT (button), "lk-path");

  lk_app_model_remove_raster_chart (settings->model, path);
}

static void
lk_raster_add_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_present_add_raster_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                settings->model);
}

static void
lk_raster_add_folder_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_present_add_raster_folder_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                       settings->model);
}

static GtkWidget *
lk_raster_switch (gboolean on)
{
  GtkWidget *widget = gtk_switch_new ();

  gtk_switch_set_active (GTK_SWITCH (widget), on);
  gtk_widget_set_valign (widget, GTK_ALIGN_CENTER);
  return widget;
}

/* One switch for the set, one for each file under it. The set is what the pill
 * cycles and what covers a piece of water; the file is what the mariner
 * downloaded. */
static void
lk_settings_fill_raster_list (LkSettings *settings)
{
  GtkWidget *list = settings->raster.box;
  GtkWidget *child;

  /* Programming a switch must not read back as a mariner moving it. */
  settings->updating = TRUE;

  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  if (lk_app_model_get_raster_count (settings->model) == 0)
    {
      GtkWidget *empty = gtk_label_new ("No raster charts");
      gtk_widget_add_css_class (empty, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (empty), 0.0);
      gtk_box_append (GTK_BOX (list), empty);
      settings->updating = FALSE;
      return;
    }

  g_autoptr (GPtrArray) groups = lk_app_model_get_raster_groups (settings->model);

  for (guint i = 0; i < groups->len; i++)
    {
      const LkRasterGroup *group = g_ptr_array_index (groups, i);
      gboolean any_on = FALSE;

      for (guint j = 0; j < group->paths->len; j++)
        {
          if (lk_app_model_raster_enabled (settings->model, g_ptr_array_index (group->paths, j)))
            any_on = TRUE;
        }

      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      GtkWidget *toggle = lk_raster_switch (any_on);
      GtkWidget *name = gtk_label_new (group->name);
      g_autofree char *count = g_strdup_printf (group->paths->len == 1 ? "%u file" : "%u files",
                                                group->paths->len);
      GtkWidget *files = gtk_label_new (count);

      gtk_widget_add_css_class (name, "heading");
      gtk_label_set_xalign (GTK_LABEL (name), 0.0);
      gtk_widget_set_hexpand (name, TRUE);
      gtk_widget_add_css_class (files, "dim-label");
      gtk_widget_add_css_class (files, "caption");

      /* The switch owns its copies. The group's strings belong to the installed
       * list, and a removal frees them while this row is still on the screen. */
      GPtrArray *owned = g_ptr_array_new_with_free_func (g_free);
      for (guint j = 0; j < group->paths->len; j++)
        g_ptr_array_add (owned, g_strdup (g_ptr_array_index (group->paths, j)));

      g_object_set_data_full (G_OBJECT (toggle), "lk-paths", owned,
                              (GDestroyNotify) g_ptr_array_unref);
      g_signal_connect (toggle, "notify::active", G_CALLBACK (lk_raster_group_toggled), settings);

      gtk_box_append (GTK_BOX (row), toggle);
      gtk_box_append (GTK_BOX (row), name);
      gtk_box_append (GTK_BOX (row), files);
      gtk_widget_set_margin_top (row, 6);
      gtk_box_append (GTK_BOX (list), row);

      for (guint j = 0; j < group->paths->len; j++)
        {
          const char *path = g_ptr_array_index (group->paths, j);
          g_autofree char *base = g_path_get_basename (path);
          gboolean on = lk_app_model_raster_enabled (settings->model, path);

          GtkWidget *file_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
          GtkWidget *file_toggle = lk_raster_switch (on);
          GtkWidget *label = gtk_label_new (base);
          GtkWidget *remove = gtk_button_new_from_icon_name ("list-remove-symbolic");

          gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_MIDDLE);
          gtk_label_set_xalign (GTK_LABEL (label), 0.0);
          gtk_widget_set_hexpand (label, TRUE);
          gtk_widget_add_css_class (label, "caption");
          if (!on)
            gtk_widget_add_css_class (label, "dim-label");

          gtk_button_set_has_frame (GTK_BUTTON (remove), FALSE);
          gtk_widget_set_valign (remove, GTK_ALIGN_CENTER);
          /* The engine cannot drop a chart from a live handle, so a removal
           * switches the picture off now and the chart goes at the next open. */
          gtk_widget_set_tooltip_text (remove, "Remove. The picture goes at once.");
          gtk_accessible_update_property (GTK_ACCESSIBLE (remove),
                                          GTK_ACCESSIBLE_PROPERTY_LABEL, "Remove raster chart", -1);

          g_object_set_data_full (G_OBJECT (file_toggle), "lk-path", g_strdup (path), g_free);
          g_object_set_data_full (G_OBJECT (remove), "lk-path", g_strdup (path), g_free);
          g_signal_connect (file_toggle, "notify::active",
                            G_CALLBACK (lk_raster_file_toggled), settings);
          g_signal_connect (remove, "clicked", G_CALLBACK (lk_raster_remove_clicked), settings);

          gtk_widget_set_margin_start (file_row, 22);
          gtk_box_append (GTK_BOX (file_row), file_toggle);
          gtk_box_append (GTK_BOX (file_row), label);
          gtk_box_append (GTK_BOX (file_row), remove);
          gtk_box_append (GTK_BOX (list), file_row);
        }
    }
  settings->updating = FALSE;
}

/* A raster chart added or removed anywhere, this list included. */
void
lk_settings_raster_changed (LkAppModel *model, gpointer user_data)
{
  LkSettings *settings = g_object_get_data (G_OBJECT (user_data), "lk-settings");

  if (settings != NULL)
    lk_deferred_list_schedule (&settings->raster);
}

/* ---- charts by link ------------------------------------------------------ */

static void
lk_link_radio_toggled (GtkCheckButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  /* NULL data is the "Lookout chart" radio, and NULL is how the links object
   * spells "lookout's own chart". */
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");

  if (settings->updating || !gtk_check_button_get_active (button))
    return;
  lk_chart_links_select (lk_app_model_get_chart_links (settings->model), url);
}

static void
lk_link_refresh_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");

  lk_chart_links_refresh (lk_app_model_get_chart_links (settings->model), url);
}

static void
lk_link_remove_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");

  lk_chart_links_remove (lk_app_model_get_chart_links (settings->model), url);
}

static void
lk_link_add_from (LkSettings *settings, GtkEntry *entry)
{
  const char *text = gtk_editable_get_text (GTK_EDITABLE (entry));

  if (text == NULL || text[0] == '\0')
    return;
  lk_chart_links_add (lk_app_model_get_chart_links (settings->model), text);
  gtk_editable_set_text (GTK_EDITABLE (entry), "");
}

static void
lk_link_entry_activated (GtkEntry *entry, gpointer user_data)
{
  lk_link_add_from (user_data, entry);
}

static void
lk_link_add_clicked (GtkButton *button, gpointer user_data)
{
  lk_link_add_from (user_data, g_object_get_data (G_OBJECT (button), "lk-entry"));
}

/* The chart election: lookout's own chart, or one of the added links. One
 * radio group — a linked chart is an entire separate chart, not an overlay,
 * so exactly one of these is ever drawn. */
static void
lk_settings_fill_links_list (LkSettings *settings)
{
  GtkWidget *list = settings->links.box;
  GtkWidget *child;
  LkChartLinks *links = lk_app_model_get_chart_links (settings->model);
  const char *active = lk_chart_links_active (links);
  const char *error = lk_chart_links_error (links);

  /* Programming a radio must not read back as a mariner picking it. */
  settings->updating = TRUE;

  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  GtkWidget *own = gtk_check_button_new_with_label ("Lookout chart");
  gtk_check_button_set_active (GTK_CHECK_BUTTON (own), active == NULL);
  g_signal_connect (own, "toggled", G_CALLBACK (lk_link_radio_toggled), settings);
  gtk_box_append (GTK_BOX (list), own);

  GPtrArray *all = lk_chart_links_list (links);
  for (guint i = 0; i < all->len; i++)
    {
      const LkChartLink *link = g_ptr_array_index (all, i);
      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 4);
      GtkWidget *radio = gtk_check_button_new_with_label (link->name);
      GtkWidget *refresh = gtk_button_new_from_icon_name ("view-refresh-symbolic");
      GtkWidget *remove = gtk_button_new_from_icon_name ("list-remove-symbolic");

      gtk_check_button_set_group (GTK_CHECK_BUTTON (radio), GTK_CHECK_BUTTON (own));
      gtk_check_button_set_active (GTK_CHECK_BUTTON (radio),
                                   g_strcmp0 (active, link->url) == 0);
      gtk_widget_set_hexpand (radio, TRUE);
      gtk_widget_set_tooltip_text (radio, link->url);
      g_object_set_data_full (G_OBJECT (radio), "lk-url", g_strdup (link->url), g_free);
      g_signal_connect (radio, "toggled", G_CALLBACK (lk_link_radio_toggled), settings);

      gtk_button_set_has_frame (GTK_BUTTON (refresh), FALSE);
      gtk_widget_set_valign (refresh, GTK_ALIGN_CENTER);
      gtk_widget_set_tooltip_text (refresh,
                                   "Re-read the link. A link that doesn't answer "
                                   "leaves the chart as it is.");
      g_object_set_data_full (G_OBJECT (refresh), "lk-url", g_strdup (link->url), g_free);
      g_signal_connect (refresh, "clicked", G_CALLBACK (lk_link_refresh_clicked), settings);

      gtk_button_set_has_frame (GTK_BUTTON (remove), FALSE);
      gtk_widget_set_valign (remove, GTK_ALIGN_CENTER);
      gtk_widget_set_tooltip_text (remove, "Forget this link");
      gtk_accessible_update_property (GTK_ACCESSIBLE (remove),
                                      GTK_ACCESSIBLE_PROPERTY_LABEL, "Forget this link", -1);
      g_object_set_data_full (G_OBJECT (remove), "lk-url", g_strdup (link->url), g_free);
      g_signal_connect (remove, "clicked", G_CALLBACK (lk_link_remove_clicked), settings);

      gtk_box_append (GTK_BOX (row), radio);
      gtk_box_append (GTK_BOX (row), refresh);
      gtk_box_append (GTK_BOX (row), remove);
      gtk_box_append (GTK_BOX (list), row);
    }

  /* A resolve is several fetches deep, so say so rather than leave the list
   * looking as though the click did nothing. */
  if (lk_chart_links_busy (links))
    {
      GtkWidget *label = gtk_label_new ("Reading the chart…");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_widget_add_css_class (label, "caption");
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (list), label);
    }

  if (error[0] != '\0')
    {
      GtkWidget *label = gtk_label_new (error);
      gtk_widget_add_css_class (label, "error");
      gtk_widget_add_css_class (label, "caption");
      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (list), label);
    }
  settings->updating = FALSE;
}

/* A chart link resolving, failing, or being picked. */
void
lk_settings_links_changed (LkChartLinks *links, gpointer user_data)
{
  LkSettings *settings = g_object_get_data (G_OBJECT (user_data), "lk-settings");

  if (settings != NULL)
    lk_deferred_list_schedule (&settings->links);
}

/* ---- the chart library --------------------------------------------------- */

static void
lk_chart_set_toggled (GtkSwitch *widget, GParamSpec *pspec, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *path = g_object_get_data (G_OBJECT (widget), "lk-path");

  if (settings->updating)
    return;
  lk_app_model_set_chart_set_on (settings->model, path, gtk_switch_get_active (widget));
}

/* The removal question outlives the button that raised it, so it carries the
   window (held by a reference) and the set's path. The settings struct hangs
   off the window, so a settings window closed while the question stands is not
   freed under the answer. */
typedef struct {
  GtkWindow *window; /* reffed */
  char      *path;
} LkSetRemoveAsk;

static void
lk_set_remove_ask_free (LkSetRemoveAsk *ask)
{
  g_clear_object (&ask->window);
  g_free (ask->path);
  g_free (ask);
}

/* The reference's estimate: about 0.2 s to rebuild each prepared chart. */
static char *
lk_rebuild_estimate (guint charts)
{
  double seconds = charts * 0.2;

  if (seconds < 60)
    return g_strdup ("under a minute");
  if (seconds < 3600)
    return g_strdup_printf ("about %d minutes", (int) ((seconds / 60) + 0.5));
  return g_strdup_printf ("about %.1f hours", seconds / 3600);
}

static void
lk_chart_set_remove_answered (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkSetRemoveAsk *ask = user_data;
  g_autoptr (GError) error = NULL;
  int chosen = gtk_alert_dialog_choose_finish (GTK_ALERT_DIALOG (source), result, &error);

  /* Cancel is 0, Remove is 1. Act only while the window still stands. */
  if (chosen == 1 && ask->window != NULL &&
      !gtk_widget_in_destruction (GTK_WIDGET (ask->window)))
    {
      LkSettings *settings = g_object_get_data (G_OBJECT (ask->window), "lk-settings");
      if (settings != NULL)
        lk_app_model_remove_chart_set (settings->model, ask->path);
    }

  lk_set_remove_ask_free (ask);
}

/* Removing a set deletes the charts Lookout prepared from it, and re-adding it
 * rebuilds them, so the removal is asked about first — as the reference does. */
static void
lk_chart_set_remove_clicked (GtkButton *button, gpointer user_data)
{
  const char *path = g_object_get_data (G_OBJECT (button), "lk-path");
  const char *name = g_object_get_data (G_OBJECT (button), "lk-set-title");
  guint charts = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (button), "lk-set-charts"));
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
  g_autofree char *question = g_strdup_printf ("Remove %s?", name != NULL ? name : "this set");
  static const char *answers[] = { "Cancel", "Remove and delete prepared charts", NULL };

  g_autofree char *detail = NULL;
  if (charts > 0)
    {
      g_autofree char *estimate = lk_rebuild_estimate (charts);
      detail = g_strdup_printf ("This deletes the %u charts Lookout prepared from it. Your "
                                "folder is not touched. Re-adding it rebuilds them, %s.",
                                charts, estimate);
    }
  else
    detail = g_strdup ("This deletes the charts Lookout prepared from it. Your folder "
                       "is not touched.");

  GtkAlertDialog *dialog = gtk_alert_dialog_new ("%s", question);
  gtk_alert_dialog_set_detail (dialog, detail);
  gtk_alert_dialog_set_buttons (dialog, answers);
  gtk_alert_dialog_set_cancel_button (dialog, 0);
  gtk_alert_dialog_set_default_button (dialog, 0);

  LkSetRemoveAsk *ask = g_new0 (LkSetRemoveAsk, 1);
  ask->window = GTK_IS_WINDOW (root) ? g_object_ref (GTK_WINDOW (root)) : NULL;
  ask->path = g_strdup (path);
  gtk_alert_dialog_choose (dialog, ask->window, NULL, lk_chart_set_remove_answered, ask);
  g_object_unref (dialog);
}

/* What is aboard, and what is being sailed on: a switch and a title per set,
 * the folder underneath so two sets from the same office are told apart, and
 * what the background scan counted once it has. */
static void
lk_settings_fill_sets_list (LkSettings *settings)
{
  GtkWidget *list = settings->sets.box;
  GtkWidget *child;

  settings->updating = TRUE;
  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  g_autoptr (GPtrArray) rows = lk_app_model_get_chart_sets (settings->model);
  if (rows->len == 0)
    {
      GtkWidget *empty = gtk_label_new ("No chart sets yet");
      gtk_widget_add_css_class (empty, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (empty), 0.0);
      gtk_box_append (GTK_BOX (list), empty);
      settings->updating = FALSE;
      return;
    }

  for (guint i = 0; i < rows->len; i++)
    {
      const LkChartSetRow *set = g_ptr_array_index (rows, i);
      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      GtkWidget *toggle = lk_raster_switch (set->on);
      GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 1);
      GtkWidget *title = gtk_label_new (set->title);
      g_autofree char *base = g_path_get_basename (set->path);
      GtkWidget *where = gtk_label_new (base);
      GtkWidget *remove = gtk_button_new_from_icon_name ("list-remove-symbolic");

      gtk_widget_add_css_class (title, "heading");
      gtk_label_set_xalign (GTK_LABEL (title), 0.0);
      gtk_label_set_ellipsize (GTK_LABEL (title), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class (where, "dim-label");
      gtk_widget_add_css_class (where, "caption");
      gtk_label_set_xalign (GTK_LABEL (where), 0.0);
      gtk_label_set_ellipsize (GTK_LABEL (where), PANGO_ELLIPSIZE_MIDDLE);
      /* The agency title can hide the folder name; the tooltip keeps the
       * whole path reachable. */
      gtk_widget_set_tooltip_text (row, set->path);

      gtk_box_append (GTK_BOX (column), title);
      gtk_box_append (GTK_BOX (column), where);
      if (set->detail[0] != '\0')
        {
          GtkWidget *detail = gtk_label_new (set->detail);
          gtk_widget_add_css_class (detail, "dim-label");
          gtk_widget_add_css_class (detail, "caption");
          gtk_label_set_xalign (GTK_LABEL (detail), 0.0);
          gtk_label_set_ellipsize (GTK_LABEL (detail), PANGO_ELLIPSIZE_END);
          gtk_box_append (GTK_BOX (column), detail);
        }
      gtk_widget_set_hexpand (column, TRUE);

      gtk_button_set_has_frame (GTK_BUTTON (remove), FALSE);
      gtk_widget_set_valign (remove, GTK_ALIGN_CENTER);
      gtk_widget_set_tooltip_text (remove,
                                   "Remove from the library. Charts Lookout prepared "
                                   "from it are deleted; your folder is not touched.");
      gtk_accessible_update_property (GTK_ACCESSIBLE (remove),
                                      GTK_ACCESSIBLE_PROPERTY_LABEL, "Remove chart set", -1);

      g_object_set_data_full (G_OBJECT (toggle), "lk-path", g_strdup (set->path), g_free);
      g_object_set_data_full (G_OBJECT (remove), "lk-path", g_strdup (set->path), g_free);
      g_object_set_data_full (G_OBJECT (remove), "lk-set-title", g_strdup (set->title), g_free);
      g_object_set_data (G_OBJECT (remove), "lk-set-charts", GUINT_TO_POINTER (set->charts));
      g_signal_connect (toggle, "notify::active", G_CALLBACK (lk_chart_set_toggled), settings);
      g_signal_connect (remove, "clicked", G_CALLBACK (lk_chart_set_remove_clicked), settings);

      gtk_box_append (GTK_BOX (row), toggle);
      gtk_box_append (GTK_BOX (row), column);
      gtk_box_append (GTK_BOX (row), remove);
      gtk_box_append (GTK_BOX (list), row);
    }
  settings->updating = FALSE;
}

/* A set arriving or leaving, and a background scan landing a title. */
void
lk_settings_sets_changed (LkAppModel *model, gpointer user_data)
{
  LkSettings *settings = g_object_get_data (G_OBJECT (user_data), "lk-settings");

  if (settings != NULL)
    lk_deferred_list_schedule (&settings->sets);
}

void
lk_build_charts_page (LkSettings *settings)
{
  GtkWidget *page = lk_page_new (settings, "charts", "Charts",
                                 "lk-charts-symbolic");

  /* WHICH chart is drawn, before where to get more of them. A chart by link
   * is a different kind again — a publisher's live map drawn AS the chart —
   * and picking one replaces the whole portrayal, so the election stands
   * first, as it does on the other shells. */
  GtkWidget *chart = lk_section (page, "Chart");
  lk_deferred_list_bind (&settings->links, settings,
                         gtk_box_new (GTK_ORIENTATION_VERTICAL, 4),
                         lk_settings_fill_links_list);
  gtk_box_append (GTK_BOX (chart), settings->links.box);
  lk_settings_fill_links_list (settings);

  GtkWidget *link_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *link_entry = gtk_entry_new ();
  GtkWidget *link_add = gtk_button_new_with_label ("Add Chart Link");

  gtk_entry_set_placeholder_text (GTK_ENTRY (link_entry),
                                  "Link to a MapLibre style or TileJSON…");
  gtk_widget_set_hexpand (link_entry, TRUE);
  g_signal_connect (link_entry, "activate", G_CALLBACK (lk_link_entry_activated), settings);
  g_object_set_data (G_OBJECT (link_add), "lk-entry", link_entry);
  g_signal_connect (link_add, "clicked", G_CALLBACK (lk_link_add_clicked), settings);
  gtk_widget_set_margin_top (link_row, 6);
  gtk_box_append (GTK_BOX (link_row), link_entry);
  gtk_box_append (GTK_BOX (link_row), link_add);
  gtk_box_append (GTK_BOX (chart), link_row);

  lk_footer (chart,
             "A chart by link is an online map drawn as the chart: paste the "
             "style link a publisher shares and sail on their portrayal, tiles "
             "fetched live. The Lookout chart and its display settings stand "
             "aside while one is picked.");

  GtkWidget *open = lk_section (page, "Open");
  const char *path = lk_app_model_get_chart_path (settings->model);
  if (path != NULL)
    {
      g_autofree char *name = g_path_get_basename (path);
      GtkWidget *label = gtk_label_new (name);
      gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_MIDDLE);
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (open), label);
    }
  else
    {
      GtkWidget *label = gtk_label_new ("No chart open");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (open), label);
    }

  /* The library: the sets aboard, each with its switch. This is what decides
   * the chart; Open above only reports what is on screen now. */
  GtkWidget *library = lk_section (page, "Chart library");
  lk_deferred_list_bind (&settings->sets, settings,
                         gtk_box_new (GTK_ORIENTATION_VERTICAL, 8),
                         lk_settings_fill_sets_list);
  gtk_box_append (GTK_BOX (library), settings->sets.box);
  lk_settings_fill_sets_list (settings);
  lk_footer (library,
             "Each folder or archive added is a set. The chart is every set "
             "switched on, drawn as one seamless library; a set switched off "
             "stays aboard and out of the chart.");

  GtkWidget *add = lk_section (page, NULL);
  GtkWidget *add_buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *button = gtk_button_new_with_label ("Add Folder…");
  GtkWidget *archive = gtk_button_new_with_label ("Add Archive…");

  g_signal_connect (button, "clicked", G_CALLBACK (lk_charts_open_clicked), settings);
  g_signal_connect (archive, "clicked", G_CALLBACK (lk_charts_archive_clicked), settings);
  gtk_box_append (GTK_BOX (add_buttons), button);
  gtk_box_append (GTK_BOX (add_buttons), archive);
  gtk_widget_set_halign (add_buttons, GTK_ALIGN_START);
  gtk_box_append (GTK_BOX (add), add_buttons);
  lk_footer (add,
             "A folder of cells, or the .zip a chart agency publishes, opens as one "
             "seamless library. Cells that arrive as raw S-57 survey data are prepared "
             "first, coarse charts before harbour detail, so a passage is covered even "
             "if the import is stopped part way. An archive is read where it lies: "
             "nothing is unpacked.");

  /* A raster chart is a different KIND of chart, so it gets its own section
   * rather than a mixed list: one is the survey, the other is a picture of the
   * water, and a mariner must never lose track of which is which. */
  GtkWidget *raster = lk_section (page, "Raster charts");
  lk_deferred_list_bind (&settings->raster, settings,
                         gtk_box_new (GTK_ORIENTATION_VERTICAL, 4),
                         lk_settings_fill_raster_list);
  gtk_box_append (GTK_BOX (raster), settings->raster.box);
  lk_settings_fill_raster_list (settings);

  GtkWidget *raster_buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *add_files = gtk_button_new_with_label ("Add Raster Charts…");
  GtkWidget *add_folder = gtk_button_new_with_label ("Add Folder…");

  g_signal_connect (add_files, "clicked", G_CALLBACK (lk_raster_add_clicked), settings);
  g_signal_connect (add_folder, "clicked", G_CALLBACK (lk_raster_add_folder_clicked), settings);
  gtk_box_append (GTK_BOX (raster_buttons), add_files);
  gtk_box_append (GTK_BOX (raster_buttons), add_folder);
  gtk_widget_set_halign (raster_buttons, GTK_ALIGN_START);
  gtk_widget_set_margin_top (raster_buttons, 6);
  gtk_box_append (GTK_BOX (raster), raster_buttons);

  lk_footer (raster,
             "Charts made of pictures: MBTiles of satellite imagery or another "
             "vendor's charts, and BSB/KAP raster nautical charts baked with tile57. "
             "The ENC draws over them and drops its depth and land shading only "
             "where they cover. Switch one off to keep it installed without "
             "drawing it.");

  lk_plugin_fill_tab (page, settings, "charts");
}
