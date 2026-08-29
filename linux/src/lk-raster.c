#include "lk-raster.h"

#include "model/store.h"

#include <string.h>

struct _LkRasterCharts {
  GPtrArray  *paths;  /* char*, in the order added; NULL-terminated for callers */
  GHashTable *off;    /* the paths switched off, as a set */
  GHashTable *hidden; /* the SET NAMES not drawn, as a set */
};

/* ---- set names ---------------------------------------------------------- */

/* A producer this name carries, if any. Longest first, so "OpenSeaMap" is not
 * reported as "OSM". The list and the order are the engine's (providerIn in
 * raster.zig): both must answer with the same name for one file. */
static const char *LK_RASTER_PROVIDERS[] = {
  "OpenSeaMap", "Navionics", "Sentinel", "ArcGIS", "Google",
  "C-Map",      "Yandex",    "Imagery",  "Bing",   "ESRI",
  "Esri",       "CMap",      "NAIP",     "SASP",   "OSM",
};

static const char *
lk_raster_provider_in (const char *name)
{
  g_autofree char *lower = g_ascii_strdown (name, -1);

  for (gsize i = 0; i < G_N_ELEMENTS (LK_RASTER_PROVIDERS); i++)
    {
      g_autofree char *needle = g_ascii_strdown (LK_RASTER_PROVIDERS[i], -1);
      if (strstr (lower, needle) != NULL)
        return LK_RASTER_PROVIDERS[i];
    }
  return NULL;
}

/* Two shapes, because raster charts arrive two ways.
 *
 * A community MBTiles names its provider, and that is what a mariner chooses
 * between: the same water ships from ArcGIS, Bing, Google and Navionics side by
 * side, and one of them shows the bottom today.
 *
 * A baked RNC does not. `tile57 bake` writes <root>/<stem>/<stem>.pmtiles, one
 * directory per sheet, and a bundle holds hundreds. Naming each after its own
 * file would make hundreds of sets of one sheet, which is not a choice a
 * mariner can make. They belong to the bake they came from. */
char *
lk_raster_set_name_for (const char *path)
{
  g_return_val_if_fail (path != NULL, g_strdup (""));

  g_autofree char *base = g_path_get_basename (path);
  const char *provider = lk_raster_provider_in (base);
  if (provider != NULL)
    return g_strdup (provider);

  const char *dot = strrchr (base, '.');
  g_autofree char *stem = dot != NULL ? g_strndup (base, dot - base) : g_strdup (base);

  /* The bake's layout: the file sits alone in a directory named for itself, and
   * the directory above is the bake. Group by the bake, and read the producer
   * out of ITS name — a baked sheet gives nothing usable of its own, while the
   * bundle it came from is named for who made it. */
  if (g_str_has_suffix (base, ".pmtiles"))
    {
      g_autofree char *dir = g_path_get_dirname (path);
      g_autofree char *dir_name = g_path_get_basename (dir);

      if (g_strcmp0 (dir_name, stem) == 0)
        {
          g_autofree char *root = g_path_get_dirname (dir);
          g_autofree char *root_name = g_path_get_basename (root);

          if (root_name[0] != '\0' && !g_str_equal (root_name, "/") &&
              !g_str_equal (root_name, "."))
            {
              const char *known = lk_raster_provider_in (root_name);
              return known != NULL ? g_strdup (known) : g_steal_pointer (&root_name);
            }
        }
    }

  return stem[0] != '\0' ? g_steal_pointer (&stem) : g_steal_pointer (&base);
}

/* ---- the installed list ------------------------------------------------- */

/* The keys of a set table as a strv the store can write. Borrowed: the strings
 * belong to the table. */
static GPtrArray *
lk_raster_keys (GHashTable *table)
{
  GPtrArray *keys = g_ptr_array_new ();
  GHashTableIter iter;
  gpointer key;

  g_hash_table_iter_init (&iter, table);
  while (g_hash_table_iter_next (&iter, &key, NULL))
    g_ptr_array_add (keys, key);
  g_ptr_array_add (keys, NULL);

  return keys;
}

static void
lk_raster_charts_save (LkRasterCharts *self)
{
  g_autoptr (GPtrArray) off = lk_raster_keys (self->off);
  g_autoptr (GPtrArray) hidden = lk_raster_keys (self->hidden);

  lk_store_save_raster_all (lk_raster_charts_paths (self),
                            (const char *const *) off->pdata,
                            (const char *const *) hidden->pdata);
}

