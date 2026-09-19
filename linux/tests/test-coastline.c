/* test-coastline.c — the first-run data the binary carries, and the
 * projection the coverage picker draws through.
 *
 * The picker has to draw on its first frame, with no camera and no tiles, so
 * everything it draws from is a resource in the binary: the coastline, and the
 * pictures the welcome step and the chart shelf show. All of it is checked
 * here, along with the numbers a panel places its points with.
 *
 * No display. The resources are compiled in, so nothing here reads a file.
 */

#include "ui/charts/catalog.h"
#include "ui/charts/coastline.h"

#include <math.h>

/* The resource parses, and it holds both kinds of ring. Land with no lakes
 * draws a Great Lakes coast as solid ground. */
static void
test_rings_load (void)
{
  guint n = 0;
  const LkCoastRing *rings = lk_coastline_rings (&n);
  guint land = 0, lakes = 0;

  g_assert_nonnull (rings);
  g_assert_cmpuint (n, >, 100);

  for (guint i = 0; i < n; i++)
    {
      const LkCoastRing *ring = &rings[i];

      g_assert_cmpuint (ring->n, >, 0);
      g_assert_nonnull (ring->points);
      if (ring->level == 1)
        land++;
      else if (ring->level == 2)
        lakes++;

      /* The extent is the ring's own, and every point is on the planet. */
      g_assert_cmpfloat (ring->west, <=, ring->east);
      g_assert_cmpfloat (ring->south, <=, ring->north);
      for (guint p = 0; p < ring->n; p++)
        {
          double lon = ring->points[p * 2];
          double lat = ring->points[p * 2 + 1];

          g_assert_cmpfloat (lon, >=, -180.0);
          g_assert_cmpfloat (lon, <=, 180.0);
          g_assert_cmpfloat (lat, >=, -90.0);
          g_assert_cmpfloat (lat, <=, 90.0);
          g_assert_cmpfloat (lon, >=, ring->west);
          g_assert_cmpfloat (lon, <=, ring->east);
          g_assert_cmpfloat (lat, >=, ring->south);
          g_assert_cmpfloat (lat, <=, ring->north);
        }
    }

  g_assert_cmpuint (land, >, 0);
  g_assert_cmpuint (lakes, >, 0);

  /* Read once. The second call is the same table. */
  guint again = 0;
  g_assert_true (lk_coastline_rings (&again) == rings);
  g_assert_cmpuint (again, ==, n);
}

/* A ring spanning more than 180 degrees of longitude crosses the
 * antimeridian. Drawn through a linear projection it is a band across the
 * whole panel, so none reaches the picker. */
static void
test_no_wrapped_rings (void)
{
  guint n = 0;
  const LkCoastRing *rings = lk_coastline_rings (&n);

  for (guint i = 0; i < n; i++)
    g_assert_cmpfloat (rings[i].east - rings[i].west, <=, 180.0);
}

/* The lower 48 as the picker frames it. The panel is wider than it is tall,
 * and a window is never stretched: the aspect comes from the projection. */
static void
test_window_aspect (void)
{
  const LkMapWindow lower48 = { .west = -132, .east = -64, .south = 20, .north = 52 };
  const LkMapWindow hawaii = { .west = -161, .east = -154, .south = 18.3, .north = 22.6 };
  double wide = lk_map_window_aspect (&lower48);

  /* 68 degrees of longitude over 32 of latitude, in Mercator. */
  g_assert_cmpfloat (wide, >, 1.5);
  g_assert_cmpfloat (wide, <, 2.5);
  g_assert_cmpfloat (lk_map_window_aspect (&hawaii), >, 1.0);

  /* A window of no height cannot be divided by. */
  const LkMapWindow flat = { .west = -10, .east = 10, .south = 5, .north = 5 };
  g_assert_cmpfloat (lk_map_window_aspect (&flat), ==, 1.0);
}

/* Where a point lands in a panel. The corners are the corners, the centre of
 * longitude is halfway across, and north is up. */
static void
test_window_point (void)
{
  const LkMapWindow window = { .west = -132, .east = -64, .south = 20, .north = 52 };
  double x = -1, y = -1;

  lk_map_window_point (&window, -132, 52, 680, 320, &x, &y);
  g_assert_cmpfloat (fabs (x), <, 0.001);
  g_assert_cmpfloat (fabs (y), <, 0.001);

  lk_map_window_point (&window, -64, 20, 680, 320, &x, &y);
  g_assert_cmpfloat (fabs (x - 680), <, 0.001);
  g_assert_cmpfloat (fabs (y - 320), <, 0.001);

  /* Longitude is linear, so the middle meridian is the middle of the panel. */
  lk_map_window_point (&window, -98, 36, 680, 320, &x, &y);
  g_assert_cmpfloat (fabs (x - 340), <, 0.001);

  /* Mercator stretches toward the pole, so the middle PARALLEL is not the
   * middle of the panel. The northern half of the window takes more of the
   * height, which puts 36 degrees BELOW the halfway line. */
  g_assert_cmpfloat (y, >, 160);
  g_assert_cmpfloat (y, <, 200);
  double mid_parallel = y;

  /* Annapolis, in the panel it belongs to: east of the middle meridian, and
   * north of the middle parallel. */
  lk_map_window_point (&window, -76.48, 38.97, 680, 320, &x, &y);
  g_assert_cmpfloat (x, >, 340);
  g_assert_cmpfloat (x, <, 680);
  g_assert_cmpfloat (y, >, 0);
  g_assert_cmpfloat (y, <, mid_parallel);
}

