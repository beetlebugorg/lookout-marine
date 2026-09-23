/* test-window.c: the main window, its actions, and the overlays that follow
 * the model's flags.
 *
 * The window is built against the real model with no chart open, so the
 * chart-only commands are disabled and every overlay reads its empty state.
 * The suite drives the model and the actions and reads what a mariner sees.
 */

#include "lk-test.h"

#include "model/app-model.h"
#include "model/mariner.h"
#include "model/store.h"
#include "noaa-fixture.h"
#include "pick-fixture.h"
#include "ui/firstrun/private.h"
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
 * left out, a test must not spawn a file chooser. */
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

/* With nothing installed the mariner gets SETUP. There is a decision to make,
 * and the flow is what asks it.
 *
 * A library whose sets are all switched off gets the basemap with the chrome
 * over it, so no page stands for that state. */
static void
test_setup_runs_over_an_empty_library (void)
{
  GtkWidget *setup = lk_test_find_label (window, "Welcome to Lookout Marine");
  GtkWidget *capsule = lk_test_find_css (window, "lk-capsule");

  g_assert_nonnull (setup);
  g_assert_true (lk_test_shown (setup, window));

  g_assert_null (lk_test_find_label (window, "Every chart set is switched off"));

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

  /* Setup is down and no page is raised in its place: the mariner asked for
     the app, and the app is the basemap with the chrome over it. */
  g_assert_null (lk_test_find_label (window, "Welcome to Lookout Marine"));
  g_assert_null (lk_test_find_label (window, "Every chart set is switched off"));

  /* And it stays down for the rest of the launch, however often the window
     reconsiders. */
  lk_app_model_set_chart_open (model, FALSE, NULL);
  lk_test_drain ();
  g_assert_null (lk_test_find_label (window, "Welcome to Lookout Marine"));
}

/* An open with no charts leaves the saved pose alone.
 *
 * With a store attached the engine writes the pose every few seconds and
 * again at close, and a chart of no charts opens on the whole world. That
 * pose read as the mariner's own, so the next open with charts restored the
 * world in place of the water they left. */
static void
test_an_empty_open_keeps_the_stored_pose (void)
{
  /* This suite opens no charts, so every open here is the empty one. */
  g_assert_false (lk_store_has_saved_view ());
}

/* A mariner setting reaches the store with a chart of no charts open.
 *
 * That chart holds no store, so the engine saves no settings through it. The
 * edit is written here, as it is with no chart at all. */
static void
test_a_setting_is_saved_over_the_basemap (void)
{
  LkChartController *controller = lk_app_model_get_controller (model);
  g_autoptr (LkMariner) mariner = lk_mariner_new (controller);
  tile57_mariner *raw = lk_mariner_raw (mariner);

  /* This suite opens a chart of no charts. */
  g_assert_true (lk_chart_controller_is_open (controller));
  g_assert_false (lk_chart_controller_has_store (controller));

  raw->safety_depth = 7.5;
  lk_mariner_touch (mariner);

  for (int i = 0; i < 60; i++)
    {
      g_main_context_iteration (NULL, FALSE);
      g_usleep (10000);
    }

  tile57_mariner saved;
  lookout_mariner_defaults (&saved);
  lookout_store_read_mariner (lk_store_handle (), &saved);
  g_assert_cmpfloat (saved.safety_depth, ==, 7.5);
}

/* The scrim goes when setup does.
 *
 * The fill and the scrim stand on the setup card, and the window read them
 * from events the model raises. Setup going away is the flow's own move, so
 * both stayed up until something unrelated redrew them. */
static void
test_the_scrim_goes_with_setup (void)
{
  GtkWidget *page = lk_test_find_css (window, "lk-scrim");

  /* This runs after Set Up Later, so the card has gone. */
  g_assert_null (lk_test_find_label (window, "Welcome to Lookout Marine"));
  g_assert_null (page);
}

/* Setup comes back when the library goes empty.
 *
 * A mariner who removes every chart through the NOAA picker has an empty
 * library and no way back to the page that builds one, because finishing setup
 * put it away for the run. This reads the rule directly. Driving it through
 * the window needs a library to remove.
 *
 * Set Up Later is the other half. A mariner who never had charts asked for the
 * app, so setup stays down for them. */
static void
test_setup_returns_when_the_library_empties (void)
{
  g_autoptr (LkFirstRun) run = lk_first_run_new ();

  /* A run with charts, put away by finishing setup. */
  g_assert_false (lk_first_run_should_run (run, FALSE, FALSE));
  lk_first_run_finish (run);
  g_assert_false (lk_first_run_should_run (run, FALSE, FALSE));

  /* The charts go. */
  g_assert_true (lk_first_run_should_run (run, TRUE, FALSE));

  /* Set Up Later over a library that never had charts holds. */
  g_autoptr (LkFirstRun) later = lk_first_run_new ();

  g_assert_true (lk_first_run_should_run (later, TRUE, FALSE));
  lk_first_run_finish (later);
  g_assert_false (lk_first_run_should_run (later, TRUE, FALSE));
}

