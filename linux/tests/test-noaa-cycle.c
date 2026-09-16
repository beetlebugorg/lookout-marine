/* test-noaa-cycle.c — the NOAA downloader over a whole cycle.
 *
 * Add a region, restart, remove it, add it again. What the picker shows at
 * each of those steps comes from two places: a record of the regions this
 * device downloaded, and the cells the downloader's own set holds. The two
 * disagree after every removal, and each way they disagreed here was a defect
 * a mariner reported.
 *
 * Needs NOAA's catalog, and reading one needs the network, so this binary
 * skips itself unless LK_TEST_NETWORK is set. It downloads no charts.
 *
 * WHAT THIS CANNOT REACH. The picker reads what the downloader's set holds
 * from the core every time it opens, so a test cannot state held water through
 * it: the library here is empty and the picker is right to say so. A region
 * held WHOLE therefore needs a real download, and the rule that decides it is
 * checked below against the catalog instead, one layer down.
 */

#include "lk-test.h"

#include "library/noaa.h"
#include "model/app-model.h"
#include "model/store.h"
#include "ui/charts/noaa-window.h"
#include "ui/window.h"

/* One district, and one next to it. Two are enough to show a removal taking
 * the right one out of the record, and the cells of the first spilling over
 * the line into the second. */
#define LK_TEST_REGION  "d1"
#define LK_TEST_REGION2 "d5"

static LkAppModel *model;
static LkNoaa     *noaa;
static GtkWidget  *window;

/* ---- the harness --------------------------------------------------------- */

/* Read the catalog, and wait for it. Every price, every per-region count and
 * the seed itself waits on this, so a test that runs without it proves
 * nothing. Bounded: NOAA answers or the run says so. */
static gboolean
catalog_ready (void)
{
  if (lk_noaa_state (noaa)->have_catalog)
    return TRUE;

  lk_noaa_refresh (noaa);

  for (int i = 0; i < 900; i++)
    {
      lk_test_drain ();
      if (lk_noaa_state (noaa)->have_catalog)
        return TRUE;
      g_usleep (100000);
      lk_noaa_poll (noaa);
    }
  g_print ("# catalog phase=%d error=%s\n", lk_noaa_state (noaa)->phase,
           lk_noaa_state (noaa)->error);
  return FALSE;
}

/* State the device holds every cell of `id`, without downloading one. The
 * picker reads what the downloader's set holds through this call, so naming
 * the cells is the same state a finished download leaves it in. */
static void
hold_region (const char *id)
{
  g_auto (GStrv) cells = lk_noaa_region_cells (noaa, id);

  g_assert_cmpuint (g_strv_length (cells), >, 0);
  lk_noaa_note_managed (noaa, (const char *const *) cells);
}

/* And hold none of it. */
static void
hold_nothing (void)
{
  static const char *const none[] = { NULL };

  lk_noaa_note_managed (noaa, none);
}

static void
record (const char *const *ids)
{
  lk_store_save_noaa_regions (ids);
}

static char **
recorded (void)
{
  return lk_noaa_downloaded_regions (noaa);
}

/* The window the picker opens in, found by its title. It is a toplevel of its
 * own, so nothing this suite holds is its parent. */
static GtkWidget *
picker_window (void)
{
  GListModel *tops = gtk_window_get_toplevels ();
  guint n = g_list_model_get_n_items (tops);

  for (guint i = 0; i < n; i++)
    {
      g_autoptr (GtkWindow) top = g_list_model_get_item (tops, i);

      if (g_strcmp0 (gtk_window_get_title (top), "NOAA Charts") == 0)
        return GTK_WIDGET (top);
    }
  return NULL;
}

static GtkWidget *
picker (void)
{
  lk_noaa_window_present (GTK_WINDOW (window), model);
  lk_test_drain ();
  return picker_window ();
}

/* ---- the record ---------------------------------------------------------- */

/* The record goes through the store, so it is what a restart reads.
 *
 * The pick itself does not survive a restart and must not: it is scratch work.
 * What the mariner downloaded is a fact about the device, and the picker opens
 * on it. */
