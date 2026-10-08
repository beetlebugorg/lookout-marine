/* library/fetch.c: see library/fetch.h. */
#include "library/fetch.h"

#include "library/agent.h"

#include <libsoup/soup.h>
#include <string.h>

struct _LkFetcher {
  /* One session for everything lookout asks for, style, TileJSON, sprite
   * packs, tiles, so soup's per-host pooling applies to the lot and no source
   * can hold a lane another source's tiles are waiting on. */
  SoupSession *session;
  /* request id -> LkFetch, borrowed. Each fetch is freed by its own
   * completion, so the table owns the key alone. */
  GHashTable  *in_flight;
  gboolean     live;
  /* TRUE once the owner has let go. A fetch cancelled then still has its
   * completion to run, and the session and the table are gone by the time it
   * does. */
  gboolean     dead;
  gint         refs;

  LkFetcherRespond respond;
  gpointer         respond_data;
};

/* One read of a streamed body. Large enough that a 200 MB bundle is a few
 * hundred reads, small enough that no piece is a burden on a phone. */
#define LK_FETCH_PIECE (256 * 1024)

typedef struct {
  LkFetcher    *fetcher; /* reffed: the completion runs after the owner lets go */
  SoupMessage  *msg; /* to read the status in the completion; NULL for a file */
  GCancellable *cancel;
  uint64_t      id;
  /* The body, read piece by piece. It never sits whole in memory. */
  GInputStream *stream;
  guint         status;
} LkFetch;

static void lk_fetcher_unref (LkFetcher *self);

static void
lk_fetch_free (LkFetch *fetch)
{
  g_clear_object (&fetch->msg);
  g_clear_object (&fetch->cancel);
  g_clear_object (&fetch->stream);
  lk_fetcher_unref (fetch->fetcher);
  g_free (fetch);
}

/* Take this fetch off the list, and only this one.
 *
 * A cancelled fetch's completion runs on a later turn of the main loop, and a
 * new handle issues ids from 1 again. Removing by id alone took the new
 * handle's request of the same number off the list, and the cancel that
 * followed found nothing to cancel. */
static void
lk_fetcher_forget (LkFetch *fetch)
{
  LkFetcher *self = fetch->fetcher;

  if (self->in_flight == NULL)
    return;
  if (g_hash_table_lookup (self->in_flight, &fetch->id) == fetch)
    g_hash_table_remove (self->in_flight, &fetch->id);
}

static void lk_fetcher_read_piece (LkFetch *fetch);

/* Hand one piece to the owner. The last piece carries `done`, and a request
 * that failed reports its status with no bytes. A dead fetcher hands over
 * none: the handle that made the request has gone. */
static void
lk_fetch_piece (LkFetch *fetch, GBytes *bytes, gboolean done)
{
  LkFetcher  *self = fetch->fetcher;
  gsize       len = 0;
  const void *data = bytes != NULL ? g_bytes_get_data (bytes, &len) : NULL;

  if (self->dead || self->respond == NULL)
    return;
  /* A piece queued before the cancel goes. A reopen cancels every fetch and
   * issues ids from 1 again, so this piece reaches the new handle's request
   * of the same number. */
  if (g_cancellable_is_cancelled (fetch->cancel))
    return;
  if (done)
    lk_fetcher_forget (fetch);
  self->respond (self->respond_data, fetch->id, data, len, (int) fetch->status, done);
}

