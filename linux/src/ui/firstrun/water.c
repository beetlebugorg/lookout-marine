/* ui/firstrun/water.c — see ui/firstrun/water.h. */
#include "ui/firstrun/water.h"

#include <lookout.h>
#include <math.h>

/* Where the shore stands, as a fraction of the panel. */
#define LK_WATER_SHORE 0.14
/* How steeply the slope falls away. Shallow water gets most of the panel,
 * because that is where both contours fall. */
#define LK_WATER_SLOPE 2.07
/* How many segments a depth line is drawn with. */
#define LK_WATER_STEPS 48
#define LK_WATER_HEIGHT 210

/* The numbers the panel draws from. */
typedef struct {
  double   safety;
  double   contour;
  double   deep;
  gboolean feet;
  int      scheme;
} LkWater;

/* Each spot depth: its depth as a multiple of the safety contour, and how far
 * along its line it stands.
 *
 * MULTIPLES, so a sounding holds both its place and its number while the
 * mariner works, and moves only when the contour steps to the next one the
 * survey draws. The shading is what answers every keystroke. */
static const struct { double of_contour; double along; } lk_water_spots[] = {
  { 0.12, 0.28 }, { 0.30, 0.68 }, { 0.45, 0.14 }, { 0.62, 0.50 },
  { 0.80, 0.84 }, { 1.00, 0.32 }, { 1.22, 0.62 }, { 1.48, 0.20 },
  { 1.78, 0.44 }, { 2.12, 0.78 }, { 2.50, 0.34 }, { 2.85, 0.58 },
};

double
lk_depth_water_reach (double depth, double floor)
{
  double fraction;

  if (floor <= 0)
    return LK_WATER_SHORE;
  fraction = pow (CLAMP (depth / floor, 0, 1), 1.0 / LK_WATER_SLOPE);
  return LK_WATER_SHORE + (1.0 - LK_WATER_SHORE) * fraction;
}

/* One colour out of the engine's own palette, in the scheme on screen. */
static void
lk_water_s52 (const char *token, int scheme, double fallback[3], cairo_t *cr)
{
  float rgba[4] = { 0, 0, 0, 1 };

  if (lookout_s52_color (token, (guint32) scheme, rgba))
    cairo_set_source_rgb (cr, rgba[0], rgba[1], rgba[2]);
  else
    cairo_set_source_rgb (cr, fallback[0], fallback[1], fallback[2]);
}

/* A point on one depth line, `u` of the way across.
 *
 * Every line is the SAME SHAPE, moved up by its depth, so each band keeps its
 * share of the panel from edge to edge. Scaling the curve by the depth instead
 * gathered them all into one corner. */
static void
lk_water_point (double width, double height, double reach, double u,
                double *out_x, double *out_y)
{
  /* The wave and the rise to the right are the same for every line, so the
   * lines never cross and the bands never pinch. */
  double wave = 0.055 * sin (u * G_PI * 1.7 + 0.4) + 0.045 * u;

  *out_x = u * width;
  *out_y = height - height * reach + height * wave;
}

/* One depth line across the panel, closed to the bottom so it fills. */
static void
lk_water_shoal (cairo_t *cr, double width, double height, double reach)
{
  double x, y;

  cairo_new_path (cr);
  cairo_move_to (cr, 0, height);
  for (int i = 0; i <= LK_WATER_STEPS; i++)
    {
      lk_water_point (width, height, reach, (double) i / LK_WATER_STEPS, &x, &y);
      cairo_line_to (cr, x, y);
    }
  cairo_line_to (cr, width, height);
  cairo_close_path (cr);
}

/* A sounding in the unit on screen, rounded up: whole numbers, the way the two
 * contours read. */
static char *
lk_water_sounding (double value)
{
  return g_strdup_printf ("%d", (int) ceil (value));
}

