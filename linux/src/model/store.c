#include "model/store.h"

#include <string.h>

#define LK_MAX_RECENTS 10

/* Whether a library has ever been saved. The core's list setter clears a key
 * given an empty list, so an emptied library and one that was never saved read
 * the same without this. It goes when lookout_chart_sets owns the list. */
#define LK_KEY_SETS_SAVED "saved"

static lookout_store *lk_store;

static char *
lk_store_dir (void)
{
  return g_build_filename (g_get_user_config_dir (), "lookout-marine", NULL);
}

static void lk_store_import_ini (const char *dir);

lookout_store *
lk_store_handle (void)
{
  if (lk_store == NULL)
    {
      g_autofree char *dir = lk_store_dir ();

      lk_store = lookout_store_open (dir);
      if (lk_store == NULL)
        g_error ("the settings store could not be opened");
      lk_store_import_ini (dir);
    }
  return lk_store;
}

void
lk_store_shutdown (void)
{
  if (lk_store != NULL)
    lookout_store_close (lk_store);
  lk_store = NULL;
}

/* ---- the one-time read of settings.ini ----------------------------------- */

/* Builds before the core owned the file wrote a GKeyFile at settings.ini, in
 * these same groups and under these same key names. It is read once, into the
 * store, and left on disk: a mariner who moves back to such a build finds their
 * settings where that build left them.
 *
 * `view/imported` marks it done. The engine writes the rest of that group, and
 * the apple shell stamps its own one-time copy the same way. */
static void
lk_import_list (GKeyFile *ini, const char *group, const char *key)
{
  g_auto (GStrv) list = g_key_file_get_string_list (ini, group, key, NULL, NULL);

  if (list == NULL)
    return;
  lookout_store_set_list (lk_store, group, key, (const char *const *) list,
                          g_strv_length (list));
}

static void
lk_import_text (GKeyFile *ini, const char *group, const char *key)
{
  g_autofree char *value = g_key_file_get_string (ini, group, key, NULL);

  if (value != NULL && value[0] != '\0')
    lookout_store_set_text (lk_store, group, key, value);
}

static void
lk_import_number (GKeyFile *ini, const char *group, const char *key)
{
  g_autoptr (GError) error = NULL;
  double value = g_key_file_get_double (ini, group, key, &error);

  if (error == NULL)
    lookout_store_set_number (lk_store, group, key, value);
}

static void
lk_import_flag (GKeyFile *ini, const char *group, const char *key)
{
  g_autoptr (GError) error = NULL;
  gboolean value = g_key_file_get_boolean (ini, group, key, &error);

  if (error == NULL)
    lookout_store_set_flag (lk_store, group, key, value);
}

/* Every key of a group, as text. This is how the plugin configs cross: one
 * config object per plugin id, under whatever ids that build had saved. */
static void
lk_import_group_text (GKeyFile *ini, const char *group)
{
  g_auto (GStrv) keys = g_key_file_get_keys (ini, group, NULL, NULL);

  for (guint i = 0; keys != NULL && keys[i] != NULL; i++)
    lk_import_text (ini, group, keys[i]);
}

