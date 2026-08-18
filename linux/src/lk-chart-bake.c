#include "lk-chart-bake.h"

#include <tile57.h>

#include <glib/gstdio.h>
#include <string.h>

/* The name a chart directory takes while it is being thrown away. Dotted so it
 * cannot be read as a set's own directory, and unique so two removals cannot
 * collide. */
#define LK_TRASH_PREFIX ".removing-"

/* A 7,000 cell import would otherwise post 7,000 times and lay the panel out
 * 7,000 times, on a machine with nothing spare. */
#define LK_BAKE_POST_INTERVAL_US (G_USEC_PER_SEC / 5)

/* A memory bound, not a speed dial: each worker holds a whole cell's working
 * set, so this is what stops a big set from filling memory. */
#define LK_BAKE_MAX_WORKERS 8

/* What has to happen to one chart before the app can draw it. The calls are
 * separate because the work is: a cell is parsed and portrayed from the
 * survey, a sheet is decoded and warped from a picture, and something that is
 * already a chart is only lifted out of the archive. */
typedef enum {
  LK_PREPARE_CELL = 0,
  LK_PREPARE_SHEET = 1,
  LK_PREPARE_LIFT = 2,
} LkPrepare;

struct _LkChartBake {
  GThread *thread;

  char *source;
  char *out_dir;
  char *name;
  gboolean archive;

  GPtrArray *in_paths;  /* char*, owned */
  GPtrArray *out_paths; /* char*, owned */
  GPtrArray *labels;    /* char*, owned; the name to report per index */
  int cell_count;
  int sheet_count;
  int lift_count;

  /* Read by the engine's progress callback on its worker threads. */
  gint cancelled;

  GMutex lock;
  int phase_offset; /* the engine counts from zero per call; put it back */
  int job_total;
  int done;
  char *last_cell;
  gint64 started_us;
  gint64 last_post_us;

  LkBakeProgressFunc on_progress;
  LkBakeDoneFunc on_done;
  gpointer user_data;

  guint baked;
  gboolean ok;
};

/* ---- progress ------------------------------------------------------------ */

double
lk_bake_progress_fraction (const LkBakeProgress *p)
{
  if (p == NULL || p->total <= 0)
    return 0;
  return (double) p->done / (double) p->total;
}

char *
lk_bake_progress_title (const LkBakeProgress *p)
{
  if (p == NULL)
    return g_strdup ("");

  const char *name = p->name != NULL ? p->name : "";

  switch (p->kind)
    {
    case LK_BAKE_REMOVING:
      return g_strdup_printf ("Removing %s", name);
    case LK_BAKE_FINDING:
      return g_strdup_printf ("Finding charts in %s", name);
    case LK_BAKE_IMPORTING:
    default:
      /* A count means the charts have been found and are being converted. */
      return p->total > 0 ? g_strdup_printf ("Importing %s", name)
                          : g_strdup_printf ("Finding charts in %s", name);
    }
}

char *
lk_bake_progress_remaining (const LkBakeProgress *p)
{
  if (p == NULL || p->kind == LK_BAKE_REMOVING)
    return NULL;
  if (p->done < 3 || p->total <= p->done || p->elapsed <= 1)
    return NULL;

  double per = p->elapsed / (double) p->done;
  double left = per * (double) (p->total - p->done);

  if (left < 60)
    return g_strdup ("under a minute left");
  if (left < 3600)
    return g_strdup_printf ("about %d min left", (int) ((left / 60) + 0.5));
  return g_strdup_printf ("about %.1f h left", left / 3600);
}

static void
lk_bake_progress_clear (LkBakeProgress *p)
{
  g_free (p->name);
  g_free (p->cell);
}

/* ---- where prepared charts live ------------------------------------------ */

const char *
lk_chart_bake_root (void)
{
  static char *root = NULL;

  if (g_once_init_enter (&root))
    {
      char *value = g_build_filename (g_get_user_data_dir (), "lookout-marine", "charts", NULL);
      g_once_init_leave (&root, value);
    }
  return root;
}

