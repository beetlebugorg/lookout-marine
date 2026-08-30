/* ui/hud/pills.c — the two progress pills at the top of the chart. */
#include "ui/hud/pills.h"
#include "ui/hud/hud.h"
#include "util/tether.h"
#include "ui/startup-view.h"

/* ---- the build indicator ------------------------------------------------ */

static void
lk_building_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  if (gtk_widget_in_destruction (GTK_WIDGET (user_data)))
    return;
  if (g_str_equal (g_param_spec_get_name (pspec), "building"))
    gtk_widget_set_visible (user_data, lk_app_model_get_building (LK_APP_MODEL (object)));
}

GtkWidget *
lk_building_pill_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  GtkWidget *pill = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *spinner = gtk_spinner_new ();
  GtkWidget *label = gtk_label_new ("Building chart…");

  gtk_spinner_start (GTK_SPINNER (spinner));
  gtk_widget_add_css_class (label, "caption");
  gtk_box_append (GTK_BOX (pill), spinner);
  gtk_box_append (GTK_BOX (pill), label);

  gtk_widget_add_css_class (pill, "lk-pill");
  gtk_widget_set_halign (pill, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (pill, GTK_ALIGN_START);
  gtk_widget_set_can_target (pill, FALSE);
  gtk_widget_set_visible (pill, lk_app_model_get_building (model));

  /* Data is the widget itself, so the object variant carries the lifetime. */
  g_signal_connect_object (model, "notify", G_CALLBACK (lk_building_notify), pill, 0);
  return pill;
}

/* ---- preparing charts --------------------------------------------------- */

/* ONE panel, in two forms, and the form follows whether a chart is drawing.
 *
 * With nothing on screen the wait IS the screen, so the panel stands in the
 * middle of the page, open, with no surface of its own. Once charts draw the
 * chart is the thing worth looking at, so the same panel travels to the top and
 * closes to a line that opens on a click. Moving one panel is what makes the
 * two states read as the same work; swapping a big panel for a small one
 * somewhere else reads as two unrelated things. The twin of ChartWorkPanel
 * (macOS).
 */

/* The reference's width, in both forms (BakeDetail.width). */
#define LK_BAKE_WIDTH 320

typedef struct {
  GtkWidget *root;
  GtkWidget *head_big;    /* the title alone, for the page form */
  GtkWidget *head_small;  /* the clickable one-line summary, for the pill */
  GtkWidget *small_title;
  GtkWidget *small_count;
  GtkWidget *small_spin;  /* stands in for the count until there is one */
  GtkWidget *chevron;
  GtkWidget *detail;
  GtkWidget *bar;
  GtkWidget *percent;
  GtkWidget *remaining;
  GtkWidget *step_find;
  GtkWidget *step_import;
  GtkWidget *stop;
  gboolean   open;        /* the pill's disclosure; the page form is always open */
  gboolean   compact;
  guint      pulse_id;    /* pulses the bar while there is nothing to count */
} LkBakePanel;

static void
lk_bake_panel_free (gpointer data, GClosure *closure)
{
  (void) closure;
  LkBakePanel *panel = data;

  g_clear_handle_id (&panel->pulse_id, g_source_remove);
  g_free (panel);
}

static gboolean
lk_bake_pulse (gpointer user_data)
{
  LkBakePanel *panel = user_data;

  gtk_progress_bar_pulse (GTK_PROGRESS_BAR (panel->bar));
  return G_SOURCE_CONTINUE;
}

static void
lk_bake_cancel_clicked (GtkButton *button, gpointer user_data)
{
  gtk_button_set_label (button, "Stopping…");
  gtk_widget_set_sensitive (GTK_WIDGET (button), FALSE);
  lk_app_model_cancel_bake (LK_APP_MODEL (user_data));
}

