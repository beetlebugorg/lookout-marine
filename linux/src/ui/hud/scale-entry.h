/* ui/hud/scale-entry.h — the scale entry the readouts capsule opens.
 *
 * Type a scale or pick a navigational purpose band, and the view zooms to it.
 * The twin of ScaleEntryPanel (macOS, iOS) and ScaleEntryDialog (Android).
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

/* The entry as a popover. The caller parents it to the control that opens it. */
GtkWidget *lk_scale_entry_popover_new (LkAppModel *model);

G_END_DECLS