static void
lk_store_import_ini (const char *dir)
{
  if (lookout_store_flag (lk_store, LOOKOUT_STORE_VIEW, "imported", 0))
    return;

  g_autofree char *path = g_build_filename (dir, "settings.ini", NULL);
  g_autoptr (GKeyFile) ini = g_key_file_new ();
  g_autoptr (GError) error = NULL;

  if (!g_key_file_load_from_file (ini, path, G_KEY_FILE_NONE, &error))
    {
      /* No ini is the ordinary case: a new install, or one that has already
       * been read. One that will not parse says so and is left alone. */
      if (!g_error_matches (error, G_FILE_ERROR, G_FILE_ERROR_NOENT))
        g_warning ("settings.ini would not parse (%s); starting fresh", error->message);
      lookout_store_set_flag (lk_store, LOOKOUT_STORE_VIEW, "imported", 1);
      return;
    }

  static const char *const view_keys[] = { "lon", "lat", "zoom", "rotation_deg" };
  for (gsize i = 0; i < G_N_ELEMENTS (view_keys); i++)
    lk_import_number (ini, LOOKOUT_STORE_VIEW, view_keys[i]);

  lk_import_list (ini, LOOKOUT_STORE_RECENTS, "paths");

  static const char *const raster_lists[] = { "paths", "off", "hidden" };
  for (gsize i = 0; i < G_N_ELEMENTS (raster_lists); i++)
    lk_import_list (ini, LOOKOUT_STORE_RASTER, raster_lists[i]);
  lk_import_flag (ini, LOOKOUT_STORE_RASTER, "chart_hidden");

  if (g_key_file_has_key (ini, LOOKOUT_STORE_CHARTSETS, "paths", NULL))
    {
      lk_import_list (ini, LOOKOUT_STORE_CHARTSETS, "paths");
      lookout_store_set_flag (lk_store, LOOKOUT_STORE_CHARTSETS, LK_KEY_SETS_SAVED, 1);
    }
  lk_import_list (ini, LOOKOUT_STORE_CHARTSETS, "off");

  lk_import_text (ini, LOOKOUT_STORE_CHARTLINKS, "links");
  lk_import_text (ini, LOOKOUT_STORE_CHARTLINKS, "active");

  /* The mariner settings and the plugin configs cross as they were written:
   * the engine reads the first group back field by field, and a plugin config
   * is one object per id whatever keys that build had in it. */
  static const char *const mariner_flags[] = {
    "four_shade_water", "display_base", "display_standard", "display_other",
    "text_names", "show_light_descriptions", "text_other", "simplified_points",
    "show_full_sector_lines", "data_quality", "show_isolated_dangers_shallow",
    "show_inform_callouts", "show_meta_bounds", "show_overscale",
    "date_dependent", "highlight_date_dependent",
  };
  static const char *const mariner_numbers[] = {
    "scheme", "depth_unit", "shallow_contour", "safety_contour", "deep_contour",
    "safety_depth", "soundings", "boundary_style", "size_scale",
    "text_size_scale", "sounding_size_scale",
  };
  for (gsize i = 0; i < G_N_ELEMENTS (mariner_flags); i++)
    lk_import_flag (ini, LOOKOUT_STORE_MARINER, mariner_flags[i]);
  for (gsize i = 0; i < G_N_ELEMENTS (mariner_numbers); i++)
    lk_import_number (ini, LOOKOUT_STORE_MARINER, mariner_numbers[i]);
  lk_import_text (ini, LOOKOUT_STORE_MARINER, "date_view");

  lk_import_group_text (ini, LOOKOUT_STORE_PLUGINS);

  lookout_store_set_flag (lk_store, LOOKOUT_STORE_VIEW, "imported", 1);
  lookout_store_flush (lk_store);
  g_message ("read the settings from %s once; it is left where it is", path);
}

/* ---- lists and strings --------------------------------------------------- */

/* A borrowed list as a strv the caller owns. Never NULL. */
static char **
lk_store_load_list (const char *group, const char *key)
{
  size_t count = 0;
  const char *const *items = lookout_store_list (lk_store_handle (), group, key, &count);
  char **out = g_new0 (char *, count + 1);

  for (size_t i = 0; i < count; i++)
    out[i] = g_strdup (items[i]);
  return out;
}

static void
lk_store_save_list (const char *group, const char *key, const char *const *paths)
{
  gsize n = paths == NULL ? 0 : g_strv_length ((char **) paths);

  lookout_store_set_list (lk_store_handle (), group, key, paths, n);
}

/* A choice the mariner made by hand reaches the disk at once, which is what the
 * keyfile store did. The engine's own writes ride the coalesce window. */
static void
lk_store_wrote (void)
{
  lookout_store_flush (lk_store_handle ());
}

static char *
lk_store_load_string (const char *group, const char *key)
{
  const char *value = lookout_store_text (lk_store_handle (), group, key);

  return value != NULL && value[0] != '\0' ? g_strdup (value) : NULL;
}

static void
lk_store_save_string (const char *group, const char *key, const char *value)
{
  if (value == NULL || value[0] == '\0')
    lookout_store_remove (lk_store_handle (), group, key);
  else
    lookout_store_set_text (lk_store_handle (), group, key, value);
}

/* ---- the camera pose ----------------------------------------------------- */

gboolean
lk_store_has_saved_view (void)
{
  return lookout_store_has (lk_store_handle (), LOOKOUT_STORE_VIEW, "lon");
}

/* ---- recents ------------------------------------------------------------ */

char **
lk_store_load_recents (void)
{
  return lk_store_load_list (LOOKOUT_STORE_RECENTS, "paths");
}

void
lk_store_note_recent (const char *path)
{
  g_return_if_fail (path != NULL);

  g_auto (GStrv) existing = lk_store_load_recents ();
  g_autoptr (GPtrArray) merged = g_ptr_array_new_with_free_func (g_free);

  g_ptr_array_add (merged, g_strdup (path));
  for (guint i = 0; existing[i] != NULL && merged->len < LK_MAX_RECENTS; i++)
    {
      if (g_strcmp0 (existing[i], path) != 0)
        g_ptr_array_add (merged, g_strdup (existing[i]));
    }

  lookout_store_set_list (lk_store_handle (), LOOKOUT_STORE_RECENTS, "paths",
                          (const char *const *) merged->pdata, merged->len);
  lk_store_wrote ();
}

/* ---- raster charts ------------------------------------------------------ */