static void
lk_fetcher_piece_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkFetch *fetch = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GBytes) bytes =
      g_input_stream_read_bytes_finish (G_INPUT_STREAM (source_object), result, &error);

  if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    {
      if (!fetch->fetcher->dead)
        lk_fetcher_forget (fetch);
      lk_fetch_free (fetch);
      return;
    }
  if (error != NULL)
    {
      /* A body that stopped part way. The core is told the request is over,
       * and a transfer short of its length is a failure to it. */
      fetch->status = 0;
      lk_fetch_piece (fetch, NULL, TRUE);
      lk_fetch_free (fetch);
      return;
    }

  /* A read of nothing is the end of the body. */
  if (bytes == NULL || g_bytes_get_size (bytes) == 0)
    {
      lk_fetch_piece (fetch, NULL, TRUE);
      lk_fetch_free (fetch);
      return;
    }

  lk_fetch_piece (fetch, bytes, FALSE);
  if (fetch->fetcher->dead)
    {
      lk_fetch_free (fetch);
      return;
    }
  lk_fetcher_read_piece (fetch);
}

static void
lk_fetcher_read_piece (LkFetch *fetch)
{
  g_input_stream_read_bytes_async (fetch->stream, LK_FETCH_PIECE, G_PRIORITY_DEFAULT,
                                   fetch->cancel, lk_fetcher_piece_done, fetch);
}

static void
lk_fetcher_send_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkFetch *fetch = user_data;
  g_autoptr (GError) error = NULL;
  GInputStream *stream =
      soup_session_send_finish (SOUP_SESSION (source_object), result, &error);

  if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    {
      g_clear_object (&stream);
      if (!fetch->fetcher->dead)
        lk_fetcher_forget (fetch);
      lk_fetch_free (fetch);
      return;
    }

  fetch->status = fetch->fetcher->dead ? 0 : soup_message_get_status (fetch->msg);
  if (error != NULL || stream == NULL)
    {
      fetch->status = 0;
      lk_fetch_piece (fetch, NULL, TRUE);
      lk_fetch_free (fetch);
      return;
    }

  fetch->stream = stream;
  lk_fetcher_read_piece (fetch);
}

static void
lk_fetcher_read_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkFetch *fetch = user_data;
  g_autoptr (GError) error = NULL;
  char  *text = NULL;
  gsize  length = 0;

  if (!g_file_load_contents_finish (G_FILE (source_object), result, &text, &length, NULL,
                                    &error))
    {
      if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        {
          /* A reopen cancelled this. The id now belongs to the new
           * handle's request of the same number. */
          if (!fetch->fetcher->dead)
            lk_fetcher_forget (fetch);
        }
      else
        lk_fetch_piece (fetch, NULL, TRUE);
    }
  else
    {
      g_autoptr (GBytes) bytes = g_bytes_new_take (text, length);

      /* A local file is a style the mariner wrote. It goes over in one piece. */
      fetch->status = 200;
      lk_fetch_piece (fetch, bytes, TRUE);
    }
  lk_fetch_free (fetch);
}

/* The path a local url names, or NULL when it names a host. A mariner's own
 * style.json is a real way to install a chart, offline, or one they wrote
 * themselves. */
static const char *
lk_fetcher_local_path (const char *url)
{
  if (g_str_has_prefix (url, "file://"))
    return url + strlen ("file://");
  if (url[0] == '/')
    return url;
  return NULL;
}

void
lk_fetcher_http_get (void *user, uint64_t req_id, const char *url, int allow_file)
{
  LkFetcher *self = user;
  LkFetch *fetch;
  uint64_t *key;
  GCancellable *cancel;
  const char *path;
  SoupMessage *msg;

  if (self == NULL || !self->live || url == NULL)
    {
      if (self != NULL && self->respond != NULL)
        self->respond (self->respond_data, req_id, NULL, 0, 0, TRUE);
      return;
    }

  fetch = g_new0 (LkFetch, 1);
  fetch->fetcher = self;
  self->refs++;
  fetch->id = req_id;

  key = g_new (uint64_t, 1);
  cancel = g_cancellable_new ();
  fetch->cancel = cancel;
  *key = req_id;
  g_hash_table_insert (self->in_flight, key, fetch);

  path = lk_fetcher_local_path (url);
  if (path != NULL)
    {
      /* The file:// boundary. lookout says when a url may be read off disk
       * (see lookout_http_get): the link the mariner typed, and what a
       * document already read from disk names inside that link's directory. A
       * style that arrived over the network never gets it, so it cannot make
       * this read arbitrary local files as its "TileJSON". */
      if (!allow_file)
        {
          lk_fetch_piece (fetch, NULL, TRUE);
          lk_fetch_free (fetch);
          return;
        }
      g_autoptr (GFile) file = g_file_new_for_path (path);
      g_file_load_contents_async (file, cancel, lk_fetcher_read_done, fetch);
      return;
    }

  msg = soup_message_new (SOUP_METHOD_GET, url);
  if (msg == NULL)
    {
      lk_fetch_piece (fetch, NULL, TRUE);
      lk_fetch_free (fetch);
      return;
    }
  soup_message_headers_append (soup_message_get_request_headers (msg),
                               "Referer", LK_REFERER);
  fetch->msg = msg;
  soup_session_send_async (self->session, msg, G_PRIORITY_DEFAULT, cancel,
                           lk_fetcher_send_done, fetch);
}

