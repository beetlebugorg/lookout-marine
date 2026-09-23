/* ui/firstrun/coverage.c — which waters to download.
 *
 * A region is a Coast Guard district, the unit NOAA files a cell under. The
 * core turns a pick into the cells that cover that water, including the ones
 * NOAA files next door, so a region downloads without a gap along its border.
 * See src/noaa.zig.
 *
 * The map, the pills and the cost line beside Download are the same three
 * pieces Mariner settings shows in its own picker window.
 */
#include "ui/firstrun/private.h"

#include "model/noaa.h"
#include "ui/charts/coverage-map.h"

GtkWidget *
lk_first_run_coverage_new (LkFirstRunFlow *flow)
{
  GtkWidget *step = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  LkNoaa *noaa = lk_app_model_get_noaa (flow->model);
  GtkWidget *heading =
      lk_step_heading ("Which waters do you sail?",
                       "Pick the water you use. Lookout downloads those charts and "
                       "prepares them. You can add the rest later.");
  GtkWidget *line = lk_noaa_catalog_line_new (noaa);
  GtkWidget *map = lk_coverage_map_new (noaa, flow->model);
  GtkWidget *pills = lk_noaa_region_pills_new (noaa);

  gtk_widget_set_margin_top (heading, 26);
  gtk_box_append (GTK_BOX (step), heading);

  gtk_widget_set_margin_top (line, 12);
  gtk_box_append (GTK_BOX (step), line);

  gtk_widget_set_margin_top (map, 10);
  gtk_box_append (GTK_BOX (step), map);

  gtk_widget_set_margin_top (pills, 12);
  gtk_box_append (GTK_BOX (step), pills);

  gtk_widget_set_margin_start (step, 20);
  gtk_widget_set_margin_end (step, 20);
  gtk_widget_set_margin_bottom (step, 22);

  /* The picker needs the catalog before it can price anything. */
  if (!lk_noaa_state (noaa)->have_catalog)
    lk_noaa_refresh (noaa);

  return step;
}
