/* ui/charts/coverage-map.c — see ui/charts/coverage-map.h. */
#include "ui/charts/coverage-map.h"

#include "ui/charts/coastline.h"

#include <math.h>

/* One panel: the ground it covers, the regions drawn on it, and what to call
 * it. The lower 48 needs no label; an inset does, so Alaska reads as itself
 * rather than as something floating off the coast of Oregon. */
typedef struct {
  LkMapWindow  window;
  const char  *ids[4]; /* NULL terminated */
  const char  *label;
} LkPanel;

static const LkPanel lk_panel_main = {
  .window = { .west = -132, .east = -64, .south = 20, .north = 52 },
  .ids = { NULL },
  .label = NULL,
};

/* Filled at build time from the region table, so a district the core adds
 * appears without this file changing. Anything not named by an inset draws on
 * the main panel. */
static const LkPanel lk_panel_alaska = {
  .window = { .west = -172, .east = -128, .south = 50.5, .north = 72 },
  .ids = { "d17", NULL },
  .label = "Alaska",
};

static const LkPanel lk_panel_hawaii = {
  .window = { .west = -161, .east = -154, .south = 18.3, .north = 22.6 },
  .ids = { "d14", NULL },
  .label = "Hawaii",
};

/* S-52 shallow blue and GSHHG land, so the picker sits in the app's own
 * palette. The accent is pinned, as the compass rose in ui/startup-view.c
 * pins it: cairo has no way to ask CSS for @accent_color. */
#define LK_WATER_RGBA 0.68, 0.84, 1.00, 0.55
#define LK_LAND_RGBA  0.64, 0.59, 0.33, 0.55
#define LK_PANEL_RGBA 0.93, 0.94, 0.95, 1.00
#define LK_EDGE_RGBA  0.00, 0.00, 0.00, 0.22
#define LK_ACCENT_R 0.039
#define LK_ACCENT_G 0.357
#define LK_ACCENT_B 0.710
/* Water already on the device. It has a hue of its own, because a mariner
 * reads the map before reading any number under it. */
#define LK_HELD_R 0.106
#define LK_HELD_G 0.522
#define LK_HELD_B 0.329

/* The inset widths. Small enough to sit in the Pacific without reaching the
 * coast at the width a sheet gives the map. */
#define LK_INSET_WIDTH 134.0

/* Everything one panel needs to draw and to answer a click. */
typedef struct {
  LkNoaa        *noaa; /* not owned; the page outlives the panel */
  const LkPanel *panel;
} LkPanelState;

static void
lk_panel_state_free (gpointer data)
{
  g_free (data);
}

/* TRUE when this panel draws this region. The main panel draws whatever no
 * inset claims. */
static gboolean
lk_panel_draws (const LkPanel *panel, const char *id)
{
  if (panel != &lk_panel_main)
    {
      for (guint i = 0; panel->ids[i] != NULL; i++)
        if (g_strcmp0 (panel->ids[i], id) == 0)
          return TRUE;
      return FALSE;
    }

  return !lk_panel_draws (&lk_panel_alaska, id) &&
         !lk_panel_draws (&lk_panel_hawaii, id);
}

/* ---- the drawing --------------------------------------------------------- */

/* A rounded rectangle over the whole panel, as the path. */
static void
lk_panel_frame (cairo_t *cr, double width, double height, double radius)
{
  cairo_new_path (cr);
  cairo_arc (cr, radius, radius, radius, G_PI, 1.5 * G_PI);
  cairo_arc (cr, width - radius, radius, radius, 1.5 * G_PI, 2 * G_PI);
  cairo_arc (cr, width - radius, height - radius, radius, 0, 0.5 * G_PI);
  cairo_arc (cr, radius, height - radius, radius, 0.5 * G_PI, G_PI);
  cairo_close_path (cr);
}

/* Every ring of one GSHHG level that reaches into this window, as one path.
 * GSHHG winds land and lakes opposite ways, so filling them together under the
 * non-zero rule would give water inside a lake and land outside it. They are
 * filled in two passes instead, land then lakes. */
