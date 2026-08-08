/* lk-plugins.h — the mariner's controls over the wasm plugins.
 *
 * A plugin declares a settings schema in its manifest; the core hands the whole
 * registry over as JSON through lookout_plugins_json, and this turns that into
 * something the settings window can draw controls from. The shell knows nothing
 * about what any plugin does — a number field with a unit and a range, a toggle,
 * a text box, and a list the mariner adds rows to, is the whole vocabulary.
 *
 * The mariner never meets the plugin system. A field names the SECTION of the
 * settings window it belongs in ("alarms", "vessels", "connections", …) and the
 * heading it sits under, so an AIS setting reads as a chart setting that happens
 * to come from a plugin. The section ids are the core's, so every shell agrees.
 *
 * Edits auto-apply (debounced, so dragging a spin button does not push per tick)
 * through lookout_plugin_config_set, which the plugin handles live: no restart.
 * They are saved as the config object the plugin last accepted (see lk-store.h).
 *
 * A LIST is a setting the mariner adds ROWS to — the NMEA connections are the
 * first. The rows are the shell's: it assigns each one an id when it is added,
 * keeps the id for the row's whole life, and sends the whole array on every
 * edit. The plugin reports each row's state back under the same id, which is how
 * "Connected · 44 msg/s" finds its way to the right line on screen.
 *
 * Every string a caller gets back from a field, group or list belongs to the
 * registry the model last parsed and is valid until the next reload.
 */
#pragma once

#include <glib.h>

#include "lk-chart-controller.h"

G_BEGIN_DECLS

typedef enum {
  LK_PLUGIN_FIELD_NUMBER,
  LK_PLUGIN_FIELD_TOGGLE,
  LK_PLUGIN_FIELD_TEXT,
} LkPluginFieldKind;

/* One control, as the manifest declared it. */
typedef struct {
  const char       *key;
  const char       *label;
  const char       *desc;          /* what it does for the person at the helm; "" when none */
  const char       *unit;          /* "m", "kn", "min"; "" when none */
  LkPluginFieldKind kind;
  double            min, max;
  double            fallback;      /* the manifest default; a toggle is 0 or 1 */
  const char       *fallback_text; /* a text field's default; only inside a row */
  gboolean          optional;      /* a text field that may be left empty */
} LkPluginField;

/* One heading's worth of controls inside one settings section — the unit the
 * window draws, and the unit "Reset to defaults" acts on. A plugin whose schema
 * spans sections contributes one of these to each. */
typedef struct {
  const char *plugin_id;
  const char *title;   /* the manifest's group, or the plugin's name */
  const char *tab;     /* the settings section it lands in */
  GPtrArray  *fields;  /* LkPluginField* */
} LkPluginGroup;

/* A repeating group the mariner adds rows to. */
typedef struct {
  const char *plugin_id;
  const char *key;
  const char *title;       /* the section heading */
  const char *tab;         /* the settings section it lands in */
  const char *footer;      /* the plugin's own sentence under its rows; "" when none */
  const char *empty;       /* what an empty list says */
  const char *add_label;
  const char *switch_key;  /* which toggle column is the row's own on/off switch */
  int         max_rows;    /* how many rows the CORE keeps; 0 = it did not say */
  GPtrArray  *item_fields; /* LkPluginField*, the columns of one row */
} LkPluginList;

typedef struct _LkPlugins LkPlugins;

/* ---- lifecycle ----------------------------------------------------------- */

/* Reads the registry at once. The controller is not owned and must outlive
 * this. Never NULL, even with no chart open: the model is simply empty. */
LkPlugins *lk_plugins_new (LkChartController *controller);
void       lk_plugins_free (LkPlugins *self);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (LkPlugins, lk_plugins_free)

/* Re-read the registry whole, after an install or anything else that changes
 * WHICH plugins are loaded. FALSE when the core did not answer, which leaves
 * the last good registry in place.
 *
 * AN UNREADABLE REGISTRY IS NOT AN EMPTY ONE. lookout_plugins_json answers NULL
 * with no chart open and in a build with no plugin host; a core holding no
 * plugins answers {"plugins":[]} instead. Reading the two the same way would
 * empty the whole settings window the moment one read came back short. */
gboolean lk_plugins_reload (LkPlugins *self);

/* Take only the STATUS lines from a fresh read. TRUE when any of them moved, so
 * the window redraws its rows and nothing else: the values and rows on screen
 * are the mariner's, and overwriting those mid-edit would fight the keyboard. */
gboolean lk_plugins_refresh_status (LkPlugins *self);

