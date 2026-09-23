/* library/noaa.c — NOAA's charts. See library/noaa.h. */
#include "library/noaa.h"

#include "library/fetch.h"
#include "model/store.h"

#include <string.h>

/* The shortest gap between two reads of a transfer's progress. A piece of a
 * transfer does not wake the service, so the pieces drive these reads. */
#define LK_NOAA_PROGRESS_MS 250

struct _LkNoaa {
  GObject parent_instance;

  lookout_noaa *service;
  LkFetcher    *fetcher;
  /* 1 while an idle is queued to read the state after a wake. */
  gint          wake_queued;
  /* When a transfer's piece last read the state, in monotonic microseconds. */
  gint64        progress_us;

  /* The region table. The core's strings are static, so the rows hold them
   * rather than copies. */
  LkNoaaRegion *regions;
  guint         n_regions;

  /* The ids picked, as a set. Keys are the static region ids. */
  GHashTable *picked;

  lookout_noaa_state state;

  /* Each region's real coverage, read once when the catalog lands.
   * id -> GArray of LkNoaaBox. */
  GHashTable *coverage;

  /* What the pick costs, refreshed whenever the pick changes. */
  guint32 cells, held;
  guint64 bytes, held_bytes;

  /* How much of each region is already installed, indexed as `regions`. Read
   * when the catalog lands and when what is installed changes, because each
   * region costs a walk of the catalog and the pick does not move it. */
  guint32 *region_cells;
  guint32 *region_held;
  gboolean regions_costed;
  /* The dataset names the downloader's own set holds. */
  GHashTable *managed;
};

enum {
  SIGNAL_CHANGED,
  N_SIGNALS
};

static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE (LkNoaa, lk_noaa, G_TYPE_OBJECT)

static void lk_noaa_recost (LkNoaa *self);
static void lk_noaa_recost_regions (LkNoaa *self);

/* ---- the region table ---------------------------------------------------- */

static void
lk_noaa_read_regions (LkNoaa *self)
{
  const lookout_noaa_region *all = NULL;
  size_t n = lookout_noaa_regions (&all);

  if (all == NULL || n == 0)
    return;

  self->regions = g_new0 (LkNoaaRegion, n);
  self->n_regions = (guint) n;
  for (size_t i = 0; i < n; i++)
    {
      self->regions[i].id = all[i].id;
      self->regions[i].name = all[i].name;
      self->regions[i].blurb = all[i].blurb;
      self->regions[i].district = all[i].district;
      self->regions[i].west = all[i].west;
      self->regions[i].south = all[i].south;
      self->regions[i].east = all[i].east;
      self->regions[i].north = all[i].north;
    }
}

const LkNoaaRegion *
lk_noaa_regions (LkNoaa *self, guint *out_n)
{
  g_return_val_if_fail (LK_IS_NOAA (self), NULL);

  if (out_n != NULL)
    *out_n = self->n_regions;
  return self->regions;
}

const LkNoaaRegion *
lk_noaa_region (LkNoaa *self, const char *id)
{
  g_return_val_if_fail (LK_IS_NOAA (self), NULL);

  if (id == NULL)
    return NULL;
  for (guint i = 0; i < self->n_regions; i++)
    {
      if (g_strcmp0 (self->regions[i].id, id) == 0)
        return &self->regions[i];
    }
  return NULL;
}

/* ---- the pick ------------------------------------------------------------ */

gboolean
lk_noaa_is_picked (LkNoaa *self, const char *id)
{
  g_return_val_if_fail (LK_IS_NOAA (self), FALSE);

  return id != NULL && g_hash_table_contains (self->picked, id);
}

