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

/* ---- reading the plugins ---------------------------------------------------
 *
 * One read, then ask a plugin what it asks consent for and what it lets the
 * mariner set.
 *
 * A read is a copy taken under the api lock, so the engine goes on changing
 * while you hold one, and everything it hands back dies at
 * lookout_plugins_free.
 *
 * Every collection is one call that returns a borrowed array and its length.
 * Every struct in one of those arrays is read-only and holds no collection of
 * its own: ask for that with the next call down. Every string is
 * NUL-terminated. */

typedef struct lookout_plugins lookout_plugins;

/* NULL when no plugin layer is up. */
lookout_plugins *lookout_plugins_read(lookout *h);
void             lookout_plugins_free(lookout_plugins *p);

/* ---- what is loaded -------------------------------------------------------- */

typedef enum {
    LOOKOUT_ORIGIN_BUNDLED   = 0,
    LOOKOUT_ORIGIN_INSTALLED = 1,
    LOOKOUT_ORIGIN_DEVELOPER = 2
} lookout_plugin_origin;

typedef struct {
    const char *id;
    const char *name;
    const char *version;
    /* The status document the plugin wrote, as text. */
    const char *status;
    /* Only an installed plugin offers Uninstall; a developer copy says so. */
    lookout_plugin_origin origin;
    int live;
} lookout_plugin;

const lookout_plugin *const *lookout_plugins_all(const lookout_plugins *p,
                                                 size_t *out_n);
/* The plugin holding `id`, or NULL. For a shell keeping a selection across a
 * read. */
const lookout_plugin *lookout_plugins_find(const lookout_plugins *p, const char *id);

/* ---- what a plugin asks consent for ---------------------------------------- */

/* One capability the manifest asked for, in the consent sheet's wording. The
 * wording is the core's, so every shell says the same thing. */
typedef struct {
    const char *name;      /* "net.http", "ais.read" */
    const char *sentence;
    /* Tracks lookout_plugin_grant_set. */
    int granted;
} lookout_plugin_capability;

const lookout_plugin_capability *const *lookout_plugin_capabilities(
    const lookout_plugin *p, size_t *out_n);

/* What the mariner consented to: the addresses net.http may dial, the topics
 * bus.publish may publish, the ports net.udp may listen on, the extensions
 * `files` may open. A capability grants nothing on its own, so an empty
 * allowlist reaches nothing, and a capability with nothing to name is empty. */
const char *const *lookout_plugin_capability_allows(
    const lookout_plugin_capability *c, size_t *out_n);

/* ---- what a plugin lets the mariner set ------------------------------------ */

typedef enum {
    LOOKOUT_PLUGIN_SETTING_NUMBER = 0,
    LOOKOUT_PLUGIN_SETTING_TOGGLE = 1,
    LOOKOUT_PLUGIN_SETTING_TEXT   = 2,
    /* A setting the mariner adds more than one of: the connections are the
     * first. It declares the shape of one item and keeps a value per item, so
     * `value` means nothing on it. See the item calls below. */
    LOOKOUT_PLUGIN_SETTING_LIST   = 3
} lookout_plugin_setting_kind;

/* Where a setting belongs. These are the app's own settings sections, which a
 * plugin's settings file into alongside the shell's, so a mariner meets no
 * plugin system. */
typedef enum {
    LOOKOUT_SECTION_DISPLAY = 0, LOOKOUT_SECTION_DEPTHS, LOOKOUT_SECTION_TEXT,
    LOOKOUT_SECTION_CHARTS,      LOOKOUT_SECTION_VESSELS,
    LOOKOUT_SECTION_ALARMS,      LOOKOUT_SECTION_CONNECTIONS,
    LOOKOUT_SECTION_ADVANCED
} lookout_section;

/* One setting. The fields below the kind apply to that kind only. A field of a
 * LIST setting has this same shape and leaves `value` at its default. */
