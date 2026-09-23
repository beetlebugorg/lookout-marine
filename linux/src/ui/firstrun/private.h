/* ui/firstrun/private.h: setup's shared state.
 *
 * The flow is built from one unit per step. They all read the one model below
 * and write into the one struct, so both live here rather than in flow.c.
 *
 * Nothing outside ui/firstrun/ includes this header. The public API is
 * ui/firstrun/flow.h.
 */
#pragma once

#include "model/app-model.h"
#include "model/mariner.h"

#include <gtk/gtk.h>
#include "ui/caption.h"

G_BEGIN_DECLS

/* ---- the model ----------------------------------------------------------- */
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


/* Whether the depth step has been shown in this run. FALSE the first time it
 * is asked, and TRUE from then on, so the step seeds the boat and the unit
 * once and leaves the mariner's own answers alone after that. */
gboolean lk_first_run_asked_depths (LkFirstRun *self);

/* ---- the flow ------------------------------------------------------------ */

typedef struct {
  LkAppModel *model;    /* not owned */
  LkFirstRun *flow;     /* owned */
  LkMariner  *mariner;  /* owned: the depth step's own, bound to the chart */

  GtkWidget *page;      /* the scroller the whole card sits in */
  GtkWidget *card;
  GtkWidget *body;      /* the step's own content, replaced per step */
  GtkWidget *footnote;
  GtkWidget *back;
  GtkWidget *stop;
  GtkWidget *later;
  GtkWidget *primary;

  /* The footer has two shapes. Every step but the first puts its actions in
   * a row at the right of a bar. The welcome step centers the primary action
   * under the prose with Set Up Later below it, because it has no previous
   * step and a lone Continue in the corner of a 640 point sheet reads as a
   * half filled form. `centered` is the shape on screen now. */
  GtkWidget *bar;
  GtkWidget *actions;
  GtkWidget *column;
  gboolean   centered;
} LkFirstRunFlow;

/* The step's content. Each unit builds one, and the flow puts it in the
 * card. */
GtkWidget *lk_first_run_welcome_new (LkFirstRunFlow *flow);
GtkWidget *lk_first_run_source_new (LkFirstRunFlow *flow);
GtkWidget *lk_first_run_coverage_new (LkFirstRunFlow *flow);
GtkWidget *lk_first_run_online_new (LkFirstRunFlow *flow);
GtkWidget *lk_first_run_importing_new (LkFirstRunFlow *flow);

/* Read the import again, into the step already on the card. The bake reports
 * several times a second, and a rebuild per report restarted the spinner. Does
 * nothing for a step built by another unit. */
void lk_first_run_importing_sync (GtkWidget *step);

/* The online step's error line, which changes while the step stands: a link
 * is resolved after Continue is pressed. */
void lk_first_run_online_sync (GtkWidget *step);

GtkWidget *lk_first_run_depths_new (LkFirstRunFlow *flow);

/* Read the footer again: the primary action's words, whether it can act, and
 * the line beside it. A step calls this when its own state moves. */
void lk_first_run_refresh_footer (LkFirstRunFlow *flow);

/* ---- the pieces every step is built from --------------------------------- */

/* A step's heading: what it asks, and the sentence under it. */
GtkWidget *lk_step_heading (const char *title, const char *blurb);

/* One fact on the welcome page: an icon, a claim, and what it means. */
GtkWidget *lk_step_fact (const char *icon_name, const char *title, const char *blurb);

/* A pick-one card: the icon, the name, the description, and the mark on the
 * chosen one. A BUTTON, not a box with a click gesture: a box is invisible to
 * the keyboard and to the accessibility tree, and this control decides what
 * the rest of setup asks. */
GtkWidget *lk_step_card (const char *icon_name, const char *title, const char *blurb,
                        gboolean recommended, gboolean picked);

/* The publisher's warning, in the publisher's terms. Amber, and shaped
 * differently from an ordinary note, so it separates from the page at a
 * glance. */
GtkWidget *lk_step_warning (const char *lead, const char *body);

/* A note under a step: an icon and a line, with markup for a link. */
GtkWidget *lk_step_note (const char *icon_name, const char *markup);

G_END_DECLS
