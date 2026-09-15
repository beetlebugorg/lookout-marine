/* test-window.c — the main window, its actions, and the overlays that follow
 * the model's flags.
 *
 * The window is built against the real model with no chart open, so the
 * chart-only commands are disabled and every overlay reads its empty state.
 * The suite drives the model and the actions and reads what a mariner sees.
 */

#include "lk-test.h"

#include "model/app-model.h"
#include "pick-fixture.h"
#include "ui/window.h"

static LkAppModel *model;
static GtkWidget  *window; /* the application window, which is the action map */

static GAction *
action (const char *name)
{
  return g_action_map_lookup_action (G_ACTION_MAP (window), name);
}

/* Every command the accel table and the menus name is registered. */
static void
test_actions_exist (void)
{
  static const char *names[] = {
    "open", "open-archive", "open-file", "install-plugin", "forget-raster",
    "zoom-in", "zoom-out", "zoom-fit", "north-up", "follow",
    "cycle-scheme", "set-scheme", "toggle-text", "toggle-soundings",
    "toggle-other", "toggle-chart", "raster-select", "raster-cycle",
    "raster-add", "raster-add-folder", "search", "settings", "full-screen",
    "close-pick", "about", "licenses",
  };
  for (gsize i = 0; i < G_N_ELEMENTS (names); i++)
    g_assert_nonnull (action (names[i]));
}

/* With no chart the commands that act on one are disabled, and the ones that
 * work from an empty view stay enabled. */
static void
test_chart_only_disabled (void)
{
  static const char *chart_only[] = {
    "zoom-in", "zoom-out", "zoom-fit", "north-up", "follow", "cycle-scheme",
    "set-scheme", "toggle-text", "toggle-soundings", "toggle-other", "toggle-chart",
  };
  for (gsize i = 0; i < G_N_ELEMENTS (chart_only); i++)
    g_assert_false (g_action_get_enabled (action (chart_only[i])));

  g_assert_true (g_action_get_enabled (action ("open")));
  g_assert_true (g_action_get_enabled (action ("search")));
  g_assert_true (g_action_get_enabled (action ("settings")));
}

/* Activating a command with no chart is safe: the chart-only ones are disabled
 * no-ops, and the ones that work do not crash. The dialog-raising commands are
 * left out — a test must not spawn a file chooser. */
static void
test_activate_no_chart_safe (void)
{
  static const char *safe[] = {
    "zoom-in", "zoom-out", "zoom-fit", "north-up", "follow", "cycle-scheme",
    "toggle-text", "toggle-soundings", "toggle-other", "toggle-chart",
    "search", "forget-raster", "close-pick",
  };
  for (gsize i = 0; i < G_N_ELEMENTS (safe); i++)
    g_action_group_activate_action (G_ACTION_GROUP (window), safe[i], NULL);
  g_action_group_activate_action (G_ACTION_GROUP (window), "search", NULL); /* close it again */
  lk_test_drain ();
}

/* With nothing installed the mariner gets SETUP, not a page: there is a
 * decision to make, and the flow is what asks it.
 *
 * The switched-off page stands for the one other case, where charts ARE
 * installed and every set is off, and it stays down here. */
static void
test_setup_runs_over_an_empty_library (void)
{
  GtkWidget *setup = lk_test_find_label (window, "Welcome to Lookout Marine");
  GtkWidget *switched_off = lk_test_find_label (window, "Every chart set is switched off");
  GtkWidget *capsule = lk_test_find_css (window, "lk-capsule");

  g_assert_nonnull (setup);
  g_assert_true (lk_test_shown (setup, window));

  g_assert_nonnull (switched_off);
  g_assert_false (lk_test_shown (switched_off, window));

  /* No chart, no readouts: a capsule reading 1:— over an empty view is chrome
   * with nothing to report. */
  g_assert_nonnull (capsule);
  g_assert_false (lk_test_shown (capsule, window));
}

