/* lk-chart-links.h — an online map AS the chart. The shell fetches a
 * publisher's MapLibre style, hands lookout the JSON, and then serves that
 * style's tiles (lookout does no networking — see include/lookout.h,
 * lookout_set_tile_provider). The GTK twin of MainWindow.ChartLinks.cpp
 * (Windows) and AltChartStyle.swift (macOS).
 *
 * Everything here runs on the main thread. Resolving a link fans out over
 * several fetches, so it runs whole on a GTask worker with its own session;
 * tile fetches are soup async calls started right in the engine's callback.
 */
#pragma once

#include "lk-chart-controller.h"

G_BEGIN_DECLS

#define LK_TYPE_CHART_LINKS (lk_chart_links_get_type ())
G_DECLARE_FINAL_TYPE (LkChartLinks, lk_chart_links, LK, CHART_LINKS, GObject)

/* One chart the mariner added by link. `url` is its identity; `doc` carries
 * the style TEXT where the link itself cannot be re-read the same way (a
 * mariner's own file, or the wrapper generated for a bare TileJSON) and is
 * empty for a style link, which is fetched fresh on every push. */
typedef struct {
  char *url;
  char *name;
  char *doc;
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

/* One sentence about the last add/refresh/push that went wrong, or "". It is
 * cleared by the next attempt. */
const char *lk_chart_links_error (LkChartLinks *self);

/* Add a chart by its style link and sail on it. The link is read ONCE here —
 * a dead or non-style link is refused now, at the form, not discovered later
 * as a blank chart. Emits ::changed when the probe answers. */
void lk_chart_links_add (LkChartLinks *self, const char *link);

/* Forget one link. Removing the active one comes back to lookout's chart. */
void lk_chart_links_remove (LkChartLinks *self, const char *url);

/* Re-read a linked chart and rebuild what was frozen when it was added. A
 * link that does not answer leaves the chart exactly as it was. */
void lk_chart_links_refresh (LkChartLinks *self, const char *url);

/* Sail on one added link, or NULL for lookout's own chart. Persists. */
void lk_chart_links_select (LkChartLinks *self, const char *url);

/* Push the active link into the handle again. Every open replaces the engine
 * handle, so the model replays this beside the raster charts. */
void lk_chart_links_reapply (LkChartLinks *self);

G_END_DECLS
