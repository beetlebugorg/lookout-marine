#include "lk-settings-window.h"

#include "lk-mariner.h"
#include "lk-window.h"

#include <gdk/gdkkeysyms.h>
#include <math.h>
#include <stdbool.h>

#define LK_FEET_PER_METRE 3.28084

typedef struct {
  LkAppModel *model;
  LkMariner  *mariner;

  /* Depths tab widgets that have to react to each other. */
  GtkWidget *band_preview;
  GtkWidget *shallow_row;
  GtkWidget *deep_row;
  GtkWidget *shading_footer;
  GtkWidget *contours_header;
  GtkWidget *shallow_spin, *safety_spin, *deep_spin, *safety_depth_spin;
  gboolean   updating; /* guard: reprogramming a widget must not re-apply */
} LkSettings;

static void
lk_settings_free (gpointer data)
{
  LkSettings *settings = data;

  g_clear_object (&settings->mariner);
  g_free (settings);
}

static gboolean
lk_settings_feet (LkSettings *settings)
{
  return lk_mariner_raw (settings->mariner)->depth_unit == TILE57_DEPTH_FEET;
}

/* ---- small builders ----------------------------------------------------- */

/* Frees a per-widget binding when its closure dies. */
static void
lk_binding_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

static GtkWidget *
lk_section_titled (GtkWidget *page, const char *title, GtkWidget **out_title)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);

  if (title != NULL)
    {
      GtkWidget *label = gtk_label_new (title);
      gtk_widget_add_css_class (label, "heading");
      gtk_widget_set_halign (label, GTK_ALIGN_START);
      gtk_box_append (GTK_BOX (box), label);
      if (out_title != NULL)
        *out_title = label;
    }

  gtk_widget_set_margin_top (box, 6);
  gtk_box_append (GTK_BOX (page), box);
  return box;
}

static GtkWidget *
lk_section (GtkWidget *page, const char *title)
{
  return lk_section_titled (page, title, NULL);
}

static GtkWidget *
lk_footer (GtkWidget *section, const char *text)
{
  GtkWidget *label = gtk_label_new (text);

  gtk_widget_add_css_class (label, "dim-label");
  gtk_widget_add_css_class (label, "caption");
  gtk_label_set_wrap (GTK_LABEL (label), TRUE);
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_widget_set_margin_bottom (label, 4);
  gtk_box_append (GTK_BOX (section), label);
  return label;
}

/* A label on the left, a control on the right. */
static GtkWidget *
lk_row (GtkWidget *section, const char *title, GtkWidget *control)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  GtkWidget *label = gtk_label_new (title);

  gtk_widget_set_halign (label, GTK_ALIGN_START);
  gtk_widget_set_hexpand (label, TRUE);
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_box_append (GTK_BOX (row), label);
  gtk_box_append (GTK_BOX (row), control);
  gtk_box_append (GTK_BOX (section), row);
  return row;
}

static GtkWidget *
lk_page_new (GtkWidget *notebook, const char *title)
{
  GtkWidget *page = gtk_box_new (GTK_ORIENTATION_VERTICAL, 10);
  GtkWidget *scroller = gtk_scrolled_window_new ();

  gtk_widget_set_margin_start (page, 16);
  gtk_widget_set_margin_end (page, 16);
  gtk_widget_set_margin_top (page, 12);
  gtk_widget_set_margin_bottom (page, 12);

  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), page);
  gtk_notebook_append_page (GTK_NOTEBOOK (notebook), scroller, gtk_label_new (title));
  return page;
}

/* ---- generic bindings --------------------------------------------------- */

/* Engine flags are C `bool` (one byte), not `gboolean`; the binding must carry
 * the real type or a write clobbers the next field. */
typedef struct {
  LkSettings *settings;
  bool       *field;
} LkBoolBinding;

static void
lk_bool_toggled (GtkCheckButton *button, gpointer user_data)
{
  LkBoolBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  *binding->field = gtk_check_button_get_active (button) ? true : false;
  lk_mariner_touch (binding->settings->mariner);
}