/* A panel draws the rings that reach into it and skips the rest. There are
 * 1,538 of them and three panels. */
static void
test_window_intersects (void)
{
  const LkMapWindow window = { .west = -132, .east = -64, .south = 20, .north = 52 };

  /* Inside, overlapping each edge, and containing the window. */
  g_assert_true (lk_map_window_intersects (&window, -100, -90, 30, 40));
  g_assert_true (lk_map_window_intersects (&window, -140, -130, 30, 40));
  g_assert_true (lk_map_window_intersects (&window, -70, -50, 30, 40));
  g_assert_true (lk_map_window_intersects (&window, -180, 180, -90, 90));

  /* Clear of it on each side. */
  g_assert_false (lk_map_window_intersects (&window, -160, -140, 30, 40));
  g_assert_false (lk_map_window_intersects (&window, -50, -40, 30, 40));
  g_assert_false (lk_map_window_intersects (&window, -100, -90, 60, 70));
  g_assert_false (lk_map_window_intersects (&window, -100, -90, 5, 15));

  /* Touching an edge counts: a coast on the frame draws. */
  g_assert_true (lk_map_window_intersects (&window, -140, -132, 30, 40));
}

/* Mercator is clamped clear of the poles, where the projection runs away. */
static void
test_mercator_clamp (void)
{
  g_assert_cmpfloat (fabs (lk_mercator_y (0)), <, 0.001);
  g_assert_cmpfloat (lk_mercator_y (45), >, 0);
  g_assert_cmpfloat (lk_mercator_y (-45), <, 0);
  g_assert_cmpfloat (lk_mercator_y (90), ==, lk_mercator_y (85.05));
  g_assert_cmpfloat (lk_mercator_y (-90), ==, lk_mercator_y (-85.05));
  g_assert_true (isfinite (lk_mercator_y (90)));
  g_assert_true (isfinite (lk_mercator_y (-90)));
}

/* Every picture the app ships decodes out of the binary.
 *
 * A missing one draws a grey box in front of a mariner on the first screen
 * they ever see, so it fails a test instead. */
static void
test_shipped_pictures (void)
{
  guint n = 0;
  const LkChartCatalogEntry *entries = lk_chart_catalog_entries (&n);
  GdkTexture *hero = lk_chart_welcome_picture ();

  g_assert_nonnull (hero);
  g_assert_cmpint (gdk_texture_get_width (hero), >, 600);
  g_assert_cmpint (gdk_texture_get_height (hero), >, 200);

  g_assert_cmpuint (n, >, 0);
  for (guint i = 0; i < n; i++)
    {
      GdkTexture *art;

      g_assert_nonnull (entries[i].name);
      g_assert_nonnull (entries[i].url);
      g_assert_true (g_str_has_prefix (entries[i].url, "https://"));
      g_assert_nonnull (entries[i].art);

      art = lk_chart_catalog_art (entries[i].url);
      g_assert_nonnull (art);
      g_assert_cmpint (gdk_texture_get_width (art), >, 400);
      g_assert_cmpint (gdk_texture_get_height (art), >, 300);

      /* Decoded once and kept: a shelf redraws whenever the list moves. */
      g_assert_true (lk_chart_catalog_art (entries[i].url) == art);

      /* By url, and by the entry's own url. */
      g_assert_true (lk_chart_catalog_entry (entries[i].url) == &entries[i]);
    }

  /* A link the mariner added has no shipped picture, and neither has nothing. */
  g_assert_null (lk_chart_catalog_entry ("https://example.org/style.json"));
  g_assert_null (lk_chart_catalog_art ("https://example.org/style.json"));
  g_assert_null (lk_chart_catalog_entry (NULL));
  g_assert_null (lk_chart_catalog_art (NULL));
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/coastline/rings-load", test_rings_load);
  g_test_add_func ("/coastline/no-wrapped-rings", test_no_wrapped_rings);
  g_test_add_func ("/coastline/window-aspect", test_window_aspect);
  g_test_add_func ("/coastline/window-point", test_window_point);
  g_test_add_func ("/coastline/window-intersects", test_window_intersects);
  g_test_add_func ("/coastline/mercator-clamp", test_mercator_clamp);
  g_test_add_func ("/coastline/shipped-pictures", test_shipped_pictures);

  return g_test_run ();
}
