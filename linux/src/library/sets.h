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
  char    *name;   /* the folder's own name, so two sets from one office differ */
  char    *detail; /* "512 charts · 3 pictures · Coastal to Harbor · 1.2 GB";
                    * "" until the background scan lands */
  guint    charts;     /* prepared cells, 0 until the scan lands */
  guint    unprepared; /* cells that bake before they draw */
  /* The files the core lists to prepare: `unprepared` less the ones a
   * finished bake refused. */
  guint    to_prepare;
  /* Files a finished bake could not prepare. They stay out of `to_prepare`
   * until a new edition of the cell arrives. */
  guint    refused;
  /* `to_prepare` by usage band, band_todo[0] is band 1. */
  guint    band_todo[6];
  guint    pictures;
  gint64   bytes;
  gboolean scanned;    /* the background scan has read this folder */
  /* TRUE when this app prepared the charts. Removing one of those deletes
   * work that has to be done again, which is worth asking about first. */
  gboolean derived;
  /* TRUE when the NOAA downloader owns this set. Charts go in and out of it
   * through the downloader, not through this list. */
  gboolean managed;
  gboolean on;
  /* The charts this set holds that another switched-on set draws in their
   * place, because both hold the same cell and the other copy is newer or is
   * the downloader's. They stay installed. 0 for a set switched off. */
  guint    held_back;
  /* Cells per usage band, 1 to 6. Index 0 holds the cells whose name states no
   * band, which is every S-101 dataset: those have no place on a scale ramp
   * and the ramp leaves them out. */
  guint    bands[7];
} LkChartSetRow;

/* A usage band in the words the readouts use. "Unknown" outside 1 to 6. */
const char *lk_chart_band_name (int band);

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

/* TRUE when a set is switched on that has something to draw: charts, pictures,
 * or a scan still to land. A set the scan has not read yet counts, so the
 * first-run page never covers a library that is still being read. */
gboolean lk_chart_sets_any_on_drawable (LkChartSets *self);

/* TRUE while a set on the list has not been read yet. A set the scan has not
 * reached composes to nothing, so an open of the library waits for this to go
 * FALSE. The changed callback runs when it does. */
gboolean lk_chart_sets_scanning (LkChartSets *self);

/* Put a source on the list, switched on. Opening a source is also selecting
 * it. TRUE when the list or the switch changed. */
gboolean lk_chart_sets_note (LkChartSets *self, const char *path);

/* Mark a set as the downloader's rather than the mariner's, and read the mark.
 * The NOAA picker states what THIS set holds: counting every installed cell
 * reads an archive the mariner merely lists as water they can delete. */
gboolean lk_chart_sets_set_managed (LkChartSets *self, const char *path, gboolean on);
gboolean lk_chart_sets_is_managed (LkChartSets *self, const char *path);

/* The dataset names the MANAGED sets hold, uppercased and deduplicated.
 * Transfer full. */
char **lk_chart_sets_managed_cell_names (LkChartSets *self);

/* One installed cell, with the edition the file states. */
typedef struct {
  char   *name;
  guint32 edition;
  guint32 update;
} LkChartSetEdition;

/* Every managed cell that states an edition, for the update check. A file on
 * disk does not say which edition it is until the scan has read it, so a set
 * the scan has yet to reach reports none. Transfer full: a GArray of
 * LkChartSetEdition, with the names owned by the array. */
GArray *lk_chart_sets_managed_editions (LkChartSets *self);

/* The files one set still has to prepare, as the core lists them: each file
 * that bakes before it draws and has no prepared chart, or whose prepared
 * chart is older than it. Empty until the core's scan has read the folder.
 * Borrowed until the next call that changes the list. */
const lookout_chart_file *const *lk_chart_sets_to_prepare (LkChartSets *self,
                                                           const char  *path,
                                                           gsize       *out_n);

/* Record how a bake of this set ended, before the bake is freed and before
 * the rescan. A finished bake marks what it could not prepare as refused, and
 * a cancelled one records a stop. */
void lk_chart_sets_note_bake (LkChartSets *self, const char *path,
                              const lookout_bake *bake);

/* Record that the mariner stopped this set's prepare. */
void lk_chart_sets_note_cancel (LkChartSets *self, const char *path);

/* The set whose prepare to finish, or NULL. Borrowed. */
const char *lk_chart_sets_resume (LkChartSets *self);

/* Read a set's folder again. Charts deleted out of a prepared directory, or
 * written into one after the scan read it, are invisible to the composed chart
 * until this runs. FALSE when the set is not on the list. */
gboolean lk_chart_sets_rescan (LkChartSets *self, const char *path);

/* Switch one set into or out of the chart. TRUE when the state changed. */
gboolean lk_chart_sets_set_on (LkChartSets *self, const char *path, gboolean on);

/* Take a set off the list and delete what Lookout prepared from it. The
 * mariner's own folder is never touched. TRUE when the set was installed. */
/* Take a set off the list. FALSE when it was not on it.
 *
 * `out_prepared` receives the directory of charts Lookout prepared from it,
 * which THE CALLER deletes: the delete reports where it has got to, and this
 * unit does not know where a report goes. NULL when nothing was prepared.
 * Free with g_free. */
gboolean lk_chart_sets_remove (LkChartSets *self, const char *path,
                               char **out_prepared);

/* The UNION of the sets switched on — the library the chart opens as.
 * Transfer full strv. */
char **lk_chart_sets_compose (LkChartSets *self);

/* Every survey cell this device holds, by dataset name (US5MD1MC), upper
 * cased, with no duplicates. Transfer full strv.
 *
 * What NOAA's cost and download are told, so a mariner who picks water they
 * have already downloaded fetches what is missing from it rather than all of
 * it again. Across EVERY set, on or off, and whether or not it is prepared
 * yet: the cell is on the device either way. A set added by hand therefore
 * counts the same as one this app downloaded.
 *
 * Pictures are left out. They are not cells and NOAA does not publish them. */
char **lk_chart_sets_cell_names (LkChartSets *self);

/* Every baked cell under a directory, sorted. Transfer full strv. */
char **lk_chart_paths_in_dir (const char *dir);

/* Target to cell list: a folder expands to its cells, a file is itself, and a
 * dangling path or an archive is empty. Transfer full strv. */
char **lk_chart_cell_paths_for (const char *target);

G_END_DECLS
