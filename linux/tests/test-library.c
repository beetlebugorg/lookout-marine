/* test-library.c: what the app opens on its own, and what counts as drawable.
 *
 * The decision behind the first-run page. An app with an empty library must
 * open a chart of no charts and say so, and it must not reach for a cell some
 * other program left in a cache: a chart the mariner never installed keeps
 * setup down on the one run that needs it.
 *
 * No display. This is the model's answer, read directly.
 */

#include <glib/gstdio.h>

#include "library/bake.h"
#include "library/scan.h"
#include "library/noaa.h"
#include "library/sets.h"
#include "model/app-model.h"

static char *home;

/* A file that exists and is not a directory, which is all the path decision
 * asks of a chart. */
static char *
touch (const char *relative)
{
  char *path = g_build_filename (home, relative, NULL);
  g_autofree char *dir = g_path_get_dirname (path);

  g_assert_cmpint (g_mkdir_with_parents (dir, 0700), ==, 0);
  g_assert_true (g_file_set_contents (path, "", 0, NULL));
  return path;
}

/* Nothing installed, and a demo cell sitting in the cache where an older
 * build's default pointed. The answer is still nothing: the app opens the
 * basemap and setup runs over it. */
static void
test_nothing_installed_opens_nothing (void)
{
  g_autoptr (LkAppModel) model = lk_app_model_new ();
  g_autofree char *demo = touch (".cache/chartplotter/NOAA/tiles/d5/US5MD1MC.pmtiles");

  g_assert_true (g_file_test (demo, G_FILE_TEST_EXISTS));

  g_auto (GStrv) paths = lk_app_model_initial_chart_paths (model);
  g_assert_nonnull (paths);
  g_assert_null (paths[0]);

  g_autofree char *source = lk_app_model_initial_source (model);
  g_assert_null (source);
}

/* $LOOKOUT_OPEN still wins, so a screenshot run and a dev run open what they
 * name. */
static void
test_env_open_wins (void)
{
  g_autoptr (LkAppModel) model = lk_app_model_new ();
  g_autofree char *cell = touch ("charts/US5MD1MC.pmtiles");

  g_setenv ("LOOKOUT_OPEN", cell, TRUE);

  g_auto (GStrv) paths = lk_app_model_initial_chart_paths (model);
  g_assert_cmpuint (g_strv_length (paths), ==, 1);
  g_assert_cmpstr (paths[0], ==, cell);

  g_autofree char *source = lk_app_model_initial_source (model);
  g_assert_cmpstr (source, ==, cell);

  g_unsetenv ("LOOKOUT_OPEN");
}

/* With nothing installed there is nothing to draw, and with no handle a chart
 * reads as holding no charts. Both are what the page stands on. */
static void
test_nothing_to_draw (void)
{
  g_autoptr (LkAppModel) model = lk_app_model_new ();

  g_assert_false (lk_app_model_get_has_chart (model));
  g_assert_false (lk_app_model_get_chart_is_empty (model));
  g_assert_true (lk_app_model_get_nothing_to_draw (model));

  /* A chart reported open that holds no charts is the basemap. Still nothing
   * to draw. */
  lk_app_model_set_chart_open (model, TRUE, NULL);
  g_assert_true (lk_app_model_get_chart_is_empty (model));
  g_assert_true (lk_app_model_get_nothing_to_draw (model));

  /* An open, a scan or a bake in flight is not an empty library. */
  lk_app_model_set_opening (model, TRUE, FALSE);
  g_assert_false (lk_app_model_get_nothing_to_draw (model));
  lk_app_model_set_opening (model, FALSE, FALSE);
  g_assert_true (lk_app_model_get_nothing_to_draw (model));
}

/* Real cells. The scan reads the surveys themselves, so a dataset name on an
 * empty file reports no chart. */
static void
noop_changed (GObject *owner)
{
}

