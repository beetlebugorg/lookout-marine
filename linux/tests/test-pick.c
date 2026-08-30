/* test-pick.c — the pick report's decode and its callout geometry.
 *
 * The engine composes the report; the shell parses {"report":…,"s57":…} and
 * lays it out. The decode and the placement are pure, and the placement is
 * the twin of OverlayLayer.calloutLayout on the other shells, so the numbers
 * here are the numbers those shells place with.
 */

#include "ui/chart/pick-report.h"

static LkPickFeature
feature (const char *cls, const char *chart, const char *s57)
{
  return (LkPickFeature) { .cls = (char *) cls, .chart = (char *) chart,
                           .s57 = (char *) s57 };
}

static void
test_decode_full_envelope (void)
{
  LkPickFeature f = feature ("LIGHTS", "US5MD1MC",
      "{\"report\":{\"title\":\"Fl(2) 10s 5m\",\"subtitle\":\"Light\","
      "\"chip\":\"Light\",\"footnote\":\"US5MD1MC ed 27\","
      "\"notes\":[\"Keep clear\",\"\"],"
      "\"rows\":[{\"label\":\"Colour\",\"value\":\"red\"},"
      "{\"label\":\"Caution\",\"value\":\"note.txt\",\"file\":true}]},"
      "\"s57\":{\"OBJL\":\"LIGHTS\",\"b\":{\"a\":1}}}");

  g_autoptr (LkPickDecoded) decoded = lk_pick_decoded_new (&f);
  g_assert_cmpstr (decoded->title, ==, "Fl(2) 10s 5m");
  g_assert_cmpstr (decoded->subtitle, ==, "Light");
  g_assert_cmpstr (decoded->chip, ==, "Light");
  g_assert_cmpstr (decoded->footnote, ==, "US5MD1MC ed 27");
  g_assert_cmpint (decoded->body, ==, LK_PICK_BODY_FULL);

  /* The empty note is dropped, not shown as a blank box. */
  g_assert_cmpuint (decoded->notes->len, ==, 1);
  g_assert_cmpstr (g_ptr_array_index (decoded->notes, 0), ==, "Keep clear");

  g_assert_cmpuint (decoded->rows->len, ==, 2);
  LkReportRow *row = g_ptr_array_index (decoded->rows, 1);
  g_assert_cmpstr (row->label, ==, "Caution");
  g_assert_true (row->file);
  g_assert_false (row->picture);

  /* The raw half, flattened depth-first with sorted keys: OBJL, then the
   * container b as a heading, then its member one deeper. */
  g_assert_cmpuint (decoded->raw_rows->len, ==, 3);
  LkRawRow *raw = g_ptr_array_index (decoded->raw_rows, 0);
  g_assert_cmpstr (raw->name, ==, "OBJL");
  g_assert_cmpstr (raw->value, ==, "LIGHTS");
  g_assert_cmpint (raw->depth, ==, 0);
  raw = g_ptr_array_index (decoded->raw_rows, 1);
  g_assert_cmpstr (raw->name, ==, "b");
  g_assert_cmpstr (raw->value, ==, "");
  raw = g_ptr_array_index (decoded->raw_rows, 2);
  g_assert_cmpstr (raw->name, ==, "a");
  g_assert_cmpstr (raw->value, ==, "1");
  g_assert_cmpint (raw->depth, ==, 1);
}

static void
test_decode_fallbacks (void)
{
  /* A report with nothing in it falls back to the S-57 class and the cell. */
  LkPickFeature f = feature ("WRECKS", "US5MD1MC", "{\"report\":{}}");

  g_autoptr (LkPickDecoded) decoded = lk_pick_decoded_new (&f);
  g_assert_cmpstr (decoded->title, ==, "WRECKS");
  g_assert_cmpstr (decoded->chip, ==, "WRECKS");
  g_assert_cmpstr (decoded->footnote, ==, "US5MD1MC");
  g_assert_null (decoded->subtitle);
  g_assert_cmpuint (decoded->rows->len, ==, 0);
}

static void
test_decode_no_envelope (void)
{
  /* The core's fallback when a compose fails: the whole payload is the raw
   * half, and the fold still shows everything. */
  LkPickFeature f = feature ("WRECKS", "US5MD1MC", "{\"OBJL\":\"WRECKS\"}");

  g_autoptr (LkPickDecoded) decoded = lk_pick_decoded_new (&f);
  g_assert_cmpstr (decoded->title, ==, "WRECKS");
  g_assert_cmpuint (decoded->raw_rows->len, ==, 1);
  LkRawRow *raw = g_ptr_array_index (decoded->raw_rows, 0);
  g_assert_cmpstr (raw->name, ==, "OBJL");
}

static void
test_decode_empty_markers (void)
{
  LkPickFeature none = feature ("SBDARE", "C",
      "{\"report\":{\"empty\":\"none\"},\"s57\":{}}");
  g_autoptr (LkPickDecoded) a = lk_pick_decoded_new (&none);
  g_assert_cmpint (a->body, ==, LK_PICK_BODY_NO_ATTRIBUTES);

  LkPickFeature source = feature ("SBDARE", "C",
      "{\"report\":{\"empty\":\"source\"},\"s57\":{}}");
  g_autoptr (LkPickDecoded) b = lk_pick_decoded_new (&source);
  g_assert_cmpint (b->body, ==, LK_PICK_BODY_SOURCE_ONLY);
}

static void
test_plain_text (void)
{
  /* What Copy puts on the clipboard: the cell's own words, out of the
   * envelope, containers as headings and two spaces of indent per depth. */
  LkPickFeature f = feature ("LIGHTS", "US5MD1MC",
      "{\"report\":{\"title\":\"x\"},"
      "\"s57\":{\"CATLIT\":\"4\",\"nested\":{\"x\":\"y\"}}}");

  g_autofree char *text = lk_pick_plain_text (&f);
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

  g_test_add_func ("/pick/decode/full-envelope", test_decode_full_envelope);
  g_test_add_func ("/pick/decode/fallbacks", test_decode_fallbacks);
  g_test_add_func ("/pick/decode/no-envelope", test_decode_no_envelope);
  g_test_add_func ("/pick/decode/empty-markers", test_decode_empty_markers);
  g_test_add_func ("/pick/plain-text", test_plain_text);
  g_test_add_func ("/pick/report-width", test_report_width);
  g_test_add_func ("/pick/callout/above", test_callout_above);
  g_test_add_func ("/pick/callout/below-near-top", test_callout_below_near_top);
  g_test_add_func ("/pick/callout/larger-side", test_callout_prefers_larger_side);
  g_test_add_func ("/pick/callout/margins", test_callout_clamps_to_margins);

  return g_test_run ();
}
