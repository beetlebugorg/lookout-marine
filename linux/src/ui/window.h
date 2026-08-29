/* ui/window.h — the main window: headerbar, chart, status bar. Chrome that
 * floats over the chart on macOS is edge-attached here (headerbar + status bar)
 * on the native-surface path. */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

GtkWidget *lk_window_new (GtkApplication *app, LkAppModel *model);

G_END_DECLS
