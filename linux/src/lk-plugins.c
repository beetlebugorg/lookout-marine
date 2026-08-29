#include "lk-plugins.h"

#include "util/json.h"
#include "model/store.h"

#include <math.h>

/* Long enough that dragging a spin button pushes once rather than per tick,
 * short enough that a toggle looks instant. */
#define LK_PLUGIN_APPLY_MS 60

/* The section anything that names none lands in, which is the core's own
 * fallback (src/plugin/host.zig, `Tab`). */
#define LK_PLUGIN_DEFAULT_TAB "advanced"

static const char lk_empty[] = "";

static const char *
lk_or_empty (const char *text)
{
  return text != NULL ? text : lk_empty;
}

/* ---- one row of a list --------------------------------------------------- */

typedef struct {
  LkPluginFieldKind kind;
  double            number;
  gboolean          toggle;
  char             *text;
} LkCell;

typedef struct {
  char       *id;
  GHashTable *cells; /* the column key -> LkCell* */
} LkRow;

static void
lk_cell_free (gpointer data)
{
  LkCell *cell = data;

  g_free (cell->text);
  g_free (cell);
}

static void
lk_row_free (gpointer data)
{
  LkRow *row = data;

  g_free (row->id);
  g_hash_table_unref (row->cells);
  g_free (row);
}

static LkRow *
lk_row_new (const char *id)
{
  LkRow *row = g_new0 (LkRow, 1);

  row->id = g_strdup (id);
  row->cells = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, lk_cell_free);
  return row;
}

/* ---- one plugin ---------------------------------------------------------- */

typedef struct {
  const char *id;
  const char *name;
  const char *version;
  const char *origin;
  gboolean    live;

  /* The status line moves on its own while the window is open, so it is re-read
   * on a poll and kept as a COPY — everything else here borrows from the
   * registry, which a poll does not replace. */
  char   *status;
  LkJson *status_tree;

  GPtrArray *fields; /* LkPluginField*, owned */
  GPtrArray *lists;  /* LkPluginList*, owned */
  GPtrArray *groups; /* LkPluginGroup*, owned */
  GPtrArray *caps;   /* LkPluginCapability*, owned */
  GPtrArray *types;  /* const char *, the file extensions it reads */

  GHashTable *values; /* the field key -> double, boxed */
  GHashTable *rows;   /* the list key -> GPtrArray of LkRow* */

  /* The config JSON as last pushed, so an apply skips a plugin whose settings
   * did not move: one edit used to re-push and re-save every plugin. */
  char *last_json;
} LkPluginState;

struct _LkPlugins {
  LkChartController *controller; /* not owned */

  /* The parsed registry. Every borrowed string below points into it, so it
   * outlives them and is replaced only by a whole reload. */
  LkJson     *registry;
  GPtrArray  *plugins; /* LkPluginState*, owned */
  GHashTable *by_id;   /* the id -> LkPluginState*, not owning */

  guint    apply_id;
  gboolean registry_unread; /* so the log line is written once each way */
};

static void
lk_plugin_group_free (gpointer data)
{
  LkPluginGroup *group = data;

  g_ptr_array_unref (group->fields);
  g_free (group);
}

static void
lk_plugin_list_free (gpointer data)
{
  LkPluginList *list = data;

  g_ptr_array_unref (list->item_fields);
  g_ptr_array_unref (list->discover);
  g_free (list);
}

/* `cap` and `sentence` borrow from the registry; `hosts` is joined here. */
static void
lk_plugin_capability_free (gpointer data)
{
  LkPluginCapability *cap = data;

  g_free (cap->hosts);
  g_free (cap);
}

static void
lk_plugin_state_free (gpointer data)
{
  LkPluginState *state = data;

  g_free (state->status);
  g_clear_pointer (&state->status_tree, lk_json_free);
  g_ptr_array_unref (state->fields);
  g_ptr_array_unref (state->lists);
  g_ptr_array_unref (state->groups);
  g_ptr_array_unref (state->caps);
  g_ptr_array_unref (state->types);
  g_hash_table_unref (state->values);
  g_hash_table_unref (state->rows);
  g_free (state->last_json);
  g_free (state);
}

static LkPluginState *
lk_plugins_find (LkPlugins *self, const char *plugin_id)
{
  if (self == NULL || plugin_id == NULL)
    return NULL;
  return g_hash_table_lookup (self->by_id, plugin_id);
}

/* ---- reading the schema -------------------------------------------------- */

/* One control out of the schema, borrowing every string from `node`. NULL for
 * an entry this shell cannot draw — no key, no kind, or a kind from a newer
 * core than this build. Skipping one field leaves the rest of its group
 * drawable, which is better than dropping the group. */
