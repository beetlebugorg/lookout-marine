/* library/sets.c: the installed chart sets.
 *
 * A SET is a folder the mariner added, or one .zip, which is how a chart
 * agency publishes one. The CORE owns the list, the switches, their
 * persistence and the background scan that learns each one's size; this is the
 * binding, plus the two things a settings row draws that no other shell draws
 * the same way: the office a producer code belongs to, and the summary line.
 */
#include "library/sets.h"

#include "library/bake.h"
#include "model/store.h"

#include <string.h>

struct _LkChartSets {
  lookout_chart_sets *sets;
  /* The list as a NULL-terminated strv, rebuilt whenever it changes. */
  GStrv paths;

  LkChartSetsChanged on_changed;
  GObject           *owner; /* not owned */

  /* Runs while a background scan is still to land, and stops when every set
   * has been read. Idle means idle: nothing is coming after that. */
  guint poll_id;
};

/* How often a landing scan is noticed. The core does the work on its own
 * thread and raises a flag; this is what asks. */
#define LK_SETS_POLL_MS 200

static void lk_chart_sets_sync_paths (LkChartSets *self);
static void lk_chart_sets_watch_scans (LkChartSets *self);

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

/* Whether the seed below has ever run. A library the mariner emptied on
 * purpose must stay empty, and the core's list key is cleared by an empty
 * list, so the answer cannot come from the list itself. */
#define LK_KEY_SETS_SEEDED "seeded"

/* No list ever saved means this build has never run here, and the charts the
 * mariner had open carry across as sets, without this they are simply gone at
 * the next launch, the folders still on disk and the app showing the first-run
 * page. What is not a chart drops out on its own the first time a scan looks.
 * Once, whatever the mariner does with the list afterwards. */
static void
lk_chart_sets_seed_from_recents (LkChartSets *self)
{
  lookout_store *store = lk_store_handle ();
  size_t count = 0;

  if (lookout_store_flag (store, LOOKOUT_STORE_CHARTSETS, LK_KEY_SETS_SEEDED, 0))
    return;
  lookout_store_set_flag (store, LOOKOUT_STORE_CHARTSETS, LK_KEY_SETS_SEEDED, 1);

  lookout_chart_sets_all (self->sets, &count);
  if (count > 0)
    return;

  g_auto (GStrv) recents = lk_store_load_recents ();
  for (guint i = 0; recents != NULL && recents[i] != NULL; i++)
    lookout_chart_sets_add (self->sets, recents[i]);
}

LkChartSets *
lk_chart_sets_new (LkChartSetsChanged on_changed, GObject *owner)
{
  LkChartSets *self = g_new0 (LkChartSets, 1);

  self->on_changed = on_changed;
  self->owner = owner;
  /* The prepared root is scanned beside each set's own path, and a prepared
   * chart wins over the file it was made from, so a folder scanned after an
   * import does not ask to be imported again. */
  self->sets = lookout_chart_sets_open (lk_store_handle (), lk_chart_bake_root ());
  if (self->sets == NULL)
    g_error ("the chart set list could not be opened");

  lk_chart_sets_seed_from_recents (self);
  lk_chart_sets_sync_paths (self);
  lk_chart_sets_watch_scans (self);
  return self;
}

lookout_chart_sets *
lk_chart_sets_handle (LkChartSets *self)
{
  return self != NULL ? self->sets : NULL;
}

void
lk_chart_sets_free (LkChartSets *self)
{
  if (self == NULL)
    return;

  g_clear_handle_id (&self->poll_id, g_source_remove);
  g_clear_pointer (&self->paths, g_strfreev);
  /* Joins the scan worker, so no result can land on a freed model. */
  g_clear_pointer (&self->sets, lookout_chart_sets_close);
  g_free (self);
}

/* The core's array is borrowed until the next call that changes the list, and
 * callers hold this one across such calls, so it is a copy. */