void
lk_noaa_toggle (LkNoaa *self, const char *id)
{
  const LkNoaaRegion *region;

  g_return_if_fail (LK_IS_NOAA (self));

  /* By the table's own id, never the caller's copy: the set borrows its keys. */
  region = lk_noaa_region (self, id);
  if (region == NULL)
    return;

  if (!g_hash_table_remove (self->picked, region->id))
    g_hash_table_add (self->picked, (gpointer) region->id);

  lk_noaa_recost (self);
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

void
lk_noaa_clear_picks (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  if (g_hash_table_size (self->picked) == 0)
    return;
  g_hash_table_remove_all (self->picked);
  lk_noaa_recost (self);
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

guint
lk_noaa_picked_count (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), 0);
  return g_hash_table_size (self->picked);
}

/* In REGION ORDER, not click order, so the same pick always reads the same
 * way and a cost is comparable between two asks. */
char *
lk_noaa_picked_ids (LkNoaa *self)
{
  GString *out;

  g_return_val_if_fail (LK_IS_NOAA (self), g_strdup (""));

  out = g_string_new (NULL);
  for (guint i = 0; i < self->n_regions; i++)
    {
      if (!g_hash_table_contains (self->picked, self->regions[i].id))
        continue;
      if (out->len > 0)
        g_string_append_c (out, ',');
      g_string_append (out, self->regions[i].id);
    }
  return g_string_free (out, FALSE);
}

/* ---- the snapshot -------------------------------------------------------- */

const lookout_noaa_state *
lk_noaa_state (LkNoaa *self)
{
  static const lookout_noaa_state empty = { 0 };

  g_return_val_if_fail (LK_IS_NOAA (self), &empty);
  return &self->state;
}

/* Every region's coverage. The catalog holds it and does not change while it
 * is loaded, so this runs once. */
static void
lk_noaa_load_coverage (LkNoaa *self)
{
  g_hash_table_remove_all (self->coverage);

  for (guint i = 0; i < self->n_regions; i++)
    {
      const char *id = self->regions[i].id;
      /* Ask once for the count, then once for the boxes. */
      gsize n = lookout_noaa_region_coverage (self->service, id, NULL, 0);
      if (n == 0)
        continue;

      g_autofree lookout_noaa_box *raw = g_new0 (lookout_noaa_box, n);
      gsize got = lookout_noaa_region_coverage (self->service, id, raw, n);
      GArray *boxes = g_array_sized_new (FALSE, FALSE, sizeof (LkNoaaBox), MIN (got, n));

      for (gsize b = 0; b < MIN (got, n); b++)
        {
          LkNoaaBox box = { raw[b].west, raw[b].south, raw[b].east, raw[b].north };
          g_array_append_val (boxes, box);
        }
      g_hash_table_insert (self->coverage, (gpointer) id, boxes);
    }
}

const LkNoaaBox *
lk_noaa_coverage (LkNoaa *self, const char *id, guint *out_n)
{
  GArray *boxes;

  g_return_val_if_fail (LK_IS_NOAA (self), NULL);

  if (out_n != NULL)
    *out_n = 0;
  if (id == NULL)
    return NULL;
  boxes = g_hash_table_lookup (self->coverage, id);
  if (boxes == NULL)
    return NULL;
  if (out_n != NULL)
    *out_n = boxes->len;
  return (const LkNoaaBox *) boxes->data;
}

