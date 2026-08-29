/* test-store.c — the settings keyfile behind every persisted choice.
 *
 * The store writes $XDG_CONFIG_HOME/lookout-marine/settings.ini, so the suite
 * points XDG_CONFIG_HOME at a fresh directory before GLib caches the path.
 * Each test then reads back what it wrote, the way a relaunch would.
 */

#include "model/store.h"

static void
test_view_roundtrip (void)
{
  lookout_view missing;
  /* Nothing saved yet reads as nothing, not as a zeroed pose. */
  g_assert_false (lk_store_load_view (&missing));

  lookout_view pose = { .lon = -76.4767, .lat = 38.9763, .zoom = 14.5,
                        .rotation_deg = 30.0 };
  lk_store_save_view (&pose);

  lookout_view loaded;
  g_assert_true (lk_store_load_view (&loaded));
  g_assert_cmpfloat (loaded.lon, ==, pose.lon);
  g_assert_cmpfloat (loaded.lat, ==, pose.lat);
  g_assert_cmpfloat (loaded.zoom, ==, pose.zoom);
  g_assert_cmpfloat (loaded.rotation_deg, ==, pose.rotation_deg);
}

static void
test_recents_order_and_cap (void)
{
  g_auto (GStrv) empty = lk_store_load_recents ();
  g_assert_nonnull (empty);
  g_assert_null (empty[0]);

  /* Most recent first, duplicates lifted to the front, capped at ten. */
  for (int i = 0; i < 12; i++)
    {
      g_autofree char *path = g_strdup_printf ("/charts/set-%d", i);
      lk_store_note_recent (path);
    }
  lk_store_note_recent ("/charts/set-5");

  g_auto (GStrv) recents = lk_store_load_recents ();
  g_assert_cmpuint (g_strv_length (recents), ==, 10);
  g_assert_cmpstr (recents[0], ==, "/charts/set-5");
  g_assert_cmpstr (recents[1], ==, "/charts/set-11");
  g_assert_cmpstr (recents[2], ==, "/charts/set-10");
}

static void
test_raster_roundtrip (void)
{
  const char *paths[] = { "/rasters/a.mbtiles", "/rasters/b.mbtiles", NULL };
  lk_store_save_raster_paths (paths);

  g_auto (GStrv) loaded = lk_store_load_raster_paths ();
  g_assert_cmpuint (g_strv_length (loaded), ==, 2);
  g_assert_cmpstr (loaded[0], ==, "/rasters/a.mbtiles");
  g_assert_cmpstr (loaded[1], ==, "/rasters/b.mbtiles");

  const char *off[] = { "/rasters/b.mbtiles", NULL };
  lk_store_save_raster_off (off);
  g_auto (GStrv) loaded_off = lk_store_load_raster_off ();
  g_assert_cmpuint (g_strv_length (loaded_off), ==, 1);

  g_assert_false (lk_store_load_chart_hidden ());
  lk_store_save_chart_hidden (TRUE);
  g_assert_true (lk_store_load_chart_hidden ());
  lk_store_save_chart_hidden (FALSE);
  g_assert_false (lk_store_load_chart_hidden ());
}