/* Forget every installed raster chart: the list, the off set, and the hidden
   set. The engine holds live pictures until the next open, so this takes effect
   then. */
void
lk_raster_charts_clear (LkRasterCharts *self)
{
  g_return_if_fail (self != NULL);

  g_ptr_array_set_size (self->paths, 0);
  g_ptr_array_add (self->paths, NULL); /* keep the strv terminator */
  g_hash_table_remove_all (self->off);
  g_hash_table_remove_all (self->hidden);
  lk_raster_charts_save (self);
}

LkRasterCharts *
lk_raster_charts_new (void)
{
  LkRasterCharts *self = g_new0 (LkRasterCharts, 1);

  self->paths = g_ptr_array_new_with_free_func (g_free);
  self->off = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  self->hidden = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);

  g_auto (GStrv) saved = lk_store_load_raster_paths ();
  for (guint i = 0; saved[i] != NULL; i++)
    g_ptr_array_add (self->paths, g_strdup (saved[i]));
  g_ptr_array_add (self->paths, NULL); /* the strv terminator callers read */

  g_auto (GStrv) off = lk_store_load_raster_off ();
  for (guint i = 0; off[i] != NULL; i++)
    g_hash_table_add (self->off, g_strdup (off[i]));

  g_auto (GStrv) hidden = lk_store_load_raster_hidden ();
  for (guint i = 0; hidden[i] != NULL; i++)
    g_hash_table_add (self->hidden, g_strdup (hidden[i]));

  return self;
}

void
lk_raster_charts_free (LkRasterCharts *self)
{
  if (self == NULL)
    return;

  g_ptr_array_unref (self->paths);
  g_hash_table_unref (self->off);
  g_hash_table_unref (self->hidden);
  g_free (self);
}

const char *const *
lk_raster_charts_paths (LkRasterCharts *self)
{
  g_return_val_if_fail (self != NULL, NULL);
  return (const char *const *) self->paths->pdata;
}

guint
lk_raster_charts_count (LkRasterCharts *self)
{
  g_return_val_if_fail (self != NULL, 0);
  return self->paths->len - 1; /* the terminator is not a chart */
}

static gboolean
lk_raster_charts_holds (LkRasterCharts *self, const char *path)
{
  for (guint i = 0; i + 1 < self->paths->len; i++)
    {
      if (g_strcmp0 (g_ptr_array_index (self->paths, i), path) == 0)
        return TRUE;
    }
  return FALSE;
}

gboolean
lk_raster_charts_add (LkRasterCharts *self, const char *path)
{
  g_return_val_if_fail (self != NULL && path != NULL, FALSE);

  if (lk_raster_charts_holds (self, path))
    return FALSE;

  /* Insert before the terminator, so the array stays a valid strv. */
  g_ptr_array_insert (self->paths, self->paths->len - 1, g_strdup (path));
  lk_raster_charts_save (self);
  return TRUE;
}

/* Is any installed file still part of the set called `name`? */
static gboolean
lk_raster_charts_holds_set (LkRasterCharts *self, const char *name)
{
  for (guint i = 0; i + 1 < self->paths->len; i++)
    {
      g_autofree char *other = lk_raster_set_name_for (g_ptr_array_index (self->paths, i));
      if (g_strcmp0 (other, name) == 0)
        return TRUE;
    }
  return FALSE;
}

void
lk_raster_charts_remove (LkRasterCharts *self, const char *path)
{
  g_return_if_fail (self != NULL && path != NULL);

  g_autofree char *name = lk_raster_set_name_for (path);

  for (guint i = 0; i + 1 < self->paths->len; i++)
    {
      if (g_strcmp0 (g_ptr_array_index (self->paths, i), path) == 0)
        {
          g_ptr_array_remove_index (self->paths, i);
          break;
        }
    }

  /* Forgotten means forgotten. The two lists are keyed by path and by set name,
   * so leaving an entry behind means the same file installed again months later
   * comes back switched off, or its set not drawn, with nothing on screen to
   * say why. The name goes with the LAST file of its set: while the mariner
   * still carries the others, it is still the set they switched off. */
  g_hash_table_remove (self->off, path);
  if (!lk_raster_charts_holds_set (self, name))
    g_hash_table_remove (self->hidden, name);

  lk_raster_charts_save (self);
}

