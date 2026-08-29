/* library/sets.c — the chart sets aboard.
 *
 * A SET is a folder the mariner added, or one .zip, which is how a chart
 * agency publishes one. This unit owns the list, which of them are switched
 * off, and the background scan that learns each one's title and size. It
 * knows nothing about the chart on screen: the model composes the library and
 * reopens the chart, and hears from here through one changed callback.
 */
#include "library/sets.h"

#include "library/bake.h"
#include "model/store.h"

#include <string.h>

struct _LkChartSets {
  GStrv       paths;    /* every set aboard, in the order added */
  GHashTable *off;      /* the paths switched off, as a set */
  GHashTable *meta;     /* path → LkSetMeta, filled by the background scan */
  gboolean    scanning; /* one scan at a time */

  LkChartSetsChanged on_changed;
  gpointer           user_data;
};

/* What one metadata scan learned about a set. */
typedef struct {
  char *title;
  char *detail;
  guint charts; /* prepared cells, for the removal dialog's rebuild estimate */
} LkSetMeta;

static void
lk_set_meta_free (gpointer data)
{
  LkSetMeta *meta = data;

  g_free (meta->title);
  g_free (meta->detail);
  g_free (meta);
}


/* Defined below, and used by the constructor and the mutators above them. */
static void lk_chart_sets_save (LkChartSets *self);
static void lk_chart_sets_kick_meta_scan (LkChartSets *self);

/* ---- the walk over what is on disk --------------------------------------- */

char **
lk_chart_paths_in_dir (const char *dir)
{
  return lk_files_under (dir, ".pmtiles");
}

/* Target to cell list: a folder expands to its cells, a file is itself, a
 * dangling path is empty (callers fall through to the next candidate). */
char **
lk_chart_cell_paths_for (const char *target)
{
  if (target == NULL || !g_file_test (target, G_FILE_TEST_EXISTS))
    return g_new0 (char *, 1);

  if (g_file_test (target, G_FILE_TEST_IS_DIR))
    return lk_chart_paths_in_dir (target);

  /* An archive is a chart SET, not a chart: handing it to the engine gets it
     read as a PMTiles file and refused. Answering empty sends it down the
     prepare road instead, which is where it belongs. */
  if (lk_chart_scan_is_archive (target))
    return g_new0 (char *, 1);

  char **one = g_new0 (char *, 2);
  one[0] = g_strdup (target);
  return one;
}

/* ---- the list ------------------------------------------------------------ */

LkChartSets *
lk_chart_sets_new (LkChartSetsChanged on_changed, gpointer user_data)
{
  LkChartSets *self = g_new0 (LkChartSets, 1);

  self->on_changed = on_changed;
  self->user_data = user_data;

  /* No list ever saved means this build has never run here, and the charts the
   * mariner had open carry across as sets — without this they are simply gone
   * at the next launch, the folders still on disk and the app showing the
   * first-run page. What is not a chart drops out on its own the first time a
   * scan looks. */
  self->paths = lk_store_load_chart_sets ();
  if (self->paths == NULL)
    {
      self->paths = lk_store_load_recents ();
      if (self->paths == NULL)
        self->paths = g_new0 (char *, 1);
      lk_store_save_chart_sets ((const char *const *) self->paths);
    }

  self->off = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  {
    g_auto (GStrv) off = lk_store_load_chart_sets_off ();
    for (guint i = 0; off != NULL && off[i] != NULL; i++)
      g_hash_table_add (self->off, g_strdup (off[i]));
  }
  self->meta = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, lk_set_meta_free);
  lk_chart_sets_kick_meta_scan (self);
  return self;
}

void
lk_chart_sets_free (LkChartSets *self)
{
  if (self == NULL)
    return;

  /* A scan in flight holds this pointer. It is dropped last, on the main loop,
   * so a job that lands after the model is gone would read freed memory. The
   * model outlives the application's windows, so that cannot happen here. */
  g_clear_pointer (&self->paths, g_strfreev);
  g_clear_pointer (&self->off, g_hash_table_unref);
  g_clear_pointer (&self->meta, g_hash_table_unref);
  g_free (self);
}

const char *const *
lk_chart_sets_paths (LkChartSets *self)
{
  return (const char *const *) self->paths;
}

