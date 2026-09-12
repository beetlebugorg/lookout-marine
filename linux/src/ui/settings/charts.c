/* ui/settings/charts.c — the Charts page.
 *
 * In the order a mariner asks: which chart is DRAWN, what it is built from,
 * what is arriving now, and where to get more.
 *
 * NO SEPARATE PICTURE LIST. A picture and a survey are different kinds of
 * chart, and the row says which, but they are the same kind of THING TO ADD:
 * they arrive in the same folders and switch on the same way. Two lists made
 * the mariner remember which panel a file had gone into, and a folder holding
 * both could only be half added.
 *
 * Where they differ is what a switch MEANS. Surveys compose, so a set is on or
 * off. Only one picture can cover a piece of water, so the pictures inside a
 * set get a switch each, by whoever made them.
 *
 * Every list rebuilds off an idle, because a control in a list changes the
 * model and the model signals straight back.
 */
#include "ui/settings/charts.h"
#include "ui/settings/widgets.h"

#include "library/bake.h"
#include "ui/charts/band-ramp.h"
#include "ui/charts/gallery.h"
#include "ui/charts/noaa-window.h"
#include "ui/open-dialogs.h"

/* ---- the ways in --------------------------------------------------------- */

/* NOAA's own charts, in the picker's own window. The map wants 1040 points and
 * this pane is about 550, so it opens beside the form. */
static void
lk_charts_noaa_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_noaa_window_present (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
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

static void
lk_charts_file_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
  GtkWidget *popover = gtk_widget_get_ancestor (GTK_WIDGET (button), GTK_TYPE_POPOVER);

  if (popover != NULL)
    gtk_popover_popdown (GTK_POPOVER (popover));
  lk_present_open_chart_file_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                     settings->model);
}

static void
lk_charts_folder_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkWidget *popover = gtk_widget_get_ancestor (GTK_WIDGET (button), GTK_TYPE_POPOVER);

  if (popover != NULL)
    gtk_popover_popdown (GTK_POPOVER (popover));
  lk_charts_open_clicked (button, settings);
}

/* ---- the active chart ---------------------------------------------------- */

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

/* The gallery's last tile. Adding a chart by link is what this page already
 * offers below, so the tile takes the mariner to it. */
static void
lk_charts_add_link_asked (gpointer user_data)
{
  LkSettings *settings = user_data;

  if (settings->link_entry != NULL)
    gtk_widget_grab_focus (settings->link_entry);
}

/* What the gallery cannot say for itself: that a resolve is in flight, why the
 * last one failed, and that a linked chart takes the display settings out of
 * the mariner's hands while it draws.
 *
 * The last of those is said only WHILE a link draws, because that is when the
 * rest of this window stops shaping the chart and the mariner is owed a
 * reason. That a tile draws when it is picked needs no saying. */
static void
lk_settings_fill_links_list (LkSettings *settings)
{
  GtkWidget *list = settings->links.box;
  LkChartLinks *links = lk_app_model_get_chart_links (settings->model);
  const char *error = lk_chart_links_error (links);
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  if (lk_chart_links_busy (links))
    {
      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
      GtkWidget *spinner = gtk_spinner_new ();
      GtkWidget *label = gtk_label_new ("Reading the chart…");

      gtk_spinner_set_spinning (GTK_SPINNER (spinner), TRUE);
      gtk_widget_set_valign (spinner, GTK_ALIGN_CENTER);
      gtk_widget_add_css_class (label, "dim-label");
      gtk_widget_add_css_class (label, "caption");
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (row), spinner);
      gtk_box_append (GTK_BOX (row), label);
      gtk_box_append (GTK_BOX (list), row);
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

  if (lk_chart_links_active (links) != NULL)
    {
      GtkWidget *label = gtk_label_new (
          "While a linked chart draws, the display, depth and symbol settings do not "
          "shape it. You are seeing its publisher's own portrayal.");

      gtk_widget_add_css_class (label, "dim-label");
      gtk_widget_add_css_class (label, "caption");
      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (list), label);
    }
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

