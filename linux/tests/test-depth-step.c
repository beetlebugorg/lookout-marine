/* test-depth-step.c — the depth step's controls.
 *
 * The step asks for a draft in the unit on screen. A change of unit has to
 * convert the boat the step already holds, and every number has to stay round
 * in the new unit.
 *
 * The step is built on its own, with LOOKOUT_FIRST_RUN naming it, so the test
 * reaches it without walking the flow.
 */

#include "lk-test.h"

#include "model/app-model.h"
#include "ui/firstrun/flow.h"

static LkAppModel *model;
static GtkWidget *page;

static gboolean
match_entry (GtkWidget *widget, gconstpointer data)
{
  (void) data;
  return GTK_IS_ENTRY (widget);
}

/* The draft field is the one entry on the step. */
static const char *
draft_text (void)
{
  GtkWidget *entry = lk_test_find (page, match_entry, NULL);

  g_assert_nonnull (entry);
  return gtk_editable_get_text (GTK_EDITABLE (entry));
}

static GtkWidget *
unit_toggle (const char *label)
{
  GtkWidget *button = lk_test_find_button (page, label);

  g_assert_nonnull (button);
  g_assert_true (GTK_IS_TOGGLE_BUTTON (button));
  return button;
}

/* The chosen clearance, read off the pill that carries the accent. Every pill
 * is a child of the one row, so the row comes off whichever pill is found. */
static char *
chosen_clearance (const char *any_pill)
{
  GtkWidget *pill = lk_test_find_button (page, any_pill);
  GtkWidget *row;

  g_assert_nonnull (pill);
  row = gtk_widget_get_parent (pill);
  for (GtkWidget *c = gtk_widget_get_first_child (row); c != NULL;
       c = gtk_widget_get_next_sibling (c))
    if (gtk_widget_has_css_class (c, "suggested-action"))
      return g_strdup (gtk_button_get_label (GTK_BUTTON (c)));
  return NULL;
}

/* Setup asks in feet, at a small keelboat. The engine's own default is metres,
 * and a mariner who wants those switches the unit. */
static void
test_starts_in_feet (void)
{
  g_assert_nonnull (lk_test_find_label (page, "How deep does your boat sit?"));
  g_assert_true (gtk_toggle_button_get_active (GTK_TOGGLE_BUTTON (unit_toggle ("Feet"))));
  g_assert_cmpstr (draft_text (), ==, "5.5");

  g_autofree char *clearance = chosen_clearance ("1 ft");
  g_assert_cmpstr (clearance, ==, "2 ft");

  /* 5.5 ft and 2 ft: an 8 ft safety depth, shaded against the 12 ft contour,
   * with the deep contour at 30 ft. */
  g_assert_nonnull (lk_test_find_label (page, "8 ft"));
  g_assert_nonnull (lk_test_find_label (page, "12 ft"));
  g_assert_nonnull (lk_test_find_label (page, "30 ft"));
}

/* The same boat in the other unit. 5.5 ft is 1.68 m, held to the half metre,
 * and 2 ft of clearance snaps to the 0.6 m the metric list offers. */
static void
test_the_unit_converts_the_boat (void)
{
  gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON (unit_toggle ("Metres")), TRUE);
  lk_test_drain ();

  g_assert_cmpstr (draft_text (), ==, "1.5");

  g_autofree char *metric = chosen_clearance ("0.3 m");
  g_assert_cmpstr (metric, ==, "0.6 m");

  /* 1.5 m and 0.6 m: a 3 m safety depth against the 5 m contour, deep at
   * 10 m. */
  g_assert_nonnull (lk_test_find_label (page, "3 m"));
  g_assert_nonnull (lk_test_find_label (page, "5 m"));
  g_assert_nonnull (lk_test_find_label (page, "10 m"));

  /* And back. The round trip holds the boat to the nearest half foot, which
   * is 5 ft rather than the 5.5 ft it started at. */
  gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON (unit_toggle ("Feet")), TRUE);
  lk_test_drain ();

  g_assert_cmpstr (draft_text (), ==, "5");
  g_autofree char *feet = chosen_clearance ("1 ft");
  g_assert_cmpstr (feet, ==, "2 ft");
}

/* A draft typed into the field moves the numbers under it. */
static void
test_a_typed_draft_moves_the_numbers (void)
{
  GtkWidget *entry = lk_test_find (page, match_entry, NULL);

  g_assert_nonnull (entry);
  gtk_editable_set_text (GTK_EDITABLE (entry), "20");
  lk_test_drain ();

  /* 20 ft and 2 ft: a 22 ft safety depth, shaded against the 30 ft contour. */
  g_assert_nonnull (lk_test_find_label (page, "22 ft"));
  g_assert_nonnull (lk_test_find_label (page, "30 ft"));
  g_assert_nonnull (lk_test_find_label (page, "60 ft"));
}

int
main (int argc, char *argv[])
{
  lk_test_gtk_init (&argc, &argv);

  /* The step names itself, so the test does not walk the flow to reach it. */
  g_setenv ("LOOKOUT_FIRST_RUN", "depths", TRUE);

  model = lk_app_model_new ();
  page = lk_first_run_page_new (model);
  lk_first_run_consider (page);
  lk_test_drain ();

  g_test_add_func ("/depth-step/starts-in-feet", test_starts_in_feet);
  g_test_add_func ("/depth-step/the-unit-converts-the-boat",
                   test_the_unit_converts_the_boat);
  /* Last: it leaves a 20 ft boat behind it. */
  g_test_add_func ("/depth-step/a-typed-draft-moves-the-numbers",
                   test_a_typed_draft_moves_the_numbers);

  return g_test_run ();
}