static LkPluginField *
lk_plugin_field_read (const LkJson *node)
{
  const char *key = lk_json_member_string (node, "key");
  const char *kind = lk_json_member_string (node, "kind");

  if (key == NULL || kind == NULL)
    return NULL;

  LkPluginFieldKind parsed;
  if (g_strcmp0 (kind, "number") == 0)
    parsed = LK_PLUGIN_FIELD_NUMBER;
  else if (g_strcmp0 (kind, "toggle") == 0)
    parsed = LK_PLUGIN_FIELD_TOGGLE;
  else if (g_strcmp0 (kind, "text") == 0)
    parsed = LK_PLUGIN_FIELD_TEXT;
  else
    return NULL;

  LkPluginField *field = g_new0 (LkPluginField, 1);
  const LkJson *fallback = lk_json_member (node, "default");

  field->kind = parsed;
  field->key = key;
  field->label = lk_json_member_string (node, "label");
  if (field->label == NULL)
    field->label = key;
  field->desc = lk_or_empty (lk_json_member_string (node, "desc"));
  field->unit = lk_or_empty (lk_json_member_string (node, "unit"));
  /* An absent bound is wide, not tight. A max defaulting to 1 clamped every
     larger plugin value down to 1; the field is unbounded unless the schema
     says otherwise. */
  field->min = lk_json_number (lk_json_member (node, "min"), 0);
  field->max = lk_json_number (lk_json_member (node, "max"), 1e9);
  field->optional = lk_json_member_bool (node, "optional", FALSE);
  field->placeholder = lk_or_empty (lk_json_member_string (node, "placeholder"));
  field->fallback_text = lk_empty;

  switch (field->kind)
    {
    case LK_PLUGIN_FIELD_TOGGLE:
      field->fallback = lk_json_bool (fallback, FALSE) ? 1 : 0;
      break;
    case LK_PLUGIN_FIELD_TEXT:
      field->fallback_text = lk_or_empty (lk_json_string (fallback));
      break;
    case LK_PLUGIN_FIELD_NUMBER:
    default:
      field->fallback = lk_json_number (fallback, 0);
      break;
    }
  return field;
}

/* The value the core says is in force, which is what the model starts from. */
static double
lk_plugin_field_live_value (const LkJson *node, const LkPluginField *field)
{
  const LkJson *value = lk_json_member (node, "value");

  if (field->kind == LK_PLUGIN_FIELD_TOGGLE)
    return lk_json_bool (value, field->fallback != 0) ? 1 : 0;
  return lk_json_number (value, field->fallback);
}

/* One cell of one row, out of the registry or off the column's default. A NULL
 * row node is a row the mariner just added, which is all defaults. */
static LkCell *
lk_cell_read (const LkJson *row_node, const LkPluginField *field)
{
  LkCell *cell = g_new0 (LkCell, 1);
  const LkJson *value = lk_json_member (row_node, field->key);

  cell->kind = field->kind;
  switch (field->kind)
    {
    case LK_PLUGIN_FIELD_TOGGLE:
      cell->toggle = lk_json_bool (value, field->fallback != 0);
      break;
    case LK_PLUGIN_FIELD_TEXT:
      cell->text = g_strdup (value != NULL ? lk_or_empty (lk_json_string (value))
                                           : field->fallback_text);
      break;
    case LK_PLUGIN_FIELD_NUMBER:
    default:
      cell->number = lk_json_number (value, field->fallback);
      break;
    }
  return cell;
}

static void
lk_plugins_set_double (GHashTable *table, const char *key, double value)
{
  double *boxed = g_new (double, 1);

  *boxed = value;
  g_hash_table_insert (table, g_strdup (key), boxed);
}

/* The group one field belongs to, made on first sight. Keyed by section AND
 * heading: a plugin whose schema spans sections contributes one group to
 * each, and two headings in one section stay apart. */
static LkPluginGroup *
lk_plugin_state_group_for (LkPluginState *state, const char *tab, const char *title)
{
  for (guint i = 0; i < state->groups->len; i++)
    {
      LkPluginGroup *group = g_ptr_array_index (state->groups, i);

      if (g_strcmp0 (group->tab, tab) == 0 && g_strcmp0 (group->title, title) == 0)
        return group;
    }

  LkPluginGroup *group = g_new0 (LkPluginGroup, 1);

  group->plugin_id = state->id;
  group->title = title;
  group->tab = tab;
  group->fields = g_ptr_array_new_with_free_func (NULL); /* the state owns them */
  g_ptr_array_add (state->groups, group);
  return group;
}

/* The scalar controls of one plugin: the registry's flat `settings` array,
 * each entry naming the section and heading it belongs under. */
static void
lk_plugin_state_read_fields (LkPluginState *state, const LkJson *node)
{
  const LkJson *settings = lk_json_member (node, "settings");
  guint n = lk_json_length (settings);

  for (guint i = 0; i < n; i++)
    {
      const LkJson *entry = lk_json_at (settings, i);
      LkPluginField *field = lk_plugin_field_read (entry);

      if (field == NULL)
        continue;

      /* A text field is only ever a column of a list; the core refuses a scalar
       * one, so there is nothing to draw for it here. */
      if (field->kind == LK_PLUGIN_FIELD_TEXT)
        {
          g_free (field);
          continue;
        }

      const char *tab = lk_json_member_string (entry, "tab");
      const char *title = lk_json_member_string (entry, "group");

      g_ptr_array_add (state->fields, field);
      lk_plugins_set_double (state->values, field->key,
                             lk_plugin_field_live_value (entry, field));

      LkPluginGroup *group = lk_plugin_state_group_for (state,
                                                        tab != NULL ? tab : LK_PLUGIN_DEFAULT_TAB,
                                                        title != NULL ? title : state->name);
      g_ptr_array_add (group->fields, field);
    }
}

/* The repeating groups of one plugin, and the rows the core is holding for
 * each. The rows become the shell's the moment they are read: it is the shell
 * that assigns row ids and sends the whole array back on every edit. */
