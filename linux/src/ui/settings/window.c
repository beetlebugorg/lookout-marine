#include "plugins/discovery.h"
#include "ui/settings/window.h"

#include "ui/chrome/licenses.h"
#include "model/mariner.h"
#include "plugins/install.h"
#include "plugins/registry.h"
#include "ui/open-dialogs.h"

#include <gdk/gdkkeysyms.h>
#include <math.h>
#include <stdbool.h>

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
 * rather than only in the ones the plugins brought into existence. Defined with
 * the rest of the plugin chrome, far below. */
static void lk_plugin_fill_tab (GtkWidget *page, LkSettings *settings, const char *tab);

static void
lk_settings_free (gpointer data)
{
  LkSettings *settings = data;

  g_clear_handle_id (&settings->raster_refresh_id, g_source_remove);
  g_clear_handle_id (&settings->links_refresh_id, g_source_remove);
  g_clear_handle_id (&settings->sets_refresh_id, g_source_remove);
  g_clear_handle_id (&settings->status_poll_id, g_source_remove);
  g_clear_handle_id (&settings->list_refill_id, g_source_remove);
  g_clear_pointer (&settings->discovery, lk_discovery_free);
  g_clear_pointer (&settings->discover_lists, g_ptr_array_unref);
  g_clear_pointer (&settings->status_labels, g_ptr_array_unref);
  g_clear_pointer (&settings->pending_lists, g_ptr_array_unref);
  g_clear_pointer (&settings->list_boxes, g_hash_table_unref);
  g_clear_pointer (&settings->plugins, lk_plugins_free);
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

/* One section: a row in the sidebar, and the pane it names in the stack.
 *
 * `id` is the CORE's section name (src/plugin/host.zig, `Tab`), so a plugin
 * and this window mean the same thing by "alarms", and a fix-it elsewhere can
 * ask for a section by the name the core uses. */
static GtkWidget *
lk_page_new (LkSettings *settings, const char *id, const char *title, const char *icon_name)
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
  gtk_stack_add_named (GTK_STACK (settings->stack), scroller, id);

  GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *icon = gtk_image_new_from_icon_name (icon_name);
  GtkWidget *label = gtk_label_new (title);
  GtkWidget *row = gtk_list_box_row_new ();

  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_box_append (GTK_BOX (line), icon);
  gtk_box_append (GTK_BOX (line), label);
  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), line);
  g_object_set_data_full (G_OBJECT (row), "lk-section", g_strdup (id), g_free);
  gtk_list_box_append (GTK_LIST_BOX (settings->sidebar), row);

  return page;
}

/* The list IS the navigation, so a row always names a pane. */
static void
lk_settings_section_selected (GtkListBox *box, GtkListBoxRow *row, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *id = row == NULL ? NULL : g_object_get_data (G_OBJECT (row), "lk-section");

  if (id != NULL)
    gtk_stack_set_visible_child_name (GTK_STACK (settings->stack), id);
}

/* Open on one section by name. A name no section carries is ignored, because a
 * section can be absent: a plugin that never came up takes its section with
 * it, and a stale request must not leave the window on nothing. */
static void
lk_settings_select_section (LkSettings *settings, const char *id)
{
  GtkListBoxRow *first = gtk_list_box_get_row_at_index (GTK_LIST_BOX (settings->sidebar), 0);
  GtkListBoxRow *wanted = NULL;

  for (int i = 0; id != NULL && id[0] != '\0'; i++)
    {
      GtkListBoxRow *row = gtk_list_box_get_row_at_index (GTK_LIST_BOX (settings->sidebar), i);

      if (row == NULL)
        break;
      if (g_strcmp0 (g_object_get_data (G_OBJECT (row), "lk-section"), id) == 0)
        {
          wanted = row;
          break;
        }
    }

  if (wanted == NULL)
    wanted = first;
  if (wanted != NULL)
    gtk_list_box_select_row (GTK_LIST_BOX (settings->sidebar), wanted);
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

/* ---- the display radio rows and scheme swatches ------------------------- */

/* The three schemes' palettes, sRGB, six colours each: deep water, three
   shallows, land, and text. The same legend the reference draws. */
static const double LK_SCHEME_PALETTE[3][6][3] = {
  { { 0.788, 0.929, 1.000 }, { 0.655, 0.851, 0.984 }, { 0.510, 0.792, 1.000 },
    { 0.380, 0.718, 1.000 }, { 0.749, 0.745, 0.561 }, { 0.298, 0.357, 0.388 } },
  { { 0.000, 0.000, 0.000 }, { 0.059, 0.106, 0.129 }, { 0.114, 0.196, 0.275 },
    { 0.118, 0.255, 0.396 }, { 0.251, 0.251, 0.180 }, { 0.420, 0.498, 0.537 } },
  { { 0.000, 0.000, 0.000 }, { 0.012, 0.027, 0.039 }, { 0.020, 0.055, 0.086 },
    { 0.027, 0.090, 0.153 }, { 0.090, 0.086, 0.055 }, { 0.145, 0.176, 0.192 } },
};

static void
lk_swatch_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data)
{
  int scheme = GPOINTER_TO_INT (data);
  double band = width / 6.0;

  for (int i = 0; i < 6; i++)
    {
      const double *c = LK_SCHEME_PALETTE[scheme][i];
      cairo_set_source_rgb (cr, c[0], c[1], c[2]);
      cairo_rectangle (cr, i * band, 0, band + 1, height);
      cairo_fill (cr);
    }
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
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  int active = lk_mariner_raw (settings->mariner)->scheme;

  gtk_box_set_homogeneous (GTK_BOX (row), TRUE);
  for (int i = 0; i < 3; i++)
    {
      GtkWidget *stack = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);
      GtkWidget *swatch = gtk_drawing_area_new ();
      GtkWidget *name = gtk_label_new (labels[i]);
      GtkWidget *button = gtk_button_new ();

      gtk_widget_set_size_request (swatch, -1, 34);
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

/* A section header with a right-aligned shortcut hint, as the reference's has. */
static GtkWidget *
lk_section_hinted (GtkWidget *page, const char *title, const char *hint)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *label = gtk_label_new (title);
  GtkWidget *tip = gtk_label_new (hint);

  gtk_widget_add_css_class (label, "heading");
  gtk_widget_set_halign (label, GTK_ALIGN_START);
  gtk_widget_set_hexpand (label, TRUE);
  gtk_widget_add_css_class (tip, "dim-label");
  gtk_widget_add_css_class (tip, "caption");
  gtk_box_append (GTK_BOX (header), label);
  gtk_box_append (GTK_BOX (header), tip);
  gtk_box_append (GTK_BOX (box), header);
  gtk_widget_set_margin_top (box, 6);
  gtk_box_append (GTK_BOX (page), box);
  return box;
}

/* ---- pages -------------------------------------------------------------- */

static void
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

static void
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

static void
lk_build_text_page (LkSettings *settings)
{
  static const char *boundaries[] = { "Symbolized", "Plain", NULL };

  GtkWidget *page = lk_page_new (settings, "text", "Text",
                                 "format-text-rich-symbolic");
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

  lk_plugin_fill_tab (page, settings, "text");
}

static void
lk_charts_archive_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_present_open_archive_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                  settings->model);
}

static void
lk_charts_open_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_present_open_chart_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                settings->model);
}

/* ---- the raster chart list ---------------------------------------------- */

static void
lk_raster_group_toggled (GtkSwitch *widget, GParamSpec *pspec, gpointer user_data)
{
  LkSettings *settings = user_data;
  gboolean on = gtk_switch_get_active (widget);

  if (settings->updating)
    return;

  /* The rebuild this starts frees the switch, and the switch owns the list. */
  g_autoptr (GPtrArray) paths = g_ptr_array_ref (g_object_get_data (G_OBJECT (widget), "lk-paths"));

  /* A mariner turns off Navionics, not four files that happen to be Navionics. */
  for (guint i = 0; i < paths->len; i++)
    lk_app_model_set_raster_enabled (settings->model, g_ptr_array_index (paths, i), on);
}

static void
lk_raster_file_toggled (GtkSwitch *widget, GParamSpec *pspec, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *path = g_object_get_data (G_OBJECT (widget), "lk-path");

  if (settings->updating)
    return;

  lk_app_model_set_raster_enabled (settings->model, path, gtk_switch_get_active (widget));
}

static void
lk_raster_remove_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *path = g_object_get_data (G_OBJECT (button), "lk-path");

  lk_app_model_remove_raster_chart (settings->model, path);
}

static void
lk_raster_add_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_present_add_raster_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                settings->model);
}

static void
lk_raster_add_folder_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_present_add_raster_folder_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                       settings->model);
}

static GtkWidget *
lk_raster_switch (gboolean on)
{
  GtkWidget *widget = gtk_switch_new ();

  gtk_switch_set_active (GTK_SWITCH (widget), on);
  gtk_widget_set_valign (widget, GTK_ALIGN_CENTER);
  return widget;
}

/* One switch for the set, one for each file under it. The set is what the pill
 * cycles and what covers a piece of water; the file is what the mariner
 * downloaded. */
