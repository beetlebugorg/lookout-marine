/* ui/settings/depths.c — the Depths page.
 *
 * Four contours, the unit they are read in, and how many shades of water the
 * chart draws between them. The engine always takes metres; feet is a labelling
 * and an editing conversion, done here so nothing below this page sees it.
 */
#include "ui/settings/depths.h"
#include "ui/settings/widgets.h"

#include <math.h>

typedef struct {
  LkSettings *settings;
  double     *field;
} LkDepthBinding;

/* The engine always takes metres; the unit only changes labelling. Feet mode
 * edits through this conversion, in whole feet. */
static void
lk_depth_changed (GtkSpinButton *spin, gpointer user_data)
{
  LkDepthBinding *binding = user_data;
  double value = gtk_spin_button_get_value (spin);

  if (binding->settings->updating)
    return;

  *binding->field = lk_settings_feet (binding->settings)
                        ? round (value) / LK_FEET_PER_METRE
                        : value;
  lk_mariner_touch (binding->settings->mariner);
  gtk_widget_queue_draw (binding->settings->band_preview);
}

/* Returns the row (to hide it); hands back the spin via `out_spin` (to reprogram). */
static GtkWidget *
lk_depth_row (GtkWidget   *section,
              LkSettings  *settings,
              const char  *title,
              double      *field,
              GtkWidget  **out_spin)
{
  gboolean feet = lk_settings_feet (settings);
  /* The range follows the unit. 660 m is the deepest contour the core takes;
     in feet that is about 2165, so a fixed metre range would clamp a deep
     contour and write the clamped value back on the next touch. */
  GtkWidget *spin =
      gtk_spin_button_new_with_range (0, feet ? round (660 * LK_FEET_PER_METRE) : 660, 1);
  LkDepthBinding *binding = g_new0 (LkDepthBinding, 1);

  binding->settings = settings;
  binding->field = field;

  gtk_spin_button_set_digits (GTK_SPIN_BUTTON (spin), feet ? 0 : 1);
  gtk_spin_button_set_value (GTK_SPIN_BUTTON (spin),
                             feet ? round (*field * LK_FEET_PER_METRE) : *field);
  gtk_widget_set_valign (spin, GTK_ALIGN_CENTER);
  g_signal_connect_data (spin, "value-changed", G_CALLBACK (lk_depth_changed), binding,
                         lk_binding_free, 0);

  if (out_spin != NULL)
    *out_spin = spin;
  return lk_row (section, title, spin);
}

/* Relabel every depth spin for the current unit without changing the depths. */
static void
lk_settings_refresh_depths (LkSettings *settings)
{
  tile57_mariner *m = lk_mariner_raw (settings->mariner);
  gboolean feet = lk_settings_feet (settings);

  struct { GtkWidget *spin; double metres; } rows[] = {
    { settings->shallow_spin, m->shallow_contour },
    { settings->safety_spin, m->safety_contour },
    { settings->deep_spin, m->deep_contour },
    { settings->safety_depth_spin, m->safety_depth },
  };

  settings->updating = TRUE;
  for (gsize i = 0; i < G_N_ELEMENTS (rows); i++)
    {
      if (rows[i].spin == NULL)
        continue;
      /* Widen the range to the unit before setting the value, or the old range
         clamps a deep contour on the way in. */
      gtk_spin_button_set_range (GTK_SPIN_BUTTON (rows[i].spin), 0,
                                 feet ? round (660 * LK_FEET_PER_METRE) : 660);
      gtk_spin_button_set_digits (GTK_SPIN_BUTTON (rows[i].spin), feet ? 0 : 1);
      gtk_spin_button_set_value (GTK_SPIN_BUTTON (rows[i].spin),
                                 feet ? round (rows[i].metres * LK_FEET_PER_METRE)
                                      : rows[i].metres);
    }
  settings->updating = FALSE;

  g_autofree char *header = g_strdup_printf ("Contours (%s)", feet ? "ft" : "m");
  gtk_label_set_text (GTK_LABEL (settings->contours_header), header);
  gtk_widget_queue_draw (settings->band_preview);
}

static void
lk_settings_refresh_shading (LkSettings *settings)
{
  gboolean four = lk_mariner_raw (settings->mariner)->four_shade_water;

  gtk_widget_set_visible (settings->shallow_row, four);
  gtk_widget_set_visible (settings->deep_row, four);
  gtk_label_set_text (GTK_LABEL (settings->shading_footer),
                      four
                          ? "Four shades: white (safe) water starts at the DEEP contour; "
                            "the safety contour separates the two middle blues."
                          : "Two shades: water deeper than the safety contour is white (safe), "
                            "everything shallower is blue.");
  gtk_widget_queue_draw (settings->band_preview);
}

static void
lk_apply_depth_unit (LkSettings *settings, int value)
{
  lk_mariner_raw (settings->mariner)->depth_unit = (tile57_depth_unit) value;
  lk_settings_refresh_depths (settings);
}

static void
lk_apply_shading (LkSettings *settings, int value)
{
  lk_mariner_raw (settings->mariner)->four_shade_water = (value == 1);
  lk_settings_refresh_shading (settings);
}

/* ---- the depth-band preview --------------------------------------------- */

/* A legend of the S-52 depth bands for the current settings. The colours only
 * approximate the day palette. */
