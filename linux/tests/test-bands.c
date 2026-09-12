/* test-bands.c — the usage-band ramp.
 *
 * A set that stops at Coastal does not draw the harbour a passage ends in, so
 * the bar says which scales a set holds and how much of it is at each. The
 * arithmetic is what this checks: the widths have to fill the bar exactly, and
 * a band the legend counts has to be ON the bar however small its share is.
 *
 * No display.
 */

#include "library/bake.h"
#include "library/sets.h"
#include "ui/charts/band-ramp.h"

#include <math.h>

#define LK_TEST_HAIR 1.0
#define LK_TEST_LEAST 4.0

/* The fill a bar of `width` has once the hairlines between the segments are
 * taken out. */
static double
room_for (const guint bands[7], double width)
{
  return width - LK_TEST_HAIR * (lk_band_ramp_count (bands) - 1);
}

static double
total_width (const guint bands[7], double room)
{
  double sum = 0;

  for (int band = 1; band <= 6; band++)
    sum += lk_band_ramp_width (bands, band, room);
  return sum;
}

/* An even set: six bands of equal size take equal segments, and they fill. */
static void
test_even_split (void)
{
  const guint bands[7] = { 0, 10, 10, 10, 10, 10, 10 };
  double room = room_for (bands, 300);

  g_assert_cmpuint (lk_band_ramp_count (bands), ==, 6);
  for (int band = 1; band <= 6; band++)
    g_assert_cmpfloat (fabs (lk_band_ramp_width (bands, band, room) - room / 6), <, 0.001);
  g_assert_cmpfloat (fabs (total_width (bands, room) - room), <, 0.001);
}

/* A real library: 7,000 cells with two dozen overviews. The overview band is
 * a fifth of a percent of the set, and it still has to be visible beside its
 * own number in the legend. */
static void
test_floor_for_a_tiny_band (void)
{
  const guint bands[7] = { 0, 24, 60, 400, 1200, 4000, 1400 };
  double room = room_for (bands, 300);
  double overview = lk_band_ramp_width (bands, 1, room);

  g_assert_cmpfloat (overview, >=, LK_TEST_LEAST);
  /* Every band on the bar clears the floor. */
  for (int band = 1; band <= 6; band++)
    g_assert_cmpfloat (lk_band_ramp_width (bands, band, room), >=, LK_TEST_LEAST);

  /* The floor is paid for by the wide bands, not by the bar: the widths still
   * add up to the room. */
  g_assert_cmpfloat (fabs (total_width (bands, room) - room), <, 0.001);

  /* The widest band is still the widest. Raising a sliver must not reorder
   * what the bar says about the set. */
  double widest = lk_band_ramp_width (bands, 5, room);
  for (int band = 1; band <= 6; band++)
    if (band != 5)
      g_assert_cmpfloat (lk_band_ramp_width (bands, band, room), <=, widest);
}

/* One band is the whole bar. */
static void
test_single_band (void)
{
  const guint bands[7] = { 0, 0, 0, 0, 0, 512, 0 };
  double room = room_for (bands, 300);

  g_assert_cmpuint (lk_band_ramp_count (bands), ==, 1);
  g_assert_cmpfloat (fabs (room - 300), <, 0.001); /* no hairlines with one segment */
  g_assert_cmpfloat (fabs (lk_band_ramp_width (bands, 5, room) - 300), <, 0.001);
  g_assert_cmpfloat (lk_band_ramp_width (bands, 4, room), ==, 0);
}

/* Nothing to draw, and nothing that could divide by zero. */
static void
test_empty_and_edges (void)
{
  const guint none[7] = { 0, 0, 0, 0, 0, 0, 0 };
  const guint some[7] = { 0, 1, 0, 0, 0, 1, 0 };
  /* Cells whose name states no band. They are counted nowhere on a scale
   * ramp: an S-101 dataset states no usage band at all. */
  const guint unbanded[7] = { 40, 0, 0, 0, 0, 0, 0 };

  g_assert_cmpuint (lk_band_ramp_count (none), ==, 0);
  g_assert_cmpfloat (lk_band_ramp_width (none, 3, 300), ==, 0);

  g_assert_cmpuint (lk_band_ramp_count (unbanded), ==, 0);
  g_assert_cmpfloat (lk_band_ramp_width (unbanded, 1, 300), ==, 0);

  /* A band with no cells takes no width, and a band outside 1 to 6 is not a
   * band. */
  g_assert_cmpfloat (lk_band_ramp_width (some, 3, 300), ==, 0);
  g_assert_cmpfloat (lk_band_ramp_width (some, 0, 300), ==, 0);
  g_assert_cmpfloat (lk_band_ramp_width (some, 7, 300), ==, 0);

  /* A bar with no room in it asks for no width. */
  g_assert_cmpfloat (lk_band_ramp_width (some, 1, 0), ==, 0);
  g_assert_cmpfloat (lk_band_ramp_width (some, 1, -10), ==, 0);
}

