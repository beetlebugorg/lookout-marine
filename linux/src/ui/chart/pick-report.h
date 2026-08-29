/* ui/chart/pick-report.h — the cursor pick report.
 *
 * One object at a time, decoded for the mariner: the operative fact as the
 * title, the attributes in chart language, and the raw S-57 rows one fold
 * away. The copy control puts the raw text on the clipboard, which is how a
 * chart problem gets reported. The GTK twin of PickReport.swift (macOS, iOS)
 * and PickReport.kt (Android).
 *
 * The ENGINE composes the report. The core emits {"report":…,"s57":…} per
 * feature — the decoded page beside the raw payload — and this parses it.
 * Nothing here decides what a mariner reads. tile57_s57_report does that once,
 * for every shell.
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

/* ---- the decode --------------------------------------------------------- */

/* One row of the engine's report: both halves already in chart language. */
typedef struct {
  char    *label;
  char    *value;
  int      depth;
  gboolean file;    /* the value names a file beside the chart */
  gboolean picture; /* …and that file is an image */
} LkReportRow;

/* One row of the payload as the cell states it, for the fold and the
 * clipboard. A container contributes a heading row with an empty value. */
typedef struct {
  char *name;
  char *value;
  int   depth;
} LkRawRow;

/* Why the body has nothing to read, when it does not. */
typedef enum {
  LK_PICK_BODY_FULL,
  LK_PICK_BODY_NO_ATTRIBUTES,
  LK_PICK_BODY_SOURCE_ONLY,
} LkPickBody;

typedef struct {
  char      *title;
  char      *subtitle; /* NULL when the object has none */
  char      *chip;
  char      *footnote;
  GPtrArray *notes;    /* char *       — INFORM, promoted above the rows */
  GPtrArray *rows;     /* LkReportRow * */
  GPtrArray *raw_rows; /* LkRawRow *   */
  LkPickBody body;
} LkPickDecoded;

LkPickDecoded *lk_pick_decoded_new (const LkPickFeature *feature);
void           lk_pick_decoded_free (LkPickDecoded *decoded);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (LkPickDecoded, lk_pick_decoded_free)

/* The report as plain text: the raw payload, out of the envelope when there is
 * one, so a chart problem is reported in the cell's own words. */
char *lk_pick_plain_text (const LkPickFeature *feature);

/* ---- the card ----------------------------------------------------------- */

/* The report for the model's current pick. Rebuilt per pick, not updated in
 * place: a pick is a new set of objects, and the card's whole shape follows
 * from how many there are. `room` is the height it may use; a longer report
 * scrolls inside it. */
GtkWidget *lk_pick_report_new (LkAppModel *model, int width, int room);

/* The mark on the object of the pick. Never takes a click — the chart under it
 * stays grabbable. */
GtkWidget *lk_pick_marker_new (void);

/* The mark's diameter and the margin the report keeps from the view's edges,
 * in logical points, as on every other shell. */
#define LK_PICK_MARKER_SIZE 34
#define LK_PICK_MARGIN      12

/* The card takes half the free area at most, but never less than this: half of
 * a short window is too little to read a report in. */
#define LK_PICK_MIN_HEIGHT  320

/* ---- placement ---------------------------------------------------------- */

typedef enum {
  LK_CALLOUT_ABOVE, /* the card's floor sits above the mark */
  LK_CALLOUT_BELOW, /* the card's top sits under the mark */
} LkCalloutEdge;

/* Where the report stands, and the height it may use. `y` is the edge that
 * `edge` names; the layout places the opposite edge, so nothing has to measure
 * the card to position it. */
typedef struct {
  double        x;
  double        y;
  LkCalloutEdge edge;
  double        room;
} LkCalloutPlace;

/* Put the report over the pick: centred on the mark, clear of it, and inside
 * the free area the HUD band leaves. The twin of OverlayLayer.calloutLayout
 * (macOS, iOS) and calloutPlacement (Android). */
LkCalloutPlace lk_callout_place (double point_x,
                                 double point_y,
                                 double width,
                                 double view_width,
                                 double view_height,
                                 double hud_band);

/* The report's width for a pick: the detail column, with the object list
 * beside it when the pick found several objects. */
int lk_pick_report_width (guint count, double view_width);

G_END_DECLS
