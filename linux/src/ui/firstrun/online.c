/* ui/firstrun/online.c — a published chart style, drawn as the chart.
 *
 * One online chart draws at a time, and while it draws it IS the chart. The
 * Mariner settings do not reach inside one, because a linked chart renders the
 * way its publisher styled it.
 *
 * The shelf is the gallery the Charts pane shows: the charts the app ships,
 * then whatever the mariner has linked themselves, each with a picture. One
 * shelf, so the two places name the same charts and picture them the same way.
 */
#include "ui/firstrun/private.h"

#include "ui/charts/gallery.h"

static void
lk_online_add_from (LkFirstRunFlow *flow, GtkEntry *entry)
{
  const char *text = gtk_editable_get_text (GTK_EDITABLE (entry));

  if (text == NULL || text[0] == '\0')
    return;
  lk_chart_links_add (lk_app_model_get_chart_links (flow->model), text);
  gtk_editable_set_text (GTK_EDITABLE (entry), "");
}

static void
lk_online_entry_activated (GtkEntry *entry, gpointer user_data)
{
  lk_online_add_from (user_data, entry);
}

static void
lk_online_add_clicked (GtkButton *button, gpointer user_data)
{
  lk_online_add_from (user_data, g_object_get_data (G_OBJECT (button), "lk-entry"));
}

/* The shelf's last tile asks for a link, and the field below is where one is
 * typed. */
static void
lk_online_add_asked (gpointer user_data)
{
  LkFirstRunFlow *flow = user_data;
  GtkWidget *entry = g_object_get_data (G_OBJECT (flow->page), "lk-online-entry");

  if (entry != NULL)
    gtk_widget_grab_focus (entry);
}

GtkWidget *
lk_first_run_online_new (LkFirstRunFlow *flow)
{
  GtkWidget *step = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *heading =
      lk_step_heading ("Choose an online chart",
                       "An online chart renders straight away, worldwide, and stores "
                       "nothing. One shows at a time, and while it is on it is the "
                       "chart.");
  GtkWidget *shelf = lk_chart_gallery_new (flow->model, lk_online_add_asked, flow);
  GtkWidget *another = gtk_label_new ("Another link");
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *entry = gtk_entry_new ();
  GtkWidget *add = gtk_button_new_with_label ("Add");
  GtkWidget *kind = gtk_label_new ("MapLibre style or TileJSON link");

  gtk_widget_set_margin_top (heading, 34);
  gtk_box_append (GTK_BOX (step), heading);

  gtk_widget_set_margin_top (shelf, 20);
  gtk_box_append (GTK_BOX (step), shelf);

  gtk_widget_add_css_class (another, "heading");
  gtk_label_set_xalign (GTK_LABEL (another), 0.0);
  gtk_widget_set_margin_top (another, 18);
  gtk_box_append (GTK_BOX (step), another);

  gtk_entry_set_placeholder_text (GTK_ENTRY (entry), "https://…/style.json");
  gtk_widget_set_hexpand (entry, TRUE);
  g_signal_connect (entry, "activate", G_CALLBACK (lk_online_entry_activated), flow);
  g_object_set_data (G_OBJECT (add), "lk-entry", entry);
  g_signal_connect (add, "clicked", G_CALLBACK (lk_online_add_clicked), flow);
  g_object_set_data (G_OBJECT (flow->page), "lk-online-entry", entry);

  gtk_box_append (GTK_BOX (row), entry);
  gtk_box_append (GTK_BOX (row), add);
  gtk_widget_set_margin_top (row, 8);
  gtk_box_append (GTK_BOX (step), row);

  gtk_widget_add_css_class (kind, "dim-label");
  gtk_widget_add_css_class (kind, "caption");
  gtk_label_set_xalign (GTK_LABEL (kind), 0.0);
  gtk_widget_set_margin_top (kind, 6);
  gtk_box_append (GTK_BOX (step), kind);

  const char *error = lk_chart_links_error (lk_app_model_get_chart_links (flow->model));
  if (error[0] != '\0')
    {
      GtkWidget *label = gtk_label_new (error);

      gtk_widget_add_css_class (label, "error");
      gtk_widget_add_css_class (label, "caption");
      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_widget_set_margin_top (label, 12);
      gtk_box_append (GTK_BOX (step), label);
    }

  GtkWidget *warning = lk_step_warning (
      "Not for navigation.",
      "A published style is drawn exactly as its publisher styled it. Its depths and "
      "marks come from whoever made it, may be missing, outdated or wrong, and are not "
      "reduced to a chart datum by Lookout.");
  gtk_widget_set_margin_top (warning, 20);
  gtk_box_append (GTK_BOX (step), warning);

  gtk_widget_set_margin_start (step, 40);
  gtk_widget_set_margin_end (step, 40);
  gtk_widget_set_margin_bottom (step, 26);
  return step;
}