static void
lk_water_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
               gpointer user_data)
{
  const LkWater *water = g_object_get_data (G_OBJECT (area), "lk-water");
  double shallow_rgb[3] = { 0.38, 0.72, 1.00 };
  double medium_rgb[3] = { 0.51, 0.79, 1.00 };
  double deep_rgb[3] = { 0.65, 0.85, 0.98 };
  double deepest_rgb[3] = { 0.79, 0.93, 1.00 };
  double land_rgb[3] = { 0.75, 0.75, 0.56 };
  double floor;

  if (water == NULL)
    return;

  /* Half again past the deep contour, so the last shade has water in it. */
  floor = water->deep * 1.5;

  /* Deepest first, then each shoal drawn over it. */
  lk_water_s52 ("DEPDW", water->scheme, deepest_rgb, cr);
  cairo_paint (cr);

  lk_water_shoal (cr, width, height, lk_depth_water_reach (water->deep, floor));
  lk_water_s52 ("DEPMD", water->scheme, deep_rgb, cr);
  cairo_fill (cr);

  lk_water_shoal (cr, width, height, lk_depth_water_reach (water->contour, floor));
  lk_water_s52 ("DEPMS", water->scheme, medium_rgb, cr);
  cairo_fill (cr);

  lk_water_shoal (cr, width, height, lk_depth_water_reach (water->safety, floor));
  lk_water_s52 ("DEPVS", water->scheme, shallow_rgb, cr);
  cairo_fill (cr);

  /* The safety contour, drawn bold the way S-52 draws the contour the boat is
   * measured against. */
  lk_water_shoal (cr, width, height, lk_depth_water_reach (water->contour, floor));
  cairo_set_source_rgba (cr, 0, 0, 0, 0.45);
  cairo_set_line_width (cr, 1.8);
  cairo_stroke (cr);

  lk_water_shoal (cr, width, height, lk_depth_water_reach (water->deep, floor));
  cairo_set_source_rgba (cr, 0, 0, 0, 0.18);
  cairo_set_line_width (cr, 0.8);
  cairo_stroke (cr);

  lk_water_shoal (cr, width, height, LK_WATER_SHORE);
  lk_water_s52 ("LANDA", water->scheme, land_rgb, cr);
  cairo_fill_preserve (cr);
  cairo_set_source_rgba (cr, 0, 0, 0, 0.45);
  cairo_set_line_width (cr, 1.0);
  cairo_stroke (cr);

  /* Spot depths across the seabed, each reporting the water it stands in.
   *
   * Bold at or shallower than the safety depth. That is what the safety depth
   * DOES to a chart, and the only way to watch the number move. */
  cairo_select_font_face (cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL,
                          CAIRO_FONT_WEIGHT_NORMAL);
  for (gsize i = 0; i < G_N_ELEMENTS (lk_water_spots); i++)
    {
      double depth = water->contour * lk_water_spots[i].of_contour;
      double reach = lk_depth_water_reach (depth, floor);
      double x, y;
      g_autofree char *text = lk_water_sounding (depth);
      cairo_text_extents_t extents;
      gboolean shoal = depth <= water->safety;

      lk_water_point (width, height, reach, lk_water_spots[i].along, &x, &y);
      cairo_select_font_face (cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL,
                              shoal ? CAIRO_FONT_WEIGHT_BOLD : CAIRO_FONT_WEIGHT_NORMAL);
      cairo_set_font_size (cr, 10.5);
      cairo_text_extents (cr, text, &extents);
      cairo_set_source_rgba (cr, 0, 0, 0, shoal ? 0.80 : 0.55);
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
lk_water_key_cell (const char *token, int scheme, double fallback[3], const char *name,
                   const char *range)
{
  GtkWidget *cell = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  GtkWidget *head = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 7);
  GtkWidget *swatch = gtk_drawing_area_new ();
  GtkWidget *label = gtk_label_new (name);
  GtkWidget *span = gtk_label_new (range);
  float rgba[4] = { 0, 0, 0, 1 };
  GdkRGBA colour;

  if (lookout_s52_color (token, (guint32) scheme, rgba))
    colour = (GdkRGBA) { rgba[0], rgba[1], rgba[2], 1 };
  else
    colour = (GdkRGBA) { fallback[0], fallback[1], fallback[2], 1 };

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

static char *
lk_water_measure (double value, gboolean feet)
{
  double rounded = round (value * 10) / 10;
  const char *unit = feet ? "ft" : "m";

  if (rounded == round (rounded))
    return g_strdup_printf ("%d %s", (int) rounded, unit);
  return g_strdup_printf ("%.1f %s", rounded, unit);
}

void
lk_depth_water_set (GtkWidget *water, double safety, double contour, double deep,
                    gboolean feet, int scheme)
{
  GtkWidget *area = g_object_get_data (G_OBJECT (water), "lk-area");
  GtkWidget *key = g_object_get_data (G_OBJECT (water), "lk-key");
  GtkWidget *child;
  LkWater *numbers;

  g_return_if_fail (area != NULL && key != NULL);

  numbers = g_new0 (LkWater, 1);
  numbers->safety = safety;
  numbers->contour = contour;
  numbers->deep = deep;
  numbers->feet = feet;
  numbers->scheme = scheme;
  g_object_set_data_full (G_OBJECT (area), "lk-water", numbers, g_free);

  while ((child = gtk_widget_get_first_child (key)) != NULL)
    gtk_box_remove (GTK_BOX (key), child);

  g_autofree char *safety_text = lk_water_measure (safety, feet);
  g_autofree char *contour_text = lk_water_measure (contour, feet);
  g_autofree char *deep_text = lk_water_measure (deep, feet);
  g_autofree char *unsafe_range = g_strdup_printf ("0 – %s", safety_text);
  g_autofree char *shallow_range = g_strdup_printf ("%s – %s", safety_text, contour_text);
  g_autofree char *medium_range = g_strdup_printf ("%s – %s", contour_text, deep_text);
  g_autofree char *deep_range = g_strdup_printf ("%s +", deep_text);

  struct { const char *token; double fallback[3]; const char *name; const char *range; }
  cells[] = {
    { "DEPVS", { 0.38, 0.72, 1.00 }, "Unsafe", unsafe_range },
    { "DEPMS", { 0.51, 0.79, 1.00 }, "Shallow", shallow_range },
    { "DEPMD", { 0.65, 0.85, 0.98 }, "Medium", medium_range },
    { "DEPDW", { 0.79, 0.93, 1.00 }, "Deep", deep_range },
  };

  for (gsize i = 0; i < G_N_ELEMENTS (cells); i++)
    {
      gtk_box_append (GTK_BOX (key),
                      lk_water_key_cell (cells[i].token, scheme, cells[i].fallback,
                                         cells[i].name, cells[i].range));
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