/* Removing a set this app PREPARED deletes work that has to be done again, so
 * that one is asked about first. A folder of the mariner's own files is a list
 * entry, and taking it off the list touches nothing, so it goes without a
 * question. */
static void
lk_chart_set_remove_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *path = g_object_get_data (G_OBJECT (button), "lk-path");
  const char *name = g_object_get_data (G_OBJECT (button), "lk-set-title");
  guint charts = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (button), "lk-set-charts"));
  gboolean derived = g_object_get_data (G_OBJECT (button), "lk-set-derived") != NULL;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
  g_autofree char *question = NULL;
  g_autofree char *detail = NULL;
  static const char *answers[] = { "Cancel", "Remove and delete prepared charts", NULL };

  if (!derived)
    {
      lk_app_model_remove_chart_set (settings->model, path);
      return;
    }

  question = g_strdup_printf ("Remove %s?", name != NULL ? name : "this set");
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

/* ---- the pictures, under the set they came in with ----------------------- */

static void
lk_raster_group_toggled (GtkSwitch *widget, GParamSpec *pspec, gpointer user_data)
{
  LkSettings *settings = user_data;
  gboolean on = gtk_switch_get_active (widget);

  if (settings->updating)
    return;

  /* The rebuild this starts frees the switch, and the switch owns the list. */
  g_autoptr (GPtrArray) paths =
      g_ptr_array_ref (g_object_get_data (G_OBJECT (widget), "lk-paths"));

  /* A mariner turns off Navionics, not four files that happen to be Navionics. */
  for (guint i = 0; i < paths->len; i++)
    lk_app_model_set_raster_enabled (settings->model, g_ptr_array_index (paths, i), on);
}

static void
lk_raster_remove_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  g_autoptr (GPtrArray) paths =
      g_ptr_array_ref (g_object_get_data (G_OBJECT (button), "lk-paths"));

  for (guint i = 0; i < paths->len; i++)
    lk_app_model_remove_raster_chart (settings->model, g_ptr_array_index (paths, i));
}

static GtkWidget *
lk_settings_switch (gboolean on)
{
  GtkWidget *widget = gtk_switch_new ();

  gtk_switch_set_active (GTK_SWITCH (widget), on);
  gtk_widget_set_valign (widget, GTK_ALIGN_CENTER);
  return widget;
}

/* TRUE when this picture came in with this set: it lives in the folder the
 * mariner added, or in the directory the bake prepared from it. */
static gboolean
lk_raster_belongs_to (const char *raster_path, const char *set_path)
{
  g_autofree char *prepared = lk_chart_bake_prepared_dir (set_path);

  return g_str_has_prefix (raster_path, set_path) ||
         (prepared != NULL && g_str_has_prefix (raster_path, prepared));
}

/* One provider's pictures: a switch, the name, and how many files. A provider
 * is what covers a piece of water, so a folder of two hundred tiles from one
 * survey is one decision. */
