/* library/links.c — charts by link. See library/links.h. */
#include "library/links.h"

#include "model/store.h"

#include <json-glib/json-glib.h>
#include <libsoup/soup.h>
#include <string.h>

/* A unique, identifiable agent with a way to reach the developer: public tile
 * hosts (openstreetmap.org's tile usage policy, osm.wiki/Blocked_tiles) serve
 * "access blocked" placeholder tiles to anonymous or platform-default agents. */
#define LK_LINKS_USER_AGENT \
  "LookoutMarine/1.0 (Linux; org.beetlebug.lookout; contact jeremy.collins@beetlebug.org)"
#define LK_LINKS_REFERER "https://beetlebug.org/"

static void
lk_chart_link_free (gpointer data)
{
  LkChartLink *link = data;

  if (link == NULL)
    return;
  g_free (link->url);
  g_free (link->name);
  g_free (link);
}

struct _LkChartLinks {
  GObject parent_instance;

  LkChartController *controller; /* strong: a late fetch must find it alive */

  /* The fetcher. One session for everything lookout asks for — style,
   * TileJSON, sprite packs, tiles — so soup's per-host pooling applies to the
   * lot and no source can hold a lane another source's tiles are waiting on. */
  SoupSession *session;
  GHashTable  *in_flight; /* request id → GCancellable */
  gboolean     live;
  /* The shell's old store has been handed over (it is cleared with it, so
   * this only guards the same run). */
  gboolean imported;

  /* The snapshot, as lookout last reported it. */
  GPtrArray *links;  /* LkChartLink* */
  char      *active; /* url, or NULL for lookout's own chart */
  char      *attribution;
  char      *error;
  gboolean   busy;
};

enum {
  SIGNAL_CHANGED,
  N_SIGNALS
};

static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE (LkChartLinks, lk_chart_links, G_TYPE_OBJECT)

/* ---- the fetcher --------------------------------------------------------- */

typedef struct {
  LkChartLinks *self; /* strong */
  SoupMessage  *msg;  /* to read the status in the completion; NULL for a file */
  guint64       id;
} LkFetch;

static void
lk_fetch_free (LkFetch *fetch)
{
  g_clear_object (&fetch->msg);
  g_clear_object (&fetch->self);
  g_free (fetch);
}

/* Every answer funnels through here. `status` is the final HTTP status, or 0
 * for a transport failure; only 2xx carries a body lookout reads. */
static void
lk_links_answer (LkChartLinks *self, guint64 id, GBytes *bytes, guint status)
{
  gsize       length = 0;
  const void *data = bytes != NULL ? g_bytes_get_data (bytes, &length) : NULL;

  g_hash_table_remove (self->in_flight, &id);
  /* Shutdown drops the controller while a fetch may still be alive. A late
     answer then has nowhere to go, and lookout already released the slot. */
  if (self->controller != NULL)
    lk_chart_controller_http_respond (self->controller, id, data, length, (int) status);
}

static void
lk_links_fetch_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkFetch *fetch = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GBytes) bytes =
      soup_session_send_and_read_finish (SOUP_SESSION (source_object), result, &error);

  if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    {
      /* lookout gave up on this one and has already released its slot. */
      g_hash_table_remove (fetch->self->in_flight, &fetch->id);
    }
  else
    {
      guint status = soup_message_get_status (fetch->msg);
      if (error != NULL)
        status = 0;
      lk_links_answer (fetch->self, fetch->id, bytes, status);
    }
  lk_fetch_free (fetch);
}

static void
lk_links_read_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkFetch *fetch = user_data;
  g_autoptr (GError) error = NULL;
  char  *text = NULL;
  gsize  length = 0;

  if (!g_file_load_contents_finish (G_FILE (source_object), result, &text, &length, NULL, &error))
    {
      if (g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
        /* As in lk_links_fetch_done: a reopen cancelled this, and the id
         * would land on the NEW handle's request of the same number. */
        g_hash_table_remove (fetch->self->in_flight, &fetch->id);
      else
        lk_links_answer (fetch->self, fetch->id, NULL, 0);
    }
  else
    {
      g_autoptr (GBytes) bytes = g_bytes_new_take (text, length);
      lk_links_answer (fetch->self, fetch->id, bytes, 200);
    }
  lk_fetch_free (fetch);
}