static void
lk_plugin_state_read_lists (LkPluginState *state, const LkJson *node)
{
  const LkJson *lists = lk_json_member (node, "lists");
  guint n = lk_json_length (lists);

  for (guint i = 0; i < n; i++)
    {
      const LkJson *entry = lk_json_at (lists, i);
      const char *key = lk_json_member_string (entry, "key");

      if (key == NULL)
        continue;

      LkPluginList *list = g_new0 (LkPluginList, 1);
      const char *tab = lk_json_member_string (entry, "tab");
      const char *title = lk_json_member_string (entry, "group");

      list->plugin_id = state->id;
      list->key = key;
      list->tab = tab != NULL ? tab : LK_PLUGIN_DEFAULT_TAB;
      list->title = title != NULL ? title : state->name;
      list->footer = lk_or_empty (lk_json_member_string (entry, "footer"));
      list->empty = lk_json_member_string (entry, "empty");
      if (list->empty == NULL)
        list->empty = "Nothing here yet.";
      list->add_label = lk_json_member_string (entry, "add_label");
      if (list->add_label == NULL)
        list->add_label = "Add";
      list->switch_key = lk_or_empty (lk_json_member_string (entry, "switch_key"));
      list->max_rows = lk_json_member_int (entry, "max_rows", 0);
      list->item_fields = g_ptr_array_new_with_free_func (g_free);
      list->discover = g_ptr_array_new_with_free_func (g_free);

      /* What to browse the boat's network for. The core carries the
       * declaration; finding anything is the shell's own job. */
      const LkJson *services = lk_json_member (entry, "discover");
      guint services_n = lk_json_length (services);
      for (guint d = 0; d < services_n; d++)
        {
          const LkJson *service_node = lk_json_at (services, d);
          const char *service = lk_json_member_string (service_node, "service");

          if (service == NULL)
            continue;

          LkPluginDiscover *want = g_new0 (LkPluginDiscover, 1);

          want->service = service;
          want->set = lk_json_member (service_node, "set");
          g_ptr_array_add (list->discover, want);
        }

      const LkJson *columns = lk_json_member (entry, "item_fields");
      guint columns_n = lk_json_length (columns);
      for (guint c = 0; c < columns_n; c++)
        {
          LkPluginField *field = lk_plugin_field_read (lk_json_at (columns, c));

          if (field != NULL)
            g_ptr_array_add (list->item_fields, field);
        }

      /* A list with no switch column named takes its first toggle, which is
       * what a list with one toggle wants. */
      if (list->switch_key[0] == '\0')
        {
          for (guint c = 0; c < list->item_fields->len; c++)
            {
              const LkPluginField *field = g_ptr_array_index (list->item_fields, c);

              if (field->kind == LK_PLUGIN_FIELD_TOGGLE)
                {
                  list->switch_key = field->key;
                  break;
                }
            }
        }

      g_ptr_array_add (state->lists, list);

      GPtrArray *rows = g_ptr_array_new_with_free_func (lk_row_free);
      const LkJson *row_nodes = lk_json_member (entry, "rows");
      guint rows_n = lk_json_length (row_nodes);

      for (guint r = 0; r < rows_n; r++)
        {
          const LkJson *row_node = lk_json_at (row_nodes, r);
          const char *row_id = lk_json_member_string (row_node, "id");

          if (row_id == NULL)
            continue;

          LkRow *row = lk_row_new (row_id);

          for (guint c = 0; c < list->item_fields->len; c++)
            {
              const LkPluginField *field = g_ptr_array_index (list->item_fields, c);

              g_hash_table_insert (row->cells, g_strdup (field->key),
                                   lk_cell_read (row_node, field));
            }
          g_ptr_array_add (rows, row);
        }
      g_hash_table_insert (state->rows, g_strdup (key), rows);
    }
}

/* ---- loading and reloading ----------------------------------------------- */

/* What the manifest asked for, in the wording the consent sheet uses, and
 * whether the mariner has left it granted.
 *
 * A GRANT CAN NEVER EXCEED THE MANIFEST. This is the asked-for set with a
 * switch beside each entry, so revoking one is the only thing the mariner can
 * do here. The broker answers a revoked call -1 and the plugin keeps running.
 *
 * The file types ride along, because that is what an open dialog names in its
 * prompt when it offers to hand a file to a plugin. */
static void
lk_plugin_state_read_caps (LkPluginState *state, const LkJson *node)
{
  const LkJson *caps = lk_json_member (node, "capabilities");

  for (guint i = 0; i < lk_json_length (caps); i++)
    {
      const LkJson *entry = lk_json_at (caps, i);
      const char *name = lk_json_member_string (entry, "cap");

      if (name == NULL)
        continue;

      LkPluginCapability *cap = g_new0 (LkPluginCapability, 1);
      cap->cap = name;
      cap->sentence = lk_or_empty (lk_json_member_string (entry, "sentence"));
      cap->granted = lk_json_member_bool (entry, "granted", TRUE);

      /* net.http and net.ws carry the hosts they asked for. The mariner needs
       * to read WHERE a plugin talks to, not only that it talks. */
      const LkJson *hosts = lk_json_member (entry, "hosts");
      if (lk_json_length (hosts) > 0)
        {
          g_autoptr (GString) joined = g_string_new (NULL);

          for (guint h = 0; h < lk_json_length (hosts); h++)
            {
              if (joined->len > 0)
                g_string_append (joined, ", ");
              g_string_append (joined, lk_json_text (lk_json_at (hosts, h)));
            }
          cap->hosts = g_string_free (g_steal_pointer (&joined), FALSE);
        }

      g_ptr_array_add (state->caps, cap);
    }

  const LkJson *types = lk_json_member (node, "file_types");
  for (guint i = 0; i < lk_json_length (types); i++)
    {
      const char *type = lk_json_string (lk_json_at (types, i));

      if (type != NULL)
        g_ptr_array_add (state->types, (gpointer) type);
    }
}

