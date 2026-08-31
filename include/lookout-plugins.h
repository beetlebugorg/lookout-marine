/* lookout-plugins.h - the plugin surface: the registry, install and consent,
 * settings, tables, alerts, the plugin overlay and the files a plugin claims.
 * Included from lookout.h. */
#ifndef LOOKOUT_PLUGINS_H
#define LOOKOUT_PLUGINS_H
#include <stdint.h>
#include <stddef.h>
#include "lookout.h"
#ifdef __cplusplus
extern "C" {
#endif

/* ---- wasm plugins (prototype) ------------------------------------------ */
/* Load and start the plugins in `dir`: every "<id>.manifest.json" with an
 * "<id>.wasm" beside it, which is the layout `zig build plugins` installs into
 * zig-out/plugins. Plugins publish vessel and AIS data and draw chart
 * overlays; the core renders whatever they draw, so a shell needs no other
 * call. Returns 0 on success, -1 when the directory cannot be read or this
 * build has no plugin host (macOS only in the prototype). A plugin that fails
 * to load is logged and skipped, so 0 does not mean every module started.
 *
 * This is also how a shell loads the BUNDLED set: the core plugins that
 * travel inside the application (macOS: LookoutMarine.app/Contents/Resources/
 * Plugins). Any directory that is not the one LOOKOUT_PLUGINS names loads with
 * origin "bundled", so call it with the shell's own directory before
 * lookout_plugins_load_installed() and the precedence comes out right:
 * developer override, then bundled, then installed.
 *
 * Setting LOOKOUT_PLUGINS=<dir> before opening does the same thing with no
 * call at all; LOOKOUT_NMEA=host:port configures the NMEA 0183 plugin. */
int lookout_plugins_load(lookout *h, const char *dir);

/* 1 while a plugin layer is running.
 *
 * A render-on-demand shell needs this. A plugin posts geometry from its own
 * thread with no gesture behind it, so a loop that only wakes on input never
 * shows moving traffic. While this returns 1, keep polling
 * lookout_needs_redraw() at a low rate (a few Hz is enough) instead of
 * sleeping until the mariner touches something. */
int lookout_plugins_active(lookout *h);

/* Every loaded plugin with its settings schema and the values in force:
 *
 *   {"plugins":[{"id":"org.beetlebug.ais","name":"AIS targets",
 *                "version":"1.2","origin":"installed","live":true,
 *                "status":"{\"state\":\"running\",...}",
 *                "capabilities":[
 *                  {"cap":"ais.read","sentence":"Read AIS traffic.",
 *                   "granted":true}],
 *                "settings":[
 *                  {"key":"cpa_limit","label":"CPA limit","kind":"number",
 *                   "unit":"m","min":93,"max":9260,"default":926,"value":926},
 *                  {"key":"cpa_alarm","label":"Collision alarm",
 *                   "kind":"toggle","default":true,"value":true}]}]}
 *
 * A shell draws a control per field — a number field with its unit and range,
 * a toggle as a switch — and needs to know nothing about what a plugin does.
 * "origin" is "bundled", "installed" or "developer": only an installed row
 * offers Uninstall, and a developer row says "developer copy" by its status.
 * "capabilities" is the manifest's asked-for set in consent-sheet wording,
 * with "hosts":[...] on the net.http/net.ws entries and "granted" tracking
 * lookout_plugin_grant_set(). Borrowed until the next plugin query; NULL when
 * no plugin layer is up. *out_len (NULL to ignore) receives the length. */
const char *lookout_plugins_json(lookout *h, size_t *out_len);

/* ---- plugin install and consent ------------------------------------------ */

/* Name the per-user plugin directory, for platforms whose environment cannot.
 * Android's files dir has no path in the environment, so the shell passes it
 * here; every other platform resolves a default (see the table in
 * plugin/install.md) and never needs this call. Call before any other plugin
 * call — the layer reads it once at creation. Returns 0 on success, -1 once
 * the layer is already up. */
int lookout_plugins_install_root(lookout *h, const char *path);

/* Load the INSTALLED plugin set — what lookout_plugin_install() put under the
 * per-user plugin directory (macOS: ~/Library/Application Support/Lookout
 * Marine/Plugins/<id>/) — creating the plugin layer if nothing has yet. Call
 * once after open, and after the bundled set: on an id collision the first
 * copy loaded wins, and the order that gives the documented precedence is
 * LOOKOUT_PLUGINS (loads at open), then bundled, then installed. Idempotent.
 * Returns 0 while the layer is up afterwards, -1 otherwise. */
int lookout_plugins_load_installed(lookout *h);

/* Read a .lkplug without installing it: everything the consent sheet shows.
 *
 *   {"id":"org.example.downwind","name":"Downwind line","version":"1.0",
 *    "sentences":["Read your instruments: position, heading, depth, wind.",
 *                 "Draw on the chart."]}
 *
 * When the id is already loaded, an "installed" object rides beside it so the
 * sheet can call out the delta: {"version":..,"origin":..,"adds":[..],
 * "drops":[..],"downgrade":true|false} — adds/drops are consent sentences the
 * new package gains/loses against the running copy. A refused package answers
 * {"error":"<one sentence, ready to show>"}. Borrowed until the next plugin
 * query; NULL only when no plugin layer can come up. */
const char *lookout_plugin_inspect(lookout *h, const char *path, size_t *out_len);

/* Install a .lkplug the mariner consented to: unpack (the zip must hold
 * exactly manifest.json and the manifest's <id>.wasm; anything else refuses
 * by name), place under the per-user plugin directory, and load hot — the
 * plugin draws without a restart. Reinstalling an id replaces the running
 * copy and resets its grants to the consented set; while LOOKOUT_PLUGINS
 * carries the same id, the files land but the developer copy keeps running. A
 * package claiming the id of a BUNDLED plugin is refused outright, because
 * those ids belong to the application, and the sentence names the plugin it
 * collided with. lookout_plugin_inspect() refuses it the same way, so the
 * sheet shows the reason instead of offering Install.
 *
 * Returns NULL on success, else one borrowed sentence saying why, ready for
 * the shell to show. Valid until the next install or inspect. */
const char *lookout_plugin_install(lookout *h, const char *path);

/* Remove an installed plugin: instance, overlay objects, published values,
 * saved storage, directory — everything it owns. 0 on success; -1 for an
 * unknown id or a bundled/developer plugin (install never wrote those, so
 * uninstall will not touch them). */
int lookout_plugin_uninstall(lookout *h, const char *id);

/* Switch one granted capability on or off, live. The broker checks every
 * mediated call, so a revoked capability answers the plugin -1 and counts
 * denied exactly as if the manifest never asked for it — the plugin keeps
 * running. The state persists beside the plugin's wasm (grants.json) and is
 * read back at every load; absent means everything the manifest asked for.
 * `cap` is the manifest capability name ("ais.read", "net.http", ...).
 * Returns 0, or -1 for an unknown id/capability or one the manifest never
 * asked for — a grant can never exceed the manifest. */
int lookout_plugin_grant_set(lookout *h, const char *id, const char *cap, int on);

/* One plugin's settings, as a JSON object of key to value. Every key its
 * schema declares is present. Borrowed until the next plugin query; NULL when
 * `id` names no loaded plugin. */
const char *lookout_plugin_config_get(lookout *h, const char *id, size_t *out_len);

/* Change one plugin's settings. `json` is an object of the keys the schema
 * declares; a key it does not declare is ignored and a number outside its
 * range is clamped. The plugin receives the WHOLE config at once and applies
 * it live — no restart, and the AIS alarm gate re-evaluates immediately.
 *
 * Returns 0, or -1 when the id is unknown, the plugin declares no settings, or
 * the JSON is not an object. Persisting the values is the shell's job. */
int lookout_plugin_config_set(lookout *h, const char *id, const char *json);

/* ---- plugin tables -------------------------------------------------------- */

/* Every table the loaded plugins declare:
 *
 *   {"tables":[{"plugin":"org.beetlebug.ais","key":"targets",
 *               "title":"AIS Targets","menu":"Vessels",
 *               "columns":[{"key":"name","label":"Vessel","type":"text"},
 *                          {"key":"cpa","label":"CPA","type":"distance"}],
 *               "sort":{"key":"cpa","ascending":true},
 *               "at":{"lat":"lat","lon":"lon"},
 *               "open":false,"rows":0,"seq":0}]}
 *
 * A shell puts one item per table in the menu the declaration names ("Vessels
 * > AIS Targets…") and builds the columns from "columns". A COLUMN TYPE is
 * what makes sorting honest: distance is METRES, speed METRES PER SECOND,
 * bearing DEGREES TRUE, duration SECONDS, and number/text/flag are what they
 * say. The plugin sends SI and the shell formats for the mariner's units:
 * the reverse of the pick report, because a table sorts and converts where a
 * pick shows one formatted line. A "flag" cell is "alarm", "warning" or null,
 * and the shell colours the row by it.
 *
 * "at" names two row keys carrying a position; a row that has them is
 * locatable, and activating it centres the chart and pins its bubble, which
 * is shell-side work. "seq" bumps on every accepted batch: reload the rows
 * when it changes and leave the table alone when it has not.
 *
 * Borrowed until the next plugin query; NULL when no plugin layer is up. */
const char *lookout_plugin_tables_json(lookout *h, size_t *out_len);

/* One table's rows, ALREADY IN ORDER:
 *
 *   {"key":"targets","seq":42,"open":true,
 *    "sort":{"key":"cpa","ascending":true},
 *    "rows":[{"id":"899000101","band":0,"at":[-76.46,38.97],
 *             "cells":["ANNE","899000101",1852,45,6.2,124,585,"alarm"]}]}
 *
 * "cells" is one value per declared column, in declaration order: a number, a
 * string, or null for a cell the plugin did not send, which renders as a
 * dash, because never heard and heard as zero are different values.
 *
 * THE ORDER IS THE PLUGIN'S POLICY FIRST. Every row carries a "band" (0
 * first); `sort_key` sorts WITHIN a band and never across one, so a plugin
 * that puts its alarmed rows in band 0 keeps them at the top of the table
 * whatever column the mariner sorted by. Rows equal on the sorted column keep
 * the order they arrived in, and an empty cell sorts last in both directions.
 * A "flag" column is the exception: an empty flag is not a value nobody has
 * heard, it is a row with nothing wrong with it, so a flag column sorts by
 * severity (alarm, warning, then nothing) and reverses like any other.
 *
 * `sort_key` NULL or empty takes the declared default sort. Borrowed until
 * the next plugin query; NULL when the plugin or the table is unknown. */
const char *lookout_plugin_table_rows(lookout *h, const char *id, const char *key,
                                      const char *sort_key, int ascending,
                                      size_t *out_len);

/* Tell the plugin its table is on screen, or is not. Call it when the dialog
 * opens and when it closes. A plugin builds rows only while a table is open,
 * so a dialog nobody opened costs nothing, and a closed table keeps no rows.
 * Returns 0, or -1 when the plugin or the table is unknown. */
int lookout_plugin_table_open(lookout *h, const char *id, const char *key, int open);

/* ---- plugin alerts -------------------------------------------------------- */

/* Every alert the plugins have raised and the mariner has not seen off:
 *
 *   {"seq":7,"alerts":[
 *     {"id":3,"plugin":"org.beetlebug.ais","severity":"alarm",
 *      "title":"AIS CPA alarm","body":"ANNE: CPA 124 m in 585 s",
 *      "raised":1754700000000,"acknowledged":false}]}
 *
 * SEVERITY IS THE CONTRACT WITH THE SHELL. An "alarm" is audible and repeats
 * until it is acknowledged; a "warning" and a "notice" are visible only. A
 * marine alarm does not time out, and looking at it is not acknowledging it.
 *
 * "raised" is the wall clock in milliseconds since the epoch. "seq" bumps on
 * every change to the set: re-read when it moves and leave the list alone when
 * it has not. The order is fixed here: what nobody has answered first, then the
 * loudest, then the oldest, so an alert on screen does not jump when another
 * arrives beneath it.
 *
 * ONE CONDITION IS ONE ALERT. The host keys them on the plugin, the title and
 * the body, so a plugin restating the same danger updates its alert instead of
 * stacking another, and two vessels closing stay two alarms. An alert whose
 * plugin unloads, or loses the alerts.raise grant, is withdrawn with it.
 *
 * Borrowed until the next plugin query; NULL when no plugin layer is up. */
const char *lookout_plugin_alerts_json(lookout *h, size_t *out_len);

/* Acknowledge one alert by its id: the alarm stops sounding, and the alert
 * stays listed (as "acknowledged") until the condition clears. It silences THAT
 * alert and no other: a mariner who has seen the vessel crossing ahead has not
 * seen the one coming up astern. Once the condition clears and returns, the
 * plugin raises it again and it sounds again. Returns 0, or -1 when no alert
 * holds that id. */
int lookout_plugin_alert_ack(lookout *h, uint64_t id);

/* Offer a file the mariner opened to the plugins.
 *
 * A manifest claims file types — "file_types":[".grib2",".grb"] — and this
 * gives the file to the plugin that claimed the extension of `path`, with read
 * access to it. The mariner opens a weather file the way they open a chart and
 * never learns a plugin was involved; the plugin declares the types it reads
 * and never learns there was a file picker.
 *
 * Call it from every place your shell opens a file — the Open item, a drop on
 * the window, a file the OS hands you at launch. lookout_plugins_json() carries
 * each plugin's "file_types", which is what a picker names in its prompt.
 *
 * Returns 1 when a plugin took the file, 0 when no plugin claims that type, and
 * -1 when one does and the file could not be given to it (two plugins claim the
 * type, or the file cannot be read; the log line says which).
 *
 * A CHART ALWAYS ANSWERS 0, whatever a manifest claims, so charts keep the path
 * they already take. On 0, do with the file what your shell did before there
 * were plugins — a build with no plugin layer also answers 0, so one code path
 * serves both. */
int lookout_open_file(lookout *h, const char *path);

/* What the plugin overlay says about the symbol nearest a LOGICAL point, as
 * JSON: {"title":"...","rows":[["key","value"],...]}. NULL when no symbol
 * carrying a payload is within about 14 pt of it. Use it for hover on a
 * pointer platform; a tap can use it too.
 *
 * Borrowed: valid until the next lookout_overlay_at(). *out_len (NULL to
 * ignore) receives the length. The payload is copied out from under the
 * plugin's own thread, so the pointer stays good even if the plugin redraws
 * that target meanwhile. */
const char *lookout_overlay_at(lookout *h, float x_pt, float y_pt, size_t *out_len);

/* One overlay object, as a hit test or an id lookup answers.
 *
 * `id` is NUL-terminated and goes straight back to lookout_overlay_info().
 * `info` is the pick payload (the same JSON lookout_overlay_at returns), NULL
 * when the object carries none. `lon`/`lat` are where the object draws NOW.
 * Every pointer is borrowed until the next overlay call. */
typedef struct {
    const char *id;
    size_t      id_len;
    const char *info;
    size_t      info_len;
    double      lon, lat;
} lookout_overlay_obj;

/* The overlay symbol nearest a LOGICAL point: 1 when one answers, 0 when none
 * is within about 14 pt. Use it on a tap: pin an info bubble to the id it
 * returns, and follow the object with lookout_overlay_info(). A tap that hits
 * an overlay symbol should not also open the chart pick report. */
int lookout_overlay_hit(lookout *h, float x_pt, float y_pt, lookout_overlay_obj *out);

/* What that object says now: 1 while it exists, 0 once it is gone (the target
 * aged out, or its plugin stopped). Payload and anchor are both current, so a
 * pinned bubble re-reads them every render tick to move itself and refresh its
 * values, and closes itself when this returns 0. */
int lookout_overlay_info(lookout *h, const char *id, lookout_overlay_obj *out);

#ifdef __cplusplus
}
#endif
#endif /* LOOKOUT_PLUGINS_H */