static void
lk_switch_row (GtkWidget *section, LkSettings *settings, const char *title, bool *field)
{
  GtkWidget *check = gtk_check_button_new ();
  LkBoolBinding *binding = g_new0 (LkBoolBinding, 1);

  binding->settings = settings;
  binding->field = field;

  gtk_check_button_set_active (GTK_CHECK_BUTTON (check), *field);
  gtk_widget_set_valign (check, GTK_ALIGN_CENTER);
  g_signal_connect_data (check, "toggled", G_CALLBACK (lk_bool_toggled), binding,
                         lk_binding_free, 0);
  lk_row (section, title, check);
}

typedef struct {
  LkSettings *settings;
  int        *field;      /* for plain int-backed enums */
  void      (*apply) (LkSettings *settings, int value);
} LkChoiceBinding;

static void
lk_choice_changed (GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data)
{
  LkChoiceBinding *binding = user_data;
  int value = (int) gtk_drop_down_get_selected (dropdown);

  if (binding->settings->updating || value < 0)
    return;

  if (binding->apply != NULL)
    binding->apply (binding->settings, value);
  else if (binding->field != NULL)
    *binding->field = value;
  else
    return;

  lk_mariner_touch (binding->settings->mariner);
}

static GtkWidget *
lk_choice_row (GtkWidget          *section,
               LkSettings         *settings,
               const char         *title,
               const char *const  *options,
               int                 selected,
               int                *field,
               void              (*apply) (LkSettings *, int))
{
  GtkWidget *dropdown = gtk_drop_down_new_from_strings (options);
  LkChoiceBinding *binding = g_new0 (LkChoiceBinding, 1);

  binding->settings = settings;
  binding->field = field;
  binding->apply = apply;

  gtk_drop_down_set_selected (GTK_DROP_DOWN (dropdown), selected);
  gtk_widget_set_valign (dropdown, GTK_ALIGN_CENTER);
  g_signal_connect_data (dropdown, "notify::selected", G_CALLBACK (lk_choice_changed),
                         binding, lk_binding_free, 0);
  lk_row (section, title, dropdown);
  return dropdown;
}

typedef struct {
  LkSettings *settings;
  double     *field;
} LkScaleBinding;

static void
lk_scale_changed (GtkRange *range, gpointer user_data)
{
  LkScaleBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  *binding->field = gtk_range_get_value (range);
  lk_mariner_touch (binding->settings->mariner);
}

static char *
lk_scale_format (GtkScale *scale, double value, gpointer user_data)
{
  return g_strdup_printf ("%.2f×", value);
}

static void
lk_size_row (GtkWidget *section, LkSettings *settings, const char *title, double *field)
{
  GtkWidget *scale = gtk_scale_new_with_range (GTK_ORIENTATION_HORIZONTAL, 0.5, 2.0, 0.05);
  LkScaleBinding *binding = g_new0 (LkScaleBinding, 1);

  binding->settings = settings;
  binding->field = field;

  gtk_range_set_value (GTK_RANGE (scale), *field > 0 ? *field : 1.0);
  gtk_scale_set_draw_value (GTK_SCALE (scale), TRUE);
  gtk_scale_set_format_value_func (GTK_SCALE (scale), lk_scale_format, NULL, NULL);
  gtk_widget_set_size_request (scale, 220, -1);
  g_signal_connect_data (scale, "value-changed", G_CALLBACK (lk_scale_changed), binding,
                         lk_binding_free, 0);
  lk_row (section, title, scale);
}

/* ---- depths ------------------------------------------------------------- */

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
  GtkWidget *spin = gtk_spin_button_new_with_range (0, 660, 1);
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

static void
lk_apply_scheme (LkSettings *settings, int value)
{
  lk_mariner_raw (settings->mariner)->scheme = (tile57_scheme) value;
}

static void
lk_apply_category (LkSettings *settings, int value)
{
  lk_mariner_set_display_category (settings->mariner, value);
}

static void
lk_apply_soundings (LkSettings *settings, int value)
{
  lk_mariner_raw (settings->mariner)->soundings = (uint8_t) value;
}

