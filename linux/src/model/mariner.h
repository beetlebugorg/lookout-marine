/* model/mariner.h — the live S-52 mariner state behind the settings form.
 *
 * Wraps the engine's tile57_mariner and edits it in place, so fields the form
 * doesn't surface are preserved untouched. Edits auto-apply (debounced) and save.
 */
#pragma once

#include <gtk/gtk.h>

#include "engine/controller.h"

G_BEGIN_DECLS

#define LK_TYPE_MARINER (lk_mariner_get_type ())
G_DECLARE_FINAL_TYPE (LkMariner, lk_mariner, LK, MARINER, GObject)

LkMariner *lk_mariner_new (LkChartController *controller);

/* Reload from the live chart — call when the form opens. */
void lk_mariner_reload (LkMariner *self);

/* The struct the form edits in place. */
tile57_mariner *lk_mariner_raw (LkMariner *self);

/* Apply and save the form's changes (debounced). */
void lk_mariner_touch (LkMariner *self);

/* Display category as one 0/1/2 axis (Base ⊂ Standard ⊂ Other) over the
 * engine's three booleans. */
int  lk_mariner_get_display_category (LkMariner *self);
void lk_mariner_set_display_category (LkMariner *self, int category);

G_END_DECLS
