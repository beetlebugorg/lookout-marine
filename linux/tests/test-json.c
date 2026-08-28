/* test-json.c — the JSON reader behind the pick report and the plugin
 * registry. The contract is lk-json.h: a strict parse, and accessors that
 * tolerate NULL so a walk down a missing branch reads as absent.
 */

#include "lk-json.h"

static void
test_scalars (void)
{
  g_autoptr (LkJson) null_node = lk_json_parse ("null");
  g_assert_nonnull (null_node);
  g_assert_cmpint (lk_json_kind (null_node), ==, LK_JSON_NULL);

  g_autoptr (LkJson) yes = lk_json_parse ("true");
  g_assert_cmpint (lk_json_kind (yes), ==, LK_JSON_BOOL);
  g_assert_true (lk_json_bool (yes, FALSE));

  g_autoptr (LkJson) no = lk_json_parse ("false");
  g_assert_false (lk_json_bool (no, TRUE));

  g_autoptr (LkJson) number = lk_json_parse ("-3.5");
  g_assert_cmpint (lk_json_kind (number), ==, LK_JSON_NUMBER);
  g_assert_cmpfloat (lk_json_number (number, 0), ==, -3.5);

  g_autoptr (LkJson) text = lk_json_parse ("\"hi\"");
  g_assert_cmpint (lk_json_kind (text), ==, LK_JSON_STRING);
  g_assert_cmpstr (lk_json_string (text), ==, "hi");
}

static void
test_rejects (void)
{
  g_assert_null (lk_json_parse (NULL));
  g_assert_null (lk_json_parse (""));
  g_assert_null (lk_json_parse ("nope"));
  g_assert_null (lk_json_parse ("{"));
  g_assert_null (lk_json_parse ("[1,"));
  g_assert_null (lk_json_parse ("\"unterminated"));
  /* Trailing junk after a full value: a half-parsed report is worse than
   * none. */
  g_assert_null (lk_json_parse ("42 x"));
  g_assert_null (lk_json_parse ("{} {}"));
}

static void
test_objects (void)
{
  g_autoptr (LkJson) root =
      lk_json_parse ("{\"title\":\"Light\",\"count\":17,\"on\":true,"
                     "\"empty\":\"\",\"nothing\":null}");
  g_assert_nonnull (root);
  g_assert_cmpint (lk_json_kind (root), ==, LK_JSON_OBJECT);

  g_assert_cmpstr (lk_json_string (lk_json_member (root, "title")), ==, "Light");
  g_assert_null (lk_json_member (root, "missing"));
  g_assert_cmpint (lk_json_member_int (root, "count", -1), ==, 17);
  g_assert_cmpint (lk_json_member_int (root, "missing", -1), ==, -1);
  g_assert_true (lk_json_member_bool (root, "on", FALSE));

  /* A missing, null, or empty string member all read as no string. */
  g_assert_null (lk_json_member_string (root, "empty"));
  g_assert_null (lk_json_member_string (root, "nothing"));
  g_assert_null (lk_json_member_string (root, "missing"));

  /* Names come back sorted, so a raw dump reads the same on every shell. */
  g_autoptr (GPtrArray) names = lk_json_member_names (root);
  g_assert_cmpuint (names->len, ==, 5);
  g_assert_cmpstr (g_ptr_array_index (names, 0), ==, "count");
  g_assert_cmpstr (g_ptr_array_index (names, 4), ==, "title");
}

static void
test_arrays (void)
{
  g_autoptr (LkJson) root = lk_json_parse ("[1, \"two\", [3]]");
  g_assert_cmpint (lk_json_kind (root), ==, LK_JSON_ARRAY);
  g_assert_cmpuint (lk_json_length (root), ==, 3);
  g_assert_cmpfloat (lk_json_number (lk_json_at (root, 0), 0), ==, 1);
  g_assert_cmpstr (lk_json_string (lk_json_at (root, 1)), ==, "two");
  g_assert_cmpuint (lk_json_length (lk_json_at (root, 2)), ==, 1);
  g_assert_null (lk_json_at (root, 3));
}

static void
test_null_tolerance (void)
{
  /* Every accessor answers a NULL node as absent, never as a crash. */
  g_assert_cmpint (lk_json_kind (NULL), ==, LK_JSON_NULL);
  g_assert_null (lk_json_member (NULL, "key"));
  g_assert_cmpuint (lk_json_length (NULL), ==, 0);
  g_assert_null (lk_json_at (NULL, 0));
  g_assert_null (lk_json_string (NULL));
  g_assert_cmpfloat (lk_json_number (NULL, 5.0), ==, 5.0);
  g_assert_true (lk_json_bool (NULL, TRUE));
  g_assert_null (lk_json_member_string (NULL, "key"));
}

static void
test_text_keeps_digits (void)
{
  /* A number keeps the cell's own digits: "17" never comes back "17.0". */
  g_autoptr (LkJson) root = lk_json_parse ("{\"a\":17,\"b\":17.0,\"c\":true}");
  g_assert_cmpstr (lk_json_text (lk_json_member (root, "a")), ==, "17");
  g_assert_cmpstr (lk_json_text (lk_json_member (root, "b")), ==, "17.0");
  g_assert_cmpstr (lk_json_text (lk_json_member (root, "c")), ==, "true");
  g_assert_cmpstr (lk_json_text (root), ==, "");
}

static void
test_escapes (void)
{
  g_autoptr (LkJson) root =
      lk_json_parse ("\"a\\n\\t\\\"b\\\\c\\u0041\\u00e9\"");
  g_assert_nonnull (root);
  g_assert_cmpstr (lk_json_string (root), ==, "a\n\t\"b\\cA\303\251");
}

static void
test_nested_pick_payload (void)
{
  /* The shape the engine actually sends: the decoded page beside the raw. */
  g_autoptr (LkJson) root = lk_json_parse (
      "{\"report\":{\"title\":\"Buoy\",\"rows\":[[\"Colour\",\"red\"]]},"
      "\"s57\":{\"OBJL\":\"BOYLAT\"}}");
  const LkJson *report = lk_json_member (root, "report");
  g_assert_cmpstr (lk_json_member_string (report, "title"), ==, "Buoy");
  const LkJson *row = lk_json_at (lk_json_member (report, "rows"), 0);
  g_assert_cmpstr (lk_json_string (lk_json_at (row, 0)), ==, "Colour");
  g_assert_cmpstr (lk_json_string (lk_json_at (row, 1)), ==, "red");
  g_assert_cmpstr (lk_json_member_string (lk_json_member (root, "s57"), "OBJL"),
                   ==, "BOYLAT");
}

int
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/json/scalars", test_scalars);
  g_test_add_func ("/json/rejects", test_rejects);
  g_test_add_func ("/json/objects", test_objects);
  g_test_add_func ("/json/arrays", test_arrays);
  g_test_add_func ("/json/null-tolerance", test_null_tolerance);
  g_test_add_func ("/json/text-keeps-digits", test_text_keeps_digits);
  g_test_add_func ("/json/escapes", test_escapes);
  g_test_add_func ("/json/pick-payload", test_nested_pick_payload);

  return g_test_run ();
}
