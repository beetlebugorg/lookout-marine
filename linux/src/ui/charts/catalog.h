/* ui/charts/catalog.h — the online charts the app offers on a fresh install,
 * and the pictures it ships for them.
 *
 * A first run has no links, so the online chart step would show an empty shelf
 * until the mariner pasted a style url. These entries give the step charts to
 * pick from on the day the app is installed.
 *
 * LOOKOUT RUNS NONE OF THESE SERVICES. A card names its publisher and shows
 * the url its tiles come from, so an entry offers a link to somebody else's
 * chart rather than a chart of Lookout's.
 *
 * Each entry ships a picture of its style, rendered by the engine and carried
 * in the binary, so the shelf draws its cards before a single tile is fetched.
 * A render of the mariner's own water replaces it once one arrives.
 */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* One chart the app knows about before the mariner adds anything. */
typedef struct {
  const char *name;
  const char *url;
  const char *art; /* the resource path of the picture shipped for it */
} LkChartCatalogEntry;

/* The entries, in the order the shelf draws them. Borrowed and static. */
const LkChartCatalogEntry *lk_chart_catalog_entries (guint *out_n);

/* The entry for a url, or NULL when the app ships none. */
const LkChartCatalogEntry *lk_chart_catalog_entry (const char *url);

/* The picture the app ships for this chart, or NULL. Borrowed: decoded once
 * and kept for the life of the process, because a shelf redraws often and a
 * chart picture is three quarters of a megabyte. */
GdkTexture *lk_chart_catalog_art (const char *url);

/* The app's own chart, as a picture: the hero the welcome step draws, and the
 * tile the gallery gives Lookout's own chart before the engine has drawn one
 * of the mariner's water. Borrowed, on the same terms. */
GdkTexture *lk_chart_welcome_picture (void);

G_END_DECLS