void
lk_noaa_sync (LkNoaa *self)
{
  gboolean had_catalog;

  g_return_if_fail (LK_IS_NOAA (self));

  had_catalog = self->state.have_catalog;
  if (self->service == NULL || !lookout_noaa_changed (self->service))
    return;
  lookout_noaa_poll (self->service, &self->state);
  if (self->state.have_catalog && !had_catalog)
    {
      lk_noaa_recost_regions (self);
      lk_noaa_recost (self);
      lk_noaa_load_coverage (self);
    }
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

static gboolean
lk_noaa_woken (gpointer data)
{
  LkNoaa *self = data;

  g_atomic_int_set (&self->wake_queued, 0);
  lk_noaa_sync (self);
  return G_SOURCE_REMOVE;
}

/* The service's fetcher. The core passes one `user` to get, cancel and wake,
 * so get and cancel reach the LkFetcher through this object. */
static void
lk_noaa_http_get (void *user, uint64_t req_id, const char *url, int allow_file)
{
  lk_fetcher_http_get (((LkNoaa *) user)->fetcher, req_id, url, allow_file);
}

static void
lk_noaa_http_cancel (void *user, uint64_t req_id)
{
  lk_fetcher_http_cancel (((LkNoaa *) user)->fetcher, req_id);
}

/* The service queued a response. Called from any thread, so this queues one
 * idle on the main loop. The idle holds a reference until it runs. */
static void
lk_noaa_wake (void *user)
{
  LkNoaa *self = user;

  if (g_atomic_int_compare_and_exchange (&self->wake_queued, 0, 1))
    g_idle_add_full (G_PRIORITY_DEFAULT_IDLE, lk_noaa_woken, g_object_ref (self),
                     g_object_unref);
}

static void
lk_noaa_respond (gpointer user_data, uint64_t req_id, const void *bytes, gsize len,
                 int status)
{
  LkNoaa *self = user_data;

  lookout_noaa_http_respond_chunk (self->service, req_id, bytes, len, status, 1);
}

static void
lk_noaa_respond_chunk (gpointer user_data, uint64_t req_id, const void *bytes,
                       gsize len, int status, gboolean done)
{
  LkNoaa *self = user_data;
  gint64 now = g_get_monotonic_time ();

  lookout_noaa_http_respond_chunk (self->service, req_id, bytes, len, status,
                                       done ? 1 : 0);
  if (done || now - self->progress_us < LK_NOAA_PROGRESS_MS * 1000)
    return;
  self->progress_us = now;
  lk_noaa_sync (self);
}

/* ---- reading the catalog ------------------------------------------------- */

void
lk_noaa_refresh (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  lookout_noaa_refresh (self->service);
  lk_noaa_sync (self);
}

/* ---- what a pick costs --------------------------------------------------- */

/* What each region holds, counted against the downloader's own set. */
static void
lk_noaa_recost_regions (LkNoaa *self)
{
  self->regions_costed = FALSE;
  if (self->regions == NULL || self->n_regions == 0)
    return;

  if (self->region_cells == NULL)
    {
      self->region_cells = g_new0 (guint32, self->n_regions);
      self->region_held = g_new0 (guint32, self->n_regions);
    }
  memset (self->region_cells, 0, self->n_regions * sizeof *self->region_cells);
  memset (self->region_held, 0, self->n_regions * sizeof *self->region_held);

  if (!self->state.have_catalog || self->managed == NULL)
    return;

  for (guint i = 0; i < self->n_regions; i++)
    {
      g_auto (GStrv) cells = lk_noaa_region_cells (self, self->regions[i].id);

      for (guint c = 0; cells != NULL && cells[c] != NULL; c++)
        {
          self->region_cells[i]++;
          if (g_hash_table_contains (self->managed, cells[c]))
            self->region_held[i]++;
        }
    }
  self->regions_costed = TRUE;
}

void
lk_noaa_note_managed (LkNoaa *self, const char *const *names)
{
  g_return_if_fail (LK_IS_NOAA (self));

  if (self->managed == NULL)
    self->managed = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  g_hash_table_remove_all (self->managed);
  for (guint i = 0; names != NULL && names[i] != NULL; i++)
    g_hash_table_add (self->managed, g_strdup (names[i]));

  lk_noaa_recost_regions (self);
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

gboolean
lk_noaa_region_held (LkNoaa *self, const char *id, guint32 *out_cells, guint32 *out_held)
{
  if (out_cells != NULL)
    *out_cells = 0;
  if (out_held != NULL)
    *out_held = 0;

  g_return_val_if_fail (LK_IS_NOAA (self), FALSE);

  if (!self->regions_costed || id == NULL)
    return FALSE;

  for (guint i = 0; i < self->n_regions; i++)
    {
      if (g_strcmp0 (self->regions[i].id, id) != 0)
        continue;
      if (out_cells != NULL)
        *out_cells = self->region_cells[i];
      if (out_held != NULL)
        *out_held = self->region_held[i];
      return TRUE;
    }
  return FALSE;
}

static void
lk_noaa_recost (LkNoaa *self)
{
  g_autofree char *ids = NULL;

  self->cells = 0;
  self->bytes = 0;
  self->held = 0;
  self->held_bytes = 0;

  if (!self->state.have_catalog)
    return;

  ids = lk_noaa_picked_ids (self);
  lookout_noaa_cost (self->service, ids, &self->cells, &self->bytes, &self->held,
                        &self->held_bytes);
}

guint32 lk_noaa_cells (LkNoaa *self)      { return LK_IS_NOAA (self) ? self->cells : 0; }
guint64 lk_noaa_bytes (LkNoaa *self)      { return LK_IS_NOAA (self) ? self->bytes : 0; }
guint32 lk_noaa_held (LkNoaa *self)       { return LK_IS_NOAA (self) ? self->held : 0; }
guint64 lk_noaa_held_bytes (LkNoaa *self) { return LK_IS_NOAA (self) ? self->held_bytes : 0; }

gboolean
lk_noaa_all_installed (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), FALSE);
  return self->cells == 0 && self->held > 0;
}


