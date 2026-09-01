#include "library/bake.h"

#include <glib/gstdio.h>
#include <string.h>

/* How often the panel is laid out again. A 7,000 cell import would otherwise
 * post 7,000 times, on a machine with nothing spare. */
#define LK_BAKE_POLL_MS 200

struct _LkChartBake {
  /* The core's job: the worker, the phases, the counters and the cancel. */
  lookout_bake *job;

  char *out_dir;
  char *name;
  gint64 started_us;

  guint poll_id;
  int   posted_done; /* the last count handed to on_progress */

  LkBakeProgressFunc on_progress;
  LkBakeDoneFunc on_done;
  gpointer user_data;
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

  /* A count means the charts have been found and are being converted. */
  return p->total > 0 ? g_strdup_printf ("Importing %s", name)
                      : g_strdup_printf ("Finding charts in %s", name);
}

char *
lk_bake_progress_remaining (const LkBakeProgress *p)
{
  if (p == NULL)
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
  if (path == NULL)
    return FALSE;
  return lookout_bake_is_derived (lk_chart_bake_root (), path) != 0;
}

char *
lk_chart_bake_prepared_dir (const char *source)
{
  char name[512];

  if (source == NULL || lookout_bake_prepared_name (source, name, sizeof name) == 0)
    return NULL;
  return g_build_filename (lk_chart_bake_root (), name, NULL);
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
  /* A symlink is removed, never followed: the walk must stay inside the
   * prepared tree whatever a lifted archive managed to put in it. */
  if (g_file_test (path, G_FILE_TEST_IS_SYMLINK))
    return g_remove (path) == 0;

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
  g_autofree char *leaf = g_strconcat (lookout_bake_trash_prefix (), uuid, NULL);
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
      if (!lookout_bake_is_trash (name))
        continue;
      GThread *t = g_thread_new ("lk-trash", lk_trash_worker,
                                 g_build_filename (root, name, NULL));
      g_thread_unref (t);
    }
}

/* ---- the bake ------------------------------------------------------------ */

/* The core runs the bake: the order, the worker cap, the three phases, the
 * counters and the cancel are all lookout_bake's. What is left here is the
 * directory the shell prepares into, the poll that feeds the pill, and the
 * wording that pill reads. */

static lookout_prepare
lk_prepare_for (const LkScannedCell *cell)
{
  if (cell->kind == LOOKOUT_FILE_SOURCE)
    return LOOKOUT_PREPARE_CELL;
  if (cell->kind == LOOKOUT_FILE_RASTER_SOURCE)
    return LOOKOUT_PREPARE_SHEET;
  return LOOKOUT_PREPARE_LIFT;
}

static void
lk_chart_bake_free (LkChartBake *bake)
{
  if (bake == NULL)
    return;
  g_clear_handle_id (&bake->poll_id, g_source_remove);
  if (bake->job != NULL)
    {
      lookout_bake_cancel (bake->job);
      lookout_bake_free (bake->job);
    }
  g_free (bake->out_dir);
  g_free (bake->name);
  g_free (bake);
}

/* One look at the job, on the main loop. The pill wants a fraction and a time
 * left; the done callback wants the directory and how many landed. */
