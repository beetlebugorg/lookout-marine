/* library/noaa.c — NOAA's charts. See library/noaa.h. */
#include "library/noaa.h"

#include <string.h>

/* How often the shell asks where the core has got to. The core reports
 * progress and takes no callback across the C ABI, so a read and a download
 * are both watched by asking. The timer runs only while one of them is in
 * flight: idle means idle. */
#define LK_NOAA_POLL_MS 400

struct _LkNoaa {
  GObject parent_instance;

  LkChartController *controller; /* strong: a late poll must find it alive */

  /* The region table. The core's strings are static, so the rows hold them
   * rather than copies. */
  LkNoaaRegion *regions;
  guint         n_regions;

  /* The ids picked, as a set. Keys are the static region ids. */
  GHashTable *picked;

  LkNoaaState state;

  /* Each region's real coverage, read once when the catalog lands.
   * id -> GArray of LkNoaaBox. */
  GHashTable *coverage;

  /* What the pick costs, refreshed whenever the pick changes. */
  guint32 cells, held;
  guint64 bytes, held_bytes;

  /* A read asked for before a chart was open. Every call here runs through a
   * chart handle, so a read asked for at launch had nothing to run through. */
  gboolean wants_catalog;
  /* True once anything has asked in this session. The catalog belongs to the
   * chart handle, so a chart that closes takes it, and the read has to be
   * asked for again on the next handle. */
  gboolean asked;

  guint poll_id;

  LkNoaaNeedChart need_chart;
  gpointer        need_chart_data;
};

enum {
  SIGNAL_CHANGED,
  N_SIGNALS
};

static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE (LkNoaa, lk_noaa, G_TYPE_OBJECT)

static void lk_noaa_recost (LkNoaa *self);
static void lk_noaa_watch (LkNoaa *self);

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

const LkNoaaState *
lk_noaa_state (LkNoaa *self)
{
  static const LkNoaaState empty = { 0 };

  g_return_val_if_fail (LK_IS_NOAA (self), &empty);
  return &self->state;
}

