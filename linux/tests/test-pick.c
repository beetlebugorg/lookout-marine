/* test-pick.c — the pick report's clipboard text and its callout geometry.
 *
 * The engine composes the report and the core folds the payload; what is left
 * here is the shell's own: what Copy puts on the clipboard, and where the card
 * stands. The placement is the twin of OverlayLayer.calloutLayout on the other
 * shells, so the numbers here are the numbers those shells place with.
 */

#include "pick-fixture.h"

static void
test_plain_text (void)
{
  /* What Copy puts on the clipboard: the cell's own words, containers as
   * headings and two spaces of indent per depth. */
  g_autoptr (LkPickDecoded) f =
      lk_fixture_feature ("LIGHTS", "US5MD1MC", "x", "", "Light", "");

  g_ptr_array_add (f->source, lk_fixture_row ("CATLIT", "4", 0));
  g_ptr_array_add (f->source, lk_fixture_row ("nested", "", 0));
  g_ptr_array_add (f->source, lk_fixture_row ("x", "y", 1));

  g_autofree char *text = lk_pick_plain_text (f);
  g_assert_cmpstr (text, ==,
      "LIGHTS  US5MD1MC\n"
      "CATLIT: 4\n"
      "nested:\n"
      "  x: y\n");
}

static void
test_report_width (void)
{
  /* One object is the detail column; several add the object list beside it.
   * A narrow view caps it, but never under 280. */
  g_assert_cmpint (lk_pick_report_width (1, 1280), ==, 430);
  g_assert_cmpint (lk_pick_report_width (3, 1280), ==, 630);
  g_assert_cmpint (lk_pick_report_width (1, 300), ==, 280);
}

static void
test_callout_above (void)
{
  /* Room above: the card stands over the mark, centred, 23 points clear. */
  LkCalloutPlace place = lk_callout_place (640, 400, 430, 1280, 800, 76);
  g_assert_cmpint (place.edge, ==, LK_CALLOUT_ABOVE);
  g_assert_cmpfloat (place.x, ==, 425);
  g_assert_cmpfloat (place.y, ==, 377);
  g_assert_cmpfloat (place.room, ==, 365);
}

static void
test_callout_below_near_top (void)
{
  /* Too little room above and more below: the card drops under the mark. */
  LkCalloutPlace place = lk_callout_place (640, 100, 430, 1280, 800, 76);
  g_assert_cmpint (place.edge, ==, LK_CALLOUT_BELOW);
  g_assert_cmpfloat (place.y, ==, 123);
  g_assert_cmpfloat (place.room, ==, 601);
}

static void
test_callout_prefers_larger_side (void)
{
  /* Little room anywhere: above wins when it is at least as large. */
  LkCalloutPlace place = lk_callout_place (640, 150, 430, 1280, 260, 76);
  g_assert_cmpint (place.edge, ==, LK_CALLOUT_ABOVE);
  g_assert_cmpfloat (place.room, ==, 115);
}

static void
test_callout_clamps_to_margins (void)
{
  /* The card never leaves the 12-point margin, whatever the mark does. */
  LkCalloutPlace left = lk_callout_place (50, 400, 430, 1280, 800, 76);
  g_assert_cmpfloat (left.x, ==, 12);

  LkCalloutPlace right = lk_callout_place (1250, 400, 430, 1280, 800, 76);
  g_assert_cmpfloat (right.x, ==, 838);
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/pick/plain-text", test_plain_text);
  g_test_add_func ("/pick/report-width", test_report_width);
  g_test_add_func ("/pick/callout/above", test_callout_above);
  g_test_add_func ("/pick/callout/below-near-top", test_callout_below_near_top);
  g_test_add_func ("/pick/callout/larger-side", test_callout_prefers_larger_side);
  g_test_add_func ("/pick/callout/margins", test_callout_clamps_to_margins);

  return g_test_run ();
}
