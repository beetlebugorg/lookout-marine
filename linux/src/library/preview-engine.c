/* library/preview-engine.c — see library/preview-engine.h. */
#include "library/preview-engine.h"

#include "library/fetch.h"

#include <string.h>

/* The size a picture is rendered at, in pixels, and the density it is rendered
 * for. A card draws it about 250 points wide, and this covers that at 2x with
 * room for the wider card the setup step uses. It is also the size of the
 * pictures the app ships, so a render that replaces one is the same picture at
 * the same sharpness. */
#define LK_PREVIEW_PX_W 960
#define LK_PREVIEW_PX_H 720
#define LK_PREVIEW_DENSITY 2.0f

/* One tick of the frame loop. */
#define LK_PREVIEW_TICK_MS 100
/* The frame loop reports idle before the style has been asked for, so
 * settling counts only after this many ticks. */
#define LK_PREVIEW_WARMUP 10
/* How long one chart has to resolve its style and fetch its tiles: the style,
 * its sprite sheets and a screen of tiles, over the network. */
#define LK_PREVIEW_PATIENCE 70
/* Consecutive quiet ticks that end a render. */
#define LK_PREVIEW_SETTLED 4

struct _LkPreviewEngine {
  lookout   *handle; /* NULL until the first render, and after a close */
  LkFetcher *fetcher;
  gboolean   refused; /* the device would not open; do not keep trying */

  /* The render running now. */
  char               *url;
  LkPreviewSettle     settle;
  guint               tick_id;
  LkPreviewEngineDone done;
  gpointer            done_data;

  /* The last frame that came back, as premultiplied RGBA. */
  guint8 *pixels;
};

gboolean
lk_preview_settle_step (LkPreviewSettle *state, gboolean idle, gboolean building,
                        gboolean snapped)
{
  g_return_val_if_fail (state != NULL, TRUE);

  state->ticks++;
  state->drawn = state->drawn || snapped;

  if (state->ticks < LK_PREVIEW_WARMUP)
    return FALSE;

  if (idle && !building)
    state->settled++;
  else
    state->settled = 0;

  return state->settled >= LK_PREVIEW_SETTLED || state->ticks >= LK_PREVIEW_PATIENCE;
}

/* ---- the handle ---------------------------------------------------------- */

static void
lk_preview_engine_respond (gpointer user_data, uint64_t req_id, const void *bytes,
                           gsize len, int status)
{
  LkPreviewEngine *self = user_data;

  /* The handle is closed while a fetch may still be alive. A late answer then
   * has nowhere to go. */
  if (self->handle == NULL)
    return;
  lookout_http_respond (self->handle, req_id, bytes, len, status);
}

/* Open the engine, once, and keep it for the rest of the pictures. */
static lookout *
lk_preview_engine_open (LkPreviewEngine *self)
{
  static const char *const none[] = { NULL };

  if (self->handle != NULL)
    return self->handle;
  if (self->refused)
    return NULL;

  /* No window, and no charts: a style is the whole picture. */
  self->handle = lookout_open_charts (none, 0, LK_PREVIEW_PX_W, LK_PREVIEW_PX_H, 0, 0);
  if (self->handle == NULL)
    {
      /* No device to render on. A headless build and a machine with no
       * Vulkan both land here, and the list draws its placeholders. */
      self->refused = TRUE;
      g_message ("chart pictures: no second engine, so an unpicked style has none");
      return NULL;
    }

  lookout_set_pixel_density (self->handle, LK_PREVIEW_DENSITY);
  lookout_set_http_provider (self->handle, lk_fetcher_http_get, lk_fetcher_http_cancel,
                             self->fetcher);
  return self->handle;
}

void
lk_preview_engine_close (LkPreviewEngine *self)
{
  g_return_if_fail (self != NULL);

  g_clear_handle_id (&self->tick_id, g_source_remove);
  g_clear_pointer (&self->url, g_free);
  self->done = NULL;
  self->done_data = NULL;

  if (self->handle == NULL)
    return;

  /* The fetcher goes first: an answer must never arrive into a handle that is
   * going away, and the next handle would reuse this one's request ids. */
  lookout_set_http_provider (self->handle, NULL, NULL, NULL);
  lk_fetcher_cancel_all (self->fetcher);
  lookout_close (self->handle);
  self->handle = NULL;
}