static LkPluginState *
lk_plugin_state_read (const LkJson *node)
{
  const char *id = lk_json_member_string (node, "id");

  if (id == NULL)
    return NULL;

  LkPluginState *state = g_new0 (LkPluginState, 1);

  state->id = id;
  state->name = lk_json_member_string (node, "name");
  if (state->name == NULL)
    state->name = id;
  state->version = lk_or_empty (lk_json_member_string (node, "version"));
  state->origin = lk_json_member_string (node, "origin");
  if (state->origin == NULL)
    state->origin = "bundled";
  state->live = lk_json_member_bool (node, "live", FALSE);
  state->status = g_strdup (lk_or_empty (lk_json_member_string (node, "status")));
  state->status_tree = lk_json_parse (state->status);

  state->fields = g_ptr_array_new_with_free_func (g_free);
  state->lists = g_ptr_array_new_with_free_func (lk_plugin_list_free);
  state->groups = g_ptr_array_new_with_free_func (lk_plugin_group_free);
  state->caps = g_ptr_array_new_with_free_func (lk_plugin_capability_free);
  state->types = g_ptr_array_new ();
  state->values = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
  state->rows = g_hash_table_new_full (g_str_hash, g_str_equal, g_free,
                                       (GDestroyNotify) g_ptr_array_unref);

  lk_plugin_state_read_fields (state, node);
  lk_plugin_state_read_lists (state, node);
  lk_plugin_state_read_caps (state, node);
  return state;
}

/* Re-read the registry whole, after an install or anything else that changes
 * WHICH plugins are loaded. FALSE when the core did not answer, which leaves
 * the last good registry in place.
 *
 * AN UNREADABLE REGISTRY IS NOT AN EMPTY ONE. lookout_plugins_json answers NULL
 * with no chart open and in a build with no plugin host; a core holding no
 * plugins answers {"plugins":[]} instead. Reading the two the same way would
 * empty the whole settings window the moment one read came back short. */
static gboolean
lk_plugins_reload (LkPlugins *self)
{
  g_return_val_if_fail (self != NULL, FALSE);

  g_autofree char *json = lk_chart_controller_plugins_json (self->controller);
  LkJson *registry = json != NULL ? lk_json_parse (json) : NULL;
  const LkJson *entries = lk_json_member (registry, "plugins");

  if (registry == NULL || lk_json_kind (entries) != LK_JSON_ARRAY)
    {
      lk_json_free (registry);
      if (!self->registry_unread)
        {
          self->registry_unread = TRUE;
          g_message ("plugins: the core did not answer with a registry; "
                     "keeping the last one, %u plugin(s)", self->plugins->len);
        }
      return FALSE;
    }

  if (self->registry_unread)
    {
      self->registry_unread = FALSE;
      g_message ("plugins: the registry is readable again, %u plugin(s)",
                 lk_json_length (entries));
    }

  g_ptr_array_set_size (self->plugins, 0);
  g_hash_table_remove_all (self->by_id);
  g_clear_pointer (&self->registry, lk_json_free);
  self->registry = registry;

  guint n = lk_json_length (entries);
  for (guint i = 0; i < n; i++)
    {
      LkPluginState *state = lk_plugin_state_read (lk_json_at (entries, i));

      if (state == NULL)
        continue;
      g_ptr_array_add (self->plugins, state);
      g_hash_table_insert (self->by_id, (gpointer) state->id, state);
    }
  return TRUE;
}

gboolean
lk_plugins_refresh_status (LkPlugins *self)
{
  g_return_val_if_fail (self != NULL, FALSE);

  g_autofree char *json = lk_chart_controller_plugins_json (self->controller);
  g_autoptr (LkJson) fresh = json != NULL ? lk_json_parse (json) : NULL;
  const LkJson *entries = lk_json_member (fresh, "plugins");

  if (lk_json_kind (entries) != LK_JSON_ARRAY)
    return FALSE;

  gboolean moved = FALSE;
  guint n = lk_json_length (entries);

  for (guint i = 0; i < n; i++)
    {
      const LkJson *entry = lk_json_at (entries, i);
      const char *id = lk_json_member_string (entry, "id");
      LkPluginState *state = lk_plugins_find (self, id);

      if (state == NULL)
        continue;

      const char *status = lk_or_empty (lk_json_member_string (entry, "status"));
      gboolean live = lk_json_member_bool (entry, "live", FALSE);

      if (live == state->live && g_strcmp0 (status, state->status) == 0)
        continue;

      state->live = live;
      g_free (state->status);
      state->status = g_strdup (status);
      lk_json_free (state->status_tree);
      state->status_tree = lk_json_parse (state->status);
      moved = TRUE;
    }
  return moved;
}

LkPlugins *
lk_plugins_new (LkChartController *controller)
{
  LkPlugins *self = g_new0 (LkPlugins, 1);

  self->controller = controller;
  self->plugins = g_ptr_array_new_with_free_func (lk_plugin_state_free);
  self->by_id = g_hash_table_new (g_str_hash, g_str_equal);
  lk_plugins_reload (self);
  return self;
}

static gboolean lk_plugins_apply (gpointer user_data);

void
lk_plugins_free (LkPlugins *self)
{
  if (self == NULL)
    return;

  /* A pending apply is the mariner's last edit. Flush it before the free, so
   * the change survives the pane closing inside the debounce window; firing it
   * after the free would be the one way this model outlives itself. */
  if (self->apply_id != 0)
    {
      g_clear_handle_id (&self->apply_id, g_source_remove);
      lk_plugins_apply (self);
    }
  g_ptr_array_unref (self->plugins);
  g_hash_table_unref (self->by_id);
  g_clear_pointer (&self->registry, lk_json_free);
  g_free (self);
}

/* ---- writing the config object ------------------------------------------- */

/* A number with no trailing ".0": the core takes either, and a settings line in
 * a log reads better without it. */
static void
lk_append_number (GString *out, double value)
{
  char buffer[G_ASCII_DTOSTR_BUF_SIZE];

  if (value == floor (value) && fabs (value) < 1e15)
    g_string_append_printf (out, "%.0f", value);
  else
    g_string_append (out, g_ascii_dtostr (buffer, sizeof buffer, value));
}