gboolean
lk_chart_bake_is_derived (const char *path)
{
  const char *root = lk_chart_bake_root ();

  if (path == NULL || root == NULL)
    return FALSE;
  if (g_strcmp0 (path, root) == 0)
    return TRUE;

  g_autofree char *prefix = g_strconcat (root, G_DIR_SEPARATOR_S, NULL);
  return g_str_has_prefix (path, prefix);
}

char *
lk_chart_bake_prepared_dir (const char *source)
{
  const char *root = lk_chart_bake_root ();

  if (source == NULL || root == NULL)
    return NULL;

  g_autofree char *base = g_path_get_basename (source);
  /* An archive names its directory without the .zip: what comes out of
     All_ENCs.zip is charts, and "All_ENCs.zip/" full of them reads like a
     mistake. */
  if (lk_chart_scan_is_archive (source))
    {
      char *dot = g_strrstr (base, ".");
      if (dot != NULL)
        *dot = '\0';
    }
  return g_build_filename (root, base, NULL);
}

static char *
lk_chart_bake_output_dir (const char *source)
{
  char *dir = lk_chart_bake_prepared_dir (source);

  if (dir == NULL)
    return NULL;
  if (g_mkdir_with_parents (dir, 0755) != 0)
    {
      g_free (dir);
      return NULL;
    }
  return dir;
}

/* ---- removing a prepared set --------------------------------------------- */

static gboolean
lk_remove_tree (const char *path)
{
  GDir *dir = g_dir_open (path, 0, NULL);

  if (dir != NULL)
    {
      const char *name;
      while ((name = g_dir_read_name (dir)) != NULL)
        {
          g_autofree char *kid = g_build_filename (path, name, NULL);
          lk_remove_tree (kid);
        }
      g_dir_close (dir);
    }
  /* g_remove takes a file or an empty directory, which is what the walk above
     leaves behind. */
  return g_remove (path) == 0;
}

static gpointer
lk_trash_worker (gpointer data)
{
  char *path = data;

  lk_remove_tree (path);
  g_free (path);
  return NULL;
}

gboolean
lk_chart_bake_delete_derived (const char *path)
{
  const char *root = lk_chart_bake_root ();

  /* Refuses anything this app did not make. A mariner's own folder is never
     touched by removing a set. */
  if (!lk_chart_bake_is_derived (path) || g_strcmp0 (path, root) == 0)
    return FALSE;
  if (!g_file_test (path, G_FILE_TEST_EXISTS))
    return FALSE;

  /* Rename first, delete behind. A large library is tens of thousands of
     files, and doing that inline reads as the app hanging. The rename is one
     step, so the charts are gone from where anything looks for them before
     this returns, and a set added straight back writes into a fresh directory
     instead of racing the delete. */
  g_autofree char *uuid = g_uuid_string_random ();
  g_autofree char *leaf = g_strconcat (LK_TRASH_PREFIX, uuid, NULL);
  g_autofree char *trash = g_build_filename (root, leaf, NULL);

  if (g_rename (path, trash) != 0)
    {
      /* Nowhere to rename it to. Still not on this thread. */
      GThread *t = g_thread_new ("lk-trash", lk_trash_worker, g_strdup (path));
      g_thread_unref (t);
      return TRUE;
    }

  GThread *t = g_thread_new ("lk-trash", lk_trash_worker, g_steal_pointer (&trash));
  g_thread_unref (t);
  return TRUE;
}

void
lk_chart_bake_sweep_trash (void)
{
  const char *root = lk_chart_bake_root ();
  g_autoptr (GDir) dir = g_dir_open (root, 0, NULL);

  if (dir == NULL)
    return;

  const char *name;
  while ((name = g_dir_read_name (dir)) != NULL)
    {
      if (!g_str_has_prefix (name, LK_TRASH_PREFIX))
        continue;
      GThread *t = g_thread_new ("lk-trash", lk_trash_worker,
                                 g_build_filename (root, name, NULL));
      g_thread_unref (t);
    }
}