/* Copy one of the repository's test cells into `dir`. */
static void
place_cell (const char *dir, const char *name)
{
  g_autofree char *from = g_build_filename (LK_TEST_CELLS, name, NULL);
  g_autofree char *to = g_build_filename (dir, name, NULL);
  g_autofree char *bytes = NULL;
  gsize len = 0;

  g_assert_cmpint (g_mkdir_with_parents (dir, 0700), ==, 0);
  g_assert_true (g_file_get_contents (from, &bytes, &len, NULL));
  g_assert_cmpuint (len, >, 0);
  g_assert_true (g_file_set_contents (to, bytes, (gssize) len, NULL));
}

/* A pick holds a survey and a picture together, and only the pictures go to
 * the raster chart list. A BSB sheet bakes into a chart, and a picture inside
 * an archive has no file at its path yet, so neither belongs on that list. */
static void
test_pictures_in_a_pick (void)
{
  LkScannedCell cells[] = {
    { .path = (char *) "/set/US5MD1MC.000", .kind = LOOKOUT_FILE_SOURCE },
    { .path = (char *) "/set/imagery.mbtiles", .kind = LOOKOUT_FILE_RASTER },
    { .path = (char *) "/set/US5MD1MC.pmtiles", .kind = LOOKOUT_FILE_BAKED },
    { .path = (char *) "/set/sheet.kap", .kind = LOOKOUT_FILE_RASTER_SOURCE },
    { .path = (char *) "inside.mbtiles", .kind = LOOKOUT_FILE_RASTER, .archived = TRUE },
    { .path = (char *) "/set/notes.txt", .kind = LOOKOUT_FILE_OTHER },
    { .path = (char *) "/set/other.mbtiles", .kind = LOOKOUT_FILE_RASTER },
  };
  g_autoptr (GPtrArray) list = g_ptr_array_new ();
  LkChartSet set = { .cells = list };

  for (guint i = 0; i < G_N_ELEMENTS (cells); i++)
    g_ptr_array_add (list, &cells[i]);

  g_auto (GStrv) pictures = lk_chart_set_picture_paths (&set);

  g_assert_cmpuint (g_strv_length (pictures), ==, 2);
  g_assert_cmpstr (pictures[0], ==, "/set/imagery.mbtiles");
  g_assert_cmpstr (pictures[1], ==, "/set/other.mbtiles");

  /* A pick with no pictures answers an empty list, never NULL: the caller
   * counts it. */
  g_ptr_array_set_size (list, 1);
  g_auto (GStrv) none = lk_chart_set_picture_paths (&set);
  g_assert_nonnull (none);
  g_assert_cmpuint (g_strv_length (none), ==, 0);

  g_auto (GStrv) empty = lk_chart_set_picture_paths (NULL);
  g_assert_nonnull (empty);
  g_assert_cmpuint (g_strv_length (empty), ==, 0);
}

/* A chart the bake has already written. An empty file is enough, because
 * lk_chart_bake_to_prepare tests for a file at a path. */
static void
place_at (const char *path)
{
  g_autofree char *dir = g_path_get_dirname (path);

  g_assert_cmpint (g_mkdir_with_parents (dir, 0700), ==, 0);
  g_assert_true (g_file_set_contents (path, "", 0, NULL));
}

/* The same, at `relative` under the prepared folder. */
static void
place_prepared (const char *prepared, const char *relative)
{
  g_autofree char *path = g_build_filename (prepared, relative, NULL);

  place_at (path);
}



/* A set is "derived" when REMOVING IT DELETES WORK.
 *
 * That is the question the remove button asks before it puts up its warning,
 * and the removal deletes the set's PREPARED directory, which a folder in the
 * mariner's own home has just as much as a lifted archive does. Reading the
 * set's own path instead answered no for every folder a mariner added, so a
 * gigabyte of prepared charts went with no warning at all, under a tooltip
 * that promised their files stayed where they were. */
/* Whether one set on the list would delete work if it were removed. Other
 * tests in this run leave sets of their own on the list, so this finds the
 * row by path rather than taking the only one. */
static gboolean
derived_row (LkChartSets *sets, const char *path)
{
  g_autoptr (GPtrArray) rows = lk_chart_sets_rows (sets);

  for (guint i = 0; i < rows->len; i++)
    {
      const LkChartSetRow *row = g_ptr_array_index (rows, i);

      if (g_strcmp0 (row->path, path) == 0)
        return row->derived;
    }
  g_assert_not_reached ();
}