void
lk_fetcher_http_cancel (void *user, uint64_t req_id)
{
  LkFetcher *self = user;
  LkFetch   *fetch;

  if (self == NULL)
    return;
  fetch = g_hash_table_lookup (self->in_flight, &req_id);
  if (fetch != NULL)
    g_cancellable_cancel (fetch->cancel);
}

void
lk_fetcher_cancel_all (LkFetcher *self)
{
  GHashTableIter iter;
  gpointer       key, value;

  g_return_if_fail (self != NULL);

  g_hash_table_iter_init (&iter, self->in_flight);
  while (g_hash_table_iter_next (&iter, &key, &value))
    g_cancellable_cancel (((LkFetch *) value)->cancel);
  g_hash_table_remove_all (self->in_flight);
}

void
lk_fetcher_set_live (LkFetcher *self, gboolean live)
{
  g_return_if_fail (self != NULL);
  self->live = live;
}

LkFetcher *
lk_fetcher_new (LkFetcherRespond respond, gpointer user_data)
{
  LkFetcher *self = g_new0 (LkFetcher, 1);

  self->respond = respond;
  self->respond_data = user_data;
  /* The key alone is owned. Each fetch is freed by its own completion, which
   * can run after the table has let go of it. */
  self->in_flight = g_hash_table_new_full (g_int64_hash, g_int64_equal, g_free, NULL);
  self->refs = 1;
  /* A stalled fetch must not hold a slot forever: the chart is drawn from
   * whatever HAS landed, so a slow tile costs only itself, and a style that
   * asks a base map past the zoom it actually serves fails fast instead of
   * holding a worker. soup pools per host, and nothing here reasons about
   * which source a url belongs to, so no source can hold a lane another
   * source's tiles are waiting on. */
  self->session = soup_session_new_with_options ("user-agent", LK_USER_AGENT,
                                                 "timeout", 8,
                                                 "idle-timeout", 10,
                                                 "max-conns", 16,
                                                 "max-conns-per-host", 8,
                                                 NULL);
  self->live = TRUE;
  return self;
}

/* The last hold goes. A cancelled fetch keeps one until its completion runs,
 * so the struct outlives the owner by as long as the main loop takes to drain
 * them. */
static void
lk_fetcher_unref (LkFetcher *self)
{
  if (self == NULL || --self->refs > 0)
    return;

  g_clear_pointer (&self->in_flight, g_hash_table_unref);
  g_free (self);
}

void
lk_fetcher_free (LkFetcher *self)
{
  if (self == NULL)
    return;

  /* Mark it dead before the cancels, so a completion that runs inside
   * soup_session_abort answers nobody. */
  self->dead = TRUE;
  self->live = FALSE;
  self->respond = NULL;
  lk_fetcher_cancel_all (self);
  if (self->session != NULL)
    soup_session_abort (self->session);
  g_clear_object (&self->session);
  lk_fetcher_unref (self);
}
