/* lk-overlay-pick.h — what the plugins put ON the chart, from the shell's side.
 *
 * A plugin draws a vessel, a layline end or a mark, and gives the symbol a
 * payload: {"title":"…","rows":[["key","value"],…]}. The core draws the symbol;
 * this says what it is.
 *
 * A CLICK ON A SYMBOL PINS ITS BUBBLE, and the chart pick report does not open
 * for the same click. One thing under the finger at a time.
 *
 * The bubble FOLLOWS the object. A target moves, its values change, and one day
 * it ages out or its plugin stops. The pinned object is re-read on every
 * readout tick, so the bubble moves, refreshes and closes itself.
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

/* The card for one payload, as the plugin wrote it. NULL when the JSON carries
 * no title and no rows, which is a symbol with nothing to say. */
GtkWidget *lk_overlay_card_new (const char *payload_json);

/* The bubble pinned to the object the mariner clicked, placed over the chart.
 * It shows nothing while nothing is pinned, so it can stand in the overlay for
 * the life of the window. */
GtkWidget *lk_overlay_bubble_new (LkAppModel *model);

G_END_DECLS
