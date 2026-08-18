#include "lk-chart-scan.h"

#include "lk-json.h"

#include <lookout.h>
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
  return g_strcmp0 (cell->kind, "source") == 0 ||
         g_strcmp0 (cell->kind, "raster_source") == 0;
}

gboolean
lk_scanned_cell_is_raster (const LkScannedCell *cell)
{
  if (cell == NULL)
    return FALSE;
  return g_strcmp0 (cell->kind, "raster") == 0 ||
         g_strcmp0 (cell->kind, "raster_source") == 0;
}

static void
lk_scanned_cell_free (gpointer data)
{
  LkScannedCell *cell = data;

  if (cell == NULL)
    return;
  g_free (cell->path);
  g_free (cell->name);
  g_free (cell->kind);
  g_free (cell->band_name);
  g_free (cell);
}

/* One "cells" or "raster" entry. */
static void
lk_scan_take_array (LkChartSet *set, const LkJson *array, gboolean archived)
{
  if (array == NULL || lk_json_kind (array) != LK_JSON_ARRAY)
    return;

  guint n = lk_json_length (array);
  for (guint i = 0; i < n; i++)
    {
      const LkJson *item = lk_json_at (array, i);
      const char *path = lk_json_member_string (item, "path");

      if (path == NULL)
        continue;

      LkScannedCell *cell = g_new0 (LkScannedCell, 1);
      cell->path = g_strdup (path);
      cell->name = g_strdup (lk_json_member_string (item, "name"));
      cell->kind = g_strdup (lk_json_member_string (item, "kind"));
      cell->band = lk_json_member_int (item, "band", 0);
      cell->band_name = g_strdup (lk_json_member_string (item, "bandName"));
      cell->bytes = (gint64) lk_json_number (lk_json_member (item, "bytes"), 0);
      cell->scale = lk_json_member_int (item, "scale", 0);
      cell->archived = archived;

      if (cell->name == NULL)
        cell->name = g_path_get_basename (cell->path);

      g_ptr_array_add (set->cells, cell);
    }
}

LkChartSet *
lk_chart_scan (const char *path)
{
  if (path == NULL || *path == '\0')
    return NULL;

  gboolean archive = lk_chart_scan_is_archive (path);
  /* The two calls answer in the same shape, so everything below reads one
     format. They also share one buffer inside the engine, which is why this
     is documented as not reentrant. */
  const char *json = archive ? lookout_scan_zip (path, NULL)
                             : lookout_scan_charts (path, NULL);
  if (json == NULL)
    return NULL;

  LkJson *root = lk_json_parse (json);
  if (root == NULL)
    return NULL;

  LkChartSet *set = g_new0 (LkChartSet, 1);
  set->cells = g_ptr_array_new_with_free_func (lk_scanned_cell_free);
  set->archive = archive;
  set->root = g_strdup (lk_json_member_string (root, "root"));
  set->producer = g_strdup (lk_json_member_string (root, "producer"));
  set->sources = lk_json_member_int (root, "sources", 0);
  set->bytes = (gint64) lk_json_number (lk_json_member (root, "bytes"), 0);

  if (set->root == NULL)
    set->root = g_strdup (path);

  lk_scan_take_array (set, lk_json_member (root, "cells"), archive);
  lk_scan_take_array (set, lk_json_member (root, "raster"), archive);

  for (guint i = 0; i < set->cells->len; i++)
    {
      const LkScannedCell *cell = g_ptr_array_index (set->cells, i);
      if (!lk_scanned_cell_needs_prepare (cell))
        set->baked++;
    }

  lk_json_free (root);
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
