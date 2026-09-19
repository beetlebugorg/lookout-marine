/* ui/charts/noaa-window.h — picking NOAA's waters, in a window of its own.
 *
 * The picker is a map of the United States with the districts drawn on it. In
 * the settings window it would come up in a pane about 550 points wide, which
 * leaves the map a column too narrow to tell the Gulf from the Atlantic. It
 * opens beside the form instead, at the width the map was drawn for.
 *
 * The same shape ui/chrome/table-window.c uses: the app owns the window, and
 * one instance serves every time it is asked for.
 */
#pragma once

#include "model/app-model.h"

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* Put the picker on screen. A second call raises the window it already has
 * rather than stacking another on it. */
void lk_noaa_window_present (GtkWindow *parent, LkAppModel *model);

G_END_DECLS
