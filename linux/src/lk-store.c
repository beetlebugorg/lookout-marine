#include "lk-store.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

#define LK_GROUP_VIEW    "view"
#define LK_GROUP_RECENTS "recents"
#define LK_GROUP_RASTER  "raster"
#define LK_GROUP_MARINER "mariner.v1"
#define LK_GROUP_PLUGINS "plugins.v1"
#define LK_GROUP_CHARTLINKS "chartlinks"
#define LK_GROUP_CHARTSETS "chartsets"

#define LK_MAX_RECENTS 10

static char *
lk_store_path (void)
{
  return g_build_filename (g_get_user_config_dir (), "lookout-marine", "settings.ini", NULL);
}

/* The whole file, or an empty keyfile when there isn't one yet. Never NULL.
 *
 * A file that EXISTS and will not parse is set aside as settings.ini.broken
 * before the empty keyfile takes its place. The next flush overwrites the
 * live file either way; the copy is what keeps a mariner's library and
 * settings recoverable after the damage, and the warning says where it is. */
static GKeyFile *
lk_store_load (void)
{
  GKeyFile *keyfile = g_key_file_new ();
  g_autofree char *path = lk_store_path ();
  g_autoptr (GError) error = NULL;

  if (!g_key_file_load_from_file (keyfile, path, G_KEY_FILE_KEEP_COMMENTS, &error) &&
      !g_error_matches (error, G_FILE_ERROR, G_FILE_ERROR_NOENT))
    {
      g_autofree char *broken = g_strconcat (path, ".broken", NULL);
      if (rename (path, broken) == 0)
        g_warning ("settings.ini would not parse (%s); set aside as %s",
                   error->message, broken);
      else
        g_warning ("settings.ini would not parse (%s) and could not be set aside: %s",
                   error->message, g_strerror (errno));
    }
  return keyfile;
}

static void
lk_store_flush (GKeyFile *keyfile)
{
  g_autofree char *path = lk_store_path ();
  g_autofree char *dir = g_path_get_dirname (path);
  g_autoptr (GError) error = NULL;

  if (g_mkdir_with_parents (dir, 0700) != 0)
    {
      g_warning ("couldn't create %s: %s", dir, g_strerror (errno));
      return;
    }

  if (!g_key_file_save_to_file (keyfile, path, &error))
    g_warning ("couldn't save %s: %s", path, error->message);
}

/* ---- camera pose -------------------------------------------------------- */

gboolean
lk_store_load_view (lookout_view *out)
{
  g_return_val_if_fail (out != NULL, FALSE);

  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  if (!g_key_file_has_key (keyfile, LK_GROUP_VIEW, "lon", NULL))
    return FALSE;

  out->lon = g_key_file_get_double (keyfile, LK_GROUP_VIEW, "lon", NULL);
  out->lat = g_key_file_get_double (keyfile, LK_GROUP_VIEW, "lat", NULL);
  out->zoom = g_key_file_get_double (keyfile, LK_GROUP_VIEW, "zoom", NULL);
  out->rotation_deg = g_key_file_get_double (keyfile, LK_GROUP_VIEW, "rotation_deg", NULL);
  return TRUE;
}

void
lk_store_save_view (const lookout_view *view)
{
  g_return_if_fail (view != NULL);

  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  g_key_file_set_double (keyfile, LK_GROUP_VIEW, "lon", view->lon);
  g_key_file_set_double (keyfile, LK_GROUP_VIEW, "lat", view->lat);
  g_key_file_set_double (keyfile, LK_GROUP_VIEW, "zoom", view->zoom);
  g_key_file_set_double (keyfile, LK_GROUP_VIEW, "rotation_deg", view->rotation_deg);
  lk_store_flush (keyfile);
}

/* ---- recents ------------------------------------------------------------ */

char **
lk_store_load_recents (void)
{
  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  char **recents = g_key_file_get_string_list (keyfile, LK_GROUP_RECENTS, "paths", NULL, NULL);

  return recents != NULL ? recents : g_new0 (char *, 1);
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

  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  g_key_file_set_string_list (keyfile, LK_GROUP_RECENTS, "paths",
                              (const char *const *) merged->pdata, merged->len);
  lk_store_flush (keyfile);
}

/* ---- raster charts ------------------------------------------------------ */

