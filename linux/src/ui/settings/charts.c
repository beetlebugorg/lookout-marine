/* ui/settings/charts.c: the Charts page.
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
#include "model/store.h"
#include "ui/open-dialogs.h"
#include "ui/work-panel.h"

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

/* Adding a chart by link, as a window the gallery's last tile raises.
 *
 * NOT A FIELD ON THE PAGE. A field standing open on every visit is a field
 * most visits do not want, and the sentence saying what a chart link IS has to
 * stand open with it: together they cost the pane a block of height that the
 * mariner reads past every time. Both belong where the mariner has just asked
 * to add one (apple/LookoutMarine/Charts/ChartsSection.swift, AddChartSheet).
 */

static void
lk_add_link_submit (LkSettings *settings, GtkWidget *entry)
{
  GtkWidget *window = gtk_widget_get_ancestor (entry, GTK_TYPE_WINDOW);
  const char *text = gtk_editable_get_text (GTK_EDITABLE (entry));

  if (text == NULL || text[0] == '\0')
    return;
  lk_chart_links_add (lk_app_model_get_chart_links (settings->model), text);
  /* The window goes at once. What happens next, reading the style, or
   * refusing it, is reported on the page, under the gallery. */
  if (window != NULL)
    gtk_window_destroy (GTK_WINDOW (window));
}

static void
lk_add_link_activated (GtkEntry *entry, gpointer user_data)
{
  lk_add_link_submit (user_data, GTK_WIDGET (entry));
}

static void
lk_add_link_clicked (GtkButton *button, gpointer user_data)
{
  lk_add_link_submit (user_data, g_object_get_data (G_OBJECT (button), "lk-entry"));
}

static void
lk_add_link_cancelled (GtkButton *button, gpointer user_data)
{
  GtkWidget *window = gtk_widget_get_ancestor (GTK_WIDGET (button), GTK_TYPE_WINDOW);

  if (window != NULL)
    gtk_window_destroy (GTK_WINDOW (window));
}

/* Add is the only thing this window is for, so it stays out of reach until
 * there is something to add. */
static void
lk_add_link_typed (GtkEditable *entry, GParamSpec *pspec, gpointer user_data)
{
  const char *text = gtk_editable_get_text (entry);
  g_autofree char *trimmed = g_strdup (text != NULL ? text : "");

  gtk_widget_set_sensitive (GTK_WIDGET (user_data), g_strstrip (trimmed)[0] != '\0');
}

