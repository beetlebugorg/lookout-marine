/* Turning raw S-57 cells and BSB sheets into charts the app can draw.
 *
 * A cell as a hydrographic office publishes it is the survey, not a picture of
 * it. The app draws baked archives, so a folder of .000 cells is baked once on
 * the way in. tile57 does the work; this chooses the order, runs it off the
 * main thread, reports where it has got to, and stops when the mariner says
 * stop.
 *
 * The core runs it: lookout_bake owns the order, the worker cap, the three
 * phases and the cancel. What is here is the directory this app prepares into,
 * a poll that feeds the pill, and the words that pill reads.
 *
 * The source is never written to: it may be a read-only disc or a drive that
 * goes away. Everything prepared lands under this app's own data directory,
 * which is also what makes it safe to delete again.
 */
#ifndef LK_CHART_BAKE_H
#define LK_CHART_BAKE_H

#include "library/scan.h"

#include <glib.h>

typedef struct {
  int         done;
  int         total;
  const char *name;   /* the set being worked on; borrowed for the call */
  double      elapsed; /* seconds since the work started */
} LkBakeProgress;

/* The fraction done, 0 when nothing is known yet. */
double lk_bake_progress_fraction (const LkBakeProgress *p);

/* What this work is called, wherever it is shown. One definition, so the
 * chart window and the Charts panel cannot disagree about a removal being
 * called an import. Free with g_free. */
char *lk_bake_progress_title (const LkBakeProgress *p);

/* What is left, from the rate so far, or NULL until there is enough to say.
 * A removal is not timed: it is seconds of disk work, and a countdown on
 * something already over by the time it is read is noise. Free with g_free. */
char *lk_bake_progress_remaining (const LkBakeProgress *p);

typedef struct _LkChartBake LkChartBake;

/* Both run on the main thread. `out_dir` is NULL when the bake failed; a
 * CANCELLED bake is not a failure, because whatever landed is a usable
 * library, so it still reports its directory. */
typedef void (*LkBakeProgressFunc) (const LkBakeProgress *progress, gpointer user_data);
typedef void (*LkBakeDoneFunc) (const char *out_dir, guint baked, gpointer user_data);

/* Bake everything in `set` that needs preparing, out of `source`. NULL when
 * there is nothing to do or the output directory cannot be made. The set is
 * borrowed for the length of the call only. */
LkChartBake *lk_chart_bake_start (const char        *source,
                                  const LkChartSet  *set,
                                  LkBakeProgressFunc on_progress,
                                  LkBakeDoneFunc     on_done,
                                  gpointer           user_data);

/* Ask the bake to stop. tile57 stops at the next chart boundary, so this lands
 * within roughly one chart's bake time, not instantly. */
void lk_chart_bake_cancel (LkChartBake *bake);

/* Join the worker and free the job. Call when the done callback has fired, or
 * to tear down a running bake (it is cancelled first and this blocks up to
 * about one chart's bake time). MAIN THREAD only: pending progress posts are
 * disarmed here and drain on the same loop. */
void lk_chart_bake_destroy (LkChartBake *bake);

/* Everything this app prepared for itself, and nothing else. */
const char *lk_chart_bake_root (void);

/* True when this app prepared the charts at `path`. */
gboolean lk_chart_bake_is_derived (const char *path);

/* Where charts prepared from `source` live, whether or not any have been.
 * Free with g_free. */
char *lk_chart_bake_prepared_dir (const char *source);

/* Delete charts this app prepared. Refuses any path it did not make, so a
 * mariner's own folder can never be deleted by removing a set. */
gboolean lk_chart_bake_delete_derived (const char *path);

/* Throw away what a previous run renamed but did not finish deleting. Without
 * this, quitting mid-delete leaves gigabytes that nothing will mention again. */
void lk_chart_bake_sweep_trash (void);

#endif /* LK_CHART_BAKE_H */