static char **
lk_store_load_group_list (const char *group, const char *key)
{
  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  char **list = g_key_file_get_string_list (keyfile, group, key, NULL, NULL);

  return list != NULL ? list : g_new0 (char *, 1);
}

static void
lk_store_save_group_list (const char *group, const char *key, const char *const *paths)
{
  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  gsize n = paths == NULL ? 0 : g_strv_length ((char **) paths);

  if (n == 0)
    g_key_file_remove_key (keyfile, group, key, NULL);
  else
    g_key_file_set_string_list (keyfile, group, key, paths, n);

  lk_store_flush (keyfile);
}

static char **
lk_store_load_list (const char *key)
{
  return lk_store_load_group_list (LK_GROUP_RASTER, key);
}

static void
lk_store_save_list (const char *key, const char *const *paths)
{
  lk_store_save_group_list (LK_GROUP_RASTER, key, paths);
}

char **
lk_store_load_raster_paths (void)
{
  return lk_store_load_list ("paths");
}

void
lk_store_save_raster_paths (const char *const *paths)
{
  lk_store_save_list ("paths", paths);
}

char **
lk_store_load_raster_off (void)
{
  return lk_store_load_list ("off");
}

void
lk_store_save_raster_off (const char *const *paths)
{
  lk_store_save_list ("off", paths);
}

char **
lk_store_load_raster_hidden (void)
{
  return lk_store_load_list ("hidden");
}

void
lk_store_save_raster_hidden (const char *const *names)
{
  lk_store_save_list ("hidden", names);
}

gboolean
lk_store_load_chart_hidden (void)
{
  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  g_autoptr (GError) error = NULL;
  gboolean hidden = g_key_file_get_boolean (keyfile, LK_GROUP_RASTER, "chart_hidden", &error);

  return error == NULL && hidden;
}

void
lk_store_save_chart_hidden (gboolean hidden)
{
  g_autoptr (GKeyFile) keyfile = lk_store_load ();

  g_key_file_set_boolean (keyfile, LK_GROUP_RASTER, "chart_hidden", hidden);
  lk_store_flush (keyfile);
}

/* ---- chart sets ---------------------------------------------------------- */

char **
lk_store_load_chart_sets (void)
{
  g_autoptr (GKeyFile) keyfile = lk_store_load ();

  /* Absent and empty are different answers: absent means this build has never
   * saved a library here, and the caller seeds it from the recents once. */
  if (!g_key_file_has_key (keyfile, LK_GROUP_CHARTSETS, "paths", NULL))
    return NULL;

  char **list = g_key_file_get_string_list (keyfile, LK_GROUP_CHARTSETS, "paths", NULL, NULL);
  return list != NULL ? list : g_new0 (char *, 1);
}

void
lk_store_save_chart_sets (const char *const *paths)
{
  /* Never back to "absent": an emptied library must stay empty rather than
   * re-seeding from the recents at the next launch. */
  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  gsize n = paths == NULL ? 0 : g_strv_length ((char **) paths);

  g_key_file_set_string_list (keyfile, LK_GROUP_CHARTSETS, "paths",
                              n == 0 ? (const char *const []) { NULL } : paths, n);
  lk_store_flush (keyfile);
}

char **
lk_store_load_chart_sets_off (void)
{
  return lk_store_load_group_list (LK_GROUP_CHARTSETS, "off");
}

void
lk_store_save_chart_sets_off (const char *const *paths)
{
  lk_store_save_group_list (LK_GROUP_CHARTSETS, "off", paths);
}

/* ---- chart links --------------------------------------------------------- */

static char *
lk_store_load_string (const char *group, const char *key)
{
  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  char *value = g_key_file_get_string (keyfile, group, key, NULL);

  if (value != NULL && value[0] == '\0')
    g_clear_pointer (&value, g_free);
  return value;
}

static void
lk_store_save_string (const char *group, const char *key, const char *value)
{
  g_autoptr (GKeyFile) keyfile = lk_store_load ();

  if (value == NULL || value[0] == '\0')
    g_key_file_remove_key (keyfile, group, key, NULL);
  else
    g_key_file_set_string (keyfile, group, key, value);
  lk_store_flush (keyfile);
}