char *
lk_noaa_cost_words (guint32 cells, guint64 bytes, guint32 held, guint64 held_bytes)
{
  /* Water wholly installed prices as a repair, so a number far under the
   * region's size reads as a saving rather than a mistake. */
  if (cells == 0 && held > 0)
    {
      g_autofree char *size = g_format_size (held_bytes);
      return g_strdup_printf ("%u charts, all installed · %s to fetch again", held, size);
    }

  g_autofree char *size = g_format_size (bytes);
  if (held > 0)
    return g_strdup_printf ("%u charts, %s · %u already installed", cells, size, held);
  return g_strdup_printf ("%u charts, %s", cells, size);
}

char **
lk_noaa_region_cells (LkNoaa *self, const char *region_ids)
{
  size_t n;
  char **out;

  g_return_val_if_fail (LK_IS_NOAA (self), g_new0 (char *, 1));

  if (region_ids == NULL || region_ids[0] == '\0')
    return g_new0 (char *, 1);
  n = lookout_noaa_region_cells (self->service, region_ids, NULL, 0);
  if (n == 0)
    return g_new0 (char *, 1);

  g_autofree const char **raw = g_new0 (const char *, n);
  n = lookout_noaa_region_cells (self->service, region_ids, raw, n);
  out = g_new0 (char *, n + 1);
  for (size_t i = 0; i < n; i++)
    out[i] = g_strdup (raw[i]);
  return out;
}

char *
lk_noaa_cost_line (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), g_strdup (""));

  return lk_noaa_cost_words (self->cells, self->bytes, self->held, self->held_bytes);
}

void
lk_noaa_note_installed (LkNoaa *self, const char *const *names)
{
  g_return_if_fail (LK_IS_NOAA (self));

  lookout_noaa_have (self->service, names,
                         names != NULL ? g_strv_length ((char **) names) : 0);
  lk_noaa_recost_regions (self);
  lk_noaa_recost (self);
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

/* ---- downloading --------------------------------------------------------- */

char **
lk_noaa_downloaded_regions (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), g_new0 (char *, 1));
  return lk_store_load_noaa_regions ();
}

void
lk_noaa_forget_downloaded (LkNoaa *self, const char *const *ids)
{
  g_auto (GStrv) was = NULL;
  g_autoptr (GPtrArray) now = g_ptr_array_new ();

  g_return_if_fail (LK_IS_NOAA (self));
  if (ids == NULL || ids[0] == NULL)
    return;

  was = lk_store_load_noaa_regions ();
  for (guint i = 0; was != NULL && was[i] != NULL; i++)
    if (!g_strv_contains (ids, was[i]))
      g_ptr_array_add (now, was[i]);

  g_ptr_array_add (now, NULL);
  lk_store_save_noaa_regions ((const char *const *) now->pdata);
}