/* True while the core has work in flight that only a poll will report. */
static gboolean
lk_noaa_working (LkNoaa *self)
{
  return self->state.phase == LK_NOAA_READING_CATALOG ||
         self->state.phase == LK_NOAA_DOWNLOADING;
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
      gsize n = lk_chart_controller_noaa_coverage (self->controller, id, NULL, 0);
      if (n == 0)
        continue;

      g_autofree lookout_noaa_box *raw = g_new0 (lookout_noaa_box, n);
      gsize got = lk_chart_controller_noaa_coverage (self->controller, id, raw, n);
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

/* Read the core's snapshot into the shell's. No timer work here: the tick and
 * the public poll each decide what to do with the result. */
static gboolean
lk_noaa_take_snapshot (LkNoaa *self)
{
  lookout_noaa_state raw;
  LkNoaaState next;
  gboolean gained;

  if (!lk_chart_controller_noaa_poll (self->controller, &raw))
    return FALSE;

  memset (&next, 0, sizeof next);
  next.phase = (LkNoaaPhase) raw.phase;
  next.have_catalog = raw.have_catalog != 0;
  g_strlcpy (next.date, raw.date, sizeof next.date);
  next.checked_at = raw.checked_at;
  next.catalog_cells = raw.catalog_cells;
  next.total = raw.total;
  next.done = raw.done;
  next.failed = raw.failed;
  next.bytes_total = raw.bytes_total;
  next.bytes_done = raw.bytes_done;
  g_strlcpy (next.error, raw.error, sizeof next.error);

  /* Nothing moved. A poll runs several times a second, and telling every
   * watcher that nothing happened is what makes a panel redraw for no
   * reason. */
  if (memcmp (&next, &self->state, sizeof next) == 0)
    return FALSE;

  gained = next.have_catalog && !self->state.have_catalog;
  self->state = next;
  if (gained)
    {
      lk_noaa_recost (self);
      lk_noaa_load_coverage (self);
    }
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
  return TRUE;
}

static gboolean
lk_noaa_poll_tick (gpointer data)
{
  LkNoaa *self = data;

  lk_noaa_take_snapshot (self);
  if (lk_noaa_working (self))
    return G_SOURCE_CONTINUE;

  self->poll_id = 0;
  return G_SOURCE_REMOVE;
}

/* Watch while a read or a download is in flight, and not otherwise. */
static void
lk_noaa_watch (LkNoaa *self)
{
  if (self->poll_id != 0 || !lk_noaa_working (self))
    return;
  self->poll_id = g_timeout_add (LK_NOAA_POLL_MS, lk_noaa_poll_tick, self);
}

void
lk_noaa_poll (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  lk_noaa_take_snapshot (self);
  lk_noaa_watch (self);
}

/* ---- reading the catalog ------------------------------------------------- */

void
lk_noaa_refresh (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  if (!lk_chart_controller_noaa_refresh (self->controller))
    {
      /* No handle. Every call here runs through one, so on a first run the
       * read had nothing to use and the coverage step sat with its regions
       * dim and no line to say why. Ask the owner for a chart of no charts
       * and replay this from lk_noaa_chart_did_open. */
      self->wants_catalog = TRUE;
      if (self->need_chart != NULL)
        self->need_chart (self->need_chart_data);
      return;
    }

  self->wants_catalog = FALSE;
  self->asked = TRUE;
  /* The core set the phase to reading when it took the call. Read it back, so
   * the line watching the phase starts its own poll. */
  lk_noaa_poll (self);
}

void
lk_noaa_chart_did_open (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  lk_noaa_poll (self);
  /* A read held for want of a handle, or one the old handle took with it. */
  if (self->wants_catalog || (self->asked && !self->state.have_catalog))
    lk_noaa_refresh (self);
}

/* ---- what a pick costs --------------------------------------------------- */

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
  lk_chart_controller_noaa_cost (self->controller, ids, &self->cells, &self->bytes,
                                 &self->held, &self->held_bytes);
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
lk_noaa_size_text (guint64 bytes)
{
  /* Decimal, and one unit either side of a gigabyte. A mariner about to spend
   * a marina's wifi on this reads GB or MB, not a three-place number. */
  if (bytes >= 1000000000ULL)
    return g_strdup_printf ("%.1f GB", (double) bytes / 1e9);
  return g_strdup_printf ("%.0f MB", (double) bytes / 1e6);
}

char *
lk_noaa_cost_words (guint32 cells, guint64 bytes, guint32 held, guint64 held_bytes)
{
  /* Water wholly installed prices as a repair, so a number far under the
   * region's size reads as a saving rather than a mistake. */
  if (cells == 0 && held > 0)
    {
      g_autofree char *size = lk_noaa_size_text (held_bytes);
      return g_strdup_printf ("%u charts, all installed · %s to fetch again", held, size);
    }

  g_autofree char *size = lk_noaa_size_text (bytes);
  if (held > 0)
    return g_strdup_printf ("%u charts, %s · %u already installed", cells, size, held);
  return g_strdup_printf ("%u charts, %s", cells, size);
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

  lk_chart_controller_noaa_have (self->controller, names);
  lk_noaa_recost (self);
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

/* ---- downloading --------------------------------------------------------- */

void
lk_noaa_download (LkNoaa *self, const char *dest_dir, gboolean again)
{
  g_autofree char *ids = NULL;

  g_return_if_fail (LK_IS_NOAA (self));
  g_return_if_fail (dest_dir != NULL);

  if (g_hash_table_size (self->picked) == 0)
    return;

  ids = lk_noaa_picked_ids (self);
  lk_chart_controller_noaa_download (self->controller, ids, dest_dir, again);
  lk_noaa_poll (self);
}

void
lk_noaa_cancel (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  lk_chart_controller_noaa_cancel (self->controller);
  lk_noaa_poll (self);
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
  return lk_chart_controller_noaa_outdated (self->controller, raw, n);
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
  lk_chart_controller_noaa_update (self->controller, raw, n, dest_dir);
  lk_noaa_poll (self);
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

void
lk_noaa_set_need_chart (LkNoaa *self, LkNoaaNeedChart fn, gpointer user_data)
{
  g_return_if_fail (LK_IS_NOAA (self));

  self->need_chart = fn;
  self->need_chart_data = user_data;
}

void
lk_noaa_shutdown (LkNoaa *self)
{
  g_return_if_fail (LK_IS_NOAA (self));

  g_clear_handle_id (&self->poll_id, g_source_remove);
  g_clear_object (&self->controller);
  self->need_chart = NULL;
  self->need_chart_data = NULL;
}

static void
lk_noaa_dispose (GObject *object)
{
  LkNoaa *self = LK_NOAA (object);

  g_clear_handle_id (&self->poll_id, g_source_remove);
  g_clear_object (&self->controller);
  g_clear_pointer (&self->picked, g_hash_table_unref);
  g_clear_pointer (&self->coverage, g_hash_table_unref);
  g_clear_pointer (&self->regions, g_free);
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
lk_noaa_new (LkChartController *controller)
{
  LkNoaa *self = g_object_new (LK_TYPE_NOAA, NULL);

  self->controller = controller != NULL ? g_object_ref (controller) : NULL;
  return self;
}