static void
lk_settings_fill_raster_list (LkSettings *settings)
{
  GtkWidget *list = settings->raster_list;
  GtkWidget *child;

  /* Programming a switch must not read back as a mariner moving it. */
  settings->updating = TRUE;

  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  if (lk_app_model_get_raster_count (settings->model) == 0)
    {
      GtkWidget *empty = gtk_label_new ("No raster charts");
      gtk_widget_add_css_class (empty, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (empty), 0.0);
      gtk_box_append (GTK_BOX (list), empty);
      settings->updating = FALSE;
      return;
    }

  g_autoptr (GPtrArray) groups = lk_app_model_get_raster_groups (settings->model);

  for (guint i = 0; i < groups->len; i++)
    {
      const LkRasterGroup *group = g_ptr_array_index (groups, i);
      gboolean any_on = FALSE;

      for (guint j = 0; j < group->paths->len; j++)
        {
          if (lk_app_model_raster_enabled (settings->model, g_ptr_array_index (group->paths, j)))
            any_on = TRUE;
        }

      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      GtkWidget *toggle = lk_raster_switch (any_on);
      GtkWidget *name = gtk_label_new (group->name);
      g_autofree char *count = g_strdup_printf (group->paths->len == 1 ? "%u file" : "%u files",
                                                group->paths->len);
      GtkWidget *files = gtk_label_new (count);

      gtk_widget_add_css_class (name, "heading");
      gtk_label_set_xalign (GTK_LABEL (name), 0.0);
      gtk_widget_set_hexpand (name, TRUE);
      gtk_widget_add_css_class (files, "dim-label");
      gtk_widget_add_css_class (files, "caption");

      /* The switch owns its copies. The group's strings belong to the installed
       * list, and a removal frees them while this row is still on the screen. */
      GPtrArray *owned = g_ptr_array_new_with_free_func (g_free);
      for (guint j = 0; j < group->paths->len; j++)
        g_ptr_array_add (owned, g_strdup (g_ptr_array_index (group->paths, j)));

      g_object_set_data_full (G_OBJECT (toggle), "lk-paths", owned,
                              (GDestroyNotify) g_ptr_array_unref);
      g_signal_connect (toggle, "notify::active", G_CALLBACK (lk_raster_group_toggled), settings);

      gtk_box_append (GTK_BOX (row), toggle);
      gtk_box_append (GTK_BOX (row), name);
      gtk_box_append (GTK_BOX (row), files);
      gtk_widget_set_margin_top (row, 6);
      gtk_box_append (GTK_BOX (list), row);

      for (guint j = 0; j < group->paths->len; j++)
        {
          const char *path = g_ptr_array_index (group->paths, j);
          g_autofree char *base = g_path_get_basename (path);
          gboolean on = lk_app_model_raster_enabled (settings->model, path);

          GtkWidget *file_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
          GtkWidget *file_toggle = lk_raster_switch (on);
          GtkWidget *label = gtk_label_new (base);
          GtkWidget *remove = gtk_button_new_from_icon_name ("list-remove-symbolic");

          gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_MIDDLE);
          gtk_label_set_xalign (GTK_LABEL (label), 0.0);
          gtk_widget_set_hexpand (label, TRUE);
          gtk_widget_add_css_class (label, "caption");
          if (!on)
            gtk_widget_add_css_class (label, "dim-label");

          gtk_button_set_has_frame (GTK_BUTTON (remove), FALSE);
          gtk_widget_set_valign (remove, GTK_ALIGN_CENTER);
          /* The engine cannot drop a chart from a live handle, so a removal
           * switches the picture off now and the chart goes at the next open. */
          gtk_widget_set_tooltip_text (remove, "Remove. The picture goes at once.");
          gtk_accessible_update_property (GTK_ACCESSIBLE (remove),
                                          GTK_ACCESSIBLE_PROPERTY_LABEL, "Remove raster chart", -1);

          g_object_set_data_full (G_OBJECT (file_toggle), "lk-path", g_strdup (path), g_free);
          g_object_set_data_full (G_OBJECT (remove), "lk-path", g_strdup (path), g_free);
          g_signal_connect (file_toggle, "notify::active",
                            G_CALLBACK (lk_raster_file_toggled), settings);
          g_signal_connect (remove, "clicked", G_CALLBACK (lk_raster_remove_clicked), settings);

          gtk_widget_set_margin_start (file_row, 22);
          gtk_box_append (GTK_BOX (file_row), file_toggle);
          gtk_box_append (GTK_BOX (file_row), label);
          gtk_box_append (GTK_BOX (file_row), remove);
          gtk_box_append (GTK_BOX (list), file_row);
        }
    }
  settings->updating = FALSE;
}

static gboolean
lk_settings_refill_raster (gpointer user_data)
{
  LkSettings *settings = user_data;

  settings->raster_refresh_id = 0;
  lk_settings_fill_raster_list (settings);
  return G_SOURCE_REMOVE;
}

/* A switch in this list changes the model, which brings us straight back here.
 * Rebuilding now would free the switch that is still emitting, so the rebuild
 * waits for the next idle — which also folds one group's files into one pass. */
static void
lk_settings_raster_changed (LkAppModel *model, gpointer user_data)
{
  LkSettings *settings = g_object_get_data (G_OBJECT (user_data), "lk-settings");

  if (settings == NULL || settings->raster_list == NULL || settings->raster_refresh_id != 0)
    return;

  settings->raster_refresh_id = g_idle_add (lk_settings_refill_raster, settings);
}

/* ---- charts by link ------------------------------------------------------ */

static void
lk_link_radio_toggled (GtkCheckButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  /* NULL data is the "Lookout chart" radio, and NULL is how the links object
   * spells "lookout's own chart". */
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");

  if (settings->updating || !gtk_check_button_get_active (button))
    return;
  lk_chart_links_select (lk_app_model_get_chart_links (settings->model), url);
}

static void
lk_link_refresh_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");

  lk_chart_links_refresh (lk_app_model_get_chart_links (settings->model), url);
}

static void
lk_link_remove_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");

  lk_chart_links_remove (lk_app_model_get_chart_links (settings->model), url);
}

static void
lk_link_add_from (LkSettings *settings, GtkEntry *entry)
{
  const char *text = gtk_editable_get_text (GTK_EDITABLE (entry));

  if (text == NULL || text[0] == '\0')
    return;
  lk_chart_links_add (lk_app_model_get_chart_links (settings->model), text);
  gtk_editable_set_text (GTK_EDITABLE (entry), "");
}

static void
lk_link_entry_activated (GtkEntry *entry, gpointer user_data)
{
  lk_link_add_from (user_data, entry);
}

static void
lk_link_add_clicked (GtkButton *button, gpointer user_data)
{
  lk_link_add_from (user_data, g_object_get_data (G_OBJECT (button), "lk-entry"));
}

/* The chart election: lookout's own chart, or one of the added links. One
 * radio group — a linked chart is an entire separate chart, not an overlay,
 * so exactly one of these is ever drawn. */
static void
lk_settings_fill_links_list (LkSettings *settings)
{
  GtkWidget *list = settings->links_list;
  GtkWidget *child;
  LkChartLinks *links = lk_app_model_get_chart_links (settings->model);
  const char *active = lk_chart_links_active (links);
  const char *error = lk_chart_links_error (links);

  /* Programming a radio must not read back as a mariner picking it. */
  settings->updating = TRUE;

  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  GtkWidget *own = gtk_check_button_new_with_label ("Lookout chart");
  gtk_check_button_set_active (GTK_CHECK_BUTTON (own), active == NULL);
  g_signal_connect (own, "toggled", G_CALLBACK (lk_link_radio_toggled), settings);
  gtk_box_append (GTK_BOX (list), own);

  GPtrArray *all = lk_chart_links_list (links);
  for (guint i = 0; i < all->len; i++)
    {
      const LkChartLink *link = g_ptr_array_index (all, i);
      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 4);
      GtkWidget *radio = gtk_check_button_new_with_label (link->name);
      GtkWidget *refresh = gtk_button_new_from_icon_name ("view-refresh-symbolic");
      GtkWidget *remove = gtk_button_new_from_icon_name ("list-remove-symbolic");

      gtk_check_button_set_group (GTK_CHECK_BUTTON (radio), GTK_CHECK_BUTTON (own));
      gtk_check_button_set_active (GTK_CHECK_BUTTON (radio),
                                   g_strcmp0 (active, link->url) == 0);
      gtk_widget_set_hexpand (radio, TRUE);
      gtk_widget_set_tooltip_text (radio, link->url);
      g_object_set_data_full (G_OBJECT (radio), "lk-url", g_strdup (link->url), g_free);
      g_signal_connect (radio, "toggled", G_CALLBACK (lk_link_radio_toggled), settings);

      gtk_button_set_has_frame (GTK_BUTTON (refresh), FALSE);
      gtk_widget_set_valign (refresh, GTK_ALIGN_CENTER);
      gtk_widget_set_tooltip_text (refresh,
                                   "Re-read the link. A link that doesn't answer "
                                   "leaves the chart as it is.");
      g_object_set_data_full (G_OBJECT (refresh), "lk-url", g_strdup (link->url), g_free);
      g_signal_connect (refresh, "clicked", G_CALLBACK (lk_link_refresh_clicked), settings);

      gtk_button_set_has_frame (GTK_BUTTON (remove), FALSE);
      gtk_widget_set_valign (remove, GTK_ALIGN_CENTER);
      gtk_widget_set_tooltip_text (remove, "Forget this link");
      gtk_accessible_update_property (GTK_ACCESSIBLE (remove),
                                      GTK_ACCESSIBLE_PROPERTY_LABEL, "Forget this link", -1);
      g_object_set_data_full (G_OBJECT (remove), "lk-url", g_strdup (link->url), g_free);
      g_signal_connect (remove, "clicked", G_CALLBACK (lk_link_remove_clicked), settings);

      gtk_box_append (GTK_BOX (row), radio);
      gtk_box_append (GTK_BOX (row), refresh);
      gtk_box_append (GTK_BOX (row), remove);
      gtk_box_append (GTK_BOX (list), row);
    }

  /* A resolve is several fetches deep, so say so rather than leave the list
   * looking as though the click did nothing. */
  if (lk_chart_links_busy (links))
    {
      GtkWidget *label = gtk_label_new ("Reading the chart…");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_widget_add_css_class (label, "caption");
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (list), label);
    }

  if (error[0] != '\0')
    {
      GtkWidget *label = gtk_label_new (error);
      gtk_widget_add_css_class (label, "error");
      gtk_widget_add_css_class (label, "caption");
      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (list), label);
    }
  settings->updating = FALSE;
}

static gboolean
lk_settings_refill_links (gpointer user_data)
{
  LkSettings *settings = user_data;

  settings->links_refresh_id = 0;
  lk_settings_fill_links_list (settings);
  return G_SOURCE_REMOVE;
}

/* Same idle deferral as the raster list: a radio here changes the links
 * object, which signals straight back, and rebuilding now would destroy the
 * radio that is still emitting. */
static void
lk_settings_links_changed (LkChartLinks *links, gpointer user_data)
{
  LkSettings *settings = g_object_get_data (G_OBJECT (user_data), "lk-settings");

  if (settings == NULL || settings->links_list == NULL || settings->links_refresh_id != 0)
    return;

  settings->links_refresh_id = g_idle_add (lk_settings_refill_links, settings);
}

/* ---- the chart library --------------------------------------------------- */

static void
lk_chart_set_toggled (GtkSwitch *widget, GParamSpec *pspec, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *path = g_object_get_data (G_OBJECT (widget), "lk-path");

  if (settings->updating)
    return;
  lk_app_model_set_chart_set_on (settings->model, path, gtk_switch_get_active (widget));
}

/* The removal question outlives the button that raised it, so it carries the
   window (held by a reference) and the set's path. The settings struct hangs
   off the window, so a settings window closed while the question stands is not
   freed under the answer. */
typedef struct {
  GtkWindow *window; /* reffed */
  char      *path;
} LkSetRemoveAsk;

static void
lk_set_remove_ask_free (LkSetRemoveAsk *ask)
{
  g_clear_object (&ask->window);
  g_free (ask->path);
  g_free (ask);
}

/* The reference's estimate: about 0.2 s to rebuild each prepared chart. */
static char *
lk_rebuild_estimate (guint charts)
{
  double seconds = charts * 0.2;

  if (seconds < 60)
    return g_strdup ("under a minute");
  if (seconds < 3600)
    return g_strdup_printf ("about %d minutes", (int) ((seconds / 60) + 0.5));
  return g_strdup_printf ("about %.1f hours", seconds / 3600);
}

