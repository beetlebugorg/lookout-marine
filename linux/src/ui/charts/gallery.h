/* ui/charts/gallery.h — the charts to draw, as tiles.
 *
 * ONE CHART DRAWS AT A TIME. Lookout's own chart is built from the installed
 * sets; a link is a publisher's style drawn instead of it. Two whole charts
 * cannot share the water, so this is a pick-one control and not a list of
 * switches.
 *
 * A row of tiles rather than a list, so two styles with similar names are told
 * apart by looking.
 */
#pragma once

#include "model/app-model.h"

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* The last tile's action. Adding a chart by link and adding one from a file
 * are the same decision to a mariner, and the page that holds the gallery is
 * where that form lives, so the gallery only asks. */
typedef void (*LkChartGalleryAdd) (gpointer user_data);

/* The gallery. Rebuilds itself off the chart links and the set list, so a
 * style the core has just read appears under the publisher's own name. */
GtkWidget *lk_chart_gallery_new (LkAppModel        *model,
                                 LkChartGalleryAdd  on_add,
                                 gpointer           user_data);

G_END_DECLS