/* A bar too narrow to give every band its floor. The widths still must not
 * run past the room: a segment drawn outside the bar is drawn over the row
 * beside it. */
static void
test_narrow_bar (void)
{
  const guint bands[7] = { 0, 1, 1, 1, 1, 1, 1 };
  double room = room_for (bands, 18); /* three points a band */

  for (int band = 1; band <= 6; band++)
    g_assert_cmpfloat (lk_band_ramp_width (bands, band, room), >, 0);
  /* Every band is under the floor, so each is raised to it and the total
   * overruns. The bar clips, which is why this is worth stating: the caller
   * cannot rely on the sum at this width. */
  g_assert_cmpfloat (total_width (bands, room), >=, room);
}

/* The ramp, deep to shallow, read as fine to coarse. Band 6 is the deepest
 * colour and band 1 the palest, so the bar runs from detail to overview. */
static void
test_ramp_colours (void)
{
  double last = -1;

  for (int band = 6; band >= 1; band--)
    {
      double r = 0, g = 0, b = 0;

      lk_band_ramp_color (band, &r, &g, &b);
      g_assert_cmpfloat (r, >=, 0);
      g_assert_cmpfloat (r, <=, 1);
      /* Each step is paler than the one before it. */
      g_assert_cmpfloat (r, >, last);
      last = r;
    }

  /* Outside the range the palest end stands in, rather than reading off the
   * end of the table. */
  double r = 0;
  lk_band_ramp_color (0, &r, NULL, NULL);
  g_assert_cmpfloat (r, ==, last);
  lk_band_ramp_color (9, &r, NULL, NULL);
  g_assert_cmpfloat (r, ==, last);
}

/* The names the readouts use, which the legend and the capsule share. */
static void
test_band_names (void)
{
  g_assert_cmpstr (lk_chart_band_name (1), ==, "Overview");
  g_assert_cmpstr (lk_chart_band_name (3), ==, "Coastal");
  g_assert_cmpstr (lk_chart_band_name (5), ==, "Harbor");
  g_assert_cmpstr (lk_chart_band_name (6), ==, "Berthing");
  g_assert_cmpstr (lk_chart_band_name (0), ==, "Unknown");
  g_assert_cmpstr (lk_chart_band_name (7), ==, "Unknown");
}

/* A bake's done count, split across the bands it works.
 *
 * lookout_bake_order runs the coarse band first, so one counter from the core
 * is enough to say which band is being worked and how much of it is left. That
 * is what tells a mariner who stops part way that their passage is covered.
 */
static void
test_bake_bands_advance (void)
{
  /* Coarse first, as the bake orders them: overview, coastal, harbour. */
  LkBakeBand bands[3] = {
    { .band = 1, .total = 2 },
    { .band = 3, .total = 5 },
    { .band = 5, .total = 10 },
  };

  /* Nothing done yet. */
  lk_bake_bands_advance (bands, 3, 0);
  g_assert_cmpuint (bands[0].done, ==, 0);
  g_assert_cmpuint (bands[1].done, ==, 0);
  g_assert_cmpuint (bands[2].done, ==, 0);

  /* Part way through the first band. */
  lk_bake_bands_advance (bands, 3, 1);
  g_assert_cmpuint (bands[0].done, ==, 1);
  g_assert_cmpuint (bands[1].done, ==, 0);

  /* The first band finished, and the second started. */
  lk_bake_bands_advance (bands, 3, 4);
  g_assert_cmpuint (bands[0].done, ==, 2);
  g_assert_cmpuint (bands[1].done, ==, 2);
  g_assert_cmpuint (bands[2].done, ==, 0);

  /* Everything. */
  lk_bake_bands_advance (bands, 3, 17);
  g_assert_cmpuint (bands[0].done, ==, 2);
  g_assert_cmpuint (bands[1].done, ==, 5);
  g_assert_cmpuint (bands[2].done, ==, 10);

  /* A count past the total cannot overfill a band: a cancelled bake reports
   * what it did, and a refused chart still counts as done. */
  lk_bake_bands_advance (bands, 3, 99);
  g_assert_cmpuint (bands[0].done, ==, 2);
  g_assert_cmpuint (bands[1].done, ==, 5);
  g_assert_cmpuint (bands[2].done, ==, 10);

  /* No bands is no work. */
  lk_bake_bands_advance (bands, 0, 5);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/bands/even-split", test_even_split);
  g_test_add_func ("/bands/floor-for-a-tiny-band", test_floor_for_a_tiny_band);
  g_test_add_func ("/bands/single-band", test_single_band);
  g_test_add_func ("/bands/empty-and-edges", test_empty_and_edges);
  g_test_add_func ("/bands/narrow-bar", test_narrow_bar);
  g_test_add_func ("/bands/ramp-colours", test_ramp_colours);
  g_test_add_func ("/bands/band-names", test_band_names);
  g_test_add_func ("/bands/bake-bands-advance", test_bake_bands_advance);

  return g_test_run ();
}