static void
lk_apply_boundary (LkSettings *settings, int value)
{
  lk_mariner_raw (settings->mariner)->boundary_style = (tile57_boundary_style) value;
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

/* ---- pages -------------------------------------------------------------- */

static void
lk_build_display_page (GtkWidget *notebook, LkSettings *settings)
{
  static const char *schemes[] = { "Day", "Dusk", "Night", NULL };
  static const char *categories[] = { "Base", "Standard", "Other", NULL };
  static const char *soundings[] = { "Follow category", "Always on", "Always off", NULL };

  GtkWidget *page = lk_page_new (notebook, "Display");
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  GtkWidget *scheme_section = lk_section (page, NULL);
  lk_choice_row (scheme_section, settings, "Color scheme", schemes,
                 (int) m->scheme, NULL, lk_apply_scheme);
  lk_footer (scheme_section, "Day, dusk and night palettes switch instantly.");

  GtkWidget *detail = lk_section (page, "Detail");
  lk_choice_row (detail, settings, "Display category", categories,
                 lk_mariner_get_display_category (settings->mariner), NULL, lk_apply_category);
  lk_choice_row (detail, settings, "Soundings", soundings,
                 m->soundings, NULL, lk_apply_soundings);
  lk_footer (detail, "Base ⊂ Standard ⊂ Other. Spot soundings switch "
                     "independently of the category.");
}

static void
lk_build_depths_page (GtkWidget *notebook, LkSettings *settings)
{
  static const char *units[] = { "Meters", "Feet", NULL };
  static const char *shading[] = { "Two shades", "Four shades", NULL };

  GtkWidget *page = lk_page_new (notebook, "Depths");
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
}

static void
lk_build_text_page (GtkWidget *notebook, LkSettings *settings)
{
  static const char *boundaries[] = { "Symbolized", "Plain", NULL };

  GtkWidget *page = lk_page_new (notebook, "Text");
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  GtkWidget *text = lk_section (page, "Text");
  lk_switch_row (text, settings, "Feature names", &m->text_names);
  lk_switch_row (text, settings, "Light descriptions", &m->show_light_descriptions);
  lk_switch_row (text, settings, "Other text", &m->text_other);

  GtkWidget *symbols = lk_section (page, "Symbols");
  lk_switch_row (symbols, settings, "Simplified point symbols", &m->simplified_points);
  lk_choice_row (symbols, settings, "Boundaries", boundaries,
                 (int) m->boundary_style, NULL, lk_apply_boundary);
  lk_switch_row (symbols, settings, "Full light-sector lines", &m->show_full_sector_lines);
}

static void
lk_charts_open_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_present_open_chart_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                settings->model);
}

static void
lk_charts_recent_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *path = g_object_get_data (G_OBJECT (button), "lk-path");

  if (path != NULL)
    lk_app_model_open_chart (settings->model, path);
}

static void
lk_build_charts_page (GtkWidget *notebook, LkSettings *settings)
{
  GtkWidget *page = lk_page_new (notebook, "Charts");

  GtkWidget *open = lk_section (page, "Open");
  const char *path = lk_app_model_get_chart_path (settings->model);
  if (path != NULL)
    {
      g_autofree char *name = g_path_get_basename (path);
      GtkWidget *label = gtk_label_new (name);
      gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_MIDDLE);
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (open), label);
    }
  else
    {
      GtkWidget *label = gtk_label_new ("No chart open");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (open), label);
    }

  const char *const *recents = lk_app_model_get_recents (settings->model);
  if (recents != NULL && recents[0] != NULL)
    {
      GtkWidget *recent_section = lk_section (page, "Recent");
      for (guint i = 0; recents[i] != NULL; i++)
        {
          g_autofree char *name = g_path_get_basename (recents[i]);
          GtkWidget *button = gtk_button_new_with_label (name);

          gtk_button_set_has_frame (GTK_BUTTON (button), FALSE);
          gtk_widget_set_halign (button, GTK_ALIGN_FILL);
          g_object_set_data_full (G_OBJECT (button), "lk-path",
                                  g_strdup (recents[i]), g_free);
          g_signal_connect (button, "clicked", G_CALLBACK (lk_charts_recent_clicked), settings);
          gtk_box_append (GTK_BOX (recent_section), button);
        }
    }

  GtkWidget *add = lk_section (page, NULL);
  GtkWidget *button = gtk_button_new_with_label ("Add Charts…");
  gtk_widget_set_halign (button, GTK_ALIGN_START);
  g_signal_connect (button, "clicked", G_CALLBACK (lk_charts_open_clicked), settings);
  gtk_box_append (GTK_BOX (add), button);
  lk_footer (add, "A folder of baked cells opens as one seamless library.");
}

