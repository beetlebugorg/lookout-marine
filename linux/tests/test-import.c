/* test-import.c — the one-time read of a settings.ini a mariner already has.
 *
 * Builds before the core owned the settings file wrote a GKeyFile beside where
 * settings.json goes now. Everything in it has to arrive in the store under the
 * same group and key names, once, and the ini has to be left where it is.
 *
 * Its own binary, because the read happens at the first store call: another
 * suite's fresh store would be seeded by it.
 */

#include "model/store.h"

static const char lk_test_ini[] =
    "[view]\n"
    "lon=-76.4820\n"
    "lat=38.9760\n"
    "zoom=13.7\n"
    "rotation_deg=45\n"
    "\n[recents]\n"
    "paths=/charts/one;/charts/two;\n"
    "\n[raster]\n"
    "paths=/rasters/a.mbtiles;/rasters/b.mbtiles;\n"
    "off=/rasters/b.mbtiles;\n"
    "hidden=harbor;\n"
    "chart_hidden=true\n"
    "\n[chartsets]\n"
    "paths=/charts/noaa;\n"
    "off=/charts/old;\n"
    "\n[chartlinks]\n"
    "links=[{\"url\":\"https://example.org/style.json\"}]\n"
    "active=https://example.org/style.json\n"
    "\n[mariner.v1]\n"
    "scheme=2\n"
    "depth_unit=1\n"
    "safety_contour=15\n"
    "size_scale=1.25\n"
    "text_names=false\n"
    "date_view=20240101\n"
    "\n[plugins.v1]\n"
    "org.beetlebug.ais={\"cpa_limit\":1500,\"cpa_alarm\":false}\n";

static char *lk_test_ini_path;

/* The pose, the lists and the flag all cross under the names they had. */
static void
test_the_shell_values_cross (void)
{
  g_assert_true (lk_store_has_saved_view ());

  g_auto (GStrv) recents = lk_store_load_recents ();
  g_assert_cmpuint (g_strv_length (recents), ==, 2);
  g_assert_cmpstr (recents[0], ==, "/charts/one");

  g_auto (GStrv) raster = lk_store_load_raster_paths ();
  g_auto (GStrv) off = lk_store_load_raster_off ();
  g_auto (GStrv) hidden = lk_store_load_raster_hidden ();
  g_assert_cmpuint (g_strv_length (raster), ==, 2);
  g_assert_cmpstr (raster[1], ==, "/rasters/b.mbtiles");
  g_assert_cmpuint (g_strv_length (off), ==, 1);
  g_assert_cmpstr (hidden[0], ==, "harbor");
  g_assert_true (lk_store_load_chart_hidden ());

  /* A library that was saved stays saved: absent and empty are different
   * answers, and this one is neither. */
  g_auto (GStrv) sets = lk_store_load_chart_sets ();
  g_assert_nonnull (sets);
  g_assert_cmpstr (sets[0], ==, "/charts/noaa");
  g_auto (GStrv) sets_off = lk_store_load_chart_sets_off ();
  g_assert_cmpstr (sets_off[0], ==, "/charts/old");

  g_autofree char *links = lk_store_load_chart_links ();
  g_autofree char *active = lk_store_load_chart_link_active ();
  g_assert_true (g_str_has_prefix (links, "[{"));
  g_assert_cmpstr (active, ==, "https://example.org/style.json");

  g_autofree char *config = lk_store_load_plugin_config ("org.beetlebug.ais");
  g_assert_cmpstr (config, ==, "{\"cpa_limit\":1500,\"cpa_alarm\":false}");
  g_auto (GStrv) ids = lk_store_load_plugin_ids ();
  g_assert_cmpstr (ids[0], ==, "org.beetlebug.ais");
}

/* The mariner's own choices, read back the way a chartless settings form
 * reads them. A field the ini never named keeps the engine's default. */
static void
test_the_mariner_settings_cross (void)
{
  tile57_mariner m;

  lookout_mariner_defaults (&m);
  lookout_store_read_mariner (lk_store_handle (), &m);

  g_assert_cmpint (m.scheme, ==, TILE57_SCHEME_NIGHT);
  g_assert_cmpint (m.depth_unit, ==, TILE57_DEPTH_FEET);
  g_assert_cmpfloat (m.safety_contour, ==, 15.0);
  g_assert_cmpfloat (m.size_scale, ==, 1.25);
  g_assert_false (m.text_names);
  g_assert_cmpstr (m.date_view, ==, "20240101");

  tile57_mariner defaults;
  lookout_mariner_defaults (&defaults);
  g_assert_cmpfloat (m.deep_contour, ==, defaults.deep_contour);
}

/* Read once, and the file stays: a mariner who goes back to the build that
 * wrote it finds their settings where that build left them. */
static void
test_the_ini_is_read_once_and_left (void)
{
  g_assert_true (g_file_test (lk_test_ini_path, G_FILE_TEST_EXISTS));
  g_assert_true (lookout_store_flag (lk_store_handle (), LOOKOUT_STORE_VIEW,
                                     "imported", 0));
}

int
main (int argc, char *argv[])
{
  /* Before anything asks GLib for the config dir: the store must land in a
   * directory this run owns and throws away. */
  g_autofree char *config_dir = g_dir_make_tmp ("lk-import-test-XXXXXX", NULL);
  g_assert_nonnull (config_dir);
  g_setenv ("XDG_CONFIG_HOME", config_dir, TRUE);

  g_autofree char *dir = g_build_filename (config_dir, "lookout-marine", NULL);
  g_assert_cmpint (g_mkdir_with_parents (dir, 0700), ==, 0);
  lk_test_ini_path = g_build_filename (dir, "settings.ini", NULL);
  g_assert_true (g_file_set_contents (lk_test_ini_path, lk_test_ini, -1, NULL));

  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/import/shell-values", test_the_shell_values_cross);
  g_test_add_func ("/import/mariner", test_the_mariner_settings_cross);
  g_test_add_func ("/import/once", test_the_ini_is_read_once_and_left);

  return g_test_run ();
}
