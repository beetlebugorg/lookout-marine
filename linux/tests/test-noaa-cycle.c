/* test-noaa-cycle.c: the NOAA picker against NOAA's real catalog.
 *
 * The core keeps the record of downloaded water and counts what each region
 * holds. This suite checks what the picker shows from those: the catalog
 * line, a stale record, and a pick that arms the button.
 *
 * Needs NOAA's catalog, and reading one needs the network, so this binary
 * skips itself unless LK_TEST_NETWORK is set. It downloads no charts.
 */

#include <string.h>

#include "lk-test.h"

#include "model/noaa.h"
#include "model/app-model.h"
#include "model/store.h"
#include "ui/charts/coverage-map.h"
#include "ui/charts/noaa-window.h"
#include "ui/window.h"

/* One district. */
#define LK_TEST_REGION "d1"

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
    }
  g_print ("# catalog phase=%d error=%s\n", lk_noaa_state (noaa)->phase,
           lk_noaa_state (noaa)->error);
  return FALSE;
}

/* The catalog is written to the disk.
 *
 * Every region control requires a catalog, and this picker is the only route
 * into a downloaded set. The core stores the catalog it reads and loads it
 * again before the next network read. That lets the picker work with no
 * network. The read-back half is checked in the core against a
 * service with no fetcher (src/noaajob.zig). */
static void
test_the_catalog_is_kept_on_the_disk (void)
{
  g_autofree char *path = g_build_filename (g_get_user_cache_dir (), "lookout",
                                            "fetched", "ENCProdCat.xml", NULL);

  /* catalog_ready has already run for this suite. */
  g_assert_true (lk_noaa_state (noaa)->have_catalog);
  g_assert_true (g_file_test (path, G_FILE_TEST_EXISTS));

  /* The file is complete. The catalog is about 10 MB, so a partial write is
   * the failure to guard against. */
  g_autofree char *bytes = NULL;
  gsize len = 0;
  g_assert_true (g_file_get_contents (path, &bytes, &len, NULL));
  g_assert_cmpuint (len, >, 0);
  g_assert_nonnull (strstr (bytes, "</EncProductCatalog>"));
}

/* A catalog already read outranks a failed read, on the line that reports it.
 *
 * The core loads the cached catalog before it requests a new one, so a
 * mariner with no network has a working picker and a failed request at the
 * same time. Showing the error first put red text where the catalog summary
 * belongs. The error now shows as a caption below the summary.
 *
 * This raises the error by asking to download water the device already holds
 * in full. That is the one failure this suite can produce with a catalog
 * still loaded. The line treats every error the same way. */
static void
test_a_failed_read_does_not_hide_the_catalog (void)
{
  GtkWidget *line = lk_noaa_catalog_line_new (noaa);
  GtkWidget *host = gtk_window_new ();

  gtk_window_set_child (GTK_WINDOW (host), line);
  gtk_window_present (GTK_WINDOW (host));
  lk_test_drain ();

  g_assert_true (lk_noaa_state (noaa)->have_catalog);

  /* Now a failed read, with the catalog still in hand. With no fetcher the
   * read fails at once. */
  lookout_noaa_set_http_provider (lk_noaa_service (noaa), NULL, NULL, NULL, NULL);
  lk_noaa_refresh (noaa);
  lk_test_drain ();

  const char *error = lk_noaa_state (noaa)->error;
  g_assert_cmpstr (error, !=, "");
  g_assert_true (lk_noaa_state (noaa)->have_catalog);

  /* The catalog summary comes first, and the failure shows below it. */
  g_autofree char *summary = g_strdup_printf ("%u charts published, catalog dated %s.",
                                              lk_noaa_state (noaa)->catalog_cells,
                                              lk_noaa_state (noaa)->date);
  GtkWidget *says_catalog = lk_test_find_label (line, summary);
  GtkWidget *says_error = lk_test_find_label (line, error);

  g_assert_nonnull (says_catalog);
  g_assert_true (lk_test_shown (says_catalog, line));
  g_assert_nonnull (says_error);
  g_assert_true (lk_test_shown (says_error, line));
  /* The catalog summary does not have the error class. */
  g_assert_false (gtk_widget_has_css_class (says_catalog, "error"));

  gtk_window_destroy (GTK_WINDOW (host));
  lk_test_drain ();
  lk_noaa_clear_picks (noaa);
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

/* ---- the picker ---------------------------------------------------------- */

/* A record naming water whose charts have gone opens UNTICKED.
 *
 * This is the state a mariner is left in by removing the chart set from the
 * Charts pane: the core's record still names the region, and the device holds
 * none of its charts. This library is empty. */
static void
test_a_stale_record_opens_unticked (void)
{
  GtkWidget *view;

  lookout_store_set_text (lk_store_handle (), LOOKOUT_STORE_CHARTSETS, "noaa-picked",
                          LK_TEST_REGION);
  lk_noaa_clear_picks (noaa);

  view = picker ();
  g_assert_nonnull (view);

  g_assert_false (lk_noaa_is_picked (noaa, LK_TEST_REGION));
  g_assert_false (lk_noaa_region_info (noaa, LK_TEST_REGION)->recorded);

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
  GtkWidget *view, *button;

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
  GtkWidget *view, *button;

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

  g_test_add_func ("/noaa-cycle/the-catalog-is-kept-on-the-disk",
                   test_the_catalog_is_kept_on_the_disk);
  g_test_add_func ("/noaa-cycle/a-failed-read-does-not-hide-the-catalog",
                   test_a_failed_read_does_not_hide_the_catalog);
  g_test_add_func ("/noaa-cycle/a-stale-record-opens-unticked",
                   test_a_stale_record_opens_unticked);
  g_test_add_func ("/noaa-cycle/an-abandoned-pick-does-not-come-back",
                   test_an_abandoned_pick_does_not_come_back);
  g_test_add_func ("/noaa-cycle/a-new-pick-arms-the-button",
                   test_a_new_pick_arms_the_button);

  return g_test_run ();
}
