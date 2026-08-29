/* ui/hud/pills.c — the two progress pills at the top of the chart. */
#include "ui/hud/pills.h"
#include "util/tether.h"

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

typedef struct {
  GtkWidget *root;
  GtkWidget *title;
  GtkWidget *bar;
  GtkWidget *detail;
} LkBakePill;

static void
lk_bake_pill_free (gpointer data, GClosure *closure)
{
  (void) closure;
  g_free (data);
}

static void
lk_bake_cancel_clicked (GtkButton *button, gpointer user_data)
{
  (void) button;
  lk_app_model_cancel_bake (LK_APP_MODEL (user_data));
}

static void
lk_bake_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  if (!g_str_equal (g_param_spec_get_name (pspec), "baking"))
    return;

  LkAppModel *model = LK_APP_MODEL (object);
  LkBakePill *pill = user_data;

  if (gtk_widget_in_destruction (pill->root))
    return;
  const LkBakeProgress *p = lk_app_model_get_bake_progress (model);

  gtk_widget_set_visible (pill->root, p != NULL);
  if (p == NULL)
    return;

  g_autofree char *title = lk_bake_progress_title (p);
  gtk_label_set_text (GTK_LABEL (pill->title), title);
  gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (pill->bar), lk_bake_progress_fraction (p));

  /* The count is the mariner's unit: charts, not bytes or percent. The chart
     that just finished rides along so the line moves even on a long cell. */
  g_autofree char *remaining = lk_bake_progress_remaining (p);
  g_autofree char *detail = NULL;
  if (p->total > 0 && remaining != NULL)
    detail = g_strdup_printf ("%d of %d  ·  %s", p->done, p->total, remaining);
  else if (p->total > 0)
    detail = g_strdup_printf ("%d of %d", p->done, p->total);
  else
    detail = g_strdup (p->cell != NULL ? p->cell : "");
  gtk_label_set_text (GTK_LABEL (pill->detail), detail);
}

GtkWidget *
lk_bake_pill_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkBakePill *pill = g_new0 (LkBakePill, 1);
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *text = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);

  pill->root = row;
  pill->title = gtk_label_new ("");
  pill->detail = gtk_label_new ("");
  pill->bar = gtk_progress_bar_new ();

  gtk_widget_add_css_class (pill->title, "heading");
  gtk_widget_add_css_class (pill->detail, "caption");
  gtk_widget_add_css_class (pill->detail, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (pill->title), 0);
  gtk_label_set_xalign (GTK_LABEL (pill->detail), 0);
  gtk_widget_set_size_request (pill->bar, 180, -1);
  gtk_widget_set_valign (pill->bar, GTK_ALIGN_CENTER);

  gtk_box_append (GTK_BOX (text), pill->title);
  gtk_box_append (GTK_BOX (text), pill->detail);
  gtk_box_append (GTK_BOX (row), text);
  gtk_box_append (GTK_BOX (row), pill->bar);

  GtkWidget *stop = gtk_button_new_with_label ("Stop");
  gtk_widget_set_valign (stop, GTK_ALIGN_CENTER);
  g_signal_connect (stop, "clicked", G_CALLBACK (lk_bake_cancel_clicked), model);
  gtk_box_append (GTK_BOX (row), stop);

  gtk_widget_add_css_class (row, "lk-pill");
  gtk_widget_set_halign (row, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (row, GTK_ALIGN_START);
  gtk_widget_set_visible (row, lk_app_model_get_baking (model));

  lk_tether (model,
             g_signal_connect_data (model, "notify", G_CALLBACK (lk_bake_notify),
                                    pill, lk_bake_pill_free, 0),
             row);
  return row;
}
