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

#include <glib-object.h>
#include <lookout.h>

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

/* A cell already installed, for the update check. */
typedef struct {
  const char *name; /* the cell name, "US5MD1MC" */
  guint32     edition;
  guint32     update;
} LkNoaaInstalled;

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
 * emitted, when lookout_noaa_svc_changed returns 1: after each order, on the
 * service's wake, and as the pieces of a transfer arrive. */
const lookout_noaa_state *lk_noaa_state (LkNoaa *self);

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

/* How much of ONE region this device already holds: `out_cells` is every cell
 * covering its water and `out_held` the ones installed. FALSE before the
 * catalog is in, with both set to 0.
 *
 * Region totals overlap, as the header says, so this reports how far one
 * region is covered and never feeds a sum. Each region costs a walk of the
 * catalog, so it is read when the catalog lands and when the installed list
 * changes. */
gboolean lk_noaa_region_held (LkNoaa *self, const char *id, guint32 *out_cells,
                              guint32 *out_held);

/* The cells THE DOWNLOADER holds. The pills read this, and only this: counting
 * every installed cell reads an archive the mariner merely lists as water they
 * can delete, so unticking asked to remove cells no download ever wrote.
 * lk_noaa_note_installed still names every installed cell, because skipping
 * what the mariner holds elsewhere is the right price for a download. */
void lk_noaa_note_managed (LkNoaa *self, const char *const *names);

/* The regions this device has downloaded, as the picker opens them. Written
 * when a download starts and read when the picker opens. */
char **lk_noaa_downloaded_regions (LkNoaa *self);

/* Take regions out of that record, when the mariner has removed their charts.
 * Without this the picker opens them ticked again and reads as holding water
 * it has just deleted. */
void lk_noaa_forget_downloaded (LkNoaa *self, const char *const *ids);

/* Drop recorded regions the downloader no longer holds whole. Charts removed
 * by other means leave the record naming water that is gone. Does nothing
 * before the per-region counts are in. */
void lk_noaa_prune_downloaded (LkNoaa *self);

/* Write the regions this device holds whole into that record, once, for a
 * library downloaded before the record existed. FALSE when the catalog is not
 * in yet, or when the record already has something in it. */
gboolean lk_noaa_adopt_downloaded (LkNoaa *self);

/* The dataset names of every cell covering `region_ids`, a comma separated
 * list. Transfer full, NULL-terminated, empty before the catalog is read.
 *
 * Regions overlap, because NOAA files a cell under one district that covers
 * another's. The cells a shell removes are the unpicked regions' minus every
 * region still picked. */
char **lk_noaa_region_cells (LkNoaa *self, const char *region_ids);

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

/* Where downloaded cells are staged before they bake. ONE directory, so the
 * whole download bakes as a single chart set. Free with g_free. */
char *lk_noaa_download_dir (void);


G_END_DECLS
