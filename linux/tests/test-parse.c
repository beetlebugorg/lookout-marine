/* test-parse.c — the tolerant parsers behind the search field and the scale
 * entry. They accept what CoordinateParser and ScaleParser accept on the other
 * shells, so a value read off one app types into another.
 */

#include "lk-app-model.h"

#include <math.h>

static void
assert_coordinate (const char *text, double lat, double lon)
{
  double got_lat = 999, got_lon = 999;
  gboolean ok = lk_coordinate_parse (text, &got_lat, &got_lon);
  g_assert_true (ok);
  g_assert_cmpfloat (fabs (got_lat - lat), <, 1e-6);
  g_assert_cmpfloat (fabs (got_lon - lon), <, 1e-6);
}

static void
assert_no_coordinate (const char *text)
{
  double lat, lon;
  g_assert_false (lk_coordinate_parse (text, &lat, &lon));
}

static void
test_coordinate_decimal (void)
{
  /* A decimal pair, latitude first, comma- or whitespace-separated. */
  assert_coordinate ("38.9763, -76.4767", 38.9763, -76.4767);
  assert_coordinate ("38.9763 -76.4767", 38.9763, -76.4767);
  assert_coordinate ("38.9763,-76.4767", 38.9763, -76.4767);
  assert_coordinate ("  38.9763 ,  -76.4767  ", 38.9763, -76.4767);
  assert_coordinate ("-38.5, 151.2", -38.5, 151.2);
  assert_coordinate ("0, 0", 0, 0);
}

static void
test_coordinate_decimal_bounds (void)
{
  assert_coordinate ("90, 180", 90, 180);
  assert_coordinate ("-90, -180", -90, -180);
  assert_no_coordinate ("90.1, 0");
  assert_no_coordinate ("-90.1, 0");
  assert_no_coordinate ("0, 180.1");
  assert_no_coordinate ("0, -180.1");
}

static void
test_coordinate_hemispheres (void)
{
  /* Degrees, optional minutes, optional seconds, then a hemisphere letter.
   * N/S assign latitude and E/W longitude, so the order does not matter. */
  assert_coordinate ("38\302\26058.578'N 76\302\26028.602'W",
                     38.0 + 58.578 / 60.0, -(76.0 + 28.602 / 60.0));
  assert_coordinate ("76\302\26028.602'W 38\302\26058.578'N",
                     38.0 + 58.578 / 60.0, -(76.0 + 28.602 / 60.0));
  assert_coordinate ("38 58 30 N, 76 29 W",
                     38.0 + 58.0 / 60.0 + 30.0 / 3600.0, -(76.0 + 29.0 / 60.0));
  assert_coordinate ("38\302\26058'34.8\"N 76\302\26028'36.1\"W",
                     38.0 + 58.0 / 60.0 + 34.8 / 3600.0,
                     -(76.0 + 28.0 / 60.0 + 36.1 / 3600.0));
  /* Lower case, and the prime/double-prime variants. */
  assert_coordinate ("38\302\26058\342\200\26230\342\200\263n 76\302\26029\342\200\262e",
                     38.0 + 58.0 / 60.0 + 30.0 / 3600.0, 76.0 + 29.0 / 60.0);
  /* South and west negate. */
  assert_coordinate ("33\302\26051'S 151\302\26012'E",
                     -(33.0 + 51.0 / 60.0), 151.0 + 12.0 / 60.0);
}

static void
test_coordinate_rejects (void)
{
  assert_no_coordinate (NULL);
  assert_no_coordinate ("");
  assert_no_coordinate ("   ");
  assert_no_coordinate ("hello");
  assert_no_coordinate ("38.9763");
  assert_no_coordinate ("38.9763, abc");
  assert_no_coordinate ("38.9763, 76.4x");
  assert_no_coordinate ("38\302\26058'N");   /* latitude alone */
  assert_no_coordinate ("76\302\26028'W");   /* longitude alone */
  /* The hemisphere path holds the same fences as the decimal one. */
  assert_no_coordinate ("91\302\26030'N 76\302\26028'W");
  assert_no_coordinate ("38\302\26058'N 200\302\26000'E");
}

static void
assert_scale_value (const char *text, double expected)
{
  double got = 0;
  g_assert_true (lk_scale_parse (text, &got));
  g_assert_cmpfloat (fabs (got - expected), <, 1e-6);
}

static void
assert_no_scale (const char *text)
{
  double got;
  g_assert_false (lk_scale_parse (text, &got));
}

static void
test_scale_forms (void)
{
  /* "25000", "25,000", "1:25000", "25k" and "1:2.5M" all mean the same. */
  assert_scale_value ("25000", 25000);
  assert_scale_value ("25,000", 25000);
  assert_scale_value ("1:25000", 25000);
  assert_scale_value ("1:25,000", 25000);
  assert_scale_value ("25k", 25000);
  assert_scale_value ("25K", 25000);
  assert_scale_value ("1:25k", 25000);
  assert_scale_value ("2.5k", 2500);
  assert_scale_value ("1:2.5M", 2500000);
  assert_scale_value ("2m", 2000000);
  assert_scale_value ("12 500", 12500);
  assert_scale_value (" 1:12500 ", 12500);
}

static void
test_scale_range (void)
{
  /* Below 1:100 no chart exists; above 1:100,000,000 the number is a typo. */
  assert_scale_value ("100", 100);
  assert_scale_value ("100000000", 100000000);
  assert_scale_value ("100M", 100000000);
  assert_no_scale ("99");
  assert_no_scale ("100000001");
  assert_no_scale ("101M");
}

static void
test_scale_rejects (void)
{
  assert_no_scale (NULL);
  assert_no_scale ("");
  assert_no_scale ("abc");
  assert_no_scale ("1:");
  assert_no_scale ("-25000");
  assert_no_scale ("0");
  assert_no_scale ("25kk");
  assert_no_scale ("2.5.5k");
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/parse/coordinate/decimal", test_coordinate_decimal);
  g_test_add_func ("/parse/coordinate/bounds", test_coordinate_decimal_bounds);
  g_test_add_func ("/parse/coordinate/hemispheres", test_coordinate_hemispheres);
  g_test_add_func ("/parse/coordinate/rejects", test_coordinate_rejects);
  g_test_add_func ("/parse/scale/forms", test_scale_forms);
  g_test_add_func ("/parse/scale/range", test_scale_range);
  g_test_add_func ("/parse/scale/rejects", test_scale_rejects);

  return g_test_run ();
}
