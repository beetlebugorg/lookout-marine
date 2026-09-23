/* ui/charts/preview.c: see ui/charts/preview.h. */
#include "ui/charts/preview.h"

#include "ui/charts/catalog.h"

struct _LkChartPreviews {
  GObject parent_instance;

  LkChartController *controller; /* strong */

  /* url (or "") -> GdkTexture. The pictures the core has drawn. */
  GHashTable *pictures;
};

G_DEFINE_FINAL_TYPE (LkChartPreviews, lk_chart_previews, G_TYPE_OBJECT)

GdkTexture *
lk_chart_previews_get (LkChartPreviews *self, const char *url)
{
  GdkTexture *texture;

  g_return_val_if_fail (LK_IS_CHART_PREVIEWS (self), NULL);

  /* A picture the core drew stands first. It is this chart at the mariner's
   * own water. */
  texture = g_hash_table_lookup (self->pictures, url != NULL ? url : "");
  if (texture != NULL)
    return texture;

  /* Then the picture the app ships. Instant, and no network. */
  texture = lk_chart_catalog_art (url);
  if (texture != NULL)
    return texture;

  /* Lookout's own chart, while it is not the one drawn: the picture the
   * welcome step shows. */
  return url == NULL || url[0] == '\0' ? lk_chart_welcome_picture () : NULL;
}

/* Ask the core for one picture, and keep it when it is ready. */
static int
lk_chart_previews_ask (LkChartPreviews *self, const char *url, int kind, double lon,
                       double lat, int width, int height)
{
  gsize len = (gsize) width * height * 4;
  g_autofree guint8 *pixels = g_malloc (len);
  int got = lk_chart_controller_chart_link_picture (self->controller, url, kind, lon, lat,
                                                    LK_PREVIEW_ZOOM, width, height, pixels);

  if (got == LOOKOUT_PICTURE_READY)
    {
      g_autoptr (GBytes) bytes = g_bytes_new_take (g_steal_pointer (&pixels), len);

      g_hash_table_insert (self->pictures, g_strdup (url),
                           gdk_memory_texture_new (width, height,
                                                   GDK_MEMORY_R8G8B8A8_PREMULTIPLIED, bytes,
                                                   (gsize) width * 4));
    }
  else if (got == LOOKOUT_PICTURE_NONE)
    g_hash_table_remove (self->pictures, url);
  return got;
}

void
lk_chart_previews_want (LkChartPreviews *self, const char *const *urls, int width,
                        int height)
{
  double lon = 0, lat = 0;

  g_return_if_fail (LK_IS_CHART_PREVIEWS (self));

  if (width <= 0 || height <= 0 ||
      !lk_chart_controller_view_centre (self->controller, &lon, &lat))
    return;

  for (guint i = 0; urls != NULL && urls[i] != NULL; i++)
    {
      const char *url = urls[i];

      /* A link the core pictures from no tile is drawn on its second handle,
       * unless the app ships a picture of it. */
      if (lk_chart_previews_ask (self, url, LOOKOUT_PICTURE_TILE, lon, lat, width, height) ==
              LOOKOUT_PICTURE_NONE &&
          url[0] != '\0' && lk_chart_catalog_art (url) == NULL)
        lk_chart_previews_ask (self, url, LOOKOUT_PICTURE_RENDER, lon, lat, width, height);
    }
}

void
lk_chart_previews_stop (LkChartPreviews *self)
{
  g_return_if_fail (LK_IS_CHART_PREVIEWS (self));
  lk_chart_controller_chart_link_pictures_cancel (self->controller);
}

static void
lk_chart_previews_dispose (GObject *object)
{
  LkChartPreviews *self = LK_CHART_PREVIEWS (object);

  if (self->controller != NULL)
    lk_chart_previews_stop (self);
  g_clear_object (&self->controller);
  g_clear_pointer (&self->pictures, g_hash_table_unref);

  G_OBJECT_CLASS (lk_chart_previews_parent_class)->dispose (object);
}

static void
lk_chart_previews_class_init (LkChartPreviewsClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = lk_chart_previews_dispose;
}

static void
lk_chart_previews_init (LkChartPreviews *self)
{
  self->pictures = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_object_unref);
}

LkChartPreviews *
lk_chart_previews_new (LkChartController *controller)
{
  LkChartPreviews *self = g_object_new (LK_TYPE_CHART_PREVIEWS, NULL);

  self->controller = controller != NULL ? g_object_ref (controller) : NULL;
  return self;
}