static gboolean
lk_chart_bake_poll (gpointer data)
{
  LkChartBake *bake = data;
  lookout_bake_progress got;

  lookout_bake_poll (bake->job, &got);

  if (bake->on_progress != NULL && (int) got.done != bake->posted_done)
    {
      gint64 now = g_get_monotonic_time ();
      LkBakeProgress progress = {
        .done = (int) got.done,
        .total = (int) got.total,
        .name = bake->name,
        .elapsed = (double) (now - bake->started_us) / G_USEC_PER_SEC,
      };

      bake->posted_done = (int) got.done;
      bake->on_progress (&progress, bake->user_data);
    }

  if (got.running)
    return G_SOURCE_CONTINUE;

  /* A cancelled bake reports ok: whatever landed is a usable library, so the
   * caller still gets the directory. */
  bake->poll_id = 0;
  if (bake->on_done != NULL)
    bake->on_done (got.ok ? bake->out_dir : NULL, got.baked, bake->user_data);
  return G_SOURCE_REMOVE;
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

  g_autoptr (GArray) items = g_array_new (FALSE, FALSE, sizeof (lookout_bake_item));
  for (guint i = 0; i < set->cells->len; i++)
    {
      const LkScannedCell *cell = g_ptr_array_index (set->cells, i);

      if (!lk_scanned_cell_needs_prepare (cell))
        continue;

      lookout_bake_item item = {
        .path = cell->path,
        .name = cell->name,
        .band = cell->band,
        .work = lk_prepare_for (cell),
      };
      g_array_append_val (items, item);
    }
  if (items->len == 0)
    return NULL;

  /* Coarse band first, sheets after the survey, lifts last, by name within
   * that. A mariner who cancels half way then has charts covering the whole
   * passage at a usable scale. */
  lookout_bake_order ((lookout_bake_item *) items->data, items->len);

  g_autofree char *out_dir = lk_chart_bake_output_dir (source);
  if (out_dir == NULL)
    return NULL;

  gboolean archive = lk_chart_scan_is_archive (source);
  g_autoptr (GPtrArray) ins = g_ptr_array_new_with_free_func (g_free);
  g_autoptr (GPtrArray) outs = g_ptr_array_new_with_free_func (g_free);
  size_t cells = 0, sheets = 0, lifts = 0;

  for (guint i = 0; i < items->len; i++)
    {
      const lookout_bake_item *item = &g_array_index (items, lookout_bake_item, i);
      char path[2048];

      if (lookout_bake_output_path (out_dir, source, item, path, sizeof path) == 0)
        continue;

      /* Already made. A source always reports its cells as needing preparing —
         a .zip of raw cells says so however many times it is opened — so
         without this every reopen bakes the whole set again. Re-importing one
         chart must not re-bake the rest. */
      if (g_file_test (path, G_FILE_TEST_EXISTS))
        continue;

      /* Only now is the chart's own directory worth making. */
      g_autofree char *dir = g_path_get_dirname (path);
      g_mkdir_with_parents (dir, 0755);

      g_ptr_array_add (ins, g_strdup (item->path));
      g_ptr_array_add (outs, g_strdup (path));
      switch (item->work)
        {
        case LOOKOUT_PREPARE_CELL:  cells++;  break;
        case LOOKOUT_PREPARE_SHEET: sheets++; break;
        case LOOKOUT_PREPARE_LIFT:  lifts++;  break;
        }
    }

  /* Every cell was prepared already: the caller opens what is there. */
  if (ins->len == 0)
    return NULL;

  g_ptr_array_add (ins, NULL);
  g_ptr_array_add (outs, NULL);

  LkChartBake *bake = g_new0 (LkChartBake, 1);

  bake->out_dir = g_steal_pointer (&out_dir);
  bake->name = g_path_get_basename (source);
  bake->started_us = g_get_monotonic_time ();
  bake->posted_done = -1;
  bake->on_progress = on_progress;
  bake->on_done = on_done;
  bake->user_data = user_data;
  bake->job = lookout_bake_start (source, (const char *const *) ins->pdata,
                                  (const char *const *) outs->pdata,
                                  cells, sheets, lifts, archive ? 1 : 0);
  if (bake->job == NULL)
    {
      lk_chart_bake_free (bake);
      return NULL;
    }

  bake->poll_id = g_timeout_add (LK_BAKE_POLL_MS, lk_chart_bake_poll, bake);
  return bake;
}

void
lk_chart_bake_cancel (LkChartBake *bake)
{
  if (bake != NULL && bake->job != NULL)
    lookout_bake_cancel (bake->job);
}

void
lk_chart_bake_destroy (LkChartBake *bake)
{
  /* lookout_bake_free cancels and joins, so a running bake stops at the next
   * chart boundary and nothing outlives this call. */
  lk_chart_bake_free (bake);
}