/* The gallery's last tile. */
static void
lk_charts_add_link_asked (gpointer user_data)
{
  LkSettings *settings = user_data;
  /* The page's own widget is the way to the window this pane is in: the
   * gallery asks without saying where from. */
  GtkRoot *root = settings->links.box != NULL
                      ? gtk_widget_get_root (settings->links.box)
                      : NULL;
  GtkWidget *window = gtk_window_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 14);
  GtkWidget *blurb = gtk_label_new (
      "An online map can be the chart. Paste its MapLibre style link, or a TileJSON "
      "tile link. A style draws exactly what its publisher styled; bare tiles get a "
      "plain generated look. Either way the content comes from whoever made it, "
      "depths, symbols and warnings included.");
  GtkWidget *entry = gtk_entry_new ();
  GtkWidget *buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *cancel = gtk_button_new_with_label ("Cancel");
  GtkWidget *add = gtk_button_new_with_label ("Add");

  gtk_window_set_title (GTK_WINDOW (window), "Add a Chart");
  gtk_window_set_default_size (GTK_WINDOW (window), 460, -1);
  gtk_window_set_resizable (GTK_WINDOW (window), FALSE);
  gtk_window_set_modal (GTK_WINDOW (window), TRUE);
  gtk_window_set_destroy_with_parent (GTK_WINDOW (window), TRUE);
  if (GTK_IS_WINDOW (root))
    gtk_window_set_transient_for (GTK_WINDOW (window), GTK_WINDOW (root));
  gtk_window_set_titlebar (GTK_WINDOW (window), gtk_header_bar_new ());

  gtk_widget_add_css_class (blurb, "dim-label");
  gtk_label_set_wrap (GTK_LABEL (blurb), TRUE);
  gtk_label_set_xalign (GTK_LABEL (blurb), 0.0);
  gtk_label_set_max_width_chars (GTK_LABEL (blurb), 52);

  gtk_entry_set_placeholder_text (GTK_ENTRY (entry), "https://…/style.json");
  gtk_entry_set_input_purpose (GTK_ENTRY (entry), GTK_INPUT_PURPOSE_URL);
  gtk_entry_set_activates_default (GTK_ENTRY (entry), FALSE);
  g_signal_connect (entry, "activate", G_CALLBACK (lk_add_link_activated), settings);

  gtk_widget_add_css_class (add, "suggested-action");
  gtk_widget_set_sensitive (add, FALSE);
  g_object_set_data (G_OBJECT (add), "lk-entry", entry);
  g_signal_connect (entry, "notify::text", G_CALLBACK (lk_add_link_typed), add);
  g_signal_connect (add, "clicked", G_CALLBACK (lk_add_link_clicked), settings);
  g_signal_connect (cancel, "clicked", G_CALLBACK (lk_add_link_cancelled), settings);

  gtk_widget_set_hexpand (cancel, TRUE);
  gtk_widget_set_halign (cancel, GTK_ALIGN_END);
  gtk_box_append (GTK_BOX (buttons), cancel);
  gtk_box_append (GTK_BOX (buttons), add);

  gtk_widget_set_margin_start (box, 18);
  gtk_widget_set_margin_end (box, 18);
  gtk_widget_set_margin_top (box, 18);
  gtk_widget_set_margin_bottom (box, 18);
  gtk_box_append (GTK_BOX (box), blurb);
  gtk_box_append (GTK_BOX (box), entry);
  gtk_box_append (GTK_BOX (box), buttons);
  gtk_window_set_child (GTK_WINDOW (window), box);

  gtk_window_present (GTK_WINDOW (window));
  gtk_widget_grab_focus (entry);
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
      GtkWidget *label = lk_caption ("Reading the chart…");

      gtk_spinner_set_spinning (GTK_SPINNER (spinner), TRUE);
      gtk_widget_set_valign (spinner, GTK_ALIGN_CENTER);
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
      GtkWidget *label = lk_caption (
          "While a linked chart draws, the display, depth and symbol settings do not "
          "shape it. You are seeing its publisher's own portrayal.");

      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
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

/* Never, at startup, or daily. */
static void
lk_charts_update_cadence_chosen (LkSettings *settings, int chosen)
{
  static const char *const keys[] = { "never", "startup", "daily" };

  if (chosen < 0 || chosen > 2)
    return;
  lk_store_save_noaa_update_check (keys[chosen]);
  /* A mariner who just asked for the check gets one now. */
  if (chosen != 0)
    lk_app_model_check_noaa_updates (settings->model);
}

/* Fetch the newer editions the check counted. */
static void
lk_charts_update_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;

  lk_app_model_download_noaa_updates (settings->model);
}

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
      char estimate[LOOKOUT_DURATION_MAX];

      /* The reference's estimate: about 0.2 s to rebuild each prepared chart. */
      lookout_fmt_duration (charts * 0.2, LOOKOUT_DURATION_ABOUT, estimate, sizeof estimate);
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
  /* WHAT KIND OF CHART THIS IS, on the row. The list holds surveys and
   * pictures together because they are added and switched on the same way,
   * and the pill is how a mariner tells them apart without a heading
   * splitting the list in two. */
  GtkWidget *kind = gtk_label_new ("RASTER");
  GtkWidget *name = lk_caption (group->name);
  g_autofree char *count = g_strdup_printf (group->paths->len == 1 ? "%u file" : "%u files",
                                            group->paths->len);
  GtkWidget *files = gtk_label_new (count);
  GtkWidget *remove = gtk_button_new_from_icon_name ("lk-remove-symbolic");

  gtk_widget_add_css_class (kind, "lk-type-pill");
  gtk_widget_add_css_class (kind, "dim-label");
  gtk_widget_set_valign (kind, GTK_ALIGN_CENTER);
  if (!any_on)
  gtk_label_set_ellipsize (GTK_LABEL (name), PANGO_ELLIPSIZE_END);
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

  /* The pill types the row, so it stands with the name and not out among the
   * numbers. What is left of the row is the gap that pushes those right. */
  GtkWidget *gap = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_set_hexpand (gap, TRUE);

  gtk_box_append (GTK_BOX (row), toggle);
  gtk_box_append (GTK_BOX (row), name);
  gtk_box_append (GTK_BOX (row), kind);
  gtk_box_append (GTK_BOX (row), gap);
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

  char size[LOOKOUT_BYTES_MAX];

  lookout_fmt_bytes (bytes, size, sizeof size);
  return g_strdup_printf ("%u charts · %s", charts, size);
}