static void
lk_panel_rings (cairo_t *cr, const LkMapWindow *window, guint8 level,
                double width, double height)
{
  guint n = 0;
  const LkCoastRing *rings = lk_coastline_rings (&n);

  cairo_new_path (cr);
  for (guint i = 0; i < n; i++)
    {
      const LkCoastRing *ring = &rings[i];

      if (ring->level != level)
        continue;
      if (!lk_map_window_intersects (window, ring->west, ring->east,
                                     ring->south, ring->north))
        continue;

      for (guint p = 0; p < ring->n; p++)
        {
          double x, y;

          lk_map_window_point (window, ring->points[p * 2], ring->points[p * 2 + 1],
                               width, height, &x, &y);
          if (p == 0)
            cairo_move_to (cr, x, y);
          else
            cairo_line_to (cr, x, y);
        }
      cairo_close_path (cr);
    }
}

/* The boxes one region covers, in this panel's coordinates.
 *
 * The catalog's boxes where it has been read, and the region's rough extent
 * until then. A region drawn as one rectangle claims water it does not cover:
 * district 8 runs Texas to the Keys around the Florida peninsula, and its
 * bounding box paints across Miami. */
static void
lk_region_boxes (cairo_t *cr, LkNoaa *noaa, const LkNoaaRegion *region,
                 const LkMapWindow *window, double width, double height)
{
  guint n = 0;
  const LkNoaaBox *boxes = lk_noaa_coverage (noaa, region->id, &n);
  LkNoaaBox rough = { region->west, region->south, region->east, region->north };

  if (boxes == NULL || n == 0)
    {
      boxes = &rough;
      n = 1;
    }

  cairo_new_path (cr);
  for (guint i = 0; i < n; i++)
    {
      double x0, y0, x1, y1;

      lk_map_window_point (window, boxes[i].west, boxes[i].north, width, height, &x0, &y0);
      lk_map_window_point (window, boxes[i].east, boxes[i].south, width, height, &x1, &y1);
      /* A box smaller than a point still has to be visible. */
      cairo_rectangle (cr, MIN (x0, x1), MIN (y0, y1),
                       MAX (fabs (x1 - x0), 1.5), MAX (fabs (y1 - y0), 1.5));
    }
}

static void
lk_panel_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data)
{
  LkPanelState *state = user_data;
  const LkMapWindow *window = &state->panel->window;
  const double radius = state->panel == &lk_panel_main ? 10.0 : 5.0;
  guint n_regions = 0;
  const LkNoaaRegion *regions = lk_noaa_regions (state->noaa, &n_regions);

  lk_panel_frame (cr, width, height, radius);
  cairo_save (cr);
  cairo_clip_preserve (cr);

  cairo_set_source_rgba (cr, LK_PANEL_RGBA);
  cairo_paint (cr);
  cairo_set_source_rgba (cr, LK_WATER_RGBA);
  cairo_paint (cr);

  lk_panel_rings (cr, window, 1, width, height);
  cairo_set_source_rgba (cr, LK_LAND_RGBA);
  cairo_fill (cr);

  /* A lake is water again, drawn over the land it sits in. */
  lk_panel_rings (cr, window, 2, width, height);
  cairo_set_source_rgba (cr, LK_WATER_RGBA);
  cairo_fill (cr);

  /* Filled, with no stroke. Outlining the path draws every cell box in it,
   * which reads as a mesh over the coast rather than as one region. */
  for (guint i = 0; i < n_regions; i++)
    {
      const LkNoaaRegion *region = &regions[i];
      double alpha;

      if (!lk_panel_draws (state->panel, region->id))
        continue;

      lk_region_boxes (cr, state->noaa, region, window, width, height);

      /* A picked region draws in the accent whatever is installed under it,
       * because that is the choice being made now. Water already held draws in
       * the held hue, deeper as more of the region is held. */
      if (lk_noaa_is_picked (state->noaa, region->id))
        {
          cairo_set_source_rgba (cr, LK_ACCENT_R, LK_ACCENT_G, LK_ACCENT_B, 0.50);
        }
      else
        {
          guint32 cells = 0, held = 0;

          lk_noaa_region_held (state->noaa, region->id, &cells, &held);
          if (held > 0 && cells > 0)
            {
              alpha = 0.18 + (0.28 * (double) held / (double) cells);
              cairo_set_source_rgba (cr, LK_HELD_R, LK_HELD_G, LK_HELD_B, alpha);
            }
          else
            {
              cairo_set_source_rgba (cr, LK_ACCENT_R, LK_ACCENT_G, LK_ACCENT_B, 0.16);
            }
        }
      cairo_fill (cr);
    }

  cairo_restore (cr);

  /* The frame again for the outline. cairo_save and cairo_restore do not keep
   * the path, and every fill above consumed it, so the stroke that ended this
   * function drew an empty path and the panel had no edge. */
  lk_panel_frame (cr, width, height, radius);
  cairo_set_source_rgba (cr, LK_EDGE_RGBA);
  cairo_set_line_width (cr, 1.0);
  cairo_stroke (cr);
}

