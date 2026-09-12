/* library/preview-engine.h — pictures of charts, drawn off to one side.
 *
 * A chart list wants a picture of every chart on it, and the engine the
 * mariner is looking at draws one chart at a time. This opens a SECOND engine
 * with no window, points it at a style, ticks it until the tiles have landed,
 * and reads the pixels back.
 *
 * It is what gives a picture to a style nobody has picked, and to one whose
 * tiles are vector: there is no single tile to fetch for either, so without
 * this they draw a placeholder for as long as the mariner leaves them
 * unpicked.
 *
 * NOTHING HERE REACHES THE CHART ON SCREEN. The style goes in through
 * lookout_chart_link_draw, which keeps no link, selects nothing and writes no
 * list: every other chart-link call saves the list, and a second handle doing
 * that rewrites the list under the handle the mariner is using.
 */
#pragma once

#include <gtk/gtk.h>
#include <lookout.h>

G_BEGIN_DECLS

typedef struct _LkPreviewEngine LkPreviewEngine;

/* The picture for `url`, or NULL when the style could not be drawn: no device
 * to render on, a style the core refuses, or nothing on the frame by the time
 * the patience ran out. */
typedef void (*LkPreviewEngineDone) (const char *url, GdkTexture *picture,
                                    gpointer user_data);

LkPreviewEngine *lk_preview_engine_new (void);
void             lk_preview_engine_free (LkPreviewEngine *self);

/* Draw one style at a point. ONE AT A TIME: this answers FALSE while a render
 * is running, and the caller comes back when it ends. */
gboolean lk_preview_engine_render (LkPreviewEngine *self, const char *url,
                                   double lon, double lat, double zoom,
                                   LkPreviewEngineDone done, gpointer user_data);

gboolean lk_preview_engine_busy (LkPreviewEngine *self);

/* Close the engine and give its device back. The list that opened it calls
 * this as it goes: a second Vulkan device is not something to hold while
 * nobody is looking at a chart list. */
void lk_preview_engine_close (LkPreviewEngine *self);

/* ---- when a render is finished ------------------------------------------- */

/* The count a render keeps as it ticks. */
typedef struct {
  int      ticks;   /* how many frames have been asked for */
  int      settled; /* consecutive ticks with nothing left to do */
  gboolean drawn;   /* a snapshot has come back at least once */
} LkPreviewSettle;

/* Advance the count by one tick, and answer whether the render is finished.
 *
 * The frame loop reports IDLE before the style has even been asked for, so
 * settling counts only after a warm-up. Four settled ticks in a row is the
 * end; so is running out of patience, which is what a style behind a dead
 * host does. */
gboolean lk_preview_settle_step (LkPreviewSettle *state, gboolean idle,
                                 gboolean building, gboolean snapped);

G_END_DECLS
