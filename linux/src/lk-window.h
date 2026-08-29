/* lk-window.h — the main window: headerbar, chart, status bar. Chrome that
 * floats over the chart on macOS is edge-attached here (headerbar + status bar)
 * on the native-surface path. */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

GtkWidget *lk_window_new (GtkApplication *app, LkAppModel *model);

/* The Open Chart picker. Selects a FOLDER of baked cells; the engine validates. */
void lk_present_open_chart_dialog (GtkWindow *parent, LkAppModel *model);

/* The Open Chart picker for an exchange set that arrives as one .zip, which is
 * how a chart agency publishes one. Separate from the folder picker because
 * GtkFileDialog chooses folders or files, never both. */
void lk_present_open_archive_dialog (GtkWindow *parent, LkAppModel *model);

/* One thing the mariner opened, routed the way every shell routes it: a plugin
 * package goes to the consent sheet, a folder is a chart library, and anything
 * else is offered to the plugins before it is treated as a chart. The core
 * answers which, so the app never matches an extension itself. */
void lk_window_open_path (GtkWindow *parent, LkAppModel *model, const char *path);

/* The Add Raster Charts pickers: several `.mbtiles` files at once, or a whole
 * folder of them. Two dialogs because one GtkFileDialog takes files or folders,
 * never both. */
void lk_present_add_raster_dialog (GtkWindow *parent, LkAppModel *model);
void lk_present_add_raster_folder_dialog (GtkWindow *parent, LkAppModel *model);

G_END_DECLS
