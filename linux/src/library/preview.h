/* library/preview.h — a picture of every chart on a list.
 *
 * A chart list wants a picture of each chart on it, and the engine draws one
 * chart at a time. Three sources fill one cache, cheapest first:
 *
 *   1. The picture the app ships (ui/charts/catalog.h). Instant, and no
 *      network: a fresh install draws its shelf before a tile is fetched.
 *   2. A snapshot of the chart being DRAWN, filed under the url that is
 *      drawing it. The engine drew it, so it is the one true picture of that
 *      publisher's portrayal.
 *   3. One tile, fetched for a chart that is not drawing. The core reads each
 *      style for where its tiles come from; this asks for the tile at the
 *      mariner's own water and fetches it.
 *
 * Every chart is pictured at the SAME point, the one the mariner is looking
 * at, so what differs between the cards is the portrayal. A picture is written
 * to disk under that point, which makes the second visit instant.
 */
#pragma once

#include "engine/controller.h"

G_BEGIN_DECLS

/* The zoom a preview tile is fetched at. Low enough that one tile holds a
 * recognisable stretch of coast, high enough to carry a chart's detail. */
#define LK_PREVIEW_ZOOM 9

#define LK_TYPE_CHART_PREVIEWS (lk_chart_previews_get_type ())
G_DECLARE_FINAL_TYPE (LkChartPreviews, lk_chart_previews, LK, CHART_PREVIEWS, GObject)

/* Takes a strong reference on the controller: a fetch that lands late must
 * find an object to refuse it. */
LkChartPreviews *lk_chart_previews_new (LkChartController *controller);

/* The picture for one chart, or NULL when none has arrived. NULL for the url
 * is Lookout's own chart. Borrowed. */
GdkTexture *lk_chart_previews_get (LkChartPreviews *self, const char *url);

/* Ask for what is missing, for the charts a list is about to draw. `urls` is
 * NULL terminated; NULL in it is Lookout's own chart.
 *
 * The core reads a style over the network, so a template is rarely there on
 * the first ask. This keeps asking while a list is on screen and gives up on
 * a chart that never answers, rather than deciding on the first answer that it
 * has no picture. Stops on its own once every chart is answered. */
void lk_chart_previews_want (LkChartPreviews *self, const char *const *urls);

/* Stop asking. The page calls it as it goes. */
void lk_chart_previews_stop (LkChartPreviews *self);

/* Take a picture of the chart being drawn and file it under `url` (NULL for
 * Lookout's own chart). TRUE when one was taken. */
gboolean lk_chart_previews_capture (LkChartPreviews *self, const char *url);

/* Keep capturing the chart being drawn while it settles, then stop.
 *
 * A linked chart resolves its style and fetches its tiles before it has
 * anything to picture, so the frame at the moment it was picked is the chart
 * it REPLACED. This keeps looking for a few seconds rather than deciding on
 * that frame. A second call for a different chart abandons the first: a
 * picture filed under a chart that is no longer drawing is another chart's
 * picture under this one's name. */
void lk_chart_previews_watch (LkChartPreviews *self, const char *url);

/* Drop the controller reference and every fetch in flight. */
void lk_chart_previews_shutdown (LkChartPreviews *self);

/* ---- the cache ----------------------------------------------------------- */

/* The tile a point falls in, at `zoom`. Slippy tile numbers, as every tile
 * server counts them. */
void lk_chart_preview_tile (double lon, double lat, int zoom, int *out_x, int *out_y);

/* Where the picture of `url` at this point is kept. The key holds the chart
 * and the TILE the water falls in, so a mariner who has moved gets a picture
 * of where they are now and one who panned across a harbour keeps the picture
 * they already have. Free with g_free. */
char *lk_chart_preview_cache_path (const char *url, double lon, double lat, int zoom);

G_END_DECLS
