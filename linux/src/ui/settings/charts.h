/* ui/settings/charts.h — the Charts page.
 *
 * The chart by link, the library of installed sets, and the installed raster
 * charts.
 */
#pragma once

#include "ui/settings/private.h"

G_BEGIN_DECLS

/* Build the page and add it to the window's stack and sidebar. */
void lk_build_charts_page (LkSettings *settings);

/* The three signal handlers the window connects, one per list. Each asks its
 * list to rebuild on the next idle. `user_data` is the settings window. */
void lk_settings_raster_changed (LkAppModel *model, gpointer user_data);
void lk_settings_links_changed (LkChartLinks *links, gpointer user_data);
void lk_settings_sets_changed (LkAppModel *model, gpointer user_data);

G_END_DECLS