void
lk_noaa_prune_downloaded (LkNoaa *self)
{
  g_auto (GStrv) was = NULL;
  g_autoptr (GPtrArray) now = g_ptr_array_new ();
  gboolean dropped = FALSE;

  g_return_if_fail (LK_IS_NOAA (self));
  if (!self->regions_costed)
    return;

  was = lk_store_load_noaa_regions ();
  for (guint i = 0; was != NULL && was[i] != NULL; i++)
    {
      guint32 cells = 0, held = 0;

      lk_noaa_region_held (self, was[i], &cells, &held);
      /* WHOLE, the same test that adopts one. A download that finished leaves
       * the region complete, and what is left of a removed one is its
       * neighbour's cells spilling over a district line: 22 of 891 is not a
       * region the mariner holds. */
      if (cells > 0 && held >= cells)
        g_ptr_array_add (now, was[i]);
      else
        dropped = TRUE;
    }

  if (!dropped)
    return;
  g_ptr_array_add (now, NULL);
  lk_store_save_noaa_regions ((const char *const *) now->pdata);
}

gboolean
lk_noaa_adopt_downloaded (LkNoaa *self)
{
  g_auto (GStrv) was = NULL;
  g_autoptr (GPtrArray) whole = g_ptr_array_new ();

  g_return_val_if_fail (LK_IS_NOAA (self), FALSE);

  was = lk_store_load_noaa_regions ();
  if (was != NULL && was[0] != NULL)
    return FALSE;
  /* An empty record still counts as a record. A mariner who gave back the
   * only region they held leaves one. Adopting every whole region then ticks
   * that water again on the next open. */
  if (lk_store_noaa_regions_recorded ())
    return FALSE;
  if (!self->regions_costed)
    return FALSE;

  /* A region held WHOLE is one the mariner downloaded. A region they hold part
   * of is their neighbour's cells spilling over a district line. */
  for (guint i = 0; i < self->n_regions; i++)
    if (self->region_cells[i] > 0 && self->region_held[i] >= self->region_cells[i])
      g_ptr_array_add (whole, (gpointer) self->regions[i].id);

  if (whole->len == 0)
    return FALSE;
  g_ptr_array_add (whole, NULL);
  lk_store_save_noaa_regions ((const char *const *) whole->pdata);
  return TRUE;
}

/* Add `region_ids` to what this device has downloaded. */
static void
lk_noaa_note_downloaded (const char *region_ids)
{
  g_auto (GStrv) was = lk_store_load_noaa_regions ();
  g_auto (GStrv) ids = g_strsplit (region_ids, ",", -1);
  g_autoptr (GHashTable) seen = g_hash_table_new (g_str_hash, g_str_equal);
  g_autoptr (GPtrArray) now = g_ptr_array_new ();

  for (guint i = 0; was != NULL && was[i] != NULL; i++)
    if (g_hash_table_add (seen, was[i]))
      g_ptr_array_add (now, was[i]);
  for (guint i = 0; ids[i] != NULL; i++)
    if (g_hash_table_add (seen, ids[i]))
      g_ptr_array_add (now, ids[i]);
  g_ptr_array_add (now, NULL);
  lk_store_save_noaa_regions ((const char *const *) now->pdata);
}

void
lk_noaa_download (LkNoaa *self, const char *region_ids, const char *dest_dir,
                  gboolean again)
{
  g_return_if_fail (LK_IS_NOAA (self));
  g_return_if_fail (dest_dir != NULL);

  if (region_ids == NULL || region_ids[0] == '\0')
    return;

  lk_noaa_note_downloaded (region_ids);
  lookout_noaa_download (self->service, region_ids, dest_dir, again ? 1 : 0);
  lk_noaa_sync (self);
}

