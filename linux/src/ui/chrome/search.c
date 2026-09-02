#include "ui/chrome/search.h"

#include "ui/hud/hud.h"

typedef struct {
  LkAppModel *model;
  GtkWidget  *root;   /* the floating capsule column, hidden until opened */
  GtkWidget  *entry;
  GtkWidget  *result; /* the row below the field: a go-to, or the coming-soon note */
} LkSearch;

static void
lk_search_free (gpointer data)
{
  g_free (data);
}

/* Show what Enter will do, so a half-typed coordinate isn't a silent no-op. The
 * result row is a second line under the field, as the reference's is. */
static void
lk_search_changed (GtkEditable *editable, gpointer user_data)
{
  LkSearch *search = user_data;
  const char *text = gtk_editable_get_text (editable);
  double lat, lon;

  if (text == NULL || text[0] == '\0')
    {
      /* Empty: the two-line coming-soon note stands as the placeholder state. */
      gtk_label_set_markup (GTK_LABEL (search->result),
                            "Feature &amp; place search\n"
                            "<span alpha='55%'>Coming soon. Needs a chart name index.</span>");
      gtk_widget_remove_css_class (search->result, "lk-search-go");
      return;
    }

  if (lookout_parse_position (text, &lat, &lon))
    {
      char position[LOOKOUT_POSITION_MAX];

      lookout_fmt_position (lat, lon, position, sizeof position);
      g_autofree char *label = g_strdup_printf ("Go to %s", position);
      gtk_label_set_text (GTK_LABEL (search->result), label);
      gtk_widget_add_css_class (search->result, "lk-search-go");
    }
  else
    {
      gtk_label_set_markup (GTK_LABEL (search->result),
                            "Feature &amp; place search\n"
                            "<span alpha='55%'>Coming soon. Needs a chart name index.</span>");
      gtk_widget_remove_css_class (search->result, "lk-search-go");
    }
}

static void
lk_search_activate (GtkEntry *entry, gpointer user_data)
{
  LkSearch *search = user_data;

  if (lk_app_model_go_to_coordinate (search->model, gtk_editable_get_text (GTK_EDITABLE (entry))))
    gtk_widget_set_visible (search->root, FALSE);
}

GtkWidget *
lk_search_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkSearch *search = g_new0 (LkSearch, 1);
  search->model = model;

  /* The capsule floats beside the top-left bubble, so it is an overlay child
     placed by margins, not a strip that takes a band of water above the chart. */
  search->root = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_set_halign (search->root, GTK_ALIGN_START);
  gtk_widget_set_valign (search->root, GTK_ALIGN_START);
  gtk_widget_set_visible (search->root, FALSE);
  gtk_widget_set_size_request (search->root, 320, -1);

  GtkWidget *field = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *icon = gtk_image_new_from_icon_name ("system-search-symbolic");
  search->entry = gtk_entry_new ();
  search->result = gtk_label_new ("");

  gtk_widget_add_css_class (field, "lk-search-capsule");
  gtk_widget_set_hexpand (search->entry, TRUE);
  gtk_entry_set_has_frame (GTK_ENTRY (search->entry), FALSE);
  gtk_entry_set_placeholder_text (GTK_ENTRY (search->entry),
                                  "Go to coordinate  (e.g. 38.978, -76.492)");
  gtk_box_append (GTK_BOX (field), icon);
  gtk_box_append (GTK_BOX (field), search->entry);

  gtk_widget_add_css_class (search->result, "lk-search-result");
  gtk_widget_add_css_class (search->result, "caption");
  gtk_label_set_xalign (GTK_LABEL (search->result), 0.0);
  gtk_label_set_wrap (GTK_LABEL (search->result), TRUE);

  gtk_box_append (GTK_BOX (search->root), field);
  gtk_box_append (GTK_BOX (search->root), search->result);

  g_signal_connect (search->entry, "changed", G_CALLBACK (lk_search_changed), search);
  g_signal_connect (search->entry, "activate", G_CALLBACK (lk_search_activate), search);
  g_object_set_data_full (G_OBJECT (search->root), "lk-search", search, lk_search_free);
  lk_search_changed (GTK_EDITABLE (search->entry), search); /* seed the note */

  return search->root;
}

gboolean
lk_search_is_open (GtkWidget *widget)
{
  return widget != NULL && gtk_widget_get_visible (widget);
}

void
lk_search_toggle (GtkWidget *widget)
{
  LkSearch *search = g_object_get_data (G_OBJECT (widget), "lk-search");
  gboolean open = !gtk_widget_get_visible (widget);

  gtk_widget_set_visible (widget, open);
  if (open)
    gtk_widget_grab_focus (search->entry);
  else
    gtk_editable_set_text (GTK_EDITABLE (search->entry), "");
}

void
lk_search_close (GtkWidget *widget)
{
  LkSearch *search = g_object_get_data (G_OBJECT (widget), "lk-search");

  if (search == NULL || !gtk_widget_get_visible (widget))
    return;
  gtk_editable_set_text (GTK_EDITABLE (search->entry), "");
  gtk_widget_set_visible (widget, FALSE);
}