static void
lk_chart_sets_sync_paths (LkChartSets *self)
{
  size_t count = 0;
  const lookout_chart_set *const *rows = lookout_chart_sets_all (self->sets, &count);
  char **paths = g_new0 (char *, count + 1);

  for (size_t i = 0; i < count; i++)
    paths[i] = g_strdup (rows[i]->path);

  g_strfreev (self->paths);
  self->paths = paths;
}

const char *const *
lk_chart_sets_paths (LkChartSets *self)
{
  return (const char *const *) self->paths;
}

static char *lk_chart_set_detail (const lookout_chart_set *row);
static const char *lk_chart_set_agency (const char *producer);

/* The cells one set holds, by usage band. The scan has already read every
 * file, so this counts what it found rather than walking the folder again. */
static void
lk_chart_set_count_bands (LkChartSets *self, const char *path, guint bands[7])
{
  size_t n = 0;
  const lookout_chart_file *const *files = lookout_chart_set_files (self->sets, path, &n);

  for (size_t i = 0; i < n; i++)
    {
      const lookout_chart_file *file = files[i];
      int band;

      /* Surveys only. A picture covers water rather than sitting on a scale,
       * and an update bakes into its base cell. */
      if (file->kind != LOOKOUT_FILE_BAKED && file->kind != LOOKOUT_FILE_SOURCE)
        continue;
      band = file->band >= 1 && file->band <= 6 ? file->band : 0;
      bands[band]++;
    }
}

GPtrArray *
lk_chart_sets_rows (LkChartSets *self)
{
  GPtrArray *rows = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_chart_set_row_free);
  size_t count = 0;
  const lookout_chart_set *const *all = lookout_chart_sets_all (self->sets, &count);

  for (size_t i = 0; i < count; i++)
    {
      const lookout_chart_set *set = all[i];
      const char *agency = lk_chart_set_agency (set->producer);
      LkChartSetRow *row;
      size_t n_files = 0;

      /* Drop a set the scan has read and found empty. The NOAA picker empties
       * one by deleting the cells for water the mariner unticked, and the
       * folder remains. That folder produced a row with a switch over zero
       * charts and a size of zero. Before the scan completes the count is 0
       * for every set, so this waits on `scanned`. The reference drops the
       * same row (apple/LookoutMarine/Charts/ChartsModel.swift,
       * pullChartSets). */
      lookout_chart_set_files (self->sets, set->path, &n_files);
      if (set->scanned != 0 && n_files == 0)
        continue;

      row = g_new0 (LkChartSetRow, 1);

      row->path = g_strdup (set->path);
      /* The core names a set by its folder. An office the app knows is the
       * better name, and a producer code the app does not know keeps the
       * folder: a wrong agency on a chart set is worse than a dull one. */
      row->title = agency != NULL ? g_strdup (agency) : g_strdup (set->title);
      row->name = g_path_get_basename (set->path);
      row->detail = lk_chart_set_detail (set);
      row->charts = (guint) set->charts;
      row->unprepared = (guint) set->unprepared;
      row->to_prepare = (guint) set->to_prepare;
      row->refused = (guint) set->refused;
      for (guint b = 0; b < G_N_ELEMENTS (row->band_todo); b++)
        row->band_todo[b] = (guint) set->band_todo[b];
      row->pictures = (guint) set->pictures;
      row->bytes = (gint64) set->bytes;
      row->scanned = set->scanned != 0;
      /* TRUE when REMOVING THIS DELETES WORK, the charts Lookout prepared
       * from it. That is the question the removal actually asks, and it is NOT
       * the same as the set's own path sitting under the prepared root: a
       * folder of the mariner's own cells lives in their home and still has a
       * prepared directory of its own, which the removal deletes. Asking the
       * other question took a gigabyte of prepared charts off the disk with no
       * word, under a tooltip promising the mariner's files stayed where they
       * were. The reference asks this one (ChartSets.swift, isDerived). */
      g_autofree char *prepared = lk_chart_bake_prepared_dir (set->path);
      row->derived = lk_chart_bake_is_derived (set->path) ||
                     (prepared != NULL && g_file_test (prepared, G_FILE_TEST_IS_DIR));
      row->managed = set->managed != 0;
      row->held_back = (guint) set->held_back;
      row->on = set->on != 0;
      lk_chart_set_count_bands (self, set->path, row->bands);
      g_ptr_array_add (rows, row);
    }
  return rows;
}

