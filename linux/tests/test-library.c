/* test-library.c — what the app opens on its own, and what counts as drawable.
 *
 * The decision behind the first-run page. An app with an empty library must
 * open a chart of no charts and say so, and it must not reach for a cell some
 * other program left in a cache: a chart the mariner never installed keeps
 * setup down on the one run that needs it.
 *
 * No display. This is the model's answer, read directly.
 */

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

/* The cell names NOAA is told about, off a set the scan has read.
 *
 * This is what stops a mariner paying twice for water they already hold, so
 * what counts and what does not is the whole point: a cell counts once
 * however many folders hold it, and a picture is not a cell at all.
 *
 * Real cells. The scan reads the surveys themselves, so a dataset name on an
 * empty file reports no chart, which is right and proves nothing.
 */
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

/* The names off one set, once the scan has landed. Bounded: the scan runs on
 * the core's own thread. */
static char **
wait_for_names (LkChartSets *sets)
{
  char **names = NULL;

  for (int i = 0; i < 400; i++)
    {
      g_strfreev (names);
      names = lk_chart_sets_cell_names (sets);
      if (g_strv_length (names) > 0)
        return names;
      g_main_context_iteration (NULL, FALSE);
      g_usleep (5000);
    }
  return names;
}

static void
test_installed_cell_names (void)
{
  g_autoptr (GObject) owner = g_object_new (G_TYPE_OBJECT, NULL);
  LkChartSets *sets = lk_chart_sets_new (noop_changed, owner);
  g_autofree char *dir = g_build_filename (home, "enc", "ENC_ROOT", NULL);
  g_autofree char *nested = g_build_filename (dir, "US3CU1EF", NULL);

  place_cell (dir, "US3CU1EF.000");
  place_cell (dir, "US4TE3W0.000");
  /* The same cell again, one directory down. A library that holds a cell
   * twice holds it once. */
  place_cell (nested, "US3CU1EF.000");

  /* Not cells: a picture and a readme. NOAA publishes neither. */
  g_autofree char *picture = g_build_filename (dir, "imagery.mbtiles", NULL);
  g_autofree char *readme = g_build_filename (dir, "README.TXT", NULL);
  g_assert_true (g_file_set_contents (picture, "", 0, NULL));
  g_assert_true (g_file_set_contents (readme, "not a chart", -1, NULL));

  g_assert_true (lk_chart_sets_note (sets, dir));

  g_auto (GStrv) names = wait_for_names (sets);

  g_assert_cmpuint (g_strv_length (names), ==, 2);
  g_assert_true (g_strv_contains ((const char *const *) names, "US3CU1EF"));
  g_assert_true (g_strv_contains ((const char *const *) names, "US4TE3W0"));

  lk_chart_sets_free (sets);
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
  g_test_add_func ("/library/installed-cell-names", test_installed_cell_names);

  return g_test_run ();
}
