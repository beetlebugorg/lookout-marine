/* test-preview.c — where a chart's picture is kept.
 *
 * Every chart on a list is pictured at the same point, the one the mariner is
 * looking at, so what differs between the cards is the portrayal. The cache
 * key is what decides when a picture still applies: a mariner working one
 * harbour must keep the pictures they have, and one who has sailed to the next
 * bay must not be shown the water they left.
 *
 * No display, and no network: the key and the tile arithmetic are pure.
 */

#include <glib/gstdio.h>

#include "library/fetch.h"
#include "library/preview-engine.h"
#include "library/preview.h"

/* The tile a point falls in, as every tile server counts them. */
static void
test_tile_numbers (void)
{
  int x = -1, y = -1;

  /* Zoom 0 is one tile, and everything is in it. */
  lk_chart_preview_tile (-76.48, 38.97, 0, &x, &y);
  g_assert_cmpint (x, ==, 0);
  g_assert_cmpint (y, ==, 0);

  /* Null Island at zoom 1 is the south-east of the four. */
  lk_chart_preview_tile (0.0001, -0.0001, 1, &x, &y);
  g_assert_cmpint (x, ==, 1);
  g_assert_cmpint (y, ==, 1);

  /* Annapolis at the zoom a preview is fetched at. Checked against the
   * standard slippy numbers for z9. */
  lk_chart_preview_tile (-76.48, 38.97, 9, &x, &y);
  g_assert_cmpint (x, ==, 147);
  g_assert_cmpint (y, ==, 195);

  /* The poles are clamped, so a tile number is always on the grid. */
  lk_chart_preview_tile (0, 90, 9, &x, &y);
  g_assert_cmpint (y, >=, 0);
  g_assert_cmpint (y, <, 512);
  lk_chart_preview_tile (0, -90, 9, &x, &y);
  g_assert_cmpint (y, >=, 0);
  g_assert_cmpint (y, <, 512);
}

/* One picture per chart per tile of water. */
static void
test_cache_key (void)
{
  const char *seascape = "https://tiles.openwaters.io/seascape/style.json";
  const char *seamap = "https://tiles.openwaters.io/seamap/style.json";

  g_autofree char *a = lk_chart_preview_cache_path (seascape, -76.48, 38.97,
                                                    LK_PREVIEW_ZOOM);
  /* The same chart, a mile up the Severn: the same preview tile, so the
   * picture a mariner already has still applies. */
  g_autofree char *near = lk_chart_preview_cache_path (seascape, -76.46, 38.99,
                                                       LK_PREVIEW_ZOOM);
  /* The same chart on the other side of the country: a different picture. */
  g_autofree char *far = lk_chart_preview_cache_path (seascape, -122.40, 37.80,
                                                      LK_PREVIEW_ZOOM);
  /* A different chart at the same water: a different picture. That is the
   * whole point of the shelf. */
  g_autofree char *other = lk_chart_preview_cache_path (seamap, -76.48, 38.97,
                                                        LK_PREVIEW_ZOOM);
  /* Lookout's own chart has no url. */
  g_autofree char *own = lk_chart_preview_cache_path (NULL, -76.48, 38.97,
                                                      LK_PREVIEW_ZOOM);

  g_assert_cmpstr (a, ==, near);
  g_assert_cmpstr (a, !=, far);
  g_assert_cmpstr (a, !=, other);
  g_assert_cmpstr (a, !=, own);

  /* Under the cache, with a name and nothing of the url in it: a style link
   * holds a publisher, a path and often a key, and none of that belongs in a
   * file name. */
  g_assert_true (g_str_has_prefix (a, g_get_user_cache_dir ()));
  g_assert_true (strstr (a, "lookout-marine") != NULL);
  g_assert_true (g_str_has_suffix (a, ".png"));
  g_assert_null (strstr (a, "openwaters"));
  g_assert_null (strstr (a, "/style.json"));

  /* The same ask twice is the same answer. */
  g_autofree char *again = lk_chart_preview_cache_path (seascape, -76.48, 38.97,
                                                        LK_PREVIEW_ZOOM);
  g_assert_cmpstr (a, ==, again);
}

/* The zoom a preview is taken at is part of the key: a picture taken for one
 * list must not be handed to a list that asks at another scale. */
static void
test_zoom_in_the_key (void)
{
  const char *url = "https://example.org/style.json";
  g_autofree char *nine = lk_chart_preview_cache_path (url, -76.48, 38.97, 9);
  g_autofree char *ten = lk_chart_preview_cache_path (url, -76.48, 38.97, 10);

  g_assert_cmpstr (nine, !=, ten);
}

/* When a render off to one side is finished.
 *
 * The frame loop reports idle before the style has even been asked for, so a
 * render that stopped at the first idle tick would hand back an empty style.
 * Four quiet ticks after a warm-up is the end, and a style behind a dead host
 * ends when the patience runs out.
 */