/* A quoted, escaped JSON string. A host name is whatever was typed. */
static void
lk_append_string (GString *out, const char *text)
{
  g_string_append_c (out, '"');
  for (const char *p = text != NULL ? text : ""; *p != '\0'; p++)
    {
      switch (*p)
        {
        case '"':  g_string_append (out, "\\\""); break;
        case '\\': g_string_append (out, "\\\\"); break;
        case '\n': g_string_append (out, "\\n"); break;
        case '\r': g_string_append (out, "\\r"); break;
        case '\t': g_string_append (out, "\\t"); break;
        default:
          if ((guchar) *p < 0x20)
            g_string_append_printf (out, "\\u%04x", (guchar) *p);
          else
            g_string_append_c (out, *p);
          break;
        }
    }
  g_string_append_c (out, '"');
}

static void
lk_append_cell (GString *out, const LkCell *cell)
{
  if (cell == NULL)
    {
      g_string_append (out, "null");
      return;
    }

  switch (cell->kind)
    {
    case LK_PLUGIN_FIELD_TOGGLE:
      g_string_append (out, cell->toggle ? "true" : "false");
      break;
    case LK_PLUGIN_FIELD_TEXT:
      lk_append_string (out, cell->text);
      break;
    case LK_PLUGIN_FIELD_NUMBER:
    default:
      lk_append_number (out, cell->number);
      break;
    }
}

/* `{"cpa_limit":926,"cpa_alarm":true,"connections":[…]}` — the object the core
 * takes: a toggle as a JSON bool, which is the only shape it accepts for one,
 * and a list as its whole array of rows, each carrying the id the shell
 * assigned it. */
static char *
lk_plugin_state_config_json (LkPluginState *state)
{
  GString *out = g_string_new ("{");
  gboolean first = TRUE;

  for (guint i = 0; i < state->fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (state->fields, i);
      const double *value = g_hash_table_lookup (state->values, field->key);

      if (!first)
        g_string_append_c (out, ',');
      first = FALSE;

      lk_append_string (out, field->key);
      g_string_append_c (out, ':');
      if (field->kind == LK_PLUGIN_FIELD_TOGGLE)
        g_string_append (out, (value != NULL && *value != 0) ? "true" : "false");
      else
        lk_append_number (out, value != NULL ? *value : field->fallback);
    }

  for (guint i = 0; i < state->lists->len; i++)
    {
      const LkPluginList *list = g_ptr_array_index (state->lists, i);
      GPtrArray *rows = g_hash_table_lookup (state->rows, list->key);

      if (!first)
        g_string_append_c (out, ',');
      first = FALSE;

      lk_append_string (out, list->key);
      g_string_append (out, ":[");
      for (guint r = 0; rows != NULL && r < rows->len; r++)
        {
          const LkRow *row = g_ptr_array_index (rows, r);

          if (r > 0)
            g_string_append_c (out, ',');
          g_string_append (out, "{\"id\":");
          lk_append_string (out, row->id);
          for (guint c = 0; c < list->item_fields->len; c++)
            {
              const LkPluginField *field = g_ptr_array_index (list->item_fields, c);

              g_string_append_c (out, ',');
              lk_append_string (out, field->key);
              g_string_append_c (out, ':');
              lk_append_cell (out, g_hash_table_lookup (row->cells, field->key));
            }
          g_string_append_c (out, '}');
        }
      g_string_append_c (out, ']');
    }

  g_string_append_c (out, '}');
  return g_string_free (out, FALSE);
}

/* ---- applying and saving -------------------------------------------------- */

static gboolean
lk_plugins_apply (gpointer user_data)
{
  LkPlugins *self = user_data;

  self->apply_id = 0;
  for (guint i = 0; i < self->plugins->len; i++)
    {
      LkPluginState *state = g_ptr_array_index (self->plugins, i);

      if (state->fields->len == 0 && state->lists->len == 0)
        continue;

      g_autofree char *json = lk_plugin_state_config_json (state);

      if (g_strcmp0 (json, state->last_json) == 0)
        continue;
      g_free (state->last_json);
      state->last_json = g_strdup (json);
      lk_chart_controller_set_plugin_config (self->controller, state->id, json);
      lk_store_save_plugin_config (state->id, json);
    }
  return G_SOURCE_REMOVE;
}

/* An edit happened. Debounced so a spin-button drag pushes once. */
static void
lk_plugins_edited (LkPlugins *self)
{
  if (self->apply_id != 0)
    g_source_remove (self->apply_id);
  self->apply_id = g_timeout_add (LK_PLUGIN_APPLY_MS, lk_plugins_apply, self);
}

void
lk_plugins_apply_saved (LkChartController *controller)
{
  /* LOOKOUT_CLEAN: a demonstration launch. The mariner's saved plugin state
   * stays on disk and stays out of the frame — no connection is dialed, no
   * private host or vessel name lands in a recording. */
  if (g_getenv ("LOOKOUT_CLEAN") != NULL)
    return;

  g_auto (GStrv) ids = lk_store_load_plugin_ids ();

  for (guint i = 0; ids != NULL && ids[i] != NULL; i++)
    {
      g_autofree char *json = lk_store_load_plugin_config (ids[i]);

      if (json != NULL)
        lk_chart_controller_set_plugin_config (controller, ids[i], json);
    }
}

/* ---- what each settings section holds ------------------------------------ */

GPtrArray *
lk_plugins_groups (LkPlugins *self, const char *tab)
{
  GPtrArray *out = g_ptr_array_new ();

  g_return_val_if_fail (self != NULL, out);

  for (guint i = 0; i < self->plugins->len; i++)
    {
      LkPluginState *state = g_ptr_array_index (self->plugins, i);

      for (guint g = 0; g < state->groups->len; g++)
        {
          LkPluginGroup *group = g_ptr_array_index (state->groups, g);

          if (g_strcmp0 (group->tab, tab) == 0)
            g_ptr_array_add (out, group);
        }
    }
  return out;
}

