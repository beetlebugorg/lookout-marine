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

  return g_test_run ();
}