/* ---- the bake ------------------------------------------------------------ */

static LkPrepare
lk_prepare_for (const LkScannedCell *cell)
{
  if (g_strcmp0 (cell->kind, "source") == 0)
    return LK_PREPARE_CELL;
  if (g_strcmp0 (cell->kind, "raster_source") == 0)
    return LK_PREPARE_SHEET;
  return LK_PREPARE_LIFT;
}

/* Coarse first, then by name so a run is repeatable. Sheets after the survey,
 * because that is what a mariner needs to sail and a picture is what they
 * compare it against, and anything only being lifted out of an archive last:
 * it is the cheapest and the least urgent. */
static int
lk_cell_order (gconstpointer a, gconstpointer b)
{
  const LkScannedCell *x = *(const LkScannedCell *const *) a;
  const LkScannedCell *y = *(const LkScannedCell *const *) b;
  LkPrepare px = lk_prepare_for (x);
  LkPrepare py = lk_prepare_for (y);

  if (px != py)
    return px < py ? -1 : 1;
  if (x->band != y->band)
    return x->band < y->band ? -1 : 1;
  return g_strcmp0 (x->name, y->name);
}

/* Every prepared chart goes in a directory of its own name, the layout
 * tile57's own bake writes and the layout an exchange set uses. Two things
 * depend on it: the raster layer reads a provider from the directory ABOVE, so
 * sheets written flat become one provider each, and a cell carries the text
 * and pictures it references beside it, which the engine only writes when the
 * chart has a directory to hold them.
 *
 * From an archive the output MIRRORS the entry's own path, so what comes out
 * is laid out like what went in. Imagery keeps its own name: an .mbtiles is a
 * chart already, and renaming it to .pmtiles would be a lie about the file. */
static char *
lk_bake_out_path (const LkChartBake *bake, const LkScannedCell *cell)
{
  g_autofree char *stem = g_strdup (cell->name);
  char *dot = g_strrstr (stem, ".");
  if (dot != NULL)
    *dot = '\0';

  g_autofree char *base = NULL;
  if (bake->archive)
    {
      g_autofree char *parent = g_path_get_dirname (cell->path);
      base = g_strcmp0 (parent, ".") == 0 ? g_strdup (bake->out_dir)
                                          : g_build_filename (bake->out_dir, parent, NULL);
    }
  else
    {
      base = g_strdup (bake->out_dir);
    }

  LkPrepare prepare = lk_prepare_for (cell);
  g_autofree char *base_leaf = g_path_get_basename (base);
  /* Unless the mirrored path IS the chart's directory already, which it is for
     every exchange set: appending it again gives US1EEZ3M/US1EEZ3M/... */
  g_autofree char *dir = (prepare == LK_PREPARE_LIFT || g_strcmp0 (base_leaf, stem) == 0)
                             ? g_strdup (base)
                             : g_build_filename (base, stem, NULL);

  g_mkdir_with_parents (dir, 0755);

  g_autofree char *leaf = NULL;
  if (prepare == LK_PREPARE_LIFT)
    leaf = g_path_get_basename (cell->path);
  else
    leaf = g_strconcat (stem, ".pmtiles", NULL);

  return g_build_filename (dir, leaf, NULL);
}

typedef struct {
  LkChartBake   *bake;
  LkBakeProgress progress;
} LkBakePost;

static gboolean
lk_bake_post_idle (gpointer data)
{
  LkBakePost *post = data;

  if (post->bake->on_progress != NULL)
    post->bake->on_progress (&post->progress, post->bake->user_data);

  lk_bake_progress_clear (&post->progress);
  g_free (post);
  return G_SOURCE_REMOVE;
}

