/* ui/charts/band-ramp.h: what scales a chart set holds.
 *
 * One bar in the S-52 depth ramp, split by usage band, finest first, with a
 * legend under it. A set that stops at Coastal does not draw the harbour a
 * passage ends in, and the width of each band says how much of the set is at
 * that scale.
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

/* The bar and its legend, from a set's per-band cell counts (index 1 to 6, as
 * LkChartSetRow states them). Draws nothing when no band has a cell. */
GtkWidget *lk_band_ramp_new (const guint bands[7], LkAppModel *model);

/* Re-letter and redraw one in place, for a row whose scan has just landed. */
void lk_band_ramp_set (GtkWidget *ramp, const guint bands[7]);

/* Set one usage band's ramp colour as the source of `cr`: the core's BAND1 to
 * BAND6 token in the model's scheme. Band 6, berthing detail, is the deep end
 * of the ramp, and band 1, an overview, the pale end. */
void lk_band_ramp_source (cairo_t *cr, int band, LkAppModel *model);

/* Redraw `area` when the model's scheme changes. */
void lk_band_ramp_follow (GtkWidget *area, LkAppModel *model);

/* One band's width in a bar with `room` points of fill.
 *
 * A floor under every band the legend counts, because a library of 7,000 cells
 * holds two dozen overviews and a band with a number beside it has to be ON the
 * bar. The floor is paid for by the bands wide enough to give it, so the bar
 * still fills exactly. */
double lk_band_ramp_width (const guint bands[7], int band, double room);

/* How many bands the bar draws: those with at least one cell. */
guint lk_band_ramp_count (const guint bands[7]);

/* One band's colour as a swatch, for a legend or a list of bands. The band
 * comes off the widget as "lk-band", and `user_data` is the LkAppModel. */
void lk_band_swatch_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
                          gpointer user_data);

G_END_DECLS
