/* ui/chrome/alerts.h — the alerts the plugins raise, on screen and out loud.
 *
 * A plugin raises an alert with a severity, a title and a body. The core keeps
 * it and hands it over through lookout_alerts_read, already ordered:
 * what nobody has answered first, then the loudest, then the oldest. This
 * shows it, sounds the alarms, and acknowledges one when the mariner asks.
 *
 * AN ALARM IS AUDIBLE AND A WARNING IS VISIBLE. That is the whole of what
 * severity means here. An alarm repeats until somebody acknowledges it. It does
 * not stop because the mariner looked at it, and it does not time out.
 *
 * Acknowledging silences ONE alert. A mariner who has seen the vessel crossing
 * ahead has not seen the one coming up astern.
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

/* The strip over the chart, at the top centre. It shows nothing while no
 * plugin has raised an alert, so it can stand in the overlay for the life of
 * the window. */
GtkWidget *lk_alerts_new (LkAppModel *model);

G_END_DECLS