/* ---- one render ---------------------------------------------------------- */

/* Hand the picture over and take the render down. */
static void
lk_preview_engine_finish (LkPreviewEngine *self, GdkTexture *picture)
{
  g_autofree char *url = g_steal_pointer (&self->url);
  LkPreviewEngineDone done = self->done;
  gpointer data = self->done_data;

  self->tick_id = 0;
  self->done = NULL;
  self->done_data = NULL;

  if (done != NULL)
    done (url, picture, data);
  g_clear_object (&picture);
}

static gboolean
lk_preview_engine_tick (gpointer data)
{
  LkPreviewEngine *self = data;
  lookout_frame frame;
  gboolean snapped;
  gsize len = (gsize) LK_PREVIEW_PX_W * LK_PREVIEW_PX_H * 4;

  if (self->handle == NULL)
    {
      lk_preview_engine_finish (self, NULL);
      return G_SOURCE_REMOVE;
    }

  memset (&frame, 0, sizeof frame);
  lookout_frame_next (self->handle, &frame);
  lookout_render (self->handle);

  /* Every tick. Asking for a frame is what works out which tiles the view
   * needs, so a loop that only ticks and snapshots at the end never asks for
   * one and draws an empty style. 0 is success here, unlike the rest of this
   * ABI. */
  snapped = lookout_snapshot_rgba (self->handle, self->pixels, len) == 0;

  if (!lk_preview_settle_step (&self->settle, frame.verdict == LOOKOUT_FRAME_IDLE,
                               frame.building != 0, snapped))
    return G_SOURCE_CONTINUE;

  if (!self->settle.drawn)
    {
      lk_preview_engine_finish (self, NULL);
      return G_SOURCE_REMOVE;
    }

  /* The bytes are copied out: the buffer is this engine's and the next render
   * writes over it. */
  g_autoptr (GBytes) bytes = g_bytes_new (self->pixels, len);
  lk_preview_engine_finish (self,
                            gdk_memory_texture_new (LK_PREVIEW_PX_W, LK_PREVIEW_PX_H,
                                                    GDK_MEMORY_R8G8B8A8_PREMULTIPLIED,
                                                    bytes, LK_PREVIEW_PX_W * 4));
  return G_SOURCE_REMOVE;
}

gboolean
lk_preview_engine_busy (LkPreviewEngine *self)
{
  return self != NULL && self->tick_id != 0;
}

gboolean
lk_preview_engine_render (LkPreviewEngine *self, const char *url,
                          double lon, double lat, double zoom,
                          LkPreviewEngineDone done, gpointer user_data)
{
  lookout_view view;
  lookout *handle;

  g_return_val_if_fail (self != NULL, FALSE);
  g_return_val_if_fail (url != NULL && url[0] != '\0', FALSE);

  if (lk_preview_engine_busy (self))
    return FALSE;

  handle = lk_preview_engine_open (self);
  if (handle == NULL)
    return FALSE;

  if (self->pixels == NULL)
    self->pixels = g_malloc0 ((gsize) LK_PREVIEW_PX_W * LK_PREVIEW_PX_H * 4);

  view = (lookout_view) { .lon = lon, .lat = lat, .zoom = zoom, .rotation_deg = 0 };
  lookout_set_view (handle, &view);
  lookout_chart_link_draw (handle, url);

  g_free (self->url);
  self->url = g_strdup (url);
  memset (&self->settle, 0, sizeof self->settle);
  self->done = done;
  self->done_data = user_data;
  self->tick_id = g_timeout_add (LK_PREVIEW_TICK_MS, lk_preview_engine_tick, self);
  return TRUE;
}

/* ---- lifecycle ----------------------------------------------------------- */

LkPreviewEngine *
lk_preview_engine_new (void)
{
  LkPreviewEngine *self = g_new0 (LkPreviewEngine, 1);

  self->fetcher = lk_fetcher_new (lk_preview_engine_respond, self);
  return self;
}

void
lk_preview_engine_free (LkPreviewEngine *self)
{
  if (self == NULL)
    return;

  lk_preview_engine_close (self);
  g_clear_pointer (&self->fetcher, lk_fetcher_free);
  g_clear_pointer (&self->pixels, g_free);
  g_free (self);
}