static void
lk_chart_set_remove_answered (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkSetRemoveAsk *ask = user_data;
  g_autoptr (GError) error = NULL;
  int chosen = gtk_alert_dialog_choose_finish (GTK_ALERT_DIALOG (source), result, &error);

  /* Cancel is 0, Remove is 1. Act only while the window still stands. */
  if (chosen == 1 && ask->window != NULL &&
      !gtk_widget_in_destruction (GTK_WIDGET (ask->window)))
    {
      LkSettings *settings = g_object_get_data (G_OBJECT (ask->window), "lk-settings");
      if (settings != NULL)
        lk_app_model_remove_chart_set (settings->model, ask->path);
    }

  lk_set_remove_ask_free (ask);
}

/* Removing a set deletes the charts Lookout prepared from it, and re-adding it
 * rebuilds them, so the removal is asked about first — as the reference does. */
static void
lk_chart_set_remove_clicked (GtkButton *button, gpointer user_data)
{
  const char *path = g_object_get_data (G_OBJECT (button), "lk-path");
  const char *name = g_object_get_data (G_OBJECT (button), "lk-set-title");
  guint charts = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (button), "lk-set-charts"));
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
  g_autofree char *question = g_strdup_printf ("Remove %s?", name != NULL ? name : "this set");
  static const char *answers[] = { "Cancel", "Remove and delete prepared charts", NULL };

  g_autofree char *detail = NULL;
  if (charts > 0)
    {
      g_autofree char *estimate = lk_rebuild_estimate (charts);
      detail = g_strdup_printf ("This deletes the %u charts Lookout prepared from it. Your "
                                "folder is not touched. Re-adding it rebuilds them, %s.",
                                charts, estimate);
    }
  else
    detail = g_strdup ("This deletes the charts Lookout prepared from it. Your folder "
                       "is not touched.");

  GtkAlertDialog *dialog = gtk_alert_dialog_new ("%s", question);
  gtk_alert_dialog_set_detail (dialog, detail);
  gtk_alert_dialog_set_buttons (dialog, answers);
  gtk_alert_dialog_set_cancel_button (dialog, 0);
  gtk_alert_dialog_set_default_button (dialog, 0);

  LkSetRemoveAsk *ask = g_new0 (LkSetRemoveAsk, 1);
  ask->window = GTK_IS_WINDOW (root) ? g_object_ref (GTK_WINDOW (root)) : NULL;
  ask->path = g_strdup (path);
  gtk_alert_dialog_choose (dialog, ask->window, NULL, lk_chart_set_remove_answered, ask);
  g_object_unref (dialog);
}

/* What is aboard, and what is being sailed on: a switch and a title per set,
 * the folder underneath so two sets from the same office are told apart, and
 * what the background scan counted once it has. */
static void
lk_settings_fill_sets_list (LkSettings *settings)
{
  GtkWidget *list = settings->sets_list;
  GtkWidget *child;

  settings->updating = TRUE;
  while ((child = gtk_widget_get_first_child (list)) != NULL)
    gtk_box_remove (GTK_BOX (list), child);

  g_autoptr (GPtrArray) rows = lk_app_model_get_chart_sets (settings->model);
  if (rows->len == 0)
    {
      GtkWidget *empty = gtk_label_new ("No chart sets yet");
      gtk_widget_add_css_class (empty, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (empty), 0.0);
      gtk_box_append (GTK_BOX (list), empty);
      settings->updating = FALSE;
      return;
    }

  for (guint i = 0; i < rows->len; i++)
    {
      const LkChartSetRow *set = g_ptr_array_index (rows, i);
      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      GtkWidget *toggle = lk_raster_switch (set->on);
      GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 1);
      GtkWidget *title = gtk_label_new (set->title);
      g_autofree char *base = g_path_get_basename (set->path);
      GtkWidget *where = gtk_label_new (base);
      GtkWidget *remove = gtk_button_new_from_icon_name ("list-remove-symbolic");

      gtk_widget_add_css_class (title, "heading");
      gtk_label_set_xalign (GTK_LABEL (title), 0.0);
      gtk_label_set_ellipsize (GTK_LABEL (title), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class (where, "dim-label");
      gtk_widget_add_css_class (where, "caption");
      gtk_label_set_xalign (GTK_LABEL (where), 0.0);
      gtk_label_set_ellipsize (GTK_LABEL (where), PANGO_ELLIPSIZE_MIDDLE);
      /* The agency title can hide the folder name; the tooltip keeps the
       * whole path reachable. */
      gtk_widget_set_tooltip_text (row, set->path);

      gtk_box_append (GTK_BOX (column), title);
      gtk_box_append (GTK_BOX (column), where);
      if (set->detail[0] != '\0')
        {
          GtkWidget *detail = gtk_label_new (set->detail);
          gtk_widget_add_css_class (detail, "dim-label");
          gtk_widget_add_css_class (detail, "caption");
          gtk_label_set_xalign (GTK_LABEL (detail), 0.0);
          gtk_label_set_ellipsize (GTK_LABEL (detail), PANGO_ELLIPSIZE_END);
          gtk_box_append (GTK_BOX (column), detail);
        }
      gtk_widget_set_hexpand (column, TRUE);

      gtk_button_set_has_frame (GTK_BUTTON (remove), FALSE);
      gtk_widget_set_valign (remove, GTK_ALIGN_CENTER);
      gtk_widget_set_tooltip_text (remove,
                                   "Remove from the library. Charts Lookout prepared "
                                   "from it are deleted; your folder is not touched.");
      gtk_accessible_update_property (GTK_ACCESSIBLE (remove),
                                      GTK_ACCESSIBLE_PROPERTY_LABEL, "Remove chart set", -1);

      g_object_set_data_full (G_OBJECT (toggle), "lk-path", g_strdup (set->path), g_free);
      g_object_set_data_full (G_OBJECT (remove), "lk-path", g_strdup (set->path), g_free);
      g_object_set_data_full (G_OBJECT (remove), "lk-set-title", g_strdup (set->title), g_free);
      g_object_set_data (G_OBJECT (remove), "lk-set-charts", GUINT_TO_POINTER (set->charts));
      g_signal_connect (toggle, "notify::active", G_CALLBACK (lk_chart_set_toggled), settings);
      g_signal_connect (remove, "clicked", G_CALLBACK (lk_chart_set_remove_clicked), settings);

      gtk_box_append (GTK_BOX (row), toggle);
      gtk_box_append (GTK_BOX (row), column);
      gtk_box_append (GTK_BOX (row), remove);
      gtk_box_append (GTK_BOX (list), row);
    }
  settings->updating = FALSE;
}

static gboolean
lk_settings_refill_sets (gpointer user_data)
{
  LkSettings *settings = user_data;

  settings->sets_refresh_id = 0;
  lk_settings_fill_sets_list (settings);
  return G_SOURCE_REMOVE;
}

static void
lk_settings_sets_changed (LkAppModel *model, gpointer user_data)
{
  LkSettings *settings = g_object_get_data (G_OBJECT (user_data), "lk-settings");

  if (settings == NULL || settings->sets_list == NULL || settings->sets_refresh_id != 0)
    return;

  settings->sets_refresh_id = g_idle_add (lk_settings_refill_sets, settings);
}

static void
lk_build_charts_page (LkSettings *settings)
{
  GtkWidget *page = lk_page_new (settings, "charts", "Charts",
                                 "lk-charts-symbolic");

  /* WHICH chart is drawn, before where to get more of them. A chart by link
   * is a different kind again — a publisher's live map drawn AS the chart —
   * and picking one replaces the whole portrayal, so the election stands
   * first, as it does on the other shells. */
  GtkWidget *chart = lk_section (page, "Chart");
  settings->links_list = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);
  gtk_box_append (GTK_BOX (chart), settings->links_list);
  lk_settings_fill_links_list (settings);

  GtkWidget *link_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *link_entry = gtk_entry_new ();
  GtkWidget *link_add = gtk_button_new_with_label ("Add Chart Link");

  gtk_entry_set_placeholder_text (GTK_ENTRY (link_entry),
                                  "Link to a MapLibre style or TileJSON…");
  gtk_widget_set_hexpand (link_entry, TRUE);
  g_signal_connect (link_entry, "activate", G_CALLBACK (lk_link_entry_activated), settings);
  g_object_set_data (G_OBJECT (link_add), "lk-entry", link_entry);
  g_signal_connect (link_add, "clicked", G_CALLBACK (lk_link_add_clicked), settings);
  gtk_widget_set_margin_top (link_row, 6);
  gtk_box_append (GTK_BOX (link_row), link_entry);
  gtk_box_append (GTK_BOX (link_row), link_add);
  gtk_box_append (GTK_BOX (chart), link_row);

  lk_footer (chart,
             "A chart by link is an online map drawn as the chart: paste the "
             "style link a publisher shares and sail on their portrayal, tiles "
             "fetched live. The Lookout chart and its display settings stand "
             "aside while one is picked.");

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

  /* The library: the sets aboard, each with its switch. This is what decides
   * the chart; Open above only reports what is on screen now. */
  GtkWidget *library = lk_section (page, "Chart library");
  settings->sets_list = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
  gtk_box_append (GTK_BOX (library), settings->sets_list);
  lk_settings_fill_sets_list (settings);
  lk_footer (library,
             "Each folder or archive added is a set. The chart is every set "
             "switched on, drawn as one seamless library; a set switched off "
             "stays aboard and out of the chart.");

  GtkWidget *add = lk_section (page, NULL);
  GtkWidget *add_buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *button = gtk_button_new_with_label ("Add Folder…");
  GtkWidget *archive = gtk_button_new_with_label ("Add Archive…");

  g_signal_connect (button, "clicked", G_CALLBACK (lk_charts_open_clicked), settings);
  g_signal_connect (archive, "clicked", G_CALLBACK (lk_charts_archive_clicked), settings);
  gtk_box_append (GTK_BOX (add_buttons), button);
  gtk_box_append (GTK_BOX (add_buttons), archive);
  gtk_widget_set_halign (add_buttons, GTK_ALIGN_START);
  gtk_box_append (GTK_BOX (add), add_buttons);
  lk_footer (add,
             "A folder of cells, or the .zip a chart agency publishes, opens as one "
             "seamless library. Cells that arrive as raw S-57 survey data are prepared "
             "first, coarse charts before harbour detail, so a passage is covered even "
             "if the import is stopped part way. An archive is read where it lies: "
             "nothing is unpacked.");

  /* A raster chart is a different KIND of chart, so it gets its own section
   * rather than a mixed list: one is the survey, the other is a picture of the
   * water, and a mariner must never lose track of which is which. */
  GtkWidget *raster = lk_section (page, "Raster charts");
  settings->raster_list = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);
  gtk_box_append (GTK_BOX (raster), settings->raster_list);
  lk_settings_fill_raster_list (settings);

  GtkWidget *raster_buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *add_files = gtk_button_new_with_label ("Add Raster Charts…");
  GtkWidget *add_folder = gtk_button_new_with_label ("Add Folder…");

  g_signal_connect (add_files, "clicked", G_CALLBACK (lk_raster_add_clicked), settings);
  g_signal_connect (add_folder, "clicked", G_CALLBACK (lk_raster_add_folder_clicked), settings);
  gtk_box_append (GTK_BOX (raster_buttons), add_files);
  gtk_box_append (GTK_BOX (raster_buttons), add_folder);
  gtk_widget_set_halign (raster_buttons, GTK_ALIGN_START);
  gtk_widget_set_margin_top (raster_buttons, 6);
  gtk_box_append (GTK_BOX (raster), raster_buttons);

  lk_footer (raster,
             "Charts made of pictures: MBTiles of satellite imagery or another "
             "vendor's charts, and BSB/KAP raster nautical charts baked with tile57. "
             "The ENC draws over them and drops its depth and land shading only "
             "where they cover. Switch one off to keep it installed without "
             "drawing it.");

  lk_plugin_fill_tab (page, settings, "charts");
}

