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

  /* The bands, in the order the bake works them, with a running total so a
   * done count can be split across them. */
  LkBakeBand bands[7];
  guint      n_bands;

  LkBakeProgressFunc on_progress;
  LkBakeDoneFunc on_done;
  gpointer user_data;
};

/* ---- progress ------------------------------------------------------------ */

void
lk_bake_bands_advance (LkBakeBand *bands, guint n, guint done)
{
  guint reached = done;

  g_return_if_fail (bands != NULL || n == 0);

  for (guint i = 0; i < n; i++)
    {
      bands[i].done = MIN (reached, bands[i].total);
      reached -= bands[i].done;
    }
}

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

  if (p->kind == LK_BAKE_REMOVE)
    return g_strdup_printf ("Removing %s", name);

  /* A count means the charts have been found and are being converted. */
  return p->total > 0 ? g_strdup_printf ("Importing %s", name)
                      : g_strdup_printf ("Finding charts in %s", name);
}

char *
lk_bake_progress_remaining (const LkBakeProgress *p)
{
  if (p == NULL || p->kind == LK_BAKE_REMOVE)
    return NULL;
  if (p->done < 3 || p->total <= p->done || p->elapsed <= 1)
    return NULL;

  double per = p->elapsed / (double) p->done;
  char left[LOOKOUT_DURATION_MAX];

  lookout_fmt_duration (per * (double) (p->total - p->done), LOOKOUT_DURATION_LEFT, left,
                        sizeof left);
  return g_strdup (left);
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

/* One removal running behind the app. The worker writes the counts, the main
 * thread reads them and draws them. */
typedef struct {
  char              *path;  /* the renamed directory being emptied */
  char              *name; /* the set the mariner removed, for the report */
  LkBakeProgressFunc on_progress;
  /* REFFED. A removal is thousands of files and outlives the window that
   * asked for it, and the report writes into the owner. */
  GObject           *owner;
  gint64             started_us;

  GMutex   mu;
  int      done;
  int      total;
  gboolean over;
  gboolean posted; /* a report is already on its way to the main thread */
  gint     refs;
} LkTrash;

static void
lk_trash_unref (LkTrash *self)
{
  if (!g_atomic_int_dec_and_test (&self->refs))
    return;
  g_mutex_clear (&self->mu);
  g_free (self->path);
  g_free (self->name);
  g_clear_object (&self->owner);
  g_free (self);
}

/* On the main thread, so the count can be drawn straight from it. */
static gboolean
lk_trash_report (gpointer data)
{
  LkTrash *self = data;
  LkBakeProgress progress = { 0 };
  gboolean over;

  g_mutex_lock (&self->mu);
  self->posted = FALSE;
  progress.done = self->done;
  progress.total = self->total;
  over = self->over;
  g_mutex_unlock (&self->mu);

  progress.kind = LK_BAKE_REMOVE;
  /* An empty name is the last word: it is what takes the panel away. */
  progress.name = over ? "" : self->name;
  progress.elapsed = (g_get_monotonic_time () - self->started_us) / 1e6;
  if (self->on_progress != NULL)
    self->on_progress (&progress, self->owner);

  lk_trash_unref (self);
  return G_SOURCE_REMOVE;
}

/* Ask for one report. A removal is thousands of directories and nobody reads
 * thousands of reports, so a count that moves while one is still on its way
 * rides along with it rather than queueing another. */
static void
lk_trash_post (LkTrash *self, gboolean always)
{
  gboolean post;

  g_mutex_lock (&self->mu);
  post = always || !self->posted;
  self->posted = TRUE;
  g_mutex_unlock (&self->mu);

  if (!post || self->on_progress == NULL)
    return;
  g_atomic_int_inc (&self->refs);
  g_idle_add (lk_trash_report, self);
}

static gpointer
lk_trash_worker (gpointer data)
{
  LkTrash *self = data;
  g_autoptr (GPtrArray) charts = g_ptr_array_new_with_free_func (g_free);

  GDir *dir = g_dir_open (self->path, 0, NULL);

  /* ONE LISTING of the top level. The bake writes a directory per chart, so
   * each entry is one chart, the unit the import counted. The count needs no
   * read of the thirty thousand files below. */
  if (dir != NULL)
    {
      const char *name;

      while ((name = g_dir_read_name (dir)) != NULL)
        g_ptr_array_add (charts, g_build_filename (self->path, name, NULL));
      g_dir_close (dir);
    }

  g_mutex_lock (&self->mu);
  self->total = (int) charts->len;
  g_mutex_unlock (&self->mu);
  lk_trash_post (self, FALSE);

  for (guint i = 0; i < charts->len; i++)
    {
      const char *chart = g_ptr_array_index (charts, i);

      lk_remove_tree (chart);
      g_mutex_lock (&self->mu);
      self->done = (int) (i + 1);
      g_mutex_unlock (&self->mu);
      lk_trash_post (self, FALSE);
    }

  /* Whatever the listing missed, and the directory itself. */
  lk_remove_tree (self->path);

  g_mutex_lock (&self->mu);
  self->over = TRUE;
  g_mutex_unlock (&self->mu);
  lk_trash_post (self, TRUE);

  lk_trash_unref (self);
  return NULL;
}

/* Start one, on a thread of its own. Takes `path`. */
static void
lk_trash_start (char *path, const char *name, LkBakeProgressFunc on_progress,
                GObject *owner)
{
  LkTrash *self = g_new0 (LkTrash, 1);
  GThread *thread;

  g_mutex_init (&self->mu);
  self->path = path;
  self->name = g_strdup (name != NULL ? name : "");
  self->on_progress = on_progress;
  self->owner = owner != NULL ? g_object_ref (owner) : NULL;
  self->started_us = g_get_monotonic_time ();
  self->refs = 1;

  thread = g_thread_new ("lk-trash", lk_trash_worker, self);
  g_thread_unref (thread);
}

gboolean
lk_chart_bake_delete_derived (const char *path, const char *name,
                              LkBakeProgressFunc on_progress, GObject *owner)
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
      lk_trash_start (g_strdup (path), name, on_progress, owner);
      return TRUE;
    }

  lk_trash_start (g_steal_pointer (&trash), name, on_progress, owner);
  return TRUE;
}