/* Which parts are up. Called whenever the form or the disclosure changes. */
static void
lk_bake_apply_form (LkBakePanel *panel)
{
  gboolean show_detail = !panel->compact || panel->open;

  gtk_widget_set_visible (panel->head_big, !panel->compact);
  gtk_widget_set_visible (panel->head_small, panel->compact);
  gtk_widget_set_visible (panel->detail, show_detail);
  gtk_image_set_from_icon_name (GTK_IMAGE (panel->chevron),
                                panel->open ? "pan-up-symbolic" : "pan-down-symbolic");
  gtk_box_set_spacing (GTK_BOX (panel->root), panel->compact ? 8 : 14);

  /* A card floats over something. On the page there is nothing under it, so the
     page form is the page itself and only the pill keeps a surface. */
  if (panel->compact)
    gtk_widget_add_css_class (panel->root, "lk-pill");
  else
    gtk_widget_remove_css_class (panel->root, "lk-pill");
  gtk_widget_set_valign (panel->root, panel->compact ? GTK_ALIGN_START : GTK_ALIGN_CENTER);
  /* Clear of the window edge as a pill; the page centres it, so no offset. */
  gtk_widget_set_margin_top (panel->root, panel->compact ? LK_CHROME_MARGIN : 0);
}

static void
lk_bake_disclose (GtkButton *button, gpointer user_data)
{
  (void) button;
  LkBakePanel *panel = user_data;

  panel->open = !panel->open;
  lk_bake_apply_form (panel);
}

static void
lk_bake_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  const char *name = g_param_spec_get_name (pspec);

  if (!g_str_equal (name, "baking") && !g_str_equal (name, "has-chart"))
    return;

  LkAppModel *model = LK_APP_MODEL (object);
  LkBakePanel *panel = user_data;

  if (gtk_widget_in_destruction (panel->root))
    return;

  const LkBakeProgress *p = lk_app_model_get_bake_progress (model);

  gtk_widget_set_visible (panel->root, p != NULL);
  if (p == NULL)
    {
      /* Idle means idle: nothing left to say, so nothing left ticking. */
      g_clear_handle_id (&panel->pulse_id, g_source_remove);
      return;
    }

  gboolean counted = p->total > 0;
  gboolean compact = lk_app_model_get_has_chart (model);

  if (compact != panel->compact)
    {
      panel->compact = compact;
      lk_bake_apply_form (panel);
    }

  g_autofree char *title = lk_bake_progress_title (p);
  gtk_label_set_text (GTK_LABEL (panel->head_big), title);
  gtk_label_set_text (GTK_LABEL (panel->small_title), title);

  /* Counted or not, the bar has to look like work. A determinate bar with
     nothing in it reads as stuck, which is what looking through a big folder
     looked like, so it pulses until there is a count. */
  if (counted)
    {
      g_clear_handle_id (&panel->pulse_id, g_source_remove);
      gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (panel->bar),
                                     lk_bake_progress_fraction (p));
    }
  else if (panel->pulse_id == 0)
    {
      panel->pulse_id = g_timeout_add (120, lk_bake_pulse, panel);
    }

  g_autofree char *pct = counted
      ? g_strdup_printf ("%d%%", (int) (lk_bake_progress_fraction (p) * 100))
      : g_strdup ("");
  gtk_label_set_text (GTK_LABEL (panel->percent), pct);

  g_autofree char *left = lk_bake_progress_remaining (p);
  gtk_label_set_text (GTK_LABEL (panel->remaining), left != NULL ? left : "");

  g_autofree char *count = counted ? g_strdup_printf ("%d of %d", p->done, p->total) : NULL;
  gtk_label_set_text (GTK_LABEL (panel->small_count), count != NULL ? count : "");
  gtk_widget_set_visible (panel->small_count, counted);
  /* Nothing to count yet. A line of text that sits there for seconds reads as a
     hang, so the pill spins instead. */
  gtk_widget_set_visible (panel->small_spin, !counted);
  gtk_spinner_set_spinning (GTK_SPINNER (panel->small_spin), !counted);

  /* A step that is done says what it produced. The step running says how far in
     it is. A step not started says nothing, because a number against work that
     has not begun is noise. */
  g_autofree char *found = counted ? g_strdup_printf ("%d found", p->total) : g_strdup ("");
  lk_loader_step_set (panel->step_find, counted ? 2 : 1, "Finding charts", found);
  lk_loader_step_set (panel->step_import,
                      !counted ? 0 : (p->done < p->total ? 1 : 2),
                      "Importing charts", count != NULL ? count : "");
}