/* ---- the key -------------------------------------------------------------- */

static void
lk_key_swatch_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
                    gpointer user_data)
{
  const double *rgba = user_data;

  cairo_set_source_rgba (cr, rgba[0], rgba[1], rgba[2], rgba[3]);
  cairo_rectangle (cr, 0, 0, width, height);
  cairo_fill (cr);
  cairo_set_source_rgba (cr, 0, 0, 0, 0.25);
  cairo_set_line_width (cr, 1.0);
  cairo_rectangle (cr, 0.5, 0.5, width - 1.0, height - 1.0);
  cairo_stroke (cr);
}

/* One swatch beside the words for it. */
static void
lk_key_item (GtkWidget *row, double r, double g, double b, double a, const char *text)
{
  GtkWidget *swatch = gtk_drawing_area_new ();
  GtkWidget *label = gtk_label_new (text);
  double *rgba = g_new0 (double, 4);

  rgba[0] = r; rgba[1] = g; rgba[2] = b; rgba[3] = a;
  gtk_widget_set_size_request (swatch, 10, 10);
  gtk_widget_set_valign (swatch, GTK_ALIGN_CENTER);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (swatch), lk_key_swatch_draw,
                                  rgba, g_free);
  gtk_widget_add_css_class (label, "caption");
  gtk_widget_add_css_class (label, "dim-label");
  gtk_box_append (GTK_BOX (row), swatch);
  gtk_box_append (GTK_BOX (row), label);
}

GtkWidget *
lk_coverage_key_new (void)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);

  lk_key_item (row, LK_HELD_R, LK_HELD_G, LK_HELD_B, 0.46, "Already downloaded");
  GtkWidget *gap = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_set_size_request (gap, 10, -1);
  gtk_box_append (GTK_BOX (row), gap);
  lk_key_item (row, LK_ACCENT_R, LK_ACCENT_G, LK_ACCENT_B, 0.50, "Picked to download");
  return row;
}

/* ---- the click ----------------------------------------------------------- */

gboolean
lk_region_box_hit (const LkNoaaBox *boxes, guint n, const LkMapWindow *window,
                   double width, double height, double x, double y)
{
  g_return_val_if_fail (window != NULL, FALSE);

  for (guint b = 0; boxes != NULL && b < n; b++)
    {
      double x0, y0, x1, y1;

      lk_map_window_point (window, boxes[b].west, boxes[b].north, width, height, &x0, &y0);
      lk_map_window_point (window, boxes[b].east, boxes[b].south, width, height, &x1, &y1);
      if (x >= MIN (x0, x1) - 1 && x <= MAX (x0, x1) + 1 &&
          y >= MIN (y0, y1) - 1 && y <= MAX (y0, y1) + 1)
        return TRUE;
    }
  return FALSE;
}

/* The region whose own water is under this point, or NULL. Tested against the
 * catalog's boxes, so a click lands on the region rather than on a rectangle
 * around it. Finest first: the boxes overlap along a district line, and the
 * later region wins there, which is the one drawn on top. */