/* Draw a separator above every entry except the first.
 *
 * A set can run to four lines: the title row, a scale ramp, a count still to
 * prepare, and the pictures added with it. With only a gap between them, two
 * such sets read as one. The reference draws each set as a List row, which
 * separates them the same way
 * (apple/LookoutMarine/Charts/ChartsSection.swift). */
static void
lk_sets_list_rule (GtkWidget *list)
{
  if (gtk_widget_get_first_child (list) != NULL)
    gtk_box_append (GTK_BOX (list), gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
}

/* The title, the mark on a managed set, and the lines under them. */
static void
lk_set_row_column (LkSettings *settings, const LkChartSetRow *set, GtkWidget *column)
{
    GtkWidget *title = gtk_label_new (set->title);

    gtk_widget_add_css_class (title, "heading");
    gtk_label_set_xalign (GTK_LABEL (title), 0.0);
    gtk_label_set_ellipsize (GTK_LABEL (title), PANGO_ELLIPSIZE_END);

    /* WHO OWNS THIS SET. Charts go in and out of a managed set through the
     * NOAA chart downloader. Without the mark a mariner reads the download
     * as a folder they picked, and looks for it on the disk
     * (apple/LookoutMarine/Charts/ChartsSection.swift, ManagedBadge). */
    if (set->managed)
      {
        GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
        /* Two words here, where the reference uses a sentence. This pane
         * is about 430 points wide against the reference's 460. The title
         * is the only label on the line that can shrink, so a five-word
         * pill reduced it to an ellipsis. The full sentence is in the
         * tooltip and the accessible label. */
        GtkWidget *pill = gtk_label_new ("NOAA downloader");

        gtk_widget_add_css_class (pill, "lk-managed-pill");
        gtk_widget_set_valign (pill, GTK_ALIGN_CENTER);
        gtk_widget_set_tooltip_text (pill, "Managed by the NOAA chart downloader.");
        gtk_accessible_update_property (GTK_ACCESSIBLE (pill),
                                        GTK_ACCESSIBLE_PROPERTY_LABEL,
                                        "Managed by the NOAA chart downloader", -1);
        gtk_box_append (GTK_BOX (line), title);
        gtk_box_append (GTK_BOX (line), pill);
        gtk_box_append (GTK_BOX (column), line);
      }
    else
      gtk_box_append (GTK_BOX (column), title);

    /* ONE line under the title, not two. Where it came from and what it
     * holds are both about the same set, and stacking them made a row three
     * lines deep that read as three facts. The folder shows only when the
     * agency title has replaced it (apple/…/ChartsSection.swift). */
    g_autofree char *under = NULL;

    if (g_strcmp0 (set->title, set->name) != 0 && set->detail[0] != '\0')
      under = g_strdup_printf ("%s · %s", set->name, set->detail);
    else if (g_strcmp0 (set->title, set->name) != 0)
      under = g_strdup (set->name);
    else if (set->detail[0] != '\0')
      under = g_strdup (set->detail);

    if (under != NULL)
      {
        GtkWidget *caption = lk_caption (under);

        gtk_label_set_ellipsize (GTK_LABEL (caption), PANGO_ELLIPSIZE_MIDDLE);
        gtk_box_append (GTK_BOX (column), caption);
      }

    /* What this set holds that another set draws in its place. Two sets can
     * hold the same cell, and the chart draws one copy, so the count on the
     * row is more than the chart shows. */
    if (set->held_back > 0)
      {
        g_autofree char *held =
            g_strdup_printf (set->held_back == 1
                                 ? "1 chart also in another set"
                                 : "%u charts also in another set",
                             set->held_back);
        GtkWidget *caption = lk_caption (held);

        gtk_box_append (GTK_BOX (column), caption);
      }
}

/* The one control at the right of a set's row. */
static GtkWidget *
lk_set_row_action (LkSettings *settings, const LkChartSetRow *set)
{
  GtkWidget *action;

    /* The managed set is removed through the NOAA picker, so this row
     * opens it. Remove on this row deleted the prepared charts and left the
     * downloaded cells under downloads/NOAA, which no page lists. The
     * picker's region record still counted that water as held. The
     * reference gives the managed row the same button
     * (apple/LookoutMarine/Charts/ChartsSection.swift, ChartSetRow). */
    if (set->managed)
      {
        action = gtk_button_new_with_label ("Manage…");

        gtk_button_set_has_frame (GTK_BUTTON (action), FALSE);
        gtk_widget_add_css_class (action, "caption");
        /* Accent color, because a frameless button beside dimmed text
         * reads as disabled. */
        gtk_widget_add_css_class (action, "lk-accent");
        gtk_widget_set_valign (action, GTK_ALIGN_CENTER);
        gtk_widget_set_tooltip_text (action, "Add or remove this water in the NOAA "
                                             "chart downloader.");
        gtk_accessible_update_property (GTK_ACCESSIBLE (action),
                                        GTK_ACCESSIBLE_PROPERTY_LABEL,
                                        "Manage the NOAA charts", -1);
        g_signal_connect (action, "clicked", G_CALLBACK (lk_charts_noaa_clicked),
                          settings);
      }
    else
      {
        action = gtk_button_new_from_icon_name ("lk-remove-symbolic");

        gtk_button_set_has_frame (GTK_BUTTON (action), FALSE);
        gtk_widget_set_valign (action, GTK_ALIGN_CENTER);
        gtk_widget_set_tooltip_text (action,
                                     set->derived
                                         ? "Remove from the library. Charts Lookout "
                                           "prepared from it are deleted; your folder "
                                           "is not touched."
                                         : "Take these charts out of the list. Your "
                                           "files stay where they are.");
        gtk_accessible_update_property (GTK_ACCESSIBLE (action),
                                        GTK_ACCESSIBLE_PROPERTY_LABEL, "Remove chart set",
                                        -1);

        g_object_set_data_full (G_OBJECT (action), "lk-path", g_strdup (set->path),
                                g_free);
        g_object_set_data_full (G_OBJECT (action), "lk-set-title", g_strdup (set->title),
                                g_free);
        g_object_set_data (G_OBJECT (action), "lk-set-charts",
                           GUINT_TO_POINTER (set->charts));
        if (set->derived)
          g_object_set_data (G_OBJECT (action), "lk-set-derived", GINT_TO_POINTER (1));
        g_signal_connect (action, "clicked", G_CALLBACK (lk_chart_set_remove_clicked),
                          settings);
      }
  return action;
}

/* What hangs under a set's row: the scales it holds, what NOAA has reissued,
 * and the count still to prepare. */
static void
lk_set_row_extras (LkSettings *settings, const LkChartSetRow *set, GtkWidget *entry)
{
    /* What scales it holds. A set that stops at Coastal does not draw the
     * harbour a passage ends in. */
    if (lk_band_ramp_count (set->bands) > 0)
      {
        GtkWidget *ramp = lk_band_ramp_new (set->bands, settings->model);

        gtk_widget_set_margin_start (ramp, 30);
        gtk_widget_set_opacity (ramp, set->on ? 1.0 : 0.5);
        gtk_box_append (GTK_BOX (entry), ramp);
      }

    /* What is still to prepare. */
    if (set->to_prepare > 0)
      {
        g_autofree char *text = g_strdup_printf ("%u to prepare", set->to_prepare);
        GtkWidget *label = lk_caption (text);

        gtk_widget_set_margin_start (label, 30);
        gtk_box_append (GTK_BOX (entry), label);
      }
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

  /* Draw the downloader's set first, whatever order the library returns.
   *
   * It is the set the app fills and empties through the NOAA picker. Without
   * this it appears below folders the mariner added earlier, and they search
   * the list for it.
   *
   * `order` holds borrowed pointers in draw order. `rows` owns them. */
  g_autoptr (GPtrArray) order = g_ptr_array_new ();

  for (guint pass = 0; pass < 2; pass++)
    for (guint i = 0; i < rows->len; i++)
      {
        const LkChartSetRow *set = g_ptr_array_index (rows, i);

        if (set->managed == (pass == 0))
          g_ptr_array_add (order, (gpointer) set);
      }

  for (guint i = 0; i < order->len; i++)
    {
      const LkChartSetRow *set = g_ptr_array_index (order, i);
      /* One set is one block: the switch, the scale ramp, the count still to
       * prepare, and the pictures added with it. The gap inside a block is
       * smaller than the gap between blocks, and a separator closes each one.
       * The reference groups it the same way
       * (apple/LookoutMarine/Charts/ChartsSection.swift). */
      GtkWidget *entry = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      GtkWidget *toggle = lk_settings_switch (set->on);
      GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
      GtkWidget *action;
      lk_set_row_column (settings, set, column);
      gtk_widget_set_hexpand (column, TRUE);

      /* The agency title can hide the folder name; the tooltip keeps the
       * whole path reachable. */
      gtk_widget_set_tooltip_text (row, set->path);

      g_object_set_data_full (G_OBJECT (toggle), "lk-path", g_strdup (set->path), g_free);
      g_signal_connect (toggle, "notify::active", G_CALLBACK (lk_chart_set_toggled),
                        settings);

      action = lk_set_row_action (settings, set);

      gtk_box_append (GTK_BOX (row), toggle);
      gtk_box_append (GTK_BOX (row), column);
      gtk_box_append (GTK_BOX (row), action);
      gtk_box_append (GTK_BOX (entry), row);
      lk_sets_list_rule (list);
      gtk_box_append (GTK_BOX (list), entry);

      /* WHAT NOAA HAS REISSUED. Only the managed row: it is the set the app
       * knows the provenance of, and the one it can fetch newer editions
       * into. */
      if (set->managed && lk_app_model_noaa_outdated (settings->model) > 0)
        {
          guint32 n = lk_app_model_noaa_outdated (settings->model);
          GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
          g_autofree char *text =
              g_strdup_printf (n == 1 ? "1 chart has a newer edition"
                                      : "%u charts have newer editions", n);
          GtkWidget *label = gtk_label_new (text);
          GtkWidget *update = gtk_button_new_with_label ("Update");

          gtk_widget_add_css_class (label, "caption");
          gtk_widget_add_css_class (label, "lk-accent");
          gtk_label_set_xalign (GTK_LABEL (label), 0.0);
          gtk_widget_set_hexpand (label, TRUE);
          gtk_button_set_has_frame (GTK_BUTTON (update), FALSE);
          gtk_widget_add_css_class (update, "caption");
          gtk_widget_add_css_class (update, "lk-accent");
          gtk_widget_set_valign (update, GTK_ALIGN_CENTER);
          /* A transfer already running is replaced by lookout_noaa_update
           * with no word to the mariner, so Update stands down while one
           * runs and while what it brought is prepared. */
          const lookout_noaa_state *state =
              lk_noaa_state (lk_app_model_get_noaa (settings->model));

          gtk_widget_set_sensitive (update,
                                    state->phase != LOOKOUT_NOAA_DOWNLOADING &&
                                        !lk_app_model_get_baking (settings->model));
          g_signal_connect (update, "clicked", G_CALLBACK (lk_charts_update_clicked),
                            settings);

          gtk_box_append (GTK_BOX (line), label);
          gtk_box_append (GTK_BOX (line), update);
          gtk_widget_set_margin_start (line, 30);
          gtk_box_append (GTK_BOX (entry), line);
        }

      lk_set_row_extras (settings, set, entry);

      /* The pictures this set came in with. */
      for (guint g = 0; g < groups->len; g++)
        {
          const LkRasterGroup *group = g_ptr_array_index (groups, g);

          if (group->paths->len == 0 ||
              !lk_raster_belongs_to (g_ptr_array_index (group->paths, 0), set->path))
            continue;
          g_hash_table_add (placed, (gpointer) group);
          lk_raster_group_row (settings, entry, group, TRUE);
        }
    }

  /* A picture the mariner added on its own belongs to no set, and still has to
   * be switchable and removable. It goes in the list as itself: the row says
   * it is a raster, so nothing has to be filed under a heading that split the
   * library into two lists again. */
  for (guint g = 0; g < groups->len; g++)
    {
      const LkRasterGroup *group = g_ptr_array_index (groups, g);

      if (g_hash_table_contains (placed, group))
        continue;
      lk_sets_list_rule (list);
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
  const lookout_noaa_state *noaa = lk_noaa_state (lk_app_model_get_noaa (settings->model));
  const LkBakeProgress *bake = lk_app_model_get_bake_progress (settings->model);
  const LkBakeProgress *gone = lk_app_model_get_remove_progress (settings->model);
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  if (noaa->phase == LOOKOUT_NOAA_DOWNLOADING)
    {
      GtkWidget *panel = lk_work_panel_new ("Cancel", G_CALLBACK (lk_noaa_cancel_clicked),
                                            settings);
      g_autofree char *counts = g_strdup_printf ("Downloading from NOAA · %u of %u charts",
                                                 noaa->done, noaa->total);
      g_autofree char *failed =
          noaa->failed > 0 ? g_strdup_printf ("%u failed", noaa->failed) : NULL;

      lk_work_panel_show (panel, counts, failed, NULL, NULL, (int) noaa->done,
                          (int) noaa->total);
      gtk_box_append (GTK_BOX (list), panel);
    }

  if (bake != NULL)
    {
      GtkWidget *panel = lk_work_panel_new ("Stop", G_CALLBACK (lk_bake_cancel_clicked),
                                            settings);
      g_autofree char *title = lk_bake_progress_title (bake);
      g_autofree char *left = lk_bake_progress_remaining (bake);

      lk_work_panel_show (panel, title, left, NULL, NULL, bake->done, bake->total);
      gtk_box_append (GTK_BOX (list), panel);
    }

  /* A removal, the same way. Deleting a library is thousands of files and it
   * runs behind the app: without this the panel says nothing at all while the
   * charts go, which reads as the removal having done nothing. It offers no
   * Cancel, the set is already off the list, and half a deleted library is
   * not a state to stop in. */
  if (gone != NULL)
    {
      GtkWidget *panel = lk_work_panel_new (NULL, NULL, NULL);
      g_autofree char *title = lk_bake_progress_title (gone);
      g_autofree char *counts =
          gone->total > 0 ? g_strdup_printf ("%d of %d", gone->done, gone->total) : NULL;

      lk_work_panel_show (panel, title, counts, NULL, NULL, gone->done, gone->total);
      gtk_box_append (GTK_BOX (list), panel);
    }

  /* A section with nothing in it is a heading over empty space. */
  if (settings->work_section != NULL)
    gtk_widget_set_visible (settings->work_section,
                            noaa->phase == LOOKOUT_NOAA_DOWNLOADING || bake != NULL ||
                                gone != NULL);
}

static char *lk_noaa_checked_text (LkNoaa *noaa);

/* When the catalog was last read, on the row that offers it.
 *
 * The row reads the time again whenever the service moves, so a catalog read
 * that finishes while the page stands is on it. */
static void
lk_settings_refresh_noaa_checked (LkSettings *settings)
{
  GtkWidget *label;

  if (settings->noaa_row == NULL)
    return;
  label = g_object_get_data (G_OBJECT (settings->noaa_row), "lk-trailing");
  if (label == NULL)
    return;

  g_autofree char *checked =
      lk_noaa_checked_text (lk_app_model_get_noaa (settings->model));

  gtk_label_set_text (GTK_LABEL (label), checked);
  gtk_widget_set_visible (label, checked[0] != '\0');
}

/* The NOAA service moving. */
void
lk_settings_work_changed (gpointer subject, gpointer user_data)
{
  LkSettings *settings = g_object_get_data (G_OBJECT (user_data), "lk-settings");

  if (settings != NULL)
    {
      lk_deferred_list_schedule (&settings->work);
      /* The managed row states what NOAA has reissued and offers Update, so
       * it follows the service too. */
      lk_deferred_list_schedule (&settings->sets);
      lk_settings_refresh_noaa_checked (settings);
    }
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
  const lookout_noaa_state *state = lk_noaa_state (noaa);
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
  GtkWidget *blurb = lk_caption (detail);
  GtkWidget *chevron = gtk_image_new_from_icon_name ("go-next-symbolic");

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 17);
  gtk_widget_add_css_class (icon, "lk-accent");
  gtk_widget_set_valign (icon, GTK_ALIGN_CENTER);

  gtk_widget_add_css_class (name, "heading");
  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_label_set_wrap (GTK_LABEL (blurb), TRUE);
  /* A GtkMenuButton measures its child at no width, so a line that wraps
   * reports one line's height and the second line is clipped. A cap on the
   * natural width makes the label report the wrapped height. */
  gtk_label_set_max_width_chars (GTK_LABEL (blurb), 64);
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

static void
lk_add_chart_popped (GtkButton *button, gpointer user_data)
{
  gtk_popover_popup (GTK_POPOVER (user_data));
}

/* A popover parented by hand is a child of the button, and a widget must have
 * none left when it is disposed. */
static void
lk_add_chart_unparent (GtkWidget *button, gpointer user_data)
{
  gtk_widget_unparent (GTK_WIDGET (user_data));
}

/* The same row, opening a popover of its own.
 *
 * ONE GtkFileDialog PICKS FILES OR FOLDERS AND NEVER BOTH, and the mariner's
 * charts arrive as either: a folder of cells, an archive an agency published,
 * a prepared chart, a picture. macOS asks for all of them in one panel. Here
 * the row is one entry that offers the two pickers.
 *
 * A PLAIN BUTTON WITH THE POPOVER PARENTED TO IT, not a GtkMenuButton. A menu
 * button does not pass the width it is given down to what it measures, so a
 * detail line that wraps to three lines in a narrow pane reported the height
 * of two, and the third line was drawn outside the row and over the shelf. */
static GtkWidget *
lk_add_chart_menu_row (GtkWidget *section, const char *icon_name, const char *title,
                       const char *detail, LkSettings *settings)
{
  GtkWidget *menu = gtk_button_new ();
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

  gtk_button_set_child (GTK_BUTTON (menu),
                        lk_add_chart_face (icon_name, title, detail, NULL, menu));
  gtk_widget_add_css_class (menu, "flat");
  gtk_widget_set_parent (popover, menu);
  gtk_popover_set_position (GTK_POPOVER (popover), GTK_POS_BOTTOM);
  gtk_popover_set_has_arrow (GTK_POPOVER (popover), FALSE);
  gtk_widget_set_halign (popover, GTK_ALIGN_START);
  g_signal_connect (menu, "clicked", G_CALLBACK (lk_add_chart_popped), popover);
  g_signal_connect (menu, "destroy", G_CALLBACK (lk_add_chart_unparent), popover);
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
  GtkWidget *chart_group = lk_group (chart, LK_GAP_ROW);

  gtk_box_append (GTK_BOX (chart_group),
                  lk_chart_gallery_new (settings->model, lk_charts_add_link_asked,
                                        settings));
  lk_deferred_list_bind (&settings->links, settings,
                         gtk_box_new (GTK_ORIENTATION_VERTICAL, 6),
                         lk_settings_fill_links_list);
  gtk_box_append (GTK_BOX (chart_group), settings->links.box);
  lk_settings_fill_links_list (settings);

  /* What the chart is built from. */
  GtkWidget *library = lk_section_hinted (page, "Your chart sets", "",
                                          &settings->sets_summary);
  GtkWidget *library_group = lk_group (library, 0);

  /* Wider than the 8 inside a set, so the gap between two sets reads as a
   * boundary. A separator closes each set as well, so 12 is enough where 16
   * was needed before. */
  lk_deferred_list_bind (&settings->sets, settings,
                         gtk_box_new (GTK_ORIENTATION_VERTICAL, 12),
                         lk_settings_fill_sets_list);
  gtk_box_append (GTK_BOX (library_group), settings->sets.box);
  lk_settings_fill_sets_list (settings);
  lk_footer (library,
             "Each folder or archive added is a set. The chart is every set switched "
             "on, drawn as one seamless library; a set switched off stays installed "
             "and out of the chart. The ENC draws over a picture and drops its depth "
             "and land shading only where the picture covers.");

  /* What is arriving now. Hidden when nothing is. */
  settings->work_section = lk_section (page, "Arriving now");
  GtkWidget *work_group = lk_group (settings->work_section, 0);

  lk_deferred_list_bind (&settings->work, settings,
                         gtk_box_new (GTK_ORIENTATION_VERTICAL, 6),
                         lk_settings_fill_work_list);
  gtk_box_append (GTK_BOX (work_group), settings->work.box);
  lk_settings_fill_work_list (settings);

  /* Where to get more. */
  GtkWidget *add = lk_section (page, "Add charts");
  GtkWidget *add_group = lk_group (add, 0);

  checked = lk_noaa_checked_text (noaa);
  settings->noaa_row =
      lk_add_chart_row (add_group, "weather-overcast-symbolic", "Get charts from NOAA…",
                        "Pick the waters you sail. Lookout downloads the cells and "
                        "prepares them. Free.",
                        checked, G_CALLBACK (lk_charts_noaa_clicked), settings);
  /* ONE ROW FOR EVERYTHING ON THE DISK. A folder of cells, the .zip an agency
   * publishes, a chart already prepared, and a picture are all the mariner's
   * own files, added the same way and switched on the same way. Three rows
   * made them remember which row a file had gone in by. */
  /* A rule between the two ways in, as the reference draws it: they are two
   * choices on one shelf, not one block of text. */
  gtk_box_append (GTK_BOX (add_group),
                  gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));

  lk_add_chart_menu_row (add_group, "folder-open-symbolic", "Add charts from this computer…",
                         "A folder of cells, an archive, a prepared chart, or "
                         "pictures. Or drop any of them anywhere in the chart window.",
                         settings);

  /* HOW OFTEN TO ASK NOAA FOR NEWER EDITIONS. NOAA reissues a cell when its
   * survey changes, and a mariner sailing on last season's edition has no way
   * to know. The read is about 10 MB, so it runs once a day at most. */
  static const char *const cadences[] = { "Never", "At startup", "Daily", NULL };
  g_autofree char *cadence = lk_store_load_noaa_update_check ();
  int chosen = g_str_equal (cadence, "never")     ? 0
               : g_str_equal (cadence, "startup") ? 1
                                                  : 2;

  lk_choice_row_plain (add_group, settings, "Check for NOAA chart updates", cadences,
                       chosen, lk_charts_update_cadence_chosen);

  lk_footer (add,
             "S-57 and S-101 cells (.000 with their updates) · charts Lookout has "
             "already prepared (.pmtiles) · imagery and vendor charts (.mbtiles) · "
             "BSB/KAP raster sheets (.kap, .bsb). Cells and raster sheets are "
             "converted once on the way in, coarse charts before harbour detail, so a "
             "passage is covered even if the import is stopped part way. Encrypted "
             "S-63 cells are not supported.");

  lk_plugin_fill_tab (page, settings, "charts");
}
