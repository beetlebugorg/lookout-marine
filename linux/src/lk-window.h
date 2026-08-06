/* lk-window.h — the main window: headerbar, chart, status bar. Chrome that
 * floats over the chart on macOS is edge-attached here (headerbar + status bar)
 * on the native-surface path. */
#pragma once

#include <gtk/gtk.h>

#include "lk-app-model.h"

G_BEGIN_DECLS

GtkWidget *lk_window_new (GtkApplication *app, LkAppModel *model);

/* The Open Chart picker. Selects a FOLDER of baked cells; the engine validates. */
void lk_present_open_chart_dialog (GtkWindow *parent, LkAppModel *model);

/* The Add Raster Charts pickers: several `.mbtiles` files at once, or a whole
 * folder of them. Two dialogs because one GtkFileDialog takes files or folders,
 * never both. */
void lk_present_add_raster_dialog (GtkWindow *parent, LkAppModel *model);
void lk_present_add_raster_folder_dialog (GtkWindow *parent, LkAppModel *model);

G_END_DECLS