GPtrArray *
lk_chart_sets_rows (LkChartSets *self)
{
  GPtrArray *rows = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_chart_set_row_free);

  for (guint i = 0; self->paths != NULL && self->paths[i] != NULL; i++)
    {
      const char *path = self->paths[i];
      const LkSetMeta *meta = g_hash_table_lookup (self->meta, path);
      LkChartSetRow *row = g_new0 (LkChartSetRow, 1);

      row->path = g_strdup (path);
      row->title = meta != NULL ? g_strdup (meta->title) : g_path_get_basename (path);
      row->detail = g_strdup (meta != NULL ? meta->detail : "");
      row->charts = meta != NULL ? meta->charts : 0;
      row->on = lk_chart_sets_is_on (self, path);
      g_ptr_array_add (rows, row);
    }
  return rows;
}

gboolean
lk_chart_sets_set_on (LkChartSets *self, const char *path, gboolean on)
{
  gboolean changed = on ? g_hash_table_remove (self->off, path)
                        : g_hash_table_add (self->off, g_strdup (path));
  if (!changed)
    return FALSE;

  lk_chart_sets_save (self);
  return TRUE;
}

gboolean
lk_chart_sets_remove (LkChartSets *self, const char *path)
{
  g_autoptr (GPtrArray) kept = g_ptr_array_new_with_free_func (g_free);
  gboolean had = FALSE;

  for (guint i = 0; self->paths != NULL && self->paths[i] != NULL; i++)
    {
      if (g_strcmp0 (self->paths[i], path) == 0)
        had = TRUE;
      else
        g_ptr_array_add (kept, g_strdup (self->paths[i]));
    }
  if (!had)
    return FALSE;

  g_ptr_array_add (kept, NULL);
  g_clear_pointer (&self->paths, g_strfreev);
  self->paths = (char **) g_ptr_array_free (g_steal_pointer (&kept), FALSE);
  g_hash_table_remove (self->off, path);
  g_hash_table_remove (self->meta, path);
  lk_chart_sets_save (self);

  /* What Lookout prepared from this set can be made again, so it goes; the
   * mariner's own folder is never touched. The delete renames first and
   * clears behind, so nothing here waits on the disk. */
  g_autofree char *prepared = lk_chart_bake_prepared_dir (path);
  if (prepared != NULL)
    lk_chart_bake_delete_derived (prepared);

  return TRUE;
}

void
lk_chart_set_row_free (LkChartSetRow *row)
{
  if (row == NULL)
    return;
  g_free (row->path);
  g_free (row->title);
  g_free (row->detail);
  g_free (row);
}

/* The hydrographic office a producer code belongs to. The code is the
 * country's, and for these that is the office a mariner would name. An office
 * not listed keeps the folder name rather than being given a title invented
 * here: a wrong agency on a chart set is worse than a dull one. The same
 * table every shell carries (ChartSets.swift). */
static const char *
lk_chart_set_agency (const char *producer)
{
  static const struct { const char *code, *name; } offices[] = {
    { "US", "NOAA" },
    { "GB", "UKHO" },
    { "CA", "CHS" },
    { "AU", "AHO" },
    { "NZ", "LINZ" },
    { "NL", "Netherlands Hydrographic Office" },
    { "DE", "BSH" },
    { "FR", "Shom" },
    { "NO", "Norwegian Hydrographic Service" },
    { "DK", "Danish Geodata Agency" },
    { "SE", "Swedish Maritime Administration" },
    { "FI", "Finnish Transport Agency" },
    { "IE", "INFOMAR" },
    { "JP", "Japan Hydrographic Association" },
    { "BR", "DHN" },
    { "ZA", "SANHO" },
  };

  for (gsize i = 0; producer != NULL && i < G_N_ELEMENTS (offices); i++)
    if (g_ascii_strcasecmp (producer, offices[i].code) == 0)
      return offices[i].name;
  return NULL;
}

static const char *
lk_chart_set_band_name (int band)
{
  static const char *names[] = { "Overview", "General", "Coastal",
                                 "Approach", "Harbor", "Berthing" };

  return band >= 1 && band <= 6 ? names[band - 1] : "Unknown";
}

/* The dataset name without its extension, which is what a prepared archive
 * and the file it was made from have in common. Transfer full. */
static char *
lk_scanned_cell_stem (const LkScannedCell *cell)
{
  char *stem = g_strdup (cell->name);
  char *dot = strrchr (stem, '.');

  if (dot != NULL && dot != stem)
    *dot = '\0';
  return stem;
}

gboolean
lk_chart_sets_is_on (LkChartSets *self, const char *path)
{
  return !g_hash_table_contains (self->off, path);
}