static gboolean
managed_row (LkChartSets *sets, const char *path)
{
  g_autoptr (GPtrArray) rows = lk_chart_sets_rows (sets);

  for (guint i = 0; i < rows->len; i++)
    {
      const LkChartSetRow *row = g_ptr_array_index (rows, i);

      if (g_strcmp0 (row->path, path) == 0)
        return row->managed;
    }
  g_assert_not_reached ();
}

static void
test_a_set_with_prepared_charts_is_derived (void)
{
  g_autoptr (GObject) owner = g_object_new (G_TYPE_OBJECT, NULL);
  LkChartSets *sets = lk_chart_sets_new (noop_changed, owner);
  g_autofree char *dir = g_build_filename (home, "own-cells", NULL);

  place_cell (dir, "US3CU1EF.000");
  g_assert_true (lk_chart_sets_note (sets, dir));

  /* Nothing prepared from it yet: removing it takes a list entry off a list
   * and touches nothing on the disk. No question to ask. */
  g_assert_false (derived_row (sets, dir));

  /* Now Lookout has prepared a chart from it. Removing it deletes that. */
  g_autofree char *prepared = lk_chart_bake_prepared_dir (dir);
  g_assert_nonnull (prepared);
  place_prepared (prepared, "US3CU1EF/US3CU1EF.pmtiles");

  g_assert_true (derived_row (sets, dir));

  lk_chart_sets_free (sets);
}

/* The downloader's mark reaches the row the settings list draws.
 *
 * The Charts pane marks a managed set so a mariner reads where the charts came
 * from, and where they are added and removed. The mark is the core's, and the
 * row is what the pane reads. */
static void
test_a_managed_set_says_so_on_its_row (void)
{
  g_autoptr (GObject) owner = g_object_new (G_TYPE_OBJECT, NULL);
  LkChartSets *sets = lk_chart_sets_new (noop_changed, owner);
  g_autofree char *dir = g_build_filename (home, "noaa-cells", NULL);

  place_cell (dir, "US3CU1EF.000");
  g_assert_true (lk_chart_sets_note (sets, dir));
  g_assert_false (managed_row (sets, dir));

  g_assert_true (lk_chart_sets_set_managed (sets, dir, TRUE));
  g_assert_true (managed_row (sets, dir));

  lk_chart_sets_free (sets);
}

/* Is this set on the list? Bounded, because the scan runs on the core's own
 * thread and the answer changes when it completes. */
static gboolean
wait_for_row (LkChartSets *sets, const char *path, gboolean want)
{
  for (int i = 0; i < 400; i++)
    {
      g_autoptr (GPtrArray) rows = lk_chart_sets_rows (sets);
      gboolean found = FALSE;

      for (guint r = 0; r < rows->len; r++)
        if (g_strcmp0 (((const LkChartSetRow *) g_ptr_array_index (rows, r))->path,
                       path) == 0)
          found = TRUE;
      if (found == want)
        return TRUE;
      g_main_context_iteration (NULL, FALSE);
      g_usleep (5000);
    }
  return FALSE;
}

/* A set the scan has read and found empty leaves the list.
 *
 * The NOAA picker empties its own set. Unticking water deletes the cells from
 * the folder they were downloaded to, and the folder remains. That folder
 * produced a row with a switch over zero charts and a size of zero. */
static void
test_an_emptied_set_leaves_the_list (void)
{
  g_autoptr (GObject) owner = g_object_new (G_TYPE_OBJECT, NULL);
  LkChartSets *sets = lk_chart_sets_new (noop_changed, owner);
  g_autofree char *dir = g_build_filename (home, "emptied", NULL);
  g_autofree char *cell = g_build_filename (dir, "US3CU1EF.000", NULL);

  place_cell (dir, "US3CU1EF.000");
  g_assert_true (lk_chart_sets_note (sets, dir));
  g_assert_true (wait_for_row (sets, dir, TRUE));

  /* What a removal leaves is the empty folder. */
  g_assert_cmpint (g_unlink (cell), ==, 0);
  g_assert_true (lk_chart_sets_rescan (sets, dir));
  g_assert_true (wait_for_row (sets, dir, FALSE));

  lk_chart_sets_free (sets);
}