/* Commits on Enter or focus loss, never per keystroke — half a date is not a
   date the chart should redraw against. */
static void
lk_date_commit (GtkEntry *entry, gpointer user_data)
{
  LkSettings *settings = user_data;
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  if (settings->updating)
    return;

  memset (m->date_view, 0, sizeof m->date_view);
  g_strlcpy (m->date_view, gtk_editable_get_text (GTK_EDITABLE (entry)), sizeof m->date_view);
  lk_mariner_touch (settings->mariner);
}

static void
lk_date_focus_left (GtkEventControllerFocus *focus, gpointer user_data)
{
  GtkWidget *entry = gtk_event_controller_get_widget (GTK_EVENT_CONTROLLER (focus));
  lk_date_commit (GTK_ENTRY (entry), user_data);
}

static void
lk_settings_licenses_clicked (GtkButton *button, gpointer user_data)
{
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
  GtkWindow *window = GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL;

  /* The MAIN window is the parent, not this panel: the licenses stay open when
   * the settings are closed. */
  lk_licenses_window_present (window != NULL ? gtk_window_get_transient_for (window) : NULL,
                              NULL);
}

/* What this build is: its version, the chart engine it is pinned to, and the
 * way to the terms it and its components carry. It stands at the foot of the
 * last page, as it does on the Mac (macos/LookoutMarine/SettingsView.swift). */
static void
lk_settings_about_section (GtkWidget *page)
{
  const GPtrArray *components = lk_licenses_components ();
  const LkLicenseComponent *engine = lk_licenses_component ("tile57");
  GtkWidget *about = lk_section (page, "About");
  GtkWidget *version = gtk_label_new (lk_licenses_app_version ());

  gtk_widget_add_css_class (version, "numeric");
  gtk_widget_add_css_class (version, "dim-label");
  gtk_label_set_selectable (GTK_LABEL (version), TRUE);
  lk_row (about, "Version", version);

  if (engine != NULL)
    {
      g_autofree char *pin = lk_licenses_pin (engine);
      g_autofree char *text = g_strdup_printf ("%s · %s", engine->name, pin);
      GtkWidget *label = gtk_label_new (text);

      gtk_widget_add_css_class (label, "monospace");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_label_set_selectable (GTK_LABEL (label), TRUE);
      lk_row (about, "Chart engine", label);
    }

  /* The ellipsis promises a window, which is where a license has the width to
   * be read whole. */
  GtkWidget *button = gtk_button_new_with_label ("Licenses…");

  gtk_widget_set_halign (button, GTK_ALIGN_START);
  gtk_widget_set_margin_top (button, 6);
  g_signal_connect (button, "clicked", G_CALLBACK (lk_settings_licenses_clicked), NULL);
  gtk_box_append (GTK_BOX (about), button);

  g_autofree char *footer =
      g_strdup_printf ("This app's terms, and the %u components it is built from. "
                       "Every license is carried whole and needs no connection.",
                       components->len);
  lk_footer (about, footer);
}

static void
lk_build_advanced_page (LkSettings *settings)
{
  GtkWidget *page = lk_page_new (settings, "advanced", "Advanced",
                                 "lk-advanced-symbolic");
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
  g_signal_connect (entry, "activate", G_CALLBACK (lk_date_commit), settings);
  GtkEventController *date_focus = gtk_event_controller_focus_new ();
  g_signal_connect (date_focus, "leave", G_CALLBACK (lk_date_focus_left), settings);
  gtk_widget_add_controller (entry, date_focus);
  lk_row (dates, "View date", entry);
  lk_footer (dates, "Leave the date empty to use today.");

  lk_plugin_fill_tab (page, settings, "advanced");

  /* Last on the page, under whatever a plugin filed here: About says what this
   * build is, and nothing is filed under it. */
  lk_settings_about_section (page);
}

/* ---- the plugins' own controls ------------------------------------------- */
/*
 * A plugin declares a settings schema in its manifest and the core hands the
 * whole registry over as JSON; plugins/registry.c turns that into groups, lists and
 * rows, and this draws them with the same builders the app's own settings use.
 * The mariner is never told which of these came from a plugin: an AIS alarm is
 * a chart setting that happens to be served by one.
 */

/* One control's sentence, under the control it explains. */
static void
lk_plugin_desc (GtkWidget *section, const char *desc)
{
  if (desc == NULL || desc[0] == '\0')
    return;

  GtkWidget *label = lk_footer (section, desc);

  /* Tucked under the row above rather than floating between two of them. */
  gtk_widget_set_margin_top (label, -2);
}

typedef struct {
  LkSettings *settings;
  char       *plugin_id;
  char       *key;
} LkPluginBinding;

static void
lk_plugin_binding_free (gpointer data, GClosure *closure)
{
  LkPluginBinding *binding = data;

  g_free (binding->plugin_id);
  g_free (binding->key);
  g_free (binding);
}

static LkPluginBinding *
lk_plugin_binding_new (LkSettings *settings, const char *plugin_id, const char *key)
{
  LkPluginBinding *binding = g_new0 (LkPluginBinding, 1);

  binding->settings = settings;
  /* Copied: every borrowed string in the schema dies with the registry, and a
   * widget outlives a reload. */
  binding->plugin_id = g_strdup (plugin_id);
  binding->key = g_strdup (key);
  return binding;
}

static void
lk_plugin_toggle_changed (GtkCheckButton *button, gpointer user_data)
{
  LkPluginBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_value (binding->settings->plugins, binding->plugin_id, binding->key,
                        gtk_check_button_get_active (button) ? 1 : 0);
}

static void
lk_plugin_number_changed (GtkSpinButton *spin, gpointer user_data)
{
  LkPluginBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_value (binding->settings->plugins, binding->plugin_id, binding->key,
                        gtk_spin_button_get_value (spin));
}

/* A spin button's step suits the range it covers: metres of CPA move in tens,
 * minutes and knots one at a time. */
static double
lk_plugin_step (const LkPluginField *field)
{
  double span = field->max - field->min;

  if (span > 100)
    return 10;
  if (span > 10)
    return 1;
  return 0.5;
}

/* A number's digits follow its step, so a whole-number range shows no ".0". */
static guint
lk_plugin_digits (double step)
{
  return step < 1 ? 1 : 0;
}

/* Returns the control, which is what "Reset to defaults" has to put back. */
static GtkWidget *
lk_plugin_scalar_row (GtkWidget           *section,
                      LkSettings          *settings,
                      const char          *plugin_id,
                      const LkPluginField *field)
{
  double value = lk_plugins_value (settings->plugins, plugin_id, field->key);

  if (field->kind == LK_PLUGIN_FIELD_TOGGLE)
    {
      GtkWidget *check = gtk_check_button_new ();

      gtk_check_button_set_active (GTK_CHECK_BUTTON (check), value != 0);
      gtk_widget_set_valign (check, GTK_ALIGN_CENTER);
      g_signal_connect_data (check, "toggled", G_CALLBACK (lk_plugin_toggle_changed),
                             lk_plugin_binding_new (settings, plugin_id, field->key),
                             lk_plugin_binding_free, 0);
      lk_row (section, field->label, check);
      lk_plugin_desc (section, field->desc);
      return check;
    }

  /* A number. The unit rides on the control rather than in the label, which is
   * where the range the manifest set is legible beside what it means. */
  double step = lk_plugin_step (field);
  GtkWidget *spin = gtk_spin_button_new_with_range (field->min, field->max, step);

  gtk_spin_button_set_digits (GTK_SPIN_BUTTON (spin), lk_plugin_digits (step));
  gtk_spin_button_set_value (GTK_SPIN_BUTTON (spin), value);
  gtk_widget_set_valign (spin, GTK_ALIGN_CENTER);
  g_signal_connect_data (spin, "value-changed", G_CALLBACK (lk_plugin_number_changed),
                         lk_plugin_binding_new (settings, plugin_id, field->key),
                         lk_plugin_binding_free, 0);

  if (field->unit[0] == '\0')
    {
      lk_row (section, field->label, spin);
    }
  else
    {
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
      GtkWidget *unit = gtk_label_new (field->unit);

      gtk_widget_add_css_class (unit, "dim-label");
      gtk_widget_set_valign (unit, GTK_ALIGN_CENTER);
      gtk_box_append (GTK_BOX (box), spin);
      gtk_box_append (GTK_BOX (box), unit);
      lk_row (section, field->label, box);
    }
  lk_plugin_desc (section, field->desc);
  return spin;
}

static void
lk_plugin_reset_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const LkPluginGroup *group = g_object_get_data (G_OBJECT (button), "lk-group");

  lk_plugins_reset_group (settings->plugins, group);

  /* The controls hold the old numbers. Reprogramming them must not read back
   * as the mariner moving each one. */
  settings->updating = TRUE;
  for (guint i = 0; i < group->fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (group->fields, i);
      g_autofree char *data_key = g_strdup_printf ("lk-field-%s", field->key);
      GtkWidget *widget = g_object_get_data (G_OBJECT (button), data_key);

      if (widget == NULL)
        continue;
      if (field->kind == LK_PLUGIN_FIELD_TOGGLE)
        gtk_check_button_set_active (GTK_CHECK_BUTTON (widget), field->fallback != 0);
      else
        gtk_spin_button_set_value (GTK_SPIN_BUTTON (widget), field->fallback);
    }
  settings->updating = FALSE;
}

/* ---- the rows of a list -------------------------------------------------- */

typedef struct {
  LkSettings         *settings;
  const LkPluginList *list;
  char               *row_id;
  char               *key;
} LkPluginRowBinding;