GPtrArray *
lk_plugins_lists (LkPlugins *self, const char *tab)
{
  GPtrArray *out = g_ptr_array_new ();

  g_return_val_if_fail (self != NULL, out);

  for (guint i = 0; i < self->plugins->len; i++)
    {
      LkPluginState *state = g_ptr_array_index (self->plugins, i);

      for (guint l = 0; l < state->lists->len; l++)
        {
          LkPluginList *list = g_ptr_array_index (state->lists, l);

          if (g_strcmp0 (list->tab, tab) == 0)
            g_ptr_array_add (out, list);
        }
    }
  return out;
}

gboolean
lk_plugins_tab_populated (LkPlugins *self, const char *tab)
{
  g_autoptr (GPtrArray) groups = lk_plugins_groups (self, tab);
  g_autoptr (GPtrArray) lists = lk_plugins_lists (self, tab);

  return groups->len > 0 || lists->len > 0;
}

/* ---- one control --------------------------------------------------------- */

static const LkPluginField *
lk_plugins_field (LkPluginState *state, const char *key)
{
  for (guint i = 0; state != NULL && i < state->fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (state->fields, i);

      if (g_strcmp0 (field->key, key) == 0)
        return field;
    }
  return NULL;
}

double
lk_plugins_value (LkPlugins *self, const char *plugin_id, const char *key)
{
  LkPluginState *state = lk_plugins_find (self, plugin_id);
  const double *value = state != NULL ? g_hash_table_lookup (state->values, key) : NULL;

  return value != NULL ? *value : 0;
}

void
lk_plugins_set_value (LkPlugins *self, const char *plugin_id, const char *key, double value)
{
  LkPluginState *state = lk_plugins_find (self, plugin_id);
  const LkPluginField *field = lk_plugins_field (state, key);

  if (field == NULL)
    return;

  /* The core clamps too. Doing it here as well keeps the control and the value
   * it shows in step without a round trip. */
  double clamped = field->kind == LK_PLUGIN_FIELD_TOGGLE
                       ? (value != 0 ? 1 : 0)
                       : CLAMP (value, field->min, field->max);

  const double *held = g_hash_table_lookup (state->values, key);
  if (held != NULL && *held == clamped)
    return;

  lk_plugins_set_double (state->values, key, clamped);
  lk_plugins_edited (self);
}

void
lk_plugins_reset_group (LkPlugins *self, const LkPluginGroup *group)
{
  LkPluginState *state = lk_plugins_find (self, group != NULL ? group->plugin_id : NULL);

  if (state == NULL)
    return;

  for (guint i = 0; i < group->fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (group->fields, i);

      lk_plugins_set_double (state->values, field->key, field->fallback);
    }
  lk_plugins_edited (self);
}

gboolean
lk_plugins_group_changed (LkPlugins *self, const LkPluginGroup *group)
{
  if (group == NULL)
    return FALSE;

  for (guint i = 0; i < group->fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (group->fields, i);

      if (lk_plugins_value (self, group->plugin_id, field->key) != field->fallback)
        return TRUE;
    }
  return FALSE;
}

/* ---- the rows of a list -------------------------------------------------- */

static GPtrArray *
lk_plugins_row_array (LkPlugins *self, const LkPluginList *list)
{
  LkPluginState *state = lk_plugins_find (self, list != NULL ? list->plugin_id : NULL);

  return state != NULL ? g_hash_table_lookup (state->rows, list->key) : NULL;
}

static LkRow *
lk_plugins_row (LkPlugins *self, const LkPluginList *list, const char *row_id)
{
  GPtrArray *rows = lk_plugins_row_array (self, list);

  for (guint i = 0; rows != NULL && i < rows->len; i++)
    {
      LkRow *row = g_ptr_array_index (rows, i);

      if (g_strcmp0 (row->id, row_id) == 0)
        return row;
    }
  return NULL;
}

GPtrArray *
lk_plugins_rows (LkPlugins *self, const LkPluginList *list)
{
  GPtrArray *out = g_ptr_array_new ();
  GPtrArray *rows = lk_plugins_row_array (self, list);

  for (guint i = 0; rows != NULL && i < rows->len; i++)
    {
      LkRow *row = g_ptr_array_index (rows, i);

      g_ptr_array_add (out, row->id);
    }
  return out;
}

gboolean
lk_plugins_list_is_full (LkPlugins *self, const LkPluginList *list)
{
  GPtrArray *rows = lk_plugins_row_array (self, list);

  if (list == NULL || list->max_rows <= 0)
    return FALSE;
  return rows != NULL && (int) rows->len >= list->max_rows;
}

void
lk_plugins_add_row (LkPlugins *self, const LkPluginList *list)
{
  GPtrArray *rows = lk_plugins_row_array (self, list);

  if (rows == NULL || lk_plugins_list_is_full (self, list))
    return;

  /* The id is minted here and never changes again: it is what the plugin's
   * status items point at, and what makes "Connected · 44 msg/s" land on this
   * line and no other. */
  g_autofree char *uuid = g_uuid_string_random ();
  g_autofree char *id = g_strdup_printf ("row-%.8s", uuid);
  LkRow *row = lk_row_new (id);

  for (guint i = 0; i < list->item_fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (list->item_fields, i);

      g_hash_table_insert (row->cells, g_strdup (field->key), lk_cell_read (NULL, field));
    }
  g_ptr_array_add (rows, row);
  lk_plugins_edited (self);
}