static void
lk_raster_group_row (LkSettings *settings, GtkWidget *list, const LkRasterGroup *group,
                     gboolean nested)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  gboolean any_on = FALSE;
  GPtrArray *owned = g_ptr_array_new_with_free_func (g_free);

  for (guint i = 0; i < group->paths->len; i++)
    {
      const char *path = g_ptr_array_index (group->paths, i);

      if (lk_app_model_raster_enabled (settings->model, path))
        any_on = TRUE;
      /* The switch owns its copies. The group's strings belong to the
       * installed list, and a removal frees them while this row is still on
       * the screen. */
      g_ptr_array_add (owned, g_strdup (path));
    }

  GtkWidget *toggle = lk_settings_switch (any_on);
  GtkWidget *icon = gtk_image_new_from_icon_name ("image-x-generic-symbolic");
  GtkWidget *name = gtk_label_new (group->name);
  g_autofree char *count = g_strdup_printf (group->paths->len == 1 ? "%u file" : "%u files",
                                            group->paths->len);
  GtkWidget *files = gtk_label_new (count);
  GtkWidget *remove = gtk_button_new_from_icon_name ("list-remove-symbolic");

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 12);
  gtk_widget_add_css_class (icon, "dim-label");
  gtk_widget_add_css_class (name, "caption");
  if (!any_on)
    gtk_widget_add_css_class (name, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_label_set_ellipsize (GTK_LABEL (name), PANGO_ELLIPSIZE_END);
  gtk_widget_set_hexpand (name, TRUE);
  gtk_widget_add_css_class (files, "dim-label");
  gtk_widget_add_css_class (files, "caption");

  gtk_button_set_has_frame (GTK_BUTTON (remove), FALSE);
  gtk_widget_set_valign (remove, GTK_ALIGN_CENTER);
  /* The engine cannot drop a chart from a live handle, so a removal switches
   * the picture off now and the chart goes at the next open. */
  gtk_widget_set_tooltip_text (remove, "Remove. The picture goes at once.");
  gtk_accessible_update_property (GTK_ACCESSIBLE (remove),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL, "Remove these pictures",
                                  -1);

  g_object_set_data_full (G_OBJECT (toggle), "lk-paths", g_ptr_array_ref (owned),
                          (GDestroyNotify) g_ptr_array_unref);
  g_object_set_data_full (G_OBJECT (remove), "lk-paths", owned,
                          (GDestroyNotify) g_ptr_array_unref);
  g_signal_connect (toggle, "notify::active", G_CALLBACK (lk_raster_group_toggled),
                    settings);
  g_signal_connect (remove, "clicked", G_CALLBACK (lk_raster_remove_clicked), settings);

  gtk_box_append (GTK_BOX (row), toggle);
  gtk_box_append (GTK_BOX (row), icon);
  gtk_box_append (GTK_BOX (row), name);
  gtk_box_append (GTK_BOX (row), files);
  gtk_box_append (GTK_BOX (row), remove);
  if (nested)
    gtk_widget_set_margin_start (row, 30);
  gtk_box_append (GTK_BOX (list), row);
}

/* ---- the set list -------------------------------------------------------- */

/* What every installed set holds together, for the section header. */
static char *
lk_sets_summary (GPtrArray *rows)
{
  guint charts = 0;
  gint64 bytes = 0;
  gboolean scanned = FALSE;

  for (guint i = 0; i < rows->len; i++)
    {
      const LkChartSetRow *set = g_ptr_array_index (rows, i);

      charts += set->charts + set->unprepared + set->pictures;
      bytes += set->bytes;
      scanned |= set->scanned;
    }

  /* Nothing to say until a scan has read something. "0 charts" of a library
   * that holds thousands is worse than saying nothing yet. */
  if (!scanned || charts == 0)
    return g_strdup ("");

  g_autofree char *size = g_format_size (bytes);
  return g_strdup_printf ("%u charts · %s", charts, size);
}

