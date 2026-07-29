#include "lk-hud.h"

#include <math.h>

char *
lk_coord_format_dms (double value, gboolean is_lat)
{
  const char *hemi = is_lat ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W");
  double magnitude = fabs (value);
  int degrees = (int) magnitude;
  double minutes = (magnitude - degrees) * 60.0;

  return g_strdup_printf ("%d°%05.2f'%s", degrees, minutes, hemi);
}

/* Compact 1:N — "1:24k" / "1:2.1M". */
static char *
lk_format_scale (double denominator)
{
  if (denominator <= 0)
    return g_strdup ("1:—");
  if (denominator >= 1000000.0)
    return g_strdup_printf ("1:%.1fM", denominator / 1000000.0);
  if (denominator >= 10000.0)
    return g_strdup_printf ("1:%.0fk", denominator / 1000.0);
  return g_strdup_printf ("1:%d", (int) round (denominator));
}

/* ---- the bar ------------------------------------------------------------ */

typedef struct {
  LkAppModel *model;
  GtkWidget  *coord_icon;
  GtkWidget  *coord_label;
  GtkWidget  *overscale_label;
  GtkWidget  *scale_label;
  GtkWidget  *zoom_label;
  GtkWidget  *scheme_label;
  GtkWidget  *building_box;
} LkHudBar;

static void
lk_hud_bar_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

static void
lk_hud_update_coord (LkHudBar *bar)
{
  gboolean cursor = lk_app_model_get_cursor_valid (bar->model);
  double lat = cursor ? lk_app_model_get_cursor_lat (bar->model)
                      : lk_app_model_get_center_lat (bar->model);
  double lon = cursor ? lk_app_model_get_cursor_lon (bar->model)
                      : lk_app_model_get_center_lon (bar->model);

  g_autofree char *text = NULL;
  if (lk_app_model_get_use_dms (bar->model))
    {
      g_autofree char *lat_s = lk_coord_format_dms (lat, TRUE);
      g_autofree char *lon_s = lk_coord_format_dms (lon, FALSE);
      text = g_strdup_printf ("%s  %s", lat_s, lon_s);
    }
  else
    {
      text = g_strdup_printf ("%.5f, %.5f", lat, lon);
    }

  gtk_label_set_text (GTK_LABEL (bar->coord_label), text);
  /* Pointer icon = following cursor; pin = view centre. */
  gtk_image_set_from_icon_name (GTK_IMAGE (bar->coord_icon),
                                cursor ? "input-mouse-symbolic" : "find-location-symbolic");
}

static void
lk_hud_update_overscale (LkHudBar *bar)
{
  double overscale = lk_app_model_get_overscale (bar->model);
  gboolean show = overscale > 1.05;

  gtk_widget_set_visible (bar->overscale_label, show);
  if (show)
    {
      g_autofree char *text = g_strdup_printf ("×%.1f", overscale);
      gtk_label_set_text (GTK_LABEL (bar->overscale_label), text);
    }
}

static void
lk_hud_update_scale (LkHudBar *bar)
{
  g_autofree char *text = lk_format_scale (lk_app_model_get_scale_denominator (bar->model));
  gtk_label_set_text (GTK_LABEL (bar->scale_label), text);
}

static void
lk_hud_update_zoom (LkHudBar *bar)
{
  g_autofree char *text = g_strdup_printf ("z%.1f", lk_app_model_get_zoom (bar->model));
  gtk_label_set_text (GTK_LABEL (bar->zoom_label), text);
}

static void
lk_hud_update_scheme (LkHudBar *bar)
{
  gtk_label_set_text (GTK_LABEL (bar->scheme_label), lk_app_model_get_scheme_name (bar->model));
}

static void
lk_hud_update_building (LkHudBar *bar)
{
  gtk_widget_set_visible (bar->building_box, lk_app_model_get_building (bar->model));
}

static void
lk_hud_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  LkHudBar *bar = user_data;
  const char *name = g_param_spec_get_name (pspec);

  if (g_str_equal (name, "cursor-valid") || g_str_equal (name, "cursor-lon") ||
      g_str_equal (name, "cursor-lat") || g_str_equal (name, "center-lon") ||
      g_str_equal (name, "center-lat") || g_str_equal (name, "use-dms"))
    lk_hud_update_coord (bar);
  else if (g_str_equal (name, "overscale"))
    lk_hud_update_overscale (bar);
  else if (g_str_equal (name, "scale-denominator"))
    lk_hud_update_scale (bar);
  else if (g_str_equal (name, "zoom"))
    lk_hud_update_zoom (bar);
  else if (g_str_equal (name, "scheme"))
    lk_hud_update_scheme (bar);
  else if (g_str_equal (name, "building"))
    lk_hud_update_building (bar);
}

