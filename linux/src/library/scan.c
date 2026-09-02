#include "library/scan.h"

#include <string.h>

gboolean
lk_chart_scan_is_archive (const char *path)
{
  if (path == NULL)
    return FALSE;

  g_autofree char *lower = g_ascii_strdown (path, -1);
  return g_str_has_suffix (lower, ".zip");
}

gboolean
lk_scanned_cell_needs_prepare (const LkScannedCell *cell)
{
  if (cell == NULL)
    return FALSE;
  if (cell->archived)
    return TRUE;
  return cell->kind == LOOKOUT_FILE_SOURCE || cell->kind == LOOKOUT_FILE_RASTER_SOURCE;
}

gboolean
lk_scanned_cell_is_raster (const LkScannedCell *cell)
{
  if (cell == NULL)
    return FALSE;
  return cell->kind == LOOKOUT_FILE_RASTER || cell->kind == LOOKOUT_FILE_RASTER_SOURCE;
}

static void
lk_scanned_cell_free (gpointer data)
{
  LkScannedCell *cell = data;

  if (cell == NULL)
    return;
  g_free (cell->path);
  g_free (cell->name);
  g_free (cell->band_name);
  g_free (cell);
}

/* One of the read's two arrays, copied so the set outlives the read. */
static void
lk_scan_take_array (LkChartSet *set, const lookout_chart_file *const *files,
                    size_t count, gboolean archived)
{
  for (size_t i = 0; i < count; i++)
    {
      LkScannedCell *cell = g_new0 (LkScannedCell, 1);

      cell->path = g_strdup (files[i]->path);
      cell->name = g_strdup (files[i]->name);
      cell->kind = files[i]->kind;
      cell->band = files[i]->band;
      cell->band_name = g_strdup (files[i]->band_name);
      cell->bytes = (gint64) files[i]->bytes;
      cell->scale = (int) files[i]->scale;
      cell->archived = archived;

      if (cell->name[0] == '\0')
        {
          g_free (cell->name);
          cell->name = g_path_get_basename (cell->path);
        }

      g_ptr_array_add (set->cells, cell);
    }
}

LkChartSet *
lk_chart_scan (const char *path)
{
  if (path == NULL || *path == '\0')
    return NULL;

  gboolean archive = lk_chart_scan_is_archive (path);
  /* The two reads answer in the same shape, so everything below reads one
     format. Each is the caller's own copy, so the open road and the library's
     background metadata scans need no lock between them. */
  lookout_scan *read = archive ? lookout_scan_zip_read (path)
                               : lookout_scan_read (path);

  if (read == NULL)
    return NULL;

  const lookout_scan_summary *found = lookout_scan_found (read);
  LkChartSet *set = g_new0 (LkChartSet, 1);

  set->cells = g_ptr_array_new_with_free_func (lk_scanned_cell_free);
  set->archive = archive;
  set->root = g_strdup (found->root[0] != '\0' ? found->root : path);
  set->producer = g_strdup (found->producer);
  set->sources = (int) found->sources;
  set->bytes = (gint64) found->bytes;

  size_t count = 0;
  const lookout_chart_file *const *files = lookout_scan_cells (read, &count);
  lk_scan_take_array (set, files, count, archive);
  files = lookout_scan_raster (read, &count);
  lk_scan_take_array (set, files, count, archive);
  lookout_scan_free (read);

  for (guint i = 0; i < set->cells->len; i++)
    {
      const LkScannedCell *cell = g_ptr_array_index (set->cells, i);
      if (!lk_scanned_cell_needs_prepare (cell))
        set->baked++;
    }

  return set;
}

void
lk_chart_set_free (LkChartSet *set)
{
  if (set == NULL)
    return;
  g_clear_pointer (&set->cells, g_ptr_array_unref);
  g_free (set->root);
  g_free (set->producer);
  g_free (set);
}

/* ---- the disk walk ------------------------------------------------------- */

static void
lk_collect_under (const char *dir, const char *suffix, GPtrArray *out)
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
        lk_collect_under (path, suffix, out);
      else if (g_str_has_suffix (lower, suffix))
        g_ptr_array_add (out, g_steal_pointer (&path));
    }
}

static int
lk_path_sort (gconstpointer a, gconstpointer b)
{
  return g_strcmp0 (*(const char *const *) a, *(const char *const *) b);
}

char **
lk_files_under (const char *dir, const char *suffix)
{
  g_autoptr (GPtrArray) paths = g_ptr_array_new_with_free_func (g_free);

  g_return_val_if_fail (dir != NULL, g_new0 (char *, 1));
  g_return_val_if_fail (suffix != NULL, g_new0 (char *, 1));

  lk_collect_under (dir, suffix, paths);
  g_ptr_array_sort (paths, lk_path_sort);
  g_ptr_array_add (paths, NULL);
  return (char **) g_ptr_array_free (g_steal_pointer (&paths), FALSE);
}
