/* test-preview.c: the fetcher, and the pictures a chart list shows.
 *
 * The core draws a chart link's picture. This checks what the shell holds
 * around it: the fetcher's responses, the pictures the binary ships, and what a
 * list shows with no chart open.
 *
 * No display, and no network.
 */

#include <glib/gstdio.h>

#include "library/fetch.h"
#include "ui/charts/catalog.h"
#include "ui/charts/preview.h"

/* A fetcher freed with a fetch in flight answers nobody and frees nothing
 * twice.
 *
 * Each completion runs on a later turn of the main loop, and a cancelled one
 * still runs. It used to read the fetcher's table and session after the free,
 * which is where a gallery row that went while a style resolved crashed. */
static void
answered (gpointer user_data, uint64_t req_id, const void *bytes, gsize len, int status,
          gboolean done)
{
  (*(guint *) user_data)++;
}

static gboolean
spin_over (gpointer user_data)
{
  *(gboolean *) user_data = TRUE;
  return G_SOURCE_REMOVE;
}

/* Run the main loop for `ms`, so the completions queued on it get their turn.
 * Blocking, because a non-blocking pass returns before a read that is already
 * on its way has finished. */
static void
spin (guint ms)
{
  gboolean over = FALSE;

  g_timeout_add (ms, spin_over, &over);
  while (!over)
    g_main_context_iteration (NULL, TRUE);
}

static void
test_a_freed_fetcher_leaves_its_completions_safe (void)
{
  guint answers = 0;
  LkFetcher *fetcher = lk_fetcher_new (answered, &answers);
  g_autofree char *path = g_build_filename (g_get_tmp_dir (), "lk-fetch-test.json", NULL);
  g_autofree char *url = g_strconcat ("file://", path, NULL);

  g_assert_true (g_file_set_contents (path, "{}", -1, NULL));

  /* Two reads in flight, off the main loop. */
  lk_fetcher_http_get (fetcher, 1, url, 1);
  lk_fetcher_http_get (fetcher, 2, url, 1);

  lk_fetcher_free (fetcher);

  /* Where the completions land. Under ASan this is the read of freed
   * memory. */
  spin (200);

  /* The owner has gone, so none of them is answered. */
  g_assert_cmpuint (answers, ==, 0);
  g_remove (path);
}

static guint chunk_pieces;
static gsize chunk_bytes;
static int chunk_status;
static gboolean chunk_done;

static void
chunked (gpointer user_data, uint64_t req_id, const void *bytes, gsize len, int status,
         gboolean done)
{
  chunk_pieces++;
  chunk_bytes += len;
  chunk_status = status;
  if (done)
    chunk_done = TRUE;
}

/* A file:// read arrives as one piece with done set. */
static void
test_a_file_read_is_one_piece (void)
{
  LkFetcher *fetcher = lk_fetcher_new (chunked, NULL);
  g_autofree char *path = g_build_filename (g_get_tmp_dir (), "lk-fetch-chunk.json", NULL);
  g_autofree char *url = g_strconcat ("file://", path, NULL);

  g_assert_true (g_file_set_contents (path, "{\"a\":1}", -1, NULL));

  chunk_pieces = 0;
  chunk_bytes = 0;
  chunk_done = FALSE;
  lk_fetcher_http_get (fetcher, 7, url, 1);
  spin (200);

  g_assert_cmpuint (chunk_pieces, ==, 1);
  g_assert_cmpuint (chunk_bytes, ==, 7);
  g_assert_cmpint (chunk_status, ==, 200);
  g_assert_true (chunk_done);

  lk_fetcher_free (fetcher);
  g_remove (path);
}

/* A refused file read is one piece with status 0, no bytes and done set. */
static void
test_a_refused_read_fails_in_one_piece (void)
{
  LkFetcher *fetcher = lk_fetcher_new (chunked, NULL);

  chunk_pieces = 0;
  chunk_bytes = 0;
  chunk_status = -1;
  chunk_done = FALSE;
  lk_fetcher_http_get (fetcher, 8, "file:///etc/hostname", 0);

  g_assert_cmpuint (chunk_pieces, ==, 1);
  g_assert_cmpuint (chunk_bytes, ==, 0);
  g_assert_cmpint (chunk_status, ==, 0);
  g_assert_true (chunk_done);

  lk_fetcher_free (fetcher);
}