static void
lk_settings_fill_sets_list (LkSettings *settings)
{
  GtkWidget *list = settings->sets.box;
  GtkWidget *child;

  settings->updating = TRUE;
  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  g_autoptr (GPtrArray) rows = lk_app_model_get_chart_sets (settings->model);
  g_autoptr (GPtrArray) groups = lk_app_model_get_raster_groups (settings->model);

  if (settings->sets_summary != NULL)
    {
      g_autofree char *summary = lk_sets_summary (rows);
      gtk_label_set_text (GTK_LABEL (settings->sets_summary), summary);
    }

  if (rows->len == 0 && groups->len == 0)
    {
      GtkWidget *empty = gtk_label_new ("No chart sets yet");

      gtk_widget_add_css_class (empty, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (empty), 0.0);
      gtk_box_append (GTK_BOX (list), empty);
      settings->updating = FALSE;
      return;
    }

  /* Which pictures have a set to sit under. What is left came in on its own. */
  g_autoptr (GHashTable) placed = g_hash_table_new (g_direct_hash, g_direct_equal);

  for (guint i = 0; i < rows->len; i++)
    {
      const LkChartSetRow *set = g_ptr_array_index (rows, i);
      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      GtkWidget *toggle = lk_settings_switch (set->on);
      GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 1);
      GtkWidget *title = gtk_label_new (set->title);
      GtkWidget *remove = gtk_button_new_from_icon_name ("list-remove-symbolic");

      gtk_widget_add_css_class (title, "heading");
      gtk_label_set_xalign (GTK_LABEL (title), 0.0);
      gtk_label_set_ellipsize (GTK_LABEL (title), PANGO_ELLIPSIZE_END);
      gtk_box_append (GTK_BOX (column), title);

      /* Where it came from, under what it is. Two sets from one office share a
       * title, so the folder still shows. */
      if (g_strcmp0 (set->title, set->name) != 0)
        {
          GtkWidget *where = gtk_label_new (set->name);

          gtk_widget_add_css_class (where, "dim-label");
          gtk_widget_add_css_class (where, "caption");
          gtk_label_set_xalign (GTK_LABEL (where), 0.0);
          gtk_label_set_ellipsize (GTK_LABEL (where), PANGO_ELLIPSIZE_MIDDLE);
          gtk_box_append (GTK_BOX (column), where);
        }
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

      /* The agency title can hide the folder name; the tooltip keeps the
       * whole path reachable. */
      gtk_widget_set_tooltip_text (row, set->path);

      gtk_button_set_has_frame (GTK_BUTTON (remove), FALSE);
      gtk_widget_set_valign (remove, GTK_ALIGN_CENTER);
      gtk_widget_set_tooltip_text (remove,
                                   set->derived
                                       ? "Remove from the library. Charts Lookout prepared "
                                         "from it are deleted; your folder is not touched."
                                       : "Take these charts out of the list. Your files "
                                         "stay where they are.");
      gtk_accessible_update_property (GTK_ACCESSIBLE (remove),
                                      GTK_ACCESSIBLE_PROPERTY_LABEL, "Remove chart set", -1);

      g_object_set_data_full (G_OBJECT (toggle), "lk-path", g_strdup (set->path), g_free);
      g_object_set_data_full (G_OBJECT (remove), "lk-path", g_strdup (set->path), g_free);
      g_object_set_data_full (G_OBJECT (remove), "lk-set-title", g_strdup (set->title),
                              g_free);
      g_object_set_data (G_OBJECT (remove), "lk-set-charts", GUINT_TO_POINTER (set->charts));
      if (set->derived)
        g_object_set_data (G_OBJECT (remove), "lk-set-derived", GINT_TO_POINTER (1));
      g_signal_connect (toggle, "notify::active", G_CALLBACK (lk_chart_set_toggled),
                        settings);
      g_signal_connect (remove, "clicked", G_CALLBACK (lk_chart_set_remove_clicked),
                        settings);

      gtk_box_append (GTK_BOX (row), toggle);
      gtk_box_append (GTK_BOX (row), column);
      gtk_box_append (GTK_BOX (row), remove);
      gtk_widget_set_margin_top (row, 6);
      gtk_box_append (GTK_BOX (list), row);

      /* What scales it holds. A set that stops at Coastal does not draw the
       * harbour a passage ends in. */
      if (lk_band_ramp_count (set->bands) > 0)
        {
          GtkWidget *ramp = lk_band_ramp_new (set->bands);

          gtk_widget_set_margin_start (ramp, 30);
          gtk_widget_set_opacity (ramp, set->on ? 1.0 : 0.5);
          gtk_box_append (GTK_BOX (list), ramp);
        }

      /* What is still to prepare. */
      if (set->unprepared > 0)
        {
          g_autofree char *text = g_strdup_printf ("%u to prepare", set->unprepared);
          GtkWidget *label = gtk_label_new (text);

          gtk_widget_add_css_class (label, "dim-label");
          gtk_widget_add_css_class (label, "caption");
          gtk_label_set_xalign (GTK_LABEL (label), 0.0);
          gtk_widget_set_margin_start (label, 30);
          gtk_box_append (GTK_BOX (list), label);
        }

      /* The pictures this set came in with. */
      for (guint g = 0; g < groups->len; g++)
        {
          const LkRasterGroup *group = g_ptr_array_index (groups, g);

          if (group->paths->len == 0 ||
              !lk_raster_belongs_to (g_ptr_array_index (group->paths, 0), set->path))
            continue;
          g_hash_table_add (placed, (gpointer) group);
          lk_raster_group_row (settings, list, group, TRUE);
        }
    }

  /* A picture the mariner added on its own belongs to no set, and still has to
   * be switchable and removable. */
  gboolean loose = FALSE;
  for (guint g = 0; g < groups->len; g++)
    {
      const LkRasterGroup *group = g_ptr_array_index (groups, g);

      if (g_hash_table_contains (placed, group))
        continue;
      if (!loose)
        {
          GtkWidget *heading = gtk_label_new ("Pictures added on their own");

          gtk_widget_add_css_class (heading, "dim-label");
          gtk_widget_add_css_class (heading, "caption");
          gtk_label_set_xalign (GTK_LABEL (heading), 0.0);
          gtk_widget_set_margin_top (heading, 8);
          gtk_box_append (GTK_BOX (list), heading);
          loose = TRUE;
        }
      lk_raster_group_row (settings, list, group, FALSE);
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

/* A raster chart added or removed anywhere. The pictures are rows of the set
 * list now, so one list answers both. */
void
lk_settings_raster_changed (LkAppModel *model, gpointer user_data)
{
  LkSettings *settings = g_object_get_data (G_OBJECT (user_data), "lk-settings");

  if (settings != NULL)
    lk_deferred_list_schedule (&settings->sets);
}

/* ---- what is arriving now ------------------------------------------------ */

static void
lk_noaa_cancel_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;

  lk_noaa_cancel (lk_app_model_get_noaa (settings->model));
}

