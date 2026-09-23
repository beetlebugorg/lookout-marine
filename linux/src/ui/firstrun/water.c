/* ui/firstrun/water.c: see ui/firstrun/water.h. */
#include "ui/firstrun/water.h"

#include <lookout.h>

#define LK_WATER_HEIGHT 210

/* What the panel draws: the core's picture of the plan, in a unit square. */
typedef struct {
  struct lookout_depth_preview preview;
  int                          scheme;
} LkWater;

/* One colour out of the engine's own palette, in the scheme on screen. */
static void
lk_water_s52 (cairo_t *cr, const char *token, int scheme, double alpha)
{
  float rgba[4] = { 0, 0, 0, 0 };

  lookout_s52_color (token, (guint32) scheme, rgba);
  cairo_set_source_rgba (cr, rgba[0], rgba[1], rgba[2], rgba[3] * alpha);
}

/* One depth line across the panel, closed to the bottom so it fills. */
static void
lk_water_shoal (cairo_t *cr, const LkWater *water, int line, double width, double height)
{
  const double *y = water->preview.y[line];

  cairo_new_path (cr);
  cairo_move_to (cr, 0, height);
  for (int i = 0; i < LOOKOUT_DEPTH_PREVIEW_POINTS; i++)
    cairo_line_to (cr, width * i / (LOOKOUT_DEPTH_PREVIEW_POINTS - 1), height * y[i]);
  cairo_line_to (cr, width, height);
  cairo_close_path (cr);
}

static void
lk_water_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
               gpointer user_data)
{
  const LkWater *water = g_object_get_data (G_OBJECT (area), "lk-water");
  const struct lookout_depth_preview *v;
  int scheme;

  if (water == NULL)
    return;
  v = &water->preview;
  scheme = water->scheme;

  /* Deepest first, then each shoal drawn over it. */
  lk_water_s52 (cr, "DEPDW", scheme, 1);
  cairo_paint (cr);

  lk_water_shoal (cr, water, LOOKOUT_DEPTH_LINE_DEEP_CONTOUR, width, height);
  lk_water_s52 (cr, "DEPMD", scheme, 1);
  cairo_fill (cr);

  lk_water_shoal (cr, water, LOOKOUT_DEPTH_LINE_SAFETY_CONTOUR, width, height);
  lk_water_s52 (cr, "DEPMS", scheme, 1);
  cairo_fill (cr);

  lk_water_shoal (cr, water, LOOKOUT_DEPTH_LINE_SAFETY_DEPTH, width, height);
  lk_water_s52 (cr, "DEPVS", scheme, 1);
  cairo_fill (cr);

  /* The safety contour, drawn bold the way S-52 draws the contour the boat is
   * measured against. */
  lk_water_shoal (cr, water, LOOKOUT_DEPTH_LINE_SAFETY_CONTOUR, width, height);
  lk_water_s52 (cr, "DEPCN", scheme, 1);
  cairo_set_line_width (cr, 1.8);
  cairo_stroke (cr);

  lk_water_shoal (cr, water, LOOKOUT_DEPTH_LINE_DEEP_CONTOUR, width, height);
  lk_water_s52 (cr, "DEPCN", scheme, 0.6);
  cairo_set_line_width (cr, 0.8);
  cairo_stroke (cr);

  lk_water_shoal (cr, water, LOOKOUT_DEPTH_LINE_SHORE, width, height);
  lk_water_s52 (cr, "LANDA", scheme, 1);
  cairo_fill_preserve (cr);
  lk_water_s52 (cr, "CSTLN", scheme, 1);
  cairo_set_line_width (cr, 1.0);
  cairo_stroke (cr);

  /* Spot depths across the seabed, each reporting the water it stands in.
   *
   * Bold at or shallower than the safety depth. That is what the safety depth
   * DOES to a chart, and the only way to watch the number move. */
  for (int i = 0; i < LOOKOUT_DEPTH_PREVIEW_SPOTS; i++)
    {
      g_autofree char *text = g_strdup_printf ("%d", v->spot_sounding[i]);
      cairo_text_extents_t extents;
      gboolean shoal = v->spot_bold[i] != 0;
      double x = width * v->spot_x[i];
      double y = height * v->spot_y[i];

      cairo_select_font_face (cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL,
                              shoal ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
      cairo_set_font_size (cr, 10.5);
      cairo_text_extents (cr, text, &extents);
      lk_water_s52 (cr, shoal ? "SNDG2" : "SNDG1", scheme, 1);
      cairo_move_to (cr, x - extents.width / 2, y + extents.height / 2);
      cairo_show_text (cr, text);
    }
}

/* ---- the key ------------------------------------------------------------- */

static void
lk_water_swatch_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
                      gpointer user_data)
{
  const GdkRGBA *colour = g_object_get_data (G_OBJECT (area), "lk-colour");

  if (colour == NULL)
    return;
  cairo_set_source_rgb (cr, colour->red, colour->green, colour->blue);
  cairo_rectangle (cr, 0.5, 0.5, width - 1, height - 1);
  cairo_fill_preserve (cr);
  cairo_set_source_rgba (cr, 0, 0, 0, 0.20);
  cairo_set_line_width (cr, 1.0);
  cairo_stroke (cr);
}

