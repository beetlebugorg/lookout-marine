#include "lk-overlay-pick.h"

#include "lk-json.h"
#include "lk-pick-report.h"

/* How often the pinned object is re-read. It matches the plugin poll, because
 * that is the rate a plugin's geometry moves at. The timer runs ONLY while
 * something is pinned, which is a state the mariner asked for and leaves. */
#define LK_OVERLAY_TRACK_MS 250

/* The gap between the symbol and the bubble's corner, in logical points. The
 * bubble stands up and to the right of the object, so it never covers the
 * symbol it describes. */
#define LK_OVERLAY_OFFSET 14

GtkWidget *
lk_overlay_card_new (const char *payload_json)
{
  if (payload_json == NULL)
    return NULL;

  g_autoptr (LkJson) root = lk_json_parse (payload_json);
  if (root == NULL)
    return NULL;

  const char *title = lk_json_member_string (root, "title");
  const LkJson *rows = lk_json_member (root, "rows");
  guint count = lk_json_length (rows);

  if (title == NULL && count == 0)
    return NULL; /* a symbol with nothing to say */

  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);

  if (title != NULL)
    {
      GtkWidget *label = gtk_label_new (title);

      gtk_widget_add_css_class (label, "heading");
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_box_append (GTK_BOX (box), label);
    }

  /* The plugin owns the words and the units on both halves. The shell prints
   * the pair and decides nothing about either. */
  for (guint i = 0; i < count; i++)
    {
      const LkJson *pair = lk_json_at (rows, i);

      if (lk_json_length (pair) < 2)
        continue;

      GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
      GtkWidget *key = gtk_label_new (lk_json_text (lk_json_at (pair, 0)));
      GtkWidget *value = gtk_label_new (lk_json_text (lk_json_at (pair, 1)));

      gtk_widget_add_css_class (key, "dim-label");
      gtk_widget_add_css_class (key, "caption");
      gtk_widget_add_css_class (value, "caption");
      gtk_label_set_xalign (GTK_LABEL (key), 0.0);
      gtk_label_set_xalign (GTK_LABEL (value), 0.0);
      gtk_widget_set_hexpand (value, TRUE);

      gtk_box_append (GTK_BOX (line), key);
      gtk_box_append (GTK_BOX (line), value);
      gtk_box_append (GTK_BOX (box), line);
    }

  return box;
}

/* ---- the pinned bubble --------------------------------------------------- */

typedef struct {
  LkAppModel *model;
  GtkWidget  *panel;
  GtkWidget  *body; /* the card, rebuilt only when the payload changes */

  char  *pinned;  /* the object id, NULL while nothing is pinned */
  char  *payload; /* what the card was last built from */
  guint  track_id;
} LkOverlayBubble;

static void
lk_overlay_bubble_stop (LkOverlayBubble *self)
{
  g_clear_handle_id (&self->track_id, g_source_remove);
  g_clear_pointer (&self->pinned, g_free);
  g_clear_pointer (&self->payload, g_free);
  gtk_widget_set_visible (self->panel, FALSE);
}

/* Re-read the pinned object: it moves, its values change, and one day it is
 * gone. A bubble must never outlive the object it describes. */
static gboolean
lk_overlay_bubble_track (gpointer user_data)
{
  LkOverlayBubble *self = user_data;
  LkChartController *controller = lk_app_model_get_controller (self->model);
  g_autoptr (LkOverlayObject) object =
      lk_chart_controller_overlay_info (controller, self->pinned);

  if (object == NULL)
    {
      lk_overlay_bubble_stop (self);
      return G_SOURCE_REMOVE;
    }

  if (g_strcmp0 (object->info, self->payload) != 0)
    {
      GtkWidget *card = lk_overlay_card_new (object->info);

      g_free (self->payload);
      self->payload = g_strdup (object->info);

      if (self->body != NULL)
        gtk_box_remove (GTK_BOX (self->panel), self->body);
      self->body = card;

      if (card == NULL)
        {
          /* The object still exists but says nothing. There is no bubble to
           * show for that, so the pin is dropped rather than left empty. */
          lk_overlay_bubble_stop (self);
          return G_SOURCE_REMOVE;
        }
      gtk_box_append (GTK_BOX (self->panel), card);
    }

  double x = 0, y = 0;
  if (!lk_chart_controller_screen_of (controller, object->lon, object->lat, &x, &y))
    return G_SOURCE_CONTINUE;

  /* The bubble is clamped inside the view, so an object near an edge does not
   * push its own description off the screen. */
  int view_width = lk_app_model_get_view_width (self->model);
  int view_height = lk_app_model_get_view_height (self->model);
  int left = (int) (x + LK_OVERLAY_OFFSET);
  int top = (int) (y - LK_OVERLAY_OFFSET);

  gtk_widget_set_margin_start (self->panel, CLAMP (left, 0, MAX (0, view_width - 120)));
  gtk_widget_set_margin_top (self->panel, CLAMP (top, 0, MAX (0, view_height - 40)));
  gtk_widget_set_visible (self->panel, TRUE);
  return G_SOURCE_CONTINUE;
}

static void
lk_overlay_bubble_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  const char *name = g_param_spec_get_name (pspec);

  /* A notify can arrive while the host widget tears down, when its data is
     half-cleared. The tether's contract is to stop at that. */
  if (gtk_widget_in_destruction (GTK_WIDGET (user_data)))
    return;
  if (!g_str_equal (name, "overlay-pin"))
    return;

  LkOverlayBubble *self = g_object_get_data (G_OBJECT (user_data), "lk-overlay-bubble");

  const char *id = lk_app_model_get_overlay_pin (self->model);

  if (id == NULL)
    {
      lk_overlay_bubble_stop (self);
      return;
    }

  g_free (self->pinned);
  self->pinned = g_strdup (id);
  /* A new pin is a new payload, whatever the last one said. */
  g_clear_pointer (&self->payload, g_free);

  /* Answer the click now, then follow the object. */
  if (lk_overlay_bubble_track (self) == G_SOURCE_CONTINUE && self->track_id == 0)
    self->track_id = g_timeout_add (LK_OVERLAY_TRACK_MS, lk_overlay_bubble_track, self);
}

static void
lk_overlay_bubble_free (gpointer data)
{
  LkOverlayBubble *self = data;

  g_clear_handle_id (&self->track_id, g_source_remove);
  g_free (self->pinned);
  g_free (self->payload);
  g_free (self);
}

GtkWidget *
lk_overlay_bubble_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkOverlayBubble *self = g_new0 (LkOverlayBubble, 1);
  self->model = model;
  self->panel = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  gtk_widget_add_css_class (self->panel, "lk-panel");
  gtk_widget_add_css_class (self->panel, "lk-overlay-bubble");
  gtk_widget_set_halign (self->panel, GTK_ALIGN_START);
  gtk_widget_set_valign (self->panel, GTK_ALIGN_START);
  gtk_widget_set_visible (self->panel, FALSE);
  /* The chart under it stays grabbable: the bubble is a readout, not a
   * control, and a mariner panning across a target must not catch on it. */
  gtk_widget_set_can_target (self->panel, FALSE);

  g_object_set_data_full (G_OBJECT (self->panel), "lk-overlay-bubble", self,
                          lk_overlay_bubble_free);
  g_signal_connect_object (model, "notify", G_CALLBACK (lk_overlay_bubble_notify),
                           self->panel, 0);
  return self->panel;
}
