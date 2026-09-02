/* util/json.h — a small JSON reader for the documents the core hands over as
 * text.
 *
 * Most of the C API answers in structs. Three payloads do not, because their
 * content is not the core's to shape: the status document a plugin writes, the
 * pick payload the plugin overlay attaches to a symbol, and what
 * lookout_plugin_inspect says about a package. The other shells parse those
 * with the platform's own reader (JSONSerialization, org.json). GLib has none,
 * and json-glib only writes here, so this reads the subset JSON actually is:
 * objects, arrays, strings, numbers, booleans, null.
 *
 * A node owns its children. Free the root and the tree goes with it. Every
 * accessor tolerates NULL, so a walk down a missing branch reads as absent
 * rather than crashing.
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef enum {
  LK_JSON_NULL,
  LK_JSON_BOOL,
  LK_JSON_NUMBER,
  LK_JSON_STRING,
  LK_JSON_ARRAY,
  LK_JSON_OBJECT,
} LkJsonKind;

typedef struct _LkJson LkJson;

/* Parse `text`. NULL when it is not JSON, or when trailing junk follows the
 * value — a half-parsed report is worse than none. */
LkJson *lk_json_parse (const char *text);
void    lk_json_free (LkJson *node);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (LkJson, lk_json_free)

LkJsonKind lk_json_kind (const LkJson *node);

/* ---- objects ------------------------------------------------------------ */

/* The member, or NULL when the node is not an object or has no such key. */
const LkJson *lk_json_member (const LkJson *node, const char *name);

/* The member names, sorted, so a raw dump reads the same on every shell.
 * Transfer container: the strings belong to `node`. */
GPtrArray *lk_json_member_names (const LkJson *node);

/* ---- arrays ------------------------------------------------------------- */

guint         lk_json_length (const LkJson *node);
const LkJson *lk_json_at (const LkJson *node, guint index);

/* ---- scalars ------------------------------------------------------------ */

/* A string node's text, else NULL. A number is not coerced: the caller that
 * wants the cell's own digits asks for lk_json_text. */
const char *lk_json_string (const LkJson *node);

/* Any scalar as the text the cell wrote — a number keeps its own digits, so
 * "17" does not come back "17.0". Empty for a container or a NULL node. */
const char *lk_json_text (const LkJson *node);

double   lk_json_number (const LkJson *node, double fallback);
gboolean lk_json_bool (const LkJson *node, gboolean fallback);

/* ---- member shorthands -------------------------------------------------- */

/* NULL for a missing, null, or empty string member — the callers all treat an
 * empty title the same as no title. */
const char *lk_json_member_string (const LkJson *node, const char *name);
int         lk_json_member_int (const LkJson *node, const char *name, int fallback);
gboolean    lk_json_member_bool (const LkJson *node, const char *name, gboolean fallback);

G_END_DECLS