GtkWidget *
lk_bake_pill_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkBakePanel *panel = g_new0 (LkBakePanel, 1);
  GtkWidget *root = gtk_box_new (GTK_ORIENTATION_VERTICAL, 14);

  panel->root = root;

  /* The page form's header: the title, and nothing else to press. */
  panel->head_big = gtk_label_new ("");
  gtk_widget_add_css_class (panel->head_big, "title-4");
  gtk_label_set_xalign (GTK_LABEL (panel->head_big), 0.0);
  gtk_box_append (GTK_BOX (root), panel->head_big);

  /* The pill form's header: the whole line is the disclosure. */
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  panel->small_title = gtk_label_new ("");
  panel->small_count = gtk_label_new ("");
  panel->small_spin = gtk_spinner_new ();
  panel->chevron = gtk_image_new_from_icon_name ("pan-down-symbolic");

  gtk_widget_add_css_class (panel->small_count, "dim-label");
  gtk_widget_add_css_class (panel->small_count, "caption");
  gtk_widget_set_size_request (panel->small_spin, 12, 12);
  gtk_widget_set_valign (panel->small_spin, GTK_ALIGN_CENTER);
  gtk_image_set_pixel_size (GTK_IMAGE (panel->chevron), 10);
  gtk_box_append (GTK_BOX (row), panel->small_title);
  gtk_box_append (GTK_BOX (row), panel->small_count);
  gtk_box_append (GTK_BOX (row), panel->small_spin);
  gtk_box_append (GTK_BOX (row), panel->chevron);

  panel->head_small = gtk_button_new ();
  gtk_button_set_child (GTK_BUTTON (panel->head_small), row);
  gtk_widget_add_css_class (panel->head_small, "flat");
  gtk_widget_set_tooltip_text (panel->head_small, "What this import is doing");
  g_signal_connect (panel->head_small, "clicked", G_CALLBACK (lk_bake_disclose), panel);
  gtk_box_append (GTK_BOX (root), panel->head_small);

  /* The detail: the bar, the steps, and the way out. One panel in both places,
     so the mariner reads the same thing either way. */
  panel->detail = gtk_box_new (GTK_ORIENTATION_VERTICAL, 11);
  gtk_widget_set_size_request (panel->detail, LK_BAKE_WIDTH, -1);

  GtkWidget *bar_block = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  panel->bar = gtk_progress_bar_new ();
  GtkWidget *figures = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  panel->percent = gtk_label_new ("");
  panel->remaining = gtk_label_new ("");
  gtk_widget_add_css_class (panel->percent, "caption");
  gtk_widget_add_css_class (panel->percent, "dim-label");
  gtk_widget_add_css_class (panel->remaining, "caption");
  gtk_widget_add_css_class (panel->remaining, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (panel->percent), 0.0);
  gtk_label_set_xalign (GTK_LABEL (panel->remaining), 1.0);
  gtk_widget_set_hexpand (panel->remaining, TRUE);
  gtk_box_append (GTK_BOX (figures), panel->percent);
  gtk_box_append (GTK_BOX (figures), panel->remaining);
  gtk_box_append (GTK_BOX (bar_block), panel->bar);
  gtk_box_append (GTK_BOX (bar_block), figures);
  gtk_box_append (GTK_BOX (panel->detail), bar_block);

  GtkWidget *steps = gtk_box_new (GTK_ORIENTATION_VERTICAL, 7);
  panel->step_find = lk_loader_step_new (steps);
  panel->step_import = lk_loader_step_new (steps);
  gtk_box_append (GTK_BOX (panel->detail), steps);

  gtk_box_append (GTK_BOX (panel->detail),
                  gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));

  GtkWidget *actions = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  panel->stop = gtk_button_new_with_label ("Cancel");
  gtk_widget_set_halign (panel->stop, GTK_ALIGN_END);
  gtk_widget_set_hexpand (panel->stop, TRUE);
  g_signal_connect (panel->stop, "clicked", G_CALLBACK (lk_bake_cancel_clicked), model);
  gtk_box_append (GTK_BOX (actions), panel->stop);
  gtk_box_append (GTK_BOX (panel->detail), actions);

  gtk_box_append (GTK_BOX (root), panel->detail);

  gtk_widget_set_halign (root, GTK_ALIGN_CENTER);
  gtk_widget_set_visible (root, lk_app_model_get_baking (model));

  panel->compact = lk_app_model_get_has_chart (model);
  lk_bake_apply_form (panel);

  lk_tether (model,
             g_signal_connect_data (model, "notify", G_CALLBACK (lk_bake_notify),
                                    panel, lk_bake_panel_free, 0),
             root);
  return root;
}
