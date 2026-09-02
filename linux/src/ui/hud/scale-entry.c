/* ui/hud/scale-entry.c — type a scale, or pick a band. */
#include "ui/hud/scale-entry.h"
#include "ui/hud/hud.h"

#include <math.h>

/* ---- the scale entry ---------------------------------------------------- */

/* One usual scale for each S-52 navigational purpose band. */
static const struct {
  const char *band;
  double      denominator;
  const char *shorthand;
} LK_SCALE_PRESETS[] = {
  { "Berthing",   2000, "1:2k" },
  { "Harbor",    12000, "1:12k" },
  { "Approach",  50000, "1:50k" },
  { "Coastal",  150000, "1:150k" },
  { "General",  700000, "1:700k" },
};

typedef struct {
  LkAppModel *model;
  GtkWidget  *popover;
  GtkWidget  *entry;
  GtkWidget  *hint;
  GtkWidget  *now;
  GtkWidget  *go;
  GtkWidget  *presets[G_N_ELEMENTS (LK_SCALE_PRESETS)];
} LkScaleEntry;

static void
lk_scale_entry_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

/* The band the typed scale belongs to, or how to write a scale. */
static void
lk_scale_entry_refresh (LkScaleEntry *entry)
{
  const char *text = gtk_editable_get_text (GTK_EDITABLE (entry->entry));
  double denominator = 0;
  gboolean valid = lookout_parse_scale (text, &denominator);

  gtk_widget_set_sensitive (entry->go, valid);

  if (valid)
    {
      g_autofree char *hint =
          g_strdup_printf ("%s band. The chart holds the nearest scale it has.",
                           lookout_band_name (denominator));
      gtk_label_set_text (GTK_LABEL (entry->hint), hint);
    }
  else
    {
      gtk_label_set_text (GTK_LABEL (entry->hint),
                          "Type a scale, for example 25,000 or 1:25k.");
    }
}

static void
lk_scale_entry_changed (GtkEditable *editable, gpointer user_data)
{
  lk_scale_entry_refresh (user_data);
}

static void
lk_scale_entry_submit (LkScaleEntry *entry)
{
  double denominator = 0;

  if (!lookout_parse_scale (gtk_editable_get_text (GTK_EDITABLE (entry->entry)), &denominator))
    return;

  lk_app_model_zoom_to_scale (entry->model, denominator);
  gtk_popover_popdown (GTK_POPOVER (entry->popover));
}

static void
lk_scale_entry_activated (GtkEntry *widget, gpointer user_data)
{
  lk_scale_entry_submit (user_data);
}

static void
lk_scale_entry_go_clicked (GtkButton *button, gpointer user_data)
{
  lk_scale_entry_submit (user_data);
}

static void
lk_scale_preset_clicked (GtkButton *button, gpointer user_data)
{
  LkScaleEntry *entry = user_data;
  double denominator = *(double *) g_object_get_data (G_OBJECT (button), "lk-denominator");

  lk_app_model_zoom_to_scale (entry->model, denominator);
  gtk_popover_popdown (GTK_POPOVER (entry->popover));
}

/* Opening the entry seeds it with the scale on show, so a small correction is
 * an edit rather than a retype. */
static void
lk_scale_entry_shown (GtkPopover *popover, gpointer user_data)
{
  LkScaleEntry *entry = user_data;
  double denominator = lk_app_model_get_scale_denominator (entry->model);
  char scale[LOOKOUT_SCALE_MAX];
  lookout_fmt_scale (denominator, scale, sizeof scale);
  g_autofree char *now = g_strconcat ("now ", scale, NULL);

  if (denominator > 0)
    {
      g_autofree char *seed = g_strdup_printf ("%" G_GINT64_FORMAT, (gint64) llround (denominator));
      gtk_editable_set_text (GTK_EDITABLE (entry->entry), seed);
      gtk_editable_select_region (GTK_EDITABLE (entry->entry), 0, -1);
    }

  /* The band the view is in is marked, so the panel says where the chart
   * stands before it asks where to go. */
  const char *band = lookout_band_name (denominator);
  for (gsize i = 0; i < G_N_ELEMENTS (LK_SCALE_PRESETS); i++)
    {
      if (g_str_equal (LK_SCALE_PRESETS[i].band, band))
        gtk_widget_add_css_class (entry->presets[i], "lk-preset-current");
      else
        gtk_widget_remove_css_class (entry->presets[i], "lk-preset-current");
    }

  gtk_label_set_text (GTK_LABEL (entry->now), now);
  lk_scale_entry_refresh (entry);
  gtk_widget_grab_focus (entry->entry);
}

