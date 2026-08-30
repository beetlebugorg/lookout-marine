/* ui/settings/display.c — the Display page.
 *
 * The colour scheme, the display category, and how soundings follow it. The
 * three schemes are shown as their own palettes rather than named, because a
 * mariner picks the one that reads on the bridge they are standing on.
 */
#include "ui/settings/display.h"
#include "ui/settings/widgets.h"

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

/* The three schemes' palettes, sRGB, six colours each: deep water, the three
   shoaling shades, land, and the coastline. The presentation library's own
   values (S-101 tokens DEPDW/DEPMD/DEPMS/DEPVS/LANDA/CSTLN), copied so a swatch
   draws without opening a chart. A legend of the palette, not the palette
   itself: the engine draws from the tables in the chart. */
static const double LK_SCHEME_PALETTE[3][6][3] = {
  { { 0.788, 0.929, 1.000 }, { 0.655, 0.851, 0.984 }, { 0.510, 0.792, 1.000 },
    { 0.380, 0.718, 1.000 }, { 0.749, 0.745, 0.561 }, { 0.298, 0.357, 0.388 } },
  { { 0.000, 0.000, 0.000 }, { 0.059, 0.106, 0.129 }, { 0.114, 0.196, 0.275 },
    { 0.118, 0.255, 0.396 }, { 0.251, 0.251, 0.180 }, { 0.420, 0.498, 0.537 } },
  { { 0.000, 0.000, 0.000 }, { 0.012, 0.027, 0.039 }, { 0.020, 0.055, 0.086 },
    { 0.027, 0.090, 0.153 }, { 0.090, 0.086, 0.055 }, { 0.145, 0.176, 0.192 } },
};

/* A shore in one scheme: the depth shades stacked out to deep water, then land
   behind a curved coastline. A piece of chart, not a colour chip — the same
   drawing the reference makes (SchemeSwatch, SettingsRows.swift), because a
   mariner picking a scheme is picking how the WATER will read, and six equal
   bars of colour do not answer that. */
static void
lk_swatch_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data)
{
  int scheme = GPOINTER_TO_INT (data);
  const double (*p)[3] = LK_SCHEME_PALETTE[scheme];
  const double w = width, h = height;
  /* Deep at the top, shoaling down: the fractions are the reference's. The last
     band runs to the bottom, so rounding never leaves a seam. */
  const double bands[3] = { h * 0.36, h * 0.18, h * 0.16 };
  const double r = 8.0; /* the CSS corner; cairo does not inherit it */
  double y = 0;

  /* Clip to the rounded corner the border draws, or the water paints over it. */
  cairo_new_sub_path (cr);
  cairo_arc (cr, w - r, r, r, -G_PI / 2, 0);
  cairo_arc (cr, w - r, h - r, r, 0, G_PI / 2);
  cairo_arc (cr, r, h - r, r, G_PI / 2, G_PI);
  cairo_arc (cr, r, r, r, G_PI, 3 * G_PI / 2);
  cairo_close_path (cr);
  cairo_clip (cr);

  for (int i = 0; i < 4; i++)
    {
      const double band = i < 3 ? bands[i] : h - y;
      cairo_set_source_rgb (cr, p[i][0], p[i][1], p[i][2]);
      cairo_rectangle (cr, 0, y, w, band + 1);
      cairo_fill (cr);
      y += band;
    }

  /* The shoreline: a bay open to the top left, land filling the corner. */
  cairo_move_to (cr, 0, h);
  cairo_line_to (cr, 0, h * 0.80);
  cairo_curve_to (cr, w * 0.35, h * 0.74, w * 0.60, h * 0.44, w, h * 0.52);
  cairo_line_to (cr, w, h);
  cairo_close_path (cr);

  cairo_set_source_rgb (cr, p[4][0], p[4][1], p[4][2]);
  cairo_fill_preserve (cr);
  cairo_set_source_rgb (cr, p[5][0], p[5][1], p[5][2]);
  cairo_set_line_width (cr, 1.5);
  cairo_stroke (cr);
}

/* Move the selection ring to the active scheme's swatch. */
static void
lk_settings_refresh_scheme_swatches (LkSettings *settings)
{
  int active = lk_mariner_raw (settings->mariner)->scheme;

  for (int i = 0; i < 3; i++)
    {
      if (settings->scheme_swatches[i] == NULL)
        continue;
      if (i == active)
        gtk_widget_add_css_class (settings->scheme_swatches[i], "lk-swatch-current");
      else
        gtk_widget_remove_css_class (settings->scheme_swatches[i], "lk-swatch-current");
    }
}

/* One scheme swatch: its palette drawn above its name, selectable. */
static void
lk_scheme_swatch_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  int scheme = GPOINTER_TO_INT (g_object_get_data (G_OBJECT (button), "lk-scheme"));

  if (settings->updating)
    return;
  lk_apply_scheme (settings, scheme);
  lk_mariner_touch (settings->mariner);
  lk_settings_refresh_scheme_swatches (settings);
}

