/* library/links.h — an online map AS the chart.
 *
 * lookout owns the whole feature: it probes the link, inlines TileJSON
 * sources, generates a wrapper style for bare tiles, fetches the sprite packs,
 * builds the credit line, templates the tile urls and persists the list. This
 * object is the shell's two halves of it — a libsoup fetcher for the urls
 * lookout asks for, and the snapshot the settings list and the HUD render.
 * See include/lookout.h, lookout_set_http_provider.
 *
 * Everything here runs on the main thread: the render tick is the main
 * thread, so lookout's asks arrive there and soup answers there.
 */
#pragma once

#include "engine/controller.h"

G_BEGIN_DECLS

#define LK_TYPE_CHART_LINKS (lk_chart_links_get_type ())
G_DECLARE_FINAL_TYPE (LkChartLinks, lk_chart_links, LK, CHART_LINKS, GObject)

/* One chart the mariner added by link. `url` is its identity. */
typedef struct {
  char *url;
  char *name;
} LkChartLink;

/* Takes a strong reference on the controller: a fetch that lands late must
 * find an object to refuse it, not a dangling pointer. */
LkChartLinks *lk_chart_links_new (LkChartController *controller);

/* The links, in the order added. Borrowed array of borrowed LkChartLink. */
GPtrArray *lk_chart_links_list (LkChartLinks *self);

/* The url being sailed on, or NULL for lookout's own chart. */
const char *lk_chart_links_active (LkChartLinks *self);

/* The credit line the active style's sources ask for ("" while none). Public
 * tile hosts make the visible credit a condition of service, so the HUD shows
 * it beside the scale readout. */
const char *lk_chart_links_attribution (LkChartLinks *self);

/* One sentence about the last add/select/refresh that went wrong, or "". It is
 * cleared by the next attempt. */
const char *lk_chart_links_error (LkChartLinks *self);

/* TRUE while a resolve is in flight. */
gboolean lk_chart_links_busy (LkChartLinks *self);

/* Add a chart by its style link and sail on it. lookout resolves it and
 * refuses a dead or non-style link, which surfaces through the error above.
 * ::changed fires as the snapshot moves. */
void lk_chart_links_add (LkChartLinks *self, const char *link);

/* Forget one link. Removing the active one comes back to lookout's chart. */
void lk_chart_links_remove (LkChartLinks *self, const char *url);

/* Read a linked chart again — its tile urls, zooms, sprites and credit. A link
 * that does not answer leaves the chart as it was. */
void lk_chart_links_refresh (LkChartLinks *self, const char *url);

/* Sail on one added link, or NULL for lookout's own chart. */
void lk_chart_links_select (LkChartLinks *self, const char *url);

/* Install the fetcher on the handle just opened, hand lookout the shell's old
 * store the first time, and take the snapshot that follows. Every open makes a
 * new handle, so the model calls this beside its raster replay. */
void lk_chart_links_reapply (LkChartLinks *self);

/* Take lookout's snapshot if it changed, emitting ::changed when it did.
 * Called once per render tick: the changed flag has ONE consumer. */
void lk_chart_links_poll (LkChartLinks *self);

/* Cancel every in-flight fetch and drop the controller reference now. The
 * model calls this at dispose, ahead of releasing the controller, so an
 * in-flight fetch cannot keep the controller alive past the final pose save. */
void lk_chart_links_shutdown (LkChartLinks *self);

G_END_DECLS
