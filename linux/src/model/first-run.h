/* model/first-run.h: setup's state, over the core's lookout_setup. The flow in
 * ui/firstrun/ draws it. */
#pragma once

#include <glib-object.h>
#include <lookout.h>

G_BEGIN_DECLS

/*
 * One decision per step, in the order a mariner is ready to answer it. What
 * this is, where the charts come from, and then the screen that source needs.
 * The model holds the answers and the steps draw them.
 */

/* The step on screen. `source` is the fork: the flow asks which source, then
 * shows the one screen that source needs. */
typedef enum {
  LK_FIRST_RUN_WELCOME,
  LK_FIRST_RUN_SOURCE,
  LK_FIRST_RUN_COVERAGE,
  LK_FIRST_RUN_ONLINE,
  /* Charts arriving and converting. Setup stays open through it, because the
   * chart opens when the import finishes. */
  LK_FIRST_RUN_IMPORTING,
  /* The safety contour, asked once there is a chart to draw it on. */
  LK_FIRST_RUN_DEPTHS,
} LkFirstRunStep;

/* Where the first charts come from.
 *
 * Only the sources the app can follow through. An offer the app cannot honour
 * costs the mariner a step and returns them nowhere. */
typedef enum {
  LK_FIRST_RUN_NOAA,
  LK_FIRST_RUN_ONLINE_CHART,
  LK_FIRST_RUN_FILES,
} LkFirstRunSource;

#define LK_TYPE_FIRST_RUN (lk_first_run_get_type ())
G_DECLARE_FINAL_TYPE (LkFirstRun, lk_first_run, LK, FIRST_RUN, GObject)

LkFirstRun *lk_first_run_new (void);

LkFirstRunStep   lk_first_run_step (LkFirstRun *self);
LkFirstRunSource lk_first_run_source (LkFirstRun *self);
void             lk_first_run_set_source (LkFirstRun *self, LkFirstRunSource source);

/* The core's setup state machine holds the step, the actions and whether
 * setup runs (lookout_setup_* in include/lookout-library.h). Note the facts
 * whenever one moves, and apply an action with lk_first_run_act. Both emit
 * ::changed when the state moves. */
const lookout_setup_state *lk_first_run_state (LkFirstRun *self);
gboolean lk_first_run_showing (LkFirstRun *self);
void     lk_first_run_note (LkFirstRun *self, const lookout_setup_facts *facts);
int      lk_first_run_act (LkFirstRun *self, int action, int arg);

/* Whether setup comes up now. `LOOKOUT_FIRST_RUN` overrides the core, because
 * a screenshot run and a test both need to choose: "0" keeps it down, and a
 * step name raises it on that step. */
gboolean lk_first_run_should_run (LkFirstRun *self);

/* Raise the flow, on the step `LOOKOUT_FIRST_RUN` names or the first one. */
void lk_first_run_begin (LkFirstRun *self);

/* The primary button's words. The online chart step names the chart it keeps,
 * so the button states what the choice does; `chosen` may be NULL. */
const char *lk_first_run_primary_title (LkFirstRun *self, const char *chosen);


/* The design's sheet widths. A step is as wide as its content, and a row of
 * cards needs more room than a paragraph. */
int lk_first_run_sheet_width (LkFirstRunStep step);

/* What the mariner asked NOAA for, kept from the moment they asked: the
 * region names this keeps, and the core's count and size. FALSE before an
 * order. */
void     lk_first_run_set_order_regions (LkFirstRun *self, const char *regions);
gboolean lk_first_run_order (LkFirstRun *self, const char **out_regions,
                            guint32 *out_charts, guint64 *out_bytes);

G_END_DECLS
