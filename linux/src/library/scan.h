/* Looking through a folder or an archive for charts.
 *
 * The engine reads a folder or an archive (lookout_scan_read,
 * lookout_scan_zip_read); this copies that into something the shell can hold
 * past the read, so the Charts panel and the bake both read one shape. A folder
 * and a .zip come back the same, with one difference the caller must respect:
 * inside an archive `path` is the ENTRY NAME, not a file, so nothing can open
 * it until the bake has taken it out.
 */
#ifndef LK_CHART_SCAN_H
#define LK_CHART_SCAN_H

#include <glib.h>
#include <lookout.h>

typedef struct {
  char   *path; /* a file, or an entry name when the set is an archive */
  char   *name; /* the dataset name, such as US5MD1MC */
  lookout_file_kind kind;
  int     band; /* 1 to 6; 0 when the name carries no usage band */
  char   *band_name;
  gint64  bytes;
  int     scale;
  gboolean archived; /* `path` lives inside the archive */
} LkScannedCell;

typedef struct {
  char      *root;     /* the folder or archive the mariner picked */
  GPtrArray *cells;    /* LkScannedCell*, the survey and the pictures together */
  int        sources;  /* cells that must bake before they draw */
  int        baked;    /* cells that draw now */
  gint64     bytes;
  char      *producer; /* the agency, when they all agree */
  gboolean   archive;
} LkChartSet;

/* True when `path` names an archive rather than a folder. */
gboolean lk_chart_scan_is_archive (const char *path);

/* Look through `path`. NULL when it cannot be read. Each read is the caller's
 * own copy, so two threads may scan at once. */
LkChartSet *lk_chart_scan (const char *path);

void lk_chart_set_free (LkChartSet *set);
G_DEFINE_AUTOPTR_CLEANUP_FUNC (LkChartSet, lk_chart_set_free)

/* True when this cell must be prepared before the engine can be handed it.
 * Inside an archive that is everything, a baked chart included: it still has
 * to come out. */
gboolean lk_scanned_cell_needs_prepare (const LkScannedCell *cell);

/* True when the cell is a picture rather than the survey. */
gboolean lk_scanned_cell_is_raster (const LkScannedCell *cell);

/* Every file under `dir` whose name ends in `suffix`, however it is cased,
 * depth first and sorted by path. Transfer full strv, never NULL. This is the
 * plain disk walk, not a scan: it reads names, not charts. */
char **lk_files_under (const char *dir, const char *suffix);

#endif /* LK_CHART_SCAN_H */
