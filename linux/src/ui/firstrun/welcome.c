/* ui/firstrun/welcome.c — what this is, and the ways to get a chart.
 *
 * The hero is a real ENC, this app's own render of Annapolis, so the promise
 * is visible before anything downloads. The rows below answer what to do next.
 * The legal notice is a footnote, near the action it qualifies.
 */
#include "ui/firstrun/private.h"

#include "ui/charts/catalog.h"

/* NOAA's own downloads page. Their agreement applies to their charts however
 * they were prepared. */
#define LK_NOAA_ENC_PAGE "https://www.charts.noaa.gov/ENCs/ENCs.shtml"
#define LK_NOAA_AGREEMENT "https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml"

/* The chart, bleeding to the top edge of the card. */
static GtkWidget *
lk_welcome_hero (void)
{
  GdkTexture *picture = lk_chart_welcome_picture ();
  GtkWidget *frame = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *content;

  if (picture != NULL)
    {
      content = gtk_picture_new_for_paintable (GDK_PAINTABLE (picture));
      gtk_picture_set_content_fit (GTK_PICTURE (content), GTK_CONTENT_FIT_COVER);
      gtk_picture_set_can_shrink (GTK_PICTURE (content), TRUE);
    }
  else
    {
      content = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
      gtk_widget_add_css_class (content, "lk-chart-art-empty");
    }

  /* The picture draws inside a box of the height this wants, so its own width
   * stays out of the layout: a picture this wide given a fixed height reports
   * a natural width that would set the width of the whole step. */
  gtk_widget_set_size_request (frame, -1, 296);
  gtk_widget_set_overflow (frame, GTK_OVERFLOW_HIDDEN);
  gtk_widget_set_vexpand (content, TRUE);
  gtk_box_append (GTK_BOX (frame), content);
  gtk_accessible_update_property (GTK_ACCESSIBLE (frame), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  "A Lookout chart of Annapolis", -1);
  return frame;
}

GtkWidget *
lk_first_run_welcome_new (LkFirstRunFlow *flow)
{
  GtkWidget *step = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *prose = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *facts = gtk_box_new (GTK_ORIENTATION_VERTICAL, 20);

  gtk_box_append (GTK_BOX (step), lk_welcome_hero ());

  GtkWidget *heading = lk_step_heading ("Welcome to Lookout Marine",
                                        "Official charts, rendered live on this "
                                        "computer.");
  gtk_widget_set_margin_top (heading, 26);
  gtk_box_append (GTK_BOX (prose), heading);

  gtk_box_append (GTK_BOX (facts),
                  lk_step_fact ("lk-charts-symbolic", "Official ENC charts, drawn live",
                                "Lookout renders S-57 and S-101 cells itself. NOAA "
                                "publishes every United States chart at no cost; most "
                                "other offices sell theirs."));
  gtk_box_append (GTK_BOX (facts),
                  lk_step_fact ("network-workgroup-symbolic",
                                "Or start with an online chart",
                                "A published chart style renders straight away, "
                                "worldwide, with nothing to download and nothing "
                                "stored."));
  gtk_box_append (GTK_BOX (facts),
                  lk_step_fact ("folder-open-symbolic",
                                "Bring charts you already have",
                                "A prepared .pmtiles chart, or a folder of S-57 cells. "
                                "Or drop either anywhere in the chart window."));
  gtk_widget_set_margin_top (facts, 26);
  gtk_box_append (GTK_BOX (prose), facts);

  /* The prototype notice, as a sentence and a link. The page that installs the
   * charts holds the full agreement; repeating it here teaches a mariner to
   * scroll past it in both places. */
  GtkWidget *notice = lk_step_note (
      "dialog-information-symbolic",
      "Lookout is a prototype and is not a certified navigation system. It does not "
      "meet chart carriage regulations. Always carry official charts aboard. "
      "<a href=\"" LK_NOAA_AGREEMENT "\">NOAA ENC User Agreement</a>");
  gtk_widget_set_margin_top (notice, 26);
  gtk_box_append (GTK_BOX (prose), notice);

  gtk_widget_set_margin_start (prose, 64);
  gtk_widget_set_margin_end (prose, 64);
  gtk_widget_set_margin_bottom (prose, 24);
  gtk_box_append (GTK_BOX (step), prose);
  return step;
}
