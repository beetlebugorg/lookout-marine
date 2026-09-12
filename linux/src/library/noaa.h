/* library/noaa.h — NOAA's charts, as the shell sees them.
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

#include "engine/controller.h"

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
  /* Where to draw the region when the catalog has not been read yet, in
   * degrees. A rough extent for display only: what a region SELECTS comes from
   * the catalog, so these never decide which cells download. */
  double west, south, east, north;
} LkNoaaRegion;

/* One box of a region's coverage, in degrees. */
typedef struct {
  double west, south, east, north;
} LkNoaaBox;

/* What the core is doing with NOAA's charts. */
typedef enum {
  LK_NOAA_IDLE = 0,
  LK_NOAA_READING_CATALOG = 1,
  LK_NOAA_READY = 2,
  LK_NOAA_DOWNLOADING = 3,
} LkNoaaPhase;

/* The whole snapshot, as the last poll read it. */
typedef struct {
  LkNoaaPhase phase;
  gboolean    have_catalog;
  char        date[16]; /* NOAA's validity date, "20250903" */
  gint64      checked_at; /* unix seconds of the last read that worked, or 0 */
  guint32     catalog_cells;
  /* The download running now. */
  guint32     total, done, failed;
  guint64     bytes_total, bytes_done;
  char        error[256];
} LkNoaaState;

/* A cell already installed, for the update check. */
typedef struct {
  const char *name; /* the cell name, "US5MD1MC" */
  guint32     edition;
  guint32     update;
} LkNoaaInstalled;

/* Called when a catalog read has no chart handle to run through. The owner
 * answers by opening a chart of no charts; the request is replayed from
 * lk_noaa_chart_did_open. */
typedef void (*LkNoaaNeedChart) (gpointer user_data);

/* Takes a strong reference on the controller, as the chart links do: a poll
 * that lands late must find an object to refuse it. */
LkNoaa *lk_noaa_new (LkChartController *controller);

/* The owner's way to supply a chart handle on demand. */
void lk_noaa_set_need_chart (LkNoaa *self, LkNoaaNeedChart fn, gpointer user_data);

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

/* The snapshot, borrowed. Never NULL. */
const LkNoaaState *lk_noaa_state (LkNoaa *self);

/* Take the core's snapshot, reprice the pick, and emit ::changed when anything
 * moved. Runs a timer of its own while a read or a download is in flight and
 * stops it when the work ends, so an idle app runs no timer. */
void lk_noaa_poll (LkNoaa *self);

/* Read NOAA's product catalog. The result arrives through the poll above. With
 * no chart open this asks the owner for one and holds the request. */
void lk_noaa_refresh (LkNoaa *self);

/* A chart handle has just been created. Anything held while there was none
 * runs now, and so does a read the old handle took with it when it closed. */
void lk_noaa_chart_did_open (LkNoaa *self);

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

/* What the pick costs, in the mariner's words. Free with g_free. */
char *lk_noaa_cost_line (LkNoaa *self);

/* The same words, from the numbers alone. `held` is how many of the pick's
 * cells are already installed, and a pick WHOLLY installed reads as a repair
 * rather than as an empty pick. Free with g_free. */
char *lk_noaa_cost_words (guint32 cells, guint64 bytes, guint32 held, guint64 held_bytes);

/* Hand the core the NOAA cells already installed, then price again. The names
 * come off the chart sets, so a set added by hand counts the same as one this
 * app downloaded. NULL forgets the list. */
void lk_noaa_note_installed (LkNoaa *self, const char *const *names);

/* Download the picked regions into `dest_dir`. `again` fetches the cells
 * already held as well. Does nothing with an empty pick. */
void lk_noaa_download (LkNoaa *self, const char *dest_dir, gboolean again);

/* Stop the download that is running. The cells already written stay. */
void lk_noaa_cancel (LkNoaa *self);

/* How many of these cells NOAA has reissued, and the download that replaces
 * them. */
guint32 lk_noaa_outdated (LkNoaa *self, const LkNoaaInstalled *have, guint n);
void    lk_noaa_update (LkNoaa *self, const LkNoaaInstalled *have, guint n,
                        const char *dest_dir);

/* Drop the poll timer and the controller reference. The owner calls this at
 * dispose, ahead of releasing the controller. */
void lk_noaa_shutdown (LkNoaa *self);

/* Where downloaded cells are staged before they bake. ONE directory, so the
 * whole download bakes as a single chart set. Free with g_free. */
char *lk_noaa_download_dir (void);

/* A size a mariner reads before agreeing to download it. Free with g_free. */
char *lk_noaa_size_text (guint64 bytes);

G_END_DECLS
