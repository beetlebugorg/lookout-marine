#include "lk-native-surface.h"

#include <lookout.h>

#ifdef LK_HAVE_X11
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#endif

#ifdef LK_HAVE_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#include <wayland-client.h>
#endif

/* S-52 NODATA, day scheme — what lookout's first frame clears to (no white flash). */
#define LK_NODATA_R 0.576
#define LK_NODATA_G 0.682
#define LK_NODATA_B 0.733

typedef enum {
  LK_BACKEND_NONE = 0,
  LK_BACKEND_X11,
  LK_BACKEND_WAYLAND,
} LkBackend;

struct _LkNativeSurface {
  LkBackend backend;

  /* last geometry, logical points */
  int x, y, width, height, scale;

  /* The struct handed to lookout_open_*_in_window; lives as long as we do. */
  union {
    lookout_x11_window x11;
    lookout_wayland_surface wl;
  } handle;

#ifdef LK_HAVE_X11
  Display *xdisplay;
  Window xwindow;
#endif

#ifdef LK_HAVE_WAYLAND
  struct wl_surface *wl_surface;
  struct wl_subsurface *wl_subsurface;
  struct wl_subcompositor *wl_subcompositor;
  struct wl_event_queue *wl_queue;
#endif
};

/* ---- X11 ---------------------------------------------------------------- */

#ifdef LK_HAVE_X11
/* GTK 4.18 deprecated the X11 backend API with no replacement, but the two
 * gdk_x11_* calls below are still the only way to name a GdkSurface's X window;
 * their warnings stand. Everything else is Xlib against the Display we hold. */
static gboolean
lk_native_surface_init_x11 (LkNativeSurface *self, GdkSurface *parent, GError **error)
{
  GdkDisplay *display = gdk_surface_get_display (parent);
  Display *xdisplay = gdk_x11_display_get_xdisplay (display);
  Window xparent = gdk_x11_surface_get_xid (parent);

  if (xparent == None)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                           "the toplevel has no X window yet");
      return FALSE;
    }

  /* The connection's default screen — the one the toplevel lives on. */
  int screen = DefaultScreen (xdisplay);
  Visual *visual = DefaultVisual (xdisplay, screen);
  int depth = DefaultDepth (xdisplay, screen);

  /* The screen's DEFAULT visual, not the toplevel's 32-bit ARGB one (Vulkan
   * presentation to which is driver-dependent). A child differing in depth from
   * its parent must bring its own colormap and border/background pixel, else BadMatch. */
  XSetWindowAttributes attrs;
  memset (&attrs, 0, sizeof attrs);
  attrs.colormap = XCreateColormap (xdisplay, RootWindow (xdisplay, screen), visual, AllocNone);
  attrs.border_pixel = 0;
  attrs.background_pixel =
      ((unsigned long) (LK_NODATA_R * 255.0 + 0.5) << 16) |
      ((unsigned long) (LK_NODATA_G * 255.0 + 0.5) << 8) |
      ((unsigned long) (LK_NODATA_B * 255.0 + 0.5));
  /* Select nothing: X propagates the events to the GTK toplevel, which routes
   * them to the chart widget's own controllers. */
  attrs.event_mask = 0;

  int sx = self->x * self->scale, sy = self->y * self->scale;
  int sw = MAX (1, self->width * self->scale), sh = MAX (1, self->height * self->scale);

  Window win = XCreateWindow (xdisplay, xparent, sx, sy, sw, sh, 0, depth,
                              InputOutput, visual,
                              CWColormap | CWBorderPixel | CWBackPixel | CWEventMask,
                              &attrs);
  if (win == None)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                           "XCreateWindow failed for the chart surface");
      return FALSE;
    }

  /* Created unmapped; mapped later once lookout has a frame. Sync, not flush:
   * the window must exist on the driver's (possibly separate) connection before
   * vkCreateXlibSurfaceKHR names it. */
  XSync (xdisplay, False);

  self->backend = LK_BACKEND_X11;
  self->xdisplay = xdisplay;
  self->xwindow = win;
  self->handle.x11.display = xdisplay;
  self->handle.x11.window = (unsigned long) win;
  return TRUE;
}
#endif /* LK_HAVE_X11 */

/* ---- Wayland ------------------------------------------------------------ */

#ifdef LK_HAVE_WAYLAND
static void
lk_registry_global (void               *data,
                    struct wl_registry *registry,
                    uint32_t            name,
                    const char         *interface,
                    uint32_t            version)
{
  struct wl_subcompositor **out = data;

  if (*out == NULL && g_strcmp0 (interface, "wl_subcompositor") == 0)
    *out = wl_registry_bind (registry, name, &wl_subcompositor_interface, 1);
}

