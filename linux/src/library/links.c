/* library/links.c — charts by link. See library/links.h. */
#include "library/links.h"

#include "library/fetch.h"
#include "model/store.h"

#include <json-glib/json-glib.h>
#include <string.h>


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

  /* The fetcher lookout drives for every url this chart needs. See
   * library/fetch.h. */
  LkFetcher *fetcher;
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

/* An answer on its way back to the handle that asked.
 *
 * Through the CONTROLLER, not the handle: a fetch may outlive the handle it
 * was started for, the controller refuses an answer with no handle behind it,
 * and an answer is adopted at the top of a frame, so one landing with no
 * gesture behind it needs someone to ask for that frame.
 *
 * Shutdown drops the controller while a fetch may still be alive. A late
 * answer then has nowhere to go, and lookout already released the slot. */
static void
lk_links_respond (gpointer user_data, uint64_t req_id, const void *bytes, gsize len,
                  int status)
{
  LkChartLinks *self = user_data;

  if (self->controller != NULL)
    lk_chart_controller_http_respond (self->controller, req_id, bytes, len, status);
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
  lk_fetcher_cancel_all (self->fetcher);
  lk_fetcher_set_live (self->fetcher, TRUE);
  lk_chart_controller_set_http_provider (self->controller, lk_fetcher_http_get,
                                         lk_fetcher_http_cancel, self->fetcher);
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

  if (self->fetcher != NULL)
    lk_fetcher_set_live (self->fetcher, FALSE);
  g_clear_pointer (&self->fetcher, lk_fetcher_free);
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
  g_clear_pointer (&self->fetcher, lk_fetcher_free);
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

static void
lk_chart_links_init (LkChartLinks *self)
{
  self->links = g_ptr_array_new_with_free_func (lk_chart_link_free);
  self->attribution = g_strdup ("");
  self->error = g_strdup ("");
  self->fetcher = lk_fetcher_new (lk_links_respond, self);
}

LkChartLinks *
lk_chart_links_new (LkChartController *controller)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (controller), NULL);

  LkChartLinks *self = g_object_new (LK_TYPE_CHART_LINKS, NULL);
  self->controller = g_object_ref (controller);
  return self;
}