static void
lk_date_changed (GtkEditable *editable, gpointer user_data)
{
  LkSettings *settings = user_data;
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  if (settings->updating)
    return;

  memset (m->date_view, 0, sizeof m->date_view);
  g_strlcpy (m->date_view, gtk_editable_get_text (editable), sizeof m->date_view);
  lk_mariner_touch (settings->mariner);
}

static void
lk_build_advanced_page (GtkWidget *notebook, LkSettings *settings)
{
  GtkWidget *page = lk_page_new (notebook, "Advanced");
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  GtkWidget *safety = lk_section (page, "Safety & Quality");
  lk_switch_row (safety, settings, "Data quality overlay", &m->data_quality);
  lk_switch_row (safety, settings, "Isolated dangers in shallow water", &m->show_isolated_dangers_shallow);
  lk_switch_row (safety, settings, "Information callouts", &m->show_inform_callouts);
  lk_switch_row (safety, settings, "Meta boundaries", &m->show_meta_bounds);
  lk_switch_row (safety, settings, "Overscale indication", &m->show_overscale);

  GtkWidget *sizing = lk_section (page, "Sizing");
  lk_size_row (sizing, settings, "Overall size", &m->size_scale);
  lk_size_row (sizing, settings, "Text size", &m->text_size_scale);
  lk_size_row (sizing, settings, "Sounding size", &m->sounding_size_scale);

  GtkWidget *dates = lk_section (page, "Dates");
  lk_switch_row (dates, settings, "Date-dependent features", &m->date_dependent);
  lk_switch_row (dates, settings, "Highlight date-dependent", &m->highlight_date_dependent);

  GtkWidget *entry = gtk_entry_new ();
  gtk_entry_set_placeholder_text (GTK_ENTRY (entry), "YYYYMMDD");
  gtk_entry_set_max_length (GTK_ENTRY (entry), 8);
  gtk_editable_set_text (GTK_EDITABLE (entry), m->date_view);
  gtk_widget_set_valign (entry, GTK_ALIGN_CENTER);
  g_signal_connect (entry, "changed", G_CALLBACK (lk_date_changed), settings);
  lk_row (dates, "View date", entry);
  lk_footer (dates, "Leave the date empty to use today.");
}

/* ---- window ------------------------------------------------------------- */

/* Esc closes it — a tiling compositor draws no titlebar X. */
static gboolean
lk_settings_key_pressed (GtkEventControllerKey *controller,
                         guint keyval, guint keycode,
                         GdkModifierType state, gpointer window)
{
  if (keyval == GDK_KEY_Escape)
    {
      gtk_window_close (GTK_WINDOW (window));
      return GDK_EVENT_STOP;
    }
  return GDK_EVENT_PROPAGATE;
}

GtkWidget *
lk_settings_window_new (LkAppModel *model, GtkWindow *parent)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkSettings *settings = g_new0 (LkSettings, 1);
  settings->model = model;
  settings->mariner = lk_mariner_new (lk_app_model_get_controller (model));

  GtkWidget *window = gtk_window_new ();
  gtk_window_set_title (GTK_WINDOW (window), "Mariner Settings");
  gtk_window_set_default_size (GTK_WINDOW (window), 520, 560);
  gtk_window_set_transient_for (GTK_WINDOW (window), parent);
  gtk_window_set_destroy_with_parent (GTK_WINDOW (window), TRUE);
  /* A live panel, not a modal: the chart stays usable while it is open. */
  gtk_window_set_modal (GTK_WINDOW (window), FALSE);
  g_object_set_data_full (G_OBJECT (window), "lk-settings", settings, lk_settings_free);

  /* A real titlebar (close button + move handle) the compositor won't draw. */
  gtk_window_set_titlebar (GTK_WINDOW (window), gtk_header_bar_new ());

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (lk_settings_key_pressed), window);
  gtk_widget_add_controller (window, keys);

  GtkWidget *notebook = gtk_notebook_new ();
  gtk_window_set_child (GTK_WINDOW (window), notebook);

  lk_build_display_page (notebook, settings);
  lk_build_depths_page (notebook, settings);
  lk_build_text_page (notebook, settings);
  lk_build_charts_page (notebook, settings);
  lk_build_advanced_page (notebook, settings);

  return window;
}
