/* ui/firstrun/water.h — what the depth answers do to a chart.
 *
 * A seabed shoaling to a shore, shaded at the derived contours, with spot
 * depths on it. The depth range follows the deep contour, so all four shades
 * are in frame whatever the boat draws.
 *
 * A WINDOW ONTO THE LIVE CHART went here first. The view the engine opens on
 * is wide enough to hold one shade and no soundings, so it showed a mariner
 * nothing about the numbers they were setting.
 *
 * The colours are the engine's own, by S-52 token, so this panel and the chart
 * cannot drift apart.
 */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* The panel: the water above, the four-shade key below. */
GtkWidget *lk_depth_water_new (void);

/* Re-shade it. The depths are in the unit on screen, `feet` says which, and
 * `scheme` is the engine's colour scheme (0 day, 1 dusk, 2 night). */
void lk_depth_water_set (GtkWidget *water, double safety, double contour, double deep,
                         gboolean feet, int scheme);

/* How far out a depth lies, as a fraction of the panel.
 *
 * Measured in CONTOURS rather than metres, because the answers span a dinghy
 * and a ship: a fixed 40 m slope puts a 5 ft contour in the first pixel of the
 * panel and a 30 ft one halfway up it. */
double lk_depth_water_reach (double depth, double floor);

G_END_DECLS
