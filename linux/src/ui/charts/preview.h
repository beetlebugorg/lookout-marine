/* ui/charts/preview.h: a picture of every chart on a list.
 *
 * The core draws each picture (lookout_chart_link_picture): the chart on
 * screen once it settles, and one publisher tile for a raster style. Any
 * other style has no picture. Every chart is pictured at the
 * point the mariner is looking at, so what differs between the cards is the
 * portrayal. A chart with no picture shows the one the app ships, if any.
 */
#pragma once

#include "engine/controller.h"

G_BEGIN_DECLS

/* The zoom a picture is drawn at. Low enough that one tile holds a
 * recognisable stretch of coast, high enough to carry a chart's detail. */
#define LK_PREVIEW_ZOOM 9

#define LK_TYPE_CHART_PREVIEWS (lk_chart_previews_get_type ())
G_DECLARE_FINAL_TYPE (LkChartPreviews, lk_chart_previews, LK, CHART_PREVIEWS, GObject)

LkChartPreviews *lk_chart_previews_new (LkChartController *controller);

/* The picture for one chart, or NULL when there is none. NULL or "" for the
 * url is Lookout's own chart. Borrowed. */
GdkTexture *lk_chart_previews_get (LkChartPreviews *self, const char *url);

/* Ask the core for each chart's picture, `width` by `height` device pixels.
 * `urls` is NULL terminated, and "" in it is Lookout's own chart. A picture
 * still being drawn raises the chart-link change flag when it is ready, so a
 * list requests them again when the links change. */
void lk_chart_previews_want (LkChartPreviews *self, const char *const *urls, int width,
                             int height);

/* Drop the pictures being drawn. The list calls it as it leaves the screen. */
void lk_chart_previews_stop (LkChartPreviews *self);

G_END_DECLS
