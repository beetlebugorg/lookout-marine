/* library/fetch.c — see library/fetch.h. */
#include "library/fetch.h"

#include "library/agent.h"

#include <libsoup/soup.h>
#include <string.h>

struct _LkFetcher {
  /* One session for everything lookout asks for — style, TileJSON, sprite
   * packs, tiles — so soup's per-host pooling applies to the lot and no source
   * can hold a lane another source's tiles are waiting on. */
  SoupSession *session;
  GHashTable  *in_flight; /* request id -> GCancellable */
  gboolean     live;

  LkFetcherRespond respond;
  gpointer         respond_data;
};

typedef struct {
  LkFetcher   *fetcher;
  SoupMessage *msg; /* to read the status in the completion; NULL for a file */
  uint64_t     id;
} LkFetch;

static void
lk_fetch_free (LkFetch *fetch)
{
  g_clear_object (&fetch->msg);
  g_free (fetch);
}

/* Every answer funnels through here. `status` is the final HTTP status, or 0
 * for a transport failure; only 2xx carries a body lookout reads. */
static void
lk_fetcher_answer (LkFetcher *self, uint64_t id, GBytes *bytes, guint status)
{
  gsize       length = 0;
  const void *data = bytes != NULL ? g_bytes_get_data (bytes, &length) : NULL;

  g_hash_table_remove (self->in_flight, &id);
  if (self->respond != NULL)
    self->respond (self->respond_data, id, data, length, (int) status);
}

static void
lk_fetcher_fetch_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkFetch *fetch = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GBytes) bytes =
      soup_session_send_and_read_finish (SOUP_SESSION (source_object), result, &error);

  if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    {
      /* lookout gave up on this one and has already released its slot. */
      g_hash_table_remove (fetch->fetcher->in_flight, &fetch->id);
    }
  else
    {
      guint status = soup_message_get_status (fetch->msg);

      if (error != NULL)
        status = 0;
      lk_fetcher_answer (fetch->fetcher, fetch->id, bytes, status);
    }
  lk_fetch_free (fetch);
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
        /* As in lk_fetcher_fetch_done: a reopen cancelled this, and the id
         * would land on the NEW handle's request of the same number. */
        g_hash_table_remove (fetch->fetcher->in_flight, &fetch->id);
      else
        lk_fetcher_answer (fetch->fetcher, fetch->id, NULL, 0);
    }
  else
    {
      g_autoptr (GBytes) bytes = g_bytes_new_take (text, length);
      lk_fetcher_answer (fetch->fetcher, fetch->id, bytes, 200);
    }
  lk_fetch_free (fetch);
}

/* The path a local url names, or NULL when it names a host. A mariner's own
 * style.json is a real way to install a chart — offline, or one they wrote
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
        self->respond (self->respond_data, req_id, NULL, 0, 0);
      return;
    }

  fetch = g_new0 (LkFetch, 1);
  fetch->fetcher = self;
  fetch->id = req_id;

  key = g_new (uint64_t, 1);
  cancel = g_cancellable_new ();
  *key = req_id;
  g_hash_table_insert (self->in_flight, key, cancel);

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
          lk_fetcher_answer (self, req_id, NULL, 0);
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
      lk_fetcher_answer (self, req_id, NULL, 0);
      lk_fetch_free (fetch);
      return;
    }
  soup_message_headers_append (soup_message_get_request_headers (msg),
                               "Referer", LK_REFERER);
  fetch->msg = msg;
  soup_session_send_and_read_async (self->session, msg, G_PRIORITY_DEFAULT, cancel,
                                    lk_fetcher_fetch_done, fetch);
}

void
lk_fetcher_http_cancel (void *user, uint64_t req_id)
{
  LkFetcher *self = user;
  GCancellable *cancel;

  if (self == NULL)
    return;
  cancel = g_hash_table_lookup (self->in_flight, &req_id);
  if (cancel != NULL)
    g_cancellable_cancel (cancel);
}

void
lk_fetcher_cancel_all (LkFetcher *self)
{
  GHashTableIter iter;
  gpointer       key, value;

  g_return_if_fail (self != NULL);

  g_hash_table_iter_init (&iter, self->in_flight);
  while (g_hash_table_iter_next (&iter, &key, &value))
    g_cancellable_cancel (value);
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
  self->in_flight = g_hash_table_new_full (g_int64_hash, g_int64_equal, g_free,
                                           g_object_unref);
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

void
lk_fetcher_free (LkFetcher *self)
{
  if (self == NULL)
    return;

  self->live = FALSE;
  self->respond = NULL;
  lk_fetcher_cancel_all (self);
  if (self->session != NULL)
    soup_session_abort (self->session);
  g_clear_object (&self->session);
  g_clear_pointer (&self->in_flight, g_hash_table_unref);
  g_free (self);
}
