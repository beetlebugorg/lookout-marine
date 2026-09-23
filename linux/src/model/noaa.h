/* model/noaa.h: NOAA's charts, as the shell sees them.
 *
 * NOAA publishes an ENC for every United States waterway at no cost. The core
 * owns the whole feature: it reads the product catalog, decides which cells a
 * region needs, fetches them through the shell's HTTP provider, and writes one
 * exchange-set zip per cell into a directory the shell then bakes. See
 * include/lookout-library.h and src/noaa.zig.
 *
 * This object is the shell's half of it: the snapshot the picker renders, the
 * regions the mariner picked, what that pick costs, and the words for both.
 *
 * WHAT A REGION SELECTS. NOAA files each cell under one Coast Guard district,
 * and water does not stop at a district line. Selecting a region takes the
 * cells NOAA files under it AND every cell whose coverage overlaps one of
 * those, so a region never draws with a hole along its border. Region totals
 * therefore overlap and do not add up: the cost of a SELECTION is the only
 * number that means anything.
 *
 * Everything here runs on the main thread.
 */
#pragma once

#include <glib-object.h>
#include <lookout.h>

#include "library/bake.h"

G_BEGIN_DECLS

#define LK_TYPE_NOAA (lk_noaa_get_type ())
G_DECLARE_FINAL_TYPE (LkNoaa, lk_noaa, LK, NOAA, GObject)

/* One region a mariner picks from. The strings are the core's and static for
 * the life of the process. */
typedef struct {
  const char *id;    /* "d5", which is what is written down */
  const char *name;  /* "Mid-Atlantic" */
  const char *blurb; /* the waters it covers, in one line */
  int         district;
  int         panel;    /* a LOOKOUT_NOAA_PANEL_ value: the map panel it draws on */
  /* Where to draw the region when the catalog has not been read yet, in
   * degrees. A rough extent for display only: what a region SELECTS comes from
   * the catalog, so these never decide which cells download. */
  double west, south, east, north;
} LkNoaaRegion;

/* One box of a region's coverage, in degrees. */
typedef struct {
  double west, south, east, north;
} LkNoaaBox;

/* Open the core's NOAA service on `store` and `sets`, with a fetcher of its
 * own. Both are borrowed and must outlive the object. */
LkNoaa *lk_noaa_new (lookout_store *store, lookout_chart_sets *sets);

/* The core's service. A test uses it to install a fetcher of its own. */
lookout_noaa *lk_noaa_service (LkNoaa *self);

/* The regions, borrowed and static. `out_n` is how many. */
const LkNoaaRegion *lk_noaa_regions (LkNoaa *self, guint *out_n);

/* One region by id, or NULL. */
const LkNoaaRegion *lk_noaa_region (LkNoaa *self, const char *id);

/* The pick. `lk_noaa_picked_ids` is the comma separated list the core reads, in
 * region order rather than click order; free it with g_free. */
gboolean lk_noaa_is_picked (LkNoaa *self, const char *id);
void     lk_noaa_toggle (LkNoaa *self, const char *id);
void     lk_noaa_clear_picks (LkNoaa *self);
guint    lk_noaa_picked_count (LkNoaa *self);
char    *lk_noaa_picked_ids (LkNoaa *self);

/* The core's state, borrowed. Never NULL. It is read again, and ::changed
 * emitted, when lookout_noaa_changed returns 1: after each order and on the
 * service's wake. */
const lookout_noaa_state *lk_noaa_state (LkNoaa *self);

/* Read the state when lookout_noaa_changed returns 1, and emit ::changed.
 * The wake calls this. A test that installs its own fetcher calls it too. */
void lk_noaa_sync (LkNoaa *self);

/* Read NOAA's product catalog. The result arrives through ::changed. */
void lk_noaa_refresh (LkNoaa *self);

/* One region's coverage, borrowed, read once when the catalog lands. Empty
 * until then, and a picker draws the rough extent instead. */
const LkNoaaBox *lk_noaa_coverage (LkNoaa *self, const char *id, guint *out_n);