/* The path a local url names, or NULL when it names a host. A mariner's own
 * style.json is a real way to install a chart — offline, or one they wrote
 * themselves. */
static const char *
lk_links_local_path (const char *url)
{
  if (g_str_has_prefix (url, "file://"))
    return url + strlen ("file://");
  if (url[0] == '/')
    return url;
  return NULL;
}

/* One url lookout wants. Fired on the render tick — the main thread here —
 * with lookout's lock held. Start the fetch and return; nothing blocks, and no
 * lookout call is made but http_respond. Every ask is ANSWERED, because an id
 * that is neither answered nor cancelled holds one of lookout's
 * outstanding-request slots. */
static void
lk_links_http_get (void *user, uint64_t req_id, const char *url, int allow_file)
{
  LkChartLinks *self = user;

  if (!self->live || url == NULL)
    {
      lk_chart_controller_http_respond (self->controller, req_id, NULL, 0, 0);
      return;
    }

  LkFetch *fetch = g_new0 (LkFetch, 1);
  fetch->self = g_object_ref (self);
  fetch->id = req_id;

  guint64      *key = g_new (guint64, 1);
  GCancellable *cancel = g_cancellable_new ();
  *key = req_id;
  g_hash_table_insert (self->in_flight, key, cancel);

  const char *path = lk_links_local_path (url);
  if (path != NULL)
    {
      /* The file:// boundary. lookout says when a url may be read off disk
       * (see lookout_http_get): the link the mariner typed, and what a
       * document already read from disk names inside that link's directory. A
       * style that arrived over the network never gets it, so it cannot make
       * this read arbitrary local files as its "TileJSON". */
      if (!allow_file)
        {
          lk_links_answer (self, req_id, NULL, 0);
          lk_fetch_free (fetch);
          return;
        }
      g_autoptr (GFile) file = g_file_new_for_path (path);
      g_file_load_contents_async (file, cancel, lk_links_read_done, fetch);
      return;
    }

  SoupMessage *msg = soup_message_new (SOUP_METHOD_GET, url);
  if (msg == NULL)
    {
      lk_links_answer (self, req_id, NULL, 0);
      lk_fetch_free (fetch);
      return;
    }
  soup_message_headers_append (soup_message_get_request_headers (msg),
                               "Referer", LK_LINKS_REFERER);
  fetch->msg = msg;
  soup_session_send_and_read_async (self->session, msg, G_PRIORITY_DEFAULT, cancel,
                                    lk_links_fetch_done, fetch);
}

/* lookout no longer wants an answer: a newer resolve superseded it, or the
 * tile left the wanted set. Advisory — aborting the transfer saves bandwidth,
 * which at sea matters. Same calling rules as the get above. */
static void
lk_links_http_cancel (void *user, uint64_t req_id)
{
  LkChartLinks *self = user;
  GCancellable *cancel = g_hash_table_lookup (self->in_flight, &req_id);

  if (cancel != NULL)
    g_cancellable_cancel (cancel);
}

static void
lk_links_cancel_all (LkChartLinks *self)
{
  GHashTableIter iter;
  gpointer       key, value;

  g_hash_table_iter_init (&iter, self->in_flight);
  while (g_hash_table_iter_next (&iter, &key, &value))
    g_cancellable_cancel (value);
  g_hash_table_remove_all (self->in_flight);
}

/* ---- the read ------------------------------------------------------------ */

static void
lk_links_adopt (LkChartLinks *self, const lookout_links *read)
{
  const lookout_link_state *state = lookout_links_state (read);
  size_t count = 0;
  const lookout_chart_link *const *all = lookout_links_all (read, &count);

  g_ptr_array_set_size (self->links, 0);
  for (size_t i = 0; i < count; i++)
    {
      LkChartLink *link = g_new0 (LkChartLink, 1);

      link->url = g_strdup (all[i]->url);
      link->name = g_strdup (all[i]->name[0] != '\0' ? all[i]->name : all[i]->url);
      g_ptr_array_add (self->links, link);
    }

  /* An EMPTY active url is lookout's own chart, and a url is never empty. */
  g_clear_pointer (&self->active, g_free);
  if (state->active[0] != '\0')
    self->active = g_strdup (state->active);

  g_free (self->attribution);
  self->attribution = g_strdup (state->attribution);
  g_free (self->error);
  self->error = g_strdup (state->error);
  self->busy = state->busy != 0;

  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

void
lk_chart_links_poll (LkChartLinks *self)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));

  lookout_links *read = lk_chart_controller_chart_links_read (self->controller);

  if (read == NULL)
    return;
  lk_links_adopt (self, read);
  lookout_links_free (read);
}