/* A fetch answered while the fetcher lives reaches the owner. */
static void
test_a_live_fetcher_answers (void)
{
  guint answers = 0;
  LkFetcher *fetcher = lk_fetcher_new (answered, &answers);
  g_autofree char *path = g_build_filename (g_get_tmp_dir (), "lk-fetch-live.json", NULL);
  g_autofree char *url = g_strconcat ("file://", path, NULL);

  g_assert_true (g_file_set_contents (path, "{}", -1, NULL));
  lk_fetcher_http_get (fetcher, 1, url, 1);

  spin (200);

  g_assert_cmpuint (answers, ==, 1);
  lk_fetcher_free (fetcher);
  g_remove (path);
}

/* Every picture the app ships decodes out of the binary.
 *
 * A missing one draws a grey box in front of a mariner on the first screen
 * they ever see, so it fails a test instead. */
static void
test_shipped_pictures (void)
{
  guint n = 0;
  const LkChartCatalogEntry *entries = lk_chart_catalog_entries (&n);
  GdkTexture *hero = lk_chart_welcome_picture ();

  g_assert_nonnull (hero);
  g_assert_cmpint (gdk_texture_get_width (hero), >, 600);
  g_assert_cmpint (gdk_texture_get_height (hero), >, 200);

  g_assert_cmpuint (n, >, 0);
  for (guint i = 0; i < n; i++)
    {
      GdkTexture *art;

      g_assert_nonnull (entries[i].name);
      g_assert_nonnull (entries[i].url);
      g_assert_true (g_str_has_prefix (entries[i].url, "https://"));
      g_assert_nonnull (entries[i].art);

      art = lk_chart_catalog_art (entries[i].url);
      g_assert_nonnull (art);
      g_assert_cmpint (gdk_texture_get_width (art), >, 400);
      g_assert_cmpint (gdk_texture_get_height (art), >, 300);

      /* Decoded once and kept: a shelf redraws whenever the list moves. */
      g_assert_true (lk_chart_catalog_art (entries[i].url) == art);

      /* By url, and by the entry's own url. */
      g_assert_true (lk_chart_catalog_entry (entries[i].url) == &entries[i]);
    }

  /* A link the mariner added has no shipped picture, and NULL has none. */
  g_assert_null (lk_chart_catalog_entry ("https://example.org/style.json"));
  g_assert_null (lk_chart_catalog_art ("https://example.org/style.json"));
  g_assert_null (lk_chart_catalog_entry (NULL));
  g_assert_null (lk_chart_catalog_art (NULL));
}

/* With no chart open the core has no picture, so a list shows the ones the
 * app ships: the welcome picture for Lookout's own chart, and each catalog
 * entry's art. A link with no shipped art has no picture. */
static void
test_no_chart_shows_the_shipped_pictures (void)
{
  g_autoptr (LkChartController) controller = lk_chart_controller_new ();
  g_autoptr (LkChartPreviews) previews = lk_chart_previews_new (controller);
  guint n = 0;
  const LkChartCatalogEntry *entries = lk_chart_catalog_entries (&n);
  const char *const urls[] = { "", entries[0].url, "https://example.org/style.json", NULL };

  lk_chart_previews_want (previews, urls, 250, 132);

  g_assert_true (lk_chart_previews_get (previews, "") == lk_chart_welcome_picture ());
  g_assert_true (lk_chart_previews_get (previews, NULL) == lk_chart_welcome_picture ());
  g_assert_true (lk_chart_previews_get (previews, entries[0].url) ==
                 lk_chart_catalog_art (entries[0].url));
  g_assert_null (lk_chart_previews_get (previews, "https://example.org/style.json"));
}

int
main (int argc, char *argv[])
{
  g_autofree char *cache = g_dir_make_tmp ("lk-preview-test-XXXXXX", NULL);

  g_assert_nonnull (cache);
  g_setenv ("XDG_CACHE_HOME", cache, TRUE);

  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/preview/a-freed-fetcher-leaves-its-completions-safe",
                   test_a_freed_fetcher_leaves_its_completions_safe);
  g_test_add_func ("/preview/a-live-fetcher-answers", test_a_live_fetcher_answers);
  g_test_add_func ("/preview/a-file-read-is-one-piece", test_a_file_read_is_one_piece);
  g_test_add_func ("/preview/a-refused-read-fails-in-one-piece",
                   test_a_refused_read_fails_in_one_piece);
  g_test_add_func ("/preview/shipped-pictures", test_shipped_pictures);
  g_test_add_func ("/preview/no-chart-shows-the-shipped-pictures",
                   test_no_chart_shows_the_shipped_pictures);

  return g_test_run ();
}
