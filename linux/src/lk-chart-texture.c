#include "lk-chart-texture.h"

#include <unistd.h>

gboolean
lk_chart_texture_available (GdkDisplay *display, lookout *handle)
{
  if (display == NULL || handle == NULL)
    return FALSE;

  /* $LOOKOUT_NO_DMABUF forces the native-surface fallback for testing. */
  if (g_getenv ("LOOKOUT_NO_DMABUF") != NULL)
    return FALSE;

  /* Both ends must speak dmabuf: driver exports, GTK imports. */
  if (!lookout_dmabuf_supported (handle))
    return FALSE;

  GdkDmabufFormats *formats = gdk_display_get_dmabuf_formats (display);
  if (formats == NULL || gdk_dmabuf_formats_get_n_formats (formats) == 0)
    return FALSE;

  /* Speaking dmabuf doesn't prove GTK can import THIS driver's export (modifiers
   * can be cross-GPU), so render one frame and actually import it. */
  GdkTexture *probe = lk_chart_texture_render (display, handle);
  if (probe == NULL)
    return FALSE;
  g_object_unref (probe);
  return TRUE;
}

/* GdkDmabufTexture takes ownership of its fds, but lookout keeps owning the one
 * it hands out (a ring image outliving this frame), so we pass a dup. */
static void
lk_close_fd (gpointer data)
{
  int fd = GPOINTER_TO_INT (data);

  if (fd >= 0)
    close (fd);
}

GdkTexture *
lk_chart_texture_render (GdkDisplay *display, lookout *handle)
{
  lookout_dmabuf_frame frame;

  memset (&frame, 0, sizeof frame);
  if (!lookout_render_dmabuf (handle, &frame) || frame.fd < 0)
    return NULL;

  int dup_fd = dup (frame.fd);
  if (dup_fd < 0)
    return NULL;

  g_autoptr (GdkDmabufTextureBuilder) builder = gdk_dmabuf_texture_builder_new ();
  gdk_dmabuf_texture_builder_set_display (builder, display);
  gdk_dmabuf_texture_builder_set_width (builder, frame.width);
  gdk_dmabuf_texture_builder_set_height (builder, frame.height);
  gdk_dmabuf_texture_builder_set_fourcc (builder, frame.fourcc);
  gdk_dmabuf_texture_builder_set_modifier (builder, frame.modifier);
  /* The chart is opaque and drawn without alpha blending against the frame. */
  gdk_dmabuf_texture_builder_set_premultiplied (builder, TRUE);
  gdk_dmabuf_texture_builder_set_n_planes (builder, frame.n_planes);
  for (guint i = 0; i < frame.n_planes; i++)
    {
      gdk_dmabuf_texture_builder_set_fd (builder, i, dup_fd);
      gdk_dmabuf_texture_builder_set_offset (builder, i, frame.offset[i]);
      gdk_dmabuf_texture_builder_set_stride (builder, i, frame.stride[i]);
    }

  g_autoptr (GError) error = NULL;
  GdkTexture *texture = gdk_dmabuf_texture_builder_build (builder, lk_close_fd,
                                                          GINT_TO_POINTER (dup_fd), &error);
  if (texture == NULL)
    {
      g_warning ("dmabuf import failed, falling back to a native surface: %s",
                 error != NULL ? error->message : "unknown");
      close (dup_fd);
      return NULL;
    }

  return texture;
}
