/* lookout-library.h - the installed charts: the library open now, the folder
 * scan, the raster underlay, a host-supplied style and the charts reached by
 * link. Included from lookout.h. */
#ifndef LOOKOUT_LIBRARY_H
#define LOOKOUT_LIBRARY_H
#include <stdint.h>
#include <stddef.h>
#include "lookout.h"
#ifdef __cplusplus
extern "C" {
#endif

/* ---- the chart library --------------------------------------------------- */

/* Add baked charts to the OPEN library and compose again. Answers how many
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

/* 1 while the library's ownership partition is being built, on a worker.
 *
 * This is the long wait when a library is large: opening 7,000 archives is
 * quick, because they are mmap'd rather than read, and then the compositor has
 * to work out which chart owns each piece of water. A host that shows one
 * "loading" state for the whole open tells the mariner nothing about which of
 * the two it is waiting in. */
int lookout_composing(lookout *h);

/* Look through `path` for charts, and report what is there. `path` is one file
 * or a directory; a directory is walked to the bottom, because a bake mirrors
 * the exchange set's tree.
 *
 * Call this BEFORE offering a path to the mariner. A chart folder also holds
 * files that are not charts (CATALOG.031, partition.tpart, the text files a
 * cell references), and a .pmtiles archive may hold pictures rather than a
 * chart. Both open in a file panel and neither draws.
 *
 * The answer is JSON. `cells` is what this build draws, in path order:
 *
 *   {"root":"/Users/x/Charts/ENC_ROOT",
 *    "sources":12,          cells that must bake before they draw
 *    "bytes":3691843584,    the bytes of every cell
 *    "updates":2129,        S-57 update files; each bakes with its base cell
 *    "other":15623,         files that are not charts
 *    "refused":1,           archives with a chart name that the engine refused
 *    "producer":"US",       the agency every chart here came from (absent when
 *                           they disagree, or when none carries a dataset name)
 *    "cells":[{"path":"...","name":"US5MD1MC","kind":"baked","band":5,
 *              "bandName":"Harbor","bytes":1331200,"scale":12000,
 *              "west":-76.6,"south":38.9,"east":-76.4,"north":39.0}],
 *    "raster":[{"path":"...","name":"ncds_08.mbtiles","kind":"raster",...}]}
 *
 * `kind` is "baked" (draws now) or "source" (an S-57 cell that bakes first).
 * A cell in `raster` is a picture chart: it belongs to lookout_raster_add, not
 * here. `scale` and the bounds appear only when the archive carries them.
 *
 * Borrowed: valid until the next lookout_scan_charts. *out_len (NULL to
 * ignore) receives the length. NULL when the path cannot be read. No handle
 * needed: this runs before anything is open.
 *
 * NOT REENTRANT. The answer lives in one buffer that the next call frees, so
 * two threads scanning at once free each other's answer and both read rubbish.
 * A host that scans off its main thread must serialize the calls. */
const char *lookout_scan_charts(const char *path, size_t *out_len);

/* lookout_scan_charts for a chart set that arrives as ONE .zip — the shape a
 * chart agency publishes: NOAA's All_ENCs.zip is 788 MB holding 2.0 GiB across
 * 27,680 entries. Only the archive's central directory is read (about 8 ms for
 * that one); nothing is inflated and nothing is written.
 *
 * Same JSON, so a host reads a folder and an archive the same way, with two
 * differences that follow from there being no files yet:
 *
 *   - Each `path` is the ENTRY NAME inside the archive, not a filesystem path.
 *     That is what the engine's zip bake takes back.
 *   - Nothing is verified, so "refused" is always 0. Verifying means opening an
 *     archive and asking the engine what it holds, and an entry cannot be
 *     opened; inside a .zip the name is the whole answer.
 *
 * Shares the one buffer with lookout_scan_charts, and is NOT REENTRANT for the
 * same reason. */
const char *lookout_scan_zip(const char *path, size_t *out_len);

/* ---- the installed sets ----------------------------------------------------
 *
 * The folders of charts the mariner added, which of them are drawn, and what
 * each holds. A SET is a folder, or one .zip, as a chart agency publishes
 * them. The chart is composed as the UNION of the sets switched on, so
 * switching one off keeps the set installed and drops it from the chart.
 *
 * Every mutator returns whether anything changed. What a change MEANS is the
 * shell's: reopen the chart, redraw a settings page.
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
    /* 1 once the background scan has read this folder. Every count below is 0
     * until then. */
    int scanned;
    /* The vector charts ready to draw, and the pictures. */
    size_t charts;
    size_t pictures;
    /* Files that bake before they draw. */
    size_t unprepared;
    uint64_t bytes;
    /* The coarsest and finest usage bands present, 1 to 6. 0 when the set
     * holds no cell with a band in its name. */
    int band_lo, band_hi;
} lookout_chart_set;

/* Load the saved list off `store` and start the background scans. NULL only
 * when the model cannot be allocated. */
lookout_chart_sets *lookout_chart_sets_open(lookout_store *store);
void                lookout_chart_sets_close(lookout_chart_sets *s);

/* 1 since the last poll, then clears. A background scan landing raises it, and
 * that is the only change this announces on its own. */
int lookout_chart_sets_changed(lookout_chart_sets *s);

/* The list, in the order added. Borrowed until the next call that changes it. */
const lookout_chart_set *const *lookout_chart_sets_all(lookout_chart_sets *s, size_t *out_n);

/* Put a folder on the list and scan it. 1 when it joined, 0 when it was
 * already there. The paths and the switches are saved; the CELLS are not,
 * because a folder changes underneath the app and a stored cell list would
 * offer charts that are no longer there. */