static void
lk_plugin_row_binding_free (gpointer data, GClosure *closure)
{
  LkPluginRowBinding *binding = data;

  g_free (binding->row_id);
  g_free (binding->key);
  g_free (binding);
}

static LkPluginRowBinding *
lk_plugin_row_binding_new (LkSettings         *settings,
                           const LkPluginList *list,
                           const char         *row_id,
                           const char         *key)
{
  LkPluginRowBinding *binding = g_new0 (LkPluginRowBinding, 1);

  binding->settings = settings;
  binding->list = list;
  binding->row_id = g_strdup (row_id);
  binding->key = g_strdup (key);
  return binding;
}

static void lk_plugin_schedule_refill (LkSettings *settings, const LkPluginList *list);

static void
lk_plugin_cell_text_changed (GtkEditable *editable, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_row_text (binding->settings->plugins, binding->list, binding->row_id,
                           binding->key, gtk_editable_get_text (editable));
}

/* GDestroyNotify shape for the binding, for when it rides on the widget
   rather than a signal closure. */
static void
lk_plugin_row_binding_destroy (gpointer data)
{
  lk_plugin_row_binding_free (data, NULL);
}

/* Commits on Enter or focus loss, never per keystroke: an address pushed
   letter-by-letter dials "1", "10", "10.0"… and the plugin churns through
   partial hosts while the mariner is mid-word (the Mac shell's
   CommitTextField rule). */
static void
lk_plugin_cell_text_commit (GtkEntry *entry, gpointer user_data)
{
  (void) user_data;
  gpointer binding = g_object_get_data (G_OBJECT (entry), "lk-cell-binding");

  if (binding != NULL)
    lk_plugin_cell_text_changed (GTK_EDITABLE (entry), binding);
}

static void
lk_plugin_cell_focus_left (GtkEventControllerFocus *focus, gpointer user_data)
{
  (void) user_data;
  GtkWidget *entry = gtk_event_controller_get_widget (GTK_EVENT_CONTROLLER (focus));

  lk_plugin_cell_text_commit (GTK_ENTRY (entry), NULL);
}

static void
lk_plugin_cell_number_changed (GtkSpinButton *spin, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_row_number (binding->settings->plugins, binding->list, binding->row_id,
                             binding->key, gtk_spin_button_get_value (spin));
}

static void
lk_plugin_cell_toggle_changed (GtkSwitch *widget, GParamSpec *pspec, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_row_toggle (binding->settings->plugins, binding->list, binding->row_id,
                             binding->key, gtk_switch_get_active (widget));
}

static void
lk_plugin_row_remove_clicked (GtkButton *button, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  lk_plugins_remove_row (binding->settings->plugins, binding->list, binding->row_id);
  lk_plugin_schedule_refill (binding->settings, binding->list);
}

static void
lk_plugin_row_add_clicked (GtkButton *button, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  lk_plugins_add_row (binding->settings->plugins, binding->list);
  lk_plugin_schedule_refill (binding->settings, binding->list);
}

/* What the mariner named this row, or the address it dials. */
static char *
lk_plugin_row_title (LkSettings *settings, const LkPluginList *list, const char *row_id)
{
  const char *name = lk_plugins_row_text (settings->plugins, list, row_id, "name");

  if (name[0] != '\0')
    return g_strdup (name);

  const char *host = lk_plugins_row_text (settings->plugins, list, row_id, "host");
  if (host[0] == '\0')
    return g_strdup ("New connection");

  return g_strdup_printf ("%s:%d", host,
                          (int) lk_plugins_row_number (settings->plugins, list, row_id, "port"));
}

/* The label that carries a row's live state, remembered so the poll can move it
 * without rebuilding the row under a mariner who is typing in it. */
static GtkWidget *
lk_plugin_status_label (LkSettings *settings, const LkPluginList *list, const char *row_id)
{
  GtkWidget *label = gtk_label_new (NULL);

  gtk_widget_add_css_class (label, "caption");
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  g_object_set_data (G_OBJECT (label), "lk-list", (gpointer) list);
  g_object_set_data_full (G_OBJECT (label), "lk-row-id", g_strdup (row_id), g_free);
  g_ptr_array_add (settings->status_labels, label);
  return label;
}

/* Put one status line on one label: the words, and the colour it reads in. */
static void
lk_plugin_apply_status (GtkWidget *label, char *line, const char *css_class)
{
  const char *previous = g_object_get_data (G_OBJECT (label), "lk-status-class");

  if (previous != NULL)
    gtk_widget_remove_css_class (label, previous);

  if (line == NULL)
    {
      /* The plugin has not spoken for this row yet. An empty line is honest;
       * an invented one would say "connected" about a socket nobody opened. */
      gtk_label_set_text (GTK_LABEL (label), "");
      gtk_widget_add_css_class (label, "dim-label");
      g_object_set_data (G_OBJECT (label), "lk-status-class", (gpointer) "dim-label");
      return;
    }

  gtk_label_set_text (GTK_LABEL (label), line);
  g_free (line);
  gtk_widget_add_css_class (label, css_class);
  g_object_set_data (G_OBJECT (label), "lk-status-class", (gpointer) css_class);
}

static void
lk_plugin_refresh_status_labels (LkSettings *settings)
{
  for (guint i = 0; i < settings->status_labels->len; i++)
    {
      GtkWidget *label = g_ptr_array_index (settings->status_labels, i);
      const LkPluginList *list = g_object_get_data (G_OBJECT (label), "lk-list");
      const char *css_class = "dim-label";
      char *line;

      if (list != NULL)
        {
          const char *row_id = g_object_get_data (G_OBJECT (label), "lk-row-id");

          line = lk_plugins_row_status (settings->plugins, list, row_id, &css_class);
        }
      else
        {
          const char *plugin_id = g_object_get_data (G_OBJECT (label), "lk-plugin-id");

          line = lk_plugins_status_line (settings->plugins, plugin_id, &css_class);
        }
      lk_plugin_apply_status (label, line, css_class);
    }
}

/* A connection's line has to move on its own: "Reconnecting" that never becomes
 * "Connected" is how a mariner learns the address is wrong. */
static gboolean
lk_plugin_status_poll (gpointer user_data)
{
  LkSettings *settings = user_data;

  if (lk_plugins_refresh_status (settings->plugins))
    lk_plugin_refresh_status_labels (settings);
  return G_SOURCE_CONTINUE;
}

/* One row: what it is called and what it is doing, a switch that pauses it, and
 * — folded away until it is wanted — the address behind it. The mariner reads
 * the first line and touches nothing else most days. */
static void
lk_plugin_fill_row (LkSettings *settings, GtkWidget *box,
                    const LkPluginList *list, const char *row_id)
{
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *expander = gtk_expander_new (NULL);
  GtkWidget *summary = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  g_autofree char *title = lk_plugin_row_title (settings, list, row_id);
  GtkWidget *name = gtk_label_new (title);
  GtkWidget *status = lk_plugin_status_label (settings, list, row_id);

  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_widget_add_css_class (name, "heading");
  gtk_box_append (GTK_BOX (summary), name);
  gtk_box_append (GTK_BOX (summary), status);

  gtk_expander_set_label_widget (GTK_EXPANDER (expander), summary);
  /* A row with no address cannot work yet, so it opens itself: the mariner has
   * to type one, and hunting for a disclosure triangle to find that out is not
   * a task. */
  gtk_expander_set_expanded (GTK_EXPANDER (expander),
                             lk_plugins_row_text (settings->plugins, list, row_id, "host")[0] == '\0');
  gtk_widget_set_hexpand (expander, TRUE);
  gtk_box_append (GTK_BOX (header), expander);

  /* The row's own on/off switch stands OUTSIDE the expander, on the line where
   * it is read at a glance: pausing a connection must not need it opened. */
  if (list->switch_key[0] != '\0')
    {
      GtkWidget *toggle = gtk_switch_new ();

      gtk_switch_set_active (GTK_SWITCH (toggle),
                             lk_plugins_row_toggle (settings->plugins, list, row_id,
                                                    list->switch_key));
      gtk_widget_set_valign (toggle, GTK_ALIGN_CENTER);
      g_signal_connect_data (toggle, "notify::active",
                             G_CALLBACK (lk_plugin_cell_toggle_changed),
                             lk_plugin_row_binding_new (settings, list, row_id, list->switch_key),
                             lk_plugin_row_binding_free, 0);
      gtk_box_append (GTK_BOX (header), toggle);
    }

  gtk_widget_set_margin_top (header, 6);
  gtk_box_append (GTK_BOX (box), header);

  GtkWidget *fields = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_set_margin_start (fields, 22);
  gtk_widget_set_margin_top (fields, 6);
  gtk_expander_set_child (GTK_EXPANDER (expander), fields);

  for (guint i = 0; i < list->item_fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (list->item_fields, i);

      /* Every column but the one already drawn on the row's line. */
      if (g_strcmp0 (field->key, list->switch_key) == 0)
        continue;

      GtkWidget *control = NULL;

      switch (field->kind)
        {
        case LK_PLUGIN_FIELD_TEXT:
          control = gtk_entry_new ();
          gtk_editable_set_text (GTK_EDITABLE (control),
                                 lk_plugins_row_text (settings->plugins, list, row_id, field->key));
          if (field->placeholder[0] != '\0')
            gtk_entry_set_placeholder_text (GTK_ENTRY (control), field->placeholder);
          else if (field->optional)
            gtk_entry_set_placeholder_text (GTK_ENTRY (control), "Optional");
          g_object_set_data_full (G_OBJECT (control), "lk-cell-binding",
                                  lk_plugin_row_binding_new (settings, list, row_id, field->key),
                                  lk_plugin_row_binding_destroy);
          g_signal_connect (control, "activate",
                            G_CALLBACK (lk_plugin_cell_text_commit), NULL);
          {
            GtkEventController *cell_focus = gtk_event_controller_focus_new ();
            g_signal_connect (cell_focus, "leave",
                              G_CALLBACK (lk_plugin_cell_focus_left), NULL);
            gtk_widget_add_controller (control, cell_focus);
          }
          break;

        case LK_PLUGIN_FIELD_NUMBER:
          {
            double step = lk_plugin_step (field);

            control = gtk_spin_button_new_with_range (field->min, field->max, step);
            gtk_spin_button_set_digits (GTK_SPIN_BUTTON (control), lk_plugin_digits (step));
            gtk_spin_button_set_value (GTK_SPIN_BUTTON (control),
                                       lk_plugins_row_number (settings->plugins, list,
                                                              row_id, field->key));
            g_signal_connect_data (control, "value-changed",
                                   G_CALLBACK (lk_plugin_cell_number_changed),
                                   lk_plugin_row_binding_new (settings, list, row_id, field->key),
                                   lk_plugin_row_binding_free, 0);
          }
          break;

        case LK_PLUGIN_FIELD_TOGGLE:
        default:
          control = gtk_switch_new ();
          gtk_switch_set_active (GTK_SWITCH (control),
                                 lk_plugins_row_toggle (settings->plugins, list,
                                                        row_id, field->key));
          g_signal_connect_data (control, "notify::active",
                                 G_CALLBACK (lk_plugin_cell_toggle_changed),
                                 lk_plugin_row_binding_new (settings, list, row_id, field->key),
                                 lk_plugin_row_binding_free, 0);
          break;
        }

      gtk_widget_set_valign (control, GTK_ALIGN_CENTER);
      lk_row (fields, field->label, control);
      lk_plugin_desc (fields, field->desc);
    }

  GtkWidget *remove = gtk_button_new_with_label ("Remove");
  gtk_widget_add_css_class (remove, "destructive-action");
  gtk_widget_set_halign (remove, GTK_ALIGN_START);
  g_signal_connect_data (remove, "clicked", G_CALLBACK (lk_plugin_row_remove_clicked),
                         lk_plugin_row_binding_new (settings, list, row_id, ""),
                         lk_plugin_row_binding_free, 0);
  gtk_box_append (GTK_BOX (fields), remove);
}

