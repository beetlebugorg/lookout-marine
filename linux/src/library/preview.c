/* library/preview.c — see library/preview.h. */
#include "library/preview.h"

#include "library/agent.h"
#include "library/preview-engine.h"
#include "ui/charts/catalog.h"

#include <glib/gstdio.h>
#include <libsoup/soup.h>
#include <math.h>

/* How often the missing pictures are asked for again, and how many times.
 * A style read is a fetch, so the first ask is almost never answered; twelve
 * seconds is long enough for a slow one and short enough that a chart with no
 * raster tiles stops being asked about. */
#define LK_PREVIEW_ASK_MS 600
#define LK_PREVIEW_TRIES  20

/* How long the chart being drawn is watched for, and how often. A style has
 * to resolve, fetch its sprites and fetch a screen of tiles before the frame
 * is its own. */
#define LK_PREVIEW_WATCH_MS 900
#define LK_PREVIEW_WATCHES  10

/* Lookout's own chart has no url. This is what it is filed under. */
#define LK_PREVIEW_OWN ""

struct _LkChartPreviews {
  GObject parent_instance;

  LkChartController *controller; /* strong */
  SoupSession       *session;

  /* url (or "") -> GdkTexture. The pictures that have arrived. */
  GHashTable *pictures;
  /* Charts asked for over the network now, so one is not fetched twice. */
  GHashTable *in_flight;
  /* Charts whose style names no raster tiles. They draw their kind instead,
   * and nothing asks again. */
  GHashTable *unavailable;

  /* The charts a list is drawing, and how many times they have been asked
   * for. */
  GStrv wanted;
  guint tries;
  guint ask_id;

  /* The point every picture was fetched at, as a tile. The mariner moves, and
   * a picture of water they have left says nothing about the style. */
  int tile_x, tile_y;
  gboolean have_tile;

  /* The engine that draws a style nobody has picked, and the charts waiting
   * for it. Opened at the first chart that needs it and closed with the list:
   * a second Vulkan device is not something to hold while nobody is looking. */
  LkPreviewEngine *engine;
  GQueue          *queue; /* char*, the urls waiting for the engine */

  /* The chart being watched as it settles, and how many looks are left. */
  char    *watching;
  gboolean watching_own; /* the watched chart is Lookout's own */
  guint    watches;
  guint    watch_id;
};

enum {
  SIGNAL_CHANGED,
  N_SIGNALS
};

static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE (LkChartPreviews, lk_chart_previews, G_TYPE_OBJECT)

static gboolean lk_chart_previews_ask (gpointer data);

/* ---- the cache ----------------------------------------------------------- */

void
lk_chart_preview_tile (double lon, double lat, int zoom, int *out_x, int *out_y)
{
  double n = pow (2.0, zoom);
  double phi = CLAMP (lat, -85.05112878, 85.05112878) * G_PI / 180.0;
  double x = (lon + 180.0) / 360.0 * n;
  double y = (1.0 - log (tan (phi) + 1.0 / cos (phi)) / G_PI) / 2.0 * n;

  /* On the grid, whatever the arithmetic says. The clamp latitude maps to the
   * top row exactly, and floating point puts it a hair the other side: the
   * floor of that is row -1, which is not a tile any server has. */
  if (out_x != NULL)
    *out_x = (int) CLAMP (floor (x), 0, n - 1);
  if (out_y != NULL)
    *out_y = (int) CLAMP (floor (y), 0, n - 1);
}

char *
lk_chart_preview_cache_path (const char *url, double lon, double lat, int zoom)
{
  int x = 0, y = 0;
  guint64 hash = 5381;

  lk_chart_preview_tile (lon, lat, zoom, &x, &y);

  g_autofree char *key = g_strdup_printf ("%s|%d/%d/%d",
                                          url != NULL ? url : LK_PREVIEW_OWN, zoom, x, y);
  for (const char *at = key; *at != '\0'; at++)
    hash = (hash * 33) + (guint64) (guchar) *at;

  g_autofree char *name = g_strdup_printf ("%016" G_GINT64_MODIFIER "x.png", hash);
  return g_build_filename (g_get_user_cache_dir (), "lookout-marine", "previews",
                           name, NULL);
}

/* ---- what has arrived ---------------------------------------------------- */

static const char *
lk_preview_key (const char *url)
{
  return url != NULL ? url : LK_PREVIEW_OWN;
}

