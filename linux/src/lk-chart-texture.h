/* lk-chart-texture.h — the chart as a zero-copy GdkTexture (preferred path).
 * lookout exports a dmabuf, imported here as a scene-graph node so widgets draw
 * OVER it; pixels never leave the GPU. Fallback for drivers without dmabuf
 * export is lk-native-surface.c, which cannot be drawn on. */
#pragma once

#include <gtk/gtk.h>
#include <lookout.h>

G_BEGIN_DECLS

/* TRUE when this display + lookout handle can do the texture path. */
gboolean lk_chart_texture_available (GdkDisplay *display, lookout *handle);

/* Render one frame and import it; NULL if it couldn't (caller falls back).
 * Transfer full. */
GdkTexture *lk_chart_texture_render (GdkDisplay *display, lookout *handle);

G_END_DECLS
