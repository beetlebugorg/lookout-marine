/* lk-search.h — the search capsule.
 *
 * A field that floats beside the top-left bubble, opened from it or with
 * Ctrl+F. Coordinate go-to works (decimal or DMS → recentre); feature/place
 * search is scaffolded "coming soon", pending a tile57 name index.
 */
#pragma once

#include <gtk/gtk.h>

#include "lk-app-model.h"

G_BEGIN_DECLS

/* The floating capsule, an overlay child the window places top-left. Hidden
 * until opened. */
GtkWidget *lk_search_new (LkAppModel *model);

/* Show or hide the capsule; opening focuses the field, closing clears it. */
void       lk_search_toggle (GtkWidget *widget);

/* Close the capsule if it is open (for the Escape cascade). */
void       lk_search_close (GtkWidget *widget);

/* TRUE while the capsule is on screen. */
gboolean   lk_search_is_open (GtkWidget *widget);

G_END_DECLS
