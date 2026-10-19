/* ui/work-panel.h: what a long job says while it runs.
 *
 * A NOAA download, an import and a removal report the same things: what the
 * job is, how far it has got, how long is left, and a bar. The HUD pill, the
 * setup step and the Charts pane each draw them.
 *
 * Every part hides when it has nothing to say, so a caller passes the ones it
 * shows and NULL for the rest. The bar pulses while `total` is 0: a
 * determinate bar with nothing in it reads as stuck, which is what looking
 * through a large folder looked like.
 */
#pragma once

#include <gtk/gtk.h>

/* `action` is the button beside the title, for a job that can be stopped, or
 * NULL for one that runs to the end. */
GtkWidget *lk_work_panel_new (const char *action, GCallback on_click,
                              gpointer user_data);

/* What the panel reads now. `title` and `detail` share the line above the bar,
 * `percent` and `left` the line under it. */
void lk_work_panel_show (GtkWidget *panel, const char *title, const char *detail,
                         const char *percent, const char *left, int done, int total);