static void
test_raster_all_roundtrip (void)
{
  /* The batched write puts all three lists in one file pass. Each list reads
     back as itself, and an empty list clears its key. */
  const char *paths[] = { "/rasters/a.mbtiles", "/rasters/b.mbtiles", "/rasters/c.mbtiles", NULL };
  const char *off[] = { "/rasters/b.mbtiles", NULL };
  const char *hidden[] = { "harbor", "approach", NULL };

  lk_store_save_raster_all (paths, off, hidden);

  g_auto (GStrv) loaded = lk_store_load_raster_paths ();
  g_auto (GStrv) loaded_off = lk_store_load_raster_off ();
  g_auto (GStrv) loaded_hidden = lk_store_load_raster_hidden ();
  g_assert_cmpuint (g_strv_length (loaded), ==, 3);
  g_assert_cmpstr (loaded[2], ==, "/rasters/c.mbtiles");
  g_assert_cmpuint (g_strv_length (loaded_off), ==, 1);
  g_assert_cmpstr (loaded_off[0], ==, "/rasters/b.mbtiles");
  g_assert_cmpuint (g_strv_length (loaded_hidden), ==, 2);

  /* Empty lists clear their keys in the same one pass. */
  const char *none[] = { NULL };
  lk_store_save_raster_all (none, none, none);
  g_auto (GStrv) empty_paths = lk_store_load_raster_paths ();
  g_auto (GStrv) empty_off = lk_store_load_raster_off ();
  g_auto (GStrv) empty_hidden = lk_store_load_raster_hidden ();
  g_assert_cmpuint (g_strv_length (empty_paths), ==, 0);
  g_assert_cmpuint (g_strv_length (empty_off), ==, 0);
  g_assert_cmpuint (g_strv_length (empty_hidden), ==, 0);
}

static void
test_chart_sets_empty_vs_absent (void)
{
  /* Never saved answers NULL, so the caller seeds from the recents once. An
   * emptied library answers an empty list and never re-seeds. */
  g_assert_null (lk_store_load_chart_sets ());

  const char *none[] = { NULL };
  lk_store_save_chart_sets (none);
  g_auto (GStrv) emptied = lk_store_load_chart_sets ();
  g_assert_nonnull (emptied);
  g_assert_null (emptied[0]);

  const char *sets[] = { "/charts/noaa", "/charts/archive.zip", NULL };
  lk_store_save_chart_sets (sets);
  g_auto (GStrv) loaded = lk_store_load_chart_sets ();
  g_assert_cmpuint (g_strv_length (loaded), ==, 2);
}

static void
test_plugin_config_roundtrip (void)
{
  g_assert_null (lk_store_load_plugin_config ("org.example.none"));

  lk_store_save_plugin_config ("org.example.ais",
                               "{\"cpa_limit\":926,\"cpa_alarm\":true}");
  g_autofree char *json = lk_store_load_plugin_config ("org.example.ais");
  g_assert_cmpstr (json, ==, "{\"cpa_limit\":926,\"cpa_alarm\":true}");

  g_auto (GStrv) ids = lk_store_load_plugin_ids ();
  gboolean found = FALSE;
  for (guint i = 0; ids != NULL && ids[i] != NULL; i++)
    found = found || g_str_equal (ids[i], "org.example.ais");
  g_assert_true (found);
}

static void
test_chart_links_roundtrip (void)
{
  g_assert_null (lk_store_load_chart_links ());

  lk_store_save_chart_links ("[{\"url\":\"https://example.org/style.json\","
                             "\"name\":\"Seascape\"}]");
  g_autofree char *links = lk_store_load_chart_links ();
  g_assert_nonnull (links);
  g_assert_true (g_str_has_prefix (links, "[{"));

  lk_store_save_chart_link_active ("https://example.org/style.json");
  g_autofree char *active = lk_store_load_chart_link_active ();
  g_assert_cmpstr (active, ==, "https://example.org/style.json");
}

int
main (int argc, char *argv[])
{
  /* Before anything asks GLib for the config dir: the store must land in a
   * directory this run owns and throws away. */
  g_autofree char *config_dir = g_dir_make_tmp ("lk-store-test-XXXXXX", NULL);
  g_assert_nonnull (config_dir);
  g_setenv ("XDG_CONFIG_HOME", config_dir, TRUE);

  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/store/view-roundtrip", test_view_roundtrip);
  g_test_add_func ("/store/recents", test_recents_order_and_cap);
  g_test_add_func ("/store/raster", test_raster_roundtrip);
  g_test_add_func ("/store/raster-all", test_raster_all_roundtrip);
  g_test_add_func ("/store/chart-sets", test_chart_sets_empty_vs_absent);
  g_test_add_func ("/store/plugin-config", test_plugin_config_roundtrip);
  g_test_add_func ("/store/chart-links", test_chart_links_roundtrip);

  return g_test_run ();
}