typedef struct {
    const char *key;
    const char *label;
    /* One sentence on what it does. Empty when the manifest declares none. */
    const char *desc;
    /* The heading it goes under. Empty when the schema declares no groups. */
    const char *group;
    lookout_plugin_setting_kind kind;
    lookout_section section;

    /* NUMBER */
    const char *unit;
    double min, max;
    double default_number;

    /* TEXT */
    const char *default_text;
    const char *placeholder;
    /* The mariner may leave it empty. */
    int optional;
    /* The longest text the core keeps. */
    size_t max_text;

    /* LIST. The plugin's own wording; empty when the manifest declares none,
     * in which case use your own. */
    const char *footer;
    const char *empty;
    const char *add_label;
    /* Which toggle field is the item's own switch. Empty means the first
     * toggle field. */
    const char *switch_key;
    /* How many items the core keeps. Past this the host drops the item, so
     * stop offering Add here. */
    size_t max_items;

    /* NUMBER and TOGGLE: the value in force. A toggle is 0 or 1. */
    double value;
} lookout_plugin_setting;

const lookout_plugin_setting *const *lookout_plugin_settings(
    const lookout_plugin *p, size_t *out_n);

/* ---- the items of a LIST setting ------------------------------------------- */

/* The shape of one item. */
const lookout_plugin_setting *const *lookout_plugin_setting_fields(
    const lookout_plugin_setting *s, size_t *out_n);

/* One item. The items are the shell's: it assigns each one an id when it is
 * added, keeps the id for the item's whole life, and sends them all back on
 * every edit. */
typedef struct {
    const char *id;
} lookout_plugin_item;

const lookout_plugin_item *const *lookout_plugin_setting_items(
    const lookout_plugin_setting *s, size_t *out_n);

/* One value an item holds, in its field's kind. */
typedef struct {
    const char *key;
    lookout_plugin_setting_kind kind;
    /* A number, and 0 or 1 for a toggle. */
    double number;
    const char *text;
} lookout_plugin_value;

/* One value per field, in field order. A field the item omits
 * reads as that field's default. */
const lookout_plugin_value *const *lookout_plugin_item_values(
    const lookout_plugin_item *it, size_t *out_n);
/* The same values by field key, for a caller that knows what it wants. */
double      lookout_plugin_item_number(const lookout_plugin_item *it, const char *key);
int         lookout_plugin_item_flag(const lookout_plugin_item *it, const char *key);
const char *lookout_plugin_item_text(const lookout_plugin_item *it, const char *key);

/* What to browse the boat's network for on a LIST setting's behalf. The host
 * browses nothing itself: the platform's own Bonjour API is the shell's. */
typedef struct {
    const char *type;      /* "_signalk-ws._tcp" */
} lookout_plugin_service;

const lookout_plugin_service *const *lookout_plugin_setting_services(
    const lookout_plugin_setting *s, size_t *out_n);
/* The values an item added from a find has beyond its name, address and
 * port. */
const lookout_plugin_value *const *lookout_plugin_service_values(
    const lookout_plugin_service *svc, size_t *out_n);

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

/* ---- reading the alerts ----------------------------------------------------
 *
 * The same alerts, as structs. A read is a copy, and everything it hands back
 * dies at lookout_alerts_free. */

typedef struct lookout_alerts lookout_alerts;

/* An alarm is audible and repeats until it is acknowledged. A warning and a
 * notice are visible only. A marine alarm does not time out, and looking at it
 * is not acknowledging it. */
typedef enum {
    LOOKOUT_ALERT_NOTICE  = 0,
    LOOKOUT_ALERT_WARNING = 1,
    LOOKOUT_ALERT_ALARM   = 2
} lookout_alert_severity;

typedef struct {
    /* What lookout_plugin_alert_ack names. Never reused. */
    uint64_t id;
    const char *plugin;
    const char *title;
    const char *body;
    lookout_alert_severity severity;
    int acknowledged;
    /* Wall clock in milliseconds since the epoch. */
    int64_t raised;
} lookout_alert;

/* NULL when no plugin layer is up. */
lookout_alerts *lookout_alerts_read(lookout *h);
void            lookout_alerts_free(lookout_alerts *a);
/* Bumps on every change to the set: re-read when it moves, and leave the list
 * alone when it has not. */
uint64_t lookout_alerts_seq(const lookout_alerts *a);
/* Every alert raised and not yet seen off. The order is fixed: what nobody has
 * answered first, then the loudest, then the oldest, so an alert on screen does
 * not jump when another arrives beneath it. */
const lookout_alert *const *lookout_alerts_all(const lookout_alerts *a, size_t *out_n);

/* ---- reading the tables ----------------------------------------------------
 *
 * The declarations, then one table's rows. Both are reads, freed by their own
 * call. */

