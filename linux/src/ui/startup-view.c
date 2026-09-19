/* ui/startup-view.c — what the window shows before a chart is open.
 *
 * The loader and its three steps, an overlay the window hides once the chart
 * draws.
 *
 * A mariner with no charts installed gets setup (ui/firstrun/), and one whose
 * sets are all switched off gets the basemap with the chrome over it.
 */
#include "ui/startup-view.h"

/* The loader's indeterminate bar has no percentage to show, so it pulses. The
 * timer runs only while the loader is up. */
gboolean
lk_window_loader_pulse (gpointer user_data)
{
  LkWindow *self = user_data;
  GtkWidget *bar = g_object_get_data (G_OBJECT (self->loader), "lk-progress");

  if (bar != NULL)
    gtk_progress_bar_pulse (GTK_PROGRESS_BAR (bar));
  return G_SOURCE_CONTINUE;
}

/* The compass rose of the loader. Drawn, not an icon, so the shape is the
 * same on each platform (CompassMark on macOS and iOS). */
static void
lk_compass_mark_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height,
                      gpointer user_data)
{
  double r = MIN (width, height) / 2.0;
  double cx = width / 2.0, cy = height / 2.0;

  /* The pinned accent (#0a5bb5) at the reference's 35%. */
  cairo_set_source_rgba (cr, 0.039, 0.357, 0.710, 0.35);
  cairo_set_line_width (cr, 2.0);
  cairo_arc (cr, cx, cy, r - 1.0, 0, 2 * G_PI);
  cairo_stroke (cr);
  for (int i = 0; i < 4; i++)
    {
      cairo_save (cr);
      cairo_translate (cr, cx, cy);
      cairo_rotate (cr, i * G_PI / 2.0);
      cairo_rectangle (cr, -0.75, -r * 0.86, 1.5, r * 0.28);
      cairo_fill (cr);
      cairo_restore (cr);
    }
  /* The north needle, in the red a chart compass rose uses. */
  cairo_save (cr);
  cairo_translate (cr, cx - r, cy - r);
  cairo_set_source_rgb (cr, 0.831, 0.180, 0.180);
  cairo_move_to (cr, r, r * 0.28);
  cairo_line_to (cr, r * 0.7, r * 1.32);
  cairo_line_to (cr, r * 1.3, r * 1.32);
  cairo_close_path (cr);
  cairo_fill (cr);
  cairo_restore (cr);
}

/* One step of the opening page: what it says, and whether it is waiting,
 * running or done. */
GtkWidget *
lk_loader_step_new (GtkWidget *box)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *mark = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  GtkWidget *spinner = gtk_spinner_new ();
  GtkWidget *check = gtk_image_new_from_icon_name ("object-select-symbolic");
  GtkWidget *label = gtk_label_new ("");
  GtkWidget *detail = gtk_label_new ("");

  gtk_widget_set_size_request (mark, 16, 16);
  gtk_widget_set_valign (mark, GTK_ALIGN_CENTER);
  gtk_widget_set_size_request (spinner, 14, 14);
  gtk_image_set_pixel_size (GTK_IMAGE (check), 14);
  gtk_box_append (GTK_BOX (mark), spinner);
  gtk_box_append (GTK_BOX (mark), check);

  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_widget_add_css_class (detail, "dim-label");
  gtk_widget_add_css_class (detail, "caption");

  gtk_box_append (GTK_BOX (row), mark);
  gtk_box_append (GTK_BOX (row), label);
  gtk_box_append (GTK_BOX (row), detail);
  gtk_box_append (GTK_BOX (box), row);

  g_object_set_data (G_OBJECT (row), "lk-spinner", spinner);
  g_object_set_data (G_OBJECT (row), "lk-check", check);
  g_object_set_data (G_OBJECT (row), "lk-label", label);
  g_object_set_data (G_OBJECT (row), "lk-detail", detail);
  return row;
}

/* `state`: 0 waiting, 1 running, 2 done. */
void
lk_loader_step_set (GtkWidget *row, int state, const char *text, const char *detail_text)
{
  GtkWidget *spinner = g_object_get_data (G_OBJECT (row), "lk-spinner");
  GtkWidget *check = g_object_get_data (G_OBJECT (row), "lk-check");
  GtkWidget *label = g_object_get_data (G_OBJECT (row), "lk-label");
  GtkWidget *detail = g_object_get_data (G_OBJECT (row), "lk-detail");

  gtk_widget_set_visible (spinner, state == 1);
  gtk_spinner_set_spinning (GTK_SPINNER (spinner), state == 1);
  gtk_widget_set_visible (check, state == 2);
  gtk_label_set_text (GTK_LABEL (label), text);
  if (state == 0)
    gtk_widget_add_css_class (label, "dim-label");
  else
    gtk_widget_remove_css_class (label, "dim-label");
  gtk_label_set_text (GTK_LABEL (detail), detail_text);
  gtk_widget_set_visible (detail, detail_text[0] != '\0');
}

/* Opening, as a page. The three waits are different work and the mariner
 * should be able to see which one they are in: the one-time symbol bake,
 * mapping the library, and tessellating the first scene. A single spinner
 * that vanishes says only that something happened. The twin of StartupLoader
 * (macOS) and the WinUI loader page. */
GtkWidget *
lk_window_build_loader (void)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *compass = gtk_drawing_area_new ();
  GtkWidget *title = gtk_label_new ("Opening the chart");

  gtk_widget_set_size_request (compass, 24, 24);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (compass),
                                  lk_compass_mark_draw, NULL, NULL);
  gtk_widget_add_css_class (title, "title-4");
  gtk_box_append (GTK_BOX (header), compass);
  gtk_box_append (GTK_BOX (header), title);
  gtk_box_append (GTK_BOX (box), header);

  /* An indeterminate bar between the header and the steps, as the reference
     has: the wait has no percentage to show, so it pulses while the loader is
     up. */
  GtkWidget *progress = gtk_progress_bar_new ();
  gtk_widget_set_size_request (progress, 320, -1);
  gtk_box_append (GTK_BOX (box), progress);
  g_object_set_data (G_OBJECT (box), "lk-progress", progress);

  g_object_set_data (G_OBJECT (box), "lk-title", title);
  g_object_set_data (G_OBJECT (box), "lk-step0", lk_loader_step_new (box));
  g_object_set_data (G_OBJECT (box), "lk-step1", lk_loader_step_new (box));
  g_object_set_data (G_OBJECT (box), "lk-step2", lk_loader_step_new (box));

  /* No surface. This stands on the page fill, not over the chart, so a card
     here would be a panel drawn on a panel. The reference's StartupLoader is
     bare content on the same fill. */
  gtk_widget_set_size_request (box, 320, -1);
  gtk_widget_set_halign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_visible (box, FALSE);
  return box;
}