static void
lk_chart_sets_save (LkChartSets *self)
{
  lk_store_save_chart_sets ((const char *const *) self->paths);

  g_autoptr (GPtrArray) off = g_ptr_array_new ();
  GHashTableIter iter;
  gpointer key;
  g_hash_table_iter_init (&iter, self->off);
  while (g_hash_table_iter_next (&iter, &key, NULL))
    g_ptr_array_add (off, key);
  g_ptr_array_add (off, NULL);
  lk_store_save_chart_sets_off ((const char *const *) off->pdata);
}

/* Everything one set can hand the engine now: its own ready archives, plus
 * whatever a bake put in its prepared directory. `seen` keeps a path that two
 * sets somehow share from opening twice. */
static void
lk_compose_add_source (GPtrArray *all, GHashTable *seen, const char *source)
{
  g_auto (GStrv) ready = lk_chart_cell_paths_for (source);
  for (guint i = 0; ready != NULL && ready[i] != NULL; i++)
    if (g_hash_table_add (seen, g_strdup (ready[i])))
      g_ptr_array_add (all, g_strdup (ready[i]));

  g_autofree char *prepared = lk_chart_bake_prepared_dir (source);
  if (prepared != NULL && g_file_test (prepared, G_FILE_TEST_IS_DIR))
    {
      g_auto (GStrv) made = lk_chart_paths_in_dir (prepared);
      for (guint i = 0; made != NULL && made[i] != NULL; i++)
        if (g_hash_table_add (seen, g_strdup (made[i])))
          g_ptr_array_add (all, g_strdup (made[i]));
    }
}

/* The UNION of the sets switched on — the library the chart opens as. */
char **
lk_chart_sets_compose (LkChartSets *self)
{
  g_autoptr (GPtrArray) all = g_ptr_array_new_with_free_func (g_free);
  g_autoptr (GHashTable) seen = g_hash_table_new_full (g_str_hash, g_str_equal,
                                                       g_free, NULL);

  for (guint i = 0; self->paths != NULL && self->paths[i] != NULL; i++)
    if (lk_chart_sets_is_on (self, self->paths[i]))
      lk_compose_add_source (all, seen, self->paths[i]);

  g_ptr_array_add (all, NULL);
  return (char **) g_ptr_array_free (g_steal_pointer (&all), FALSE);
}

/* Put a source on the list, switched on. Opening a source is also
 * selecting it. */
gboolean
lk_chart_sets_note (LkChartSets *self, const char *path)
{
  if (path == NULL)
    return FALSE;

  gboolean have = FALSE;
  for (guint i = 0; self->paths != NULL && self->paths[i] != NULL; i++)
    have = have || g_strcmp0 (self->paths[i], path) == 0;
  gboolean was_off = g_hash_table_remove (self->off, path);

  if (!have)
    {
      guint n = self->paths != NULL ? g_strv_length (self->paths) : 0;
      self->paths = g_realloc (self->paths, (n + 2) * sizeof (char *));
      self->paths[n] = g_strdup (path);
      self->paths[n + 1] = NULL;
    }
  if (have && !was_off)
    return FALSE;

  lk_chart_sets_save (self);
  lk_chart_sets_kick_meta_scan (self);
  return TRUE;
}

/* ---- the library's background metadata scans ------------------------------ */

typedef struct {
  LkChartSets *sets;  /* outlives the job: the model owns both */
  char        *path;
  LkChartSet  *source;  /* the folder or archive itself */
  LkChartSet  *derived; /* its prepared directory, when one exists */
} LkMetaJob;

/* Title and summary from the pair of scans, the prepared half winning where
 * both hold the same chart — the way the reference merges them, so a folder
 * scanned after an import is not counted twice. */
