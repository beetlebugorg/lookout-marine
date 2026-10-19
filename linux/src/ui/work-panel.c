/* ui/work-panel.c: see ui/work-panel.h. */
#include "ui/work-panel.h"

#include "ui/caption.h"

typedef struct {
  GtkWidget *line;
  GtkWidget *title;
  GtkWidget *detail;
  GtkWidget *action;
  GtkWidget *bar;
  GtkWidget *numbers;
  GtkWidget *percent;
  GtkWidget *left;
  guint      pulse_id;
} LkWorkPanel;

static void
lk_work_panel_free (gpointer data)
{
  LkWorkPanel *self = data;

  g_clear_handle_id (&self->pulse_id, g_source_remove);
  g_free (self);
}

static gboolean
lk_work_panel_pulse (gpointer user_data)
{
  LkWorkPanel *self = user_data;

  gtk_progress_bar_pulse (GTK_PROGRESS_BAR (self->bar));
  return G_SOURCE_CONTINUE;
}

GtkWidget *
lk_work_panel_new (const char *action, GCallback on_click, gpointer user_data)
{
  GtkWidget *panel = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  LkWorkPanel *self = g_new0 (LkWorkPanel, 1);

  self->line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  self->title = lk_caption ("");
  self->detail = lk_caption ("");
  self->bar = gtk_progress_bar_new ();
  self->numbers = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  self->percent = lk_caption ("");
  self->left = lk_caption ("");

  gtk_label_set_ellipsize (GTK_LABEL (self->title), PANGO_ELLIPSIZE_END);
  gtk_widget_set_hexpand (self->title, TRUE);
  gtk_widget_set_hexpand (self->percent, TRUE);
  gtk_box_append (GTK_BOX (self->line), self->title);
  gtk_box_append (GTK_BOX (self->line), self->detail);
  gtk_box_append (GTK_BOX (self->numbers), self->percent);
  gtk_box_append (GTK_BOX (self->numbers), self->left);
  gtk_box_append (GTK_BOX (panel), self->line);
  gtk_box_append (GTK_BOX (panel), self->bar);
  gtk_box_append (GTK_BOX (panel), self->numbers);

  if (action != NULL)
    {
      self->action = gtk_button_new_with_label (action);
      gtk_widget_set_valign (self->action, GTK_ALIGN_CENTER);
      g_signal_connect (self->action, "clicked", on_click, user_data);
      gtk_box_append (GTK_BOX (self->line), self->action);
    }

  g_object_set_data_full (G_OBJECT (panel), "lk-work-panel", self, lk_work_panel_free);
  return panel;
}

/* Letter one label and show it only when it has something to say. */
static gboolean
lk_work_panel_letter (GtkWidget *label, const char *text)
{
  gboolean shown = text != NULL && text[0] != '\0';

  gtk_label_set_text (GTK_LABEL (label), shown ? text : "");
  gtk_widget_set_visible (label, shown);
  return shown;
}

void
lk_work_panel_show (GtkWidget *panel, const char *title, const char *detail,
                    const char *percent, const char *left, int done, int total)
{
  LkWorkPanel *self = g_object_get_data (G_OBJECT (panel), "lk-work-panel");
  gboolean head = lk_work_panel_letter (self->title, title);
  gboolean tail = lk_work_panel_letter (self->detail, detail);
  gboolean pct = lk_work_panel_letter (self->percent, percent);
  gboolean rest = lk_work_panel_letter (self->left, left);

  gtk_widget_set_visible (self->line, head || tail || self->action != NULL);
  gtk_widget_set_visible (self->numbers, pct || rest);

  if (total > 0)
    {
      g_clear_handle_id (&self->pulse_id, g_source_remove);
      gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (self->bar),
                                     CLAMP ((double) done / total, 0.0, 1.0));
    }
  else if (self->pulse_id == 0)
    self->pulse_id = g_timeout_add (120, lk_work_panel_pulse, self);
}