static const LkNoaaRegion *
lk_panel_region_at (LkPanelState *state, double x, double y, double width, double height)
{
  guint n_regions = 0;
  const LkNoaaRegion *regions = lk_noaa_regions (state->noaa, &n_regions);
  const LkNoaaRegion *hit = NULL;

  for (guint i = 0; i < n_regions; i++)
    {
      const LkNoaaRegion *region = &regions[i];
      guint n = 0;
      const LkNoaaBox *boxes;
      LkNoaaBox rough = { region->west, region->south, region->east, region->north };

      if (!lk_panel_draws (state->panel, region->id))
        continue;

      boxes = lk_noaa_coverage (state->noaa, region->id, &n);
      if (boxes == NULL || n == 0)
        {
          boxes = &rough;
          n = 1;
        }

      if (lk_region_box_hit (boxes, n, &state->panel->window, width, height, x, y))
        hit = region;
    }
  return hit;
}

static void
lk_panel_clicked (GtkGestureClick *gesture, int n_press, double x, double y,
                  gpointer user_data)
{
  LkPanelState *state = user_data;
  GtkWidget *area = gtk_event_controller_get_widget (GTK_EVENT_CONTROLLER (gesture));
  const lookout_noaa_state *noaa_state = lk_noaa_state (state->noaa);
  const LkNoaaRegion *region;

  /* Nothing to pick until the catalog says what a pick would cost. */
  if (!noaa_state->have_catalog)
    return;

  region = lk_panel_region_at (state, x, y,
                               gtk_widget_get_width (area),
                               gtk_widget_get_height (area));
  if (region != NULL)
    lk_noaa_toggle (state->noaa, region->id);
}

/* ---- the panels ---------------------------------------------------------- */

static void
lk_coverage_redraw (LkNoaa *noaa, gpointer user_data)
{
  gtk_widget_queue_draw (GTK_WIDGET (user_data));
}

/* One panel: a drawing area that keeps its window's shape. */
static GtkWidget *
lk_panel_new (LkNoaa *noaa, const LkPanel *panel)
{
  GtkWidget *area = gtk_drawing_area_new ();
  LkPanelState *state = g_new0 (LkPanelState, 1);
  GtkGesture *click = gtk_gesture_click_new ();

  state->noaa = noaa;
  state->panel = panel;

  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (area), lk_panel_draw, state,
                                  lk_panel_state_free);
  g_signal_connect_data (click, "pressed", G_CALLBACK (lk_panel_clicked), state, NULL, 0);
  gtk_widget_add_controller (area, GTK_EVENT_CONTROLLER (click));

  /* Every move the service makes can change what this draws: the catalog
   * landing brings the real coverage, and a pick changes a fill. */
  g_signal_connect_object (noaa, "changed", G_CALLBACK (lk_coverage_redraw), area, 0);
  return area;
}

/* An inset keeps a frame and a name of its own. */
static GtkWidget *
lk_inset_new (LkNoaa *noaa, const LkPanel *panel, double width)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
  GtkWidget *area = lk_panel_new (noaa, panel);
  double aspect = lk_map_window_aspect (&panel->window);

  if (panel->label != NULL)
    {
      GtkWidget *label = gtk_label_new (panel->label);

      gtk_widget_add_css_class (label, "caption");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (box), label);
    }

  gtk_widget_set_size_request (area, (int) width, (int) (width / MAX (aspect, 0.1)));
  gtk_box_append (GTK_BOX (box), area);
  gtk_widget_set_halign (box, GTK_ALIGN_START);
  gtk_widget_set_valign (box, GTK_ALIGN_END);
  return box;
}

