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

/* The components `shell` carries: "macos", "ios", "android", "linux" or
 * "windows". One manifest serves every build, so a shell reads the entries that
 * name it and no others. A shell the manifest never names gets this app's terms
 * and no components. NULL only when the read cannot be allocated. */
lookout_licenses *lookout_licenses_read(const char *shell);
void              lookout_licenses_free(lookout_licenses *l);
/* The components, in the order the manifest lists them. Group them by `group`
 * in that order: it is the reading order, not an alphabet. */
const lookout_license *const *lookout_licenses_all(const lookout_licenses *l, size_t *out_n);
/* This app's own terms. NOT a component and not in the count above, so it does
 * not belong in a component tally. Only `name`, `summary`, `license`,
 * `copyright`, `url` and `text` are set; the rest are empty. */
const lookout_license *lookout_licenses_app(const lookout_licenses *l);

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
 * *out_lon (either may be NULL), or 0 when the text is not a position. A
 * decimal pair outside ±90 / ±180 is refused. */
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