static void
lk_band_preview_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data)
{
  LkSettings *settings = user_data;
  tile57_mariner *m = lk_mariner_raw (settings->mariner);
  gboolean feet = lk_settings_feet (settings);

  typedef struct { double r, g, b; char *label; } LkBand;
  LkBand bands[5];
  int n = 0;

#define LABEL(metres)                                                          \
  (feet ? g_strdup_printf ("%d ft", (int) round ((metres) * LK_FEET_PER_METRE)) \
        : g_strdup_printf ("%g m", (metres)))

  bands[n++] = (LkBand) { 0.55, 0.80, 0.60, g_strdup ("drying") };
  if (m->four_shade_water)
    {
      double first = MIN (m->shallow_contour, m->safety_contour);
      g_autofree char *first_s = LABEL (first);
      g_autofree char *safety_s = LABEL (m->safety_contour);
      g_autofree char *deep_s = LABEL (MAX (m->deep_contour, m->safety_contour));

      bands[n++] = (LkBand) { 0.45, 0.75, 0.93, g_strdup_printf ("0–%s", first_s) };
      bands[n++] = (LkBand) { 0.55, 0.82, 0.97, g_strdup_printf ("–%s", safety_s) };
      bands[n++] = (LkBand) { 0.75, 0.90, 0.99, g_strdup_printf ("–%s", deep_s) };
    }
  else
    {
      g_autofree char *safety_s = LABEL (m->safety_contour);
      bands[n++] = (LkBand) { 0.45, 0.75, 0.93, g_strdup_printf ("0–%s", safety_s) };
    }
  bands[n++] = (LkBand) { 1.0, 1.0, 1.0, g_strdup ("deeper") };

#undef LABEL

  const double radius = 6.0;
  double band_width = (double) width / n;

  cairo_select_font_face (cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
  cairo_set_font_size (cr, 9);

  /* Rounded clip: reads as one strip, and gives the WHITE deepest band an edge
   * against the page. */
  cairo_new_path (cr);
  cairo_arc (cr, radius, radius, radius, G_PI, 1.5 * G_PI);
  cairo_arc (cr, width - radius, radius, radius, 1.5 * G_PI, 2 * G_PI);
  cairo_arc (cr, width - radius, height - radius, radius, 0, 0.5 * G_PI);
  cairo_arc (cr, radius, height - radius, radius, 0.5 * G_PI, G_PI);
  cairo_close_path (cr);
  cairo_save (cr);
  cairo_clip_preserve (cr);

  for (int i = 0; i < n; i++)
    {
      cairo_set_source_rgb (cr, bands[i].r, bands[i].g, bands[i].b);
      cairo_rectangle (cr, i * band_width, 0, band_width, height);
      cairo_fill (cr);

      cairo_text_extents_t extents;
      cairo_text_extents (cr, bands[i].label, &extents);
      cairo_set_source_rgba (cr, 0, 0, 0, 0.75);
      cairo_move_to (cr, i * band_width + (band_width - extents.width) / 2, height - 5);
      cairo_show_text (cr, bands[i].label);

      g_free (bands[i].label);
    }

  cairo_restore (cr);
  cairo_set_source_rgba (cr, 0, 0, 0, 0.25);
  cairo_set_line_width (cr, 1.0);
  cairo_stroke (cr);
}

void
lk_build_depths_page (LkSettings *settings)
{
  static const char *units[] = { "Meters", "Feet", NULL };
  static const char *shading[] = { "Two shades", "Four shades", NULL };

  GtkWidget *page = lk_page_new (settings, "depths", "Depths",
                                 "lk-depths-symbolic");
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  GtkWidget *model_section = lk_section (page, NULL);
  lk_choice_row (model_section, settings, "Depth unit", units,
                 (int) m->depth_unit, NULL, lk_apply_depth_unit);
  lk_choice_row (model_section, settings, "Water shading", shading,
                 m->four_shade_water ? 1 : 0, NULL, lk_apply_shading);
  settings->shading_footer = lk_footer (model_section, "");

  GtkWidget *preview_section = lk_section (page, NULL);
  settings->band_preview = gtk_drawing_area_new ();
  gtk_widget_set_size_request (settings->band_preview, -1, 34);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (settings->band_preview),
                                  lk_band_preview_draw, settings, NULL);
  /* The preview is drawn, so it has no text a screen reader can read. Name it. */
  gtk_accessible_update_property (GTK_ACCESSIBLE (settings->band_preview),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL,
                                  "Depth shading preview", -1);
  gtk_box_append (GTK_BOX (preview_section), settings->band_preview);
  lk_footer (preview_section,
             "Shading follows the depth areas in the chart: the effective safety "
             "contour is the next DEEPER contour available in the data, drawn bold.");

  GtkWidget *contours = lk_section_titled (page, "Contours (m)", &settings->contours_header);

  settings->shallow_row = lk_depth_row (contours, settings, "Shallow contour",
                                        &m->shallow_contour, &settings->shallow_spin);
  lk_depth_row (contours, settings, "Safety contour", &m->safety_contour, &settings->safety_spin);
  settings->deep_row = lk_depth_row (contours, settings, "Deep contour",
                                     &m->deep_contour, &settings->deep_spin);
  lk_depth_row (contours, settings, "Safety depth", &m->safety_depth, &settings->safety_depth_spin);

  lk_footer (contours, "Safety depth bolds soundings at or shallower than it; "
                       "it does not shade water.");

  lk_settings_refresh_shading (settings);
  lk_settings_refresh_depths (settings);

  lk_plugin_fill_tab (page, settings, "depths");
}
