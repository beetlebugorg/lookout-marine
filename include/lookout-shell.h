/* lookout-shell.h - the shell kit: the license manifest and the format kit.
 * Included from lookout.h. */
#ifndef LOOKOUT_SHELL_H
#define LOOKOUT_SHELL_H
#include <stdint.h>
#include <stddef.h>
#include "lookout.h"
#ifdef __cplusplus
extern "C" {
#endif

/* ---- licenses ---------------------------------------------------------- */

/* This app's terms and every component it is built from, as JSON, for the
 * licenses screen. Baked in from vendor/licenses/licenses.json, so it is
 * complete with no connection.
 *
 *   {"app":{"name":"Lookout Marine","summary":"...","license":"MIT",
 *           "copyright":"...","url":"...","text":"<the full MIT text>"},
 *    "components":[
 *      {"id":"wamr","name":"WebAssembly Micro Runtime","group":"Plugins",
 *       "summary":"...","license":"Apache 2.0 with the LLVM exception",
 *       "license_short":"Apache-2.0",
 *       "license_note":"...","version":"WAMR-2.4.5","commit":"25bd7eb...",
 *       "pinned_in":"scripts/build-wamr.sh","copyright":"...","url":"...",
 *       "shells":["macos","ios","android","linux","windows"],
 *       "text":"<the full license text>","notice":""}]}
 *
 * `app` is this app's own terms. It is not a component and does not belong in
 * the component count.
 *
 * `shells` is which builds carry that component: "macos", "ios", "android",
 * "linux" or "windows". One manifest serves every build, so a shell draws the
 * entries that name it and no others.
 *
 * `license_short` names the same terms in twenty characters or less, for the
 * narrow column a list of components is read down. `license` is what a detail
 * pane says.
 *
 * `text` is the license, whole and unmodified, hard-wrapped as upstream wrote
 * it. Never truncate it or summarize it on screen.
 *
 * `notice` is the component's NOTICE file, which Apache 2.0 section 4(d) makes
 * travel with the software. It is a separate obligation from the license and
 * is empty for a component that ships none.
 *
 * An empty `license` means the terms could not be determined. The entry still
 * ships, and `license_note` says why. Empty `version` or `commit` means
 * upstream states none, and a component that publishes neither has both empty.
 *
 * Static storage: valid for the life of the process, needs no handle and is
 * safe from any thread. *out_len (NULL to ignore) receives the length. */
const char *lookout_licenses_json(size_t *out_len);

/* ---- reading the licenses --------------------------------------------------
 *
 * The same manifest, as structs, filtered to the shell that asks. A read is a
 * copy, and everything it hands back dies at lookout_licenses_free. */

typedef struct lookout_licenses lookout_licenses;

/* Above this many components a screen groups the rows under their headings and
 * offers a search. Below it the headings outnumber the rows. */
#define LOOKOUT_LICENSES_GROUP_ABOVE 12

/* One component, or this app's own terms. Every field above is documented for
 * lookout_licenses_json and means the same here. */
typedef struct {
    const char *id;
    const char *name;
    const char *group;
    const char *summary;
    const char *license;
    const char *license_short;
    const char *license_note;
    const char *version;
    const char *commit;
    const char *pinned_in;
    const char *copyright;
    const char *url;
    const char *text;
    const char *notice;
} lookout_license;

/* The components `shell` ships with: "macos", "ios", "android", "linux" or
 * "windows". One manifest serves every build, so a shell reads the entries that
 * name it and no others. A shell the manifest never names gets this app's terms
 * and no components. NULL only when the read cannot be allocated. */
lookout_licenses *lookout_licenses_read(const char *shell);
void              lookout_licenses_free(lookout_licenses *l);
/* The components, in the order the manifest lists them. Group them by `group`
 * in that order, which the manifest sets. */
const lookout_license *const *lookout_licenses_all(const lookout_licenses *l, size_t *out_n);
/* This app's own terms. NOT a component and not in the count above, so it does
 * not belong in a component tally. Only `name`, `summary`, `license`,
 * `copyright`, `url` and `text` are set; the rest are empty. */
const lookout_license *lookout_licenses_app(const lookout_licenses *l);

/* ---- the settings store ----------------------------------------------------
 *
 * What a shell keeps across launches, in one file: the camera pose, the
 * recents, the mariner settings, the plugin values, the chart links, the chart
 * sets and the raster charts. Four shells kept four stores over four platform
 * preference systems, and every one of them had to be taught the same key
 * names.
 *
 * THE FILE IS AN INI at <dir>/settings.ini: `[group]` lines, `key=value` under
 * them, a list as its items separated and terminated by semicolons. Backslash,
 * newline, tab, carriage return and (in a list item) the semicolon are escaped.
 * A key holds text; what a value MEANS is the accessor's business.
 *
 * WRITES COALESCE. A pose saved every three seconds does not fsync a file
 * every three seconds: a write marks the store dirty and the file is written at
 * the next lookout_store_flush, at lookout_store_close, or once the oldest
 * unwritten change is a second old.
 *
 * ONE LOCK over the file, so two writers cannot interleave and lose a group.
 *
 * A FILE THAT WILL NOT PARSE is set aside as settings.ini.broken before an
 * empty store replaces it, so a mariner's library stays recoverable.
 *
 * No handle: a shell reads its store before it opens anything. */

/* `lookout_store` is declared in lookout.h, because the set list in
 * lookout-library.h needs one too.
 *
 * The groups. A shell that names its own group here names it for every shell. */
#define LOOKOUT_STORE_VIEW       "view"
#define LOOKOUT_STORE_RECENTS    "recents"
#define LOOKOUT_STORE_RASTER     "raster"
#define LOOKOUT_STORE_MARINER    "mariner.v1"
#define LOOKOUT_STORE_PLUGINS    "plugins.v1"
#define LOOKOUT_STORE_CHARTLINKS "chartlinks"
#define LOOKOUT_STORE_CHARTSETS  "chartsets"

/* Open the store under `dir`, reading settings.ini if it is there. The
 * directory is made at the first write, so a shell that only reads leaves no
 * trace. NULL only when the store cannot be allocated. */
lookout_store *lookout_store_open(const char *dir);
/* Write anything waiting, then close. */
void lookout_store_close(lookout_store *s);
/* Write anything waiting now, whatever the coalesce window says. */
void lookout_store_flush(lookout_store *s);

int    lookout_store_has(lookout_store *s, const char *group, const char *key);
/* NULL when the key is not set. Borrowed until the next write to this store. */
const char *lookout_store_text(lookout_store *s, const char *group, const char *key);
/* `fallback` when the key is not set or does not parse as a number. */
double lookout_store_number(lookout_store *s, const char *group, const char *key,
                            double fallback);
/* "true" and "1" are true, "false" and "0" false, anything else `fallback`. */
int    lookout_store_flag(lookout_store *s, const char *group, const char *key,
                          int fallback);
/* NULL and *out_n 0 when the key is not set. Borrowed until the next write. */
const char *const *lookout_store_list(lookout_store *s, const char *group,
                                      const char *key, size_t *out_n);
/* The keys set under a group, in the order they were written. This is how a
 * shell reads back the plugin ids it saved a config for. Borrowed until the
 * next write. */
const char *const *lookout_store_keys(lookout_store *s, const char *group,
                                      size_t *out_n);

void lookout_store_set_text(lookout_store *s, const char *group, const char *key,
                            const char *value);
/* Written in its shortest form, so an integral value writes as an integer. */
void lookout_store_set_number(lookout_store *s, const char *group, const char *key,
                              double value);
void lookout_store_set_flag(lookout_store *s, const char *group, const char *key,
                            int value);
/* An EMPTY list clears the key, so a read of it comes back empty. */
void lookout_store_set_list(lookout_store *s, const char *group, const char *key,
                            const char *const *items, size_t n);
/* Forget a key. Forgetting the last key of a group forgets the group. */
void lookout_store_remove(lookout_store *s, const char *group, const char *key);

/* Hand the store to a chart handle and the ENGINE keeps the camera pose and the
 * mariner's display settings in it: they are restored at once, the pose is
 * written down as the mariner moves, and both are written at lookout_close and
 * lookout_detach_surface. Four shells each had their own copy of this, with the
 * same fields and the same cadence.
 *
 * The store belongs to the SHELL and must outlive the handle. Pass NULL to
 * detach, which writes the pose down on the way out. A handle with no store
 * persists nothing and behaves exactly as it did before there was one.
 *
 * The pose goes in the `view` group and the settings in `mariner.v1`, under
 * the names above, so a chart opened on one shell and moved on another reopens
 * where it was left.
 *
 * `device_scale`, `ignore_scamin`, `scamin_filter_gate` and the viewing groups
 * are NOT saved: the first is the device's, the next two are debug toggles, and
 * the last is a borrowed pointer. */
void lookout_set_store(lookout *h, lookout_store *s);

/* ---- the frame loop --------------------------------------------------------
 *
 * When the next frame is, and what to advance before it: the gap since the last
 * tick, the fling, the queued chart-link answers, and the verdict.
 *
 * lookout_tick_anim, lookout_animating and lookout_needs_redraw stay for a
 * shell that has not adopted this. */

typedef enum {
    LOOKOUT_FRAME_RENDER = 0,
    /* Nothing to draw yet, and something is coming: ask again in `wait_ms`. */
    LOOKOUT_FRAME_WAIT   = 1,
    /* Nothing is moving. Stop the loop; lookout_frame_kick starts it again. */
    LOOKOUT_FRAME_IDLE   = 2
} lookout_frame_verdict;

typedef struct {
    lookout_frame_verdict verdict;
    /* For LOOKOUT_FRAME_WAIT: how long before asking again. 0 is the next
     * display tick, the rate a build fills in at. */
    int wait_ms;
    /* 1 while a background tessellation is filling in, for the loader. */
    int building;
} lookout_frame;

/* One tick. The gap since the last tick is measured here and capped: an app
 * that was in the background for a minute must not advance a fling by a minute.
 *
 * A shell that skips a LOOKOUT_FRAME_RENDER loses nothing, because the next
 * tick measures the whole elapsed gap. */
void lookout_frame_next(lookout *h, lookout_frame *out);

/* Start the loop again after a change the shell made itself: a gesture, an
 * opened chart, a setting. */
void lookout_frame_kick(lookout *h);

/* ---- the format kit ----------------------------------------------------
 *
 * The strings a mariner reads and the text a mariner types. Each writes into
 * the caller's buffer and allocates nothing, so none of it needs a handle and
 * all of it is safe from any thread.
 *
 * A writer NUL-terminates `out` and returns the length written, excluding the
 * NUL. It returns 0 and writes an empty string when `cap` is short, when `out`
 * is NULL, or when there is no string for the value. The buffer sizes below are
 * large enough for every value. */

#define LOOKOUT_COORD_MAX    32
#define LOOKOUT_POSITION_MAX 72
#define LOOKOUT_SCALE_MAX    32

/* Degrees and decimal minutes with a hemisphere: "38°58.578'N". A longitude
 * (is_lat = 0) has three degree digits, so a pair keeps its column width.
 * Returns 0 for a value that is not finite. */
size_t lookout_fmt_coord_dm(double value, int is_lat, char *out, size_t cap);

/* A full position, latitude first: "38°58.578'N 076°28.920'W". */
size_t lookout_fmt_position(double lat, double lon, char *out, size_t cap);

/* The 1:N display scale with group separators: "1:13,267". The separator is a
 * comma on every shell, independent of locale. A denominator of zero or less
 * writes "1:—". */
size_t lookout_fmt_scale(double denominator, char *out, size_t cap);

/* The S-52 navigational purpose band for a display scale: "Berthing",
 * "Harbor", "Approach", "Coastal", "General", "Overview", or "—" below 1:0.001.
 * Static storage, valid for the life of the process. */
const char *lookout_band_name(double denominator);

/* Parse a position the mariner typed: a decimal pair ("38.98, -76.48") or
 * degrees with hemispheres ("38°58.8'N 076°29.0'W", "38 58 30 N, 76 29 W").
 * Either half may lead in the hemisphere form. Returns 1 and fills *out_lat and
 * *out_lon (either may be NULL), or 0 when the text is not a position.
 *
 * The two axes differ, in both forms. A latitude past 90 is refused: the poles
 * are the ends of the axis. A longitude past 180 is wrapped: it names a real
 * place, so 181 East arrives as 179 West. A value already at either end of the
 * longitude range keeps its sign. */
int lookout_parse_position(const char *text, double *out_lat, double *out_lon);

/* Parse a scale the mariner typed: "25000", "25,000", "1:25000", "25k",
 * "1:2.5M". Returns 1 and fills *out_denominator (may be NULL), or 0 when the
 * text is not a scale. A denominator outside 100 to 100,000,000 is refused. */
int lookout_parse_scale(const char *text, double *out_denominator);

/* A wanted display scale as a zoom delta, to hand to lookout_zoom_at. At one
 * latitude the denominator is C·cos(lat)/2^zoom, so the engine's own zoom does
 * the work and keeps its limits and its easing. Returns 0 when either
 * denominator is zero or less. */
double lookout_zoom_delta_for_scale(double current_denominator,
                                    double wanted_denominator);

#ifdef __cplusplus
}
#endif
#endif /* LOOKOUT_SHELL_H */