void
lk_plugins_add_row_from (LkPlugins          *self,
                         const LkPluginList *list,
                         const char         *service,
                         const char         *name,
                         const char         *host,
                         int                 port)
{
  GPtrArray *rows = lk_plugins_row_array (self, list);

  if (rows == NULL || lk_plugins_list_is_full (self, list))
    return;

  const LkJson *set = NULL;

  for (guint i = 0; i < list->discover->len; i++)
    {
      const LkPluginDiscover *want = g_ptr_array_index (list->discover, i);

      if (g_strcmp0 (want->service, service) == 0)
        {
          set = want->set;
          break;
        }
    }

  g_autofree char *uuid = g_uuid_string_random ();
  g_autofree char *id = g_strdup_printf ("row-%.8s", uuid);
  LkRow *row = lk_row_new (id);

  /* The service type's columns read exactly like a row out of the registry:
   * anything it does not name falls back to the column's own default. */
  for (guint i = 0; i < list->item_fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (list->item_fields, i);

      g_hash_table_insert (row->cells, g_strdup (field->key), lk_cell_read (set, field));
    }
  g_ptr_array_add (rows, row);

  lk_plugins_set_row_text (self, list, id, "name", name);
  lk_plugins_set_row_text (self, list, id, "host", host);
  lk_plugins_set_row_number (self, list, id, "port", port);
  lk_plugins_edited (self);
}

void
lk_plugins_remove_row (LkPlugins *self, const LkPluginList *list, const char *row_id)
{
  GPtrArray *rows = lk_plugins_row_array (self, list);

  for (guint i = 0; rows != NULL && i < rows->len; i++)
    {
      const LkRow *row = g_ptr_array_index (rows, i);

      if (g_strcmp0 (row->id, row_id) == 0)
        {
          g_ptr_array_remove_index (rows, i);
          lk_plugins_edited (self);
          return;
        }
    }
}

static LkCell *
lk_plugins_cell (LkPlugins *self, const LkPluginList *list,
                 const char *row_id, const char *key)
{
  LkRow *row = lk_plugins_row (self, list, row_id);

  return row != NULL ? g_hash_table_lookup (row->cells, key) : NULL;
}

const char *
lk_plugins_row_text (LkPlugins *self, const LkPluginList *list,
                     const char *row_id, const char *key)
{
  const LkCell *cell = lk_plugins_cell (self, list, row_id, key);

  return cell != NULL && cell->text != NULL ? cell->text : lk_empty;
}

double
lk_plugins_row_number (LkPlugins *self, const LkPluginList *list,
                       const char *row_id, const char *key)
{
  const LkCell *cell = lk_plugins_cell (self, list, row_id, key);

  return cell != NULL ? cell->number : 0;
}

gboolean
lk_plugins_row_toggle (LkPlugins *self, const LkPluginList *list,
                       const char *row_id, const char *key)
{
  const LkCell *cell = lk_plugins_cell (self, list, row_id, key);

  return cell != NULL && cell->toggle;
}

void
lk_plugins_set_row_text (LkPlugins *self, const LkPluginList *list,
                         const char *row_id, const char *key, const char *text)
{
  LkCell *cell = lk_plugins_cell (self, list, row_id, key);

  if (cell == NULL || g_strcmp0 (cell->text, text) == 0)
    return;
  g_free (cell->text);
  cell->text = g_strdup (text != NULL ? text : "");
  lk_plugins_edited (self);
}

void
lk_plugins_set_row_number (LkPlugins *self, const LkPluginList *list,
                           const char *row_id, const char *key, double value)
{
  LkCell *cell = lk_plugins_cell (self, list, row_id, key);

  if (cell == NULL)
    return;

  double clamped = value;
  for (guint i = 0; i < list->item_fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (list->item_fields, i);

      if (g_strcmp0 (field->key, key) == 0)
        {
          clamped = CLAMP (value, field->min, field->max);
          break;
        }
    }

  if (cell->number == clamped)
    return;
  cell->number = clamped;
  lk_plugins_edited (self);
}

void
lk_plugins_set_row_toggle (LkPlugins *self, const LkPluginList *list,
                           const char *row_id, const char *key, gboolean on)
{
  LkCell *cell = lk_plugins_cell (self, list, row_id, key);

  if (cell == NULL || cell->toggle == on)
    return;
  cell->toggle = on;
  lk_plugins_edited (self);
}

/* ---- what the plugin says about itself ----------------------------------- */

/* Green while it works, amber while it is trying, red when it has given up,
 * grey while it is switched off. The same palette the plugin lines use. */
static const char *
lk_plugins_state_class (const char *state)
{
  if (g_strcmp0 (state, "connected") == 0 || g_strcmp0 (state, "running") == 0)
    return "success";
  if (g_strcmp0 (state, "reconnecting") == 0 || g_strcmp0 (state, "degraded") == 0)
    return "warning";
  if (g_strcmp0 (state, "paused") == 0 || g_strcmp0 (state, "stopped") == 0 ||
      g_strcmp0 (state, "starting") == 0 || g_strcmp0 (state, "disabled") == 0)
    return "dim-label";
  return "error";
}

/* The core's state words, in the mariner's language. A state this shell does
 * not know is shown as the core wrote it rather than hidden. */
static const char *
lk_plugins_state_word (const char *state)
{
  static const struct { const char *state, *word; } words[] = {
    { "running", "Running" },     { "starting", "Starting" },
    { "degraded", "Degraded" },   { "disabled", "Disabled" },
    { "stopped", "Stopped" },     { "connected", "Connected" },
    { "paused", "Paused" },       { "reconnecting", "Reconnecting" },
    { "unreachable", "Unreachable" }, { "no_address", "No address" },
  };

  for (gsize i = 0; i < G_N_ELEMENTS (words); i++)
    {
      if (g_strcmp0 (state, words[i].state) == 0)
        return words[i].word;
    }
  return state;
}

