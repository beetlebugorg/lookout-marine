/* ui/settings/private.h — the settings window's shared state.
 *
 * The window is built from one unit per page. They all read and write the one
 * struct below, so it lives here rather than in ui/settings/window.c.
 *
 * Nothing outside ui/settings/ includes this header. The public API is
 * ui/settings/window.h.
 */
#pragma once

#include <gtk/gtk.h>
#include <stdbool.h>

#include "model/app-model.h"
#include "model/mariner.h"
#include "plugins/discovery.h"
#include "plugins/registry.h"

G_BEGIN_DECLS

#define LK_FEET_PER_METRE 3.28084

typedef struct {
  LkAppModel *model;
  LkMariner  *mariner;

  /* The sections, as a sidebar beside the pane they choose. The list IS the
   * navigation, as it is on the Mac: a row per section, and the pane it names
   * in the stack. */
  GtkWidget *sidebar;
  GtkWidget *stack;

  /* The raster chart list, rebuilt whenever the installed set changes. The
   * rebuild runs off an idle: a switch here changes the model, and rebuilding
   * inside that would destroy the very switch that is still emitting. */
  GtkWidget *raster_list;
  guint      raster_refresh_id;

  /* The chart-link list, rebuilt off an idle for the same reason: picking a
   * radio here changes the links object, which signals straight back. */
  GtkWidget *links_list;
  guint      links_refresh_id;

  /* The chart library, same discipline. */
  GtkWidget *sets_list;
  guint      sets_refresh_id;

  /* The Display tab's three scheme swatches, so the ring can move to the pick. */
  GtkWidget *scheme_swatches[3];

  /* Depths tab widgets that have to react to each other. */
  GtkWidget *band_preview;
  GtkWidget *shallow_row;
  GtkWidget *deep_row;
  GtkWidget *shading_footer;
  GtkWidget *contours_header;
  GtkWidget *shallow_spin, *safety_spin, *deep_spin, *safety_depth_spin;
  gboolean   updating; /* guard: reprogramming a widget must not re-apply */

  /* The plugins' own controls. The model is read once when the window opens;
   * the status LINES move on their own after that, so the labels showing them
   * are kept and re-lettered in place rather than the page being rebuilt under
   * the mariner's hands. */
  LkPlugins *plugins;
  GPtrArray *status_labels; /* GtkLabel*, not owned: the page owns them */

  /* What is answering on the boat's network, browsed only while this window is
   * up. A browse nobody is watching is a radio left on. */
  LkDiscovery *discovery;
  GPtrArray   *discover_lists; /* const LkPluginList*, the ones that browse */
  guint      status_poll_id;
  /* The row boxes of every list, so adding or removing a row refills one list
   * instead of the window. Keyed "<plugin id>/<list key>". */
  GHashTable *list_boxes;
  GPtrArray  *pending_lists; /* const LkPluginList*, waiting for the idle below */
  guint       list_refill_id;
} LkSettings;

/* Appends whatever a plugin filed under one settings section. Every page ends
 * with a call to it, so a plugin can put a control in any section the app has
 * rather than only in the ones the plugins brought into existence. */
void lk_plugin_fill_tab (GtkWidget *page, LkSettings *settings, const char *tab);

/* True when the mariner reads depths in feet. */
gboolean lk_settings_feet (LkSettings *settings);

G_END_DECLS