/* Drop the status labels of one list, so a refill does not leave the poll
 * writing into widgets that are no longer on the screen. */
static void
lk_plugin_forget_status_labels (LkSettings *settings, const LkPluginList *list)
{
  for (guint i = settings->status_labels->len; i > 0; i--)
    {
      GtkWidget *label = g_ptr_array_index (settings->status_labels, i - 1);

      if (g_object_get_data (G_OBJECT (label), "lk-list") == list)
        g_ptr_array_remove_index (settings->status_labels, i - 1);
    }
}

/* One find, and the list it would be added to. */
typedef struct {
  LkSettings         *settings;
  const LkPluginList *list;
  char               *service;
  char               *name;
  char               *host;
  int                 port;
} LkNearbyBinding;

static void
lk_nearby_binding_free (gpointer data, GClosure *closure)
{
  LkNearbyBinding *binding = data;

  g_free (binding->service);
  g_free (binding->name);
  g_free (binding->host);
  g_free (binding);
}

static void
lk_plugin_nearby_add_clicked (GtkButton *button, gpointer user_data)
{
  LkNearbyBinding *binding = user_data;

  lk_plugins_add_row_from (binding->settings->plugins, binding->list, binding->service,
                           binding->name, binding->host, binding->port);
  lk_plugin_schedule_refill (binding->settings, binding->list);
}

/* Is this find already in the list?
 *
 * A HOST the list points at is not offered again, whatever port the row uses.
 * One machine announces the port it wants to be reached on and is often
 * reachable on another — a Signal K server announces its websocket on 3000 and
 * carries the same boat on 8375 — so a second row to it would send everything
 * twice. */
static gboolean
lk_plugin_holds_host (LkSettings *settings, const LkPluginList *list, const char *host)
{
  g_autoptr (GPtrArray) rows = lk_plugins_rows (settings->plugins, list);

  for (guint i = 0; i < rows->len; i++)
    {
      const char *row_id = g_ptr_array_index (rows, i);
      const char *held = lk_plugins_row_text (settings->plugins, list, row_id, "host");

      if (g_ascii_strcasecmp (held, host) == 0)
        return TRUE;
    }
  return FALSE;
}

/* What is answering on the network for this list's service types, offered ready
 * to add. Nothing found draws nothing: at a desk that is the ordinary case, and
 * an empty heading is a question nobody asked. */
static void
lk_plugin_fill_nearby (LkSettings *settings, const LkPluginList *list, GtkWidget *box)
{
  if (settings->discovery == NULL || list->discover->len == 0
      || lk_plugins_list_is_full (settings->plugins, list))
    return;

  const GPtrArray *found = lk_discovery_found (settings->discovery);

  for (guint i = 0; i < found->len; i++)
    {
      const LkDiscovered *service = g_ptr_array_index (found, i);
      gboolean wanted = FALSE;

      for (guint d = 0; d < list->discover->len; d++)
        {
          const LkPluginDiscover *want = g_ptr_array_index (list->discover, d);

          if (g_strcmp0 (want->service, service->service) == 0)
            {
              wanted = TRUE;
              break;
            }
        }
      if (!wanted || lk_plugin_holds_host (settings, list, service->host))
        continue;

      GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
      GtkWidget *text = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
      GtkWidget *name = gtk_label_new (service->name);
      g_autofree char *where = g_strdup_printf ("%s:%d", service->host, service->port);
      GtkWidget *address = gtk_label_new (where);
      GtkWidget *add = gtk_button_new_from_icon_name ("list-add-symbolic");
      LkNearbyBinding *binding = g_new0 (LkNearbyBinding, 1);

      gtk_label_set_xalign (GTK_LABEL (name), 0.0);
      gtk_label_set_xalign (GTK_LABEL (address), 0.0);
      gtk_widget_add_css_class (address, "dim-label");
      gtk_box_append (GTK_BOX (text), name);
      gtk_box_append (GTK_BOX (text), address);
      gtk_widget_set_hexpand (text, TRUE);
      gtk_box_append (GTK_BOX (line), text);

      binding->settings = settings;
      binding->list = list;
      binding->service = g_strdup (service->service);
      binding->name = g_strdup (service->name);
      binding->host = g_strdup (service->host);
      binding->port = service->port;

      gtk_widget_set_tooltip_text (add, "Add this source");
      gtk_widget_set_valign (add, GTK_ALIGN_CENTER);
      g_signal_connect_data (add, "clicked", G_CALLBACK (lk_plugin_nearby_add_clicked), binding,
                             lk_nearby_binding_free, 0);
      gtk_box_append (GTK_BOX (line), add);
      gtk_box_append (GTK_BOX (box), line);
    }
}

static void
lk_plugin_fill_rows (LkSettings *settings, const LkPluginList *list, GtkWidget *box)
{
  GtkWidget *child;

  lk_plugin_forget_status_labels (settings, list);
  while ((child = gtk_widget_get_first_child (box)) != NULL)
    gtk_box_remove (GTK_BOX (box), child);

  g_autoptr (GPtrArray) rows = lk_plugins_rows (settings->plugins, list);

  if (rows->len == 0)
    {
      GtkWidget *empty = gtk_label_new (list->empty);

      gtk_widget_add_css_class (empty, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (empty), 0.0);
      gtk_box_append (GTK_BOX (box), empty);
    }

  for (guint i = 0; i < rows->len; i++)
    lk_plugin_fill_row (settings, box, list, g_ptr_array_index (rows, i));

  lk_plugin_fill_nearby (settings, list, box);

  GtkWidget *add = gtk_button_new_with_label (list->add_label);
  gboolean full = lk_plugins_list_is_full (settings->plugins, list);

  gtk_widget_set_halign (add, GTK_ALIGN_START);
  gtk_widget_set_margin_top (add, 8);
  /* AT THE CAP THERE IS NOTHING TO ADD: the core keeps max_rows and drops the
   * rest, so a mariner who typed a ninth gateway address would be left with a
   * row that looks like the other eight and never connects. */
  gtk_widget_set_sensitive (add, !full);
  g_signal_connect_data (add, "clicked", G_CALLBACK (lk_plugin_row_add_clicked),
                         lk_plugin_row_binding_new (settings, list, "", ""),
                         lk_plugin_row_binding_free, 0);
  gtk_box_append (GTK_BOX (box), add);

  if (full)
    {
      g_autofree char *note = g_strdup_printf ("%d is the most this list holds. "
                                               "Remove one to add another.",
                                               list->max_rows);
      lk_footer (box, note);
    }

  lk_plugin_refresh_status_labels (settings);
}

/* A button in a list changes the model, which brings us straight back here.
 * Rebuilding now would free the button that is still emitting, so the refill
 * waits for the next idle. */
static gboolean
lk_plugin_refill_lists (gpointer user_data)
{
  LkSettings *settings = user_data;

  settings->list_refill_id = 0;
  for (guint i = 0; i < settings->pending_lists->len; i++)
    {
      const LkPluginList *list = g_ptr_array_index (settings->pending_lists, i);
      g_autofree char *key = g_strdup_printf ("%s/%s", list->plugin_id, list->key);
      GtkWidget *box = g_hash_table_lookup (settings->list_boxes, key);

      if (box != NULL)
        lk_plugin_fill_rows (settings, list, box);
    }
  g_ptr_array_set_size (settings->pending_lists, 0);
  return G_SOURCE_REMOVE;
}

static void
lk_plugin_schedule_refill (LkSettings *settings, const LkPluginList *list)
{
  if (!g_ptr_array_find (settings->pending_lists, list, NULL))
    g_ptr_array_add (settings->pending_lists, (gpointer) list);

  if (settings->list_refill_id == 0)
    settings->list_refill_id = g_idle_add (lk_plugin_refill_lists, settings);
}

/* ---- what a plugin put in one settings section --------------------------- */

/* Append the groups and lists a plugin filed under `tab`. Draws nothing when it
 * filed none, which is what keeps a section the app owns looking untouched. */
static void
lk_plugin_fill_tab (GtkWidget *page, LkSettings *settings, const char *tab)
{
  if (settings->plugins == NULL)
    return;

  g_autoptr (GPtrArray) groups = lk_plugins_groups (settings->plugins, tab);

  for (guint i = 0; i < groups->len; i++)
    {
      const LkPluginGroup *group = g_ptr_array_index (groups, i);
      GtkWidget *section = lk_section (page, group->title);
      GtkWidget *reset = gtk_button_new_with_label ("Reset to defaults");

      for (guint f = 0; f < group->fields->len; f++)
        {
          const LkPluginField *field = g_ptr_array_index (group->fields, f);
          GtkWidget *control = lk_plugin_scalar_row (section, settings,
                                                     group->plugin_id, field);

          /* The reset has to put each control back where the manifest had it,
           * so it carries them, keyed by the field they belong to. The key is
           * prefixed: a manifest field named "lk-group" would otherwise land on
           * the shell's own data key and hand Reset a widget where it reads a
           * group. */
          g_autofree char *data_key = g_strdup_printf ("lk-field-%s", field->key);
          g_object_set_data (G_OBJECT (reset), data_key, control);
        }

      gtk_widget_set_halign (reset, GTK_ALIGN_START);
      gtk_widget_set_margin_top (reset, 4);
      g_object_set_data (G_OBJECT (reset), "lk-group", (gpointer) group);
      g_signal_connect (reset, "clicked", G_CALLBACK (lk_plugin_reset_clicked), settings);
      gtk_box_append (GTK_BOX (section), reset);
    }

  g_autoptr (GPtrArray) lists = lk_plugins_lists (settings->plugins, tab);

  for (guint i = 0; i < lists->len; i++)
    {
      const LkPluginList *list = g_ptr_array_index (lists, i);
      GtkWidget *section = lk_section (page, list->title);
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);

      gtk_box_append (GTK_BOX (section), box);
      g_hash_table_insert (settings->list_boxes,
                           g_strdup_printf ("%s/%s", list->plugin_id, list->key), box);
      if (list->discover->len > 0)
        g_ptr_array_add (settings->discover_lists, (gpointer) list);
      lk_plugin_fill_rows (settings, list, box);

      /* The plugin's own sentence, never the window's. Connections holds two
       * lists — NMEA gateways and Signal K servers — and a line about WiFi
       * gateways under a list of Signal K servers sends the mariner to the
       * wrong port. */
      if (list->footer[0] != '\0')
        lk_footer (section, list->footer);
    }
}

