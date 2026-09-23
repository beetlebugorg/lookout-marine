/* model/noaa.c: NOAA's charts. See model/noaa.h. */
#include "model/noaa.h"

#include "library/fetch.h"

#include <string.h>

struct _LkNoaa {
  GObject parent_instance;

  lookout_noaa *service;
  LkFetcher    *fetcher;
  /* 1 while an idle is queued to read the state after a wake. */
  gint          wake_queued;

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

  /* Each region as the core counts it, indexed as `regions`. */
  lookout_noaa_region_info *infos;

  /* The `run` of the order followed to its end, or 0 when none is. */
  guint32  run;
  /* The last order, which Retry repeats: the regions and `again` of a
   * download, or an update when `order_ids` is NULL. */
  char    *order_ids;
  gboolean order_again;
  /* Retry found no catalog. It orders again when the catalog read ends. */
  gboolean retry_waiting;
  /* How many managed charts NOAA has reissued, as counted after the check
   * recorded at `counted_at`. */
  guint32  outdated;
  gint64   counted_at;
  /* The core's prepare and removal, drawn as the shell's bake and removal. */
  gboolean       preparing;
  gint64         prepare_started_us;
  LkBakeProgress prepare_progress;
  LkBakeBand     prepare_bands[6];
  gboolean       removing;
  LkBakeProgress remove_progress;
};

enum {
  SIGNAL_CHANGED,
  SIGNAL_ALERT,
  SIGNAL_WORK_MOVED,
  N_SIGNALS
};

static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE (LkNoaa, lk_noaa, G_TYPE_OBJECT)

static void lk_noaa_recost (LkNoaa *self);
static void lk_noaa_flow (LkNoaa *self);
static void lk_noaa_read_infos (LkNoaa *self);

/* ---- the region table ---------------------------------------------------- */

static void
lk_noaa_read_regions (LkNoaa *self)
{
  const lookout_noaa_region *all = NULL;
  size_t n = lookout_noaa_regions (&all);

  if (all == NULL || n == 0)
    return;

  self->regions = g_new0 (LkNoaaRegion, n);
  self->infos = g_new0 (lookout_noaa_region_info, n);
  self->n_regions = (guint) n;
  for (size_t i = 0; i < n; i++)
    {
      self->regions[i].id = all[i].id;
      self->regions[i].name = all[i].name;
      self->regions[i].blurb = all[i].blurb;
      self->regions[i].district = all[i].district;
      self->regions[i].panel = all[i].panel;
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
      lk_noaa_recost (self);
      lk_noaa_read_infos (self);
      lk_noaa_load_coverage (self);
    }
  lk_noaa_flow (self);
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
lk_noaa_respond (gpointer user_data, uint64_t req_id, const void *bytes,
                       gsize len, int status, gboolean done)
{
  LkNoaa *self = user_data;

  lookout_noaa_http_respond_chunk (self->service, req_id, bytes, len, status,
                                   done ? 1 : 0);
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

/* The core walks the catalog for each region, so the map reads this copy. */
static void
lk_noaa_read_infos (LkNoaa *self)
{
  for (guint i = 0; i < self->n_regions; i++)
    lookout_noaa_region_state (self->service, self->regions[i].id, &self->infos[i]);
}

const lookout_noaa_region_info *
lk_noaa_region_info (LkNoaa *self, const char *id)
{
  static const lookout_noaa_region_info none = { 0 };
  const LkNoaaRegion *region;

  g_return_val_if_fail (LK_IS_NOAA (self), &none);

  region = lk_noaa_region (self, id);
  return region != NULL ? &self->infos[region - self->regions] : &none;
}

void
lk_noaa_reprice (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  lk_noaa_recost (self);
  lk_noaa_read_infos (self);
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
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
  char size[LOOKOUT_BYTES_MAX];
  char count[LOOKOUT_COUNT_MAX];
  char have[LOOKOUT_COUNT_MAX];

  lookout_fmt_count (held, have, sizeof have);
  if (cells == 0 && held > 0)
    {
      lookout_fmt_bytes (held_bytes, size, sizeof size);
      return g_strdup_printf ("%s charts, all installed · %s to fetch again", have, size);
    }

  lookout_fmt_bytes (bytes, size, sizeof size);
  lookout_fmt_count (cells, count, sizeof count);
  if (held > 0)
    return g_strdup_printf ("%s charts, %s · %s already installed", count, size, have);
  return g_strdup_printf ("%s charts, %s", count, size);
}

char *
lk_noaa_cost_line (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), g_strdup (""));

  return lk_noaa_cost_words (self->cells, self->bytes, self->held, self->held_bytes);
}

/* ---- downloading --------------------------------------------------------- */

void
lk_noaa_download (LkNoaa *self, const char *region_ids, const char *dest_dir,
                  gboolean again)
{
  g_return_if_fail (LK_IS_NOAA (self));
  g_return_if_fail (dest_dir != NULL);

  if (region_ids == NULL || region_ids[0] == '\0')
    return;

  lookout_noaa_download (self->service, region_ids, dest_dir, again ? 1 : 0);
  lk_noaa_read_infos (self);
  lk_noaa_sync (self);
}

