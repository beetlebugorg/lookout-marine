/* ui/firstrun/parts.c — the pieces every setup step is built from.
 *
 * A step is a heading, some rows or cards, and at most one warning. The sizes
 * come from the design board; the colours come from the CSS in src/main.c,
 * which is the palette the chart chrome uses.
 */
#include "ui/firstrun/private.h"

GtkWidget *
lk_step_heading (const char *title, const char *blurb)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 9);
  GtkWidget *heading = gtk_label_new (title);
  GtkWidget *sentence = gtk_label_new (blurb);

  gtk_widget_add_css_class (heading, "title-2");
  gtk_label_set_xalign (GTK_LABEL (heading), 0.0);
  gtk_label_set_wrap (GTK_LABEL (heading), TRUE);

  gtk_widget_add_css_class (sentence, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (sentence), 0.0);
  gtk_label_set_wrap (GTK_LABEL (sentence), TRUE);

  gtk_box_append (GTK_BOX (box), heading);
  gtk_box_append (GTK_BOX (box), sentence);
  return box;
}

GtkWidget *
lk_step_fact (const char *icon_name, const char *title, const char *blurb)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 16);
  GtkWidget *icon = gtk_image_new_from_icon_name (icon_name);
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);
  GtkWidget *name = gtk_label_new (title);
  GtkWidget *sentence = gtk_label_new (blurb);

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 22);
  gtk_widget_add_css_class (icon, "lk-accent");
  gtk_widget_set_valign (icon, GTK_ALIGN_START);
  gtk_widget_set_size_request (icon, 30, -1);

  gtk_widget_add_css_class (name, "heading");
  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_widget_add_css_class (sentence, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (sentence), 0.0);
  gtk_label_set_wrap (GTK_LABEL (sentence), TRUE);

  gtk_box_append (GTK_BOX (column), name);
  gtk_box_append (GTK_BOX (column), sentence);
  gtk_widget_set_hexpand (column, TRUE);

  gtk_box_append (GTK_BOX (row), icon);
  gtk_box_append (GTK_BOX (row), column);
  return row;
}

GtkWidget *
lk_step_card (const char *icon_name, const char *title, const char *blurb,
              gboolean recommended, gboolean picked)
{
  GtkWidget *button = gtk_button_new ();
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *tile = gtk_image_new_from_icon_name (icon_name);
  GtkWidget *name = gtk_label_new (title);
  GtkWidget *sentence = gtk_label_new (blurb);
  GtkWidget *mark = gtk_image_new_from_icon_name (picked ? "emblem-ok-symbolic"
                                                         : "radio-symbolic");

  gtk_image_set_pixel_size (GTK_IMAGE (tile), 24);
  gtk_widget_add_css_class (tile, "lk-accent");
  gtk_widget_add_css_class (tile, "lk-card-tile");
  gtk_widget_set_halign (tile, GTK_ALIGN_START);
  gtk_widget_set_margin_bottom (tile, 16);
  gtk_box_append (GTK_BOX (column), tile);

  gtk_widget_add_css_class (name, "heading");
  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_label_set_wrap (GTK_LABEL (name), TRUE);
  gtk_box_append (GTK_BOX (column), name);

  if (recommended)
    {
      GtkWidget *tag = gtk_label_new ("Recommended");

      gtk_widget_add_css_class (tag, "caption");
      gtk_widget_add_css_class (tag, "lk-accent");
      gtk_label_set_xalign (GTK_LABEL (tag), 0.0);
      gtk_widget_set_margin_top (tag, 3);
      gtk_box_append (GTK_BOX (column), tag);
    }

  gtk_widget_add_css_class (sentence, "dim-label");
  gtk_widget_add_css_class (sentence, "caption");
  gtk_label_set_xalign (GTK_LABEL (sentence), 0.0);
  gtk_label_set_wrap (GTK_LABEL (sentence), TRUE);
  gtk_widget_set_margin_top (sentence, 6);
  gtk_widget_set_vexpand (sentence, TRUE);
  gtk_widget_set_valign (sentence, GTK_ALIGN_START);
  gtk_box_append (GTK_BOX (column), sentence);

  /* A row of cards reaches a common height, so the mark goes at the bottom
   * rather than beside the title. */
  gtk_image_set_pixel_size (GTK_IMAGE (mark), 18);
  gtk_widget_set_halign (mark, GTK_ALIGN_START);
  gtk_widget_set_margin_top (mark, 18);
  if (picked)
    gtk_widget_add_css_class (mark, "lk-accent");
  else
    gtk_widget_add_css_class (mark, "dim-label");
  gtk_box_append (GTK_BOX (column), mark);

  gtk_button_set_child (GTK_BUTTON (button), column);
  gtk_widget_add_css_class (button, "lk-step-card");
  if (picked)
    gtk_widget_add_css_class (button, "lk-step-card-picked");
  gtk_widget_set_hexpand (button, TRUE);
  gtk_accessible_update_state (GTK_ACCESSIBLE (button), GTK_ACCESSIBLE_STATE_SELECTED,
                               picked, -1);
  return button;
}

GtkWidget *
lk_step_warning (const char *lead, const char *body)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *icon = gtk_image_new_from_icon_name ("dialog-warning-symbolic");
  GtkWidget *text = gtk_label_new (NULL);
  g_autofree char *lead_escaped = g_markup_escape_text (lead, -1);
  g_autofree char *body_escaped = g_markup_escape_text (body, -1);
  g_autofree char *markup = g_strdup_printf ("<b>%s</b> %s", lead_escaped, body_escaped);

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 13);
  gtk_widget_set_valign (icon, GTK_ALIGN_START);
  gtk_widget_add_css_class (icon, "lk-amber");

  gtk_label_set_markup (GTK_LABEL (text), markup);
  gtk_label_set_wrap (GTK_LABEL (text), TRUE);
  gtk_label_set_xalign (GTK_LABEL (text), 0.0);
  gtk_widget_add_css_class (text, "caption");
  gtk_widget_set_hexpand (text, TRUE);

  gtk_box_append (GTK_BOX (row), icon);
  gtk_box_append (GTK_BOX (row), text);
  gtk_widget_add_css_class (row, "lk-step-warning");
  return row;
}

GtkWidget *
lk_step_note (const char *icon_name, const char *markup)
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
  return row;
}
