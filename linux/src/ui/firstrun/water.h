/* ui/firstrun/water.h: what the depth answers do to a chart.
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
#include <lookout.h>

G_BEGIN_DECLS

/* The panel: the water above, the four-shade key below. */
GtkWidget *lk_depth_water_new (void);

/* Re-shade it for `plan`. `feet` says which unit the key reads in, and
 * `scheme` is the engine's colour scheme (0 day, 1 dusk, 2 night). The seabed
 * is the core's (lookout_depth_preview). */
void lk_depth_water_set (GtkWidget *water, const struct lookout_depth_plan *plan,
                         gboolean feet, int scheme);

G_END_DECLS
