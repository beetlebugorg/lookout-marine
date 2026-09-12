/* ui/firstrun/flow.h — setup, over the running app.
 *
 * The first thing a mariner sees when there is nothing to draw: what this is,
 * where the charts come from, and the one screen that source needs.
 *
 * A CARD OVER THE CHART, in the window's own overlay. The app keeps running
 * behind it: the chart stays open and the plugins keep running, so Set Up
 * Later returns the mariner to a working app.
 */
#pragma once

#include "model/app-model.h"

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* Build the page. It starts hidden; the window raises it through
 * lk_first_run_consider. */
GtkWidget *lk_first_run_page_new (LkAppModel *model);

/* Raise setup when the app has settled on having nothing to draw.
 *
 * Called whenever the answer can have changed rather than once at launch:
 * nothing-to-draw is false for the first moment of every launch while the scan
 * reads the library, and raising the flow on that puts it over a mariner's own
 * charts. Does nothing when it is already up. */
void lk_first_run_consider (GtkWidget *page);

/* TRUE while setup is on screen. The window asks, because the page it covers
 * has chrome of its own to keep down. */
gboolean lk_first_run_page_showing (GtkWidget *page);

G_END_DECLS
