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

/* The chart's presentation surface. NULL before it's created at open. */
LkNativeSurface *lk_chart_view_get_native_surface (LkChartView *self);

/* Create the chart's native subsurface; FALSE if none could be made. */
gboolean lk_chart_view_ensure_native_surface (LkChartView *self);

/* The widget's size in logical points (with a fallback before layout). */
void lk_chart_view_get_point_size (LkChartView *self, int *width, int *height);

/* lookout presented its first frame — map the surface (hidden until then). */
void lk_chart_view_surface_ready (LkChartView *self);

G_END_DECLS
