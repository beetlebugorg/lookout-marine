/* ui/startup-view.c — what the window shows before a chart is open.
 *
 * Two pages, both overlays the window hides once the chart draws: the loader
 * with its three steps while a chart opens, and the first-run page that says
 * where charts come from. The list of sets the mariner switched off belongs to
 * the second one, because that is the one case where charts are aboard and the
 * chart is still blank.
 */
#include "ui/startup-view.h"

/* Turning a set back on composes the chart, which closes this page. */
static void
lk_switched_off_toggled (GtkSwitch *sw, GParamSpec *pspec, gpointer user_data)
{
  LkWindow *self = user_data;
  const char *path = g_object_get_data (G_OBJECT (sw), "lk-path");

  if (gtk_widget_in_destruction (self->window))
    return;
  if (gtk_switch_get_active (sw) && path != NULL)
    lk_app_model_set_chart_set_on (self->model, path, TRUE);
}

/* The "Switched off" list on the empty page: the sets aboard when every one is
 * off, each with a switch to bring it back. When any set is on the chart draws
 * and this page is not showing, so the list stays hidden. */
void
lk_window_refresh_switched_off (LkWindow *self)
{
  GtkWidget *box = g_object_get_data (G_OBJECT (self->empty_state), "lk-switched-off");
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (box)) != NULL)
    gtk_box_remove (GTK_BOX (box), child);

  g_autoptr (GPtrArray) rows = lk_app_model_get_chart_sets (self->model);
  gboolean any_on = FALSE;
  for (guint i = 0; i < rows->len; i++)
    any_on |= ((const LkChartSetRow *) g_ptr_array_index (rows, i))->on;

  if (rows->len == 0 || any_on)
    {
      gtk_widget_set_visible (box, FALSE);
      return;
    }

  GtkWidget *header = gtk_label_new ("Switched off");
  gtk_widget_add_css_class (header, "heading");
  gtk_label_set_xalign (GTK_LABEL (header), 0.0);
  gtk_box_append (GTK_BOX (box), header);

  for (guint i = 0; i < rows->len; i++)
    {
      const LkChartSetRow *set = g_ptr_array_index (rows, i);
      GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      GtkWidget *sw = gtk_switch_new ();
      GtkWidget *name = gtk_label_new (set->title);

      gtk_switch_set_active (GTK_SWITCH (sw), FALSE);
      gtk_widget_set_valign (sw, GTK_ALIGN_CENTER);
      g_object_set_data_full (G_OBJECT (sw), "lk-path", g_strdup (set->path), g_free);
      g_signal_connect (sw, "notify::active", G_CALLBACK (lk_switched_off_toggled), self);

      gtk_label_set_xalign (GTK_LABEL (name), 0.0);
      gtk_label_set_ellipsize (GTK_LABEL (name), PANGO_ELLIPSIZE_END);
      gtk_widget_set_hexpand (name, TRUE);
      gtk_box_append (GTK_BOX (row), sw);
      gtk_box_append (GTK_BOX (row), name);
      gtk_box_append (GTK_BOX (box), row);
    }
  gtk_widget_set_visible (box, TRUE);
}

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

/* One fact under the first-run panel's buttons: an icon and a line. */
static void
lk_empty_state_note (GtkWidget *box, const char *icon_name, const char *markup)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *icon = gtk_image_new_from_icon_name (icon_name);
  GtkWidget *text = gtk_label_new (NULL);

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 13);
  gtk_widget_add_css_class (icon, "dim-label");
  gtk_widget_set_valign (icon, GTK_ALIGN_START);
  gtk_widget_set_margin_top (icon, 2);
  gtk_label_set_markup (GTK_LABEL (text), markup);
  gtk_widget_add_css_class (text, "dim-label");
  gtk_widget_add_css_class (text, "caption");
  gtk_label_set_wrap (GTK_LABEL (text), TRUE);
  gtk_label_set_xalign (GTK_LABEL (text), 0.0);
  gtk_widget_set_hexpand (text, TRUE);

  gtk_box_append (GTK_BOX (row), icon);
  gtk_box_append (GTK_BOX (row), text);
  gtk_box_append (GTK_BOX (box), row);
}