void
lk_raster_charts_set_enabled (LkRasterCharts *self, const char *path, gboolean on)
{
  g_return_if_fail (self != NULL && path != NULL);

  if (on)
    g_hash_table_remove (self->off, path);
  else
    g_hash_table_add (self->off, g_strdup (path));

  lk_raster_charts_save (self);
}

gboolean
lk_raster_charts_enabled (LkRasterCharts *self, const char *path)
{
  g_return_val_if_fail (self != NULL && path != NULL, TRUE);
  return !g_hash_table_contains (self->off, path);
}

gboolean
lk_raster_charts_shown (LkRasterCharts *self, const char *name)
{
  g_return_val_if_fail (self != NULL && name != NULL, TRUE);
  return !g_hash_table_contains (self->hidden, name);
}

gboolean
lk_raster_charts_note_shown (LkRasterCharts    *self,
                             const char *const *shown,
                             const char *const *hidden)
{
  gboolean changed = FALSE;

  g_return_val_if_fail (self != NULL, FALSE);

  for (guint i = 0; shown != NULL && shown[i] != NULL; i++)
    {
      if (g_hash_table_remove (self->hidden, shown[i]))
        changed = TRUE;
    }

  for (guint i = 0; hidden != NULL && hidden[i] != NULL; i++)
    {
      if (g_hash_table_contains (self->hidden, hidden[i]))
        continue;
      g_hash_table_add (self->hidden, g_strdup (hidden[i]));
      changed = TRUE;
    }

  /* Only on a real change: this is read back after every frame that moves the
   * raster state, and rewriting settings.ini as the mariner sails in and out of
   * coverage would be a file write for nothing. */
  if (changed)
    lk_raster_charts_save (self);
  return changed;
}

static void
lk_raster_group_free (gpointer data)
{
  LkRasterGroup *group = data;

  g_free (group->name);
  g_ptr_array_unref (group->paths);
  g_free (group);
}

GPtrArray *
lk_raster_charts_groups (LkRasterCharts *self)
{
  GPtrArray *groups = g_ptr_array_new_with_free_func (lk_raster_group_free);

  g_return_val_if_fail (self != NULL, groups);

  for (guint i = 0; i + 1 < self->paths->len; i++)
    {
      char *path = g_ptr_array_index (self->paths, i);
      g_autofree char *name = lk_raster_set_name_for (path);
      LkRasterGroup *group = NULL;

      for (guint j = 0; j < groups->len; j++)
        {
          LkRasterGroup *candidate = g_ptr_array_index (groups, j);
          if (g_strcmp0 (candidate->name, name) == 0)
            {
              group = candidate;
              break;
            }
        }

      if (group == NULL)
        {
          group = g_new0 (LkRasterGroup, 1);
          group->name = g_steal_pointer (&name);
          group->paths = g_ptr_array_new ();
          g_ptr_array_add (groups, group);
        }

      g_ptr_array_add (group->paths, path);
    }

  return groups;
}

/* ---- finding them on disk ------------------------------------------------ */

static void
lk_raster_collect (const char *dir, GPtrArray *out)
{
  g_autoptr (GDir) handle = g_dir_open (dir, 0, NULL);

  if (handle == NULL)
    return;

  const char *name;
  while ((name = g_dir_read_name (handle)) != NULL)
    {
      g_autofree char *path = g_build_filename (dir, name, NULL);
      g_autofree char *lower = g_ascii_strdown (name, -1);

      if (g_file_test (path, G_FILE_TEST_IS_DIR))
        lk_raster_collect (path, out);
      else if (g_str_has_suffix (lower, ".mbtiles"))
        g_ptr_array_add (out, g_steal_pointer (&path));
    }
}

static int
lk_raster_sort (gconstpointer a, gconstpointer b)
{
  return g_strcmp0 (*(const char *const *) a, *(const char *const *) b);
}

char **
lk_raster_charts_in_dir (const char *dir)
{
  g_autoptr (GPtrArray) paths = g_ptr_array_new_with_free_func (g_free);

  g_return_val_if_fail (dir != NULL, g_new0 (char *, 1));

  lk_raster_collect (dir, paths);
  g_ptr_array_sort (paths, lk_raster_sort);
  g_ptr_array_add (paths, NULL);
  return (char **) g_ptr_array_free (g_steal_pointer (&paths), FALSE);
}