static void
lk_registry_global_remove (void *data, struct wl_registry *registry, uint32_t name)
{
}

static const struct wl_registry_listener lk_registry_listener = {
  lk_registry_global,
  lk_registry_global_remove,
};

static gboolean
lk_native_surface_init_wayland (LkNativeSurface *self, GdkSurface *parent, GError **error)
{
  GdkDisplay *display = gdk_surface_get_display (parent);
  struct wl_display *wl_display = gdk_wayland_display_get_wl_display (display);
  struct wl_compositor *compositor = gdk_wayland_display_get_wl_compositor (display);
  struct wl_surface *wl_parent = gdk_wayland_surface_get_wl_surface (parent);

  if (wl_display == NULL || compositor == NULL || wl_parent == NULL)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                           "the toplevel has no wl_surface yet");
      return FALSE;
    }

  /* GDK exposes no subcompositor, so bind it off the registry on a PRIVATE queue:
   * roundtripping GDK's default queue would dispatch input/configure events
   * reentrantly from inside a widget realize. */
  self->wl_queue = wl_display_create_queue (wl_display);
  struct wl_display *wrapped = wl_proxy_create_wrapper (wl_display);
  wl_proxy_set_queue ((struct wl_proxy *) wrapped, self->wl_queue);
  struct wl_registry *registry = wl_display_get_registry (wrapped);
  wl_proxy_wrapper_destroy (wrapped);

  wl_registry_add_listener (registry, &lk_registry_listener, &self->wl_subcompositor);
  wl_display_roundtrip_queue (wl_display, self->wl_queue);
  wl_registry_destroy (registry);

  if (self->wl_subcompositor == NULL)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                           "the compositor does not offer wl_subcompositor");
      return FALSE;
    }

  /* On the DEFAULT queue: wl_surface has events, and GDK drains that queue; on
   * our private queue they would pile up unread. */
  self->wl_surface = wl_compositor_create_surface (compositor);
  self->wl_subsurface = wl_subcompositor_get_subsurface (self->wl_subcompositor,
                                                         self->wl_surface, wl_parent);

  /* Below the toplevel: the chart shows through a transparent hole in the GTK
   * window, so the chrome (HUD, zoom bubbles) composites OVER it. Applied on the
   * parent's next commit, which GTK does when it paints. */
  wl_subsurface_place_below (self->wl_subsurface, wl_parent);

  /* EMPTY input region: the default (whole buffer) would swallow every event over
   * the chart; empty passes them to the parent, where GDK routes them to the
   * chart widget. The Wayland spelling of the X11 event_mask=0 trick above. */
  struct wl_region *empty = wl_compositor_create_region (compositor);
  wl_surface_set_input_region (self->wl_surface, empty);
  wl_region_destroy (empty);

  wl_subsurface_set_position (self->wl_subsurface, self->x, self->y);
  /* Desync so chart frames land on Vulkan present, not on the toplevel's commit
   * (else the frame rate is pegged to the static chrome's redraw rate). */
  wl_subsurface_set_desync (self->wl_subsurface);
  wl_surface_set_buffer_scale (self->wl_surface, self->scale);
  wl_surface_commit (self->wl_surface);

  self->backend = LK_BACKEND_WAYLAND;
  self->handle.wl.display = wl_display;
  self->handle.wl.surface = self->wl_surface;
  return TRUE;
}
#endif /* LK_HAVE_WAYLAND */

/* ---- public ------------------------------------------------------------- */

LkNativeSurface *
lk_native_surface_new (GdkSurface  *parent,
                       int          x,
                       int          y,
                       int          width,
                       int          height,
                       int          scale,
                       GError     **error)
{
  g_return_val_if_fail (GDK_IS_SURFACE (parent), NULL);

  LkNativeSurface *self = g_new0 (LkNativeSurface, 1);
  self->x = x;
  self->y = y;
  self->width = MAX (1, width);
  self->height = MAX (1, height);
  self->scale = MAX (1, scale);

  gboolean ok = FALSE;

#ifdef LK_HAVE_WAYLAND
  if (!ok && GDK_IS_WAYLAND_SURFACE (parent))
    ok = lk_native_surface_init_wayland (self, parent, error);
#endif
#ifdef LK_HAVE_X11
  if (!ok && GDK_IS_X11_SURFACE (parent))
    ok = lk_native_surface_init_x11 (self, parent, error);
#endif

  if (!ok)
    {
      if (error != NULL && *error == NULL)
        g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
                             "no native chart surface for this GDK backend — "
                             "lookout renders Vulkan and needs a real X11 or "
                             "Wayland surface to present into");
      lk_native_surface_free (self);
      return NULL;
    }

  return self;
}

