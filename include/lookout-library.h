/* lookout-library.h - the installed charts: the library open now, the bake,
 * the folder scan, the chart sets, the raster underlay, the charts reached by
 * link, NOAA's charts and the setup flow. Included from lookout.h.
 *
 * OWNERSHIP. Each call that hands out a pointer names which of these it is:
 *
 *   - Static: valid for the life of the process.
 *   - Borrowed until the list changes: valid until the next call that
 *     changes the list it came from.
 *   - Borrowed from the read: valid until the read it came from is freed.
 *   - Borrowed from an argument: valid while the argument the shell passed
 *     is.
 *   - Caller-owned: the shell frees it with the call named. A call that
 *     writes into a buffer the shell passed in keeps no pointer to it. */
#ifndef LOOKOUT_LIBRARY_H
#define LOOKOUT_LIBRARY_H
#include <stdint.h>
#include <stddef.h>
#include "lookout.h"
#ifdef __cplusplus
extern "C" {
#endif

/* ---- the chart library --------------------------------------------------- */

/* Add baked charts to the OPEN library and compose again. Returns how many
 * opened, or -1 on error; a chart that will not open is skipped, as at open.
 *
 * This is how charts arrive into a running app: a bake finishing, a download
 * landing, a drive plugged in. The mariner keeps the chart on screen and the
 * view they were looking at. The composition is rebuilt on a worker thread and
 * swapped in when it is ready, so the charts already drawn keep drawing until
 * then; lookout_needs_redraw goes true when the new one lands.
 *
 * Adding a chart already in the library opens it twice. The caller knows what
 * it has; the core does not deduplicate. */
int lookout_charts_add(lookout *h, const char *const *paths, size_t n);

/* How many charts the library holds. */
uint32_t lookout_charts_count(lookout *h);

/* ---- the bake --------------------------------------------------------------
 *
 * A cell as a hydrographic office publishes it is an S-57 dataset: the survey,
 * rather than a picture of it. The app draws baked archives, so a folder of
 * .000 cells is baked once on the way in.
 *
 * THE SHELL POLLS. No callback crosses back out: a bake worker is not a thread
 * the shell owns, and a callback into its language from a tile57 worker needs
 * care that a poll does not. lookout_bake_poll is one atomic read.
 *
 * `ins` and `outs` are KIND-CONTIGUOUS: the cells, then the sheets, then the
 * lifts, with `cells`, `sheets` and `lifts` naming how many of each. That is
 * the order lookout_bake_order puts them in. A cell is parsed and portrayed
 * from the survey, a sheet is decoded and warped from a picture, and imagery
 * that is already a chart is only lifted out of the archive.
 *
 * From an ARCHIVE each `in` is an ENTRY NAME and the engine reads it where it
 * lies, so importing NOAA's 788 MB All_ENCs.zip never costs the 2.0 GiB of
 * source it holds. */

typedef struct lookout_bake lookout_bake;

/* How far a bake has got. A snapshot: every field is read in one call. */
typedef struct {
    uint32_t done;
    uint32_t total;
    /* How many charts landed. Less than `done` when one was refused. */
    uint32_t baked;
    /* 1 when every phase returned OK. A CANCEL leaves this 1: whatever landed
     * is a usable library. */
    int ok;
    /* 1 while the worker is still going. */
    int running;
    /* The chart written most recently, with no extension, NUL-terminated.
     * Empty until the first one lands, and through the lift, which reports no
     * name. A bake runs several charts at once, so this is one of the few in
     * flight rather than the one `done` counts to. */
    char chart[64];
    /* Why a phase stopped, NUL-terminated. Empty while `ok` is 1, and empty
     * for a failure the baker gave no detail for, where an import that
     * produced nothing has to say so in the shell's own words. */
    char why[256];
} lookout_bake_progress;

/* Start a bake on a thread of its own. NULL when it does not start. The
 * strings are copied. Caller-owned: free with lookout_bake_free. */
lookout_bake *lookout_bake_start(const char *source,
                                 const char *const *ins, const char *const *outs,
                                 size_t cells, size_t sheets, size_t lifts,
                                 int archive);
/* Stop at the next chart boundary. tile57 checks between charts, so this lands
 * within about one cell's bake time. */
void lookout_bake_cancel(lookout_bake *b);
/* Safe from any thread while the bake runs. */
void lookout_bake_poll(const lookout_bake *b, lookout_bake_progress *out);
/* Join the worker and free the bake. CANCEL FIRST, or this blocks for about
 * one chart's bake time. */
void lookout_bake_free(lookout_bake *b);

/* ---- what a bake prepares, and where it goes ----
 *
 * The rules a shell needs before it starts one. */

/* What has to happen to one file before it can be drawn. */
typedef enum {
    /* An S-57 or S-101 cell: parse the survey and portray it. */
    LOOKOUT_PREPARE_CELL  = 0,
    /* A BSB/KAP sheet: decode the picture and warp it. */
    LOOKOUT_PREPARE_SHEET = 1,
    /* Already a chart, and only has to come out of the archive. */
    LOOKOUT_PREPARE_LIFT  = 2
} lookout_prepare;

typedef struct {
    /* The absolute path, or the entry name inside an archive. */
    const char *path;
    /* The dataset name, such as US5MD1MC.000. */
    const char *name;
    /* 1 to 6, or 0 when the name has no usage band. */
    int band;
    lookout_prepare work;
} lookout_bake_item;

/* Sort the items into the order a bake runs them in, in place.
 *
 * COARSE BAND FIRST: Overview, General, Coastal, then the harbor detail. A
 * mariner who cancels half way then has charts that cover the whole passage at
 * a usable scale; the other order gives them every berth in one river and
 * nothing between rivers. Sheets after the survey, and a lift last because it
 * is the cheapest. By name within that, so a run is repeatable.
 *
 * The order is also what makes `ins` and `outs` kind-contiguous for
 * lookout_bake_start. */
void lookout_bake_order(lookout_bake_item *items, size_t n);

/* Where one prepared chart is written under `out_dir`. Writes at most `cap`
 * bytes including the NUL and returns the length, or 0 when it does not fit.
 *
 * Every prepared chart goes in a directory of its own name. That is the layout
 * tile57's own bake writes and an exchange set uses. The raster layer reads a
 * provider from the directory ABOVE, so a folder of 900 sheets written flat
 * becomes 900 switches; and a cell's referenced text and pictures are written
 * beside it only when the chart has a directory to hold them.
 *
 * From an ARCHIVE the output mirrors the entry's own path. A LIFT keeps the
 * name the file already has: an .mbtiles is a chart already. */
size_t lookout_bake_output_path(const char *out_dir, const char *source,
                                const lookout_bake_item *item,
                                char *out, size_t cap);

/* The directory name `source` is prepared into, under the shell's charts root.
 * An archive names it without the .zip. */
size_t lookout_bake_prepared_name(const char *source, char *out, size_t cap);

/* True when `path` is under `root`, the directory this app prepares into.
 * Removing a set may delete what is under it; what is outside is the mariner's
 * own and is never touched. */
int lookout_bake_is_derived(const char *root, const char *path);

/* Removing a set renames first and deletes behind: a 7,224-chart library is
 * 36,000 files, measured at 3.7 seconds of disk work. This is the prefix to
 * rename to. Static. */
const char *lookout_bake_trash_prefix(void);

/* Delete every directory directly under `root` whose name has the trash
 * prefix: what a removal left when the process ended during its delete.
 * Returns how many went. Blocks while it deletes, so call it off the main
 * thread, once at launch. */
size_t lookout_bake_sweep(const char *root);

/* ---- reading a scan --------------------------------------------------------
 *
 * Look through a path for charts, and report what is there. A directory is
 * walked to the bottom, because a bake mirrors the exchange set's tree.
 *
 * Call this BEFORE offering a path to the mariner. A chart folder also holds
 * files that are not charts (CATALOG.031, partition.tpart, the text files a
 * cell references), and a .pmtiles archive may hold pictures rather than a
 * chart. Both open in a file panel and neither draws.
 *
 * A read is a copy, so it needs no serializing: two threads may scan at once
 * and each frees its own read. */

typedef struct lookout_scan lookout_scan;

/* What a scanned file is. */
typedef enum {
    /* A baked archive: it draws now. */
    LOOKOUT_FILE_BAKED         = 0,
    /* An S-57 base cell: it bakes before it draws. */
    LOOKOUT_FILE_SOURCE        = 1,
    /* An S-57 update file: it bakes with its base cell. */
    LOOKOUT_FILE_UPDATE        = 2,
    /* A picture chart: it draws now, through the raster chart list. */
    LOOKOUT_FILE_RASTER        = 3,
    /* A picture chart in a format that bakes first. */
    LOOKOUT_FILE_RASTER_SOURCE = 4,
    /* Not a chart. */
    LOOKOUT_FILE_OTHER         = 5
} lookout_file_kind;

typedef struct {
    /* The absolute path. For a .zip read this is the ENTRY NAME inside the
     * archive, which is what the engine's zip bake takes back: there is no
     * file at it until it is taken out. */
    const char *path;
    /* The dataset name: 8 characters under S-57 (US5MD1MC), up to 13 under
     * S-101 (101AA00DS0001). */
    const char *name;
    lookout_file_kind kind;
    /* 1 to 6, or 0 when the name has no usage band. */
    int band;
    /* The band in the words the readouts use. Empty when `band` is 0. */
    const char *band_name;
    uint64_t bytes;
    /* 0 when the archive states none. */
    double scale;
    /* 1 when the archive states its coverage, and the four edges of it. */
    int located;
    double west, south, east, north;
    /* The dataset edition and update number, from DSID after the update chain
     * is applied. Both 0 when the file states no identity: a baked archive, a
     * picture, or an entry read from a zip listing. */
    uint32_t edition, update;
    /* 1 when this source cell was written after the chart prepared from it.
     * The prepared chart still draws, one edition behind, until the shell
     * prepares the cell again. A NOAA update writes such a cell beside every
     * chart it refreshes. 0 for every other file. */
    int stale;
} lookout_chart_file;

/* The totals, and where the scan started. */
typedef struct {
    const char *root;
    /* S-57 update files. Each one bakes with its base cell. */
    size_t updates;
    /* Files that are not charts. */
    size_t other;
    /* Files that carry a chart name and that the engine refused. Always 0 for
     * an archive, where the name is the whole answer. */
    size_t refused;
    /* How many cells bake before they draw. */
    size_t sources;
    /* The bytes of every cell. */
    uint64_t bytes;
    /* The two-letter agency every chart here came from. EMPTY when they
     * disagree, or when no file here has a dataset name. A mixed folder has
     * no single name, and one of the two would be wrong about the rest. */
    const char *producer;
} lookout_scan_summary;

/* Walk a folder and report what is there. A path that is not a directory is
 * taken as one file, because the open panel takes one archive as readily as a
 * folder of them; a path that is not there reads as one file that is not a
 * chart. NULL only when the read cannot be allocated. No handle needed: this
 * runs before anything is open. Caller-owned: free with lookout_scan_free. */
lookout_scan *lookout_scan_read(const char *path);
/* lookout_scan_read for a chart set that arrives as ONE .zip. Only the
 * archive's central directory is read; nothing is inflated and nothing is
 * written. Caller-owned: free with lookout_scan_free. */
lookout_scan *lookout_scan_zip_read(const char *path);
void          lookout_scan_free(lookout_scan *s);
/* The three calls below are borrowed from the read. */
const lookout_scan_summary *lookout_scan_found(const lookout_scan *s);
/* The baked archives and the source cells, by name. */
const lookout_chart_file *const *lookout_scan_cells(const lookout_scan *s, size_t *out_n);
/* The picture charts. A cell here belongs to lookout_raster_add, not to the
 * chart list. */
const lookout_chart_file *const *lookout_scan_raster(const lookout_scan *s, size_t *out_n);

/* ---- the installed sets ----------------------------------------------------
 *
 * The folders of charts the mariner added, which of them are drawn, and what
 * each holds. A SET is a folder, or one .zip, as a chart agency publishes
 * them. The chart is composed as the UNION of the sets switched on, so
 * switching one off keeps the set installed and drops it from the chart.
 *
 * The calls that add, remove, rescan or switch a set return whether anything
 * changed. What a change MEANS is the shell's: reopen the chart, redraw a
 * settings page.
 *
 * The metadata scans run in the background, ONE AT A TIME: two scans of a big
 * library compete for the same disk, and the full NOAA library is 7,217
 * archives. A scan landing raises lookout_chart_sets_changed.
 *
 * No chart handle. The sets exist before anything is open, and the first-run
 * page is drawn from them. */

typedef struct lookout_chart_sets lookout_chart_sets;

/* One row of the list, as a settings page or a first-run page draws it. */
typedef struct {
    /* The folder or archive. Also the identity: adding the same one twice
     * updates the row rather than making a second. */
    const char *path;
    /* The agency when the charts agree on one, else the folder name. */
    const char *title;
    /* The two-letter producer code. Empty when the charts disagree. */
    const char *producer;
    /* 0 when the mariner switched this set off. It stays installed. */
    int on;
    /* 1 when a downloader owns this set rather than the mariner. See
     * lookout_chart_sets_set_managed. */
    int managed;
    /* 1 once the background scan has read this folder. 0 while it is being
     * read: on the first pass with every count below 0, and after
     * lookout_chart_sets_rescan with what the last pass found. */
    int scanned;
    /* The vector charts ready to draw, and the pictures. */
    size_t charts;
    size_t pictures;
    /* Files that bake before they draw. Inside a .zip that is every chart,
     * because a baked one is lifted out of the archive first. */
    size_t unprepared;
    uint64_t bytes;
    /* The coarsest and finest usage bands present, 1 to 6. 0 when the set
     * holds no cell with a band in its name. */
    int band_lo, band_hi;
    /* The charts this set holds that another switched-on set draws instead,
     * because both hold the same cell and the other copy has the newer
     * edition or is in the managed set: "12 charts also in the NOAA
     * download". They stay installed. 0 for a set switched off. */
    size_t held_back;
    /* The files lookout_chart_set_to_prepare lists: `unprepared` less
     * `refused`. */
    size_t to_prepare;
    /* Files a finished bake of this set did not prepare. They stay out of
     * `to_prepare` until a new edition or update of the cell arrives. See
     * lookout_chart_sets_note_bake. */
    size_t refused;
    /* `to_prepare` by usage band: band_todo[0] is band 1. A file with no band
     * is in no entry. */
    size_t band_todo[6];
    /* The vector charts by usage band, prepared or not: band_count[0] is
     * band 1. `charts` and the vector files in `unprepared`, less any cell
     * with no band. Pictures are in no entry. */
    size_t band_count[6];
} lookout_chart_set;

/* Load the saved list off `store` and start the background scans.
 *
 * `prepared_root` is where the SHELL puts what it prepared, the directory a
 * bake writes into. Each set is scanned there as well as at its own path, and
 * a prepared chart WINS over the file it was made from, so a folder scanned
 * after an import does not ask to be imported again. Pass NULL or "" when the
 * shell prepares nowhere.
 *
 * NULL only when the model cannot be allocated. Caller-owned: free with
 * lookout_chart_sets_close. */
lookout_chart_sets *lookout_chart_sets_open(lookout_store *store,
                                            const char *prepared_root);
void                lookout_chart_sets_close(lookout_chart_sets *s);

/* 1 since the last poll, then clears. A background scan landing raises it, and
 * that is the only change this announces on its own. */
int lookout_chart_sets_changed(lookout_chart_sets *s);

/* The list, in the order added. Borrowed until the list changes. A
 * background scan landing does not end the borrow: the list read before it
 * stays readable, and the next read returns the new scan. */
const lookout_chart_set *const *lookout_chart_sets_all(lookout_chart_sets *s, size_t *out_n);

/* Every file one set holds, as the background scan found it: the charts ready
 * to draw and the ones that bake first, with the band and the size. A shell
 * BAKES FROM THIS rather than walking the folder again, so the scan happens
 * once. `lookout_chart_file` is the scan read's own row.
 *
 * Empty until the scan has read the folder, which lookout_chart_sets_changed
 * announces. Borrowed until the list changes. */
const lookout_chart_file *const *lookout_chart_set_files(lookout_chart_sets *s,
                                                         const char *path,
                                                         size_t *out_n);

/* The files one set still has to prepare: each file that bakes before it
 * draws and has no prepared chart, or whose prepared chart is older than it,
 * as an update leaves it. Inside a .zip each baked chart is listed as well,
 * for a LOOKOUT_PREPARE_LIFT, until it is lifted out. A file a finished bake
 * refused is left out. This is the list to hand
 * lookout_bake_start, and its length is the set's `to_prepare`.
 *
 * Empty until the scan has read the folder. Borrowed until the list
 * changes. */
const lookout_chart_file *const *lookout_chart_set_to_prepare(lookout_chart_sets *s,
                                                              const char *path,
                                                              size_t *out_n);

/* Record how a bake of the set at `path` ended. Call it once the bake has
 * stopped running and before lookout_bake_free, then call
 * lookout_chart_sets_rescan for the set.
 *
 * A bake that ran to the end records as REFUSED each of its `ins` that the
 * rescan still lists to prepare, keyed by the dataset name, edition and update
 * number. A refusal is saved: that edition of the cell leaves
 * lookout_chart_set_to_prepare and counts in `refused`, on this launch and the
 * next. A cancelled or failed bake records a stop, as
 * lookout_chart_sets_note_cancel does. The set need not be on the list yet: a
 * refusal waits for the set's next scan.
 *
 * 1 when recorded. 0 when `b` is NULL or still running. */
int lookout_chart_sets_note_bake(lookout_chart_sets *s, const char *path,
                                 const lookout_bake *b);

/* Record that the mariner stopped the prepare of the set at `path`. The NOAA
 * service does not finish the set's prepare on its own until a scan of it
 * finds a file to prepare that was not there when it stopped: a new cell, or
 * a new edition of one. A stop lasts until the app closes the sets. */
void lookout_chart_sets_note_cancel(lookout_chart_sets *s, const char *path);

/* Put a folder on the list and scan it. 1 when it joined, 0 when it was
 * already there. The paths and the switches are saved; the CELLS are not,
 * because a folder changes underneath the app and a stored cell list would
 * offer charts that are no longer there. */
int lookout_chart_sets_add(lookout_chart_sets *s, const char *path);
/* Read a folder again. 1 when it is on the list.
 *
 * A shell calls this after preparing charts. The bake writes into
 * `prepared_root`, which is scanned beside each set, so a set keeps its
 * pre-bake counts until the folder is read again: every chart unprepared, and
 * no openable path to compose. The row returns to unscanned while the worker
 * reads it, and the result raises lookout_chart_sets_changed the same as any
 * other scan. */
int lookout_chart_sets_rescan(lookout_chart_sets *s, const char *path);
/* Take a folder off the list. 1 when it was on it. This deletes nothing: what
 * a bake produced is the shell's to remove. */
int lookout_chart_sets_remove(lookout_chart_sets *s, const char *path);
/* 1 when the switch moved. */
int lookout_chart_sets_set_on(lookout_chart_sets *s, const char *path, int on);
int lookout_chart_sets_is_on(lookout_chart_sets *s, const char *path);

/* Mark a set as a downloader's rather than the mariner's. A managed set is
 * added and removed where it was downloaded, a shell says so on its row, and
 * it wins a dataset name it shares with a set the mariner added by hand.
 * Returns 1 when the mark changed. */
int lookout_chart_sets_set_managed(lookout_chart_sets *s, const char *path, int managed);

/* Every chart the switched-on sets hold, sorted and deduplicated: the UNION,
 * the list lookout_open_charts_in_window reads. Two sets may overlap, and a
 * cell in both is listed once. Borrowed until the list changes. */
const char *const *lookout_chart_sets_compose(lookout_chart_sets *s, size_t *out_n);


/* ---- raster underlay ---------------------------------------------------
 *
 * Satellite imagery and other picture charts the MARINER supplies, drawn
 * beneath the vector chart. The app offers no catalogue and no download: it
 * opens files that are already on the device.
 *
 * Sources group into SETS by provider, because the same water ships from
 * several — ArcGIS, Bing, Google, Navionics side by side — and finding the one
 * that shows the bottom today means flipping between them over the spot that
 * matters. One set is drawn at a time; the cycle includes "no picture", so a
 * single control also reaches the full chart.
 *
 * A step never moves the camera and never rebuilds the chart scene. That is the
 * point: a mariner comparing two providers over a reef must not lose their fix
 * to a flicker.
 *
 * Tiles stream on a worker with their own memory ceiling, so nothing here
 * blocks a frame. Where a source has no tile — the ordinary case, since these
 * pyramids are clipped to a coastline — the chart simply draws alone. */

/* Open a raster chart (.mbtiles today) and add it to its set. 1 on success, 0
 * when the file will not open — a bad chart never takes the app down, so a host
 * importing a folder keeps going. */
int lookout_raster_add(lookout *h, const char *path);

/* Step to the next raster chart set COVERING THE SAME WATER, or to "no picture"
 * after the last one.
 *
 * Sets that cover different water are not steps in the cycle. They are drawn
 * together (see below), so there is nothing to choose between them. */
void lookout_raster_cycle(lookout *h);

/* The name of the set drawn over THIS view, or "" for no picture.
 *
 * Sets that cover different water draw at the same time: San Francisco and the
 * Atlantic are not a mode a mariner should have to switch. Only sets whose
 * coverage meets are a choice, and the cycle settles it. So one name describes
 * one view, not the whole selection.
 *
 * Borrowed until the set list changes. *out_len (NULL to ignore) receives
 * the length. */
const char *lookout_raster_active_name(lookout *h, size_t *out_len);

/* 1 while the chart is drawing WITHOUT its opaque water and land fills, because
 * a picture is beneath THIS view. NOT the same as "a set is selected": the mode
 * engages only where imagery actually covers, so a mariner carrying a Croatian
 * set still gets a full chart in Chesapeake Bay. A host showing "the chart is
 * reduced" must key off THIS, not off the set name. */
int lookout_raster_over_chart(lookout *h);

/* Name set `i`, ask whether it has enabled charts in view, read which set is
 * drawn, and draw one directly.
 *
 * A mariner carrying four providers for one coast has to SEE what they carry
 * and pick one. A cycle alone cannot report what is installed. Build a menu
 * from these: walk 0..lookout_raster_set_count, keep the sets in view, and mark
 * the one lookout_raster_active_index reports — which is the set drawn over
 * this view, so the mark agrees with the picture.
 *
 * Each set carries its own on/off. Selecting one turns off the sets covering
 * the same water and leaves the other coasts alone, so a mariner switching the
 * Atlantic on does not switch the Pacific on with it.
 *
 * lookout_raster_select(h, -1) turns off what is drawn over THIS view, not
 * every set. Names are borrowed until the set list changes. */
const char *lookout_raster_set_name(lookout *h, uint32_t i, size_t *out_len);
int lookout_raster_set_in_view(lookout *h, uint32_t i);
int32_t lookout_raster_active_index(lookout *h);
void lookout_raster_select(lookout *h, int32_t i);

/* Read and write one set's DRAWN state by index, with no camera in it.
 *
 * A host has to save which sets the mariner chose and put them back at the next
 * launch, because lookout_raster_add draws a set it has just opened — right for
 * a chart the mariner is adding now, wrong for one being re-installed after
 * they switched it off. The pair above cannot do it: lookout_raster_active_index
 * describes one view, and lookout_raster_select(-1) turns off whatever is drawn
 * over that view rather than a set you name. Both fail on the ordinary case of a
 * set covering water the opening view is nowhere near.
 *
 * The election still holds. Showing a set turns off the sets covering the same
 * water, so a restore can never put two competing pictures on at once, and a set
 * whose every chart is switched off (lookout_raster_set_enabled) stays off.
 *
 * Restore in two passes: turn off everything the mariner had off, then turn on
 * everything they had on. One pass in either direction loses a set whose rival
 * was drawn first when the sources were added. */
int  lookout_raster_shown(lookout *h, uint32_t i);
void lookout_raster_set_shown(lookout *h, uint32_t i, int shown);

/* Turn one raster chart on or off WITHOUT removing it, by the path it was added
 * with. A mariner who carries four providers for one coast wants three of them
 * quiet, not deleted — they are half-gigabyte downloads. Takes effect at once;
 * every cached tile is dropped, because a change here changes which picture a
 * given address answers with. 0 when no installed chart has that path. */
int lookout_raster_set_enabled(lookout *h, const char *path, int enabled);
int lookout_raster_enabled(lookout *h, const char *path);

/* The name of a set that covers this view, DRAWN OR NOT, or "". Use it to tell
 * the mariner a picture is available here while it is switched off — otherwise
 * a mariner sailing into coverage sees no reason to turn it on, and never
 * learns the raster chart they installed is under them. Borrowed until the
 * set list changes. */
const char *lookout_raster_available_name(lookout *h, size_t *out_len);

/* What to call the set a raster file belongs to, WITHOUT opening it. A shell
 * needs this before the file reaches the engine: to group a folder of files
 * into the switches a mariner picks between, and to name the set an added file
 * joined.
 *
 * Two shapes, because raster charts arrive two ways. A community MBTiles names
 * its provider, and that is what a mariner chooses between: the same water
 * ships from ArcGIS, Bing, Google and Navionics side by side. A BAKED sheet
 * does not: `tile57 bake` writes one directory per sheet under a bake root, and
 * a bundle holds hundreds, so a sheet at <root>/<stem>/<stem>.pmtiles belongs
 * to <root>.
 *
 * This is the ENGINE'S OWN rule, the one it names the sets it draws by, so a
 * shell that groups by anything else disagrees with what the pill then shows.
 *
 * Static, or borrowed from the argument `path`. It is NOT NUL-terminated:
 * read *out_len bytes. NULL for a NULL path. */
const char *lookout_raster_set_name_for(const char *path, size_t *out_len);

/* Hide the vector chart WHERE A PICTURE COVERS IT. The chart stays everywhere
 * else, so the mariner never gives up the chart to look at the picture. The
 * scene stays built, so this is instant and never rebuilds.
 *
 * Use it to compare. Hide the chart and show it again over a feature; anything
 * that moves is a real disagreement between the chart and the picture. Your eye
 * finds that motion far better than it finds a small offset in a blend. */
void lookout_set_chart_hidden(lookout *h, int hidden);
void lookout_toggle_chart(lookout *h);
int  lookout_chart_hidden(lookout *h);

/* How many sets are installed. The cycle has this many positions, plus one for
 * "no picture". */
uint32_t lookout_raster_set_count(lookout *h);

/* ---- charts by link ------------------------------------------------------
 *
 * A publisher's MapLibre style drawn AS the chart. Paste a link and the chart
 * becomes whatever its publisher styled — a harbour authority's own portrayal,
 * a bathymetry set, an OSM base map.
 *
 * lookout owns the whole behaviour: probing the link, inlining TileJSON
 * sources, generating a wrapper style for bare tiles, fetching sprite packs,
 * building the credit line, templating tile urls, and persisting the list. It
 * still opens no socket. The shell keeps ONE job — fetch the bytes at a url —
 * and lookout drives it. */

/* Fetch the bytes at `url`. Called from lookout with its lock held: do NOT
 * block and do NOT call back into lookout except lookout_http_respond — start
 * the fetch on your own thread and return. Answer from any thread; answering
 * synchronously from inside this callback is also safe, because
 * lookout_http_respond only enqueues (see below).
 *
 * Send an identifying User-Agent and Referer. Public tile hosts serve "access
 * blocked" placeholder tiles to anonymous or platform-default agents —
 * openstreetmap.org's tile usage policy (osm.wiki/Blocked_tiles) wants a
 * unique agent with a way to reach the developer.
 *
 * `allow_file` says whether the shell may read the url from local disk. It is
 * 1 only for: the link the mariner typed; and a style/TileJSON/sprite url
 * named by a document ITSELF read from disk, when it resolves inside the typed
 * link's directory. Tiles are always 0, and so is every url that arrived over
 * the network — a hostile style must not be able to make the shell read
 * arbitrary local files as its "TileJSON". THE SHELL MUST HONOUR THIS. */
typedef void (*lookout_http_get)(void *user, uint64_t req_id,
                                 const char *url, int allow_file);

/* lookout no longer wants this answer: a newer resolve superseded it, or the
 * tile left the wanted set. Advisory — the shell may abort the transfer to
 * save bandwidth (at sea it matters), and answering anyway is harmless: a
 * cancelled id is ignored like an unknown one. Same calling rules as
 * lookout_http_get: lock held, return at once. May be NULL. */
typedef void (*lookout_http_cancel)(void *user, uint64_t req_id);

/* Adopt the shell's fetcher. Everything the feature fetches — style, TileJSON,
 * sibling style.json, sprite index and sheet, and every map tile — comes
 * through it; the shell does not know which is which and fetches the url it is
 * handed.
 *
 * Clearing it (get NULL) stands the feature down and fails every outstanding
 * tile, because a tile nobody will answer is a hole in the chart that never
 * fills.
 *
 * Setting one also resolves whatever chart the mariner left selected: the list
 * is read at open, before the shell can have supplied a fetcher. */
void lookout_set_http_provider(lookout *h, lookout_http_get get,
                               lookout_http_cancel cancel, void *user);

/* Answer one GET. `status` is the final HTTP status after the platform stack
 * followed redirects (200, 404, …), or 0 for a transport failure; only 2xx
 * carries a body lookout reads. `bytes`/`len` are copied before this returns,
 * so the shell may free them immediately. An unknown, cancelled or
 * already-answered id is ignored.
 *
 * Safe from any thread, and it does NOT take lookout's lock: it enqueues and
 * raises the needs-redraw flag, and lookout adopts queued answers at the top
 * of the next frame — so an answer landing never waits on a frame. The cost is
 * that a resolve advances only while frames run: a backgrounded shell finishes
 * one on its first frame back.
 *
 * Every req_id must eventually be answered or cancelled — an id that is
 * neither holds one of lookout's outstanding-request slots — so a shell
 * tearing down its stack answers its in-flight ids with status 0 first. */
void lookout_http_respond(lookout *h, uint64_t req_id, const void *bytes,
                          size_t len, int status);

/* Answer one GET a piece at a time. Same rules as lookout_http_respond, with
 * one addition: deliver the pieces of one request in order on one thread, and
 * set `done` on the last of them. `status` is the same final status on every
 * piece. A shell that already holds the whole body calls lookout_http_respond
 * instead: the same call with a single piece and `done` set.
 *
 * A style, a TileJSON, a sprite sheet and a tile are read whole, and their
 * pieces are joined here. The NOAA service has a call of its own on these
 * terms, lookout_noaa_http_respond_chunk, and writes each piece of a
 * district zip to disk as it arrives.
 *
 * A piece with len 0 and `done` clear is ignored, so a shell may call this for
 * a short read without checking. Answering a piece of a request that has
 * already finished, or one nobody issued, is ignored the same way. */
void lookout_http_respond_chunk(lookout *h, uint64_t req_id, const void *bytes,
                                size_t len, int status, int done);

/* Add a chart by link. lookout resolves it and, on success, adds it to the
 * persisted list and selects it. Non-blocking; progress and result surface
 * through the poll below. A link already carried is selected, not added
 * twice. */
void lookout_chart_link_add(lookout *h, const char *link);

/* Draw one of the carried charts. NULL restores lookout's own chart. */
void lookout_chart_link_select(lookout *h, const char *url);

/* 1 while a chart link's style is drawn rather than lookout's own chart.
 * While it is, the mariner's display settings do not shape the chart. */
int lookout_alt_chart_style_active(lookout *h);

/* Drop one chart. Its kept style text goes with it, and if it was the one
 * being drawn, lookout's own chart comes back. */
void lookout_chart_link_remove(lookout *h, const char *url);

/* Read one chart again: re-fetch a url, re-read a path. When a path will not
 * read, the kept text stands and the error below is set. */
void lookout_chart_link_refresh(lookout *h, const char *url);

/* ---- chart pictures -------------------------------------------------------
 *
 * A picture of one chart at one point, drawn by lookout, for a chart list.
 *
 * LOOKOUT_PICTURE_TILE is for a list of every chart. The chart being drawn
 * is pictured as this handle draws it, once it has settled. `url` NULL or ""
 * is lookout's own chart, and it has a picture only while it is the one
 * drawn. Any other link is the one publisher tile at the point, at the zoom
 * rounded down, for a style whose sources are all raster. A style with any
 * other source has no picture.
 *
 * LOOKOUT_PICTURE_RENDER draws the link on a second handle with no window,
 * whether or not it is the chart being drawn. Its fetches go through this
 * handle's fetcher. One render runs at a time, in the order they were asked
 * for, and each is kept on disk under the cache root, keyed by the link, the
 * zoom, a quarter degree cell and the size. A style that does not resolve has
 * no picture.
 *
 * The picture is scaled to cover `width` by `height` and cropped evenly off
 * the long side. It is written into `dst`, which the shell owns and which
 * holds width * height * 4 bytes: RGBA8, premultiplied alpha, top row first.
 * lookout writes `dst` only on READY.
 *
 * PENDING: lookout is drawing it. The handle's frame loop drives the work.
 * While any picture is pending lookout_frame_next does not return IDLE, and a
 * WAIT is no longer than 100 ms, so a shell whose loop has stopped starts it
 * again after PENDING.
 * When a picture is ready or has failed, lookout_chart_links_changed returns
 * 1, and asking again returns READY or NONE. A picture that has not settled
 * in its time fails: a snapshot after 9 s, a tile style read after 12 s and a
 * tile fetch after 20 s. A render stops after at most 70 ticks of 100 ms.
 * Once no picture is pending, pictures add no wake.
 *
 * NONE: there is no picture. The shell draws its own art for the chart.
 *
 * Pictures are held in memory by link, kind, place and size, and asking
 * again for one that is READY copies it again. */
#define LOOKOUT_PICTURE_TILE    0
#define LOOKOUT_PICTURE_RENDER  1

#define LOOKOUT_PICTURE_NONE    0
#define LOOKOUT_PICTURE_READY   1
#define LOOKOUT_PICTURE_PENDING 2

int lookout_chart_link_picture(lookout *h, const char *url, int kind,
                               double lon, double lat, double zoom,
                               int width, int height, uint8_t *dst);

/* Drop every picture that is not READY and close the second handle. Call it
 * when the list leaves the screen. A picture that failed is tried again on
 * the next ask. */
void lookout_chart_link_pictures_cancel(lookout *h);

/* Everything the UI renders, as one transfer-full document:
 *   {"links":[{"url":…,"name":…}…],
 *    "active":…,          // null = lookout's own chart
 *    "attribution":…,     // "" when none
 *    "error":…,           // "" when none
 *    "busy":true|false}   // a resolve is in flight
 *
 * One document on purpose: borrowed per-field getters could be freed under the
 * caller by a resolve finishing on a fetch thread. Caller-owned: free with
 * lookout_string_free. NULL only when it could not be built.
 *
 * `attribution` is a condition of service on public tile hosts, not a
 * courtesy: draw it while a link is active.
 *
 * Poll after a change — lookout_chart_links_changed is a flag the shell's
 * frame loop reads, so there is no callback to marshal across threads. It has
 * ONE consumer: whoever polls it clears it. */
char *lookout_chart_links_json(lookout *h);
int lookout_chart_links_changed(lookout *h); /* 1 since last poll, then clears */

/* One-time migration from a shell's old store. Pass the old link-list JSON
 * once; lookout adopts and persists it, and the shell then deletes its store.
 * Ignored when lookout has already persisted a list, so a crash between the
 * import and the delete replays harmlessly next launch.
 *
 * Takes {"links":[{"url":…,"name":…}…],"active":…} or a bare array of the
 * same objects. A link entry may also carry "doc", the style text the shell
 * kept: it is taken for a LOCAL link, whose path may no longer read, and
 * ignored for a network one, which is resolved from its url instead. */
void lookout_chart_links_import(lookout *h, const char *links_json);

/* ---- reading the links -----------------------------------------------------
 *
 * The same snapshot, as structs. It is a copy taken under the api lock, so a
 * resolve finishing on a fetch thread cannot free a field under the reader. */

typedef struct lookout_links lookout_links;

typedef struct {
    const char *url;
    const char *name;
} lookout_chart_link;

typedef struct {
    /* The picked link's url. EMPTY draws lookout's own chart, where the JSON
     * writes `active: null`. A url is never empty. */
    const char *active;
    /* A condition of service on public tile hosts, not a courtesy: draw it
     * while a link is active. Empty when there is none. */
    const char *attribution;
    /* Empty when the last resolve succeeded. */
    const char *error;
    /* 1 while a resolve is in flight. */
    int busy;
} lookout_link_state;

/* NULL only when the read cannot be allocated. Poll after
 * lookout_chart_links_changed, which has ONE consumer. Caller-owned: free
 * with lookout_links_free. */
lookout_links *lookout_links_read(lookout *h);
void           lookout_links_free(lookout_links *r);
/* This call and the next are borrowed from the read. */
const lookout_link_state *lookout_links_state(const lookout_links *r);
/* The links the mariner added, in the order they were added. */
const lookout_chart_link *const *lookout_links_all(const lookout_links *r, size_t *out_n);

/* ---- NOAA charts ----------------------------------------------------------
 *
 * NOAA publishes an ENC for every United States waterway at no cost, and a
 * product catalog (ENCProdCat.xml) listing each cell with its edition, its
 * download url and the Coast Guard district it is filed under. lookout reads
 * that catalog, decides which cells a region needs, and fetches them as
 * NOAA publishes them: a district's bundle zip when more than a handful of
 * its cells are needed, else one zip for each cell. It unpacks each zip into
 * a directory as it arrives, so the directory is an ordinary ENC_ROOT, and
 * prepares what arrived. See THE PREPARE below.
 *
 * The shell keeps the one job it has for chart links: fetch the bytes at a
 * url. The service has a handle of its own, lookout_noaa, opened with
 * lookout_noaa_open and given its fetcher with
 * lookout_noaa_set_http_provider. Closing or reopening a chart handle
 * does not touch it, so a download runs while the shell reopens its charts.
 * Every call on it is lookout_noaa_*, declared at the end of this
 * section.
 *
 * WHAT A REGION SELECTS. NOAA files each cell under one district, and water
 * does not stop at a district line: a cell can cover the approach a mariner
 * is sailing and be filed under the district next door. Selecting a region
 * therefore takes the cells NOAA files under it AND every cell whose own
 * coverage overlaps one of those. The result is a superset of NOAA's own
 * per-district bundle, so a region never draws with a hole in it.
 *
 * THE PREPARE. When a download, an apply or an update writes a cell, the
 * service puts the download directory on the chart sets as a managed set,
 * reads it again, and bakes its lookout_chart_set_to_prepare list into
 * lookout_bake_prepared_name(dest_dir) under the chart sets' prepared root,
 * on the bake's own threads. It then records the bake with
 * lookout_chart_sets_note_bake and reads the set again, and
 * lookout_chart_sets_changed returns 1. The run's `outcome` stays
 * LOOKOUT_NOAA_RUNNING until then. The service also finishes a managed set's
 * prepare that an earlier launch left. A service opened with no sets, or
 * with sets that have no prepared root, prepares no chart, and a run ends
 * with its transfers. */

/* One region a mariner picks from. The strings are static. */
typedef struct {
    const char *id;      /* "d5", written to the store */
    const char *name;    /* "Mid-Atlantic" */
    const char *blurb;   /* the waters it covers, in one line */
    int district;        /* the Coast Guard district number */
    /* Where to draw the region on a picker's map, in degrees. A rough extent
     * for display. What a region selects comes from the catalog, so these
     * never decide which cells download. */
    double west, south, east, north;
    /* The map panel the region is drawn on, a LOOKOUT_NOAA_PANEL_ value. */
    int panel;
} lookout_noaa_region;

/* lookout_noaa_region.panel. A picker's map has the lower 48 as its main
 * panel, with Alaska and Hawaii in panels of their own. */
#define LOOKOUT_NOAA_PANEL_LOWER48 0
#define LOOKOUT_NOAA_PANEL_ALASKA  1
#define LOOKOUT_NOAA_PANEL_HAWAII  2

/* The regions, and how many. `out` may be NULL to ask only for the count. The
 * table is static. */
size_t lookout_noaa_regions(const lookout_noaa_region **out);

/* One box of a region's coverage, in degrees. */
typedef struct {
    double west, south, east, north;
} lookout_noaa_box;

/* lookout_noaa_state.phase: what the service is doing now. */
#define LOOKOUT_NOAA_IDLE        0
#define LOOKOUT_NOAA_READING     1 /* reading the catalog */
#define LOOKOUT_NOAA_READY       2 /* a catalog is loaded */
#define LOOKOUT_NOAA_DOWNLOADING 3

/* lookout_noaa_state.outcome: how the download numbered `run` ended. */
#define LOOKOUT_NOAA_NONE      0 /* no download has been ordered */
/* Downloading, or preparing what arrived. */
#define LOOKOUT_NOAA_RUNNING   1
/* The plan ran to its end, at least one chart arrived, and the prepare
 * ended with at least one chart prepared, or with none left to prepare.
 * `failed` counts the charts that did not arrive. */
#define LOOKOUT_NOAA_FINISHED  2
/* Every chart the order named is already installed, or an update found no
 * reissue, and no request went out. Or charts arrived and the prepare
 * refused every one of them. Ordering again cannot change a refusal, so
 * `retry` is 0. `error` names the refusal in the second case. */
#define LOOKOUT_NOAA_EMPTY     3
/* Stopped by lookout_noaa_cancel, by a new download, or by clearing the
 * fetcher. A stop during the transfer still prepares what arrived, and the
 * run ends when that does. */
#define LOOKOUT_NOAA_CANCELLED 4
/* The plan ran to its end with no chart arriving, or hit an error, or the
 * prepare failed. `error` names the cause. */
#define LOOKOUT_NOAA_FAILED    5
/* The order ended before any transfer: no catalog, no fetcher, or no download
 * directory. `error` names the cause. */
#define LOOKOUT_NOAA_REFUSED   6

/* What lookout is doing with NOAA's charts. Every field is read in one call. */
typedef struct {
    /* A LOOKOUT_NOAA_IDLE .. _DOWNLOADING value. */
    uint8_t phase;
    uint8_t have_catalog;
    /* NOAA's validity date for the loaded catalog, "20250903". */
    char date[16];
    /* Unix seconds of the last catalog read that succeeded, or 0. */
    int64_t checked_at;
    uint32_t catalog_cells;
    /* The current download. */
    uint32_t total;
    uint32_t done;
    uint32_t failed;
    uint64_t bytes_total;
    uint64_t bytes_done;
    /* What went wrong, or an empty string. */
    char error[256];
    /* A LOOKOUT_NOAA_NONE .. _REFUSED value, for the download numbered `run`. */
    uint8_t outcome;
    /* Counts the downloads and updates ordered on this service, refused ones
     * included. 0 before the first. A shell that ordered one reads its end
     * when `run` has moved past the value it read before ordering and
     * `outcome` is no longer LOOKOUT_NOAA_RUNNING. */
    uint32_t run;
    /* When `outcome` is LOOKOUT_NOAA_FAILED or LOOKOUT_NOAA_REFUSED: 1 when
     * ordering again can clear the cause, else 0. It is 1 for a refusal with
     * no catalog, where the shell refreshes the catalog and then orders again,
     * and for a download where a transfer failed on the network. */
    uint8_t retry;
    /* 1 while the charts a lookout_noaa_apply took out of the library are
     * being deleted. They are out of the library before the call returns. */
    uint8_t removing;
    /* The directories being deleted, and how many are gone. A prepared
     * chart and the cell it was prepared from are two. */
    uint32_t remove_done;
    uint32_t remove_total;
    /* 1 while the service prepares the managed set: after a download, or to
     * finish one an earlier launch left. */
    uint8_t preparing;
    /* The files the prepare has been through, of `to_prepare`. These and the
     * band counts keep their last values once the prepare ends, until the
     * next download or prepare starts. */
    uint32_t prepared;
    uint32_t to_prepare;
    /* The same by usage band: band_done[0] is band 1. The bake runs coarse
     * band first, so the bands fill in that order. A file with no band is in
     * no entry. */
    uint32_t band_done[6];
    uint32_t band_total[6];
} lookout_noaa_state;

/* ---- The NOAA service handle ----------------------------------------------
 *
 * The handle stands apart from any chart handle:
 *
 * - lookout_close does not touch it. Only lookout_noaa_close ends its
 *   download.
 * - It has its own fetcher, and responses go to
 *   lookout_noaa_http_respond_chunk.
 * - Responses are adopted only when the shell calls
 *   lookout_noaa_changed, from its frame loop or on the wake callback.
 * - The cells held and their editions are read off the chart sets it was
 *   opened with. The shell names none. Every set counts toward the cells
 *   held, switched on or off, so a pick prices what is missing. The update
 *   check reads the editions of the managed sets alone, the charts the
 *   service downloaded.
 *
 * Calls from different threads are serialized on the handle's own lock. The
 * fetcher's get and cancel are called with that lock held, from the thread
 * that made the call. lookout_noaa_poll and
 * lookout_noaa_http_respond_chunk do not take it. */

typedef struct lookout_noaa lookout_noaa;

/* Open the service. `store` and `sets` are borrowed and must outlive the
 * handle. Either may be NULL. With no sets, no cell is held, the update
 * check finds none to check, and no chart is prepared. The prepare writes
 * under the prepared root the sets were opened with. With no store, the
 * update check is daily and its time is kept for the life of the handle. The
 * service reads its cached catalog on the first lookout_noaa_refresh. NULL
 * when it cannot be allocated. Caller-owned: free with lookout_noaa_close. */
lookout_noaa *lookout_noaa_open(lookout_store *store, lookout_chart_sets *sets);

/* Cancel the download and free the handle. The shell stops calling
 * lookout_noaa_http_respond_chunk on `n` before this. */
void lookout_noaa_close(lookout_noaa *n);

/* Called once for each response queued for adopt, at most four times a
 * second while a transfer's bytes arrive, at most five times a second while
 * a prepare's count moves, once when a prepare's bake ends, and when a scan
 * of the chart sets ends or a set is removed. A shell whose frame loop has
 * stopped then knows to call lookout_noaa_changed. An idle service does not
 * call it. Called from any thread, including from inside
 * lookout_noaa_http_respond_chunk and lookout_chart_sets_remove, and from a
 * thread of lookout's own.
 * Post to the shell's own loop and return. Do not call into lookout from
 * it. */
typedef void (*lookout_noaa_wake)(void *user);

/* Install the service's fetcher, on the terms of lookout_set_http_provider.
 * `wake` may be NULL for a shell that calls lookout_noaa_changed every
 * frame. `user` is passed to all three. Clearing it (get NULL) cancels the
 * download. */
void lookout_noaa_set_http_provider(lookout_noaa *n, lookout_http_get get,
                                    lookout_http_cancel cancel,
                                    lookout_noaa_wake wake, void *user);

/* Answer one GET the service's fetcher was handed, on the terms of
 * lookout_http_respond_chunk. Safe from any thread, and does not lock. */
void lookout_noaa_http_respond_chunk(lookout_noaa *n, uint64_t req_id,
                                     const void *bytes, size_t len,
                                     int status, int done);

/* Adopt the responses that arrived, start the next transfers, and return 1
 * when the state lookout_noaa_poll reads has changed since the last
 * call, else 0. An idle service returns 0 on every call. Call it from the
 * frame loop and on every wake. */
int lookout_noaa_changed(lookout_noaa *n);

/* The state, as of the last call that changed it. Does not lock. */
void lookout_noaa_poll(lookout_noaa *n, lookout_noaa_state *out);

/* Read NOAA's product catalog. Non-blocking, and it drives the fetcher. One
 * read is outstanding at a time; calling again while one runs has no effect.
 * The cached catalog, when there is one, is loaded first. The result surfaces
 * through lookout_noaa_poll. */
void lookout_noaa_refresh(lookout_noaa *n);

/* What picking these regions costs. `region_ids` is a comma separated list of
 * region ids ("d5,d8"); an id that names no region is skipped. `out_cells`
 * and `out_bytes` size the download of the cells not held, `out_held` counts
 * the region's cells that are already installed, and `out_held_bytes` sizes
 * fetching those again. Any may be NULL. Returns 0 when no catalog is loaded,
 * leaving every output at 0. */
int lookout_noaa_cost(lookout_noaa *n, const char *region_ids,
                      uint32_t *out_cells, uint64_t *out_bytes,
                      uint32_t *out_held, uint64_t *out_held_bytes);

/* The coverage of one region, as the boxes of the finest coarse band it has:
 * band 3 hugs the coast, and a district without one falls back to 2 then 1.
 * There are tens of them. Writes at most `cap` boxes and returns how many
 * there are, so a caller sizes its buffer by calling once with `out` NULL.
 * Returns 0 before a catalog is read.
 *
 * A region drawn as one rectangle claims water it does not cover: district 8
 * runs Texas to the Keys around the Florida peninsula, and its bounding box
 * paints across Miami. These boxes are the catalog's own. */
size_t lookout_noaa_region_coverage(lookout_noaa *n, const char *region_id,
                                    lookout_noaa_box *out, size_t cap);

/* Download the cells covering these regions into `dest_dir`, created if it is
 * not there. Each cell's exchange set is unpacked as it arrives, so `dest_dir`
 * becomes an ordinary ENC_ROOT, and what arrived is prepared as THE PREPARE
 * above sets out. Replaces a download already running, and stops a prepare
 * running. Progress surfaces through lookout_noaa_poll.
 *
 * Cells already held are left out, so picking water that is partly installed
 * fetches the rest of it. `again` nonzero fetches those too, so a mariner can
 * repair or refresh charts they already hold. A downloaded cell replaces the
 * copy of it already in `dest_dir`.
 *
 * A catalog read through lookout_noaa_refresh does not end a download. The
 * regions are added to the record lookout_noaa_region_state reads. */
void lookout_noaa_download(lookout_noaa *n, const char *region_ids,
                           const char *dest_dir, int again);

/* One region: what it covers, and how much of it the managed sets hold. */
typedef struct {
    /* The cells the region selects. */
    uint32_t cells;
    /* Of those, the ones a managed set draws now. These are the charts
     * lookout_noaa_apply deletes when the region is given back. A cell that
     * still has to be prepared is not counted. */
    uint32_t held;
    /* What fetching the cells no set holds costs, as lookout_noaa_cost
     * sizes it. */
    uint64_t bytes;
    /* What fetching the `held` cells again costs. */
    uint64_t held_bytes;
    /* 1 when `held` is `cells` and both are above 0. */
    uint8_t all_held;
    /* 1 when the region is in the record of downloaded water and `all_held`
     * is 1. This is what a picker ticks. Before any record is written, every
     * region held whole reads 1, so a library downloaded before the record
     * existed opens ticked. */
    uint8_t recorded;
} lookout_noaa_region_info;

/* Fill `out` for the region `region_id` ("d5"). Returns 1, or 0 with `out`
 * zeroed when no catalog is loaded or no region has that id.
 *
 * The record of downloaded water is kept in the store, in the chart sets
 * group under "noaa-picked": the region ids, comma separated. The
 * record written under "noaa-regions" is moved there on the first read, and
 * one under "noaa_regions" is copied. */
int lookout_noaa_region_state(lookout_noaa *n, const char *region_id,
                              lookout_noaa_region_info *out);

/* Make the download at `dest_dir` hold the water in `picked_ids` ("d5,d8"),
 * as a picker's Apply does. In order:
 *
 * - The pick becomes the record.
 * - A download fetching water outside the pick is stopped. An update is
 *   stopped when this deletes charts, and so is a prepare, which this waits
 *   for.
 * - The regions the picker ticked (see lookout_noaa_region_info.recorded)
 *   and the pick leaves out are given back. Their cells that no picked
 *   region selects are deleted: the cell directory under `dest_dir`, and the
 *   chart prepared from it, lookout_bake_prepared_name(dest_dir) under the
 *   chart sets' prepared root. Regions overlap, so a cell a picked region
 *   shares stays. The set at `dest_dir` is read again.
 * - An empty pick deletes the whole download and what was prepared from
 *   it, whatever the catalog lists, and removes the set from the list.
 *   lookout_chart_sets_changed then returns 1.
 * - What the pick lacks is downloaded, as lookout_noaa_download does. When
 *   the pick lacks no cell and `again` is 0, no download is ordered and `run`
 *   stays.
 *
 * A delete renames into one directory with the trash prefix, in the prepared
 * root, and a thread of the service's own deletes it behind. The charts are
 * out of the library when this returns. Progress surfaces through
 * lookout_noaa_poll. Only `dest_dir` as a managed set, or as the directory
 * the service last downloaded into, is deleted from.
 *
 * Returns how many directories left the library. */
uint32_t lookout_noaa_apply(lookout_noaa *n, const char *picked_ids,
                            const char *dest_dir, int again);

/* How many of the managed sets' cells NOAA has reissued: the catalog lists a
 * higher edition, or the same edition with a higher update number. A cell the
 * catalog no longer lists does not count, because NOAA withdraws cells and
 * the one on the device is the last good edition of it.
 *
 * Returns 0 until a catalog has been read from the network since the handle
 * opened. The cached catalog can predate a reissue. The count follows the
 * sets, so a shell reads it again when lookout_chart_sets_changed returns 1. */
uint32_t lookout_noaa_outdated(lookout_noaa *n);

/* Download the reissued editions of the managed sets' cells into `dest_dir`,
 * on the terms of lookout_noaa_download. Cells that are current are
 * skipped. */
void lookout_noaa_update(lookout_noaa *n, const char *dest_dir);

/* The update check. Returns 1 when a check is due and has started, or is
 * still running, else 0. The count is lookout_noaa_outdated once the
 * catalog read ends: `phase` is no longer LOOKOUT_NOAA_READING.
 *
 * The cadence is the store's "noaa-update-check" in the chart sets group:
 * "never", "startup" (once per handle) or "daily" (the default). The last
 * check is "noaa-update-checked", in unix seconds. A check reads the catalog
 * from the network, and uses one read under a day old as it is. The time is
 * recorded only when that read succeeds, so a failed read leaves the check
 * due. With no managed cell that states an edition it returns 0 and sends no
 * request.
 *
 * No timer starts a check. Call this when a chart opens and when
 * lookout_chart_sets_changed returns 1. */
int lookout_noaa_update_due(lookout_noaa *n);

/* Stop the download that is running and drop its outstanding requests. The
 * cells already written stay where they are, and are prepared. A cancel
 * while they are prepared stops the prepare and records the stop with
 * lookout_chart_sets_note_cancel, so the set does not resume on its own. */
void lookout_noaa_cancel(lookout_noaa *n);

/* ---- Setup ----------------------------------------------------------------
 *
 * The setup flow's state: the step on screen, what the primary action and
 * Back do, and whether setup comes up. The shell notes the facts it observes
 * and applies the mariner's actions, then reads the state back. The titles
 * and the words of each step stay in the shell.
 *
 * WHEN IT RUNS. Setup comes up over an app that has settled on having no
 * chart to draw and has no chart link selected, on every launch that finds
 * one. Set Up Later and a finished run put it away for the life of the
 * handle. A library seen with charts in it since setup last came up brings
 * it back once the library is empty again, so a mariner who removes every
 * chart has the page that builds a library. One whose library never held
 * charts keeps Set Up Later.
 *
 * The handle does no I/O, and its state ends with the handle. Call it from
 * one thread: it has no lock. */

typedef struct lookout_setup lookout_setup;

/* lookout_setup_state.step, and the argument of LOOKOUT_SETUP_BEGIN. */
#define LOOKOUT_SETUP_STEP_WELCOME   0
#define LOOKOUT_SETUP_STEP_SOURCE    1
#define LOOKOUT_SETUP_STEP_COVERAGE  2
#define LOOKOUT_SETUP_STEP_ONLINE    3
#define LOOKOUT_SETUP_STEP_IMPORTING 4
#define LOOKOUT_SETUP_STEP_DEPTHS    5

/* Where the first charts come from: the argument of LOOKOUT_SETUP_ADVANCE on
 * the source step, and what lookout_setup_act returns. */
#define LOOKOUT_SETUP_FROM_NOAA   0
#define LOOKOUT_SETUP_FROM_ONLINE 1
#define LOOKOUT_SETUP_FROM_FILES  2

/* The actions lookout_setup_act applies. */
/* Raise setup on the step in `arg`. An unknown step is the welcome step. */
#define LOOKOUT_SETUP_BEGIN        0
/* Raise the step in `arg` on its own, such as the coverage picker opened from
 * the Charts pane. Back applies only from an ended import, and Continue on
 * the import step puts it away. */
#define LOOKOUT_SETUP_BEGIN_PICKER 1
/* The primary action. `arg` is the source picked, read on the source step.
 * NOAA raises the terms and stays on the source step. */
#define LOOKOUT_SETUP_ADVANCE      2
#define LOOKOUT_SETUP_BACK         3
/* NOAA's terms accepted: on to the coverage step. */
#define LOOKOUT_SETUP_AGREE        4
/* NOAA's terms dismissed. The source step stays. */
#define LOOKOUT_SETUP_DECLINE      5
/* Set Up Later, Cancel, or the end of a finished run. */
#define LOOKOUT_SETUP_LATER        6

/* What the shell observes. Each uint8_t is 0 or 1 unless stated. */
typedef struct {
    uint8_t catalog_ready;   /* NOAA's catalog is loaded */
    uint8_t picked;          /* the coverage pick holds a region */
    uint8_t on_link;         /* a chart link is selected */
    uint8_t nothing_to_draw; /* the app has settled on no chart to draw */
    /* A switched-on set holds something to draw. Read it from the sets:
     * nothing_to_draw is also 0 while the first scan of a launch runs. */
    uint8_t has_charts;
    uint8_t work_running;    /* a bake, a scan or a NOAA prepare runs */
    uint8_t downloading;     /* a NOAA transfer runs */
    uint8_t chart_open;      /* a chart with cells in it is open */
    /* lookout_noaa_state.outcome and .run. */
    uint8_t noaa_outcome;
    uint32_t noaa_run;
    /* What Download orders, as the shell prices the pick. Setup keeps the
     * values it holds when Download is pressed. */
    uint32_t pick_charts;
    uint64_t pick_bytes;
} lookout_setup_facts;

/* What the views read. Each uint8_t is 0 or 1 unless stated. */
typedef struct {
    uint8_t step;            /* a LOOKOUT_SETUP_STEP_* value */
    uint8_t showing;
    /* Setup is down and has a reason to come up. The shell applies
     * LOOKOUT_SETUP_BEGIN. */
    uint8_t should_run;
    uint8_t can_go_back;
    uint8_t primary_enabled;
    uint8_t terms_showing;   /* NOAA's terms are up over the source step */
    uint8_t picker_only;     /* raised by LOOKOUT_SETUP_BEGIN_PICKER */
    /* A NOAA download was ordered from the coverage step since setup came
     * up or since Back from the import step. */
    uint8_t ordered;
    /* The order's run ended FAILED, REFUSED, EMPTY or CANCELLED, no work
     * runs, and no chart is ready to continue to. The import step shows the
     * end, and Back returns to the coverage step. */
    uint8_t import_ended;
    /* Work ran on the import step, or the order finished. An import yet to
     * start and one that has finished both have no work running. */
    uint8_t saw_work;
    /* The order as it was placed: pick_charts and pick_bytes at Download. */
    uint32_t order_charts;
    uint64_t order_bytes;
} lookout_setup_state;

/* A setup handle, down, with no facts noted. NULL when it cannot be
 * allocated. Caller-owned: free with lookout_setup_free. */
lookout_setup *lookout_setup_new(void);
void lookout_setup_free(lookout_setup *s);

/* Replace the facts. Call it whenever one of them changes, then read the
 * state. */
void lookout_setup_note(lookout_setup *s, const lookout_setup_facts *facts);

/* Apply a LOOKOUT_SETUP_* action. Returns the LOOKOUT_SETUP_FROM_* source the
 * shell acts on, else -1: NOAA after Download on the coverage step, to start
 * the download; ONLINE after Continue on the online step; FILES after
 * Continue with files picked, to raise the shell's picker. Setup is put away
 * before FILES returns. */
int lookout_setup_act(lookout_setup *s, int action, int arg);

/* Read the state. The type and the call cannot share a name in C. */
void lookout_setup_read(lookout_setup *s, lookout_setup_state *out);

#ifdef __cplusplus
}
#endif
#endif /* LOOKOUT_LIBRARY_H */
