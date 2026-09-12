/* ui/firstrun/depths.h — the depth step, and the ladder behind it.
 *
 * The step asks for a draft and a clearance under the keel. Everything the
 * engine draws with follows from those two, and the arithmetic is here so it
 * can be checked without a screen.
 */
#pragma once

#include "ui/firstrun/private.h"

G_BEGIN_DECLS

/* The contours an S-57 survey draws, in the unit on screen. Borrowed and
 * static, ascending. */
const double *lk_depth_ladder (gboolean feet, guint *out_n);

/* The clearances the step offers, in the unit on screen. Round in both
 * units. */
const double *lk_depth_clearances (gboolean feet, guint *out_n);

/* The safety depth: the draft plus the clearance, rounded UP to a whole foot
 * or metre. A chart names its depths in whole numbers, and the fraction
 * belongs to the keel rather than to the water. */
double lk_depth_safety (double draft, double clearance);

/* The safety contour: the first contour the survey draws at or past the safety
 * depth. The chart shades on a contour it HAS, so a boat drawing 7 ft is
 * shaded against the 12 ft contour. */
double lk_depth_contour (double safety, gboolean feet);

/* The deep contour: twice the safety contour, up the same ladder, so it
 * displays round. The step does not ask for it. */
double lk_depth_deep_contour (double contour, gboolean feet);

/* The offered clearance nearest `want`, for a change of unit. */
double lk_depth_nearest_clearance (double want, gboolean feet);

G_END_DECLS
