/* lk-raster.h — the raster charts the mariner installed, and which of them are
 * switched on. The Linux twin of RasterCharts.kt and AppModel's raster list.
 *
 * A raster chart is a chart made of pictures the mariner supplies: MBTiles of
 * satellite imagery, or another vendor's chart rendered to tiles. The engine
 * draws them BELOW the ENC, and the ENC drops its opaque depth and land fills
 * where one covers. The mariner keeps the contours, the buoys, the lights and
 * the soundings, and sees the water as well.
 *
 * WHY THE LIST LIVES HERE AND NOT IN THE ENGINE. The engine holds what is open
 * now. A chart set must outlive both a change of ENC and a restart — it is the
 * mariner's own material, gathered for one coast, and half a gigabyte a file.
 * So the list is persisted here and replayed into each chart the engine opens.
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

typedef struct _LkRasterCharts LkRasterCharts;

/* Loads the installed list from the store. */
LkRasterCharts *lk_raster_charts_new (void);
void            lk_raster_charts_free (LkRasterCharts *self);

/* The installed files, in the order added. NULL-terminated, borrowed. */
const char *const *lk_raster_charts_paths (LkRasterCharts *self);
guint              lk_raster_charts_count (LkRasterCharts *self);

/* Install one file. FALSE when the list already holds it. */
gboolean lk_raster_charts_add (LkRasterCharts *self, const char *path);
void     lk_raster_charts_remove (LkRasterCharts *self, const char *path);
void     lk_raster_charts_clear (LkRasterCharts *self);

/* Off keeps the file installed and stops drawing it: a mariner carrying four
 * providers for one coast wants three of them quiet, not deleted. */
void     lk_raster_charts_set_enabled (LkRasterCharts *self, const char *path, gboolean on);
gboolean lk_raster_charts_enabled (LkRasterCharts *self, const char *path);

/* Which SETS the mariner has stopped drawing, by set name. The engine draws a
 * set as it opens it, which is right for a chart being added now and wrong for
 * one being re-installed at launch, so the choice has to be kept here and put
 * back into every chart the engine opens.
 *
 * `note_shown` takes the whole engine account at once: the sets it reports
 * drawn, and the sets it reports not drawn. A name in neither list is left as
 * it stands, so a set on a drive that is unplugged today keeps the answer the
 * mariner gave it. TRUE when something changed, which is also when it was
 * written to disk. */
gboolean lk_raster_charts_shown (LkRasterCharts *self, const char *name);
gboolean lk_raster_charts_note_shown (LkRasterCharts    *self,
                                      const char *const *shown,
                                      const char *const *hidden);

/* One provider's files: what the pill draws as a single picture, and what the
 * settings form switches with one control. */
typedef struct {
  char      *name;
  GPtrArray *paths; /* char*, borrowed from the list */
} LkRasterGroup;

/* Transfer full: a GPtrArray of LkRasterGroup, in the order the files were
 * added. */
GPtrArray *lk_raster_charts_groups (LkRasterCharts *self);

/* What to call the set a file belongs to. It mirrors the engine's own rule
 * (raster.zig setNameFor), so the name in the settings form is the name the
 * pill cycles. */
char *lk_raster_set_name_for (const char *path);

/* Every raster chart under a directory, sorted. `.mbtiles` today: the extension
 * is a hint only, and the engine decides by what the file IS. */
char **lk_raster_charts_in_dir (const char *dir);

G_END_DECLS
