/* ui/caption.h: the small dim line under a control or beside a row.
 *
 * Three properties set the same way at every one of them, so they are set
 * here. Inline, because this has no state and the header is all of it.
 */
#pragma once

#include <gtk/gtk.h>

static inline GtkWidget *
lk_caption (const char *text)
{
  GtkWidget *label = gtk_label_new (text);

  gtk_widget_add_css_class (label, "caption");
  gtk_widget_add_css_class (label, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  return label;
}
