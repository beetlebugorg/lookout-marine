/* lk-chart-view.h — the GPU chart surface embedded in GTK.
 *
 * Owns the native chart surface, pins it over its allocation, and forwards
 * input to the controller. Drag pans (with fling), Shift-drag rotates, wheel
 * and pinch zoom under the pointer, click identifies, motion feeds the readout.
 */
#pragma once

#include <gtk/gtk.h>

#include "lk-native-surface.h"

G_BEGIN_DECLS

#define LK_TYPE_CHART_VIEW (lk_chart_view_get_type ())
G_DECLARE_FINAL_TYPE (LkChartView, lk_chart_view, LK, CHART_VIEW, GtkWidget)

typedef struct _LkAppModel LkAppModel;

GtkWidget *lk_chart_view_new (LkAppModel *model);

/* The presentation surface. NULL in texture mode and before realize. */
LkNativeSurface *lk_chart_view_get_native_surface (LkChartView *self);

/* Create the fallback surface when the texture path is unavailable; FALSE if
 * none could be made. */
gboolean lk_chart_view_ensure_native_surface (LkChartView *self);

/* TRUE when the chart is a texture, so GTK chrome can be drawn over it. */
gboolean lk_chart_view_can_overlay (LkChartView *self);

/* Hand the widget the frame just rendered; drawn 1:1, never resampled. */
void lk_chart_view_set_texture (LkChartView *self, GdkTexture *texture);

/* The widget's size in logical points (with a fallback before layout). */
void lk_chart_view_get_point_size (LkChartView *self, int *width, int *height);

/* The surface's FRACTIONAL scale (1.5 on a 150% monitor); the texture is
 * rendered to match. Falls back to the integer factor before the surface. */
double lk_chart_view_get_scale (LkChartView *self);

/* lookout presented its first frame — map the surface (hidden until then). */
void lk_chart_view_surface_ready (LkChartView *self);

/* Show the identify popover at a point in widget coordinates. */
void lk_chart_view_present_identify (LkChartView *self, double x, double y);

G_END_DECLS