/* Push the settings saved by an earlier session into the plugins that just came
 * up. Called once per chart open, after the plugin layer exists. A saved key the
 * schema no longer declares is ignored by the core. */
void lk_plugins_apply_saved (LkChartController *controller);

/* ---- what each settings section holds ------------------------------------ */

/* TRUE while a plugin has put a group or a list in this section. A section with
 * nothing in it is not shown at all. */
gboolean lk_plugins_tab_populated (LkPlugins *self, const char *tab);

/* The groups and the lists that land in one section, in load then declaration
 * order. Transfer container: the entries belong to the model. */
GPtrArray *lk_plugins_groups (LkPlugins *self, const char *tab);
GPtrArray *lk_plugins_lists (LkPlugins *self, const char *tab);

/* ---- one control --------------------------------------------------------- */

/* The value in force. A toggle is 0 or 1. */
double lk_plugins_value (LkPlugins *self, const char *plugin_id, const char *key);
void   lk_plugins_set_value (LkPlugins *self, const char *plugin_id, const char *key, double value);

/* Put one group back on the defaults its manifest declared. The group is what
 * the mariner sees, so it is what the reset acts on: resetting the collision
 * alarm must not move the target vectors in another section. A LIST is not
 * touched — a reset puts controls back, it does not throw away the connections
 * the mariner typed in, which nothing else could get back. */
void     lk_plugins_reset_group (LkPlugins *self, const LkPluginGroup *group);
gboolean lk_plugins_group_changed (LkPlugins *self, const LkPluginGroup *group);

/* ---- the rows of a list -------------------------------------------------- */

/* The row ids, in order. Transfer container: the strings belong to the model. */
GPtrArray *lk_plugins_rows (LkPlugins *self, const LkPluginList *list);

/* TRUE when the list holds every row the core will keep. The window stops
 * offering Add there: a row past the cap is dropped by the host, and the
 * mariner would be left with a connection that looks like every other one and
 * never connects. */
gboolean lk_plugins_list_is_full (LkPlugins *self, const LkPluginList *list);

/* Add a row on the schema's defaults. The id is minted here and never changes
 * again: it is what the plugin's status items point at. */
void lk_plugins_add_row (LkPlugins *self, const LkPluginList *list);
void lk_plugins_remove_row (LkPlugins *self, const LkPluginList *list, const char *row_id);

const char *lk_plugins_row_text (LkPlugins *self, const LkPluginList *list,
                                 const char *row_id, const char *key);
double      lk_plugins_row_number (LkPlugins *self, const LkPluginList *list,
                                   const char *row_id, const char *key);
gboolean    lk_plugins_row_toggle (LkPlugins *self, const LkPluginList *list,
                                   const char *row_id, const char *key);

void lk_plugins_set_row_text (LkPlugins *self, const LkPluginList *list,
                              const char *row_id, const char *key, const char *text);
void lk_plugins_set_row_number (LkPlugins *self, const LkPluginList *list,
                                const char *row_id, const char *key, double value);
void lk_plugins_set_row_toggle (LkPlugins *self, const LkPluginList *list,
                                const char *row_id, const char *key, gboolean on);

/* What one row is doing, in the plugin's own words: "Connected · 44 msg/s".
 * NULL when the plugin says nothing about that row — a connection it has not
 * reached yet. *out_css_class (NULL to ignore) receives the GTK style class the
 * line reads in: "success" while it works, "warning" while it is trying,
 * "error" when it has given up, "dim-label" while it is switched off.
 * Transfer full. */
char *lk_plugins_row_status (LkPlugins  *self,
                             const LkPluginList *list,
                             const char *row_id,
                             const char **out_css_class);

/* ---- the plugins themselves ---------------------------------------------- */

/* Every loaded plugin, for the section that talks ABOUT plugins rather than
 * about the chart. Transfer container: the strings belong to the model. */
GPtrArray *lk_plugins_all (LkPlugins *self); /* const char *, the ids in load order */

const char *lk_plugins_name (LkPlugins *self, const char *plugin_id);
const char *lk_plugins_version (LkPlugins *self, const char *plugin_id);
/* "bundled", "installed" or "developer". */
const char *lk_plugins_origin (LkPlugins *self, const char *plugin_id);

/* The line under a plugin's name: the state in a word, then its own detail. A
 * dead plugin says so whatever its last words were. *out_css_class as above.
 * Transfer full. */
char *lk_plugins_status_line (LkPlugins *self, const char *plugin_id,
                              const char **out_css_class);

G_END_DECLS
