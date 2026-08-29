/* ui/hud/scale-bar.h — the distance bar at the bottom left of the chart.
 *
 * Four alternating segments under a round distance, so a mariner reads a
 * length off the chart without a scale in the head.
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

/* The distance bar: four alternating segments under a round distance. */
GtkWidget *lk_scale_bar_new (LkAppModel *model);

/* The nice round distance the scale bar draws, in metres, with its bar width
   in points through out_width_points. The width never passes the bar's target
   cap. Exposed for tests. */
double lk_scale_bar_nice_metres (double denominator, double *out_width_points);

G_END_DECLS