static void
lk_bake_cancel_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;

  lk_app_model_cancel_bake (settings->model);
}

/* A NOAA download and a bake, each shown only while it runs.
 *
 * THIS WINDOW STANDS OVER THE CHART, so a transfer begun here otherwise runs
 * behind it with nothing to say where it got to. */
static void
lk_settings_fill_work_list (LkSettings *settings)
{
  GtkWidget *list = settings->work.box;
  const LkNoaaState *noaa = lk_noaa_state (lk_app_model_get_noaa (settings->model));
  const LkBakeProgress *bake = lk_app_model_get_bake_progress (settings->model);
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  if (noaa->phase == LK_NOAA_DOWNLOADING)
    {
      GtkWidget *head = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      g_autofree char *counts = g_strdup_printf ("Downloading from NOAA · %u of %u charts",
                                                 noaa->done, noaa->total);
      GtkWidget *label = gtk_label_new (counts);
      GtkWidget *cancel = gtk_button_new_with_label ("Cancel");
      GtkWidget *bar = gtk_progress_bar_new ();

      gtk_widget_add_css_class (label, "caption");
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_widget_set_hexpand (label, TRUE);
      gtk_box_append (GTK_BOX (head), label);

      if (noaa->failed > 0)
        {
          g_autofree char *failed = g_strdup_printf ("%u failed", noaa->failed);
          GtkWidget *bad = gtk_label_new (failed);

          gtk_widget_add_css_class (bad, "error");
          gtk_widget_add_css_class (bad, "caption");
          gtk_box_append (GTK_BOX (head), bad);
        }

      gtk_widget_set_valign (cancel, GTK_ALIGN_CENTER);
      g_signal_connect (cancel, "clicked", G_CALLBACK (lk_noaa_cancel_clicked), settings);
      gtk_box_append (GTK_BOX (head), cancel);

      gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (bar),
                                     noaa->total > 0 ? (double) noaa->done / noaa->total
                                                     : 0.0);
      gtk_box_append (GTK_BOX (list), head);
      gtk_box_append (GTK_BOX (list), bar);
    }

  if (bake != NULL)
    {
      GtkWidget *head = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      g_autofree char *title = lk_bake_progress_title (bake);
      g_autofree char *left = lk_bake_progress_remaining (bake);
      GtkWidget *label = gtk_label_new (title);
      GtkWidget *cancel = gtk_button_new_with_label ("Stop");
      GtkWidget *bar = gtk_progress_bar_new ();

      gtk_widget_add_css_class (label, "caption");
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
      gtk_widget_set_hexpand (label, TRUE);
      gtk_box_append (GTK_BOX (head), label);

      if (left != NULL)
        {
          GtkWidget *remaining = gtk_label_new (left);

          gtk_widget_add_css_class (remaining, "dim-label");
          gtk_widget_add_css_class (remaining, "caption");
          gtk_box_append (GTK_BOX (head), remaining);
        }

      gtk_widget_set_valign (cancel, GTK_ALIGN_CENTER);
      gtk_widget_set_tooltip_text (cancel,
                                   "Whatever has been prepared stays. Coarse charts are "
                                   "prepared first, so a passage is covered even if this "
                                   "is stopped part way.");
      g_signal_connect (cancel, "clicked", G_CALLBACK (lk_bake_cancel_clicked), settings);
      gtk_box_append (GTK_BOX (head), cancel);

      gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (bar),
                                     lk_bake_progress_fraction (bake));
      gtk_box_append (GTK_BOX (list), head);
      gtk_box_append (GTK_BOX (list), bar);
    }

  /* A section with nothing in it is a heading over empty space. */
  if (settings->work_section != NULL)
    gtk_widget_set_visible (settings->work_section,
                            noaa->phase == LK_NOAA_DOWNLOADING || bake != NULL);
}

