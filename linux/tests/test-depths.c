/* test-depths.c — the depth step's arithmetic.
 *
 * The step asks a mariner two things about their boat and derives the three
 * numbers the engine shades water with. Getting that wrong shades water the
 * boat can cross, or leaves water it cannot look safe, so the ladder is
 * checked in both units.
 *
 * No display.
 */

#include "ui/firstrun/depths.h"

#include <math.h>

/* Draft plus clearance, rounded UP to a whole foot or metre. A chart names its
 * depths in whole numbers, and the fraction belongs to the keel rather than to
 * the water. */
static void
test_safety_depth_rounds_up (void)
{
  g_assert_cmpfloat (lk_depth_safety (1.7, 0.6), ==, 3);
  g_assert_cmpfloat (lk_depth_safety (5.5, 2.0), ==, 8);
  /* Already whole: nothing is added. */
  g_assert_cmpfloat (lk_depth_safety (4.0, 1.0), ==, 5);
  /* A hair over still rounds up: the keel does not care about the fraction. */
  g_assert_cmpfloat (lk_depth_safety (5.01, 0.0), ==, 6);
}

/* The safety contour is the first contour an S-57 survey DRAWS at or past the
 * safety depth. The chart shades on a contour it has, so a boat measured at 7
 * feet is shaded against the 12 foot contour. */
static void
test_safety_contour_climbs_the_ladder (void)
{
  /* Feet: 6, 12, 18, 30, 60, 90, 120, 180, 240, 300. */
  g_assert_cmpfloat (lk_depth_contour (5, TRUE), ==, 6);
  g_assert_cmpfloat (lk_depth_contour (6, TRUE), ==, 6);
  g_assert_cmpfloat (lk_depth_contour (7, TRUE), ==, 12);
  g_assert_cmpfloat (lk_depth_contour (8, TRUE), ==, 12);
  g_assert_cmpfloat (lk_depth_contour (19, TRUE), ==, 30);

  /* Metres: 2, 5, 10, 20, 30, 50, 75, 100. */
  g_assert_cmpfloat (lk_depth_contour (2, FALSE), ==, 2);
  g_assert_cmpfloat (lk_depth_contour (3, FALSE), ==, 5);
  g_assert_cmpfloat (lk_depth_contour (10, FALSE), ==, 10);
  g_assert_cmpfloat (lk_depth_contour (11, FALSE), ==, 20);

  /* A ship deeper than the deepest contour is shaded against that one. There
   * is nothing deeper to shade against. */
  g_assert_cmpfloat (lk_depth_contour (400, TRUE), ==, 300);
  g_assert_cmpfloat (lk_depth_contour (500, FALSE), ==, 100);
}

/* The deep contour is twice the safety contour, up the same ladder, so it
 * displays round. */
static void
test_deep_contour (void)
{
  g_assert_cmpfloat (lk_depth_deep_contour (6, TRUE), ==, 12);
  g_assert_cmpfloat (lk_depth_deep_contour (12, TRUE), ==, 30);
  g_assert_cmpfloat (lk_depth_deep_contour (10, FALSE), ==, 20);
  g_assert_cmpfloat (lk_depth_deep_contour (20, FALSE), ==, 50);

  /* Always deeper than the safety contour, whatever the boat. That is what
   * makes the four shades four. */
  guint n = 0;
  const double *ladder = lk_depth_ladder (FALSE, &n);
  for (guint i = 0; i + 1 < n; i++)
    g_assert_cmpfloat (lk_depth_deep_contour (ladder[i], FALSE), >, ladder[i]);
}

/* The boat is held in the unit on screen, so every number displays round: a
 * metric list converted into feet gave a 4.9 ft clearance and a 16.4 ft
 * contour. A change of unit snaps the clearance to one the new unit offers. */
static void
test_clearances_are_round (void)
{
  guint n = 0;
  const double *feet = lk_depth_clearances (TRUE, &n);

  g_assert_cmpuint (n, ==, 4);
  for (guint i = 0; i < n; i++)
    g_assert_cmpfloat (feet[i], ==, round (feet[i])); /* whole feet */

  const double *metres = lk_depth_clearances (FALSE, &n);
  g_assert_cmpuint (n, ==, 4);
  for (guint i = 0; i < n; i++)
    g_assert_cmpfloat (metres[i] * 10, ==, round (metres[i] * 10)); /* a tenth */

  /* 0.6 m is about 2 ft, and 2 ft is one of the choices. */
  g_assert_cmpfloat (lk_depth_nearest_clearance (0.6 * 3.28084, TRUE), ==, 2);
  /* 3 ft is about 0.9 m, and the nearest metric choice is 1. */
  g_assert_cmpfloat (lk_depth_nearest_clearance (3 / 3.28084, FALSE), ==, 1);
  /* Beyond either end it takes the end. */
  g_assert_cmpfloat (lk_depth_nearest_clearance (99, TRUE), ==, 5);
  g_assert_cmpfloat (lk_depth_nearest_clearance (0, FALSE), ==, 0.3);
}

/* The ladders climb, so "the first at or past" is a meaningful question. */
static void
test_ladders_ascend (void)
{
  for (int feet = 0; feet < 2; feet++)
    {
      guint n = 0;
      const double *ladder = lk_depth_ladder (feet == 1, &n);

      g_assert_cmpuint (n, >, 4);
      for (guint i = 0; i + 1 < n; i++)
        g_assert_cmpfloat (ladder[i], <, ladder[i + 1]);
      g_assert_cmpfloat (ladder[0], >, 0);
    }
}

/* The whole chain, for a small keelboat and for a ship, in the unit each is
 * measured in. The four shades have to come out in order. */
static void
test_the_whole_chain (void)
{
  /* A keelboat drawing 1.7 m, wanting 0.6 m under the keel. */
  double safety = lk_depth_safety (1.7, 0.6);
  double contour = lk_depth_contour (safety, FALSE);
  double deep = lk_depth_deep_contour (contour, FALSE);

  g_assert_cmpfloat (safety, ==, 3);
  g_assert_cmpfloat (contour, ==, 5);
  g_assert_cmpfloat (deep, ==, 10);
  g_assert_cmpfloat (safety, <=, contour);
  g_assert_cmpfloat (contour, <, deep);

  /* A ship drawing 38 ft, wanting 5 ft. */
  safety = lk_depth_safety (38, 5);
  contour = lk_depth_contour (safety, TRUE);
  deep = lk_depth_deep_contour (contour, TRUE);

  g_assert_cmpfloat (safety, ==, 43);
  g_assert_cmpfloat (contour, ==, 60);
  g_assert_cmpfloat (deep, ==, 120);
  g_assert_cmpfloat (safety, <=, contour);
  g_assert_cmpfloat (contour, <, deep);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/depths/safety-depth-rounds-up", test_safety_depth_rounds_up);
  g_test_add_func ("/depths/safety-contour-climbs", test_safety_contour_climbs_the_ladder);
  g_test_add_func ("/depths/deep-contour", test_deep_contour);
  g_test_add_func ("/depths/clearances-are-round", test_clearances_are_round);
  g_test_add_func ("/depths/ladders-ascend", test_ladders_ascend);
  g_test_add_func ("/depths/the-whole-chain", test_the_whole_chain);

  return g_test_run ();
}