/* Setup asks the three sources, with NOAA the one it recommends. */
static void
test_setup_steps (void)
{
  GtkWidget *later = lk_test_find_button (window, "Set Up Later");
  GtkWidget *primary = lk_test_find_button (window, "Continue");

  g_assert_nonnull (later);
  g_assert_true (lk_test_shown (later, window));
  g_assert_nonnull (primary);

  /* Continue moves to the source step, which offers the three sources. */
  g_signal_emit_by_name (primary, "clicked");
  lk_test_drain ();
  g_assert_nonnull (lk_test_find_label (window, "How would you like to add charts?"));
  g_assert_nonnull (lk_test_find_label (window, "NOAA charts"));
  g_assert_nonnull (lk_test_find_label (window, "Online chart"));
  g_assert_nonnull (lk_test_find_label (window, "Files on this computer"));
  g_assert_nonnull (lk_test_find_label (window, "Recommended"));

  /* Set Up Later belongs to the welcome step alone. Past it the mariner is
     choosing a chart, and Back is what returns them. */
  g_assert_false (lk_test_shown (lk_test_find_button (window, "Set Up Later"), window));
  GtkWidget *back = lk_test_find_button (window, "Back");
  g_assert_nonnull (back);
  g_assert_true (lk_test_shown (back, window));

  g_signal_emit_by_name (back, "clicked");
  lk_test_drain ();
  g_assert_nonnull (lk_test_find_label (window, "Welcome to Lookout Marine"));
}

/* Set Up Later is "not now", and it leaves a working app behind it. */
static void
test_setup_later_puts_it_away (void)
{
  GtkWidget *later = lk_test_find_button (window, "Set Up Later");

  g_assert_nonnull (later);
  g_signal_emit_by_name (later, "clicked");
  lk_test_drain ();

  /* Setup is down, and the page under it is not raised in its place: the
     mariner asked for the app, not for another page. */
  g_assert_null (lk_test_find_label (window, "Welcome to Lookout Marine"));
  g_assert_false (lk_test_shown (lk_test_find_label (window,
                                                     "Every chart set is switched off"),
                                 window));

  /* And it stays down for the rest of the launch, however often the window
     reconsiders. */
  lk_app_model_set_chart_open (model, FALSE, NULL);
  lk_test_drain ();
  g_assert_null (lk_test_find_label (window, "Welcome to Lookout Marine"));
}

/* The page answers to whether anything is DRAWN, not to whether a chart is
 * open. A chart of no charts is open and draws the basemap, so has-chart says
 * yes while the mariner has nothing.
 *
 * The four states, in the order a launch meets them. The engine has no handle
 * here, so a chart reported open reads as one holding no charts, which is
 * exactly the state under test. */
static void
test_page_follows_nothing_to_draw (void)
{
  GtkWidget *page = lk_test_find_css (window, "lk-page");
  GtkWidget *first_run = lk_test_find_label (window, "Welcome to Lookout Marine");
  GtkWidget *loader = lk_test_find_label (window, "Opening the chart");

  g_assert_nonnull (page);
  g_assert_nonnull (first_run);
  g_assert_nonnull (loader);

  /* Nothing open, nothing installed. */
  g_assert_true (lk_app_model_get_nothing_to_draw (model));
  g_assert_true (lk_test_shown (page, window));
  g_assert_true (lk_test_shown (first_run, window));

  /* An open in flight. The loader says which of the three waits this is.
     Setup STAYS up: it is a card over a running app, and its import step is
     the page that watches the charts arrive. */
  lk_app_model_set_opening (model, TRUE, FALSE);
  lk_test_drain ();
  g_assert_false (lk_app_model_get_nothing_to_draw (model));
  g_assert_true (lk_test_shown (loader, window));

  /* Open, and holding no charts. The loader has done its job and the page
     comes back: the basemap is not a library. */
  lk_app_model_set_opening (model, FALSE, FALSE);
  lk_app_model_set_chart_open (model, TRUE, NULL);
  lk_app_model_set_first_build_done (model, TRUE);
  lk_test_drain ();
  g_assert_true (lk_app_model_get_has_chart (model));
  g_assert_true (lk_app_model_get_chart_is_empty (model));
  g_assert_true (lk_app_model_get_nothing_to_draw (model));
  g_assert_true (lk_test_shown (first_run, window));

  /* The chrome that reports on a chart stays down with setup up. */
  g_assert_false (lk_test_shown (lk_test_find_css (window, "lk-capsule"), window));
  g_assert_false (g_action_get_enabled (action ("zoom-in")));

  lk_app_model_set_chart_open (model, FALSE, NULL);
  lk_test_drain ();
}