/* What was found moved, so every list that browses shows it again. */
static void
lk_settings_discovery_changed (gpointer user_data)
{
  LkSettings *settings = user_data;

  for (guint i = 0; i < settings->discover_lists->len; i++)
    lk_plugin_schedule_refill (settings, g_ptr_array_index (settings->discover_lists, i));
}

/* Browse for what the loaded lists declare, and for nothing else. A window with
 * no list that browses starts nothing at all. */
static void
lk_settings_start_discovery (LkSettings *settings)
{
  if (settings->discover_lists->len == 0)
    return;

  g_autoptr (GPtrArray) services = g_ptr_array_new ();

  for (guint i = 0; i < settings->discover_lists->len; i++)
    {
      const LkPluginList *list = g_ptr_array_index (settings->discover_lists, i);

      for (guint d = 0; d < list->discover->len; d++)
        {
          const LkPluginDiscover *want = g_ptr_array_index (list->discover, d);

          g_ptr_array_add (services, (gpointer) want->service);
        }
    }

  settings->discovery = lk_discovery_new (lk_settings_discovery_changed, settings);
  lk_discovery_browse (settings->discovery, services);
}

/* ---- the Plugins page ---------------------------------------------------- */

/* Anything here changes WHICH plugins are loaded, so the whole window is built
 * again from a fresh registry. Doing it on an idle keeps the rebuild off the
 * signal that asked for it: a switch or a button is still emitting, and
 * destroying it inside its own handler is how a settings window crashes. */
static gboolean
lk_plugins_reopen_window (gpointer user_data)
{
  GtkWindow *window = user_data;
  LkSettings *settings = g_object_get_data (G_OBJECT (window), "lk-settings");
  GtkWindow *parent = gtk_window_get_transient_for (window);
  LkAppModel *model = settings->model;
  /* The mariner was on Plugins when they installed or removed one, so that is
   * where the rebuilt window opens. Copied out: the window dies below, and the
   * settings it carries die with it. */
  g_autofree char *section =
      g_strdup (gtk_stack_get_visible_child_name (GTK_STACK (settings->stack)));

  gtk_window_destroy (window);
  gtk_window_present (GTK_WINDOW (lk_settings_window_new (model, parent, section)));
  return G_SOURCE_REMOVE;
}

static void
lk_plugins_queue_reopen (GtkWidget *any_child)
{
  GtkRoot *root = gtk_widget_get_root (any_child);

  if (GTK_IS_WINDOW (root))
    g_idle_add (lk_plugins_reopen_window, root);
}

/* The install sheet's callback. It arrives with the model, and the settings
 * window it was raised from is the widget the closure carries. */
static void
lk_plugins_installed (gpointer model, gpointer user_data)
{
  lk_plugins_queue_reopen (user_data);
}

static void
lk_plugins_install_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_plugin_install_choose (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                            settings->model, lk_plugins_installed, GTK_WIDGET (button));
}

/* The dialog is async and outlives the button that raised it. It carries the
   window instead, held by a reference, so a settings window closed while the
   question stands cannot be freed under the answer: the settings struct hangs
   off the window and lives as long as it does. */
typedef struct {
  GtkWindow *window; /* reffed */
  char      *id;
} LkUninstallAsk;

static void
lk_uninstall_ask_free (LkUninstallAsk *ask)
{
  g_clear_object (&ask->window);
  g_free (ask->id);
  g_free (ask);
}

static void
lk_plugins_uninstall_answered (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkUninstallAsk *ask = user_data;
  g_autoptr (GError) error = NULL;
  int chosen = gtk_alert_dialog_choose_finish (GTK_ALERT_DIALOG (source), result, &error);

  /* Cancel is 0, Uninstall is 1. The window may have closed while the question
     stood; act only while it is still standing. */
  if (chosen == 1 && ask->window != NULL &&
      !gtk_widget_in_destruction (GTK_WIDGET (ask->window)))
    {
      LkSettings *settings = g_object_get_data (G_OBJECT (ask->window), "lk-settings");
      if (settings != NULL &&
          lk_chart_controller_plugin_uninstall (lk_app_model_get_controller (settings->model),
                                                ask->id))
        g_idle_add (lk_plugins_reopen_window, ask->window);
    }

  lk_uninstall_ask_free (ask);
}

/* Uninstall takes everything the plugin owns: its instance, the objects it
 * drew, the values it published and the settings it saved. That is not a thing
 * to do on one click, so it is asked about first. */
static void
lk_plugins_uninstall_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *id = g_object_get_data (G_OBJECT (button), "lk-plugin-id");
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
  g_autofree char *question = g_strdup_printf ("Uninstall %s?",
                                               lk_plugins_name (settings->plugins, id));
  static const char *answers[] = { "Cancel", "Uninstall", NULL };

  GtkAlertDialog *dialog = gtk_alert_dialog_new ("%s", question);
  const char *detail = "Removes the plugin and everything it drew.";
  gtk_alert_dialog_set_detail (dialog, detail);
  gtk_alert_dialog_set_buttons (dialog, answers);
  gtk_alert_dialog_set_cancel_button (dialog, 0);
  gtk_alert_dialog_set_default_button (dialog, 0);

  LkUninstallAsk *ask = g_new0 (LkUninstallAsk, 1);
  ask->window = GTK_IS_WINDOW (root) ? g_object_ref (GTK_WINDOW (root)) : NULL;
  ask->id = g_strdup (id);
  gtk_alert_dialog_choose (dialog, ask->window, NULL,
                           lk_plugins_uninstall_answered, ask);
  g_object_unref (dialog);
}

/* A grant goes off and on while the plugin runs. The core persists it beside
 * the plugin's wasm and reads it back at every load, so nothing is saved here.
 * A refusal puts the switch back rather than lying about the state. */
static void
lk_plugins_grant_toggled (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkSwitch *sw = GTK_SWITCH (object);
  const char *id = g_object_get_data (object, "lk-plugin-id");
  const char *cap = g_object_get_data (object, "lk-plugin-cap");

  if (settings->updating)
    return;

  if (lk_plugins_set_granted (settings->plugins, id, cap, gtk_switch_get_active (sw)))
    return;

  settings->updating = TRUE;
  gtk_switch_set_active (sw, !gtk_switch_get_active (sw));
  settings->updating = FALSE;
}

/* The one section that talks ABOUT plugins rather than about the chart: what
 * the mariner added, what it is doing, what it is allowed to do, and how to add
 * or remove one.
 *
 * ONLY WHAT THE MARINER PUT THERE IS LISTED: installed plugins, and the
 * developer copies LOOKOUT_PLUGINS brings. THE SHIPPED SET IS THE PRODUCT. Own
 * ship, AIS, NMEA 0183, Signal K and laylines are how the app works, not
 * choices somebody made, so they take no consent surface and never appear here.
 * Their settings are chart settings, filed under the sections they belong to. */
static void
lk_build_plugins_page (LkSettings *settings)
{
  g_autoptr (GPtrArray) ids = lk_plugins_all (settings->plugins);
  GtkWidget *page = lk_page_new (settings, "plugins", "Plugins",
                                 "application-x-addon-symbolic");
  GtkWidget *section = lk_section (page, NULL);
  guint managed = 0;

  for (guint i = 0; i < ids->len; i++)
    {
      const char *id = g_ptr_array_index (ids, i);
      const char *version = lk_plugins_version (settings->plugins, id);
      const char *from = lk_plugins_origin (settings->plugins, id);

      if (g_strcmp0 (from, "bundled") == 0)
        continue;
      managed++;
      GtkWidget *summary = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
      GtkWidget *name = gtk_label_new (lk_plugins_name (settings->plugins, id));
      GtkWidget *status = gtk_label_new (NULL);
      /* One quiet line saying which copy this is: the version, where it came
       * from, and what it reads. The same line the macOS row prints. */
      g_autoptr (GString) about = g_string_new (NULL);
      if (version[0] != '\0')
        g_string_append_printf (about, "Version %s · ", version);
      g_string_append (about, g_strcmp0 (from, "developer") == 0
                                  ? "developer copy from LOOKOUT_PLUGINS"
                                  : "installed from a plugin file");
      g_autofree char *types = lk_plugins_file_types_for (settings->plugins, id);
      if (types != NULL)
        g_string_append_printf (about, " · reads %s files you open", types);
      about->str[0] = g_ascii_toupper (about->str[0]);
      GtkWidget *where = gtk_label_new (about->str);

      gtk_widget_add_css_class (name, "heading");
      gtk_label_set_xalign (GTK_LABEL (name), 0.0);
      gtk_widget_add_css_class (where, "dim-label");
      gtk_widget_add_css_class (where, "caption");
      gtk_label_set_wrap (GTK_LABEL (where), TRUE);
      gtk_label_set_xalign (GTK_LABEL (where), 0.0);
      gtk_widget_add_css_class (status, "caption");
      gtk_label_set_xalign (GTK_LABEL (status), 0.0);

      /* Keyed by plugin rather than by row, which is what tells the poll to ask
       * for the plugin's own line. */
      g_object_set_data_full (G_OBJECT (status), "lk-plugin-id", g_strdup (id), g_free);
      g_ptr_array_add (settings->status_labels, status);

      /* AT REST, ONE CALM ROW: the name and what it is doing, and nothing
       * else. Everything about MANAGING it stands behind the disclosure, so a
       * mariner reading down the list reads five plugins rather than thirty
       * switches. The provenance goes in there too: it answers "which copy is
       * this", which is a question somebody asks once. */
      GtkWidget *expander = gtk_expander_new (NULL);
      GtkWidget *body = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);

      gtk_box_append (GTK_BOX (summary), name);
      gtk_box_append (GTK_BOX (summary), status);
      gtk_expander_set_label_widget (GTK_EXPANDER (expander), summary);
      gtk_widget_set_margin_top (expander, 6);
      gtk_widget_set_margin_start (body, 6);
      gtk_widget_set_margin_top (body, 6);
      gtk_box_append (GTK_BOX (body), where);

      /* What the manifest asked for, one switch each, in the same sentences
       * the consent sheet used. A grant can never exceed the manifest, so this
       * list only ever takes something away. */
      GPtrArray *caps = lk_plugins_capabilities (settings->plugins, id);
      for (guint c = 0; caps != NULL && c < caps->len; c++)
        {
          const LkPluginCapability *cap = g_ptr_array_index (caps, c);
          GtkWidget *sw = gtk_switch_new ();
          g_autofree char *title =
              cap->hosts != NULL ? g_strdup_printf ("%s (%s)", cap->sentence, cap->hosts)
                                 : g_strdup (cap->sentence);

          gtk_widget_set_valign (sw, GTK_ALIGN_CENTER);
          gtk_switch_set_active (GTK_SWITCH (sw), cap->granted);
          g_object_set_data_full (G_OBJECT (sw), "lk-plugin-id", g_strdup (id), g_free);
          g_object_set_data_full (G_OBJECT (sw), "lk-plugin-cap", g_strdup (cap->cap), g_free);
          g_signal_connect (sw, "notify::active", G_CALLBACK (lk_plugins_grant_toggled),
                            settings);
          lk_row (body, title, sw);
        }

      /* Uninstall acts only on what install wrote. A bundled copy belongs to
       * the application and a developer copy to LOOKOUT_PLUGINS, and the core
       * refuses both, so neither is offered. */
      if (lk_plugins_is_installed (settings->plugins, id))
        {
          GtkWidget *remove = gtk_button_new_with_label ("Uninstall…");

          gtk_widget_add_css_class (remove, "destructive-action");
          gtk_widget_set_halign (remove, GTK_ALIGN_START);
          gtk_widget_set_margin_top (remove, 4);
          g_object_set_data_full (G_OBJECT (remove), "lk-plugin-id", g_strdup (id), g_free);
          g_object_set_data (G_OBJECT (remove), "lk-settings", settings);
          g_signal_connect (remove, "clicked", G_CALLBACK (lk_plugins_uninstall_clicked),
                            settings);
          gtk_box_append (GTK_BOX (body), remove);
        }

      gtk_expander_set_child (GTK_EXPANDER (expander), body);
      gtk_box_append (GTK_BOX (section), expander);
    }

  /* Nothing added is the ordinary state: the shipped set is not listed, so a
   * mariner who has installed nothing sees this and the button. */
  if (managed == 0)
    {
      GtkWidget *none = gtk_label_new ("No plugins installed.");

      gtk_widget_add_css_class (none, "dim-label");
      gtk_label_set_wrap (GTK_LABEL (none), TRUE);
      gtk_label_set_xalign (GTK_LABEL (none), 0.0);
      gtk_box_append (GTK_BOX (section), none);
    }

  GtkWidget *install = gtk_button_new_with_label ("Install Plugin…");

  gtk_widget_set_halign (install, GTK_ALIGN_START);
  gtk_widget_set_margin_top (install, 6);
  g_signal_connect (install, "clicked", G_CALLBACK (lk_plugins_install_clicked), settings);
  gtk_box_append (GTK_BOX (section), install);

  /* The same sentence the macOS panel prints under this button. */
  lk_footer (section,
             "A plugin file (.lkplug) can also be opened from the file manager or "
             "dropped on the chart. Nothing is installed before its permissions "
             "are shown.");

  lk_plugin_refresh_status_labels (settings);
}