/* ---- migration ----------------------------------------------------------- */

/* Hand the shell's old keyfile list to lookout, once, and then drop it.
 *
 * lookout ignores the import when it already has a list of its own, so the
 * window between handing it over and clearing the keys replays harmlessly if
 * the app dies in it. */
static void
lk_links_migrate (LkChartLinks *self)
{
  if (self->imported)
    return;
  self->imported = TRUE;

  g_autofree char *links = lk_store_load_chart_links ();
  if (links == NULL || links[0] == '\0')
    return;

  g_autoptr (JsonParser) parser = json_parser_new ();
  if (!json_parser_load_from_data (parser, links, -1, NULL))
    {
      lk_store_save_chart_links (NULL);
      lk_store_save_chart_link_active (NULL);
      return;
    }

  g_autofree char *active = lk_store_load_chart_link_active ();
  g_autoptr (JsonBuilder) builder = json_builder_new ();
  json_builder_begin_object (builder);
  json_builder_set_member_name (builder, "links");
  json_builder_add_value (builder, json_node_copy (json_parser_get_root (parser)));
  if (active != NULL && active[0] != '\0')
    {
      json_builder_set_member_name (builder, "active");
      json_builder_add_string_value (builder, active);
    }
  json_builder_end_object (builder);

  g_autoptr (JsonGenerator) generator = json_generator_new ();
  g_autoptr (JsonNode) root = json_builder_get_root (builder);
  json_generator_set_root (generator, root);
  g_autofree char *doc = json_generator_to_data (generator, NULL);

  g_message ("chart links: handing the old store to the core");
  lk_chart_controller_chart_links_import (self->controller, doc);
  lk_store_save_chart_links (NULL);
  lk_store_save_chart_link_active (NULL);
}

/* ---- the surface --------------------------------------------------------- */

GPtrArray *
lk_chart_links_list (LkChartLinks *self)
{
  g_return_val_if_fail (LK_IS_CHART_LINKS (self), NULL);
  return self->links;
}

const char *
lk_chart_links_active (LkChartLinks *self)
{
  g_return_val_if_fail (LK_IS_CHART_LINKS (self), NULL);
  return self->active;
}

const char *
lk_chart_links_attribution (LkChartLinks *self)
{
  g_return_val_if_fail (LK_IS_CHART_LINKS (self), "");
  return self->attribution;
}

const char *
lk_chart_links_error (LkChartLinks *self)
{
  g_return_val_if_fail (LK_IS_CHART_LINKS (self), "");
  return self->error;
}

gboolean
lk_chart_links_busy (LkChartLinks *self)
{
  g_return_val_if_fail (LK_IS_CHART_LINKS (self), FALSE);
  return self->busy;
}

void
lk_chart_links_add (LkChartLinks *self, const char *link)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));
  if (link == NULL)
    return;

  g_autofree char *trimmed = g_strdup (link);
  g_strstrip (trimmed);
  if (trimmed[0] == '\0')
    return;
  lk_chart_controller_chart_link_add (self->controller, trimmed);
  lk_chart_links_poll (self);
}

void
lk_chart_links_remove (LkChartLinks *self, const char *url)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));
  lk_chart_controller_chart_link_remove (self->controller, url);
  lk_chart_links_poll (self);
}

void
lk_chart_links_refresh (LkChartLinks *self, const char *url)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));
  lk_chart_controller_chart_link_refresh (self->controller, url);
  lk_chart_links_poll (self);
}

