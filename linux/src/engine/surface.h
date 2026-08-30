/* engine/surface.h — the chart's own presentation surface, under GTK.
 *
 * lookout renders Vulkan and needs a real window-system surface, which GTK4
 * won't hand out per-widget. So the chart gets its own child surface under the
 * toplevel, over the chart widget's allocation: on X11 a child Window, on
 * Wayland a wl_subsurface.
 *
 * It composites ABOVE the GTK widget tree, so no widget can draw over the chart
 * (hence edge-attached chrome, and identify results as a popover — separate GDK
 * surfaces still stack above us). It is INPUT-TRANSPARENT (X11: selects no
 * events; Wayland: empty input region), so input reaches the chart widget's own
 * gestures — nothing arrives at this file.
 *
 * Geometry is in LOGICAL points plus the integer scale factor; each backend
 * converts (X11 multiplies out to pixels, Wayland carries density as buffer scale).
 */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

typedef struct _LkNativeSurface LkNativeSurface;

/* Create the chart surface under `parent`, covering (x, y, width, height) in
 * logical points at `scale`. NULL with *error when the backend has no path. */
LkNativeSurface *lk_native_surface_new (GdkSurface  *parent,
                                        int          x,
                                        int          y,
                                        int          width,
                                        int          height,
                                        int          scale,
                                        GError     **error);
void             lk_native_surface_free (LkNativeSurface *self);

/* The native kind and handle for lookout_open_*_in_window; handle points into
 * `self` and is read only during the open call. */
int   lk_native_surface_kind   (LkNativeSurface *self);
void *lk_native_surface_handle (LkNativeSurface *self);

/* Track the widget's allocation (logical points). TRUE when the SIZE changed. */
gboolean lk_native_surface_move_resize (LkNativeSurface *self,
                                        int              x,
                                        int              y,
                                        int              width,
                                        int              height,
                                        int              scale);

/* Map/unmap alongside the chart widget. */
void lk_native_surface_set_visible (LkNativeSurface *self, gboolean visible);

/* Human-readable backend name, for logs and error paths. */
const char *lk_native_surface_backend (LkNativeSurface *self);

G_END_DECLS