guint32
lk_noaa_apply (LkNoaa *self, const char *dest_dir, gboolean again)
{
  g_autofree char *ids = NULL;
  guint32 moved;

  g_return_val_if_fail (LK_IS_NOAA (self), 0);
  g_return_val_if_fail (dest_dir != NULL, 0);

  ids = lk_noaa_picked_ids (self);
  moved = lookout_noaa_apply (self->service, ids, dest_dir, again ? 1 : 0);
  lk_noaa_read_infos (self);
  lk_noaa_sync (self);
  return moved;
}

void
lk_noaa_cancel (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  lookout_noaa_cancel (self->service);
  lk_noaa_sync (self);
}

gboolean
lk_noaa_update_due (LkNoaa *self)
{
  gboolean due;

  g_return_val_if_fail (LK_IS_NOAA (self), FALSE);

  due = lookout_noaa_update_due (self->service) != 0;
  lk_noaa_sync (self);
  return due;
}

guint32
lk_noaa_outdated (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), 0);
  return lookout_noaa_outdated (self->service);
}

void
lk_noaa_update (LkNoaa *self, const char *dest_dir)
{
  g_return_if_fail (LK_IS_NOAA (self));
  g_return_if_fail (dest_dir != NULL);

  lookout_noaa_update (self->service, dest_dir);
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

/* ---- the orders the app follows ------------------------------------------- */

/* End the followed order when its outcome is no longer running. A failure
 * raises ::alert, and so does a refusal that a retry can clear. Setup shows
 * the end in its own step, so the window skips this alert while setup is
 * showing. */
static void
lk_noaa_follow (LkNoaa *self)
{
  const lookout_noaa_state *state = &self->state;

  if (self->run == 0 || state->run != self->run || state->outcome == LOOKOUT_NOAA_RUNNING)
    return;
  self->run = 0;

  if (state->outcome == LOOKOUT_NOAA_FAILED ||
      (state->outcome == LOOKOUT_NOAA_REFUSED && state->retry))
    g_signal_emit (self, signals[SIGNAL_ALERT], 0,
                   state->error[0] != '\0' ? state->error
                                           : "The download stopped before any chart arrived.",
                   TRUE, state->retry != 0);
}

/* Follow the order just placed. `before` is the `run` read before it. */
static void
lk_noaa_ordered (LkNoaa *self, guint32 before)
{
  if (self->state.run == before)
    return;
  self->run = self->state.run;
  lk_noaa_follow (self);
}

/* The download directory, made if it is not there. NULL, with ::alert
 * raised, when it cannot be made. */
static char *
lk_noaa_dest (LkNoaa *self)
{
  g_autofree char *dest = lk_noaa_download_dir ();

  if (g_mkdir_with_parents (dest, 0700) != 0)
    {
      g_signal_emit (self, signals[SIGNAL_ALERT], 0,
                     "Couldn't make a place to download charts to.", FALSE, FALSE);
      return NULL;
    }
  return g_steal_pointer (&dest);
}

void
lk_noaa_order_download (LkNoaa *self, const char *region_ids, gboolean again)
{
  g_autofree char *dest = NULL;
  g_autofree char *ids = g_strdup (region_ids);
  guint32 before;

  g_return_if_fail (LK_IS_NOAA (self));

  dest = lk_noaa_dest (self);
  if (dest == NULL)
    return;

  /* Price against what is already here first. A mariner who picks water they
   * partly hold fetches the rest of it. */
  lk_noaa_reprice (self);

  g_free (self->order_ids);
  self->order_ids = g_strdup (ids);
  self->order_again = again;
  before = self->state.run;
  lk_noaa_download (self, ids, dest, again);
  lk_noaa_ordered (self, before);
}

void
lk_noaa_order_apply (LkNoaa *self)
{
  g_autofree char *dest = NULL;
  guint32 before;

  g_return_if_fail (LK_IS_NOAA (self));

  dest = lk_noaa_dest (self);
  if (dest == NULL)
    return;

  g_free (self->order_ids);
  self->order_ids = lk_noaa_picked_ids (self);
  self->order_again = FALSE;
  before = self->state.run;
  /* The charts it gives back are out of the library when it returns, so the
   * chart opens again on what is left. */
  if (lk_noaa_apply (self, dest, FALSE) > 0)
    g_signal_emit (self, signals[SIGNAL_WORK_MOVED], 0, TRUE);
  lk_noaa_ordered (self, before);
}

void
lk_noaa_order_update (LkNoaa *self)
{
  g_autofree char *dest = NULL;
  guint32 before;

  g_return_if_fail (LK_IS_NOAA (self));

  dest = lk_noaa_dest (self);
  if (dest == NULL)
    return;

  g_clear_pointer (&self->order_ids, g_free);
  before = self->state.run;
  lk_noaa_update (self, dest);
  lk_noaa_ordered (self, before);
}

/* Order the last download or update again. */
static void
lk_noaa_reorder (LkNoaa *self)
{
  g_autofree char *ids = g_strdup (self->order_ids);

  if (ids != NULL)
    lk_noaa_order_download (self, ids, self->order_again);
  else
    lk_noaa_order_update (self);
}

void
lk_noaa_retry (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  if (self->state.have_catalog)
    {
      lk_noaa_reorder (self);
      return;
    }
  self->retry_waiting = TRUE;
  lk_noaa_refresh (self);
}

void
lk_noaa_check_updates (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  lk_noaa_update_due (self);
}

void
lk_noaa_sets_changed (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  /* The count and the check both follow the managed sets. There is no count
   * until a check has been recorded. */
  if (self->state.update_checked_at != 0)
    self->outdated = lk_noaa_outdated (self);
  lk_noaa_check_updates (self);
}

int
lk_noaa_get_update_check (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), LOOKOUT_NOAA_CHECK_DAILY);
  return lookout_noaa_update_check (self->service);
}