/* The NOAA service moving. */
void
lk_settings_work_changed (gpointer subject, gpointer user_data)
{
  LkSettings *settings = g_object_get_data (G_OBJECT (user_data), "lk-settings");

  if (settings != NULL)
    lk_deferred_list_schedule (&settings->work);
}

/* The bake starting or stopping. A ::notify carries the property between the
 * subject and the data, so it cannot share the handler above. */
void
lk_settings_baking_changed (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  lk_settings_work_changed (object, user_data);
}

/* ---- the page ------------------------------------------------------------ */

/* When NOAA's catalog was last read, for the row that offers it. */
static char *
lk_noaa_checked_text (LkNoaa *noaa)
{
  const LkNoaaState *state = lk_noaa_state (noaa);
  g_autoptr (GDateTime) when = NULL;
  g_autoptr (GDateTime) now = NULL;

  if (state->checked_at == 0)
    return g_strdup ("");

  when = g_date_time_new_from_unix_local (state->checked_at);
  now = g_date_time_new_now_local ();
  if (when == NULL || now == NULL)
    return g_strdup ("");

  if (g_date_time_get_year (when) == g_date_time_get_year (now) &&
      g_date_time_get_day_of_year (when) == g_date_time_get_day_of_year (now))
    {
      g_autofree char *clock = g_date_time_format (when, "%H:%M");
      return g_strdup_printf ("Checked today %s", clock);
    }

  g_autofree char *date = g_date_time_format (when, "%e %b %H:%M");
  return g_strdup_printf ("Checked %s", g_strstrip (date));
}

/* One way to add charts: what it does, and what it costs to find out.
 *
 * The detail line is not decoration. A mariner choosing between NOAA and a
 * folder they already have is choosing between free official cover and their
 * own files, and this row is where that choice is made. */