/* A pick raises the report into the overlay; close-pick clears the set, and the
 * report leaves with it. */
static void
test_close_pick_clears_report (void)
{
  LkPickDecoded *f = lk_fixture_feature ("LIGHTS", "US5MD1MC", "Fl(2) 10s 5m",
                                         "Light", "Light", "US5MD1MC ed 27");
  GPtrArray *results = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_pick_decoded_free);

  g_ptr_array_add (f->rows, lk_fixture_row ("Colour", "red", 0));
  g_ptr_array_add (results, f);
  lk_app_model_set_pick (model, results, 640, 400, -76.48, 38.98);
  lk_test_drain ();

  g_assert_nonnull (lk_test_find_css (window, "lk-pick-report"));

  g_action_group_activate_action (G_ACTION_GROUP (window), "close-pick", NULL);
  lk_test_drain ();

  g_assert_null (lk_test_find_css (window, "lk-pick-report"));
}

/* The scheme action tracks the chart's scheme, so the menu radio marks the one
 * in force even when a cycle or a load moved it. The engine reports the scheme
 * through the readouts push, which is the path a load or a Ctrl+L cycle takes. */
static void
push_scheme (int scheme)
{
  lookout_view view = { .lon = -76.48, .lat = 38.98, .zoom = 14, .rotation_deg = 0 };
  lk_app_model_push_readouts (model, view, 13267, 1.0, scheme);
  lk_test_drain ();
}

static void
test_scheme_action_follows (void)
{
  g_autoptr (GVariant) night = NULL;
  g_autoptr (GVariant) day = NULL;

  push_scheme (2);
  night = g_action_get_state (action ("set-scheme"));
  g_assert_cmpint (g_variant_get_int32 (night), ==, 2);

  push_scheme (0);
  day = g_action_get_state (action ("set-scheme"));
  g_assert_cmpint (g_variant_get_int32 (day), ==, 0);
}

int
main (int argc, char *argv[])
{
  lk_test_gtk_init (&argc, &argv);

  g_autoptr (GtkApplication) app =
      gtk_application_new ("org.beetlebug.LookoutMarine.Test", G_APPLICATION_NON_UNIQUE);
  g_application_register (G_APPLICATION (app), NULL, NULL);

  model = lk_app_model_new ();
  window = lk_window_new (app, model);
  gtk_window_present (GTK_WINDOW (window));
  lk_app_model_set_view_size (model, 1280, 800);
  lk_test_drain ();

  g_test_add_func ("/window/actions-exist", test_actions_exist);
  g_test_add_func ("/window/chart-only-disabled", test_chart_only_disabled);
  g_test_add_func ("/window/activate-no-chart-safe", test_activate_no_chart_safe);
  g_test_add_func ("/window/setup-runs-over-an-empty-library",
                   test_setup_runs_over_an_empty_library);
  g_test_add_func ("/window/setup-steps", test_setup_steps);
  g_test_add_func ("/window/page-follows-nothing-to-draw", test_page_follows_nothing_to_draw);
  g_test_add_func ("/window/close-pick-clears-report", test_close_pick_clears_report);
  g_test_add_func ("/window/scheme-action-follows", test_scheme_action_follows);
  /* Last: it puts setup away for the rest of the run. */
  g_test_add_func ("/window/setup-later-puts-it-away", test_setup_later_puts_it_away);

  return g_test_run ();
}
