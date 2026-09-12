/* ui/charts/band-ramp.h — what scales a chart set holds.
 *
 * One bar in the S-52 depth ramp, split by usage band, finest first, with a
 * legend under it. A set that stops at Coastal does not draw the harbour a
 * passage ends in, and the width of each band says how much of the set is at
 * that scale.
 */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* The bar and its legend, from a set's per-band cell counts (index 1 to 6, as
 * LkChartSetRow states them). Draws nothing when no band has a cell. */
GtkWidget *lk_band_ramp_new (const guint bands[7]);

/* Re-letter and redraw one in place, for a row whose scan has just landed. */
void lk_band_ramp_set (GtkWidget *ramp, const guint bands[7]);

/* The ramp colour for one usage band, as RGB in 0..1.
 *
 * The S-52 depth ramp, deep to shallow, read as fine to coarse: band 6 is
 * berthing detail and band 1 is an overview. */
void lk_band_ramp_color (int band, double *out_r, double *out_g, double *out_b);

/* One band's width in a bar with `room` points of fill.
 *
 * A floor under every band the legend counts, because a library of 7,000 cells
 * holds two dozen overviews and a band with a number beside it has to be ON the
 * bar. The floor is paid for by the bands wide enough to give it, so the bar
 * still fills exactly. */
double lk_band_ramp_width (const guint bands[7], int band, double room);

/* How many bands the bar draws: those with at least one cell. */
guint lk_band_ramp_count (const guint bands[7]);

G_END_DECLS