/* One shade, its name, and the water it covers. */
static GtkWidget *
lk_water_key_cell (const char *token, int scheme, const char *name, const char *range)
{
  GtkWidget *cell = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  GtkWidget *head = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 7);
  GtkWidget *swatch = gtk_drawing_area_new ();
  GtkWidget *label = gtk_label_new (name);
  GtkWidget *span = gtk_label_new (range);
  float rgba[4] = { 0, 0, 0, 0 };
  GdkRGBA colour;

  lookout_s52_color (token, (guint32) scheme, rgba);
  colour = (GdkRGBA) { rgba[0], rgba[1], rgba[2], rgba[3] };

  gtk_widget_set_size_request (swatch, 11, 11);
  gtk_widget_set_valign (swatch, GTK_ALIGN_CENTER);
  /* The swatch owns its colour: the key is rebuilt whenever the numbers
   * move. */
  GdkRGBA *owned = g_new (GdkRGBA, 1);
  *owned = colour;
  g_object_set_data_full (G_OBJECT (swatch), "lk-colour", owned, g_free);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (swatch), lk_water_swatch_draw, NULL,
                                  NULL);

  gtk_widget_add_css_class (label, "caption");
  gtk_widget_add_css_class (label, "heading");
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_box_append (GTK_BOX (head), swatch);
  gtk_box_append (GTK_BOX (head), label);

  gtk_widget_add_css_class (span, "dim-label");
  gtk_widget_add_css_class (span, "caption");
  gtk_label_set_xalign (GTK_LABEL (span), 0.0);

  gtk_box_append (GTK_BOX (cell), head);
  gtk_box_append (GTK_BOX (cell), span);
  gtk_widget_set_hexpand (cell, TRUE);
  gtk_widget_add_css_class (cell, "lk-water-key");
  return cell;
}

/* ---- the panel ----------------------------------------------------------- */

/* A depth in the unit on screen, with the unit on it. */
static char *
lk_water_measure (double value, gboolean feet)
{
  char text[LOOKOUT_DEPTH_MAX];

  lookout_fmt_depth (value * (feet ? LOOKOUT_METRES_PER_FOOT : 1.0),
                     feet ? LOOKOUT_DEPTH_FEET : LOOKOUT_DEPTH_METRES, text, sizeof text);
  return g_strdup (text);
}

void
lk_depth_water_set (GtkWidget *water, const struct lookout_depth_plan *plan, gboolean feet,
                    int scheme)
{
  GtkWidget *area = g_object_get_data (G_OBJECT (water), "lk-area");
  GtkWidget *key = g_object_get_data (G_OBJECT (water), "lk-key");
  GtkWidget *child;
  LkWater *numbers;

  g_return_if_fail (area != NULL && key != NULL);

  numbers = g_new0 (LkWater, 1);
  lookout_depth_preview (plan, &numbers->preview);
  numbers->scheme = scheme;
  g_object_set_data_full (G_OBJECT (area), "lk-water", numbers, g_free);

  while ((child = gtk_widget_get_first_child (key)) != NULL)
    gtk_box_remove (GTK_BOX (key), child);

  g_autofree char *safety_text = lk_water_measure (plan->safety_depth, feet);
  g_autofree char *contour_text = lk_water_measure (plan->safety_contour, feet);
  g_autofree char *deep_text = lk_water_measure (plan->deep_contour, feet);
  g_autofree char *unsafe_range = g_strdup_printf ("0 – %s", safety_text);
  g_autofree char *shallow_range = g_strdup_printf ("%s – %s", safety_text, contour_text);
  g_autofree char *medium_range = g_strdup_printf ("%s – %s", contour_text, deep_text);
  g_autofree char *deep_range = g_strdup_printf ("%s +", deep_text);

  struct { const char *token; const char *name; const char *range; } cells[] = {
    { "DEPVS", "Unsafe", unsafe_range },
    { "DEPMS", "Shallow", shallow_range },
    { "DEPMD", "Medium", medium_range },
    { "DEPDW", "Deep", deep_range },
  };

  for (gsize i = 0; i < G_N_ELEMENTS (cells); i++)
    {
      gtk_box_append (GTK_BOX (key),
                      lk_water_key_cell (cells[i].token, scheme, cells[i].name, cells[i].range));
    }

  /* One sentence for a reader who cannot see the panel. */
  g_autofree char *spoken =
      g_strdup_printf ("Water shallower than %s shades as unsafe, and water deeper than "
                       "%s draws in the lightest shade.",
                       contour_text, deep_text);
  gtk_accessible_update_property (GTK_ACCESSIBLE (area), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  spoken, -1);
  gtk_widget_queue_draw (area);
}

GtkWidget *
lk_depth_water_new (void)
{
  GtkWidget *panel = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *area = gtk_drawing_area_new ();
  GtkWidget *key = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);

  gtk_widget_set_size_request (area, -1, LK_WATER_HEIGHT);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (area), lk_water_draw, NULL, NULL);
  gtk_widget_add_css_class (area, "lk-water-panel");

  gtk_box_append (GTK_BOX (panel), area);
  gtk_box_append (GTK_BOX (panel), key);
  gtk_widget_add_css_class (panel, "lk-water");
  gtk_widget_set_overflow (panel, GTK_OVERFLOW_HIDDEN);

  g_object_set_data (G_OBJECT (panel), "lk-area", area);
  g_object_set_data (G_OBJECT (panel), "lk-key", key);
  return panel;
}