/* Called on tile57's worker threads, out of order, so everything it touches is
 * behind the lock. Returning false CANCELS the bake. */
static bool
lk_bake_progress_cb (void *ctx, uint32_t done, uint32_t total)
{
  LkChartBake *bake = ctx;
  gint64 now = g_get_monotonic_time ();
  gboolean post = FALSE;

  g_mutex_lock (&bake->lock);
  bake->done = bake->phase_offset + (int) done;
  if (now - bake->last_post_us >= LK_BAKE_POST_INTERVAL_US ||
      bake->done >= bake->job_total)
    {
      bake->last_post_us = now;
      post = TRUE;
    }
  LkBakePost *msg = NULL;
  if (post)
    {
      msg = g_new0 (LkBakePost, 1);
      msg->bake = bake;
      msg->progress.kind = LK_BAKE_IMPORTING;
      msg->progress.done = bake->done;
      msg->progress.total = bake->job_total;
      msg->progress.name = g_strdup (bake->name);
      msg->progress.cell = g_strdup (bake->last_cell);
      msg->progress.elapsed = (double) (now - bake->started_us) / G_USEC_PER_SEC;
    }
  g_mutex_unlock (&bake->lock);

  (void) total;
  if (msg != NULL)
    g_idle_add (lk_bake_post_idle, msg);

  return g_atomic_int_get (&bake->cancelled) == 0;
}

/* Names the chart that just finished, by its index into the caller's paths for
 * THIS call, which is why the phase offset goes back on. */
static void
lk_bake_label_cb (void *ctx, uint32_t index)
{
  LkChartBake *bake = ctx;

  g_mutex_lock (&bake->lock);
  guint at = bake->phase_offset + index;
  if (at < bake->labels->len)
    {
      g_free (bake->last_cell);
      bake->last_cell = g_strdup (g_ptr_array_index (bake->labels, at));
    }
  g_mutex_unlock (&bake->lock);
}

/* The engine names and counts from zero for each call; the job puts them back
 * on the mariner's scale. */
static void
lk_bake_begin_phase (LkChartBake *bake, int offset)
{
  g_mutex_lock (&bake->lock);
  bake->phase_offset = offset;
  g_mutex_unlock (&bake->lock);
}

static gboolean
lk_bake_done_idle (gpointer data)
{
  LkChartBake *bake = data;

  if (bake->on_done != NULL)
    bake->on_done (bake->ok ? bake->out_dir : NULL, bake->baked, bake->user_data);
  return G_SOURCE_REMOVE;
}

/* Run each kind of work through the engine call that does it, and report the
 * lot as one job. From an archive each input is an ENTRY NAME and the engine
 * reads it where it lies: nothing is unzipped, so importing NOAA's 788 MB
 * All_ENCs.zip never costs the 2.0 GiB of source it holds. */