GtkWidget *
lk_coverage_map_new (LkNoaa *noaa)
{
  GtkWidget *overlay = gtk_overlay_new ();
  GtkWidget *main_area = lk_panel_new (noaa, &lk_panel_main);
  GtkWidget *frame = gtk_aspect_frame_new (0.5, 0.5,
                                           (float) lk_map_window_aspect (&lk_panel_main.window),
                                           FALSE);
  GtkWidget *corners = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);

  g_return_val_if_fail (LK_IS_NOAA (noaa), NULL);

  /* The map keeps its own shape at whatever width it is given, so the coast is
   * never stretched, and the insets sit INSIDE that shape. The aspect frame
   * centres the map in whatever width it is given, so insets placed outside it
   * align to the empty margin and hang off the map's own edge. */
  gtk_overlay_set_child (GTK_OVERLAY (overlay), main_area);
  gtk_aspect_frame_set_child (GTK_ASPECT_FRAME (frame), overlay);

  /* Alaska and Hawaii sit in the Pacific, in the corner of the map. */
  gtk_box_append (GTK_BOX (corners), lk_inset_new (noaa, &lk_panel_alaska, LK_INSET_WIDTH));
  gtk_box_append (GTK_BOX (corners), lk_inset_new (noaa, &lk_panel_hawaii,
                                                   LK_INSET_WIDTH * 0.54));
  gtk_widget_set_halign (corners, GTK_ALIGN_START);
  gtk_widget_set_valign (corners, GTK_ALIGN_END);
  gtk_widget_set_margin_start (corners, 8);
  gtk_widget_set_margin_bottom (corners, 8);
  gtk_overlay_add_overlay (GTK_OVERLAY (overlay), corners);

  gtk_widget_set_hexpand (frame, TRUE);
  return frame;
}

/* ---- the pills ----------------------------------------------------------- */

static void
lk_pill_toggled (GtkToggleButton *button, gpointer user_data)
{
  LkNoaa *noaa = user_data;
  const char *id = g_object_get_data (G_OBJECT (button), "lk-region");
  gboolean on = gtk_toggle_button_get_active (button);

  /* Programming a pill back to the model's answer must not read as a click. */
  if (g_object_get_data (G_OBJECT (button), "lk-updating") != NULL)
    return;
  if (lk_noaa_is_picked (noaa, id) != on)
    lk_noaa_toggle (noaa, id);
}

/* Put every pill back to what the model says, and enable them once there is a
 * catalog to price a pick against. */
/* What of this region is already on the device, on the pill that picks it.
 *
 * A mariner coming back to add more water reads what they already hold before
 * picking. The cost line reports it only after a pick, and only as one number
 * for the whole selection. */
static void
lk_pill_mark_held (GtkWidget *pill, LkNoaa *noaa, const char *id)
{
  GtkWidget *mark = g_object_get_data (G_OBJECT (pill), "lk-held-mark");
  const char *blurb = g_object_get_data (G_OBJECT (pill), "lk-blurb");
  const char *name = g_object_get_data (G_OBJECT (pill), "lk-name");
  guint32 cells = 0, held = 0;
  gboolean known = lk_noaa_region_held (noaa, id, &cells, &held);
  gboolean all = known && cells > 0 && held >= cells;

  /* WHOLE REGIONS ONLY. NOAA files cells across district lines, so downloading
   * one region installs some of its neighbour's, and "42 of 1045" on a pill
   * reads as a transfer that stopped part way. */
  gtk_widget_set_visible (mark, all);
  if (all)
    gtk_widget_add_css_class (pill, "lk-region-held");
  else
    gtk_widget_remove_css_class (pill, "lk-region-held");

  g_autofree char *have = all ? g_strdup_printf ("%s. Installed. %s", name, blurb)
                              : g_strdup_printf ("%s. %s", name, blurb);

  gtk_widget_set_tooltip_text (pill, have);
  gtk_accessible_update_property (GTK_ACCESSIBLE (pill),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL, have, -1);
}

