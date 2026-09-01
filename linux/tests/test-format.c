/* test-format.c — the shell's own readout geometry, and the link to the core's
 * format kit.
 *
 * The strings and the parsers are the core's, and `zig build test` holds their
 * expectations. What is checked here is that this binary reaches them and that
 * the buffer sizes the shell passes are long enough: a short buffer writes an
 * empty string, which is a blank readout and not a build error.
 */

#include "ui/hud/hud.h"
#include "ui/hud/scale-bar.h"
#include "ui/chart/view.h"

#include <lookout.h>

/* The kit, through the buffers the shell declares for it. One value per
 * writer and one per parser: what each answers is the core's business. */
static void
test_format_kit (void)
{
  char coord[LOOKOUT_COORD_MAX];
  char position[LOOKOUT_POSITION_MAX];
  char scale[LOOKOUT_SCALE_MAX];
  double lat = 0, lon = 0, denominator = 0;

  g_assert_cmpuint (lookout_fmt_coord_dm (38.9763, TRUE, coord, sizeof coord), >, 0);
  g_assert_cmpstr (coord, ==, "38\302\26058.578'N");

  g_assert_cmpuint (lookout_fmt_position (38.9763, -76.4767, position, sizeof position), >, 0);
  g_assert_cmpstr (position, ==, "38\302\26058.578'N 076\302\26028.602'W");

  g_assert_cmpuint (lookout_fmt_scale (13267, scale, sizeof scale), >, 0);
  g_assert_cmpstr (scale, ==, "1:13,267");

  g_assert_cmpstr (lookout_band_name (13267), ==, "Harbor");

  g_assert_true (lookout_parse_position ("38 58 30 N, 76 29 W", &lat, &lon));
  g_assert_cmpfloat (fabs (lat - (38.0 + 58.0 / 60.0 + 30.0 / 3600.0)), <, 1e-9);
  g_assert_cmpfloat (fabs (lon + (76.0 + 29.0 / 60.0)), <, 1e-9);

  g_assert_true (lookout_parse_scale ("1:2.5M", &denominator));
  g_assert_cmpfloat (fabs (denominator - 2500000.0), <, 1e-9);

  g_assert_cmpfloat (fabs (lookout_zoom_delta_for_scale (50000, 25000) - 1.0), <, 1e-9);
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
  g_test_add_func ("/format/kit", test_format_kit);

  return g_test_run ();
}