static GtkWidget *
lk_add_chart_face (const char *icon_name, const char *title, const char *detail,
                   const char *trailing, GtkWidget *holder)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 13);
  GtkWidget *icon = gtk_image_new_from_icon_name (icon_name);
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);
  GtkWidget *name = gtk_label_new (title);
  GtkWidget *blurb = gtk_label_new (detail);
  GtkWidget *chevron = gtk_image_new_from_icon_name ("go-next-symbolic");

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 17);
  gtk_widget_add_css_class (icon, "lk-accent");
  gtk_widget_set_valign (icon, GTK_ALIGN_CENTER);

  gtk_widget_add_css_class (name, "heading");
  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_widget_add_css_class (blurb, "dim-label");
  gtk_widget_add_css_class (blurb, "caption");
  gtk_label_set_xalign (GTK_LABEL (blurb), 0.0);
  gtk_label_set_wrap (GTK_LABEL (blurb), TRUE);
  gtk_box_append (GTK_BOX (column), name);
  gtk_box_append (GTK_BOX (column), blurb);
  gtk_widget_set_hexpand (column, TRUE);

  gtk_box_append (GTK_BOX (row), icon);
  gtk_box_append (GTK_BOX (row), column);

  if (trailing != NULL)
    {
      GtkWidget *when = gtk_label_new (trailing);

      gtk_widget_add_css_class (when, "dim-label");
      gtk_widget_add_css_class (when, "caption");
      gtk_widget_set_valign (when, GTK_ALIGN_CENTER);
      gtk_widget_set_visible (when, trailing[0] != '\0');
      gtk_box_append (GTK_BOX (row), when);
      g_object_set_data (G_OBJECT (holder), "lk-trailing", when);
    }

  gtk_image_set_pixel_size (GTK_IMAGE (chevron), 12);
  gtk_widget_add_css_class (chevron, "dim-label");
  gtk_widget_set_valign (chevron, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (row), chevron);
  return row;
}

static GtkWidget *
lk_add_chart_row (GtkWidget *section, const char *icon_name, const char *title,
                  const char *detail, const char *trailing,
                  GCallback clicked, LkSettings *settings)
{
  GtkWidget *button = gtk_button_new ();

  gtk_button_set_child (GTK_BUTTON (button),
                        lk_add_chart_face (icon_name, title, detail, trailing, button));
  gtk_widget_add_css_class (button, "flat");
  g_signal_connect (button, "clicked", clicked, settings);
  gtk_box_append (GTK_BOX (section), button);
  return button;
}

/* The same row, opening a popover of its own.
 *
 * ONE GtkFileDialog PICKS FILES OR FOLDERS AND NEVER BOTH, and the mariner's
 * charts arrive as either: a folder of cells, an archive an agency published,
 * a prepared chart, a picture. macOS asks for all of them in one panel. Here
 * the row is one entry that offers the two pickers. */
static GtkWidget *
lk_add_chart_menu_row (GtkWidget *section, const char *icon_name, const char *title,
                       const char *detail, LkSettings *settings)
{
  GtkWidget *menu = gtk_menu_button_new ();
  GtkWidget *popover = gtk_popover_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
  GtkWidget *folder = gtk_button_new_with_label ("Choose a Folder…");
  GtkWidget *file = gtk_button_new_with_label ("Choose a File…");

  gtk_widget_add_css_class (folder, "flat");
  gtk_widget_add_css_class (file, "flat");
  gtk_widget_set_halign (gtk_button_get_child (GTK_BUTTON (folder)), GTK_ALIGN_START);
  gtk_widget_set_halign (gtk_button_get_child (GTK_BUTTON (file)), GTK_ALIGN_START);
  g_signal_connect (folder, "clicked", G_CALLBACK (lk_charts_folder_clicked), settings);
  g_signal_connect (file, "clicked", G_CALLBACK (lk_charts_file_clicked), settings);

  gtk_box_append (GTK_BOX (box), folder);
  gtk_box_append (GTK_BOX (box), file);
  gtk_popover_set_child (GTK_POPOVER (popover), box);

  gtk_menu_button_set_child (GTK_MENU_BUTTON (menu),
                             lk_add_chart_face (icon_name, title, detail, NULL, menu));
  gtk_menu_button_set_popover (GTK_MENU_BUTTON (menu), popover);
  gtk_widget_add_css_class (menu, "flat");
  gtk_box_append (GTK_BOX (section), menu);
  return menu;
}