void
lk_chart_links_select (LkChartLinks *self, const char *url)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));

  /* Selecting the link that is already drawn is a no-op: the settings row
   * fires on every click, and re-selecting would re-resolve the style and
   * every sprite pack for nothing. A selection whose last resolve failed does
   * retry. */
  if (url != NULL && self->active != NULL && g_str_equal (url, self->active) &&
      self->error[0] == '\0')
    return;
  lk_chart_controller_chart_link_select (self->controller, url);
  lk_chart_links_poll (self);
}

void
lk_chart_links_reapply (LkChartLinks *self)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));

  /* A new handle numbers its requests from the start, so the old handle's
   * outstanding ids must go before this one can hand any out. */
  lk_links_cancel_all (self);
  self->live = TRUE;
  lk_chart_controller_set_http_provider (self->controller, lk_links_http_get,
                                         lk_links_http_cancel, self);
  /* AFTER the fetcher: lookout resolves the imported selection as soon as it
   * has somewhere to fetch from. */
  lk_links_migrate (self);
  lk_chart_links_poll (self);
}

/* ---- GObject ------------------------------------------------------------- */

/* Break the fetch → links → controller reference chain. An in-flight fetch
   holds a strong reference to this object, and this object holds one to the
   controller. At quit there is no main loop left to drain the fetch, so the
   controller would never finalise and lookout_close and the final pose save
   would not run. Cancel the fetches, detach the provider, and drop the
   controller reference now, so the model's own reference is the last one. Safe
   to call more than once; dispose calls it too. */
void
lk_chart_links_shutdown (LkChartLinks *self)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));

  self->live = FALSE;
  if (self->in_flight != NULL)
    lk_links_cancel_all (self);
  if (self->session != NULL)
    soup_session_abort (self->session);
  g_clear_object (&self->session);
  if (self->controller != NULL)
    {
      lk_chart_controller_set_http_provider (self->controller, NULL, NULL, NULL);
      g_clear_object (&self->controller);
    }
}

static void
lk_chart_links_dispose (GObject *object)
{
  LkChartLinks *self = LK_CHART_LINKS (object);

  lk_chart_links_shutdown (self);
  g_clear_pointer (&self->in_flight, g_hash_table_unref);
  g_clear_pointer (&self->links, g_ptr_array_unref);
  g_clear_pointer (&self->active, g_free);
  g_clear_pointer (&self->attribution, g_free);
  g_clear_pointer (&self->error, g_free);

  G_OBJECT_CLASS (lk_chart_links_parent_class)->dispose (object);
}

static void
lk_chart_links_class_init (LkChartLinksClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->dispose = lk_chart_links_dispose;

  /* The list, the pick, the credit or the error moved. One signal: the
   * settings section and the HUD credit are each rebuilt as a whole. */
  signals[SIGNAL_CHANGED] =
      g_signal_new ("changed", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

static guint
lk_links_id_hash (gconstpointer key)
{
  const guint64 *id = key;
  return (guint) (*id ^ (*id >> 32));
}

static gboolean
lk_links_id_equal (gconstpointer a, gconstpointer b)
{
  return *(const guint64 *) a == *(const guint64 *) b;
}

static void
lk_chart_links_init (LkChartLinks *self)
{
  self->links = g_ptr_array_new_with_free_func (lk_chart_link_free);
  self->attribution = g_strdup ("");
  self->error = g_strdup ("");
  self->in_flight = g_hash_table_new_full (lk_links_id_hash, lk_links_id_equal,
                                           g_free, g_object_unref);
  /* A stalled fetch must not hold a slot forever: the chart is drawn from
   * whatever HAS landed, so a slow tile costs only itself, and a style that
   * asks a base map past the zoom it actually serves fails fast instead of
   * holding a worker. soup pools per host, and nothing here reasons about
   * which source a url belongs to, so no source can hold a lane another
   * source's tiles are waiting on. */
  self->session = soup_session_new_with_options ("user-agent", LK_LINKS_USER_AGENT,
                                                 "timeout", 8,
                                                 "idle-timeout", 10,
                                                 "max-conns", 16,
                                                 "max-conns-per-host", 8,
                                                 NULL);
}

LkChartLinks *
lk_chart_links_new (LkChartController *controller)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (controller), NULL);

  LkChartLinks *self = g_object_new (LK_TYPE_CHART_LINKS, NULL);
  self->controller = g_object_ref (controller);
  return self;
}