char **
lk_store_load_raster_paths (void)
{
  return lk_store_load_list (LOOKOUT_STORE_RASTER, "paths");
}

void
lk_store_save_raster_paths (const char *const *paths)
{
  lk_store_save_list (LOOKOUT_STORE_RASTER, "paths", paths);
  lk_store_wrote ();
}

char **
lk_store_load_raster_off (void)
{
  return lk_store_load_list (LOOKOUT_STORE_RASTER, "off");
}

void
lk_store_save_raster_off (const char *const *paths)
{
  lk_store_save_list (LOOKOUT_STORE_RASTER, "off", paths);
  lk_store_wrote ();
}

char **
lk_store_load_raster_hidden (void)
{
  return lk_store_load_list (LOOKOUT_STORE_RASTER, "hidden");
}

void
lk_store_save_raster_hidden (const char *const *names)
{
  lk_store_save_list (LOOKOUT_STORE_RASTER, "hidden", names);
  lk_store_wrote ();
}

void
lk_store_save_raster_all (const char *const *paths,
                          const char *const *off,
                          const char *const *hidden)
{
  lk_store_save_list (LOOKOUT_STORE_RASTER, "paths", paths);
  lk_store_save_list (LOOKOUT_STORE_RASTER, "off", off);
  lk_store_save_list (LOOKOUT_STORE_RASTER, "hidden", hidden);
  lk_store_wrote ();
}

gboolean
lk_store_load_chart_hidden (void)
{
  return lookout_store_flag (lk_store_handle (), LOOKOUT_STORE_RASTER, "chart_hidden", 0) != 0;
}

void
lk_store_save_chart_hidden (gboolean hidden)
{
  lookout_store_set_flag (lk_store_handle (), LOOKOUT_STORE_RASTER, "chart_hidden", hidden);
  lk_store_wrote ();
}

/* ---- chart sets ---------------------------------------------------------- */

char **
lk_store_load_chart_sets (void)
{
  /* Absent and empty are different answers: absent means this build has never
   * saved a library here, and the caller seeds it from the recents once. */
  if (!lookout_store_flag (lk_store_handle (), LOOKOUT_STORE_CHARTSETS, LK_KEY_SETS_SAVED, 0))
    return NULL;
  return lk_store_load_list (LOOKOUT_STORE_CHARTSETS, "paths");
}

void
lk_store_save_chart_sets (const char *const *paths)
{
  /* Never back to "absent": an emptied library must stay empty rather than
   * re-seeding from the recents at the next launch. */
  lk_store_save_list (LOOKOUT_STORE_CHARTSETS, "paths", paths);
  lookout_store_set_flag (lk_store_handle (), LOOKOUT_STORE_CHARTSETS, LK_KEY_SETS_SAVED, 1);
  lk_store_wrote ();
}

char **
lk_store_load_chart_sets_off (void)
{
  return lk_store_load_list (LOOKOUT_STORE_CHARTSETS, "off");
}

void
lk_store_save_chart_sets_off (const char *const *paths)
{
  lk_store_save_list (LOOKOUT_STORE_CHARTSETS, "off", paths);
  lk_store_wrote ();
}

/* ---- chart links --------------------------------------------------------- */

char *
lk_store_load_chart_links (void)
{
  return lk_store_load_string (LOOKOUT_STORE_CHARTLINKS, "links");
}

void
lk_store_save_chart_links (const char *json)
{
  lk_store_save_string (LOOKOUT_STORE_CHARTLINKS, "links", json);
  lk_store_wrote ();
}

char *
lk_store_load_chart_link_active (void)
{
  return lk_store_load_string (LOOKOUT_STORE_CHARTLINKS, "active");
}

void
lk_store_save_chart_link_active (const char *url)
{
  lk_store_save_string (LOOKOUT_STORE_CHARTLINKS, "active", url);
  lk_store_wrote ();
}

/* ---- plugin settings ----------------------------------------------------- */

char **
lk_store_load_plugin_ids (void)
{
  size_t count = 0;
  const char *const *keys =
      lookout_store_keys (lk_store_handle (), LOOKOUT_STORE_PLUGINS, &count);
  char **out = g_new0 (char *, count + 1);

  for (size_t i = 0; i < count; i++)
    out[i] = g_strdup (keys[i]);
  return out;
}

char *
lk_store_load_plugin_config (const char *plugin_id)
{
  g_return_val_if_fail (plugin_id != NULL, NULL);
  return lk_store_load_string (LOOKOUT_STORE_PLUGINS, plugin_id);
}

void
lk_store_save_plugin_config (const char *plugin_id, const char *json)
{
  g_return_if_fail (plugin_id != NULL);
  lk_store_save_string (LOOKOUT_STORE_PLUGINS, plugin_id, json);
  lk_store_wrote ();
}