char *
lk_store_load_chart_links (void)
{
  return lk_store_load_string (LK_GROUP_CHARTLINKS, "links");
}

void
lk_store_save_chart_links (const char *json)
{
  lk_store_save_string (LK_GROUP_CHARTLINKS, "links", json);
}

char *
lk_store_load_chart_link_active (void)
{
  return lk_store_load_string (LK_GROUP_CHARTLINKS, "active");
}

void
lk_store_save_chart_link_active (const char *url)
{
  lk_store_save_string (LK_GROUP_CHARTLINKS, "active", url);
}

/* ---- mariner ------------------------------------------------------------ */

void
lk_store_save_mariner (const tile57_mariner *m)
{
  g_return_if_fail (m != NULL);

  g_autoptr (GKeyFile) keyfile = lk_store_load ();

#define SET_INT(key, value)  g_key_file_set_integer (keyfile, LK_GROUP_MARINER, key, (int) (value))
#define SET_BOOL(key, value) g_key_file_set_boolean (keyfile, LK_GROUP_MARINER, key, (value))
#define SET_DBL(key, value)  g_key_file_set_double (keyfile, LK_GROUP_MARINER, key, (value))

  SET_INT ("scheme", m->scheme);
  SET_INT ("depth_unit", m->depth_unit);
  SET_DBL ("shallow_contour", m->shallow_contour);
  SET_DBL ("safety_contour", m->safety_contour);
  SET_DBL ("deep_contour", m->deep_contour);
  SET_DBL ("safety_depth", m->safety_depth);
  SET_BOOL ("four_shade_water", m->four_shade_water);
  SET_BOOL ("display_base", m->display_base);
  SET_BOOL ("display_standard", m->display_standard);
  SET_BOOL ("display_other", m->display_other);
  SET_INT ("soundings", m->soundings);
  SET_BOOL ("text_names", m->text_names);
  SET_BOOL ("show_light_descriptions", m->show_light_descriptions);
  SET_BOOL ("text_other", m->text_other);
  SET_BOOL ("simplified_points", m->simplified_points);
  SET_INT ("boundary_style", m->boundary_style);
  SET_BOOL ("show_full_sector_lines", m->show_full_sector_lines);
  SET_BOOL ("data_quality", m->data_quality);
  SET_BOOL ("show_isolated_dangers_shallow", m->show_isolated_dangers_shallow);
  SET_BOOL ("show_inform_callouts", m->show_inform_callouts);
  SET_BOOL ("show_meta_bounds", m->show_meta_bounds);
  SET_BOOL ("show_overscale", m->show_overscale);
  SET_DBL ("size_scale", m->size_scale);
  SET_DBL ("text_size_scale", m->text_size_scale);
  SET_DBL ("sounding_size_scale", m->sounding_size_scale);
  SET_BOOL ("date_dependent", m->date_dependent);
  SET_BOOL ("highlight_date_dependent", m->highlight_date_dependent);
  g_key_file_set_string (keyfile, LK_GROUP_MARINER, "date_view", m->date_view);

#undef SET_INT
#undef SET_BOOL
#undef SET_DBL

  lk_store_flush (keyfile);
}

