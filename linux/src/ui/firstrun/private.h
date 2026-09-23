/* ui/firstrun/private.h: setup's shared state.
 *
 * The flow is built from one unit per step. They all read the one model,
 * model/first-run.h, and write into the one struct below.
 *
 * Nothing outside ui/firstrun/ includes this header. The public API is
 * ui/firstrun/flow.h.
 */
#pragma once

#include "model/app-model.h"
#include "model/first-run.h"
#include "model/mariner.h"

#include <gtk/gtk.h>
#include "ui/caption.h"

G_BEGIN_DECLS

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
