/* ui/window-private.h — the main window's shared state.
 *
 * The window is built from several units: the file dialogs, the dev hooks and
 * the startup view each own one part of it. They all read and write the one
 * struct below, so it lives here rather than in ui/window.c.
 *
 * Nothing outside ui/ includes this header. The public API is ui/window.h.
 */
#pragma once

#include <gtk/gtk.h>

#include "model/app-model.h"

G_BEGIN_DECLS

typedef struct {
  LkAppModel *model;
  GtkWidget  *window;
  GtkWidget  *chart_view;
  GtkWidget  *overlay;
  GtkWidget  *search; /* the floating search capsule, an overlay child */
  GtkWidget  *page;   /* opaque fill over the whole window while no chart draws */
  GtkWidget  *loader;
  GtkWidget  *empty_state;
  GtkWidget  *scale_bar;
  GtkWidget  *capsule;

  /* The pick: the mark on the chart and the report beside it, both rebuilt
   * per pick and both NULL while none is open. */
  GtkWidget *pick_marker;
  GtkWidget *pick_report;
  int        pick_width;   /* the report's built width; a resize that leaves it
                              unchanged re-places the card without a rebuild */
  gboolean   pick_compact; /* the report is the bottom sheet, not a callout */
  guint      place_id;     /* re-places the report after a resize, off the layout */
  guint      loader_pulse_id; /* pulses the loader's indeterminate bar while up */
  guint      dark_sync_id;    /* re-reads the chrome's own colour after a theme change */
  guint      chart_set_actions; /* per-set toggle actions the Charts submenu added */

  GtkWidget *settings_window;

  /* What the desktop preferred before the chart's scheme overrode it, so day
   * gives the preference back instead of forcing light on a dark desktop. */
  gboolean desktop_prefers_dark;
} LkWindow;

/* ---- across the unit boundary ------------------------------------------- */
/*
 * These are the window's own functions, not public API. Each is defined in one
 * unit and called from another, so they are declared here instead of being
 * made static in a file that cannot hold every caller.
 */

/* The Open a File picker's completion. A GAsyncReadyCallback, and the window's
 * open-file action is what passes it. ui/open-dialogs.c. */
void lk_open_file_chosen (GObject *source, GAsyncResult *result, gpointer user_data);

G_END_DECLS
