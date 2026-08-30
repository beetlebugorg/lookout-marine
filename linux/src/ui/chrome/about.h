/* ui/chrome/about.h — the About window.
 *
 * What this build is: its name, its version, the chart engine it is pinned to,
 * and the way to its licenses. It says NOT FOR NAVIGATION, because a
 * chartplotter that is not certified has to say so where it says what it is.
 */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* Put the About window on screen. A second call raises the one it already
 * has. */
void lk_about_window_present (GtkWindow *parent);

G_END_DECLS