static void
lk_pills_sync (LkNoaa *noaa, gpointer user_data)
{
  GtkWidget *box = user_data;
  gboolean ready = lk_noaa_state (noaa)->have_catalog;

  /* A flow box wraps every child of its own, so the pill is one level down. */
  for (GtkWidget *wrapper = gtk_widget_get_first_child (box);
       wrapper != NULL;
       wrapper = gtk_widget_get_next_sibling (wrapper))
    {
      GtkWidget *pill = GTK_IS_FLOW_BOX_CHILD (wrapper)
                            ? gtk_flow_box_child_get_child (GTK_FLOW_BOX_CHILD (wrapper))
                            : wrapper;
      const char *id = pill == NULL ? NULL : g_object_get_data (G_OBJECT (pill), "lk-region");
      gboolean on;

      if (id == NULL)
        continue;
      on = lk_noaa_is_picked (noaa, id);

      g_object_set_data (G_OBJECT (pill), "lk-updating", GINT_TO_POINTER (1));
      gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON (pill), on);
      g_object_set_data (G_OBJECT (pill), "lk-updating", NULL);

      gtk_widget_set_sensitive (pill, ready);
      if (on)
        gtk_widget_add_css_class (pill, "suggested-action");
      else
        gtk_widget_remove_css_class (pill, "suggested-action");

      lk_pill_mark_held (pill, noaa, id);
    }
}

GtkWidget *
lk_noaa_region_pills_new (LkNoaa *noaa)
{
  GtkWidget *box = gtk_flow_box_new ();
  guint n = 0;
  const LkNoaaRegion *regions;

  g_return_val_if_fail (LK_IS_NOAA (noaa), NULL);

  /* A row that wraps. Nine pills fit two lines at any width the picker
   * reaches, and a flow box is GTK's own answer to that. */
  gtk_flow_box_set_selection_mode (GTK_FLOW_BOX (box), GTK_SELECTION_NONE);
  gtk_flow_box_set_homogeneous (GTK_FLOW_BOX (box), FALSE);
  gtk_flow_box_set_max_children_per_line (GTK_FLOW_BOX (box), 9);
  gtk_flow_box_set_row_spacing (GTK_FLOW_BOX (box), 6);
  gtk_flow_box_set_column_spacing (GTK_FLOW_BOX (box), 6);

  regions = lk_noaa_regions (noaa, &n);
  for (guint i = 0; i < n; i++)
    {
      const LkNoaaRegion *region = &regions[i];
      GtkWidget *pill = gtk_toggle_button_new ();
      GtkWidget *face = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 5);
      GtkWidget *mark = gtk_image_new_from_icon_name ("object-select-symbolic");

      gtk_image_set_pixel_size (GTK_IMAGE (mark), 12);
      gtk_widget_set_visible (mark, FALSE);
      gtk_box_append (GTK_BOX (face), mark);
      gtk_box_append (GTK_BOX (face), gtk_label_new (region->name));
      gtk_button_set_child (GTK_BUTTON (pill), face);

      gtk_widget_add_css_class (pill, "pill");
      /* The name alone says little to a reader who cannot see the map, so the
       * accessible name gives the water the region covers, and what of it is
       * already installed. lk_pill_mark_held writes both. */
      g_object_set_data (G_OBJECT (pill), "lk-held-mark", mark);
      g_object_set_data (G_OBJECT (pill), "lk-name", (gpointer) region->name);
      g_object_set_data (G_OBJECT (pill), "lk-blurb", (gpointer) region->blurb);
      g_object_set_data (G_OBJECT (pill), "lk-region", (gpointer) region->id);
      g_signal_connect (pill, "toggled", G_CALLBACK (lk_pill_toggled), noaa);
      gtk_flow_box_append (GTK_FLOW_BOX (box), pill);
    }

  g_signal_connect_object (noaa, "changed", G_CALLBACK (lk_pills_sync), box, 0);
  lk_pills_sync (noaa, box);
  return box;
}

/* ---- where the catalog stands -------------------------------------------- */

static void
lk_catalog_try_again (GtkButton *button, gpointer user_data)
{
  lk_noaa_refresh (LK_NOAA (user_data));
}

