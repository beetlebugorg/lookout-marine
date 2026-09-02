/* ui/chart/pick-report.h — the cursor pick report.
 *
 * One object at a time, decoded for the mariner: the operative fact as the
 * title, the attributes in chart language, and the raw S-57 rows one fold
 * away. The copy control puts the raw text on the clipboard, which is how a
 * chart problem gets reported. The GTK twin of PickReport.swift (macOS, iOS)
 * and PickReport.kt (Android).
 *
 * The ENGINE composes the report. lookout_picks_read hands over the page and
 * the source fold as structs, and this copies them into the widgets. Nothing
 * here decides what a mariner reads.
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

/* ---- the decode --------------------------------------------------------- */

/* One row of a report: the page's rows and the source fold's rows have the
 * same shape, as they do in the core. `depth` indents a sub-attribute under
 * its heading. */
typedef struct {
  char    *label;
  char    *value;
  int      depth;
  gboolean file;    /* the value names a file beside the chart */
  gboolean picture; /* …and that file is an image */
} LkPickRow;

/* One picked feature, copied out of a core read so the card can outlive it.
 * Every string is set; a field the page states nothing for is empty. */
typedef struct {
  char      *cls;      /* S-57 object-class acronym, e.g. "LIGHTS" */
  char      *chart;    /* source cell name */
  char      *title;
  char      *subtitle; /* empty when the object has none */
  char      *chip;
  char      *footnote;
  char      *raw;      /* the payload in METRES, as the cell states it */
  GPtrArray *notes;    /* char *      — INFORM, promoted above the rows */
  GPtrArray *rows;     /* LkPickRow * — the page */
  GPtrArray *source;   /* LkPickRow * — the fold */
  lookout_pick_empty empty;
} LkPickDecoded;

LkPickDecoded *lk_pick_decoded_new (const lookout_pick_feature *feature);
void           lk_pick_decoded_free (LkPickDecoded *decoded);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (LkPickDecoded, lk_pick_decoded_free)

/* Every feature of a read, best first, as the card holds them. Transfer full;
 * the array frees its rows. Never NULL. */
GPtrArray *lk_pick_decoded_list (const lookout_picks *picks);

/* The report as plain text: the payload as the cell states it, so a chart
 * problem is reported in the cell's own words. */
char *lk_pick_plain_text (const LkPickDecoded *decoded);

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
