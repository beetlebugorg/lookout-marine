/* ui/settings/charts.h — the Charts page.
 *
 * Which chart is drawn, the library it is built from, the work arriving now,
 * and where to get more.
 */
#pragma once

#include "ui/settings/private.h"

G_BEGIN_DECLS

/* Build the page and add it to the window's stack and sidebar. */
void lk_build_charts_page (LkSettings *settings);

/* The signal handlers the window connects. Each asks one list to rebuild on
 * the next idle. `user_data` is the settings window.
 *
 * A picture is a row of the SET list now, so a raster change and a set change
 * rebuild the same list. */
void lk_settings_raster_changed (LkAppModel *model, gpointer user_data);
void lk_settings_links_changed (LkChartLinks *links, gpointer user_data);
void lk_settings_sets_changed (LkAppModel *model, gpointer user_data);

/* A NOAA download moving. `subject` is the object that raised it. */
void lk_settings_work_changed (gpointer subject, gpointer user_data);

/* The bake starting or stopping, which arrives as a property notification. */
void lk_settings_baking_changed (GObject *object, GParamSpec *pspec, gpointer user_data);

G_END_DECLS