/* What the current pick costs. `held` counts the pick's cells that are already
 * installed, and `held_bytes` sizes fetching those again for a repair. */
guint32 lk_noaa_cells (LkNoaa *self);
guint64 lk_noaa_bytes (LkNoaa *self);
guint32 lk_noaa_held (LkNoaa *self);
guint64 lk_noaa_held_bytes (LkNoaa *self);

/* TRUE when every cell the pick names is already on this device. The download
 * then repairs or refreshes them rather than adding any. */
gboolean lk_noaa_all_installed (LkNoaa *self);

/* Price the pick and read each region again, and emit ::changed. The core
 * reads what the chart sets hold, so the owner calls this when they change. */
void lk_noaa_reprice (LkNoaa *self);

/* One region as lookout_noaa_region_state last read it. Zeroed before the
 * catalog is read and for an unknown id. Never NULL. */
const lookout_noaa_region_info *lk_noaa_region_info (LkNoaa *self, const char *id);

/* What the pick costs, in the mariner's words. Free with g_free. */
char *lk_noaa_cost_line (LkNoaa *self);

/* The same words, from the numbers alone. `held` is how many of the pick's
 * cells are already installed, and a pick WHOLLY installed reads as a repair
 * rather than as an empty pick. Free with g_free. */
char *lk_noaa_cost_words (guint32 cells, guint64 bytes, guint32 held, guint64 held_bytes);

/* Download `region_ids`, a comma separated list, into `dest_dir`. `again`
 * fetches the cells already held as well. An empty list orders no download. */
void lk_noaa_download (LkNoaa *self, const char *region_ids, const char *dest_dir,
                       gboolean again);

/* Make the download at `dest_dir` hold the pick, through lookout_noaa_apply:
 * record it, delete the water it gives back, and download what it lacks.
 * Returns how many directories left the library. */
guint32 lk_noaa_apply (LkNoaa *self, const char *dest_dir, gboolean again);

/* Stop the download that is running. The cells already written stay. */
void lk_noaa_cancel (LkNoaa *self);

/* How many of the managed sets' cells NOAA has reissued, and the download
 * that replaces them. The core reads the editions off the managed sets. */
guint32 lk_noaa_outdated (LkNoaa *self);

/* Start the update check when the store's cadence says one is due. TRUE while
 * the check runs. The count is lk_noaa_outdated once the catalog read ends. */
gboolean lk_noaa_update_due (LkNoaa *self);

void    lk_noaa_update (LkNoaa *self, const char *dest_dir);

/* ---- the orders the app follows ------------------------------------------ */

/* Download `region_ids`, apply the pick, or fetch the reissued editions, into
 * the download directory, and follow the order to its end. ::alert reports a
 * directory that cannot be made, and an order that ended FAILED, or REFUSED
 * with retry set. ::work-moved reports the core's prepare and removal. */
void lk_noaa_order_download (LkNoaa *self, const char *region_ids, gboolean again);
void lk_noaa_order_apply (LkNoaa *self);
void lk_noaa_order_update (LkNoaa *self);

/* Place the last order again. With no catalog loaded this reads the catalog
 * first and orders when that read ends. */
void lk_noaa_retry (LkNoaa *self);

/* Start the update check when the core finds one due. The count arrives when
 * the catalog read ends, through ::changed. */
void lk_noaa_check_updates (LkNoaa *self);

/* The chart sets changed: count the reissued charts again, and check for
 * more when one is due. */
void lk_noaa_sets_changed (LkNoaa *self);

/* How many managed charts NOAA has reissued, as the last count found. */
guint32 lk_noaa_outdated_found (LkNoaa *self);

/* The core's prepare and removal, as the shell's bake reports them. NULL when
 * none runs. */
const LkBakeProgress *lk_noaa_prepare_progress (LkNoaa *self);
const LkBakeProgress *lk_noaa_remove_progress (LkNoaa *self);

/* Where downloaded cells are staged before they bake. ONE directory, so the
 * whole download bakes as a single chart set. Free with g_free. */
char *lk_noaa_download_dir (void);


G_END_DECLS