static void
test_the_record_survives_a_restart (void)
{
  static const char *const two[] = { LK_TEST_REGION, LK_TEST_REGION2, NULL };

  record (two);

  g_auto (GStrv) back = recorded ();
  g_assert_cmpuint (g_strv_length (back), ==, 2);
  g_assert_true (g_strv_contains ((const char *const *) back, LK_TEST_REGION));
  g_assert_true (g_strv_contains ((const char *const *) back, LK_TEST_REGION2));

  /* A second model reads the same record. This is the restart. */
  g_autoptr (LkAppModel) again = lk_app_model_new ();
  g_auto (GStrv) theirs = lk_noaa_downloaded_regions (lk_app_model_get_noaa (again));

  g_assert_cmpuint (g_strv_length (theirs), ==, 2);
}

/* A region downloaded whole reads as held whole, and its neighbour does not.
 *
 * NOAA files cells across district lines, so downloading one district installs
 * some of the next one's. Counting those as the neighbour is what ticked a
 * district the mariner never chose. */
static void
test_a_downloaded_region_is_held_whole (void)
{
  guint32 cells = 0, held = 0;

  hold_region (LK_TEST_REGION);

  g_assert_true (lk_noaa_region_held (noaa, LK_TEST_REGION, &cells, &held));
  g_assert_cmpuint (cells, >, 0);
  g_assert_cmpuint (held, ==, cells);

  /* The neighbour holds some of those cells and is not downloaded. */
  g_assert_true (lk_noaa_region_held (noaa, LK_TEST_REGION2, &cells, &held));
  g_assert_cmpuint (cells, >, 0);
  g_assert_cmpuint (held, <, cells);
}

/* A library downloaded before the record existed adopts what it holds whole,
 * once, and the spillover district stays out of it. */
static void
test_adopt_takes_only_whole_regions (void)
{
  static const char *const none[] = { NULL };

  record (none);
  hold_region (LK_TEST_REGION);

  g_assert_true (lk_noaa_adopt_downloaded (noaa));

  g_auto (GStrv) after = recorded ();
  g_assert_true (g_strv_contains ((const char *const *) after, LK_TEST_REGION));
  g_assert_false (g_strv_contains ((const char *const *) after, LK_TEST_REGION2));

  /* Once. A record with something in it is the mariner's, not a guess. */
  g_assert_false (lk_noaa_adopt_downloaded (noaa));
}

/* Charts removed by another route take their region out of the record.
 *
 * Removing the chart set from the Charts pane deletes the prepared charts
 * without the picker hearing of it. Without this the region opens ticked ever
 * after, and reads as water the device holds. */
static void
test_prune_drops_a_region_whose_charts_have_gone (void)
{
  static const char *const one[] = { LK_TEST_REGION, NULL };

  record (one);
  hold_nothing ();
  lk_noaa_prune_downloaded (noaa);

  g_auto (GStrv) after = recorded ();
  g_assert_cmpuint (g_strv_length (after), ==, 0);
}

/* And a region still held stays. A prune that emptied the record on every open
 * would send a mariner to download what they have. */
static void
test_prune_keeps_a_region_still_held (void)
{
  static const char *const one[] = { LK_TEST_REGION, NULL };

  record (one);
  hold_region (LK_TEST_REGION);
  lk_noaa_prune_downloaded (noaa);

  g_auto (GStrv) after = recorded ();
  g_assert_cmpuint (g_strv_length (after), ==, 1);
  g_assert_cmpstr (after[0], ==, LK_TEST_REGION);
}

/* A removal takes its own region out and leaves the rest. */
static void
test_forget_drops_only_what_was_removed (void)
{
  static const char *const two[] = { LK_TEST_REGION, LK_TEST_REGION2, NULL };
  static const char *const gone[] = { LK_TEST_REGION, NULL };

  record (two);
  lk_noaa_forget_downloaded (noaa, gone);

  g_auto (GStrv) after = recorded ();
  g_assert_cmpuint (g_strv_length (after), ==, 1);
  g_assert_cmpstr (after[0], ==, LK_TEST_REGION2);
}

/* ---- the picker ---------------------------------------------------------- */

/* A record naming water whose charts have gone opens UNTICKED.
 *
 * This is the state a mariner is left in by removing the chart set from the
 * Charts pane: the record still names the regions, and the device holds none
 * of their charts. The picker opened them ticked and read as holding water it
 * had deleted.
 *
 * The counts start out saying the charts are there, which is what an earlier
 * open of the picker left behind. The library is what settles it, and this
 * library is empty. */
