/* lk-hud.h — the chrome that floats over the chart.
 *
 * The layout is the layout every shell uses (windows/ui/MainWindow.xaml,
 * ChartView.swift, ChartScreen.kt): north at the top right, zoom at the bottom
 * right, the distance bar at the bottom left, the readouts at the bottom
 * centre, and the build indicator at the top centre. The engine draws the
 * chart only; all of this is native widgets above it.
 */
#pragma once

#include <gtk/gtk.h>

#include "lk-app-model.h"

G_BEGIN_DECLS

/* ---- sizes, shared with the window's layout ----------------------------- */

/* Bubble diameter, the gap between chrome items, the distance from the chrome
 * to the edge of the chart, and the readout capsule's height. The same four
 * numbers as Chrome.swift and Chrome.kt. */
#define LK_CHROME_BUBBLE  48
#define LK_CHROME_GAP     10
#define LK_CHROME_MARGIN  16
#define LK_CHROME_CAPSULE 44

/* The bottom band the capsule owns: its height and a margin each side. The
 * pick report stops above it. */
#define LK_HUD_BAND (LK_CHROME_CAPSULE + LK_CHROME_MARGIN * 2)

/* Below this width the capsule and the corner chrome cannot share the bottom
 * row, so the capsule drops the band and takes a smaller type. */
#define LK_CHROME_COMPACT_WIDTH 700

/* ---- the chrome --------------------------------------------------------- */

/* Band, 1:N, zoom and position in one capsule. The 1:N is a control: it opens
 * the scale entry. */
GtkWidget *lk_hud_capsule_new (LkAppModel *model);

/* The distance bar: four alternating segments under a round distance. */
GtkWidget *lk_scale_bar_new (LkAppModel *model);

/* The tessellation indicator. It shows while the chart fills in. */
GtkWidget *lk_building_pill_new (LkAppModel *model);

/* Fit, zoom in and zoom out, as a column of bubbles. */
GtkWidget *lk_zoom_controls_new (LkAppModel *model);

/* The north bubble. The mark turns with the view and a click sets the chart
 * north-up. It is always visible: a mariner reads the chart's orientation from
 * it, so it must not appear only once the chart is already turned. */
GtkWidget *lk_north_bubble_new (LkAppModel *model);

/* One circular chrome control over the chart. `action` may be NULL. */
GtkWidget *lk_bubble_new (const char *icon_name, const char *tooltip, const char *action);

/* The same bubble, opening a menu instead of firing an action. */
GtkWidget *lk_bubble_menu_new (const char *icon_name, const char *tooltip, GMenuModel *menu);

/* ---- readout formatting ------------------------------------------------- */

/* One half of a position, in degrees, minutes and seconds: 38°58'34.8"N. */
char *lk_coord_format_dms (double value, gboolean is_lat);

/* The full scale with group separators, as every shell prints it: 1:13,267. */
char *lk_format_scale (double denominator);

/* The S-52 navigational purpose band for a display scale. */
const char *lk_format_band (double denominator);

G_END_DECLS