/* "Connected · 44 msg/s" out of a {"state":…,"detail":…} object. */
static char *
lk_plugins_line (const LkJson *node, const char *fallback_state, const char **out_css_class)
{
  const char *state = lk_json_member_string (node, "state");
  const char *detail = lk_json_member_string (node, "detail");

  if (state == NULL)
    state = fallback_state;
  if (out_css_class != NULL)
    *out_css_class = lk_plugins_state_class (state);

  const char *word = lk_plugins_state_word (state);
  return detail != NULL ? g_strdup_printf ("%s · %s", word, detail) : g_strdup (word);
}

char *
lk_plugins_row_status (LkPlugins  *self,
                       const LkPluginList *list,
                       const char *row_id,
                       const char **out_css_class)
{
  LkPluginState *state = lk_plugins_find (self, list != NULL ? list->plugin_id : NULL);

  if (state == NULL)
    return NULL;

  const LkJson *items = lk_json_member (state->status_tree, "items");
  guint n = lk_json_length (items);

  for (guint i = 0; i < n; i++)
    {
      const LkJson *item = lk_json_at (items, i);

      if (g_strcmp0 (lk_json_member_string (item, "id"), row_id) == 0)
        return lk_plugins_line (item, "running", out_css_class);
    }
  return NULL;
}

GPtrArray *
lk_plugins_all (LkPlugins *self)
{
  GPtrArray *out = g_ptr_array_new ();

  g_return_val_if_fail (self != NULL, out);

  for (guint i = 0; i < self->plugins->len; i++)
    {
      const LkPluginState *state = g_ptr_array_index (self->plugins, i);

      g_ptr_array_add (out, (gpointer) state->id);
    }
  return out;
}

const char *
lk_plugins_name (LkPlugins *self, const char *plugin_id)
{
  const LkPluginState *state = lk_plugins_find (self, plugin_id);

  return state != NULL ? state->name : lk_empty;
}

const char *
lk_plugins_version (LkPlugins *self, const char *plugin_id)
{
  const LkPluginState *state = lk_plugins_find (self, plugin_id);

  return state != NULL ? state->version : lk_empty;
}

const char *
lk_plugins_origin (LkPlugins *self, const char *plugin_id)
{
  const LkPluginState *state = lk_plugins_find (self, plugin_id);

  return state != NULL ? state->origin : lk_empty;
}

char *
lk_plugins_status_line (LkPlugins *self, const char *plugin_id, const char **out_css_class)
{
  LkPluginState *state = lk_plugins_find (self, plugin_id);

  if (state == NULL)
    return NULL;

  /* A dead plugin says so whatever its last words were. */
  if (!state->live)
    {
      if (out_css_class != NULL)
        *out_css_class = "dim-label";
      return g_strdup ("Stopped");
    }
  return lk_plugins_line (state->status_tree, "running", out_css_class);
}

GPtrArray *
lk_plugins_capabilities (LkPlugins *self, const char *plugin_id)
{
  LkPluginState *state = lk_plugins_find (self, plugin_id);

  return state == NULL ? NULL : state->caps;
}

gboolean
lk_plugins_set_granted (LkPlugins  *self,
                        const char *plugin_id,
                        const char *cap,
                        gboolean    granted)
{
  g_return_val_if_fail (self != NULL, FALSE);

  if (!lk_chart_controller_plugin_grant_set (self->controller, plugin_id, cap, granted))
    return FALSE;

  /* The core persists the grant beside the plugin's wasm and reads it back at
   * every load, so nothing is saved here. The cached entry is moved so the
   * switch and the model agree without a whole reload. */
  GPtrArray *caps = lk_plugins_capabilities (self, plugin_id);
  for (guint i = 0; caps != NULL && i < caps->len; i++)
    {
      LkPluginCapability *entry = g_ptr_array_index (caps, i);

      if (g_strcmp0 (entry->cap, cap) == 0)
        entry->granted = granted;
    }
  return TRUE;
}

gboolean
lk_plugins_is_installed (LkPlugins *self, const char *plugin_id)
{
  LkPluginState *state = lk_plugins_find (self, plugin_id);

  return state != NULL && g_strcmp0 (state->origin, "installed") == 0;
}

char *
lk_plugins_file_types (LkPlugins *self)
{
  g_return_val_if_fail (self != NULL, NULL);

  g_autoptr (GString) joined = g_string_new (NULL);

  for (guint i = 0; i < self->plugins->len; i++)
    {
      LkPluginState *state = g_ptr_array_index (self->plugins, i);

      /* A plugin that is not running claims nothing: offering its types would
       * promise a handover that cannot happen. */
      if (!state->live)
        continue;

      for (guint t = 0; t < state->types->len; t++)
        {
          if (joined->len > 0)
            g_string_append (joined, ", ");
          g_string_append (joined, g_ptr_array_index (state->types, t));
        }
    }

  if (joined->len == 0)
    return NULL;
  return g_string_free (g_steal_pointer (&joined), FALSE);
}

char *
lk_plugins_file_types_for (LkPlugins *self, const char *plugin_id)
{
  LkPluginState *state = lk_plugins_find (self, plugin_id);

  if (state == NULL || state->types->len == 0)
    return NULL;

  g_autoptr (GString) joined = g_string_new (NULL);
  for (guint t = 0; t < state->types->len; t++)
    {
      if (joined->len > 0)
        g_string_append (joined, ", ");
      g_string_append (joined, g_ptr_array_index (state->types, t));
    }
  return g_string_free (g_steal_pointer (&joined), FALSE);
}
