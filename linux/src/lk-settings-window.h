/* lk-settings-window.h — the S-52 mariner settings.
 *
 * Five tabs: Display / Depths / Text / Charts / Advanced. The Depths tab's band
 * preview makes the S-52 shading model visible (white water starts at the DEEP
 * contour under four-shade), which is otherwise mistaken for a bug.
 */
#pragma once

#include <gtk/gtk.h>

#include "lk-app-model.h"

G_BEGIN_DECLS

GtkWidget *lk_settings_window_new (LkAppModel *model, GtkWindow *parent);

G_END_DECLS