/* The window is going away. The data the window carries is freed at FINALIZE,
 * which is after its children are destroyed, so a poll or a refill that fired
 * in between would write into labels and boxes that are already gone. Both are
 * stopped here, at destroy, while everything is still standing. */
static void
lk_settings_window_destroyed (GtkWidget *window, gpointer user_data)
{
  LkSettings *settings = user_data;

  g_clear_handle_id (&settings->status_poll_id, g_source_remove);
  g_clear_handle_id (&settings->list_refill_id, g_source_remove);
  /* Every queued refill too: a toggle or an edit queues one, and a window
     destroyed before the idle runs would have it write into freed rows. */
  g_clear_handle_id (&settings->raster_refresh_id, g_source_remove);
  g_clear_handle_id (&settings->links_refresh_id, g_source_remove);
  g_clear_handle_id (&settings->sets_refresh_id, g_source_remove);
  g_clear_pointer (&settings->discovery, lk_discovery_free);
  g_ptr_array_set_size (settings->discover_lists, 0);
  g_ptr_array_set_size (settings->status_labels, 0);
  g_ptr_array_set_size (settings->pending_lists, 0);
  g_hash_table_remove_all (settings->list_boxes);
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
lk_settings_window_new (LkAppModel *model, GtkWindow *parent, const char *tab)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkSettings *settings = g_new0 (LkSettings, 1);
  settings->model = model;
  settings->mariner = lk_mariner_new (lk_app_model_get_controller (model));

  /* The plugin schemas are read once, here: what a plugin declares does not
   * change while the window is open, and re-reading it would fight the
   * keyboard. Only the status lines are polled after this. */
  settings->plugins = lk_plugins_new (lk_app_model_get_controller (model));
  settings->status_labels = g_ptr_array_new ();
  settings->pending_lists = g_ptr_array_new ();
  settings->discover_lists = g_ptr_array_new ();
  settings->list_boxes = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);

  GtkWidget *window = gtk_window_new ();
  gtk_window_set_title (GTK_WINDOW (window), "Mariner Settings");
  /* Two columns need the room the Mac window takes: 720 by 560. */
  gtk_window_set_default_size (GTK_WINDOW (window), 760, 580);
  gtk_widget_set_size_request (window, 640, 480);
  gtk_window_set_transient_for (GTK_WINDOW (window), parent);
  gtk_window_set_destroy_with_parent (GTK_WINDOW (window), TRUE);
  /* A live panel, not a modal: the chart stays usable while it is open. */
  gtk_window_set_modal (GTK_WINDOW (window), FALSE);
  g_object_set_data_full (G_OBJECT (window), "lk-settings", settings, lk_settings_free);
  g_signal_connect (window, "destroy", G_CALLBACK (lk_settings_window_destroyed), settings);

  /* A real titlebar (close button + move handle) the compositor won't draw. */
  gtk_window_set_titlebar (GTK_WINDOW (window), gtk_header_bar_new ());

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (lk_settings_key_pressed), window);
  gtk_widget_add_controller (window, keys);

  /* The panel outlives none of its own edits, but a raster chart added from the
   * pill's list while the panel is open must appear in it. connect_object drops
   * the handler with the window. */
  g_signal_connect_object (model, "raster-changed",
                           G_CALLBACK (lk_settings_raster_changed), window, 0);
  /* Likewise a chart link resolving (or failing) while the panel is open. */
  g_signal_connect_object (lk_app_model_get_chart_links (model), "changed",
                           G_CALLBACK (lk_settings_links_changed), window, 0);
  /* And the library, whose titles fill in as the background scans land. */
  g_signal_connect_object (model, "chart-sets-changed",
                           G_CALLBACK (lk_settings_sets_changed), window, 0);

  /* A SIDEBAR OF SECTIONS beside the pane it chooses, as on the Mac. It is a
   * slot list, not a fixed menu: the four core sections, Plugins and Advanced
   * always exist, and the rest appear only while they hold something. */
  GtkWidget *split = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  GtkWidget *rail = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  settings->sidebar = gtk_list_box_new ();
  settings->stack = gtk_stack_new ();

  gtk_list_box_set_selection_mode (GTK_LIST_BOX (settings->sidebar), GTK_SELECTION_BROWSE);
  gtk_widget_add_css_class (settings->sidebar, "navigation-sidebar");
  gtk_widget_set_vexpand (settings->sidebar, TRUE);
  g_signal_connect (settings->sidebar, "row-selected",
                    G_CALLBACK (lk_settings_section_selected), settings);

  gtk_widget_set_hexpand (settings->stack, TRUE);
  gtk_stack_set_transition_type (GTK_STACK (settings->stack), GTK_STACK_TRANSITION_TYPE_NONE);

  /* The one thing the whole window promises. It stands under the list of
   * sections rather than repeating itself inside every one of them. */
  GtkWidget *promise = gtk_label_new ("Applies at once · kept for next launch");
  gtk_widget_add_css_class (promise, "dim-label");
  gtk_widget_add_css_class (promise, "caption");
  gtk_label_set_wrap (GTK_LABEL (promise), TRUE);
  gtk_label_set_xalign (GTK_LABEL (promise), 0.0);
  gtk_widget_set_margin_start (promise, 14);
  gtk_widget_set_margin_end (promise, 14);
  gtk_widget_set_margin_bottom (promise, 10);
  gtk_widget_set_margin_top (promise, 6);

  GtkWidget *rail_scroller = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (rail_scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (rail_scroller), settings->sidebar);
  gtk_widget_set_vexpand (rail_scroller, TRUE);

  gtk_box_append (GTK_BOX (rail), rail_scroller);
  gtk_box_append (GTK_BOX (rail), promise);
  gtk_widget_set_size_request (rail, 190, -1);
  gtk_widget_add_css_class (rail, "lk-settings-rail");

  gtk_box_append (GTK_BOX (split), rail);
  gtk_box_append (GTK_BOX (split), gtk_separator_new (GTK_ORIENTATION_VERTICAL));
  gtk_box_append (GTK_BOX (split), settings->stack);
  gtk_window_set_child (GTK_WINDOW (window), split);

  lk_build_display_page (settings);
  lk_build_depths_page (settings);
  lk_build_text_page (settings);
  lk_build_charts_page (settings);

  /* Vessels, Alarms and Connections exist only while something puts settings in
   * them, and today that something is a plugin. The section ids are the core's
   * (src/plugin/host.zig, `Tab`), so a plugin and this window mean the same
   * thing by "alarms". Advanced is last: it is where anything unclaimed lands. */
  static const struct { const char *tab, *title, *icon; } plugin_pages[] = {
    { "vessels", "Vessels", "lk-vessels-symbolic" },
    { "alarms", "Alarms", "lk-alarms-symbolic" },
    { "connections", "Connections", "network-wireless-symbolic" },
  };

  for (gsize i = 0; i < G_N_ELEMENTS (plugin_pages); i++)
    {
      if (!lk_plugins_tab_populated (settings->plugins, plugin_pages[i].tab))
        continue;
      lk_plugin_fill_tab (lk_page_new (settings, plugin_pages[i].tab, plugin_pages[i].title,
                                       plugin_pages[i].icon),
                          settings, plugin_pages[i].tab);
    }

  lk_build_plugins_page (settings);
  lk_build_advanced_page (settings);

  lk_settings_select_section (settings, tab);

  /* While the window is up, the connection lines move on their own — but only
     when a plugin shows a status line. With nothing to watch the poll would
     read the whole registry once a second to change nothing. A hot install
     rebuilds this window, so a plugin added later starts the poll then. */
  if (settings->status_labels->len > 0)
    settings->status_poll_id = g_timeout_add_seconds (1, lk_plugin_status_poll, settings);

  lk_settings_start_discovery (settings);

  return window;
}