void
lk_native_surface_free (LkNativeSurface *self)
{
  if (self == NULL)
    return;

#ifdef LK_HAVE_X11
  if (self->backend == LK_BACKEND_X11 && self->xwindow != None)
    {
      XDestroyWindow (self->xdisplay, self->xwindow);
      XFlush (self->xdisplay);
    }
#endif
#ifdef LK_HAVE_WAYLAND
  if (self->backend == LK_BACKEND_WAYLAND)
    {
      g_clear_pointer (&self->wl_subsurface, wl_subsurface_destroy);
      g_clear_pointer (&self->wl_surface, wl_surface_destroy);
      g_clear_pointer (&self->wl_subcompositor, wl_subcompositor_destroy);
      g_clear_pointer (&self->wl_queue, wl_event_queue_destroy);
    }
#endif

  g_free (self);
}

int
lk_native_surface_kind (LkNativeSurface *self)
{
  g_return_val_if_fail (self != NULL, LOOKOUT_NATIVE_NONE);

  switch (self->backend)
    {
    case LK_BACKEND_X11:     return LOOKOUT_NATIVE_X11_WINDOW;
    case LK_BACKEND_WAYLAND: return LOOKOUT_NATIVE_WAYLAND_SURFACE;
    default:                 return LOOKOUT_NATIVE_NONE;
    }
}

void *
lk_native_surface_handle (LkNativeSurface *self)
{
  g_return_val_if_fail (self != NULL, NULL);
  return &self->handle;
}

gboolean
lk_native_surface_move_resize (LkNativeSurface *self,
                               int              x,
                               int              y,
                               int              width,
                               int              height,
                               int              scale)
{
  g_return_val_if_fail (self != NULL, FALSE);

  width = MAX (1, width);
  height = MAX (1, height);
  scale = MAX (1, scale);

  gboolean moved = (x != self->x || y != self->y);
  gboolean resized = (width != self->width || height != self->height || scale != self->scale);
  if (!moved && !resized)
    return FALSE;

  self->x = x;
  self->y = y;
  self->width = width;
  self->height = height;
  self->scale = scale;

  switch (self->backend)
    {
#ifdef LK_HAVE_X11
    case LK_BACKEND_X11:
      /* X11 has no scale factor; allocations are points, so multiply out. */
      XMoveResizeWindow (self->xdisplay, self->xwindow,
                         x * scale, y * scale, width * scale, height * scale);
      XFlush (self->xdisplay);
      break;
#endif
#ifdef LK_HAVE_WAYLAND
    case LK_BACKEND_WAYLAND:
      /* Logical position; density rides on buffer scale; size follows lookout's
       * swapchain buffer, not us. */
      wl_subsurface_set_position (self->wl_subsurface, x, y);
      wl_surface_set_buffer_scale (self->wl_surface, scale);
      wl_surface_commit (self->wl_surface);
      break;
#endif
    default:
      break;
    }

  return resized;
}

void
lk_native_surface_set_visible (LkNativeSurface *self, gboolean visible)
{
  g_return_if_fail (self != NULL);

  switch (self->backend)
    {
#ifdef LK_HAVE_X11
    case LK_BACKEND_X11:
      if (visible)
        XMapWindow (self->xdisplay, self->xwindow);
      else
        XUnmapWindow (self->xdisplay, self->xwindow);
      XFlush (self->xdisplay);
      break;
#endif
#ifdef LK_HAVE_WAYLAND
    case LK_BACKEND_WAYLAND:
      /* A subsurface unmaps by losing its buffer; the next present re-maps it. */
      if (!visible)
        {
          wl_surface_attach (self->wl_surface, NULL, 0, 0);
          wl_surface_commit (self->wl_surface);
        }
      break;
#endif
    default:
      break;
    }
}

const char *
lk_native_surface_backend (LkNativeSurface *self)
{
  g_return_val_if_fail (self != NULL, "none");

  switch (self->backend)
    {
    case LK_BACKEND_X11:     return "x11";
    case LK_BACKEND_WAYLAND: return "wayland";
    default:                 return "none";
    }
}