/* Keep a picture, and tell whoever is drawing the list. */
static void
lk_chart_previews_keep (LkChartPreviews *self, const char *url, GdkTexture *texture)
{
  if (texture == NULL)
    return;
  g_hash_table_insert (self->pictures, g_strdup (lk_preview_key (url)), texture);
  g_hash_table_remove (self->unavailable, lk_preview_key (url));
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

/* Write a picture where the next run finds it. */
static void
lk_chart_previews_write (LkChartPreviews *self, const char *url, GdkTexture *texture)
{
  double lon = 0, lat = 0;

  if (!lk_chart_controller_view_centre (self->controller, &lon, &lat))
    return;

  g_autofree char *path = lk_chart_preview_cache_path (url, lon, lat, LK_PREVIEW_ZOOM);
  g_autofree char *dir = g_path_get_dirname (path);

  if (g_mkdir_with_parents (dir, 0700) != 0)
    return;
  /* A picture that will not save is not worth reporting: the list has it in
   * memory, and the next run simply fetches again. */
  gdk_texture_save_to_png (texture, path);
}

/* A picture kept from a previous run, if there is one for this chart at this
 * water. Reading one costs a file open, so a list looked at before draws at
 * once. */
static GdkTexture *
lk_chart_previews_read (LkChartPreviews *self, const char *url)
{
  double lon = 0, lat = 0;

  if (!lk_chart_controller_view_centre (self->controller, &lon, &lat))
    return NULL;

  g_autofree char *path = lk_chart_preview_cache_path (url, lon, lat, LK_PREVIEW_ZOOM);
  if (!g_file_test (path, G_FILE_TEST_EXISTS))
    return NULL;

  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) file = g_file_new_for_path (path);
  GdkTexture *texture = gdk_texture_new_from_file (file, &error);

  if (texture == NULL)
    {
      /* A half-written picture from a run that was killed. Throw it away and
       * fetch again rather than carrying it. */
      g_remove (path);
      return NULL;
    }
  return texture;
}

GdkTexture *
lk_chart_previews_get (LkChartPreviews *self, const char *url)
{
  GdkTexture *texture;

  g_return_val_if_fail (LK_IS_CHART_PREVIEWS (self), NULL);

  /* A picture the ENGINE drew stands first. It is this chart at the mariner's
   * own water, rather than a render of somebody else's water or of one of the
   * sources this style draws from. */
  texture = g_hash_table_lookup (self->pictures, lk_preview_key (url));
  if (texture != NULL)
    return texture;

  /* Then the picture the app ships. Instant, and no network. */
  texture = lk_chart_catalog_art (url);
  if (texture != NULL)
    return texture;

  /* Lookout's own chart, before the engine has drawn anything: the picture the
   * welcome step shows. */
  return url == NULL ? lk_chart_welcome_picture () : NULL;
}

/* ---- the chart being drawn ----------------------------------------------- */

gboolean
lk_chart_previews_capture (LkChartPreviews *self, const char *url)
{
  g_autoptr (GdkTexture) shot = NULL;

  g_return_val_if_fail (LK_IS_CHART_PREVIEWS (self), FALSE);

  shot = lk_chart_controller_snapshot (self->controller);
  if (shot == NULL)
    return FALSE;

  /* Written once. A watch takes ten pictures of one chart as it settles, and
   * ten full-window PNGs is a cache nobody asked for. */
  if (lk_chart_previews_read (self, url) == NULL)
    lk_chart_previews_write (self, url, shot);
  lk_chart_previews_keep (self, url, g_steal_pointer (&shot));
  return TRUE;
}

static gboolean
lk_chart_previews_watch_tick (gpointer data)
{
  LkChartPreviews *self = data;

  lk_chart_previews_capture (self, self->watching_own ? NULL : self->watching);
  if (--self->watches > 0)
    return G_SOURCE_CONTINUE;

  self->watch_id = 0;
  g_clear_pointer (&self->watching, g_free);
  return G_SOURCE_REMOVE;
}