static void
test_settle_warms_up (void)
{
  LkPreviewSettle state = { 0 };

  /* Idle from the very first tick, which is what the loop reports before the
   * style has been asked for. The warm-up has to outlast it. */
  for (int i = 0; i < 9; i++)
    g_assert_false (lk_preview_settle_step (&state, TRUE, FALSE, TRUE));

  /* Now the quiet ticks count, and four of them end it. */
  g_assert_false (lk_preview_settle_step (&state, TRUE, FALSE, TRUE));
  g_assert_false (lk_preview_settle_step (&state, TRUE, FALSE, TRUE));
  g_assert_false (lk_preview_settle_step (&state, TRUE, FALSE, TRUE));
  g_assert_true (lk_preview_settle_step (&state, TRUE, FALSE, TRUE));
  g_assert_true (state.drawn);
}

/* A tile landing resets the count: the frame that follows it is a new chart. */
static void
test_settle_resets_on_work (void)
{
  LkPreviewSettle state = { 0 };

  for (int i = 0; i < 12; i++)
    lk_preview_settle_step (&state, TRUE, FALSE, TRUE);
  /* Three quiet ticks in, and then the engine has work again. */
  state = (LkPreviewSettle) { .ticks = 12, .settled = 3, .drawn = TRUE };
  g_assert_false (lk_preview_settle_step (&state, FALSE, TRUE, TRUE));
  g_assert_cmpint (state.settled, ==, 0);

  /* And four quiet ticks from there. */
  g_assert_false (lk_preview_settle_step (&state, TRUE, FALSE, TRUE));
  g_assert_false (lk_preview_settle_step (&state, TRUE, FALSE, TRUE));
  g_assert_false (lk_preview_settle_step (&state, TRUE, FALSE, TRUE));
  g_assert_true (lk_preview_settle_step (&state, TRUE, FALSE, TRUE));
}

/* A style that never settles ends anyway. A publisher behind a dead host must
 * not hold the engine for the life of the app. */
static void
test_settle_runs_out_of_patience (void)
{
  LkPreviewSettle state = { 0 };
  int ticks = 0;

  while (!lk_preview_settle_step (&state, FALSE, TRUE, FALSE))
    {
      ticks++;
      g_assert_cmpint (ticks, <, 500); /* it has to end */
    }
  g_assert_cmpint (state.ticks, ==, 70);
  /* Nothing was ever drawn, so the caller has no picture to keep. */
  g_assert_false (state.drawn);
}

/* A fetcher freed with a fetch in flight answers nobody and frees nothing
 * twice.
 *
 * Each completion runs on a later turn of the main loop, and a cancelled one
 * still runs. It used to read the fetcher's table and session after the free,
 * which is where a gallery row that went while a style resolved crashed. */
static void
answered (gpointer user_data, uint64_t req_id, const void *bytes, gsize len, int status)
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
static gboolean chunk_done;

static void
chunked (gpointer user_data, uint64_t req_id, const void *bytes, gsize len, int status,
         gboolean done)
{
  chunk_pieces++;
  chunk_bytes += len;
  if (done)
    chunk_done = TRUE;
}

/* A body delivered in pieces arrives in order and ends with done.
 *
 * A district bundle runs to a couple of hundred megabytes, and the whole-body
 * read needs that much again for the copy the core makes. A file:// read
 * stays whole, so this states what the owner is handed rather than how the
 * pieces are cut.
 */
static void
test_a_chunked_fetch_ends_with_done (void)
{
  guint answers = 0;
  LkFetcher *fetcher = lk_fetcher_new (answered, &answers);
  g_autofree char *path = g_build_filename (g_get_tmp_dir (), "lk-fetch-chunk.json", NULL);
  g_autofree char *url = g_strconcat ("file://", path, NULL);

  lk_fetcher_set_chunk_respond (fetcher, chunked);
  g_assert_true (g_file_set_contents (path, "{\"a\":1}", -1, NULL));

  chunk_pieces = 0;
  chunk_bytes = 0;
  chunk_done = FALSE;
  lk_fetcher_http_get (fetcher, 7, url, 1);
  spin (200);

  /* A local read answers whole, through the plain responder. */
  g_assert_cmpuint (answers, ==, 1);
  g_assert_cmpuint (chunk_pieces, ==, 0);

  lk_fetcher_free (fetcher);
  g_remove (path);
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
  g_test_add_func ("/preview/a-chunked-fetch-ends-with-done",
                   test_a_chunked_fetch_ends_with_done);
  g_test_add_func ("/preview/tile-numbers", test_tile_numbers);
  g_test_add_func ("/preview/cache-key", test_cache_key);
  g_test_add_func ("/preview/zoom-in-the-key", test_zoom_in_the_key);
  g_test_add_func ("/preview/settle-warms-up", test_settle_warms_up);
  g_test_add_func ("/preview/settle-resets-on-work", test_settle_resets_on_work);
  g_test_add_func ("/preview/settle-runs-out-of-patience", test_settle_runs_out_of_patience);

  return g_test_run ();
}
