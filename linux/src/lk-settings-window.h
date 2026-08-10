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

/* `tab` names the section to open on, by its title ("Connections", "Plugins").
 * NULL or an empty string opens on the first, which is what the gear bubble
 * asks for. A fix-it names the section that fixes the thing it is about: the
 * position readout's "Configure GPS" opens on Connections, because that is
 * where a position source is added. A name no section carries is ignored. */
GtkWidget *lk_settings_window_new (LkAppModel *model, GtkWindow *parent, const char *tab);

G_END_DECLS
