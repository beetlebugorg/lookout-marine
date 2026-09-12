/* ui/charts/band-ramp.c — see ui/charts/band-ramp.h. */
#include "ui/charts/band-ramp.h"

#include "library/sets.h"

#include <string.h>

/* A hairline between the segments. Four of the six bands are the pale end of
 * the ramp, and next to each other in a 9 point bar they read as one stripe. */
#define LK_RAMP_HAIR 1.0
/* The narrowest a band draws. */
#define LK_RAMP_LEAST 4.0
#define LK_RAMP_HEIGHT 9

void
lk_band_ramp_color (int band, double *out_r, double *out_g, double *out_b)
{
  /* #2F8FE0, #61B7FF, #82CAFF, #A7D9FB, #C9EDFF, #E4F5FF. */
  static const double ramp[6][3] = {
    { 0.184, 0.561, 0.878 }, /* band 6, berthing */
    { 0.380, 0.718, 1.000 }, /* band 5, harbour */
    { 0.510, 0.792, 1.000 }, /* band 4, approach */
    { 0.655, 0.851, 0.984 }, /* band 3, coastal */
    { 0.788, 0.929, 1.000 }, /* band 2, general */
    { 0.894, 0.961, 1.000 }, /* band 1, overview */
  };
  int at = band >= 1 && band <= 6 ? 6 - band : 5;

  if (out_r != NULL)
    *out_r = ramp[at][0];
  if (out_g != NULL)
    *out_g = ramp[at][1];
  if (out_b != NULL)
    *out_b = ramp[at][2];
}

guint
lk_band_ramp_count (const guint bands[7])
{
  guint n = 0;

  for (int band = 1; band <= 6; band++)
    if (bands[band] > 0)
      n++;
  return n;
}

static guint
lk_band_ramp_total (const guint bands[7])
{
  guint sum = 0;

  for (int band = 1; band <= 6; band++)
    sum += bands[band];
  return sum;
}

double
lk_band_ramp_width (const guint bands[7], int band, double room)
{
  guint sum = lk_band_ramp_total (bands);
  double owed = 0, spare = 0, mine;

  if (sum == 0 || room <= 0 || band < 1 || band > 6 || bands[band] == 0)
    return 0;

  /* What every band is owed over the floor, and what the wide ones have to
   * spare. A band under the floor is raised to it; the rest give up their
   * share of that in proportion. */
  for (int i = 1; i <= 6; i++)
    {
      double raw;

      if (bands[i] == 0)
        continue;
      raw = room * bands[i] / sum;
      if (raw < LK_RAMP_LEAST)
        owed += LK_RAMP_LEAST - raw;
      else
        spare += raw - LK_RAMP_LEAST;
    }

  mine = room * bands[band] / sum;
  if (mine < LK_RAMP_LEAST)
    return LK_RAMP_LEAST;
  if (spare <= 0)
    return mine;
  return mine - (mine - LK_RAMP_LEAST) * MIN (owed / spare, 1.0);
}

/* ---- the bar ------------------------------------------------------------- */

static void
lk_band_bar_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
                  gpointer user_data)
{
  const guint *bands = g_object_get_data (G_OBJECT (area), "lk-bands");
  guint n = bands == NULL ? 0 : lk_band_ramp_count (bands);
  double radius = height / 2.0;
  double room, x = 0;

  if (n == 0)
    return;

  room = width - LK_RAMP_HAIR * (n - 1);
  if (room <= 0)
    return;

  /* Rounded, and clipped to it: the pale end of the ramp needs an edge
   * against the page. */
  cairo_new_path (cr);
  cairo_arc (cr, radius, radius, radius, 0.5 * G_PI, 1.5 * G_PI);
  cairo_arc (cr, width - radius, radius, radius, 1.5 * G_PI, 0.5 * G_PI);
  cairo_close_path (cr);
  cairo_save (cr);
  cairo_clip_preserve (cr);

  /* The hairline shows through as the gap between the segments. */
  cairo_set_source_rgba (cr, 0, 0, 0, 0.20);
  cairo_paint (cr);

  /* Finest first, so the bar runs from the deep end of the ramp to the pale. */
  for (int band = 6; band >= 1; band--)
    {
      double r, g, b;
      double segment = lk_band_ramp_width (bands, band, room);

      if (segment <= 0)
        continue;
      lk_band_ramp_color (band, &r, &g, &b);
      cairo_set_source_rgb (cr, r, g, b);
      cairo_rectangle (cr, x, 0, segment, height);
      cairo_fill (cr);
      x += segment + LK_RAMP_HAIR;
    }

  cairo_restore (cr);
  cairo_set_source_rgba (cr, 0, 0, 0, 0.25);
  cairo_set_line_width (cr, 1.0);
  cairo_stroke (cr);
}

