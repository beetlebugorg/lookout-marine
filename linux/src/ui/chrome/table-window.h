/* ui/chrome/table-window.h — a plugin's declared table, as a window.
 *
 * A plugin declares a table in its manifest: a key, a title, the menu it opens
 * from, and TYPED columns. The core hands the declaration over through
 * lookout_tables_read and the rows through lookout_table_rows_read, already in
 * the order they are to be shown. This builds the window and the table, and
 * knows nothing about what any plugin does.
 *
 * UNITS ARE THE SHELL'S. The column type says what a number means: distance is
 * metres, speed metres per second, bearing degrees true, duration seconds. Each
 * is formatted here, in the units of the sea. That is the reverse of the pick
 * report, and it is what lets the core sort a column numerically while the
 * mariner reads knots and nautical miles.
 *
 * THE ORDER IS THE PLUGIN'S FIRST. Every row carries a band, and the core sorts
 * within a band and never across one. A header click therefore reorders the
 * vessels under an alarmed one and never moves it off the top line.
 *
 * A null cell is a dash. Never heard and heard as zero are different values,
 * and the table says which one it has.
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

/* One table a plugin declared. The strings are owned. */
typedef struct {
  char     *plugin;
  char     *key;
  char     *title;
  char     *menu;      /* the menu the declaration asks to be opened from */
  gboolean  locatable; /* the declaration's `at` named a position */
} LkTableSpec;

void lk_table_spec_free (LkTableSpec *spec);

/* Every table the loaded plugins declare, in registry order. Transfer full: a
 * GPtrArray of LkTableSpec. Never NULL; empty when no plugin declares one. */
GPtrArray *lk_table_specs (LkAppModel *model);

/* Put one table's window on screen. A second call for the same declaration
 * raises the window it already has rather than stacking another on it. */
void lk_table_window_present (GtkWindow *parent, LkAppModel *model, const LkTableSpec *spec);

G_END_DECLS