GtkWidget *
lk_scale_entry_popover_new (LkAppModel *model)
{
  LkScaleEntry *entry = g_new0 (LkScaleEntry, 1);
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);

  entry->model = model;
  entry->popover = gtk_popover_new ();
  gtk_popover_set_child (GTK_POPOVER (entry->popover), box);
  gtk_widget_set_margin_start (box, 6);
  gtk_widget_set_margin_end (box, 6);
  gtk_widget_set_margin_top (box, 6);
  gtk_widget_set_margin_bottom (box, 6);
  gtk_widget_set_size_request (box, 320, -1);

  /* Title, and the scale the view is on now. */
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *title = gtk_label_new ("Zoom to scale");
  gtk_widget_add_css_class (title, "heading");
  gtk_widget_set_hexpand (title, TRUE);
  gtk_label_set_xalign (GTK_LABEL (title), 0);
  entry->now = gtk_label_new ("");
  gtk_widget_add_css_class (entry->now, "dim-label");
  gtk_widget_add_css_class (entry->now, "caption");

  /* A close button in the header, as the reference's card has: a popover
     dismisses on a click outside, but the xmark is the plain way out. */
  GtkWidget *close = gtk_button_new_from_icon_name ("window-close-symbolic");
  gtk_widget_add_css_class (close, "flat");
  gtk_widget_add_css_class (close, "circular");
  gtk_widget_set_valign (close, GTK_ALIGN_CENTER);
  gtk_actionable_set_action_name (GTK_ACTIONABLE (close), "popover.popdown");

  gtk_box_append (GTK_BOX (header), title);
  gtk_box_append (GTK_BOX (header), entry->now);
  gtk_box_append (GTK_BOX (header), close);
  gtk_box_append (GTK_BOX (box), header);

  /* The entry, prefixed with the 1: a scale is always written with. */
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  entry->entry = gtk_entry_new ();
  gtk_entry_set_placeholder_text (GTK_ENTRY (entry->entry), "25,000");
  gtk_entry_set_input_purpose (GTK_ENTRY (entry->entry), GTK_INPUT_PURPOSE_DIGITS);
  gtk_entry_set_activates_default (GTK_ENTRY (entry->entry), FALSE);
  gtk_widget_set_hexpand (entry->entry, TRUE);

  GtkWidget *prefix = gtk_label_new ("1:");
  gtk_widget_add_css_class (prefix, "dim-label");
  entry->go = gtk_button_new_with_label ("Go");
  gtk_widget_add_css_class (entry->go, "suggested-action");

  gtk_box_append (GTK_BOX (row), prefix);
  gtk_box_append (GTK_BOX (row), entry->entry);
  gtk_box_append (GTK_BOX (row), entry->go);
  gtk_box_append (GTK_BOX (box), row);

  entry->hint = gtk_label_new ("");
  gtk_widget_add_css_class (entry->hint, "caption");
  gtk_widget_add_css_class (entry->hint, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (entry->hint), 0);
  gtk_label_set_wrap (GTK_LABEL (entry->hint), TRUE);
  gtk_box_append (GTK_BOX (box), entry->hint);

  gtk_box_append (GTK_BOX (box), gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));

  /* The bands, so a mariner picks a purpose instead of a number. Three across,
     as the reference lays them, so the fifth does not squeeze the row thin. */
  GtkWidget *presets = gtk_grid_new ();
  gtk_grid_set_column_homogeneous (GTK_GRID (presets), TRUE);
  gtk_grid_set_row_spacing (GTK_GRID (presets), 6);
  gtk_grid_set_column_spacing (GTK_GRID (presets), 6);
  for (gsize i = 0; i < G_N_ELEMENTS (LK_SCALE_PRESETS); i++)
    {
      GtkWidget *stack = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
      GtkWidget *band = gtk_label_new (LK_SCALE_PRESETS[i].band);
      GtkWidget *shorthand = gtk_label_new (LK_SCALE_PRESETS[i].shorthand);
      GtkWidget *button = gtk_button_new ();
      double *denominator = g_new (double, 1);

      gtk_widget_add_css_class (band, "caption-heading");
      gtk_widget_add_css_class (shorthand, "caption");
      gtk_widget_add_css_class (shorthand, "dim-label");
      gtk_box_append (GTK_BOX (stack), band);
      gtk_box_append (GTK_BOX (stack), shorthand);

      gtk_button_set_child (GTK_BUTTON (button), stack);
      gtk_widget_add_css_class (button, "flat");
      gtk_widget_set_tooltip_text (button, LK_SCALE_PRESETS[i].shorthand);

      *denominator = LK_SCALE_PRESETS[i].denominator;
      g_object_set_data_full (G_OBJECT (button), "lk-denominator", denominator, g_free);
      g_signal_connect (button, "clicked", G_CALLBACK (lk_scale_preset_clicked), entry);
      gtk_grid_attach (GTK_GRID (presets), button, (int) (i % 3), (int) (i / 3), 1, 1);
      entry->presets[i] = button;
    }
  gtk_box_append (GTK_BOX (box), presets);

  g_signal_connect (entry->entry, "changed", G_CALLBACK (lk_scale_entry_changed), entry);
  g_signal_connect (entry->entry, "activate", G_CALLBACK (lk_scale_entry_activated), entry);
  g_signal_connect (entry->go, "clicked", G_CALLBACK (lk_scale_entry_go_clicked), entry);
  g_signal_connect_data (entry->popover, "show", G_CALLBACK (lk_scale_entry_shown),
                         entry, lk_scale_entry_free, 0);

  return entry->popover;
}