void
lk_noaa_set_update_check (LkNoaa *self, int cadence)
{
  g_return_if_fail (LK_IS_NOAA (self));
  lookout_noaa_set_update_check (self->service, cadence);
}

guint32
lk_noaa_outdated_found (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), 0);
  return self->outdated;
}

const LkBakeProgress *
lk_noaa_prepare_progress (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), NULL);
  return self->preparing ? &self->prepare_progress : NULL;
}

const LkBakeProgress *
lk_noaa_remove_progress (LkNoaa *self)
{
  g_return_val_if_fail (LK_IS_NOAA (self), NULL);
  return self->removing ? &self->remove_progress : NULL;
}

/* The core's prepare of a download, drawn as a bake. ::work-moved on each
 * change, and its end opens the chart on what it made. */
static void
lk_noaa_prepare (LkNoaa *self)
{
  const lookout_noaa_state *state = &self->state;
  gboolean was = self->preparing;

  if (!state->preparing && !was)
    return;
  self->preparing = state->preparing != 0;
  if (self->preparing && !was)
    self->prepare_started_us = g_get_monotonic_time ();

  self->prepare_progress = (LkBakeProgress) {
    .kind = LK_BAKE_IMPORT,
    .done = (int) state->prepared,
    .total = (int) state->to_prepare,
    /* The download directory's name, as the shell's bake titled it. */
    .name = "NOAA",
    .elapsed = (g_get_monotonic_time () - self->prepare_started_us) / 1e6,
    .bands = self->prepare_bands,
  };
  for (guint i = 0; i < G_N_ELEMENTS (state->band_total); i++)
    if (state->band_total[i] > 0)
      self->prepare_bands[self->prepare_progress.n_bands++] = (LkBakeBand) {
        .band = (int) i + 1,
        .total = state->band_total[i],
        .done = state->band_done[i],
      };
  g_signal_emit (self, signals[SIGNAL_WORK_MOVED], 0, was && !self->preparing);
}

/* The follow-up on each change of the core's state. */
static void
lk_noaa_flow (LkNoaa *self)
{
  const lookout_noaa_state *state = &self->state;

  /* A check that the core has recorded is counted once. */
  if (!state->update_checking && state->update_checked_at != self->counted_at)
    {
      self->counted_at = state->update_checked_at;
      self->outdated = lk_noaa_outdated (self);
    }
  if (self->retry_waiting && (state->have_catalog || state->phase != LOOKOUT_NOAA_READING))
    {
      self->retry_waiting = FALSE;
      lk_noaa_reorder (self);
    }
  lk_noaa_follow (self);
  lk_noaa_prepare (self);

  /* A removal an apply started. Each change reports, so the panel moves. */
  if (state->removing || self->removing)
    {
      self->removing = state->removing != 0;
      self->remove_progress = (LkBakeProgress) {
        .kind = LK_BAKE_REMOVE,
        .done = (int) state->remove_done,
        .total = (int) state->remove_total,
        .name = state->removing ? "NOAA charts" : "",
      };
      g_signal_emit (self, signals[SIGNAL_WORK_MOVED], 0, FALSE);
    }
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
  g_clear_pointer (&self->infos, g_free);
  g_clear_pointer (&self->order_ids, g_free);
  self->n_regions = 0;

  G_OBJECT_CLASS (lk_noaa_parent_class)->dispose (object);
}

static void
lk_noaa_class_init (LkNoaaClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = lk_noaa_dispose;

  /* The catalog landing, a pick repriced, a transfer moving, a failure. One
   * signal: every watcher redraws from the snapshot. */
  /* A message for the app's open error: whether it reports the end of an
   * order, and whether Retry can clear it. */
  signals[SIGNAL_ALERT] =
      g_signal_new ("alert", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST, 0, NULL,
                    NULL, NULL, G_TYPE_NONE, 3, G_TYPE_STRING, G_TYPE_BOOLEAN,
                    G_TYPE_BOOLEAN);
  /* The prepare or the removal moved. TRUE when the library changed under the
   * chart: a prepare ended, or an apply took charts out. */
  signals[SIGNAL_WORK_MOVED] =
      g_signal_new ("work-moved", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST, 0, NULL,
                    NULL, NULL, G_TYPE_NONE, 1, G_TYPE_BOOLEAN);
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