/* ---- the bake ------------------------------------------------------------ */

/* The core runs the bake: the order, the worker cap, the three phases, the
 * counters and the cancel are all lookout_bake's. What is left here is the
 * directory the shell prepares into, the poll that feeds the pill, and the
 * wording that pill reads. */
const lookout_bake *
lk_chart_bake_job (LkChartBake *bake)
{
  return bake != NULL ? bake->job : NULL;
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

      lk_bake_bands_advance (bake->bands, bake->n_bands, got.done);
      progress.bands = bake->bands;
      progress.n_bands = bake->n_bands;

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

/* The work one scan row states. */
static lookout_prepare
lk_prepare_for_kind (lookout_file_kind kind)
{
  if (kind == LOOKOUT_FILE_SOURCE)
    return LOOKOUT_PREPARE_CELL;
  if (kind == LOOKOUT_FILE_RASTER_SOURCE)
    return LOOKOUT_PREPARE_SHEET;
  return LOOKOUT_PREPARE_LIFT;
}

LkChartBake *
lk_chart_bake_start (const char        *source,
                     LkChartSets       *sets,
                     LkBakeProgressFunc on_progress,
                     LkBakeDoneFunc     on_done,
                     gpointer           user_data)
{
  if (source == NULL)
    return NULL;

  g_autoptr (GArray) items = g_array_new (FALSE, FALSE, sizeof (lookout_bake_item));
  gsize n_listed = 0;
  const lookout_chart_file *const *listed =
      lk_chart_sets_to_prepare (sets, source, &n_listed);

  for (gsize i = 0; i < n_listed; i++)
    {
      const lookout_chart_file *file = listed[i];
      lookout_bake_item item = {
        .path = file->path,
        .name = file->name,
        .band = file->band,
        .work = lk_prepare_for_kind (file->kind),
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

  /* The bands, in the order above. A band appears once, where its first chart
   * falls. */
  LkBakeBand bands[7] = { 0 };
  guint n_bands = 0;
  for (guint i = 0; i < items->len; i++)
    {
      const lookout_bake_item *item = &g_array_index (items, lookout_bake_item, i);
      int band = item->band >= 1 && item->band <= 6 ? item->band : 0;
      gboolean seen = FALSE;

      for (guint b = 0; b < n_bands; b++)
        {
          if (bands[b].band != band)
            continue;
          bands[b].total++;
          seen = TRUE;
          break;
        }
      if (!seen && n_bands < G_N_ELEMENTS (bands))
        bands[n_bands++] = (LkBakeBand) { .band = band, .total = 1, .done = 0 };
    }

  gboolean archive = lk_chart_scan_is_archive (source);
  g_autoptr (GPtrArray) ins = g_ptr_array_new_with_free_func (g_free);
  g_autoptr (GPtrArray) outs = g_ptr_array_new_with_free_func (g_free);
  size_t cells = 0, sheets = 0, lifts = 0;

  for (guint i = 0; i < items->len; i++)
    {
      const lookout_bake_item *item = &g_array_index (items, lookout_bake_item, i);
      char path[2048];

      if (lookout_bake_output_path (out_dir, source, item, path, sizeof path) == 0)
        {
          /* Nowhere to write it that fits. Say so rather than leaving one
             chart quietly out of the library. */
          g_warning ("no output path for %s under %s", item->name, out_dir);
          continue;
        }

      /* The chart's own directory. Every item here still needs preparing,
         because lk_chart_bake_to_prepare dropped the rest. */
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
  memcpy (bake->bands, bands, sizeof bands);
  bake->n_bands = n_bands;
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