void
lk_chart_previews_watch (LkChartPreviews *self, const char *url)
{
  g_return_if_fail (LK_IS_CHART_PREVIEWS (self));

  /* Already watching this one. */
  if (self->watch_id != 0 && g_strcmp0 (self->watching, url) == 0)
    return;

  g_clear_handle_id (&self->watch_id, g_source_remove);
  g_free (self->watching);
  self->watching = g_strdup (url);
  self->watching_own = url == NULL;
  self->watches = LK_PREVIEW_WATCHES;
  /* Not now: the frame on the screen at this moment is the chart this one
   * replaced. */
  self->watch_id = g_timeout_add (LK_PREVIEW_WATCH_MS, lk_chart_previews_watch_tick, self);
}

/* ---- one tile, fetched --------------------------------------------------- */

typedef struct {
  LkChartPreviews *self;    /* strong */
  SoupMessage     *message; /* to read the status in the completion */
  char            *url;
} LkPreviewFetch;

static void
lk_preview_fetch_free (LkPreviewFetch *fetch)
{
  g_clear_object (&fetch->self);
  g_clear_object (&fetch->message);
  g_free (fetch->url);
  g_free (fetch);
}

static void
lk_preview_tile_done (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkPreviewFetch *fetch = user_data;
  LkChartPreviews *self = fetch->self;
  g_autoptr (GError) error = NULL;
  g_autoptr (GBytes) bytes =
      soup_session_send_and_read_finish (SOUP_SESSION (source), result, &error);

  guint status = soup_message_get_status (fetch->message);

  g_hash_table_remove (self->in_flight, fetch->url);

  /* Only 2xx carries a tile. A host that answers 403 with a page saying so
   * would otherwise be filed as this publisher's chart. */
  if (error == NULL && status / 100 == 2 && bytes != NULL && g_bytes_get_size (bytes) > 0)
    {
      g_autoptr (GError) decode = NULL;
      GdkTexture *texture = gdk_texture_new_from_bytes (bytes, &decode);

      if (texture != NULL)
        {
          lk_chart_previews_write (self, fetch->url, texture);
          lk_chart_previews_keep (self, fetch->url, texture);
        }
      else
        {
          /* A publisher serving something other than a PNG or a JPEG draws no
           * picture here. It is not a failure worth a line in the log on
           * every list. */
          g_hash_table_add (self->unavailable, g_strdup (fetch->url));
        }
    }
  else if (!g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    {
      g_hash_table_add (self->unavailable, g_strdup (fetch->url));
    }

  lk_preview_fetch_free (fetch);
}

static void
lk_chart_previews_fetch (LkChartPreviews *self, const char *url, const char *tile)
{
  g_autoptr (SoupMessage) message = soup_message_new (SOUP_METHOD_GET, tile);
  LkPreviewFetch *fetch;

  if (message == NULL)
    {
      g_hash_table_add (self->unavailable, g_strdup (url));
      return;
    }

  soup_message_headers_append (soup_message_get_request_headers (message),
                               "Referer", LK_REFERER);

  fetch = g_new0 (LkPreviewFetch, 1);
  fetch->self = g_object_ref (self);
  fetch->message = g_object_ref (message);
  fetch->url = g_strdup (url);

  g_hash_table_add (self->in_flight, g_strdup (url));
  soup_session_send_and_read_async (self->session, message, G_PRIORITY_LOW, NULL,
                                    lk_preview_tile_done, fetch);
}

/* ---- drawing a style nobody has picked ----------------------------------- */

static void lk_chart_previews_draw_next (LkChartPreviews *self);

static void
lk_chart_previews_drawn (const char *url, GdkTexture *picture, gpointer user_data)
{
  LkChartPreviews *self = user_data;

  if (picture != NULL)
    {
      lk_chart_previews_write (self, url, picture);
      lk_chart_previews_keep (self, url, g_object_ref (picture));
    }
  else
    {
      /* Nothing came back. The style is refused, or it draws nothing this
       * engine can read: the card shows its kind. */
      g_hash_table_add (self->unavailable, g_strdup (url));
    }

  lk_chart_previews_draw_next (self);
}

/* One at a time. A second engine is one device and one style's worth of
 * working set; two would be two. */
static void
lk_chart_previews_draw_next (LkChartPreviews *self)
{
  double lon = 0, lat = 0;

  if (self->engine == NULL || lk_preview_engine_busy (self->engine))
    return;
  if (!lk_chart_controller_view_centre (self->controller, &lon, &lat))
    return;

  while (!g_queue_is_empty (self->queue))
    {
      g_autofree char *url = g_queue_pop_head (self->queue);

      /* A picture arrived while this one waited. */
      if (g_hash_table_contains (self->pictures, url))
        continue;
      if (lk_preview_engine_render (self->engine, url, lon, lat, LK_PREVIEW_ZOOM,
                                    lk_chart_previews_drawn, self))
        return;
    }

  /* Nothing left to draw. The device goes back. */
  lk_preview_engine_close (self->engine);
}

/* Draw this chart on the engine with no window, when nothing cheaper can
 * picture it. */
static void
lk_chart_previews_draw (LkChartPreviews *self, const char *url)
{
  for (GList *at = self->queue->head; at != NULL; at = at->next)
    if (g_strcmp0 (at->data, url) == 0)
      return;

  if (self->engine == NULL)
    self->engine = lk_preview_engine_new ();
  g_queue_push_tail (self->queue, g_strdup (url));
  lk_chart_previews_draw_next (self);
}

/* ---- asking for what is missing ------------------------------------------ */

/* Ask the core for each chart's tile, and fetch the ones it can name. TRUE
 * once every chart on the list is answered, one way or the other. */
static gboolean
lk_chart_previews_round (LkChartPreviews *self)
{
  double lon = 0, lat = 0;
  int x = 0, y = 0;
  gboolean settled = TRUE;

  if (self->wanted == NULL)
    return TRUE;
  if (!lk_chart_controller_view_centre (self->controller, &lon, &lat))
    return FALSE;

  /* The mariner has sailed out of the tile every picture was taken in. What
   * is on screen is water they have left, so it goes. */
  lk_chart_preview_tile (lon, lat, LK_PREVIEW_ZOOM, &x, &y);
  if (self->have_tile && (x != self->tile_x || y != self->tile_y))
    {
      g_hash_table_remove_all (self->pictures);
      g_hash_table_remove_all (self->unavailable);
    }
  self->tile_x = x;
  self->tile_y = y;
  self->have_tile = TRUE;

  for (guint i = 0; self->wanted[i] != NULL; i++)
    {
      /* An empty string in the list is Lookout's own chart, which is pictured
       * by a snapshot rather than by a tile. */
      const char *url = self->wanted[i];

      if (url[0] == '\0')
        continue;
      /* A picture the app ships, or one that has arrived, stands. */
      if (lk_chart_catalog_art (url) != NULL)
        continue;
      if (g_hash_table_contains (self->pictures, url))
        continue;
      if (g_hash_table_contains (self->unavailable, url))
        continue;
      if (g_hash_table_contains (self->in_flight, url))
        {
          settled = FALSE;
          continue;
        }

      /* One kept from a previous run at this water. */
      GdkTexture *kept = lk_chart_previews_read (self, url);
      if (kept != NULL)
        {
          lk_chart_previews_keep (self, url, kept);
          continue;
        }

      g_autofree char *tile =
          lk_chart_controller_chart_link_preview_url (self->controller, url, lon, lat,
                                                      LK_PREVIEW_ZOOM);
      if (tile == NULL)
        {
          /* Either the core has not read this style yet, or it has and the
           * style names no raster tiles. The first wants another round; the
           * second has no tile to fetch, ever, and goes to the engine with no
           * window instead. Asking again a few times costs nothing and tells
           * the two apart. */
          if (self->tries >= LK_PREVIEW_TRIES / 2)
            lk_chart_previews_draw (self, url);
          settled = FALSE;
          continue;
        }
      lk_chart_previews_fetch (self, url, tile);
      settled = FALSE;
    }
  return settled;
}

static gboolean
lk_chart_previews_ask (gpointer data)
{
  LkChartPreviews *self = data;

  if (lk_chart_previews_round (self) || ++self->tries >= LK_PREVIEW_TRIES)
    {
      /* Out of patience for a tile. Anything still unpictured goes to the
       * engine with no window, which draws the style itself. */
      for (guint i = 0; self->wanted != NULL && self->wanted[i] != NULL; i++)
        {
          const char *url = self->wanted[i];

          if (url[0] == '\0' || g_hash_table_contains (self->pictures, url))
            continue;
          if (lk_chart_catalog_art (url) != NULL)
            continue;
          lk_chart_previews_draw (self, url);
        }
      self->ask_id = 0;
      return G_SOURCE_REMOVE;
    }
  return G_SOURCE_CONTINUE;
}

/* TRUE while a wanted chart still needs a tile template off the core.
 *
 * Reading a style is not free: a publisher's chart names its sources, its
 * sprite packs and its fonts, and the core reads all of them inside a frame.
 * One style here holds 389 layers and 5,354 sprite cells, which is over a
 * second of the main thread on this machine. A chart the app ships art for,
 * or one already pictured, needs none of that. */
static gboolean
lk_chart_previews_need_template (LkChartPreviews *self)
{
  for (guint i = 0; self->wanted != NULL && self->wanted[i] != NULL; i++)
    {
      const char *url = self->wanted[i];

      if (url[0] == '\0')
        continue;
      if (lk_chart_catalog_art (url) != NULL)
        continue;
      if (g_hash_table_contains (self->pictures, url))
        continue;
      if (g_hash_table_contains (self->unavailable, url))
        continue;
      if (g_hash_table_contains (self->in_flight, url))
        continue;
      return TRUE;
    }
  return FALSE;
}

void
lk_chart_previews_want (LkChartPreviews *self, const char *const *urls)
{
  g_return_if_fail (LK_IS_CHART_PREVIEWS (self));

  g_clear_pointer (&self->wanted, g_strfreev);
  self->wanted = g_strdupv ((char **) urls);
  self->tries = 0;

  /* The core reads the style of every link whose template it does not know.
   * One call covers the whole list. */
  if (lk_chart_previews_need_template (self))
    lk_chart_controller_chart_links_preview (self->controller);

  if (lk_chart_previews_round (self))
    return;
  if (self->ask_id == 0)
    self->ask_id = g_timeout_add (LK_PREVIEW_ASK_MS, lk_chart_previews_ask, self);
}

void
lk_chart_previews_stop (LkChartPreviews *self)
{
  g_return_if_fail (LK_IS_CHART_PREVIEWS (self));

  g_clear_handle_id (&self->ask_id, g_source_remove);
  g_clear_handle_id (&self->watch_id, g_source_remove);
  g_clear_pointer (&self->wanted, g_strfreev);
  g_clear_pointer (&self->watching, g_free);
}

/* ---- lifecycle ----------------------------------------------------------- */

void
lk_chart_previews_shutdown (LkChartPreviews *self)
{
  g_return_if_fail (LK_IS_CHART_PREVIEWS (self));

  lk_chart_previews_stop (self);
  if (self->session != NULL)
    soup_session_abort (self->session);
  g_clear_pointer (&self->engine, lk_preview_engine_free);
  g_clear_object (&self->controller);
}

static void
lk_chart_previews_dispose (GObject *object)
{
  LkChartPreviews *self = LK_CHART_PREVIEWS (object);

  lk_chart_previews_stop (self);
  if (self->session != NULL)
    soup_session_abort (self->session);
  g_clear_object (&self->session);
  g_clear_object (&self->controller);
  g_clear_pointer (&self->pictures, g_hash_table_unref);
  g_clear_pointer (&self->in_flight, g_hash_table_unref);
  g_clear_pointer (&self->unavailable, g_hash_table_unref);
  g_clear_pointer (&self->watching, g_free);
  g_clear_pointer (&self->engine, lk_preview_engine_free);
  if (self->queue != NULL)
    {
      g_queue_free_full (self->queue, g_free);
      self->queue = NULL;
    }

  G_OBJECT_CLASS (lk_chart_previews_parent_class)->dispose (object);
}

static void
lk_chart_previews_class_init (LkChartPreviewsClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = lk_chart_previews_dispose;

  /* A picture arrived. One signal: whoever draws the list asks again for
   * every chart on it. */
  signals[SIGNAL_CHANGED] =
      g_signal_new ("changed", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

static void
lk_chart_previews_init (LkChartPreviews *self)
{
  self->queue = g_queue_new ();
  self->pictures = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_object_unref);
  self->in_flight = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  self->unavailable = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
}

LkChartPreviews *
lk_chart_previews_new (LkChartController *controller)
{
  LkChartPreviews *self = g_object_new (LK_TYPE_CHART_PREVIEWS, NULL);

  self->controller = controller != NULL ? g_object_ref (controller) : NULL;
  /* A session of the shell's own. The one in library/links.c answers what the
   * CORE asks for, and a tile fetched for a picture is the shell's own ask. */
  self->session = soup_session_new_with_options ("user-agent", LK_USER_AGENT, NULL);
  soup_session_set_timeout (self->session, 20);
  return self;
}