/* The first thing a mariner sees, before any chart is aboard.
 *
 * It answers three questions in the order they are asked: what is this
 * program for, why is it empty, what do I do now — and it closes with the one
 * block that is not about getting started, which a mariner must not skim.
 * The twin of EmptyChartState (macOS); the words are the reference's. */
GtkWidget *
lk_window_build_empty_state (void)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *icon = gtk_image_new_from_icon_name ("mark-location-symbolic");
  GtkWidget *title = gtk_label_new ("No charts yet");
  GtkWidget *body = gtk_label_new ("Lookout draws official S-57 and S-101 ENC charts. "
                                   "It does not come with any, so point it at yours.");
  GtkWidget *error = gtk_label_new ("");
  GtkWidget *buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *button = gtk_button_new_with_label ("Choose Charts…");
  GtkWidget *archive = gtk_button_new_with_label ("Choose an Archive…");
  GtkWidget *drop_hint = gtk_label_new ("or drop them anywhere in this window");

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 26);
  gtk_widget_add_css_class (icon, "lk-accent");
  gtk_widget_set_halign (icon, GTK_ALIGN_START);
  gtk_widget_set_margin_bottom (icon, 12);

  gtk_widget_add_css_class (title, "title-2");
  gtk_label_set_xalign (GTK_LABEL (title), 0.0);
  gtk_widget_set_margin_bottom (title, 6);

  gtk_widget_add_css_class (body, "dim-label");
  gtk_label_set_wrap (GTK_LABEL (body), TRUE);
  gtk_label_set_xalign (GTK_LABEL (body), 0.0);
  gtk_widget_set_margin_bottom (body, 16);

  /* A folder that held nothing has to say so HERE. This page is where the
   * mariner pressed the button, and an alert over an empty page is ceremony. */
  gtk_widget_add_css_class (error, "warning");
  gtk_label_set_wrap (GTK_LABEL (error), TRUE);
  gtk_label_set_xalign (GTK_LABEL (error), 0.0);
  gtk_widget_set_margin_bottom (error, 10);
  gtk_widget_set_visible (error, FALSE);

  gtk_widget_add_css_class (button, "suggested-action");
  gtk_widget_add_css_class (button, "pill");
  gtk_actionable_set_action_name (GTK_ACTIONABLE (button), "win.open");
  gtk_widget_add_css_class (archive, "pill");
  gtk_actionable_set_action_name (GTK_ACTIONABLE (archive), "win.open-archive");
  gtk_widget_add_css_class (drop_hint, "dim-label");
  gtk_widget_add_css_class (drop_hint, "caption");
  gtk_box_append (GTK_BOX (buttons), button);
  gtk_box_append (GTK_BOX (buttons), archive);
  gtk_box_append (GTK_BOX (buttons), drop_hint);
  gtk_widget_set_halign (buttons, GTK_ALIGN_START);
  gtk_widget_set_margin_bottom (buttons, 14);

  /* The sets that are aboard but switched off. When every set is off the chart
     is empty, so this page shows instead — with a switch to bring each back,
     rather than sending the mariner to settings to find them. Filled from the
     model on chart-sets-changed. */
  GtkWidget *switched_off = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_set_visible (switched_off, FALSE);
  gtk_widget_set_margin_bottom (switched_off, 14);

  gtk_box_append (GTK_BOX (box), icon);
  gtk_box_append (GTK_BOX (box), title);
  gtk_box_append (GTK_BOX (box), body);
  gtk_box_append (GTK_BOX (box), error);
  gtk_box_append (GTK_BOX (box), buttons);
  gtk_box_append (GTK_BOX (box), switched_off);

  /* What actually works, in the words of what the mariner has in hand. Where
   * the charts come from goes first: a mariner with none needs that before a
   * list of file extensions. */
  lk_empty_state_note (box, "web-browser-symbolic",
                       "NOAA publishes every United States chart at no cost, at "
                       "<a href=\"https://www.charts.noaa.gov/ENCs/ENCs.shtml\">"
                       "charts.noaa.gov</a>. Most other offices sell theirs.");
  lk_empty_state_note (box, "folder-open-symbolic",
                       "A folder of cells (.000), prepared charts (.pmtiles), imagery "
                       "(.mbtiles) or BSB/KAP sheets. Cells and sheets are converted "
                       "once on the way in, a few seconds each.");

  /* Last, and set apart. */
  GtkWidget *warn = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);
  GtkWidget *warn_title = gtk_label_new ("NOT FOR NAVIGATION");
  GtkWidget *warn_body = gtk_label_new (
      "By importing charts you accept that Lookout is a prototype and not a "
      "certified navigation system, and that the charts it prepares are processed "
      "for display and are not the official ENC. They do not meet chart carriage "
      "regulations. You remain responsible for the safe navigation of your vessel "
      "and for keeping clear of every danger. Verify everything shown here against "
      "official, up-to-date charts and publications, and keep a paper backup.");
  GtkWidget *warn_noaa = gtk_label_new (NULL);

  gtk_widget_add_css_class (warn, "lk-not-nav");
  gtk_widget_add_css_class (warn_title, "lk-not-nav-title");
  gtk_label_set_xalign (GTK_LABEL (warn_title), 0.0);
  gtk_label_set_wrap (GTK_LABEL (warn_body), TRUE);
  gtk_label_set_xalign (GTK_LABEL (warn_body), 0.0);
  gtk_widget_add_css_class (warn_body, "caption");
  /* NOAA's own terms, in their words. They apply to their charts whoever
   * prepared them. */
  gtk_label_set_markup (GTK_LABEL (warn_noaa),
                        "NOAA ENC\xC2\xAE charts come from the NOAA Office of Coast "
                        "Survey and are updated weekly on a best-efforts basis; you "
                        "are responsible for holding the current edition and the "
                        "latest updates. NOAA makes no warranty and assumes no "
                        "liability for their use. See the <a href=\""
                        "https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml\">"
                        "NOAA ENC User Agreement</a>.");
  gtk_label_set_wrap (GTK_LABEL (warn_noaa), TRUE);
  gtk_label_set_xalign (GTK_LABEL (warn_noaa), 0.0);
  gtk_widget_add_css_class (warn_noaa, "caption");
  gtk_widget_add_css_class (warn_noaa, "dim-label");
  gtk_box_append (GTK_BOX (warn), warn_title);
  gtk_box_append (GTK_BOX (warn), warn_body);
  gtk_box_append (GTK_BOX (warn), warn_noaa);
  gtk_widget_set_margin_top (warn, 10);
  gtk_box_append (GTK_BOX (box), warn);

  /* No surface, for the reason lk_window_build_loader gives. 430 is the
     reference's content width (EmptyChartState, maxWidth 430). */
  gtk_widget_set_size_request (box, 430, -1);
  /* The card centres INSIDE the scroller, which is what leaves it in the middle
     of a tall window. The margins are its clearance from the window edges once
     it is taller than the window and the scroller has filled. */
  gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_margin_top (box, 16);
  gtk_widget_set_margin_bottom (box, 16);

  /* A page this tall must still fit a short window, so it scrolls.
     valign FILL, not CENTER: an overlay child that is not FILL is allocated its
     NATURAL height, and a card taller than the window is then centred and
     clipped at both ends with no way to scroll to what it cut, because the
     scroller believes it fits. Filling hands it the window's height, and
     anything over that scrolls. */
  GtkWidget *scroller = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), box);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  /* Do NOT propagate the natural width. A wrapping label reports its UNWRAPPED
     text as its natural width, so propagating ran the card the whole width of
     the window instead of the reference's 430 (EmptyChartState, maxWidth 430).
     Refusing it leaves the scroller asking for the card's minimum, which is the
     430 above, and the labels wrap to that. max-content-width cannot do this
     job: the horizontal policy is NEVER, and that path ignores it. */
  gtk_scrolled_window_set_propagate_natural_width (GTK_SCROLLED_WINDOW (scroller), FALSE);
  gtk_widget_set_halign (scroller, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (scroller, GTK_ALIGN_FILL);
  gtk_widget_set_visible (scroller, FALSE);

  g_object_set_data (G_OBJECT (scroller), "lk-error", error);
  g_object_set_data (G_OBJECT (scroller), "lk-switched-off", switched_off);
  return scroller;
}
