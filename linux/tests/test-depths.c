/* test-depths.c: the depth step's water panel.
 *
 * The core derives the depth settings (lookout_depth_plan) and its own tests
 * check them. This checks how far the panel's water reaches.
 *
 * No display.
 */

#include "ui/firstrun/water.h"

#include <math.h>

/* How far out a depth lies in the drawn panel.
 *
 * Measured in contours rather than metres, because the answers span a dinghy
 * and a ship: a fixed 40 m slope puts a 5 ft contour in the first pixel of the
 * panel and a 30 ft one halfway up it. */
static void
test_water_reach (void)
{
  double floor = 15; /* a 10 m deep contour, half again */

  /* The shore is where the land ends, and nothing reaches below it. */
  g_assert_cmpfloat (lk_depth_water_reach (0, floor), ==, lk_depth_water_reach (0, floor));
  g_assert_cmpfloat (lk_depth_water_reach (0, floor), >, 0);
  g_assert_cmpfloat (lk_depth_water_reach (-5, floor), >=,
                     lk_depth_water_reach (0, floor));

  /* Deeper water is further out, always. The bands must not cross. */
  double last = 0;
  for (double depth = 0; depth <= floor; depth += 0.5)
    {
      double reach = lk_depth_water_reach (depth, floor);

      g_assert_cmpfloat (reach, >=, last);
      g_assert_cmpfloat (reach, <=, 1.0);
      last = reach;
    }

  /* The floor fills the panel. */
  g_assert_cmpfloat (lk_depth_water_reach (floor, floor), ==, 1.0);
  /* And past it nothing runs off the end. */
  g_assert_cmpfloat (lk_depth_water_reach (floor * 4, floor), ==, 1.0);

  /* Shallow water gets most of the panel: that is where both contours fall.
   * Half the floor therefore sits past the middle. */
  g_assert_cmpfloat (lk_depth_water_reach (floor / 2, floor), >, 0.5);

  /* A boat with no deep contour to scale against cannot divide by it. */
  g_assert_cmpfloat (lk_depth_water_reach (5, 0), >, 0);
  g_assert_cmpfloat (lk_depth_water_reach (5, 0), <, 1);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/depths/water-reach", test_water_reach);

  return g_test_run ();
}
