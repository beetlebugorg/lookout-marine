/* test-noaa.c: NOAA's charts, as the shell holds them.
 *
 * The region table comes from the core and is static, so it can be read with
 * no chart open. The pick, the words and the staging directory are the shell's
 * own, and they are what a mariner reads before agreeing to a download.
 *
 * No display, and no catalog: a read needs the network. What is checked here
 * is everything that does not.
 */

#include "library/noaa.h"
#include "model/app-model.h"
#include "model/store.h"

static char *home;

/* The model owns the NOAA object and hands it the controller, so a test reads
 * it the way the Charts page does. No chart is open, so every core call
 * answers its documented empty value. */
static LkNoaa *
noaa_of (LkAppModel *model)
{
  LkNoaa *noaa = lk_app_model_get_noaa (model);

  g_assert_nonnull (noaa);
  return noaa;
}

/* The core publishes one region per Coast Guard district, and every field the
 * picker draws is filled in. A region with no extent cannot be drawn, and one
 * with no blurb cannot say which water it covers. */
static void
test_region_table (void)
{
  g_autoptr (LkAppModel) model = lk_app_model_new ();
  guint n = 0;
  const LkNoaaRegion *regions = lk_noaa_regions (noaa_of (model), &n);

  g_assert_cmpuint (n, >, 0);
  g_assert_nonnull (regions);

  for (guint i = 0; i < n; i++)
    {
      const LkNoaaRegion *r = &regions[i];

      g_assert_nonnull (r->id);
      g_assert_cmpuint (strlen (r->id), >, 0);
      g_assert_nonnull (r->name);
      g_assert_cmpuint (strlen (r->name), >, 0);
      g_assert_nonnull (r->blurb);
      g_assert_cmpuint (strlen (r->blurb), >, 0);
      g_assert_cmpint (r->district, >, 0);
      /* A rough extent, but a real one: west of east, south of north, and on
       * the planet. */
      g_assert_cmpfloat (r->west, <, r->east);
      g_assert_cmpfloat (r->south, <, r->north);
      g_assert_cmpfloat (r->west, >=, -180.0);
      g_assert_cmpfloat (r->east, <=, 180.0);
      g_assert_cmpfloat (r->south, >=, -90.0);
      g_assert_cmpfloat (r->north, <=, 90.0);
    }

  /* Every id is unique: it is what is written down and what the core reads. */
  g_autoptr (GHashTable) seen = g_hash_table_new (g_str_hash, g_str_equal);
  for (guint i = 0; i < n; i++)
    g_assert_true (g_hash_table_add (seen, (gpointer) regions[i].id));

  /* By id, and nothing else. */
  g_assert_nonnull (lk_noaa_region (noaa_of (model), regions[0].id));
  g_assert_null (lk_noaa_region (noaa_of (model), "not-a-district"));
  g_assert_null (lk_noaa_region (noaa_of (model), NULL));
}

/* The pick is a set, and the list handed to the core is in REGION order. Two
 * mariners who pick the same water in a different order ask for the same
 * thing. */
static void
test_pick_order (void)
{
  g_autoptr (LkAppModel) model = lk_app_model_new ();
  LkNoaa *noaa = noaa_of (model);
  guint n = 0;
  const LkNoaaRegion *regions = lk_noaa_regions (noaa, &n);

  g_assert_cmpuint (n, >=, 3);

  g_assert_cmpuint (lk_noaa_picked_count (noaa), ==, 0);
  g_autofree char *none = lk_noaa_picked_ids (noaa);
  g_assert_cmpstr (none, ==, "");

  /* Picked last first. */
  lk_noaa_toggle (noaa, regions[2].id);
  lk_noaa_toggle (noaa, regions[0].id);
  g_assert_cmpuint (lk_noaa_picked_count (noaa), ==, 2);
  g_assert_true (lk_noaa_is_picked (noaa, regions[0].id));
  g_assert_true (lk_noaa_is_picked (noaa, regions[2].id));
  g_assert_false (lk_noaa_is_picked (noaa, regions[1].id));

  g_autofree char *expect = g_strdup_printf ("%s,%s", regions[0].id, regions[2].id);
  g_autofree char *ids = lk_noaa_picked_ids (noaa);
  g_assert_cmpstr (ids, ==, expect);

  /* A second toggle takes it back off. */
  lk_noaa_toggle (noaa, regions[0].id);
  g_assert_false (lk_noaa_is_picked (noaa, regions[0].id));
  g_assert_cmpuint (lk_noaa_picked_count (noaa), ==, 1);

  /* An id no region answers to is not a pick. */
  lk_noaa_toggle (noaa, "d999");
  g_assert_cmpuint (lk_noaa_picked_count (noaa), ==, 1);

  lk_noaa_clear_picks (noaa);
  g_assert_cmpuint (lk_noaa_picked_count (noaa), ==, 0);
}