static void
lk_catalog_line_sync (LkNoaa *noaa, gpointer user_data)
{
  GtkWidget *box = user_data;
  const lookout_noaa_state *state = lk_noaa_state (noaa);
  GtkWidget *spinner = g_object_get_data (G_OBJECT (box), "lk-spinner");
  GtkWidget *label = g_object_get_data (G_OBJECT (box), "lk-label");
  GtkWidget *again = g_object_get_data (G_OBJECT (box), "lk-again");
  GtkWidget *note = g_object_get_data (G_OBJECT (box), "lk-note");
  gboolean reading = state->phase == LOOKOUT_NOAA_READING;
  gboolean failed = !reading && state->error[0] != '\0';
  /* A catalog already read outranks a failed read. The core loads the cached
   * catalog before it requests a new one, so a mariner with no network has a
   * working picker and a failed request at the same time. Showing the error
   * first put red text where the catalog summary belongs. The error now shows
   * as a caption below the summary. */
  gboolean stale = failed && state->have_catalog;

  gtk_widget_set_visible (spinner, reading);
  gtk_spinner_set_spinning (GTK_SPINNER (spinner), reading);
  gtk_widget_set_visible (again, failed);
  gtk_widget_set_visible (note, stale);
  if (stale)
    gtk_label_set_text (GTK_LABEL (note), state->error);

  if (reading)
    {
      gtk_label_set_text (GTK_LABEL (label), "Reading NOAA's chart catalog…");
      gtk_widget_remove_css_class (label, "error");
    }
  else if (state->have_catalog)
    {
      g_autofree char *count = g_strdup_printf ("%u", state->catalog_cells);
      g_autofree char *text =
          state->date[0] != '\0'
              ? g_strdup_printf ("%s charts published, catalog dated %s.", count, state->date)
              : g_strdup_printf ("%s charts published.", count);

      gtk_label_set_text (GTK_LABEL (label), text);
      gtk_widget_remove_css_class (label, "error");
    }
  else if (failed)
    {
      gtk_label_set_text (GTK_LABEL (label), state->error);
      gtk_widget_add_css_class (label, "error");
    }
  else
    {
      gtk_label_set_text (GTK_LABEL (label), "");
      gtk_widget_remove_css_class (label, "error");
    }

  gtk_widget_set_visible (box, reading || failed || state->have_catalog);
}

GtkWidget *
lk_noaa_catalog_line_new (LkNoaa *noaa)
{
  /* Two lines: the catalog summary, and below it the reason a read failed
   * over a catalog already loaded. */
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
  GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *spinner = gtk_spinner_new ();
  GtkWidget *label = gtk_label_new ("");
  GtkWidget *note = gtk_label_new ("");
  GtkWidget *again = gtk_button_new_with_label ("Try Again");

  g_return_val_if_fail (LK_IS_NOAA (noaa), NULL);

  gtk_widget_set_valign (spinner, GTK_ALIGN_CENTER);
  gtk_widget_add_css_class (label, "caption");
  gtk_widget_add_css_class (label, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_label_set_wrap (GTK_LABEL (label), TRUE);
  gtk_widget_set_hexpand (label, TRUE);
  gtk_widget_add_css_class (note, "caption");
  gtk_widget_add_css_class (note, "error");
  gtk_label_set_xalign (GTK_LABEL (note), 0.0);
  gtk_label_set_wrap (GTK_LABEL (note), TRUE);
  gtk_widget_set_visible (note, FALSE);
  gtk_widget_set_valign (again, GTK_ALIGN_CENTER);
  g_signal_connect (again, "clicked", G_CALLBACK (lk_catalog_try_again), noaa);

  gtk_box_append (GTK_BOX (line), spinner);
  gtk_box_append (GTK_BOX (line), label);
  gtk_box_append (GTK_BOX (line), again);
  gtk_box_append (GTK_BOX (box), line);
  gtk_box_append (GTK_BOX (box), note);

  g_object_set_data (G_OBJECT (box), "lk-spinner", spinner);
  g_object_set_data (G_OBJECT (box), "lk-label", label);
  g_object_set_data (G_OBJECT (box), "lk-again", again);
  g_object_set_data (G_OBJECT (box), "lk-note", note);

  g_signal_connect_object (noaa, "changed", G_CALLBACK (lk_catalog_line_sync), box, 0);
  lk_catalog_line_sync (noaa, box);
  return box;
}
