/* lk-hud.h — the readouts, floated over the chart.
 *
 * On the native-surface fallback nothing composites over the chart, so the
 * window puts this same bar below it instead (see lk-native-surface.h).
 */
#pragma once

#include <gtk/gtk.h>

#include "lk-app-model.h"

G_BEGIN_DECLS

/* Coord/scale/zoom/scheme readout bound to the model. `floating` = translucent
 * overlay rather than a status bar. */
GtkWidget *lk_hud_bar_new (LkAppModel *model, gboolean floating);

/* Floating +/- zoom controls, plus north-up when rotated. */
GtkWidget *lk_zoom_controls_new (LkAppModel *model);

/* Compass rose that turns with the view and resets to north when clicked. */
GtkWidget *lk_compass_new (LkAppModel *model);

/* One line per feature under the last tap: object class + source cell. */
GtkWidget *lk_identify_panel_new (GPtrArray *results);

/* One half of a position, in degrees, minutes and seconds: 38°58'34.8"N. */
char *lk_coord_format_dms (double value, gboolean is_lat);

G_END_DECLS
