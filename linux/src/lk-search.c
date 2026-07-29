#include "lk-search.h"

#include "lk-hud.h"

typedef struct {
  LkAppModel *model;
  GtkWidget  *bar;
  GtkWidget  *entry;
  GtkWidget  *hint;
} LkSearch;

static void
lk_search_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

/* Show what Enter will do, so a half-typed coordinate isn't a silent no-op. */
static void
lk_search_changed (GtkEditable *editable, gpointer user_data)
{
  LkSearch *search = user_data;
  const char *text = gtk_editable_get_text (editable);
  double lat, lon;

  if (text == NULL || text[0] == '\0')
    {
      gtk_widget_set_visible (search->hint, FALSE);
      return;
    }

  gtk_widget_set_visible (search->hint, TRUE);

  if (lk_coordinate_parse (text, &lat, &lon))
    {
      g_autofree char *lat_s = lk_coord_format_dms (lat, TRUE);
      g_autofree char *lon_s = lk_coord_format_dms (lon, FALSE);
      g_autofree char *label = g_strdup_printf ("Go to %s %s", lat_s, lon_s);
      gtk_label_set_text (GTK_LABEL (search->hint), label);
      gtk_widget_remove_css_class (search->hint, "dim-label");
    }
  else
    {
      gtk_label_set_text (GTK_LABEL (search->hint),
                          "Feature & place search — coming soon; needs a chart name index");
      gtk_widget_add_css_class (search->hint, "dim-label");
    }
}

static void
lk_search_activate (GtkEntry *entry, gpointer user_data)
{
  LkSearch *search = user_data;

  if (lk_app_model_go_to_coordinate (search->model, gtk_editable_get_text (GTK_EDITABLE (entry))))
    gtk_search_bar_set_search_mode (GTK_SEARCH_BAR (search->bar), FALSE);
}

GtkWidget *
lk_search_bar_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkSearch *search = g_new0 (LkSearch, 1);
  search->model = model;

  search->bar = gtk_search_bar_new ();
  search->entry = gtk_search_entry_new ();
  search->hint = gtk_label_new ("");

  gtk_widget_set_size_request (search->entry, 340, -1);
  gtk_search_entry_set_placeholder_text (GTK_SEARCH_ENTRY (search->entry),
                                         "Go to coordinate  (e.g. 38.978, -76.492)");
  gtk_widget_add_css_class (search->hint, "caption");
  gtk_widget_add_css_class (search->hint, "dim-label");
  gtk_widget_set_visible (search->hint, FALSE);

  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  gtk_widget_set_halign (box, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (box), search->entry);
  gtk_box_append (GTK_BOX (box), search->hint);

  gtk_search_bar_set_child (GTK_SEARCH_BAR (search->bar), box);
  gtk_search_bar_connect_entry (GTK_SEARCH_BAR (search->bar), GTK_EDITABLE (search->entry));

  g_signal_connect_data (search->entry, "changed", G_CALLBACK (lk_search_changed),
                         search, lk_search_free, 0);
  g_signal_connect (search->entry, "activate", G_CALLBACK (lk_search_activate), search);

  return search->bar;
}