const lookout_chart_file *const *
lk_chart_sets_to_prepare (LkChartSets *self, const char *path, gsize *out_n)
{
  size_t n = 0;
  const lookout_chart_file *const *files = NULL;

  if (self != NULL && path != NULL)
    files = lookout_chart_set_to_prepare (self->sets, path, &n);
  if (out_n != NULL)
    *out_n = (gsize) n;
  return files;
}

void
lk_chart_sets_note_bake (LkChartSets *self, const char *path, const lookout_bake *bake)
{
  if (self == NULL || path == NULL || bake == NULL)
    return;
  lookout_chart_sets_note_bake (self->sets, path, bake);
}

void
lk_chart_sets_note_cancel (LkChartSets *self, const char *path)
{
  if (self == NULL || path == NULL)
    return;
  lookout_chart_sets_note_cancel (self->sets, path);
}

gboolean
lk_chart_sets_rescan (LkChartSets *self, const char *path)
{
  if (path == NULL || !lookout_chart_sets_rescan (self->sets, path))
    return FALSE;

  lk_chart_sets_watch_scans (self);
  return TRUE;
}

gboolean
lk_chart_sets_set_on (LkChartSets *self, const char *path, gboolean on)
{
  return lookout_chart_sets_set_on (self->sets, path, on ? 1 : 0) != 0;
}

gboolean
lk_chart_sets_remove (LkChartSets *self, const char *path, char **out_prepared)
{
  if (out_prepared != NULL)
    *out_prepared = NULL;
  if (!lookout_chart_sets_remove (self->sets, path))
    return FALSE;
  lk_chart_sets_sync_paths (self);

  /* The core deletes nothing, and neither does this. What Lookout prepared
   * from the set can be made again, so it goes, but the delete is thousands
   * of files and says where it has got to, and this unit has nowhere to say
   * it. The caller does the deleting. The mariner's own folder is never
   * touched either way. */
  if (out_prepared != NULL)
    *out_prepared = lk_chart_bake_prepared_dir (path);

  return TRUE;
}

gboolean
lk_chart_sets_is_on (LkChartSets *self, const char *path)
{
  return lookout_chart_sets_is_on (self->sets, path) != 0;
}

gboolean
lk_chart_sets_any_on_drawable (LkChartSets *self)
{
  size_t count = 0;
  const lookout_chart_set *const *all = lookout_chart_sets_all (self->sets, &count);

  for (size_t i = 0; i < count; i++)
    {
      const lookout_chart_set *set = all[i];

      if (set->on == 0)
        continue;
      /* Unread counts as drawable. The counts arrive with the scan, and a set
       * read as empty in the meantime is a set the mariner watches vanish. */
      if (!set->scanned || set->charts > 0 || set->pictures > 0)
        return TRUE;
    }
  return FALSE;
}

gboolean
lk_chart_sets_scanning (LkChartSets *self)
{
  size_t count = 0;
  const lookout_chart_set *const *all = lookout_chart_sets_all (self->sets, &count);

  for (size_t i = 0; i < count; i++)
    if (all[i]->scanned == 0)
      return TRUE;
  return FALSE;
}

/* Put a source on the list, switched on. Opening a source is also
 * selecting it. */
gboolean
lk_chart_sets_note (LkChartSets *self, const char *path)
{
  gboolean added, switched;

  if (path == NULL)
    return FALSE;

  added = lookout_chart_sets_add (self->sets, path) != 0;
  switched = lookout_chart_sets_set_on (self->sets, path, 1) != 0;
  if (!added && !switched)
    return FALSE;

  lk_chart_sets_sync_paths (self);
  lk_chart_sets_watch_scans (self);
  return TRUE;
}

/* The UNION of the sets switched on, the library the chart opens as. The core
 * composes it: two sets may hold the same cell, and it is opened once. */