static void
test_a_stale_record_opens_unticked (void)
{
  static const char *const one[] = { LK_TEST_REGION, NULL };
  GtkWidget *view;

  record (one);
  hold_region (LK_TEST_REGION);
  lk_noaa_clear_picks (noaa);

  view = picker ();
  g_assert_nonnull (view);

  g_assert_false (lk_noaa_is_picked (noaa, LK_TEST_REGION));

  /* And the record itself is corrected, so the next open agrees with this one. */
  g_auto (GStrv) after = recorded ();
  g_assert_cmpuint (g_strv_length (after), ==, 0);

  gtk_window_destroy (GTK_WINDOW (view));
  lk_test_drain ();
}

/* A pick the mariner abandoned does not come back on the next open.
 *
 * The pick lives on the model, which outlives the picker window. Left standing,
 * the next open takes it as the baseline, so the region opens ticked and the
 * button opens dead: the water cannot be downloaded without unticking it
 * first. */
static void
test_an_abandoned_pick_does_not_come_back (void)
{
  static const char *const none[] = { NULL };
  GtkWidget *view, *button;

  record (none);
  hold_nothing ();

  view = picker ();
  g_assert_nonnull (view);
  lk_noaa_toggle (noaa, LK_TEST_REGION);
  lk_test_drain ();
  g_assert_true (lk_noaa_is_picked (noaa, LK_TEST_REGION));

  /* Cancel, which is what the mariner presses to abandon it. */
  g_signal_emit_by_name (lk_test_find_button (view, "Cancel"), "clicked");
  lk_test_drain ();
  g_assert_null (picker_window ());
  g_assert_cmpuint (lk_noaa_picked_count (noaa), ==, 0);

  /* The next open is bare, and picking the same water arms the button. */
  view = picker ();
  g_assert_nonnull (view);
  g_assert_false (lk_noaa_is_picked (noaa, LK_TEST_REGION));

  lk_noaa_toggle (noaa, LK_TEST_REGION);
  lk_test_drain ();
  button = lk_test_find_button (view, "Download");
  g_assert_nonnull (button);
  g_assert_true (gtk_widget_get_sensitive (button));

  gtk_window_destroy (GTK_WINDOW (view));
  lk_test_drain ();
}

/* Picking water arms the button, and it says the water is coming down. */
static void
test_a_new_pick_arms_the_button (void)
{
  static const char *const none[] = { NULL };
  GtkWidget *view, *button;

  record (none);
  hold_nothing ();

  view = picker ();
  g_assert_nonnull (view);
  button = lk_test_find_button (view, "Download");
  g_assert_nonnull (button);
  g_assert_false (gtk_widget_get_sensitive (button));

  lk_noaa_toggle (noaa, LK_TEST_REGION);
  lk_test_drain ();

  g_assert_true (gtk_widget_get_sensitive (button));
  g_assert_cmpstr (gtk_button_get_label (GTK_BUTTON (button)), ==, "Download");

  gtk_window_destroy (GTK_WINDOW (view));
  lk_test_drain ();
}

/* The whole cycle, in order: add, restart, remove, add again.
 *
 * The library here is empty, so the steps that state held water are stated one
 * layer down, against the record and the per-region counts. What the picker is
 * asked is what an empty library can answer: that it opens bare, that a pick
 * arms the button, and that neither the pick nor the record carries anything
 * into the next open that the device does not hold. */
