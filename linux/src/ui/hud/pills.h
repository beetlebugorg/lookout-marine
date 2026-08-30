/* ui/hud/pills.h — the progress pills that float at the top centre.
 *
 * Two indicators share that place and never both show: the tessellation
 * indicator while the chart fills in, and the bake pill while charts import.
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

/* The tessellation indicator. It shows while the chart fills in. */
GtkWidget *lk_building_pill_new (LkAppModel *model);

/* Preparing charts: what is being imported, how far in, and a way to stop.
 * Unlike the build indicator this one takes clicks, because a bake of a whole
 * agency's catalogue is measured in hours and a mariner must be able to say
 * that is enough. */
GtkWidget *lk_bake_pill_new (LkAppModel *model);

G_END_DECLS
