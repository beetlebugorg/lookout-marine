/* ui/charts/coverage-map.h — picking the waters to download.
 *
 * Setup asks this on its coverage step, and Mariner settings asks it again
 * from Charts. One map and one row of regions, so the two places name the same
 * waters and price them the same way.
 *
 * Region sizes are per SELECTION rather than per region. The core includes
 * every cell covering a region's water, including the ones NOAA files under
 * the district next door, so per-region totals overlap and do not add up. One
 * accurate total beats nine numbers that do not sum.
 */
#pragma once

#include "library/noaa.h"
#include "ui/charts/coastline.h"

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* The lower 48, with Alaska and Hawaii inset.
 *
 * One view cannot hold all three: they span 128 degrees of longitude, and at
 * that scale their latitude span is taller than the panel. An atlas prints
 * them as insets for the same reason.
 *
 * Reads the pick and the coverage off `noaa` live and redraws on its
 * ::changed. A click lands on a region's own water, not on a rectangle around
 * it, and does nothing until the catalog is in. */
GtkWidget *lk_coverage_map_new (LkNoaa *noaa);

/* The regions as pills under the map: the name, and a mark on a chosen one.
 * The same selection the map drives. */
GtkWidget *lk_noaa_region_pills_new (LkNoaa *noaa);

/* Where NOAA's catalog stands: a spinner while it is read, the failure and a
 * way to try again, or what the catalog holds once it has landed. */
GtkWidget *lk_noaa_catalog_line_new (LkNoaa *noaa);

/* TRUE when the point `x`,`y` of a `width` by `height` panel falls on one of
 * `boxes`, projected through `window`.
 *
 * What a click asks. A region is its own water rather than a rectangle around
 * it, so the boxes are the catalog's and the answer is per box. A box thinner
 * than a point is still worth a point of tolerance, because it is drawn that
 * wide. */
gboolean lk_region_box_hit (const LkNoaaBox *boxes, guint n, const LkMapWindow *window,
                            double width, double height, double x, double y);

G_END_DECLS
