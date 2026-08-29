/* model/coord.h — the tolerant coordinate and scale parsers.
 *
 * Pure text-to-number, no model state, so the search go-to and the scale entry
 * share one parser each and the suites test them on their own. Each accepts
 * what its counterpart accepts on the other shells, so a value read off one app
 * types into another.
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

/* Tolerant lat/lon parser: decimal pairs and DMS with hemispheres. TRUE when
 * the text names a place inside ±90/±180. */
gboolean lk_coordinate_parse (const char *text, double *out_lat, double *out_lon);

/* Tolerant scale parser: "25000", "25,000", "1:25000", "25k", "1:2.5M". TRUE
 * when the text names a denominator between 1:100 and 1:100,000,000. */
gboolean lk_scale_parse (const char *text, double *out_denominator);

G_END_DECLS
