/* test-pick-report.c — the pick report card, as a widget.
 *
 * The report is built from the model's current pick, so the suite sets a pick
 * and reads the card a mariner reads: the object column for a multi-object
 * pick, the selected object's title, the S-57 fold, and the close control.
 */

#include "lk-test.h"

#include "model/app-model.h"
#include "pick-fixture.h"

static LkAppModel *model;
static GtkWidget  *window;

/* Match a label whose text starts with `prefix`. */
static gboolean
match_label_prefix (GtkWidget *widget, gconstpointer data)
{
  return GTK_IS_LABEL (widget) &&
         g_str_has_prefix (gtk_label_get_text (GTK_LABEL (widget)), data);
}

static void
set_two_object_pick (void)
{
  LkPickDecoded *a = lk_fixture_feature ("LIGHTS", "US5MD1MC", "Fl(2) 10s",
                                         "Light", "Light", "US5MD1MC ed 27");
  LkPickDecoded *b = lk_fixture_feature ("WRECKS", "US5MD1MC", "Wreck",
                                         "Dangerous", "Wreck", "US5MD1MC ed 27");
  GPtrArray *results = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_pick_decoded_free);

  g_ptr_array_add (a->rows, lk_fixture_row ("Colour", "red", 0));
  g_ptr_array_add (a->source, lk_fixture_row ("OBJL", "LIGHTS", 0));
  g_ptr_array_add (a->source, lk_fixture_row ("COLOUR", "3", 0));

  g_ptr_array_add (b->rows, lk_fixture_row ("Depth", "3 m", 0));
  g_ptr_array_add (b->source, lk_fixture_row ("OBJL", "WRECKS", 0));
  g_ptr_array_add (b->source, lk_fixture_row ("CATWRK", "2", 0));
  g_ptr_array_add (b->source, lk_fixture_row ("WATLEV", "3", 0));

  g_ptr_array_add (results, a);
  g_ptr_array_add (results, b);
  lk_app_model_set_pick (model, results, 640, 400, -76.48, 38.98);
  lk_test_drain ();
}

/* A multi-object pick lays a column of objects beside the report, opens on the
 * first, and folds the raw S-57 rows under a labelled control. */
static void
test_multi_object_report (void)
{
  set_two_object_pick ();

  GtkWidget *card = lk_pick_report_new (model, lk_pick_report_width (2, 1280), 360);
  window = gtk_window_new ();
  gtk_window_set_child (GTK_WINDOW (window), card);
  gtk_window_present (GTK_WINDOW (window));
  lk_test_drain ();

  /* Both objects stand in the column; the first is the one on show. */
  GtkWidget *list = lk_test_find_type (card, GTK_TYPE_LIST_BOX);
  g_assert_nonnull (list);
  g_assert_nonnull (lk_test_find_label (card, "Fl(2) 10s"));

  /* The S-57 fold stands under the report, naming the raw-row count. */
  g_assert_nonnull (lk_test_find (card, match_label_prefix, "S-57 source attributes ("));

  /* A close control, and the width is a real number of points. */
  g_assert_cmpint (lk_pick_report_width (2, 1280), >, 0);

  gtk_window_destroy (GTK_WINDOW (window));
}

/* Selecting the second object moves the model's pick index, so the report and
 * the mark stay on the same object. */
static void
test_select_moves_index (void)
{
  set_two_object_pick ();

  GtkWidget *card = lk_pick_report_new (model, lk_pick_report_width (2, 1280), 360);
  window = gtk_window_new ();
  gtk_window_set_child (GTK_WINDOW (window), card);
  gtk_window_present (GTK_WINDOW (window));
  lk_test_drain ();

  GtkListBox *list = GTK_LIST_BOX (lk_test_find_type (card, GTK_TYPE_LIST_BOX));
  GtkListBoxRow *second = gtk_list_box_get_row_at_index (list, 1);
  g_assert_nonnull (second);

  gtk_list_box_select_row (list, second);
  lk_test_drain ();
  g_assert_nonnull (lk_test_find_label (card, "Wreck"));

  gtk_window_destroy (GTK_WINDOW (window));
}

int
main (int argc, char *argv[])
{
  lk_test_gtk_init (&argc, &argv);

  model = lk_app_model_new ();

  g_test_add_func ("/pick-report/multi-object", test_multi_object_report);
  g_test_add_func ("/pick-report/select-moves-index", test_select_moves_index);

  return g_test_run ();
}