void
lk_build_charts_page (LkSettings *settings)
{
  GtkWidget *page = lk_page_new (settings, "charts", "Charts", "lk-charts-symbolic");
  LkNoaa *noaa = lk_app_model_get_noaa (settings->model);
  g_autofree char *checked = NULL;

  /* WHICH chart is drawn, before where to get more of them. One chart draws at
   * a time: Lookout's own, built from the sets below, or a publisher's style
   * drawn instead of it. */
  GtkWidget *chart = lk_section (page, "Active chart");
  gtk_box_append (GTK_BOX (chart),
                  lk_chart_gallery_new (settings->model, lk_charts_add_link_asked,
                                        settings));
  lk_deferred_list_bind (&settings->links, settings,
                         gtk_box_new (GTK_ORIENTATION_VERTICAL, 6),
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
  /* The Add tile in the gallery asks for the same thing this row does, so it
   * puts the cursor here rather than raising a second way to type a link. */
  settings->link_entry = link_entry;

  lk_footer (chart,
             "A chart by link is an online map drawn as the chart: paste the style "
             "link a publisher shares and sail on their portrayal, tiles fetched "
             "live. Nothing is stored.");

  /* What the chart is built from. */
  GtkWidget *library = lk_section_hinted (page, "Your chart sets", "",
                                          &settings->sets_summary);
  lk_deferred_list_bind (&settings->sets, settings,
                         gtk_box_new (GTK_ORIENTATION_VERTICAL, 4),
                         lk_settings_fill_sets_list);
  gtk_box_append (GTK_BOX (library), settings->sets.box);
  lk_settings_fill_sets_list (settings);
  lk_footer (library,
             "Each folder or archive added is a set. The chart is every set switched "
             "on, drawn as one seamless library; a set switched off stays installed "
             "and out of the chart. The ENC draws over a picture and drops its depth "
             "and land shading only where the picture covers.");

  /* What is arriving now. Hidden when nothing is. */
  settings->work_section = lk_section (page, "Arriving now");
  lk_deferred_list_bind (&settings->work, settings,
                         gtk_box_new (GTK_ORIENTATION_VERTICAL, 6),
                         lk_settings_fill_work_list);
  gtk_box_append (GTK_BOX (settings->work_section), settings->work.box);
  lk_settings_fill_work_list (settings);

  /* Where to get more. */
  GtkWidget *add = lk_section (page, "Add charts");

  checked = lk_noaa_checked_text (noaa);
  settings->noaa_row =
      lk_add_chart_row (add, "weather-overcast-symbolic", "Get charts from NOAA…",
                        "Pick the waters you sail. Lookout downloads the cells and "
                        "prepares them. Free.",
                        checked, G_CALLBACK (lk_charts_noaa_clicked), settings);
  /* ONE ROW FOR EVERYTHING ON THE DISK. A folder of cells, the .zip an agency
   * publishes, a chart already prepared, and a picture are all the mariner's
   * own files, added the same way and switched on the same way. Three rows
   * made them remember which row a file had gone in by. */
  lk_add_chart_menu_row (add, "folder-open-symbolic", "Add charts from this computer…",
                         "A folder of cells, an archive, a prepared chart, or "
                         "pictures. Or drop any of them anywhere in the chart window.",
                         settings);

  lk_footer (add,
             "S-57 and S-101 cells (.000 with their updates) · charts Lookout has "
             "already prepared (.pmtiles) · imagery and vendor charts (.mbtiles) · "
             "BSB/KAP raster sheets (.kap, .bsb). Cells and raster sheets are "
             "converted once on the way in, coarse charts before harbour detail, so a "
             "passage is covered even if the import is stopped part way. Encrypted "
             "S-63 cells are not supported.");

  lk_plugin_fill_tab (page, settings, "charts");
}