static gpointer
lk_bake_worker (gpointer data)
{
  LkChartBake *bake = data;
  const char *const *ins = (const char *const *) bake->in_paths->pdata;
  const char *const *outs = (const char *const *) bake->out_paths->pdata;
  uint32_t workers = (uint32_t) CLAMP (g_get_num_processors (), 1, LK_BAKE_MAX_WORKERS);
  tile57_error err = { 0 };
  tile57_status st = TILE57_OK;
  uint32_t total = 0;
  uint32_t n = 0;

  if (bake->cell_count > 0)
    {
      lk_bake_begin_phase (bake, 0);
      st = bake->archive
               ? tile57_bake_zip_charts (bake->source, ins, outs, bake->cell_count, workers,
                                         lk_bake_progress_cb, lk_bake_label_cb, bake, &n, &err)
               : tile57_bake_files (ins, outs, bake->cell_count, workers,
                                    lk_bake_progress_cb, lk_bake_label_cb, bake, &n, &err);
      total += n;
    }

  if (st == TILE57_OK && bake->sheet_count > 0)
    {
      int off = bake->cell_count;
      lk_bake_begin_phase (bake, off);
      n = 0;
      st = bake->archive
               ? tile57_bake_zip_rasters (bake->source, ins + off, outs + off, bake->sheet_count,
                                          workers, lk_bake_progress_cb, lk_bake_label_cb, bake, &n, &err)
               : tile57_bake_rasters (ins + off, outs + off, bake->sheet_count, workers,
                                      lk_bake_progress_cb, lk_bake_label_cb, bake, &n, &err);
      total += n;
    }

  /* Only an archive has anything to lift: in a folder these files are already
     where the engine can read them. */
  if (st == TILE57_OK && bake->archive && bake->lift_count > 0)
    {
      int off = bake->cell_count + bake->sheet_count;
      lk_bake_begin_phase (bake, off);
      n = 0;
      st = tile57_zip_extract (bake->source, ins + off, outs + off, bake->lift_count,
                               lk_bake_progress_cb, bake, &n, &err);
      total += n;
    }

  bake->baked = total;
  /* A cancelled bake is TILE57_OK, not a failure: whatever landed is a usable
     library, so the caller still gets the directory. */
  bake->ok = (st == TILE57_OK);
  g_idle_add (lk_bake_done_idle, bake);
  return NULL;
}

LkChartBake *
lk_chart_bake_start (const char        *source,
                     const LkChartSet  *set,
                     LkBakeProgressFunc on_progress,
                     LkBakeDoneFunc     on_done,
                     gpointer           user_data)
{
  if (source == NULL || set == NULL || set->cells == NULL)
    return NULL;

  g_autoptr (GPtrArray) ordered = g_ptr_array_new ();
  for (guint i = 0; i < set->cells->len; i++)
    {
      LkScannedCell *cell = g_ptr_array_index (set->cells, i);
      if (lk_scanned_cell_needs_prepare (cell))
        g_ptr_array_add (ordered, cell);
    }
  if (ordered->len == 0)
    return NULL;
  g_ptr_array_sort (ordered, lk_cell_order);

  char *out_dir = lk_chart_bake_output_dir (source);
  if (out_dir == NULL)
    return NULL;

  LkChartBake *bake = g_new0 (LkChartBake, 1);
  g_mutex_init (&bake->lock);
  bake->source = g_strdup (source);
  bake->out_dir = out_dir;
  bake->name = g_path_get_basename (source);
  bake->archive = lk_chart_scan_is_archive (source);
  bake->in_paths = g_ptr_array_new_with_free_func (g_free);
  bake->out_paths = g_ptr_array_new_with_free_func (g_free);
  bake->labels = g_ptr_array_new_with_free_func (g_free);
  bake->on_progress = on_progress;
  bake->on_done = on_done;
  bake->user_data = user_data;
  bake->job_total = (int) ordered->len;
  bake->started_us = g_get_monotonic_time ();

  for (guint i = 0; i < ordered->len; i++)
    {
      const LkScannedCell *cell = g_ptr_array_index (ordered, i);
      LkPrepare prepare = lk_prepare_for (cell);

      g_ptr_array_add (bake->in_paths, g_strdup (cell->path));
      g_ptr_array_add (bake->out_paths, lk_bake_out_path (bake, cell));
      g_ptr_array_add (bake->labels, g_strdup (cell->name));

      switch (prepare)
        {
        case LK_PREPARE_CELL:  bake->cell_count++;  break;
        case LK_PREPARE_SHEET: bake->sheet_count++; break;
        case LK_PREPARE_LIFT:  bake->lift_count++;  break;
        }
    }

  bake->thread = g_thread_new ("lk-chart-bake", lk_bake_worker, bake);
  return bake;
}

void
lk_chart_bake_cancel (LkChartBake *bake)
{
  if (bake != NULL)
    g_atomic_int_set (&bake->cancelled, 1);
}