void
lk_noaa_cancel (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  lookout_noaa_cancel (self->service);
  lk_noaa_sync (self);
}

guint32
lk_noaa_outdated (LkNoaa *self, const LkNoaaInstalled *have, guint n)
{
  g_return_val_if_fail (LK_IS_NOAA (self), 0);

  if (have == NULL || n == 0)
    return 0;

  g_autofree lookout_noaa_installed *raw = g_new0 (lookout_noaa_installed, n);
  for (guint i = 0; i < n; i++)
    {
      raw[i].name = have[i].name;
      raw[i].edition = have[i].edition;
      raw[i].update = have[i].update;
    }
  return lookout_noaa_outdated (self->service, raw, n);
}

void
lk_noaa_update (LkNoaa *self, const LkNoaaInstalled *have, guint n, const char *dest_dir)
{
  g_return_if_fail (LK_IS_NOAA (self));
  g_return_if_fail (dest_dir != NULL);

  if (have == NULL || n == 0)
    return;

  g_autofree lookout_noaa_installed *raw = g_new0 (lookout_noaa_installed, n);
  for (guint i = 0; i < n; i++)
    {
      raw[i].name = have[i].name;
      raw[i].edition = have[i].edition;
      raw[i].update = have[i].update;
    }
  lookout_noaa_update (self->service, raw, n, dest_dir);
  lk_noaa_sync (self);
}

char *
lk_noaa_download_dir (void)
{
  /* Beside what the app prepared, not inside it. The bake mirrors its own
   * output under charts/, and it refuses to delete a path it did not make, so
   * the downloads a bake READS must live somewhere of their own. */
  return g_build_filename (g_get_user_data_dir (), "lookout-marine",
                           "downloads", "NOAA", NULL);
}

/* ---- lifecycle ----------------------------------------------------------- */

static void
lk_noaa_dispose (GObject *object)
{
  LkNoaa *self = LK_NOAA (object);

  /* The fetcher goes first, so no response reaches a closed service. */
  g_clear_pointer (&self->fetcher, lk_fetcher_free);
  g_clear_pointer (&self->service, lookout_noaa_close);
  g_clear_pointer (&self->picked, g_hash_table_unref);
  g_clear_pointer (&self->coverage, g_hash_table_unref);
  g_clear_pointer (&self->regions, g_free);
  g_clear_pointer (&self->region_cells, g_free);
  g_clear_pointer (&self->region_held, g_free);
  g_clear_pointer (&self->managed, g_hash_table_unref);
  self->n_regions = 0;

  G_OBJECT_CLASS (lk_noaa_parent_class)->dispose (object);
}

static void
lk_noaa_class_init (LkNoaaClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = lk_noaa_dispose;

  /* The catalog landing, a pick repriced, a transfer moving, a failure. One
   * signal: every watcher redraws from the snapshot. */
  signals[SIGNAL_CHANGED] =
      g_signal_new ("changed", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

static void
lk_noaa_init (LkNoaa *self)
{
  /* Borrowed keys on both: the region ids are the core's static strings. */
  self->picked = g_hash_table_new (g_str_hash, g_str_equal);
  self->coverage = g_hash_table_new_full (g_str_hash, g_str_equal, NULL,
                                          (GDestroyNotify) g_array_unref);
  lk_noaa_read_regions (self);
}

LkNoaa *
lk_noaa_new (lookout_store *store, lookout_chart_sets *sets)
{
  LkNoaa *self = g_object_new (LK_TYPE_NOAA, NULL);

  self->service = lookout_noaa_open (store, sets);
  self->fetcher = lk_fetcher_new (lk_noaa_respond, self);
  lk_fetcher_set_chunk_respond (self->fetcher, lk_noaa_respond_chunk);
  lookout_noaa_set_http_provider (self->service, lk_noaa_http_get,
                                      lk_noaa_http_cancel, lk_noaa_wake, self);
  return self;
}

lookout_noaa *
lk_noaa_service (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), NULL);
  return self->service;
}
