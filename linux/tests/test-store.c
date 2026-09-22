/* test-store.c: what the shell keeps across launches.
 *
 * The core owns the file and its format; what is checked here is the shell's
 * own reading of it, and the one-time read of a settings.ini a mariner already
 * has. The store lands under $XDG_CONFIG_HOME, so the suite points that at a
 * fresh directory before GLib caches the path.
 */

#include "model/store.h"

/* An emptied record still counts as a record.
 *
 * The picker adopts every whole region a library holds when this device has
 * recorded none. A mariner who gives back the only region they held leaves an
 * empty record. The store drops a key set to an empty list, so the list alone
 * cannot distinguish the two cases. Without the flag the picker ticked that
 * water again on the next open. */
static void
test_noaa_regions_record (void)
{
  static const char *const one[] = { "d1", NULL };
  static const char *const none[] = { NULL };

  g_assert_false (lk_store_noaa_regions_recorded ());

  lk_store_save_noaa_regions (one);
  g_assert_true (lk_store_noaa_regions_recorded ());

  g_auto (GStrv) held = lk_store_load_noaa_regions ();
  g_assert_cmpuint (g_strv_length (held), ==, 1);
  g_assert_cmpstr (held[0], ==, "d1");

  /* Given back. The list is empty and the flag remains set. */
  lk_store_save_noaa_regions (none);
  g_auto (GStrv) after = lk_store_load_noaa_regions ();
  g_assert_cmpuint (g_strv_length (after), ==, 0);
  g_assert_true (lk_store_noaa_regions_recorded ());

  /* And back to a device that has never downloaded anything. */
  lk_store_forget_noaa_regions ();
  g_assert_false (lk_store_noaa_regions_recorded ());
}

/* The NOAA update cadence, as the Charts page saves it. Daily on a device
 * that has never said. */
static void
test_noaa_update_cadence (void)
{
  g_autofree char *first = lk_store_load_noaa_update_check ();

  g_assert_cmpstr (first, ==, "daily");
  g_assert_cmpint (lk_store_load_noaa_update_checked (), ==, 0);

  lk_store_save_noaa_update_check ("startup");
  lk_store_save_noaa_update_checked (1700000000);

  g_autofree char *second = lk_store_load_noaa_update_check ();

  g_assert_cmpstr (second, ==, "startup");
  g_assert_cmpint (lk_store_load_noaa_update_checked (), ==, 1700000000);
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

  g_test_add_func ("/store/noaa-regions", test_noaa_regions_record);
  g_test_add_func ("/store/noaa-update-cadence", test_noaa_update_cadence);
  g_test_add_func ("/store/recents", test_recents_order_and_cap);
  g_test_add_func ("/store/raster", test_raster_roundtrip);
  g_test_add_func ("/store/raster-all", test_raster_all_roundtrip);
  g_test_add_func ("/store/plugin-config", test_plugin_config_roundtrip);
  g_test_add_func ("/store/chart-links", test_chart_links_roundtrip);

  return g_test_run ();
}