static void
lk_scheme_swatches (GtkWidget *section, LkSettings *settings)
{
  static const char *labels[] = { "Day", "Dusk", "Night" };
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  int active = lk_mariner_raw (settings->mariner)->scheme;

  gtk_box_set_homogeneous (GTK_BOX (row), TRUE);
  for (int i = 0; i < 3; i++)
    {
      GtkWidget *stack = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
      GtkWidget *swatch = gtk_drawing_area_new ();
      GtkWidget *name = gtk_label_new (labels[i]);
      GtkWidget *button = gtk_button_new ();

      gtk_widget_set_size_request (swatch, -1, 78);
      gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (swatch), lk_swatch_draw,
                                      GINT_TO_POINTER (i), NULL);
      gtk_widget_add_css_class (swatch, "lk-swatch");
      gtk_box_append (GTK_BOX (stack), swatch);
      gtk_box_append (GTK_BOX (stack), name);

      gtk_button_set_child (GTK_BUTTON (button), stack);
      gtk_widget_add_css_class (button, "flat");
      if (i == active)
        gtk_widget_add_css_class (button, "lk-swatch-current");
      g_object_set_data (G_OBJECT (button), "lk-scheme", GINT_TO_POINTER (i));
      g_signal_connect (button, "clicked", G_CALLBACK (lk_scheme_swatch_clicked), settings);
      gtk_box_append (GTK_BOX (row), button);
      settings->scheme_swatches[i] = button;
    }
  gtk_box_append (GTK_BOX (section), row);
}

/* A radio row: a title, a description, and a check that marks the pick. Grouped
   so one of the set is chosen. */
typedef struct {
  LkSettings *settings;
  void      (*apply) (LkSettings *, int);
  int         value;
} LkRadioBinding;

static void
lk_radio_toggled (GtkCheckButton *check, gpointer user_data)
{
  LkRadioBinding *binding = user_data;

  if (binding->settings->updating || !gtk_check_button_get_active (check))
    return;
  binding->apply (binding->settings, binding->value);
  lk_mariner_touch (binding->settings->mariner);
}

static GtkWidget *
lk_radio_row (GtkWidget    *section,
              LkSettings   *settings,
              GtkWidget    *group,
              const char   *title,
              const char   *desc,
              gboolean      selected,
              int           value,
              void        (*apply) (LkSettings *, int))
{
  GtkWidget *check = gtk_check_button_new ();
  GtkWidget *stack = gtk_box_new (GTK_ORIENTATION_VERTICAL, 1);
  GtkWidget *label = gtk_label_new (title);
  GtkWidget *sub = gtk_label_new (desc);
  LkRadioBinding *binding = g_new0 (LkRadioBinding, 1);

  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_label_set_xalign (GTK_LABEL (sub), 0.0);
  gtk_label_set_wrap (GTK_LABEL (sub), TRUE);
  gtk_widget_add_css_class (sub, "dim-label");
  gtk_widget_add_css_class (sub, "caption");
  gtk_box_append (GTK_BOX (stack), label);
  gtk_box_append (GTK_BOX (stack), sub);

  if (group != NULL)
    gtk_check_button_set_group (GTK_CHECK_BUTTON (check), GTK_CHECK_BUTTON (group));
  gtk_check_button_set_child (GTK_CHECK_BUTTON (check), stack);
  gtk_check_button_set_active (GTK_CHECK_BUTTON (check), selected);

  binding->settings = settings;
  binding->apply = apply;
  binding->value = value;
  g_signal_connect_data (check, "toggled", G_CALLBACK (lk_radio_toggled), binding,
                         lk_binding_free, 0);
  gtk_box_append (GTK_BOX (section), check);
  return check;
}

void
lk_build_display_page (LkSettings *settings)
{
  static const char *categories[] = { "Base", "Standard", "Other", NULL };
  static const char *soundings[] = { "Follow category", "Always on", "Always off", NULL };

  GtkWidget *page = lk_page_new (settings, "display", "Display",
                                 "lk-display-symbolic");
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  /* "Colour scheme" here, the reference's settings header spelling, while the
     commands menu says "Color Scheme". Each mirrors macOS as it is. */
  GtkWidget *scheme_section = lk_section_hinted (page, "Colour scheme", "Ctrl+L steps");
  lk_scheme_swatches (scheme_section, settings);
  lk_footer (scheme_section,
             "The palettes switch instantly. Night keeps your eyes dark-adapted.");

  /* Radio rows with a line each, as the reference draws them, in place of a
     dropdown that hid what each choice does. */
  static const char *category_desc[] = {
    "Coastline, safety contour, dangers and traffic lanes. Never hidden.",
    "Adds buoys, beacons, lights, restricted areas and ferry routes",
    "Adds spot soundings, contour labels, seabed quality and cables",
  };
  GtkWidget *detail = lk_section_hinted (page, "Display category", "Ctrl+D adds Other");
  GtkWidget *cat_group = NULL;
  int cat = lk_mariner_get_display_category (settings->mariner);
  for (int i = 0; i < 3; i++)
    {
      GtkWidget *r = lk_radio_row (detail, settings, cat_group, categories[i],
                                   category_desc[i], i == cat, i, lk_apply_category);
      if (cat_group == NULL)
        cat_group = r;
    }
  lk_footer (detail, "Each category contains the one before it.");

  static const char *soundings_desc[] = {
    "Drawn when the category includes them, which is Other",
    "Spot depths, whatever the category",
    "No spot depths, whatever the category",
  };
  GtkWidget *sound = lk_section_hinted (page, "Soundings", "Ctrl+Shift+S steps");
  GtkWidget *snd_group = NULL;
  for (int i = 0; i < 3; i++)
    {
      GtkWidget *r = lk_radio_row (sound, settings, snd_group, soundings[i],
                                   soundings_desc[i], i == m->soundings, i, lk_apply_soundings);
      if (snd_group == NULL)
        snd_group = r;
    }

  lk_plugin_fill_tab (page, settings, "display");
}
