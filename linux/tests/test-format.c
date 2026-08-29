/* test-format.c — the readout formatters in ui/hud/hud.c.
 *
 * Each format agrees with CoordFormat (macOS and iOS), lkw::FormatCoord
 * (Windows) and Hud.kt (Android). The expected strings here are the strings
 * the macOS shell prints, so a drift on either side fails this suite.
 */

#include "ui/hud/hud.h"
#include "ui/chart/view.h"

static void
assert_coord (double value, gboolean is_lat, const char *expected)
{
  g_autofree char *got = lk_coord_format_dm (value, is_lat);
  g_assert_cmpstr (got, ==, expected);
}

static void
test_coord_dm_basic (void)
{
  /* Degrees and decimal minutes. Latitude has two degree digits, longitude
   * three, so a pair keeps its column width. */
  assert_coord (38.9763, TRUE, "38\302\26058.578'N");
  assert_coord (-76.4767, FALSE, "076\302\26028.602'W");
  assert_coord (2.5, TRUE, "02\302\26030.000'N");
  assert_coord (-2.5, TRUE, "02\302\26030.000'S");
  assert_coord (151.2093, FALSE, "151\302\26012.558'E");
}

static void
test_coord_dm_zero (void)
{
  /* Zero is north and east: value >= 0 picks the positive hemisphere. */
  assert_coord (0.0, TRUE, "00\302\26000.000'N");
  assert_coord (0.0, FALSE, "000\302\26000.000'E");
}

static void
test_coord_dm_carry (void)
{
  /* 59.9996' rounds to 60.000', which must carry into the next degree. */
  assert_coord (38.0 + 59.9996 / 60.0, TRUE, "39\302\26000.000'N");
  assert_coord (-(179.0 + 59.9996 / 60.0), FALSE, "180\302\26000.000'W");
  /* Just under the carry threshold stays put. */
  assert_coord (38.0 + 59.999 / 60.0, TRUE, "38\302\26059.999'N");
}

static void
assert_scale (double denominator, const char *expected)
{
  g_autofree char *got = lk_format_scale (denominator);
  g_assert_cmpstr (got, ==, expected);
}

static void
test_scale_grouping (void)
{
  assert_scale (999, "1:999");
  assert_scale (1000, "1:1,000");
  assert_scale (13267, "1:13,267");
  assert_scale (1234567, "1:1,234,567");
  assert_scale (100000000, "1:100,000,000");
}

static void
test_scale_rounding (void)
{
  assert_scale (2499.6, "1:2,500");
  assert_scale (2499.4, "1:2,499");
}

static void
test_scale_empty (void)
{
  /* No chart open reads as no scale, never as a zero. */
  assert_scale (0, "1:\342\200\224");
  assert_scale (-5, "1:\342\200\224");
}

static void
test_band_thresholds (void)
{
  /* The S-52 navigational purpose bands, same fences as every shell. */
  g_assert_cmpstr (lk_format_band (0.0005), ==, "\342\200\224");
  g_assert_cmpstr (lk_format_band (2000), ==, "Berthing");
  g_assert_cmpstr (lk_format_band (4999.9), ==, "Berthing");
  g_assert_cmpstr (lk_format_band (5000), ==, "Harbor");
  g_assert_cmpstr (lk_format_band (24999.9), ==, "Harbor");
  g_assert_cmpstr (lk_format_band (25000), ==, "Approach");
  g_assert_cmpstr (lk_format_band (74999.9), ==, "Approach");
  g_assert_cmpstr (lk_format_band (75000), ==, "Coastal");
  g_assert_cmpstr (lk_format_band (299999.9), ==, "Coastal");
  g_assert_cmpstr (lk_format_band (300000), ==, "General");
  g_assert_cmpstr (lk_format_band (1499999.9), ==, "General");
  g_assert_cmpstr (lk_format_band (1500000), ==, "Overview");
  g_assert_cmpstr (lk_format_band (50000000), ==, "Overview");
}

static void
test_scale_bar_cap (void)
{
  /* The bar picks the largest nice distance that fits its target width, so the
     drawn width never passes the target cap. The nice table now reaches down to
     1 m, so it fits every real chart scale — including the small scales near
     1:360 that once had no nice distance small enough. */
  static const double denominators[] = {
    100, 200, 360, 500, 1000, 5000, 13267, 50000, 250000, 1500000,
  };
  for (gsize i = 0; i < G_N_ELEMENTS (denominators); i++)
    {
      double width = 0;
      double metres = lk_scale_bar_nice_metres (denominators[i], &width);
      g_assert_cmpfloat (metres, >, 0);
      g_assert_cmpfloat (width, >, 0);
      g_assert_cmpfloat (width, <=, 140.0 + 1e-6);
    }
}

static void
test_unwrap_angle (void)
{
  const double pi = G_PI;

  /* Already inside (−π, π] passes through. */
  g_assert_cmpfloat (fabs (lk_chart_view_unwrap_angle (0.0)), <, 1e-9);
  g_assert_cmpfloat (fabs (lk_chart_view_unwrap_angle (1.0) - 1.0), <, 1e-9);
  g_assert_cmpfloat (fabs (lk_chart_view_unwrap_angle (-1.0) + 1.0), <, 1e-9);

  /* A small turn reported near 2π folds back to a small angle, so the dead-zone
     test sees the true magnitude instead of a near-full turn. */
  g_assert_cmpfloat (fabs (lk_chart_view_unwrap_angle (2.0 * pi - 0.05) + 0.05), <, 1e-9);
  g_assert_cmpfloat (fabs (lk_chart_view_unwrap_angle (2.0 * pi + 0.05) - 0.05), <, 1e-9);

  /* The wrap point stays continuous either side of π. */
  g_assert_cmpfloat (lk_chart_view_unwrap_angle (pi), >, pi - 1e-9);
  g_assert_cmpfloat (lk_chart_view_unwrap_angle (pi + 0.01), <, 0);
  g_assert_cmpfloat (fabs (lk_chart_view_unwrap_angle (4.0 * pi)), <, 1e-9);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/format/rotate/unwrap", test_unwrap_angle);
  g_test_add_func ("/format/scale-bar/cap", test_scale_bar_cap);
  g_test_add_func ("/format/coord/basic", test_coord_dm_basic);
  g_test_add_func ("/format/coord/zero", test_coord_dm_zero);
  g_test_add_func ("/format/coord/carry", test_coord_dm_carry);
  g_test_add_func ("/format/scale/grouping", test_scale_grouping);
  g_test_add_func ("/format/scale/rounding", test_scale_rounding);
  g_test_add_func ("/format/scale/empty", test_scale_empty);
  g_test_add_func ("/format/band/thresholds", test_band_thresholds);

  return g_test_run ();
}
