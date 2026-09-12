/* test-preview.c — where a chart's picture is kept.
 *
 * Every chart on a list is pictured at the same point, the one the mariner is
 * looking at, so what differs between the cards is the portrayal. The cache
 * key is what decides when a picture still applies: a mariner working one
 * harbour must keep the pictures they have, and one who has sailed to the next
 * bay must not be shown the water they left.
 *
 * No display, and no network: the key and the tile arithmetic are pure.
 */

#include "library/preview.h"

/* The tile a point falls in, as every tile server counts them. */
static void
test_tile_numbers (void)
{
  int x = -1, y = -1;

  /* Zoom 0 is one tile, and everything is in it. */
  lk_chart_preview_tile (-76.48, 38.97, 0, &x, &y);
  g_assert_cmpint (x, ==, 0);
  g_assert_cmpint (y, ==, 0);

  /* Null Island at zoom 1 is the south-east of the four. */
  lk_chart_preview_tile (0.0001, -0.0001, 1, &x, &y);
  g_assert_cmpint (x, ==, 1);
  g_assert_cmpint (y, ==, 1);

  /* Annapolis at the zoom a preview is fetched at. Checked against the
   * standard slippy numbers for z9. */
  lk_chart_preview_tile (-76.48, 38.97, 9, &x, &y);
  g_assert_cmpint (x, ==, 147);
  g_assert_cmpint (y, ==, 195);

  /* The poles are clamped, so a tile number is always on the grid. */
  lk_chart_preview_tile (0, 90, 9, &x, &y);
  g_assert_cmpint (y, >=, 0);
  g_assert_cmpint (y, <, 512);
  lk_chart_preview_tile (0, -90, 9, &x, &y);
  g_assert_cmpint (y, >=, 0);
  g_assert_cmpint (y, <, 512);
}

/* One picture per chart per tile of water. */
static void
test_cache_key (void)
{
  const char *seascape = "https://tiles.openwaters.io/seascape/style.json";
  const char *seamap = "https://tiles.openwaters.io/seamap/style.json";

  g_autofree char *a = lk_chart_preview_cache_path (seascape, -76.48, 38.97,
                                                    LK_PREVIEW_ZOOM);
  /* The same chart, a mile up the Severn: the same preview tile, so the
   * picture a mariner already has still applies. */
  g_autofree char *near = lk_chart_preview_cache_path (seascape, -76.46, 38.99,
                                                       LK_PREVIEW_ZOOM);
  /* The same chart on the other side of the country: a different picture. */
  g_autofree char *far = lk_chart_preview_cache_path (seascape, -122.40, 37.80,
                                                      LK_PREVIEW_ZOOM);
  /* A different chart at the same water: a different picture. That is the
   * whole point of the shelf. */
  g_autofree char *other = lk_chart_preview_cache_path (seamap, -76.48, 38.97,
                                                        LK_PREVIEW_ZOOM);
  /* Lookout's own chart has no url. */
  g_autofree char *own = lk_chart_preview_cache_path (NULL, -76.48, 38.97,
                                                      LK_PREVIEW_ZOOM);

  g_assert_cmpstr (a, ==, near);
  g_assert_cmpstr (a, !=, far);
  g_assert_cmpstr (a, !=, other);
  g_assert_cmpstr (a, !=, own);

  /* Under the cache, with a name and nothing of the url in it: a style link
   * holds a publisher, a path and often a key, and none of that belongs in a
   * file name. */
  g_assert_true (g_str_has_prefix (a, g_get_user_cache_dir ()));
  g_assert_true (strstr (a, "lookout-marine") != NULL);
  g_assert_true (g_str_has_suffix (a, ".png"));
  g_assert_null (strstr (a, "openwaters"));
  g_assert_null (strstr (a, "/style.json"));

  /* The same ask twice is the same answer. */
  g_autofree char *again = lk_chart_preview_cache_path (seascape, -76.48, 38.97,
                                                        LK_PREVIEW_ZOOM);
  g_assert_cmpstr (a, ==, again);
}

/* The zoom a preview is taken at is part of the key: a picture taken for one
 * list must not be handed to a list that asks at another scale. */
static void
test_zoom_in_the_key (void)
{
  const char *url = "https://example.org/style.json";
  g_autofree char *nine = lk_chart_preview_cache_path (url, -76.48, 38.97, 9);
  g_autofree char *ten = lk_chart_preview_cache_path (url, -76.48, 38.97, 10);

  g_assert_cmpstr (nine, !=, ten);
}

int
main (int argc, char *argv[])
{
  g_autofree char *cache = g_dir_make_tmp ("lk-preview-test-XXXXXX", NULL);

  g_assert_nonnull (cache);
  g_setenv ("XDG_CACHE_HOME", cache, TRUE);

  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/preview/tile-numbers", test_tile_numbers);
  g_test_add_func ("/preview/cache-key", test_cache_key);
  g_test_add_func ("/preview/zoom-in-the-key", test_zoom_in_the_key);

  return g_test_run ();
}
