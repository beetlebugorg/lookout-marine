/* library/sets.h — the installed chart sets.
 *
 * A SET is a folder the mariner added, or one .zip — how a chart agency
 * publishes them. The list answers what is installed and what is being sailed
 * on: switching a set off keeps it installed and takes it out of the chart, and
 * the chart is composed as the UNION of the sets switched on.
 *
 * Every mutator answers whether anything changed. The owner decides what a
 * change means — reopen the chart, tell the windows — so this unit never
 * reaches into the model. The one thing it announces on its own is a
 * background scan landing, through the changed callback.
 */
#pragma once

#include <glib-object.h>

#include "library/scan.h"

G_BEGIN_DECLS

typedef struct _LkChartSets LkChartSets;

/* One row of the list, as a settings page or the first-run page draws it. */
typedef struct {
  char    *path;
  char    *title;  /* the agency when the charts agree on one, else the folder name */
  char    *detail; /* "512 charts · 3 pictures · Coastal to Harbor · 1.2 GB";
                    * "" until the background scan lands */
  guint    charts; /* prepared cells, 0 until the scan lands */
  gboolean on;
} LkChartSetRow;

void lk_chart_set_row_free (LkChartSetRow *row);

/* The library changed on its own: a background scan landed a title and a size.
 * Every other change is answered by the call that made it. */
typedef void (*LkChartSetsChanged) (GObject *owner);

/* Load the list, the switched-off set, and start the metadata scans.
 *
 * `owner` is what this belongs to, and what the changed callback is handed. A
 * scan in flight holds a reference to it, so the owner cannot be finalized
 * while a result is still on its way to the main loop. */
LkChartSets *lk_chart_sets_new (LkChartSetsChanged on_changed, GObject *owner);
void lk_chart_sets_free (LkChartSets *self);

/* Every installed set, in the order added. Transfer full: a GPtrArray of
 * LkChartSetRow. Titles and details fill in as the scans land. */
GPtrArray *lk_chart_sets_rows (LkChartSets *self);

/* The installed paths, borrowed and NULL-terminated. */
const char *const *lk_chart_sets_paths (LkChartSets *self);

/* Is this set switched on? A set that is not listed reads as on. */
gboolean lk_chart_sets_is_on (LkChartSets *self, const char *path);

/* Put a source on the list, switched on. Opening a source is also selecting
 * it. TRUE when the list or the switch changed. */
gboolean lk_chart_sets_note (LkChartSets *self, const char *path);

/* Switch one set into or out of the chart. TRUE when the state changed. */
gboolean lk_chart_sets_set_on (LkChartSets *self, const char *path, gboolean on);

/* Take a set off the list and delete what Lookout prepared from it. The
 * mariner's own folder is never touched. TRUE when the set was installed. */
gboolean lk_chart_sets_remove (LkChartSets *self, const char *path);

/* The UNION of the sets switched on — the library the chart opens as.
 * Transfer full strv. */
char **lk_chart_sets_compose (LkChartSets *self);

/* Every baked cell under a directory, sorted. Transfer full strv. */
char **lk_chart_paths_in_dir (const char *dir);

/* Target to cell list: a folder expands to its cells, a file is itself, and a
 * dangling path or an archive is empty. Transfer full strv. */
char **lk_chart_cell_paths_for (const char *target);

G_END_DECLS