typedef struct lookout_tables     lookout_tables;
typedef struct lookout_table_rows lookout_table_rows;

/* What a column holds. The type is what makes sorting honest, and the plugin
 * sends SI: distance in METRES, speed in METRES PER SECOND, bearing in DEGREES
 * TRUE, duration in SECONDS. The shell formats for the mariner's units. */
typedef enum {
    LOOKOUT_COLUMN_DISTANCE = 0,
    LOOKOUT_COLUMN_SPEED    = 1,
    LOOKOUT_COLUMN_BEARING  = 2,
    LOOKOUT_COLUMN_DURATION = 3,
    LOOKOUT_COLUMN_NUMBER   = 4,
    LOOKOUT_COLUMN_TEXT     = 5,
    /* "alarm", "warning" or empty. Colour the row by it. */
    LOOKOUT_COLUMN_FLAG     = 6
} lookout_column_type;

typedef struct {
    const char *key;
    const char *label;
    lookout_column_type type;
} lookout_table_column;

typedef struct {
    const char *plugin;
    const char *key;
    const char *title;
    /* The menu to put this table's item in: "Vessels > AIS Targets…". */
    const char *menu;
    /* The column to sort by until the mariner says otherwise, and which way.
     * Empty when the table declares no default. */
    const char *sort_key;
    int sort_ascending;
    /* The row keys holding a position. Empty when a row of this table is not
     * locatable; both are set together. Centring the chart on a locatable row
     * and pinning its bubble is shell-side work. */
    const char *at_lat;
    const char *at_lon;
    /* 1 while lookout_plugin_table_open has said the table is on screen. */
    int open;
    /* How many rows the plugin is holding now. */
    size_t rows;
    /* Bumps on every accepted batch. Re-read the rows when it moves. */
    uint64_t seq;
} lookout_table;

/* NULL when no plugin layer is up. */
lookout_tables *lookout_tables_read(lookout *h);
void            lookout_tables_free(lookout_tables *t);
const lookout_table *const *lookout_tables_all(const lookout_tables *t, size_t *out_n);
const lookout_table_column *const *lookout_table_columns(const lookout_table *t,
                                                         size_t *out_n);

typedef struct {
    const char *id;
    /* The plugin's own ordering policy, 0 first. A column sort never crosses a
     * band, so a plugin that puts its alarmed rows in band 0 keeps them at the
     * top whatever the mariner sorted by. */
    int32_t band;
    /* 1 when the table declares an `at` and this row holds one. */
    int located;
    double lon, lat;
} lookout_table_row;

/* Which of a cell's two values holds it. `absent` is a cell the plugin did not
 * send, which renders as a dash: never heard and heard as zero are different
 * values. */
typedef enum {
    LOOKOUT_TABLE_CELL_ABSENT = 0,
    LOOKOUT_TABLE_CELL_NUMBER = 1,
    LOOKOUT_TABLE_CELL_TEXT   = 2
} lookout_table_cell_kind;

/* One value of one row. `type` says how to FORMAT it, `kind` says which field
 * holds it. A plugin may send a string for a numeric column, and the shell
 * shows the string. */
typedef struct {
    lookout_column_type type;
    lookout_table_cell_kind kind;
    double number;
    const char *text;
} lookout_table_cell;

/* One table's rows, ALREADY IN ORDER: the plugin's bands first, then `sort_key`
 * within each band, then arrival. Rows equal on the sorted column keep the
 * order they arrived in, and an empty cell sorts last in both directions. A
 * flag column is the exception: an empty flag is a row with nothing wrong with
 * it, so it sorts by severity and reverses like any other.
 *
 * `sort_key` NULL or empty uses the declared default sort. NULL when the
 * plugin or the table is unknown. */
lookout_table_rows *lookout_table_rows_read(lookout *h, const char *id, const char *key,
                                            const char *sort_key, int ascending);
void     lookout_table_rows_free(lookout_table_rows *r);
/* The table's batch sequence when these rows were read. */
uint64_t lookout_table_rows_seq(const lookout_table_rows *r);
const lookout_table_row *const *lookout_table_rows_all(const lookout_table_rows *r,
                                                       size_t *out_n);
/* One cell per declared column, in declaration order. */
const lookout_table_cell *const *lookout_table_row_cells(const lookout_table_row *row,
                                                         size_t *out_n);

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