static GtkWidget *
lk_hud_labelled (const char *icon_name, GtkWidget **out_label)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 4);
  GtkWidget *image = gtk_image_new_from_icon_name (icon_name);
  GtkWidget *label = gtk_label_new ("");

  gtk_widget_add_css_class (image, "dim-label");
  gtk_widget_add_css_class (label, "dim-label");
  gtk_widget_add_css_class (label, "caption");
  gtk_box_append (GTK_BOX (box), image);
  gtk_box_append (GTK_BOX (box), label);

  *out_label = label;
  return box;
}

GtkWidget *
lk_hud_bar_new (LkAppModel *model, gboolean floating)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkHudBar *bar = g_new0 (LkHudBar, 1);
  bar->model = model;

  GtkWidget *root = gtk_center_box_new ();
  gtk_widget_add_css_class (root, "toolbar");
  if (floating)
    {
      /* Own backdrop, and must not swallow drags — the chart stays grabbable under it. */
      gtk_widget_add_css_class (root, "lk-hud-floating");
      gtk_widget_set_valign (root, GTK_ALIGN_END);
      gtk_widget_set_can_target (root, FALSE);
    }
  gtk_widget_set_margin_start (root, 12);
  gtk_widget_set_margin_end (root, 12);
  gtk_widget_set_margin_top (root, 4);
  gtk_widget_set_margin_bottom (root, 4);

  /* Left: coordinate readout and overscale badge. */
  GtkWidget *left = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  bar->coord_icon = gtk_image_new_from_icon_name ("find-location-symbolic");
  gtk_widget_add_css_class (bar->coord_icon, "dim-label");
  bar->coord_label = gtk_label_new ("");
  gtk_widget_add_css_class (bar->coord_label, "monospace");
  gtk_label_set_selectable (GTK_LABEL (bar->coord_label), TRUE);

  bar->overscale_label = gtk_label_new ("");
  gtk_widget_add_css_class (bar->overscale_label, "lk-overscale");
  gtk_widget_set_visible (bar->overscale_label, FALSE);

  gtk_box_append (GTK_BOX (left), bar->coord_icon);
  gtk_box_append (GTK_BOX (left), bar->coord_label);
  gtk_box_append (GTK_BOX (left), bar->overscale_label);
  gtk_center_box_set_start_widget (GTK_CENTER_BOX (root), left);

  /* Centre: tessellation indicator, so it never shifts the readouts. */
  bar->building_box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *spinner = gtk_spinner_new ();
  gtk_spinner_start (GTK_SPINNER (spinner));
  GtkWidget *building_label = gtk_label_new ("Building chart…");
  gtk_widget_add_css_class (building_label, "dim-label");
  gtk_widget_add_css_class (building_label, "caption");
  gtk_box_append (GTK_BOX (bar->building_box), spinner);
  gtk_box_append (GTK_BOX (bar->building_box), building_label);
  gtk_widget_set_visible (bar->building_box, FALSE);
  gtk_center_box_set_center_widget (GTK_CENTER_BOX (root), bar->building_box);

  /* Right: scale, zoom, scheme. */
  GtkWidget *right = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_box_append (GTK_BOX (right), lk_hud_labelled ("zoom-fit-best-symbolic", &bar->scale_label));
  gtk_box_append (GTK_BOX (right), lk_hud_labelled ("zoom-in-symbolic", &bar->zoom_label));
  gtk_box_append (GTK_BOX (right), lk_hud_labelled ("weather-clear-symbolic", &bar->scheme_label));
  gtk_center_box_set_end_widget (GTK_CENTER_BOX (root), right);

  g_signal_connect_data (model, "notify", G_CALLBACK (lk_hud_notify), bar,
                         lk_hud_bar_free, 0);

  lk_hud_update_coord (bar);
  lk_hud_update_overscale (bar);
  lk_hud_update_scale (bar);
  lk_hud_update_zoom (bar);
  lk_hud_update_scheme (bar);
  lk_hud_update_building (bar);

  return root;
}

/* ---- identify ----------------------------------------------------------- */

GtkWidget *
lk_identify_panel_new (GPtrArray *results)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);

  gtk_widget_set_margin_start (box, 8);
  gtk_widget_set_margin_end (box, 8);
  gtk_widget_set_margin_top (box, 8);
  gtk_widget_set_margin_bottom (box, 8);

  GtkWidget *title = gtk_label_new ("Identify");
  gtk_widget_add_css_class (title, "heading");
  gtk_widget_set_halign (title, GTK_ALIGN_START);
  gtk_box_append (GTK_BOX (box), title);

  if (results == NULL || results->len == 0)
    {
      GtkWidget *empty = gtk_label_new ("Nothing here");
      gtk_widget_add_css_class (empty, "dim-label");
      gtk_widget_set_halign (empty, GTK_ALIGN_START);
      gtk_box_append (GTK_BOX (box), empty);
      return box;
    }

  for (guint i = 0; i < results->len; i++)
    {
      const LkPickFeature *feature = g_ptr_array_index (results, i);
      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);

      GtkWidget *cls = gtk_label_new (feature->cls);
      gtk_widget_add_css_class (cls, "monospace");
      gtk_widget_add_css_class (cls, "heading");
      gtk_widget_set_halign (cls, GTK_ALIGN_START);

      GtkWidget *chart = gtk_label_new (feature->chart);
      gtk_widget_add_css_class (chart, "dim-label");
      gtk_widget_add_css_class (chart, "caption");

      gtk_box_append (GTK_BOX (row), cls);
      gtk_box_append (GTK_BOX (row), chart);
      gtk_box_append (GTK_BOX (box), row);
    }

  return box;
}