/* Unticking every region gives the whole download back, through
 * lookout_noaa_apply with an empty pick: the exchange set, the charts
 * prepared from it, and the folder itself. */
static void
test_the_whole_download_goes (void)
{
  g_autoptr (LkAppModel) model = NULL;
  g_autofree char *source = lk_noaa_download_dir ();
  g_autofree char *prepared = lk_chart_bake_prepared_dir (source);
  g_autofree char *root = g_build_filename (source, "ENC_ROOT", NULL);
  g_autofree char *cell = g_build_filename (root, "US3CU1EF", NULL);
  g_autofree char *readme = g_build_filename (root, "README.TXT", NULL);

  place_cell (cell, "US3CU1EF.000");
  g_assert_true (g_file_set_contents (readme, "", 0, NULL));
  place_prepared (prepared, "US3CU1EF/US3CU1EF.pmtiles");

  {
    g_autoptr (GObject) owner = g_object_new (G_TYPE_OBJECT, NULL);
    LkChartSets *sets = lk_chart_sets_new (noop_changed, owner);

    g_assert_true (lk_chart_sets_note (sets, source));
    g_assert_true (lk_chart_sets_set_managed (sets, source, TRUE));
    lk_chart_sets_free (sets);
  }

  model = lk_app_model_new ();
  lk_app_model_apply_noaa_pick (model);

  /* The rename is synchronous, so the charts are out of reach before this
   * returns. The delete behind it runs on its own thread. */
  g_assert_false (g_file_test (source, G_FILE_TEST_EXISTS));
  g_assert_false (g_file_test (prepared, G_FILE_TEST_EXISTS));
}

static guint removal_reports;

static void
count_removal (const LkBakeProgress *progress, gpointer user_data)
{
  removal_reports++;
}

/* A removal reports as it goes, and holds what it reports into.
 *
 * The panel draws from each report, so a removal that reported once at the
 * start and once at the end left the count standing at its first value for
 * the whole run. The owner is reffed, because a removal of thousands of
 * charts outlives the window that asked for it. */
static void
test_a_removal_reports_every_step (void)
{
  g_autoptr (GObject) owner = g_object_new (G_TYPE_OBJECT, NULL);
  g_autofree char *root = g_build_filename (lk_chart_bake_root (), "reported", NULL);

  place_prepared (root, "US3CU1EF/US3CU1EF.pmtiles");
  place_prepared (root, "US4TE3W0/US4TE3W0.pmtiles");
  place_prepared (root, "US5MD1MC/US5MD1MC.pmtiles");

  removal_reports = 0;
  g_assert_true (lk_chart_bake_delete_derived (root, "three", count_removal, owner));

  /* The owner is held for the length of the removal. */
  g_assert_cmpuint (owner->ref_count, >, 1);

  for (int i = 0; i < 400 && removal_reports < 4; i++)
    {
      g_main_context_iteration (NULL, FALSE);
      g_usleep (5000);
    }

  /* One per chart, and a last one with an empty name to close the panel. A
   * report can ride along with one already on its way, so the floor is what
   * this checks. */
  g_assert_cmpuint (removal_reports, >=, 2);
  g_assert_false (g_file_test (root, G_FILE_TEST_EXISTS));
}

/* Wait for a set's row to report `want` files to prepare. Bounded, because
 * the scan runs on the core's own thread. */
static gboolean
wait_for_to_prepare (LkChartSets *sets, const char *path, guint want)
{
  for (int i = 0; i < 400; i++)
    {
      g_autoptr (GPtrArray) rows = lk_chart_sets_rows (sets);

      for (guint r = 0; r < rows->len; r++)
        {
          const LkChartSetRow *row = g_ptr_array_index (rows, r);

          if (g_strcmp0 (row->path, path) == 0 && row->scanned &&
              row->to_prepare == want)
            return TRUE;
        }
      g_main_context_iteration (NULL, FALSE);
      g_usleep (5000);
    }
  return FALSE;
}

