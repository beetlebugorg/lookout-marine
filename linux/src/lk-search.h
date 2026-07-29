/* lk-search.h — the search bar.
 *
 * Coordinate go-to works (decimal or DMS → recentre); feature/place search is
 * scaffolded "coming soon", pending a tile57 name index.
 */
#pragma once

#include <gtk/gtk.h>

#include "lk-app-model.h"

G_BEGIN_DECLS

GtkWidget *lk_search_bar_new (LkAppModel *model);

G_END_DECLS
