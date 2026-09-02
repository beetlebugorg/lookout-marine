/* ui/startup-view.h — the loader and the first-run page.
 *
 * The window builds both once and shows one of them while no chart draws.
 */
#pragma once

#include "ui/window-private.h"

G_BEGIN_DECLS

/* The opening page: a compass rose, a pulsing bar, and three steps. */
GtkWidget *lk_window_build_loader (void);

/* The first-run page: where charts come from, and how to install one. */
GtkWidget *lk_window_build_empty_state (void);

/* One step row, appended to `box`. The opening page and the import panel both
 * show their work as steps, and they show it the same way. */
GtkWidget *lk_loader_step_new (GtkWidget *box);

/* One step of the opening page: what it says, and whether it is waiting (0),
 * running (1) or done (2). The window drives it from the model. */
void lk_loader_step_set (GtkWidget *row, int state,
                         const char *text, const char *detail_text);

/* Pulses the loader's indeterminate bar. A GSourceFunc. */
gboolean lk_window_loader_pulse (gpointer user_data);

/* Rebuild the "Switched off" list on the first-run page. */
void lk_window_refresh_switched_off (LkWindow *self);

G_END_DECLS