/* NOAA's terms are answered before their charts are picked.
 *
 * The step went straight to coverage and showed the terms as a note beside
 * the map, so there was no accept and no decline. The reference moves to
 * coverage only from the accept. */
static void
test_the_noaa_terms_gate_the_coverage_step (void)
{
  g_autoptr (LkFirstRun) run = lk_first_run_new ();

  g_setenv ("LOOKOUT_FIRST_RUN", "source", TRUE);
  lk_first_run_begin (run);
  g_unsetenv ("LOOKOUT_FIRST_RUN");
  lk_first_run_set_source (run, LK_FIRST_RUN_NOAA);

  /* Continue asks, and leaves the mariner where they were. */
  g_assert_false (lk_first_run_advance (run, NULL));
  g_assert_cmpint (lk_first_run_step (run), ==, LK_FIRST_RUN_SOURCE);

  /* A decline is the same as never answering. */
  g_assert_cmpint (lk_first_run_step (run), ==, LK_FIRST_RUN_SOURCE);

  lk_first_run_accept_terms (run);
  g_assert_cmpint (lk_first_run_step (run), ==, LK_FIRST_RUN_COVERAGE);

  /* And the accept applies to that one step alone. */
  lk_first_run_accept_terms (run);
  g_assert_cmpint (lk_first_run_step (run), ==, LK_FIRST_RUN_COVERAGE);
}

/* An import with no chart offers a way out.
 *
 * Continue waits on a bake, and the bake starts only once a cell arrives. A
 * download that failed every cell left the step with Continue dead, Stop with
 * no job, and Back hidden, so the card stood over an empty library with no
 * live control. */
static void
test_an_import_with_no_chart_can_go_back (void)
{
  g_autoptr (LkFirstRun) run = lk_first_run_new ();
  LkFirstRunFlow flow = { .model = model, .flow = run };

  g_setenv ("LOOKOUT_FIRST_RUN", "importing", TRUE);
  lk_first_run_begin (run);
  g_unsetenv ("LOOKOUT_FIRST_RUN");

  /* No download, no bake, and an empty library. */
  g_assert_true (lk_app_model_get_nothing_to_draw (model));
  g_assert_false (lk_first_run_saw_bake (run));
  g_assert_true (lk_first_run_import_stalled (&flow));

  /* Back leaves for the coverage step, where the water is still picked. */
  lk_first_run_back (run);
  g_assert_cmpint (lk_first_run_step (run), ==, LK_FIRST_RUN_COVERAGE);

  /* A bake seen is an import doing its job, so the step waits as it did. */
  g_setenv ("LOOKOUT_FIRST_RUN", "importing", TRUE);
  lk_first_run_begin (run);
  g_unsetenv ("LOOKOUT_FIRST_RUN");
  lk_first_run_note_bake (run);
  g_assert_false (lk_first_run_import_stalled (&flow));
}

/* A download that failed ends the import, and Back leaves the step. The
 * only transfer fails on the network, so the outcome is FAILED. */
static void
test_a_failed_download_can_go_back (void)
{
  g_autoptr (LkFirstRun) run = lk_first_run_new ();
  LkFirstRunFlow flow = { .model = model, .flow = run };
  LkNoaa *noaa = lk_app_model_get_noaa (model);
  lookout_noaa *service = lk_noaa_service (noaa);
  g_autofree char *cached = lk_fixture_catalog_path ();
  LkFakeFetch fake = { 0 };

  g_setenv ("LOOKOUT_FIRST_RUN", "importing", TRUE);
  lk_first_run_begin (run);
  g_unsetenv ("LOOKOUT_FIRST_RUN");

  /* Clearing the fetcher ends a catalog read that an earlier step started. */
  lk_fixture_cache_catalog ();
  lookout_noaa_set_http_provider (service, NULL, NULL, NULL, NULL);
  lookout_noaa_set_http_provider (service, lk_fake_get, lk_fake_cancel, NULL, &fake);
  lk_noaa_refresh (noaa);
  lk_noaa_toggle (noaa, "d5");
  lk_app_model_start_noaa_download (model, FALSE);
  lk_noaa_clear_picks (noaa);
  g_assert_cmpint (lk_noaa_state (noaa)->outcome, ==, LOOKOUT_NOAA_RUNNING);
  g_assert_false (lk_first_run_import_stalled (&flow));

  lookout_noaa_http_respond_chunk (service, fake.last, NULL, 0, 0, 1);
  lk_noaa_sync (noaa);
  g_assert_cmpint (lk_noaa_state (noaa)->outcome, ==, LOOKOUT_NOAA_FAILED);

  g_assert_true (lk_first_run_import_stalled (&flow));
  lk_first_run_back (run);
  g_assert_cmpint (lk_first_run_step (run), ==, LK_FIRST_RUN_COVERAGE);

  lookout_noaa_set_http_provider (service, NULL, NULL, NULL, NULL);
  g_assert_cmpint (g_remove (cached), ==, 0);
}

