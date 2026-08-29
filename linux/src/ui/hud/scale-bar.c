/* ui/hud/scale-bar.c — the distance bar at the bottom left of the chart. */
#include "ui/hud/scale-bar.h"
#include "util/tether.h"

#include <math.h>

/* ---- the distance bar --------------------------------------------------- */

/* Ground metres per logical point at a 1:1 display scale, from the standard
 * 0.28 mm pixel the engine's denominator is defined against. */
#define LK_METRES_PER_POINT_AT_1_TO_1 0.00028

/* The bar is this wide or less; the distance rounds down to a round number, so
 * the label always reads as one. */
#define LK_SCALE_BAR_TARGET 140.0

static const double LK_NICE_DISTANCES[] = {
  1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000,
  10000, 20000, 50000, 100000, 200000, 500000,
};

typedef struct {
  LkAppModel *model;
  GtkWidget  *root;
  GtkWidget  *label;
  GtkWidget  *bar;
} LkScaleBar;

static void
lk_scale_bar_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

/* Four alternating segments in a hairline box. The chart under it can be light
 * or dark, so the segments alternate the label's own colour with its inverse
 * and the box is drawn in the label's colour. */
static void
lk_scale_bar_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data)
{
  GdkRGBA ink;
  gtk_widget_get_color (GTK_WIDGET (area), &ink);
  gboolean dark_ink = (ink.red + ink.green + ink.blue) / 3.0 < 0.5;

  for (int i = 0; i < 4; i++)
    {
      double x = width * i / 4.0;
      double w = width / 4.0;

      if (i % 2 == 0)
        gdk_cairo_set_source_rgba (cr, &ink);
      else if (dark_ink)
        cairo_set_source_rgba (cr, 1, 1, 1, 0.92);
      else
        cairo_set_source_rgba (cr, 0, 0, 0, 0.75);

      cairo_rectangle (cr, x, 0, w, height);
      cairo_fill (cr);
    }

  gdk_cairo_set_source_rgba (cr, &ink);
  cairo_set_line_width (cr, 1);
  cairo_rectangle (cr, 0.5, 0.5, width - 1, height - 1);
  cairo_stroke (cr);
}

/* The nice round distance the bar draws at this scale, in metres, and the bar
   width it maps to in points. The largest nice distance that fits the target
   width keeps the bar at or under LK_SCALE_BAR_TARGET — the reason the nice
   table reaches down to 1 m. Exposed so a test can check that cap. */
double
lk_scale_bar_nice_metres (double denominator, double *out_width_points)
{
  double metres_per_point = denominator * LK_METRES_PER_POINT_AT_1_TO_1;
  double target = LK_SCALE_BAR_TARGET * metres_per_point;
  double metres = LK_NICE_DISTANCES[0];

  for (gsize i = 0; i < G_N_ELEMENTS (LK_NICE_DISTANCES); i++)
    {
      if (LK_NICE_DISTANCES[i] <= target)
        metres = LK_NICE_DISTANCES[i];
    }

  if (out_width_points != NULL)
    *out_width_points = metres / metres_per_point;
  return metres;
}

static void
lk_scale_bar_update (LkScaleBar *bar)
{
  double denominator = lk_app_model_get_scale_denominator (bar->model);

  if (denominator <= 0)
    {
      gtk_widget_set_visible (bar->root, FALSE);
      return;
    }

  double width_points = 0;
  double metres = lk_scale_bar_nice_metres (denominator, &width_points);

  /* Every nice number of 1000 or more is a whole number of kilometres. */
  g_autofree char *label = metres >= 1000
                               ? g_strdup_printf ("%d km", (int) (metres / 1000))
                               : g_strdup_printf ("%d m", (int) metres);

  gtk_label_set_text (GTK_LABEL (bar->label), label);
  gtk_widget_set_size_request (bar->bar, (int) round (width_points), 6);
  gtk_widget_set_visible (bar->root, TRUE);
}

static void
lk_scale_bar_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  LkScaleBar *bar = user_data;

  if (gtk_widget_in_destruction (bar->root))
    return;
  if (g_str_equal (g_param_spec_get_name (pspec), "scale-denominator") ||
      g_str_equal (g_param_spec_get_name (pspec), "has-chart"))
    lk_scale_bar_update (bar);
}

GtkWidget *
lk_scale_bar_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkScaleBar *bar = g_new0 (LkScaleBar, 1);
  bar->model = model;
  bar->root = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);
  bar->label = gtk_label_new ("");
  bar->bar = gtk_drawing_area_new ();

  gtk_widget_add_css_class (bar->label, "lk-scale-bar-label");
  gtk_label_set_xalign (GTK_LABEL (bar->label), 0);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (bar->bar), lk_scale_bar_draw, NULL, NULL);
  gtk_widget_set_halign (bar->bar, GTK_ALIGN_START);

  gtk_box_append (GTK_BOX (bar->root), bar->label);
  gtk_box_append (GTK_BOX (bar->root), bar->bar);

  /* A drawing, not a control: a drag that starts on it is a drag on the chart. */
  gtk_widget_set_can_target (bar->root, FALSE);
  gtk_widget_set_halign (bar->root, GTK_ALIGN_START);
  gtk_widget_set_valign (bar->root, GTK_ALIGN_END);

  lk_tether (model,
             g_signal_connect_data (model, "notify", G_CALLBACK (lk_scale_bar_notify),
                                    bar, lk_scale_bar_free, 0),
             bar->root);
  lk_scale_bar_update (bar);
  return bar->root;
}