int lookout_chart_sets_add(lookout_chart_sets *s, const char *path);
/* Take a folder off the list. 1 when it was on it. This deletes nothing: what
 * a bake produced is the shell's to remove. */
int lookout_chart_sets_remove(lookout_chart_sets *s, const char *path);
/* 1 when the switch moved. */
int lookout_chart_sets_set_on(lookout_chart_sets *s, const char *path, int on);
int lookout_chart_sets_is_on(lookout_chart_sets *s, const char *path);

/* Every chart the switched-on sets hold, sorted and deduplicated: the UNION,
 * the list lookout_open_charts_in_window reads. Two sets may overlap, and
 * the same cell twice would be composed twice. Borrowed until the next call
 * that changes the list. */
const char *const *lookout_chart_sets_compose(lookout_chart_sets *s, size_t *out_n);

/* ---- reading a scan --------------------------------------------------------
 *
 * The same walk, as structs. A read is a copy, so it needs no serializing: two
 * threads may scan at once and each frees its own answer. */

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
    /* The 8 character dataset name, such as US5MD1MC. */
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

/* Walk a folder and report what is there. NULL when the path cannot be read.
 * No handle needed: this runs before anything is open. */
lookout_scan *lookout_scan_read(const char *path);
/* lookout_scan_read for a chart set that arrives as ONE .zip. Only the
 * archive's central directory is read; nothing is inflated and nothing is
 * written. */
lookout_scan *lookout_scan_zip_read(const char *path);
void          lookout_scan_free(lookout_scan *s);
const lookout_scan_summary *lookout_scan_found(const lookout_scan *s);
/* The baked archives and the source cells, by name. */
const lookout_chart_file *const *lookout_scan_cells(const lookout_scan *s, size_t *out_n);
/* The picture charts. A cell here belongs to lookout_raster_add, not to the
 * chart list. */
const lookout_chart_file *const *lookout_scan_raster(const lookout_scan *s, size_t *out_n);

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
/* Draw a style the HOST supplies instead of lookout's own portrayal: paste a
 * MapLibre style and the chart becomes whatever its publisher styled. `json`
 * NULL (or len 0) restores lookout's chart.
 *
 * The bytes are copied. This is the raw entry: it takes a style that is
 * already whole, and the sources it names are served through the url fetcher
 * at "charts by link" below. Adding a chart BY LINK goes through
 * lookout_chart_link_add instead, which resolves the link and calls this.
 *
 * While a style is set, the mariner's display settings do not shape the chart.
 * They build lookout's portrayal, and this is not it. */
int lookout_alt_chart_style_json(lookout *h, const char *json, size_t len);

/* Is a host-supplied style the one being drawn? */
int lookout_alt_chart_style_active(lookout *h);

/* One sprite pack of the active alt style: the index JSON and the sheet PNG
 * exactly as fetched (maplibre.org/maplibre-style-spec/sprite). `prefix` is
 * the pack's id from the style's array form — its icons resolve as
 * "<prefix>:<name>" — or NULL/"" for the spec's "default" pack (bare names).
 *
 * Sent AFTER lookout_alt_chart_style_json: setting a style clears the previous
 * style's packs. A chart added by link has its packs fetched and folded in by
 * lookout itself. The cells fold into the resident symbol atlas and the scene
 * rebuilds, so icons the style asked for by these names start drawing. Cells
 * the pack marks `sdf` are skipped (they need a pipeline this tier does not
 * run them through). Answers how many cells landed. Bytes are copied. */
int lookout_alt_sprite_pack(lookout *h, const char *prefix,
                            const char *index_json, size_t json_len,
                            const char *png, size_t png_len);

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
 * Borrowed: valid until the set list changes. *out_len (NULL to ignore)
 * receives the length. */
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
 * every set. Names are borrowed and valid until the set list changes. */
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
 * learns the raster chart they installed is under them. Borrowed; valid until the
 * set list changes. */
const char *lookout_raster_available_name(lookout *h, size_t *out_len);

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
 * and lookout drives it.
 *
 * lookout_alt_chart_style_json and lookout_alt_sprite_pack stay as the raw
 * entries for a style that is already whole; nothing here needs them. */

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

/* Add a chart by link. lookout resolves it and, on success, adds it to the
 * persisted list and selects it. Non-blocking; progress and result surface
 * through the poll below. A link already carried is selected, not added
 * twice. */
void lookout_chart_link_add(lookout *h, const char *link);

/* Draw one of the carried charts. NULL restores lookout's own chart. */
void lookout_chart_link_select(lookout *h, const char *url);

/* Drop one chart. Its kept style text goes with it, and if it was the one
 * being drawn, lookout's own chart comes back. */
void lookout_chart_link_remove(lookout *h, const char *url);

/* Read one chart again: re-fetch a url, re-read a path. When a path will not
 * read, the kept text stands and the error below is set. */
void lookout_chart_link_refresh(lookout *h, const char *url);

/* Everything the UI renders, as one transfer-full document:
 *   {"links":[{"url":…,"name":…}…],
 *    "active":…,          // null = lookout's own chart
 *    "attribution":…,     // "" when none
 *    "error":…,           // "" when none
 *    "busy":true|false}   // a resolve is in flight
 *
 * One document on purpose: borrowed per-field getters could be freed under the
 * caller by a resolve finishing on a fetch thread. Free it with
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
 * lookout_chart_links_changed, which has ONE consumer. */
lookout_links *lookout_links_read(lookout *h);
void           lookout_links_free(lookout_links *r);
const lookout_link_state *lookout_links_state(const lookout_links *r);
/* The links the mariner added, in the order they were added. */
const lookout_chart_link *const *lookout_links_all(const lookout_links *r, size_t *out_n);

#ifdef __cplusplus
}
#endif
#endif /* LOOKOUT_LIBRARY_H */