/* The core lists the files a set has to prepare, and names them.
 *
 * The list includes a cell whose prepared chart is older than it, which a
 * NOAA update leaves behind. A prepared chart that the core accepts is a real
 * pmtiles of a few megabytes, and this suite ships none, so the stale half of
 * the rule is checked by hand against a prepared library. */
static void
test_the_core_lists_what_a_set_has_to_prepare (void)
{
  g_autoptr (GObject) owner = g_object_new (G_TYPE_OBJECT, NULL);
  LkChartSets *sets = lk_chart_sets_new (noop_changed, owner);
  g_autofree char *dir = g_build_filename (home, "to-prepare", NULL);

  place_cell (dir, "US3CU1EF.000");
  g_assert_true (lk_chart_sets_note (sets, dir));
  g_assert_true (wait_for_to_prepare (sets, dir, 1));

  gsize n = 0;
  const lookout_chart_file *const *listed = lk_chart_sets_to_prepare (sets, dir, &n);

  g_assert_cmpuint (n, ==, 1);
  g_assert_cmpstr (listed[0]->name, ==, "US3CU1EF");
  g_assert_cmpint (listed[0]->kind, ==, LOOKOUT_FILE_SOURCE);

  lk_chart_sets_free (sets);
}

/* A folder the app did not download is never deleted through an apply. */
static void
test_only_the_downloads_directory_is_given_back (void)
{
  g_autoptr (LkAppModel) model = lk_app_model_new ();
  lookout_noaa *service = lk_noaa_service (lk_app_model_get_noaa (model));
  g_autofree char *mine = g_build_filename (home, "my-cells", NULL);

  place_cell (mine, "US3CU1EF.000");
  g_assert_cmpuint (lookout_noaa_apply (service, "", mine, 0), ==, 0);
  g_assert_true (g_file_test (mine, G_FILE_TEST_IS_DIR));
}

int
main (int argc, char *argv[])
{
  /* Before anything asks GLib for a directory: the store, the recents and the
   * set list must land where this run can throw them away. */
  home = g_dir_make_tmp ("lk-library-test-XXXXXX", NULL);
  g_assert_nonnull (home);
  g_setenv ("HOME", home, TRUE);
  g_setenv ("XDG_CONFIG_HOME", g_build_filename (home, ".config", NULL), TRUE);
  g_setenv ("XDG_DATA_HOME", g_build_filename (home, ".local", "share", NULL), TRUE);
  g_setenv ("XDG_CACHE_HOME", g_build_filename (home, ".cache", NULL), TRUE);
  g_unsetenv ("LOOKOUT_OPEN");

  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/library/nothing-installed-opens-nothing",
                   test_nothing_installed_opens_nothing);
  g_test_add_func ("/library/env-open-wins", test_env_open_wins);
  g_test_add_func ("/library/nothing-to-draw", test_nothing_to_draw);
  g_test_add_func ("/library/pictures-in-a-pick", test_pictures_in_a_pick);
  g_test_add_func ("/library/a-set-with-prepared-charts-is-derived",
                   test_a_set_with_prepared_charts_is_derived);
  g_test_add_func ("/library/the-core-lists-what-a-set-has-to-prepare",
                   test_the_core_lists_what_a_set_has_to_prepare);
  g_test_add_func ("/library/a-removal-reports-every-step",
                   test_a_removal_reports_every_step);
  g_test_add_func ("/library/the-whole-download-goes", test_the_whole_download_goes);
  g_test_add_func ("/library/only-the-downloads-directory-is-given-back",
                   test_only_the_downloads_directory_is_given_back);
  g_test_add_func ("/library/an-emptied-set-leaves-the-list",
                   test_an_emptied_set_leaves_the_list);
  g_test_add_func ("/library/a-managed-set-says-so-on-its-row",
                   test_a_managed_set_says_so_on_its_row);

  return g_test_run ();
}