static LkSetMeta *
lk_set_meta_build (const char *path, const LkChartSet *source, const LkChartSet *derived)
{
  LkSetMeta *meta = g_new0 (LkSetMeta, 1);
  g_autoptr (GHashTable) stems = g_hash_table_new_full (g_str_hash, g_str_equal,
                                                        g_free, NULL);
  guint charts = 0, pictures = 0;
  int band_lo = 0, band_hi = 0;
  gint64 bytes = 0;

  const LkChartSet *halves[] = { derived, source };
  for (gsize h = 0; h < G_N_ELEMENTS (halves); h++)
    {
      const LkChartSet *half = halves[h];
      for (guint i = 0; half != NULL && i < half->cells->len; i++)
        {
          const LkScannedCell *cell = g_ptr_array_index (half->cells, i);
          if (!g_hash_table_add (stems, lk_scanned_cell_stem (cell)))
            continue; /* the archive wins over the file it was made from */
          if (lk_scanned_cell_is_raster (cell))
            {
              pictures++;
            }
          else
            {
              charts++;
              if (cell->band > 0)
                {
                  band_lo = band_lo == 0 ? cell->band : MIN (band_lo, cell->band);
                  band_hi = MAX (band_hi, cell->band);
                }
            }
          bytes += cell->bytes;
        }
    }

  /* Whichever half holds the charts knows who made them. */
  const char *producer = source != NULL && source->producer != NULL
                             ? source->producer
                             : (derived != NULL ? derived->producer : NULL);
  const char *agency = lk_chart_set_agency (producer);
  if (agency != NULL)
    meta->title = g_strdup (agency);
  else
    meta->title = g_path_get_basename (path);

  GString *detail = g_string_new (NULL);
  if (charts > 0)
    g_string_append_printf (detail, charts == 1 ? "%u chart" : "%u charts", charts);
  if (pictures > 0)
    g_string_append_printf (detail, "%s%u picture%s", detail->len > 0 ? " · " : "",
                            pictures, pictures == 1 ? "" : "s");
  if (band_lo > 0)
    {
      g_string_append (detail, detail->len > 0 ? " · " : "");
      if (band_lo == band_hi)
        g_string_append (detail, lk_chart_set_band_name (band_lo));
      else
        g_string_append_printf (detail, "%s to %s", lk_chart_set_band_name (band_lo),
                                lk_chart_set_band_name (band_hi));
    }
  if (bytes > 0)
    {
      g_autofree char *size = g_format_size (bytes);
      g_string_append_printf (detail, "%s%s", detail->len > 0 ? " · " : "", size);
    }
  if (detail->len == 0)
    g_string_append (detail, "No charts found");
  meta->detail = g_string_free (detail, FALSE);
  meta->charts = charts;
  return meta;
}

static gboolean
lk_meta_done_idle (gpointer data)
{
  LkMetaJob *job = data;
  LkChartSets *self = job->sets;

  /* The set can leave the library while its scan is in flight. Keeping the
   * result would pin stale metadata: a later re-add reads the cache and
   * never rescans. */
  gboolean still_aboard = FALSE;
  for (guint i = 0; self->paths != NULL && self->paths[i] != NULL; i++)
    still_aboard = still_aboard || g_strcmp0 (self->paths[i], job->path) == 0;

  if (still_aboard)
    g_hash_table_replace (self->meta, g_strdup (job->path),
                          lk_set_meta_build (job->path, job->source, job->derived));
  self->scanning = FALSE;
  self->on_changed (self->user_data);
  lk_chart_sets_kick_meta_scan (self);

  g_clear_pointer (&job->source, lk_chart_set_free);
  g_clear_pointer (&job->derived, lk_chart_set_free);
  g_free (job->path);
  g_free (job);
  return G_SOURCE_REMOVE;
}

static gpointer
lk_meta_worker (gpointer data)
{
  LkMetaJob *job = data;

  job->source = lk_chart_scan (job->path);
  g_autofree char *prepared = lk_chart_bake_prepared_dir (job->path);
  if (prepared != NULL && g_file_test (prepared, G_FILE_TEST_IS_DIR))
    job->derived = lk_chart_scan (prepared);
  g_idle_add (lk_meta_done_idle, job);
  return NULL;
}

/* One set at a time, off the main loop: a scan opens every archive it finds,
 * and the full NOAA library is 7,217 of them. The engine's scan buffer is
 * serialized inside lk_chart_scan, so these never trip over an open. */
static void
lk_chart_sets_kick_meta_scan (LkChartSets *self)
{
  if (self->scanning)
    return;

  const char *next = NULL;
  for (guint i = 0; self->paths != NULL && self->paths[i] != NULL; i++)
    {
      if (!g_hash_table_contains (self->meta, self->paths[i]))
        {
          next = self->paths[i];
          break;
        }
    }
  if (next == NULL)
    return;

  LkMetaJob *job = g_new0 (LkMetaJob, 1);
  job->sets = self;
  job->path = g_strdup (next);
  self->scanning = TRUE;

  GThread *thread = g_thread_new ("lk-set-meta", lk_meta_worker, job);
  g_thread_unref (thread);
}