/* ---- the legend ---------------------------------------------------------- */

static void
lk_band_swatch_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
                     gpointer user_data)
{
  int band = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (area), "lk-band"));
  double r, g, b;

  lk_band_ramp_color (band, &r, &g, &b);
  cairo_set_source_rgb (cr, r, g, b);
  cairo_rectangle (cr, 0.5, 0.5, width - 1, height - 1);
  cairo_fill_preserve (cr);
  cairo_set_source_rgba (cr, 0, 0, 0, 0.25);
  cairo_set_line_width (cr, 1.0);
  cairo_stroke (cr);
}

/* One band: its ramp colour, its name, and how many cells it holds. */
static GtkWidget *
lk_band_legend_entry (int band, guint count)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 5);
  GtkWidget *swatch = gtk_drawing_area_new ();
  GtkWidget *name = gtk_label_new (lk_chart_band_name (band));
  g_autofree char *text = g_strdup_printf ("%u", count);
  GtkWidget *number = gtk_label_new (text);

  gtk_widget_set_size_request (swatch, 8, 8);
  gtk_widget_set_valign (swatch, GTK_ALIGN_CENTER);
  g_object_set_data (G_OBJECT (swatch), "lk-band", GINT_TO_POINTER (band));
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (swatch), lk_band_swatch_draw,
                                  NULL, NULL);

  gtk_widget_add_css_class (name, "caption");
  gtk_widget_add_css_class (name, "dim-label");
  gtk_widget_add_css_class (number, "caption");

  gtk_box_append (GTK_BOX (row), swatch);
  gtk_box_append (GTK_BOX (row), name);
  gtk_box_append (GTK_BOX (row), number);
  return row;
}

/* ---- the widget ---------------------------------------------------------- */

void
lk_band_ramp_set (GtkWidget *ramp, const guint bands[7])
{
  GtkWidget *bar = g_object_get_data (G_OBJECT (ramp), "lk-bar");
  GtkWidget *legend = g_object_get_data (G_OBJECT (ramp), "lk-legend");
  GtkWidget *child;
  guint *owned;

  g_return_if_fail (bar != NULL && legend != NULL);

  if (bands == NULL || lk_band_ramp_count (bands) == 0)
    {
      gtk_widget_set_visible (ramp, FALSE);
      return;
    }

  owned = g_new0 (guint, 7);
  memcpy (owned, bands, sizeof (guint) * 7);
  g_object_set_data_full (G_OBJECT (bar), "lk-bands", owned, g_free);

  while ((child = gtk_widget_get_first_child (legend)) != NULL)
    gtk_flow_box_remove (GTK_FLOW_BOX (legend), child);

  /* Finest first, matching the bar. */
  for (int band = 6; band >= 1; band--)
    {
      if (bands[band] == 0)
        continue;
      gtk_flow_box_append (GTK_FLOW_BOX (legend), lk_band_legend_entry (band, bands[band]));
    }

  /* One sentence for a reader who cannot see the bar. */
  g_autoptr (GString) spoken = g_string_new (NULL);
  for (int band = 6; band >= 1; band--)
    {
      if (bands[band] == 0)
        continue;
      g_string_append_printf (spoken, "%s%s %u", spoken->len > 0 ? ", " : "",
                              lk_chart_band_name (band), bands[band]);
    }
  gtk_accessible_update_property (GTK_ACCESSIBLE (bar), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  spoken->str, -1);

  gtk_widget_set_visible (ramp, TRUE);
  gtk_widget_queue_draw (bar);
}

GtkWidget *
lk_band_ramp_new (const guint bands[7])
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  GtkWidget *bar = gtk_drawing_area_new ();
  GtkWidget *legend = gtk_flow_box_new ();

  gtk_widget_set_size_request (bar, -1, LK_RAMP_HEIGHT);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (bar), lk_band_bar_draw, NULL, NULL);

  /* Wraps rather than scrolls: six bands fit two lines at any width the pane
   * reaches. */
  gtk_flow_box_set_selection_mode (GTK_FLOW_BOX (legend), GTK_SELECTION_NONE);
  gtk_flow_box_set_homogeneous (GTK_FLOW_BOX (legend), FALSE);
  gtk_flow_box_set_max_children_per_line (GTK_FLOW_BOX (legend), 6);
  gtk_flow_box_set_column_spacing (GTK_FLOW_BOX (legend), 12);
  gtk_flow_box_set_row_spacing (GTK_FLOW_BOX (legend), 4);

  gtk_box_append (GTK_BOX (box), bar);
  gtk_box_append (GTK_BOX (box), legend);
  g_object_set_data (G_OBJECT (box), "lk-bar", bar);
  g_object_set_data (G_OBJECT (box), "lk-legend", legend);

  lk_band_ramp_set (box, bands);
  return box;
}