static void
test_add_restart_remove_add (void)
{
  static const char *const none[] = { NULL };
  static const char *const one[] = { LK_TEST_REGION, NULL };
  GtkWidget *view, *button;

  /* ADD. Nothing held and nothing recorded, so the picker opens bare. */
  record (none);
  hold_nothing ();
  lk_noaa_clear_picks (noaa);

  view = picker ();
  g_assert_nonnull (view);
  g_assert_false (lk_noaa_is_picked (noaa, LK_TEST_REGION));

  lk_noaa_toggle (noaa, LK_TEST_REGION);
  lk_test_drain ();
  button = lk_test_find_button (view, "Download");
  g_assert_nonnull (button);
  g_assert_true (gtk_widget_get_sensitive (button));

  /* The download writes the record and fetches the cells. State both. */
  record (one);
  hold_region (LK_TEST_REGION);
  gtk_window_destroy (GTK_WINDOW (view));
  lk_test_drain ();

  /* RESTART. The pick is scratch work and goes. The record is a fact about the
   * device and stays, and the region reads as held whole. */
  g_assert_cmpuint (lk_noaa_picked_count (noaa), ==, 0);
  {
    guint32 cells = 0, held = 0;
    g_auto (GStrv) kept = recorded ();

    g_assert_cmpuint (g_strv_length (kept), ==, 1);
    g_assert_cmpstr (kept[0], ==, LK_TEST_REGION);
    g_assert_true (lk_noaa_region_held (noaa, LK_TEST_REGION, &cells, &held));
    g_assert_cmpuint (held, ==, cells);
  }

  /* REMOVE. The charts go and the region comes out of the record. */
  lk_noaa_forget_downloaded (noaa, one);
  hold_nothing ();
  {
    g_auto (GStrv) emptied = recorded ();

    g_assert_cmpuint (g_strv_length (emptied), ==, 0);
  }

  /* ADD AGAIN. The picker opens bare and the same water can be picked. A pick
   * left standing by the earlier open blocked exactly this: the region opened
   * ticked, and the button opened dead. */
  view = picker ();
  g_assert_nonnull (view);
  g_assert_false (lk_noaa_is_picked (noaa, LK_TEST_REGION));

  lk_noaa_toggle (noaa, LK_TEST_REGION);
  lk_test_drain ();
  button = lk_test_find_button (view, "Download");
  g_assert_nonnull (button);
  g_assert_true (gtk_widget_get_sensitive (button));

  gtk_window_destroy (GTK_WINDOW (view));
  lk_test_drain ();
}

int
main (int argc, char *argv[])
{
  lk_test_gtk_init (&argc, &argv);

  if (g_getenv ("LK_TEST_NETWORK") == NULL)
    {
      g_print ("1..0 # SKIP set LK_TEST_NETWORK=1: the catalog needs the network\n");
      return 77;
    }

  /* The real window, because the catalog is read through a chart handle and
     the chart view is what opens one. A bare window leaves the read with
     nothing to run on and the picker with nothing to price. */
  g_autoptr (GtkApplication) app =
      gtk_application_new ("org.beetlebug.LookoutMarine.Test", G_APPLICATION_NON_UNIQUE);
  g_application_register (G_APPLICATION (app), NULL, NULL);

  model = lk_app_model_new ();
  noaa = lk_app_model_get_noaa (model);
  window = lk_window_new (app, model);
  gtk_window_present (GTK_WINDOW (window));
  lk_app_model_set_view_size (model, 1280, 800);
  lk_test_drain ();

  if (!catalog_ready ())
    {
      g_print ("1..0 # SKIP NOAA's catalog did not arrive\n");
      return 77;
    }

  g_test_add_func ("/noaa-cycle/the-record-survives-a-restart",
                   test_the_record_survives_a_restart);
  g_test_add_func ("/noaa-cycle/a-downloaded-region-is-held-whole",
                   test_a_downloaded_region_is_held_whole);
  g_test_add_func ("/noaa-cycle/adopt-takes-only-whole-regions",
                   test_adopt_takes_only_whole_regions);
  g_test_add_func ("/noaa-cycle/prune-drops-a-region-whose-charts-have-gone",
                   test_prune_drops_a_region_whose_charts_have_gone);
  g_test_add_func ("/noaa-cycle/prune-keeps-a-region-still-held",
                   test_prune_keeps_a_region_still_held);
  g_test_add_func ("/noaa-cycle/forget-drops-only-what-was-removed",
                   test_forget_drops_only_what_was_removed);
  g_test_add_func ("/noaa-cycle/a-stale-record-opens-unticked",
                   test_a_stale_record_opens_unticked);
  g_test_add_func ("/noaa-cycle/an-abandoned-pick-does-not-come-back",
                   test_an_abandoned_pick_does_not_come_back);
  g_test_add_func ("/noaa-cycle/a-new-pick-arms-the-button",
                   test_a_new_pick_arms_the_button);
  g_test_add_func ("/noaa-cycle/add-restart-remove-add", test_add_restart_remove_add);

  return g_test_run ();
}