void
lk_store_apply_saved_mariner (tile57_mariner *m)
{
  g_return_if_fail (m != NULL);

  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  if (!g_key_file_has_group (keyfile, LK_GROUP_MARINER))
    return;

  /* Apply each field only when the key is present, so older settings files
   * leave newer fields at engine defaults instead of zeroing them. */
  /* Every integer key is an enum, and the engine indexes tables by it: a
   * value outside the enum's range is damage and keeps the default. */
#define GET_ENUM(key, field, hi)                                                   \
  G_STMT_START {                                                                    \
    g_autoptr (GError) e = NULL;                                                    \
    int v = g_key_file_get_integer (keyfile, LK_GROUP_MARINER, key, &e);             \
    if (e == NULL && v >= 0 && v <= (hi))                                           \
      field = v;                                                                    \
  } G_STMT_END

#define GET_BOOL(key, field)                                                       \
  G_STMT_START {                                                                    \
    g_autoptr (GError) e = NULL;                                                    \
    gboolean v = g_key_file_get_boolean (keyfile, LK_GROUP_MARINER, key, &e);        \
    if (e == NULL)                                                                  \
      field = v;                                                                    \
  } G_STMT_END

#define GET_DBL(key, field)                                                        \
  G_STMT_START {                                                                    \
    g_autoptr (GError) e = NULL;                                                    \
    double v = g_key_file_get_double (keyfile, LK_GROUP_MARINER, key, &e);           \
    if (e == NULL)                                                                  \
      field = v;                                                                    \
  } G_STMT_END

  /* Positive-only: a stored 0 for a size scale would black out every symbol. */
#define GET_SCALE(key, field)                                                      \
  G_STMT_START {                                                                    \
    g_autoptr (GError) e = NULL;                                                    \
    double v = g_key_file_get_double (keyfile, LK_GROUP_MARINER, key, &e);           \
    if (e == NULL && v > 0)                                                         \
      field = v;                                                                    \
  } G_STMT_END

  GET_ENUM ("scheme", m->scheme, TILE57_SCHEME_NIGHT);
  GET_ENUM ("depth_unit", m->depth_unit, TILE57_DEPTH_FEET);
  GET_DBL ("shallow_contour", m->shallow_contour);
  GET_DBL ("safety_contour", m->safety_contour);
  GET_DBL ("deep_contour", m->deep_contour);
  GET_DBL ("safety_depth", m->safety_depth);
  GET_BOOL ("four_shade_water", m->four_shade_water);
  GET_BOOL ("display_base", m->display_base);
  GET_BOOL ("display_standard", m->display_standard);
  GET_BOOL ("display_other", m->display_other);
  GET_ENUM ("soundings", m->soundings, 2);
  GET_BOOL ("text_names", m->text_names);
  GET_BOOL ("show_light_descriptions", m->show_light_descriptions);
  GET_BOOL ("text_other", m->text_other);
  GET_BOOL ("simplified_points", m->simplified_points);
  GET_ENUM ("boundary_style", m->boundary_style, TILE57_BOUNDARY_PLAIN);
  GET_BOOL ("show_full_sector_lines", m->show_full_sector_lines);
  GET_BOOL ("data_quality", m->data_quality);
  GET_BOOL ("show_isolated_dangers_shallow", m->show_isolated_dangers_shallow);
  GET_BOOL ("show_inform_callouts", m->show_inform_callouts);
  GET_BOOL ("show_meta_bounds", m->show_meta_bounds);
  GET_BOOL ("show_overscale", m->show_overscale);
  GET_SCALE ("size_scale", m->size_scale);
  GET_SCALE ("text_size_scale", m->text_size_scale);
  GET_SCALE ("sounding_size_scale", m->sounding_size_scale);
  GET_BOOL ("date_dependent", m->date_dependent);
  GET_BOOL ("highlight_date_dependent", m->highlight_date_dependent);

#undef GET_ENUM
#undef GET_BOOL
#undef GET_DBL
#undef GET_SCALE

  g_autofree char *date = g_key_file_get_string (keyfile, LK_GROUP_MARINER, "date_view", NULL);
  if (date != NULL)
    {
      memset (m->date_view, 0, sizeof m->date_view);
      g_strlcpy (m->date_view, date, sizeof m->date_view);
    }
}

/* ---- plugin settings ----------------------------------------------------- */

char **
lk_store_load_plugin_ids (void)
{
  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  char **ids = g_key_file_get_keys (keyfile, LK_GROUP_PLUGINS, NULL, NULL);

  return ids != NULL ? ids : g_new0 (char *, 1);
}

char *
lk_store_load_plugin_config (const char *plugin_id)
{
  g_return_val_if_fail (plugin_id != NULL, NULL);

  g_autoptr (GKeyFile) keyfile = lk_store_load ();
  return g_key_file_get_string (keyfile, LK_GROUP_PLUGINS, plugin_id, NULL);
}

void
lk_store_save_plugin_config (const char *plugin_id, const char *json)
{
  g_return_if_fail (plugin_id != NULL);

  g_autoptr (GKeyFile) keyfile = lk_store_load ();

  if (json == NULL)
    g_key_file_remove_key (keyfile, LK_GROUP_PLUGINS, plugin_id, NULL);
  else
    g_key_file_set_string (keyfile, LK_GROUP_PLUGINS, plugin_id, json);
  lk_store_flush (keyfile);
}
