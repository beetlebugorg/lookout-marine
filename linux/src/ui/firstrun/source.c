/* ui/firstrun/source.c — where the first charts come from.
 *
 * One decision, as big as the card allows. The cards stand side by side, in
 * equal columns, so blurbs of different lengths still make one row rather than
 * a staircase.
 */
#include "ui/firstrun/private.h"

typedef struct {
  LkFirstRunSource  source;
  const char       *icon;
  const char       *title;
  const char       *blurb;
} LkSourceSpec;

/* The list. A source that gains a screen gains a card without this file
 * changing anywhere else. */
static const LkSourceSpec lk_sources[] = {
  { LK_FIRST_RUN_NOAA, "lk-charts-symbolic", "NOAA charts",
    "Official ENC for every U.S. waterway, free. Downloaded to this computer and "
    "prepared here." },
  { LK_FIRST_RUN_ONLINE_CHART, "network-workgroup-symbolic", "Online chart",
    "A published chart style. Renders straight away, worldwide, and stores nothing." },
  { LK_FIRST_RUN_FILES, "folder-open-symbolic", "Files on this computer",
    "A prepared .pmtiles chart, or a folder of S-57 cells. Or drop either anywhere in "
    "the chart window." },
};

static void
lk_source_card_clicked (GtkButton *button, gpointer user_data)
{
  LkFirstRunFlow *flow = user_data;
  LkFirstRunSource source =
      (LkFirstRunSource) GPOINTER_TO_INT (g_object_get_data (G_OBJECT (button),
                                                             "lk-source"));

  lk_first_run_set_source (flow->flow, source);
}

GtkWidget *
lk_first_run_source_new (LkFirstRunFlow *flow)
{
  GtkWidget *step = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *cards = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 14);
  GtkWidget *heading =
      lk_step_heading ("How would you like to add charts?",
                       "You can add the other sources any time, from Charts in Mariner "
                       "settings.");
  LkFirstRunSource picked = lk_first_run_source (flow->flow);
  GtkSizeGroup *columns = gtk_size_group_new (GTK_SIZE_GROUP_HORIZONTAL);

  gtk_widget_set_margin_top (heading, 38);
  gtk_box_append (GTK_BOX (step), heading);

  for (gsize i = 0; i < G_N_ELEMENTS (lk_sources); i++)
    {
      const LkSourceSpec *spec = &lk_sources[i];
      GtkWidget *card = lk_step_card (spec->icon, spec->title, spec->blurb,
                                      spec->source == LK_FIRST_RUN_NOAA,
                                      spec->source == picked);

      g_object_set_data (G_OBJECT (card), "lk-source", GINT_TO_POINTER (spec->source));
      g_signal_connect (card, "clicked", G_CALLBACK (lk_source_card_clicked), flow);
      /* Equal columns: the cards make one row, not a staircase. */
      gtk_size_group_add_widget (columns, card);
      gtk_box_append (GTK_BOX (cards), card);
    }
  g_object_unref (columns);

  gtk_widget_set_margin_top (cards, 26);
  gtk_box_append (GTK_BOX (step), cards);

  gtk_widget_set_margin_start (step, 40);
  gtk_widget_set_margin_end (step, 40);
  gtk_widget_set_margin_bottom (step, 26);
  return step;
}