char **
lk_chart_sets_compose (LkChartSets *self)
{
  size_t count = 0;
  const char *const *all = lookout_chart_sets_compose (self->sets, &count);
  char **out = g_new0 (char *, count + 1);

  for (size_t i = 0; i < count; i++)
    out[i] = g_strdup (all[i]);
  return out;
}

gboolean
lk_chart_sets_set_managed (LkChartSets *self, const char *path, gboolean on)
{
  return path != NULL &&
         lookout_chart_sets_set_managed (self->sets, path, on ? 1 : 0) != 0;
}

/* ---- watching for a scan to land ------------------------------------------ */

static gboolean
lk_chart_sets_poll (gpointer data)
{
  LkChartSets *self = data;
  gboolean changed = lookout_chart_sets_changed (self->sets);
  size_t count = 0;
  const lookout_chart_set *const *all;
  gboolean waiting = FALSE;

  all = lookout_chart_sets_all (self->sets, &count);
  for (size_t i = 0; i < count && !waiting; i++)
    waiting = all[i]->scanned == 0;

  /* The tick that settles the scan always reports, flag or no flag. The last
   * scan can land between the flag read and the count read, and this timer
   * stops here: there is no later tick for that landing to arrive on, and the
   * chart the library composes to waits for it. */
  if (changed || !waiting)
    self->on_changed (self->owner);

  if (waiting)
    return G_SOURCE_CONTINUE;

  self->poll_id = 0;
  return G_SOURCE_REMOVE;
}

/* A scan runs on the core's own thread and raises a flag. Watch for it while
 * one is still to land, and stop once every set has been read: nothing is
 * coming after that, and a timer that keeps beating is a battery a boat
 * cannot spare. */
static void
lk_chart_sets_watch_scans (LkChartSets *self)
{
  size_t count = 0;
  const lookout_chart_set *const *all = lookout_chart_sets_all (self->sets, &count);

  if (self->poll_id != 0)
    return;
  for (size_t i = 0; i < count; i++)
    {
      if (all[i]->scanned == 0)
        {
          self->poll_id = g_timeout_add (LK_SETS_POLL_MS, lk_chart_sets_poll, self);
          return;
        }
    }
}

void
lk_chart_set_row_free (LkChartSetRow *row)
{
  if (row == NULL)
    return;
  g_free (row->path);
  g_free (row->title);
  g_free (row->name);
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

/* "512 charts · 3 pictures · Coastal to Harbor · 1.2 GB": what a settings row
 * reads under the name. The counts are the core's; the wording is this
 * shell's, and each shell writes its own. */
static char *
lk_chart_set_detail (const lookout_chart_set *row)
{
  g_autoptr (GString) detail = g_string_new (NULL);

  if (!row->scanned)
    return g_strdup ("");

  /* A cell that still has to bake is counted with the rest: the row says what
   * the folder holds, and the mariner asked for all of it. */
  size_t charts = row->charts + row->unprepared;

  if (charts > 0)
    g_string_append_printf (detail, charts == 1 ? "%zu chart" : "%zu charts", charts);
  if (row->pictures > 0)
    g_string_append_printf (detail, "%s%zu picture%s", detail->len > 0 ? " · " : "",
                            row->pictures, row->pictures == 1 ? "" : "s");
  if (row->band_lo > 0)
    {
      g_string_append (detail, detail->len > 0 ? " · " : "");
      if (row->band_lo == row->band_hi)
        g_string_append (detail, lookout_usage_band_name (row->band_lo));
      else
        g_string_append_printf (detail, "%s to %s", lookout_usage_band_name (row->band_lo),
                                lookout_usage_band_name (row->band_hi));
    }
  if (row->bytes > 0)
    {
      char size[LOOKOUT_BYTES_MAX];

      lookout_fmt_bytes (row->bytes, size, sizeof size);
      g_string_append_printf (detail, "%s%s", detail->len > 0 ? " · " : "", size);
    }
  if (detail->len == 0)
    g_string_append (detail, "No charts found");

  return g_strdup (detail->str);
}