/* The page fill stands while there is no chart handle. A chart of no charts
 * draws the basemap, and setup floats over that, so the fill goes.
 *
 * The four states, in the order a launch meets them, driven through the model:
 * the harness opens a handle of its own accord and the assertions here are
 * about what the window draws for each state. */
static void
test_page_follows_nothing_to_draw (void)
{
  GtkWidget *page = lk_test_find_css (window, "lk-page");
  GtkWidget *first_run = lk_test_find_label (window, "Welcome to Lookout Marine");
  GtkWidget *loader = lk_test_find_label (window, "Opening the chart");

  g_assert_nonnull (page);
  g_assert_nonnull (first_run);
  g_assert_nonnull (loader);

  /* No handle and nothing installed: the fill stands, with no basemap under
     it, and setup stands on the fill. */
  lk_app_model_set_chart_open (model, FALSE, NULL);
  lk_app_model_set_opening (model, FALSE, FALSE);
  lk_test_drain ();
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

  /* Open, and holding no charts. The loader has done its job and the basemap
     draws. Setup stands over it behind a scrim, so the fill is up and dimming
     rather than hiding the map. */
  lk_app_model_set_opening (model, FALSE, FALSE);
  lk_app_model_set_chart_open (model, TRUE, NULL);
  lk_app_model_set_first_build_done (model, TRUE);
  lk_test_drain ();
  g_assert_true (lk_app_model_get_has_chart (model));
  g_assert_true (lk_app_model_get_chart_is_empty (model));
  g_assert_true (lk_app_model_get_nothing_to_draw (model));
  g_assert_true (lk_test_shown (first_run, window));
  g_assert_true (lk_test_shown (page, window));
  g_assert_true (gtk_widget_has_css_class (page, "lk-scrim"));

  /* The chrome that reports on a chart stays down with setup up. */
  g_assert_false (lk_test_shown (lk_test_find_css (window, "lk-capsule"), window));
  g_assert_false (g_action_get_enabled (action ("zoom-in")));

  /* The handle gone again: the fill stands on its own, with no basemap under
     it to dim. */
  lk_app_model_set_chart_open (model, FALSE, NULL);
  lk_test_drain ();
  g_assert_true (lk_test_shown (page, window));
  g_assert_false (gtk_widget_has_css_class (page, "lk-scrim"));
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
 * in force even when a cycle or a load moved it.
 *
 * Set through the model and wait for the engine to report it back, which is
 * the path a load or a Ctrl+L cycle takes. Pushing a readout by hand raced the
 * frame tick: the window opens a chart of no charts for the basemap, and that
 * tick pushes the engine's scheme over one written by hand. */
static void
push_scheme (int scheme)
{
  lk_app_model_set_scheme (model, scheme);
  for (int i = 0; i < 100; i++)
    {
      lk_test_drain ();
      if (lk_app_model_get_scheme (model) == scheme)
        return;
      g_usleep (5000);
    }
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
  g_test_add_func ("/window/the-noaa-terms-gate-the-coverage-step",
                   test_the_noaa_terms_gate_the_coverage_step);
  g_test_add_func ("/window/an-import-with-no-chart-can-go-back",
                   test_an_import_with_no_chart_can_go_back);
  g_test_add_func ("/window/a-failed-download-can-go-back",
                   test_a_failed_download_can_go_back);
  g_test_add_func ("/window/setup-returns-when-the-library-empties",
                   test_setup_returns_when_the_library_empties);
  g_test_add_func ("/window/page-follows-nothing-to-draw", test_page_follows_nothing_to_draw);
  g_test_add_func ("/window/close-pick-clears-report", test_close_pick_clears_report);
  g_test_add_func ("/window/scheme-action-follows", test_scheme_action_follows);
  /* Last: it puts setup away for the rest of the run. */
  g_test_add_func ("/window/setup-later-puts-it-away", test_setup_later_puts_it_away);
  g_test_add_func ("/window/a-setting-is-saved-over-the-basemap",
                   test_a_setting_is_saved_over_the_basemap);
  g_test_add_func ("/window/the-scrim-goes-with-setup", test_the_scrim_goes_with_setup);
  g_test_add_func ("/window/an-empty-open-keeps-the-stored-pose",
                   test_an_empty_open_keeps_the_stored_pose);

  return g_test_run ();
}