/* ---- floating controls -------------------------------------------------- */

/* One chartplotter-style circular button. */
static GtkWidget *
lk_bubble (const char *icon_name, const char *tooltip, const char *action)
{
  GtkWidget *button = gtk_button_new_from_icon_name (icon_name);

  gtk_widget_add_css_class (button, "lk-bubble");
  gtk_widget_set_tooltip_text (button, tooltip);
  gtk_actionable_set_action_name (GTK_ACTIONABLE (button), action);
  return button;
}

typedef struct {
  LkAppModel *model;
  GtkWidget  *north;
  GtkWidget  *needle;
} LkRotationWatch;

static void
lk_rotation_watch_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

static void
lk_rotation_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  LkRotationWatch *watch = user_data;
  double rotation;

  if (!g_str_equal (g_param_spec_get_name (pspec), "rotation"))
    return;

  rotation = lk_app_model_get_rotation (watch->model);
  if (watch->north != NULL)
    gtk_widget_set_visible (watch->north, fabs (rotation) >= 0.5);
  if (watch->needle != NULL)
    {
      gtk_widget_set_visible (gtk_widget_get_parent (watch->needle), fabs (rotation) >= 0.5);
      gtk_widget_queue_draw (watch->needle);
    }
}

GtkWidget *
lk_zoom_controls_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 10);
  LkRotationWatch *watch = g_new0 (LkRotationWatch, 1);

  watch->model = model;
  gtk_box_append (GTK_BOX (box), lk_bubble ("zoom-in-symbolic", "Zoom in", "win.zoom-in"));
  gtk_box_append (GTK_BOX (box), lk_bubble ("zoom-out-symbolic", "Zoom out", "win.zoom-out"));

  watch->north = lk_bubble ("go-up-symbolic", "North-up", "win.north-up");
  gtk_widget_set_visible (watch->north, FALSE);
  gtk_box_append (GTK_BOX (box), watch->north);

  g_signal_connect_data (model, "notify", G_CALLBACK (lk_rotation_notify), watch,
                         lk_rotation_watch_free, 0);
  return box;
}

/* Red north needle turned by -rotation, so it keeps pointing true north. */
static void
lk_compass_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data)
{
  LkAppModel *model = user_data;
  double rotation = lk_app_model_get_rotation (model) * G_PI / 180.0;
  double cx = width / 2.0, cy = height / 2.0;
  double r = MIN (cx, cy) - 3;

  cairo_save (cr);
  cairo_translate (cr, cx, cy);
  cairo_rotate (cr, -rotation);

  cairo_move_to (cr, 0, -r);
  cairo_line_to (cr, -r * 0.32, r * 0.28);
  cairo_line_to (cr, 0, r * 0.10);
  cairo_close_path (cr);
  cairo_set_source_rgb (cr, 0.85, 0.18, 0.18);
  cairo_fill (cr);

  cairo_move_to (cr, 0, -r);
  cairo_line_to (cr, r * 0.32, r * 0.28);
  cairo_line_to (cr, 0, r * 0.10);
  cairo_close_path (cr);
  cairo_set_source_rgba (cr, 0.35, 0.35, 0.35, 0.85);
  cairo_fill (cr);

  cairo_restore (cr);
}

GtkWidget *
lk_compass_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  GtkWidget *button = gtk_button_new ();
  GtkWidget *area = gtk_drawing_area_new ();
  LkRotationWatch *watch = g_new0 (LkRotationWatch, 1);

  gtk_widget_set_size_request (area, 26, 26);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (area), lk_compass_draw, model, NULL);
  gtk_button_set_child (GTK_BUTTON (button), area);
  gtk_widget_add_css_class (button, "lk-bubble");
  gtk_widget_set_tooltip_text (button, "Reset to north-up");
  gtk_actionable_set_action_name (GTK_ACTIONABLE (button), "win.north-up");
  gtk_widget_set_visible (button, FALSE);

  watch->model = model;
  watch->needle = area;
  g_signal_connect_data (model, "notify", G_CALLBACK (lk_rotation_notify), watch,
                         lk_rotation_watch_free, 0);
  return button;
}