/* ::changed carries the picker and the pane, so a pick has to raise it. */
static void
count_changed (LkNoaa *noaa, gpointer data)
{
  (*(guint *) data)++;
}

static void
test_changed_signal (void)
{
  g_autoptr (LkAppModel) model = lk_app_model_new ();
  LkNoaa *noaa = noaa_of (model);
  guint n = 0;
  const LkNoaaRegion *regions = lk_noaa_regions (noaa, &n);
  guint changes = 0;

  g_signal_connect (noaa, "changed", G_CALLBACK (count_changed), &changes);

  lk_noaa_toggle (noaa, regions[0].id);
  g_assert_cmpuint (changes, ==, 1);
  lk_noaa_toggle (noaa, regions[0].id);
  g_assert_cmpuint (changes, ==, 2);

  /* Nothing to clear is nothing to report. */
  lk_noaa_clear_picks (noaa);
  g_assert_cmpuint (changes, ==, 2);
}



/* With no catalog there is nothing to price and nothing to draw, and the
 * snapshot says idle rather than guessing. */
static void
test_no_catalog (void)
{
  g_autoptr (LkAppModel) model = lk_app_model_new ();
  LkNoaa *noaa = noaa_of (model);
  guint n = 0;
  const LkNoaaRegion *regions = lk_noaa_regions (noaa, &n);
  const LkNoaaState *state = lk_noaa_state (noaa);

  g_assert_cmpint (state->phase, ==, LK_NOAA_IDLE);
  g_assert_false (state->have_catalog);
  g_assert_cmpstr (state->error, ==, "");
  g_assert_cmpint (state->checked_at, ==, 0);

  lk_noaa_toggle (noaa, regions[0].id);
  g_assert_cmpuint (lk_noaa_cells (noaa), ==, 0);
  g_assert_cmpuint (lk_noaa_bytes (noaa), ==, 0);
  g_assert_false (lk_noaa_all_installed (noaa));

  guint boxes = 99;
  g_assert_null (lk_noaa_coverage (noaa, regions[0].id, &boxes));
  g_assert_cmpuint (boxes, ==, 0);
}

/* The downloaded zips are staged in one directory, so the whole download bakes
 * as a single set. It must not land where the bake writes: the bake refuses to
 * delete a path it did not make, and a removal would then leave the zips. */
static void
test_download_dir (void)
{
  g_autofree char *dir = lk_noaa_download_dir ();

  g_assert_nonnull (dir);
  g_assert_true (g_str_has_suffix (dir, "downloads/NOAA"));
  g_assert_true (g_str_has_prefix (dir, home));
  g_assert_false (g_str_has_prefix (dir, lk_chart_bake_root ()));
}

/* With no chart handle the service reads as idle and the poll stops.
 *
 * The snapshot kept whatever phase the last handle left, so a phase of
 * downloading or reading held the 400 ms timer for the life of the process
 * and the panels went on saying a transfer was running. */
static void
test_no_handle_reads_as_idle (void)
{
  g_autoptr (LkAppModel) model = lk_app_model_new ();
  LkNoaa *noaa = noaa_of (model);
  const LkNoaaState *state = lk_noaa_state (noaa);

  /* This model has no chart open, so every poll finds no handle. */
  lk_noaa_poll (noaa);
  g_assert_cmpint (state->phase, ==, LK_NOAA_IDLE);
  g_assert_false (state->have_catalog);
  g_assert_cmpuint (state->total, ==, 0);
  g_assert_cmpuint (state->done, ==, 0);
}


int
main (int argc, char *argv[])
{
  home = g_dir_make_tmp ("lk-noaa-test-XXXXXX", NULL);
  g_assert_nonnull (home);
  g_setenv ("HOME", home, TRUE);
  g_setenv ("XDG_CONFIG_HOME", g_build_filename (home, ".config", NULL), TRUE);
  g_setenv ("XDG_DATA_HOME", g_build_filename (home, ".local", "share", NULL), TRUE);
  g_setenv ("XDG_CACHE_HOME", g_build_filename (home, ".cache", NULL), TRUE);
  g_unsetenv ("LOOKOUT_OPEN");

  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/noaa/region-table", test_region_table);
  g_test_add_func ("/noaa/pick-order", test_pick_order);
  g_test_add_func ("/noaa/changed-signal", test_changed_signal);
  g_test_add_func ("/noaa/no-catalog", test_no_catalog);
  g_test_add_func ("/noaa/no-handle-reads-as-idle", test_no_handle_reads_as_idle);
  g_test_add_func ("/noaa/download-dir", test_download_dir);

  return g_test_run ();
}
