#include "ui/chart/pick-report.h"

#include <math.h>

/* The object column's width, and the detail column's. A report needs the room
 * to read a note; the pair matches PickReport.swift and PickReport.kt. */
#define LK_PICK_LIST_WIDTH   200
#define LK_PICK_DETAIL_WIDTH 430

/* ---- the decode --------------------------------------------------------- */

static void
lk_pick_row_free (LkPickRow *row)
{
  if (row == NULL)
    return;
  g_free (row->label);
  g_free (row->value);
  g_free (row);
}

/* One collection of core rows, copied. The page and the fold share a row type
 * in the core, so they share one here. */
static GPtrArray *
lk_pick_rows_copy (const lookout_pick_row *const *rows, size_t count)
{
  GPtrArray *out = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_pick_row_free);

  for (size_t i = 0; i < count; i++)
    {
      LkPickRow *row = g_new0 (LkPickRow, 1);

      row->label = g_strdup (rows[i]->label);
      row->value = g_strdup (rows[i]->value);
      row->depth = rows[i]->depth;
      row->file = rows[i]->file != 0;
      row->picture = rows[i]->picture != 0;
      g_ptr_array_add (out, row);
    }
  return out;
}

LkPickDecoded *
lk_pick_decoded_new (const lookout_pick_feature *feature)
{
  g_return_val_if_fail (feature != NULL, NULL);

  LkPickDecoded *decoded = g_new0 (LkPickDecoded, 1);
  size_t count = 0;

  decoded->cls = g_strdup (feature->cls);
  decoded->chart = g_strdup (feature->chart);
  decoded->title = g_strdup (feature->title);
  decoded->subtitle = g_strdup (feature->subtitle);
  decoded->chip = g_strdup (feature->chip);
  decoded->footnote = g_strdup (feature->footnote);
  decoded->raw = g_strdup (feature->raw);
  decoded->empty = feature->empty;

  decoded->notes = g_ptr_array_new_with_free_func (g_free);
  const char *const *notes = lookout_pick_notes (feature, &count);
  for (size_t i = 0; i < count; i++)
    g_ptr_array_add (decoded->notes, g_strdup (notes[i]));

  const lookout_pick_row *const *rows = lookout_pick_rows (feature, &count);
  decoded->rows = lk_pick_rows_copy (rows, count);

  const lookout_pick_row *const *source = lookout_pick_source (feature, &count);
  decoded->source = lk_pick_rows_copy (source, count);
  return decoded;
}

void
lk_pick_decoded_free (LkPickDecoded *decoded)
{
  if (decoded == NULL)
    return;

  g_free (decoded->cls);
  g_free (decoded->chart);
  g_free (decoded->title);
  g_free (decoded->subtitle);
  g_free (decoded->chip);
  g_free (decoded->footnote);
  g_free (decoded->raw);
  g_ptr_array_unref (decoded->notes);
  g_ptr_array_unref (decoded->rows);
  g_ptr_array_unref (decoded->source);
  g_free (decoded);
}

GPtrArray *
lk_pick_decoded_list (const lookout_picks *picks)
{
  GPtrArray *out = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_pick_decoded_free);
  size_t count = 0;
  const lookout_pick_feature *const *features = lookout_picks_all (picks, &count);

  for (size_t i = 0; i < count; i++)
    g_ptr_array_add (out, lk_pick_decoded_new (features[i]));
  return out;
}

char *
lk_pick_plain_text (const LkPickDecoded *decoded)
{
  g_return_val_if_fail (decoded != NULL, NULL);

  g_autoptr (GString) text = g_string_new (NULL);

  g_string_append_printf (text, "%s  %s\n", decoded->cls, decoded->chart);

  for (guint i = 0; i < decoded->source->len; i++)
    {
      const LkPickRow *row = g_ptr_array_index (decoded->source, i);
      g_autofree char *indent = g_strnfill ((gsize) row->depth * 2, ' ');

      if (row->value[0] == '\0')
        g_string_append_printf (text, "%s%s:\n", indent, row->label);
      else
        g_string_append_printf (text, "%s%s: %s\n", indent, row->label, row->value);
    }

  return g_string_free (g_steal_pointer (&text), FALSE);
}

/* ---- placement ---------------------------------------------------------- */

int
lk_pick_report_width (guint count, double view_width)
{
  double want = count > 1 ? LK_PICK_LIST_WIDTH + LK_PICK_DETAIL_WIDTH : LK_PICK_DETAIL_WIDTH;
  double room = view_width - LK_PICK_MARGIN * 2;

  return (int) MIN (want, MAX (280.0, room));
}

LkCalloutPlace
lk_callout_place (double point_x,
                  double point_y,
                  double width,
                  double view_width,
                  double view_height,
                  double hud_band)
{
  double clear = LK_PICK_MARKER_SIZE / 2.0 + 6;
  double min_x = LK_PICK_MARGIN;
  double max_x = MAX (min_x, view_width - LK_PICK_MARGIN - width);
  /* The free area's floor. The card stops here; the HUD owns the rest. */
  double floor_y = MAX ((double) LK_PICK_MARGIN, view_height - hud_band);
  double x = MIN (MAX (point_x - width / 2.0, min_x), max_x);

  double over = (point_y - clear) - LK_PICK_MARGIN;
  double under = floor_y - (point_y + clear);

  /* Use the space above unless it is too small and the space below is larger. */
  if (over >= 200 || over >= under)
    return (LkCalloutPlace) { x, point_y - clear, LK_CALLOUT_ABOVE, MAX (0.0, over) };

  return (LkCalloutPlace) { x, point_y + clear, LK_CALLOUT_BELOW, MAX (0.0, under) };
}

/* ---- the mark ----------------------------------------------------------- */

/* S-52 highlights in magenta; the white ring under it keeps the mark visible
 * on a night chart. */
static void
lk_pick_marker_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data)
{
  double cx = width / 2.0;
  double cy = height / 2.0;
  double r = MIN (cx, cy) - 2;

  cairo_set_line_width (cr, 4);
  cairo_set_source_rgba (cr, 1, 1, 1, 0.85);
  cairo_arc (cr, cx, cy, r, 0, 2 * G_PI);
  cairo_stroke (cr);

  cairo_set_line_width (cr, 2);
  cairo_set_source_rgb (cr, 0.878, 0.129, 0.541); /* #E0218A */
  cairo_arc (cr, cx, cy, r, 0, 2 * G_PI);
  cairo_stroke (cr);
}

GtkWidget *
lk_pick_marker_new (void)
{
  GtkWidget *area = gtk_drawing_area_new ();

  gtk_widget_set_size_request (area, LK_PICK_MARKER_SIZE, LK_PICK_MARKER_SIZE);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (area), lk_pick_marker_draw, NULL, NULL);
  /* The mark is a drawing, not a control: a press on it is a press on the
   * chart, which is what a mariner expects of a thing painted on the chart. */
  gtk_widget_set_can_target (area, FALSE);
  gtk_widget_set_halign (area, GTK_ALIGN_START);
  gtk_widget_set_valign (area, GTK_ALIGN_START);
  return area;
}

/* ---- the card ----------------------------------------------------------- */

typedef struct {
  LkAppModel *model;
  GtkWidget  *root;        /* the card itself, which the height floor holds up */
  GtkWidget  *detail_slot; /* the column rebuilt as the selection moves */
  GtkWidget  *list;        /* the objects, NULL for a single-object pick */
  GtkWidget  *notes;       /* the chart's M_* notes, NULL when the cell has none */
  GtkWidget  *body;        /* the detail scroller, rebuilt with the selection */
  int         width;       /* the card's width, one value for the whole pick */
  int         ceiling;     /* the most of the given room the card may take */
  int         floor;       /* the tallest the card has stood for this pick */
  gboolean    fold_open;   /* per pick, not per object */
  gboolean    setting_row; /* guards the list's own selection callback */
} LkPickCard;

/* The chart's own notes. An M_* object states something about the cell over
 * its whole area — the survey behind it, the horizontal datum, the quality of
 * the sounding data — so it is not the object under the cursor and does not
 * belong among the objects that are. */
static gboolean
lk_pick_is_note (const LkPickDecoded *decoded)
{
  return g_str_has_prefix (decoded->cls, "M_");
}

static void lk_pick_card_show (LkPickCard *card, guint index);

static void
lk_pick_picture_texture_drop (gpointer data, GClosure *closure)
{
  g_object_unref (data);
}

static gboolean
lk_pick_picture_key (GtkEventControllerKey *keys, guint keyval, guint keycode,
                     GdkModifierType state, gpointer user_data)
{
  if (keyval != GDK_KEY_Escape)
    return FALSE;
  gtk_window_close (GTK_WINDOW (user_data));
  return TRUE;
}

/* The viewer a click on the inline picture opens: the picture in a window of
 * its own, at its own size up to the screen, scaling with the window from
 * there. A chart picture is a bridge clearance diagram or an anchorage
 * sketch — reading matter, and the report's column is too narrow to read it
 * in. Escape closes, as it closes the report. */
static void
lk_pick_picture_clicked (GtkGestureClick *gesture, int n_press, double x, double y,
                         gpointer user_data)
{
  GdkTexture *texture = user_data;
  GtkWidget *picture = gtk_event_controller_get_widget (GTK_EVENT_CONTROLLER (gesture));
  GtkRoot *root = gtk_widget_get_root (picture);
  const char *name = g_object_get_data (G_OBJECT (picture), "lk-name");

  GtkWidget *window = gtk_window_new ();
  gtk_window_set_title (GTK_WINDOW (window), name != NULL ? name : "Chart picture");
  if (GTK_IS_WINDOW (root))
    gtk_window_set_transient_for (GTK_WINDOW (window), GTK_WINDOW (root));
  gtk_window_set_destroy_with_parent (GTK_WINDOW (window), TRUE);

  GtkWidget *full = gtk_picture_new_for_paintable (GDK_PAINTABLE (texture));
  gtk_picture_set_content_fit (GTK_PICTURE (full), GTK_CONTENT_FIT_CONTAIN);
  gtk_picture_set_can_shrink (GTK_PICTURE (full), TRUE);
  gtk_window_set_child (GTK_WINDOW (window), full);
  gtk_window_set_default_size (GTK_WINDOW (window),
                               MIN (gdk_texture_get_width (texture) + 8, 1200),
                               MIN (gdk_texture_get_height (texture) + 8, 850));

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (lk_pick_picture_key), window);
  gtk_widget_add_controller (window, keys);

  gtk_window_present (GTK_WINDOW (window));
}

/* A file a feature points at, rather than carries: a caution note or a chart
 * picture. The bake stores those beside the chart; a chart baked before that
 * carries the name alone, and the row then says so. */
static GtkWidget *
lk_pick_aux_widget (LkPickCard *card, const char *cell, const char *name, gboolean picture)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  GtkWidget *name_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *icon = gtk_image_new_from_icon_name (picture ? "image-x-generic-symbolic"
                                                          : "text-x-generic-symbolic");
  GtkWidget *name_label = gtk_label_new (name);

  gtk_widget_add_css_class (icon, "lk-accent");
  gtk_label_set_xalign (GTK_LABEL (name_label), 0);
  gtk_label_set_selectable (GTK_LABEL (name_label), TRUE);
  gtk_box_append (GTK_BOX (name_row), icon);
  gtk_box_append (GTK_BOX (name_row), name_label);
  gtk_box_append (GTK_BOX (box), name_row);

  const guint8 *bytes = NULL;
  gsize length = 0;
  const char *mime = NULL;
  lk_chart_controller_aux_file (lk_app_model_get_controller (card->model), cell, name,
                               &bytes, &length, &mime);

  if (bytes == NULL || length == 0)
    {
      GtkWidget *missing = gtk_label_new ("The chart does not carry this file.");
      gtk_widget_add_css_class (missing, "dim-label");
      gtk_widget_add_css_class (missing, "caption");
      gtk_label_set_xalign (GTK_LABEL (missing), 0);
      gtk_box_append (GTK_BOX (box), missing);
      return box;
    }

  g_autoptr (GBytes) data = g_bytes_new (bytes, length);

  if (mime != NULL && g_str_has_prefix (mime, "image/"))
    {
      g_autoptr (GError) error = NULL;
      g_autoptr (GdkTexture) texture = gdk_texture_new_from_bytes (data, &error);

      if (texture != NULL)
        {
          GtkWidget *image = gtk_picture_new_for_paintable (GDK_PAINTABLE (texture));
          /* A chart picture is a diagram or a note. Small it is unreadable, so
           * it gets the report's width and as much height as it needs up to a
           * limit; the report scrolls past that. */
          gtk_picture_set_content_fit (GTK_PICTURE (image), GTK_CONTENT_FIT_CONTAIN);
          gtk_picture_set_can_shrink (GTK_PICTURE (image), TRUE);
          gtk_widget_set_size_request (image, -1, MIN (340, gdk_texture_get_height (texture)));
          gtk_widget_add_css_class (image, "lk-aux-picture");

          /* A click opens it full size. The gesture keeps the texture alive
           * for the viewer it will open. */
          gtk_widget_set_cursor_from_name (image, "pointer");
          gtk_widget_set_tooltip_text (image, "Open full size");
          g_object_set_data_full (G_OBJECT (image), "lk-name", g_strdup (name), g_free);
          GtkGesture *open = gtk_gesture_click_new ();
          g_signal_connect_data (open, "released", G_CALLBACK (lk_pick_picture_clicked),
                                 g_object_ref (texture), lk_pick_picture_texture_drop, 0);
          gtk_widget_add_controller (image, GTK_EVENT_CONTROLLER (open));

          gtk_box_append (GTK_BOX (box), image);
          return box;
        }
      /* Not a format the platform decodes. Fall through and show the bytes as
       * text, which at least says what the cell holds. */
    }

  gsize text_length = 0;
  const char *raw = g_bytes_get_data (data, &text_length);
  g_autofree char *text = g_utf8_make_valid (raw, (gssize) text_length);
  GtkWidget *view = gtk_label_new (g_strstrip (text));

  gtk_label_set_wrap (GTK_LABEL (view), TRUE);
  gtk_label_set_xalign (GTK_LABEL (view), 0);
  gtk_label_set_selectable (GTK_LABEL (view), TRUE);
  gtk_widget_add_css_class (view, "monospace");
  gtk_widget_add_css_class (view, "caption");
  gtk_widget_add_css_class (view, "lk-aux-text");
  gtk_box_append (GTK_BOX (box), view);
  return box;
}

/* The label on the left, the value beside it. The engine decoded both; this
 * only lays them out. The value owns the width, because a note or a name is
 * the reading matter. */
static GtkWidget *
lk_pick_row_widget (LkPickCard *card, const LkPickRow *row, const char *cell)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  GtkWidget *label = gtk_label_new (row->label);

  gtk_widget_set_margin_start (box, 16 + row->depth * 12);
  gtk_widget_set_margin_end (box, 16);
  gtk_widget_set_margin_top (box, 6);
  gtk_widget_set_margin_bottom (box, 6);

  gtk_label_set_xalign (GTK_LABEL (label), 0);
  gtk_label_set_wrap (GTK_LABEL (label), TRUE);
  gtk_widget_set_valign (label, GTK_ALIGN_START);
  gtk_widget_set_size_request (label, 132 - row->depth * 12, -1);
  gtk_widget_add_css_class (label, "dim-label");
  gtk_box_append (GTK_BOX (box), label);

  if (row->file)
    {
      GtkWidget *aux = lk_pick_aux_widget (card, cell, row->value, row->picture);
      gtk_widget_set_hexpand (aux, TRUE);
      gtk_box_append (GTK_BOX (box), aux);
    }
  else
    {
      GtkWidget *value = gtk_label_new (row->value);
      gtk_label_set_xalign (GTK_LABEL (value), 0);
      gtk_label_set_wrap (GTK_LABEL (value), TRUE);
      gtk_label_set_selectable (GTK_LABEL (value), TRUE);
      gtk_widget_set_hexpand (value, TRUE);
      gtk_box_append (GTK_BOX (box), value);
    }

  return box;
}

/* A note the mariner reads before the attributes: INFORM, promoted. */
static GtkWidget *
lk_pick_note_widget (const char *text)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *icon = gtk_image_new_from_icon_name ("dialog-warning-symbolic");
  GtkWidget *label = gtk_label_new (text);

  gtk_widget_set_valign (icon, GTK_ALIGN_START);
  gtk_label_set_wrap (GTK_LABEL (label), TRUE);
  gtk_label_set_xalign (GTK_LABEL (label), 0);
  gtk_label_set_selectable (GTK_LABEL (label), TRUE);
  gtk_widget_set_hexpand (label, TRUE);

  gtk_box_append (GTK_BOX (box), icon);
  gtk_box_append (GTK_BOX (box), label);
  gtk_widget_add_css_class (box, "lk-note");
  gtk_widget_set_margin_start (box, 16);
  gtk_widget_set_margin_end (box, 16);
  gtk_widget_set_margin_top (box, 5);
  gtk_widget_set_margin_bottom (box, 5);
  return box;
}

/* The payload as the cell states it. Nothing the decode did is applied here. */
static void
lk_pick_append_source_rows (GtkWidget *body, const LkPickDecoded *decoded)
{
  for (guint i = 0; i < decoded->source->len; i++)
    {
      const LkPickRow *row = g_ptr_array_index (decoded->source, i);
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
      g_autofree char *name = row->value[0] == '\0' ? g_strdup (row->label)
                                                    : g_strconcat (row->label, ":", NULL);
      GtkWidget *name_label = gtk_label_new (name);
      GtkWidget *value_label = gtk_label_new (row->value);

      gtk_widget_set_margin_start (box, 16 + row->depth * 12);
      gtk_widget_set_margin_end (box, 16);
      gtk_widget_set_margin_top (box, 2);
      gtk_widget_set_margin_bottom (box, 2);

      gtk_label_set_xalign (GTK_LABEL (name_label), 0);
      gtk_label_set_wrap (GTK_LABEL (name_label), TRUE);
      gtk_widget_set_valign (name_label, GTK_ALIGN_START);
      gtk_widget_set_size_request (name_label, 88 - row->depth * 12, -1);
      gtk_widget_add_css_class (name_label, "monospace");
      gtk_widget_add_css_class (name_label, "caption");
      gtk_widget_add_css_class (name_label, "dim-label");

      gtk_label_set_xalign (GTK_LABEL (value_label), 0);
      gtk_label_set_wrap (GTK_LABEL (value_label), TRUE);
      gtk_label_set_selectable (GTK_LABEL (value_label), TRUE);
      gtk_widget_set_hexpand (value_label, TRUE);
      gtk_widget_add_css_class (value_label, "monospace");
      gtk_widget_add_css_class (value_label, "caption");

      gtk_box_append (GTK_BOX (box), name_label);
      gtk_box_append (GTK_BOX (box), value_label);
      gtk_box_append (GTK_BOX (body), box);
    }
}

static void
lk_pick_copy_clicked (GtkButton *button, gpointer user_data)
{
  LkPickCard *card = user_data;
  GPtrArray *results = lk_app_model_get_pick_results (card->model);
  guint index = lk_app_model_get_pick_index (card->model);

  if (results == NULL || index >= results->len)
    return;

  g_autofree char *text = lk_pick_plain_text (g_ptr_array_index (results, index));
  gdk_clipboard_set_text (gtk_widget_get_clipboard (GTK_WIDGET (button)), text);
}

static void
lk_pick_close_clicked (GtkButton *button, gpointer user_data)
{
  LkPickCard *card = user_data;

  lk_app_model_clear_pick (card->model);
}

static void
lk_pick_fold_clicked (GtkButton *button, gpointer user_data)
{
  LkPickCard *card = user_data;

  card->fold_open = !card->fold_open;
  lk_pick_card_show (card, lk_app_model_get_pick_index (card->model));
}

/* A flat, square control for the header and the fold. */
static GtkWidget *
lk_pick_flat_button (const char *icon_name, const char *tooltip)
{
  GtkWidget *button = gtk_button_new_from_icon_name (icon_name);

  gtk_widget_add_css_class (button, "flat");
  gtk_widget_set_valign (button, GTK_ALIGN_START);
  gtk_widget_set_tooltip_text (button, tooltip);
  /* An icon-only button has no accessible name of its own, so the tooltip words
     name it for a screen reader too. */
  gtk_accessible_update_property (GTK_ACCESSIBLE (button),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL, tooltip, -1);
  return button;
}

/* The detail column for one object: the header, the body that scrolls, and
 * the provenance and the fold pinned under it — a control keeps its place. */
static GtkWidget *
lk_pick_detail_new (LkPickCard *card, const LkPickDecoded *decoded)
{
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  /* ---- header ---- */
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *titles = gtk_box_new (GTK_ORIENTATION_VERTICAL, 1);
  GtkWidget *title = gtk_label_new (decoded->title);
  /* The subtitle line is kept even when empty, so the header is the same
   * height for every object and the rows below cannot shift as the selection
   * moves. */
  GtkWidget *subtitle = gtk_label_new (decoded->subtitle[0] != '\0' ? decoded->subtitle : " ");

  gtk_label_set_xalign (GTK_LABEL (title), 0);
  gtk_label_set_ellipsize (GTK_LABEL (title), PANGO_ELLIPSIZE_END);
  gtk_label_set_selectable (GTK_LABEL (title), TRUE);
  gtk_widget_add_css_class (title, "title-4");

  gtk_label_set_xalign (GTK_LABEL (subtitle), 0);
  gtk_label_set_ellipsize (GTK_LABEL (subtitle), PANGO_ELLIPSIZE_END);
  gtk_widget_add_css_class (subtitle, "caption");
  gtk_widget_add_css_class (subtitle, "dim-label");

  gtk_widget_set_hexpand (titles, TRUE);
  gtk_box_append (GTK_BOX (titles), title);
  gtk_box_append (GTK_BOX (titles), subtitle);
  gtk_box_append (GTK_BOX (header), titles);

  GtkWidget *copy = lk_pick_flat_button ("edit-copy-symbolic", "Copy this report");
  GtkWidget *close = lk_pick_flat_button ("window-close-symbolic", "Close the pick report");
  g_signal_connect (copy, "clicked", G_CALLBACK (lk_pick_copy_clicked), card);
  g_signal_connect (close, "clicked", G_CALLBACK (lk_pick_close_clicked), card);
  gtk_box_append (GTK_BOX (header), copy);
  gtk_box_append (GTK_BOX (header), close);

  gtk_widget_set_margin_start (header, 16);
  gtk_widget_set_margin_end (header, 6);
  gtk_widget_set_margin_top (header, 12);
  gtk_widget_set_margin_bottom (header, 10);
  gtk_box_append (GTK_BOX (column), header);
  gtk_box_append (GTK_BOX (column), gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));

  /* ---- body ---- */
  GtkWidget *body = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_margin_top (body, 6);
  gtk_widget_set_margin_bottom (body, 6);

  for (guint i = 0; i < decoded->notes->len; i++)
    gtk_box_append (GTK_BOX (body), lk_pick_note_widget (g_ptr_array_index (decoded->notes, i)));

  /* The engine's verdict. A body with nothing to read says why, because a
   * blank body reads as a defect. */
  if (decoded->empty != LOOKOUT_PICK_READS)
    {
      GtkWidget *empty = gtk_label_new (
          decoded->empty == LOOKOUT_PICK_NO_ATTRIBUTES
              ? "The cell carries no attributes for this object."
              : "The cell carries only source data for this object.");
      gtk_label_set_xalign (GTK_LABEL (empty), 0);
      gtk_label_set_wrap (GTK_LABEL (empty), TRUE);
      gtk_widget_add_css_class (empty, "dim-label");
      gtk_widget_set_margin_start (empty, 16);
      gtk_widget_set_margin_end (empty, 16);
      gtk_widget_set_margin_top (empty, 14);
      gtk_widget_set_margin_bottom (empty, 14);
      gtk_box_append (GTK_BOX (body), empty);
    }

  for (guint i = 0; i < decoded->rows->len; i++)
    gtk_box_append (GTK_BOX (body),
                    lk_pick_row_widget (card, g_ptr_array_index (decoded->rows, i),
                                        decoded->chart));

  if (card->fold_open)
    lk_pick_append_source_rows (body, decoded);

  GtkWidget *scroller = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), body);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  /* The report takes the height its content asks for, and scrolls once that
   * would run past the card's ceiling. */
  gtk_scrolled_window_set_propagate_natural_height (GTK_SCROLLED_WINDOW (scroller), TRUE);
  gtk_scrolled_window_set_max_content_height (GTK_SCROLLED_WINDOW (scroller),
                                              MAX (80, card->ceiling - 150));
  gtk_widget_set_vexpand (scroller, TRUE);
  gtk_box_append (GTK_BOX (column), scroller);
  card->body = scroller;

  /* ---- provenance and the fold ---- */
  gtk_box_append (GTK_BOX (column), gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));

  /* The provenance as one muted line, not a table: the mariner reads it once,
   * to decide how much to trust the rows above it. A cell that states none
   * gets no line at all — an empty strip under a rule reads as a defect. */
  g_autofree char *footnote_text = g_strstrip (g_strdup (decoded->footnote));
  if (footnote_text[0] != '\0')
    {
      GtkWidget *footnote = gtk_label_new (footnote_text);
      gtk_label_set_xalign (GTK_LABEL (footnote), 0);
      gtk_label_set_wrap (GTK_LABEL (footnote), TRUE);
      gtk_label_set_selectable (GTK_LABEL (footnote), TRUE);
      gtk_widget_add_css_class (footnote, "caption");
      gtk_widget_add_css_class (footnote, "dim-label");
      gtk_widget_set_margin_start (footnote, 16);
      gtk_widget_set_margin_end (footnote, 16);
      gtk_widget_set_margin_top (footnote, 8);
      gtk_widget_set_margin_bottom (footnote, 8);
      gtk_box_append (GTK_BOX (column), footnote);
    }

  g_autofree char *fold_text =
      g_strdup_printf ("S-57 source attributes (%u)", decoded->source->len);
  GtkWidget *fold_box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 5);
  GtkWidget *chevron = gtk_image_new_from_icon_name (card->fold_open ? "pan-down-symbolic"
                                                                    : "pan-end-symbolic");
  GtkWidget *fold_label = gtk_label_new (fold_text);
  gtk_widget_add_css_class (fold_label, "caption");
  gtk_box_append (GTK_BOX (fold_box), chevron);
  gtk_box_append (GTK_BOX (fold_box), fold_label);

  GtkWidget *fold = gtk_button_new ();
  gtk_button_set_child (GTK_BUTTON (fold), fold_box);
  gtk_widget_add_css_class (fold, "flat");
  gtk_widget_add_css_class (fold, "lk-fold");
  gtk_widget_set_tooltip_text (fold, card->fold_open ? "Hide the S-57 source attributes"
                                                     : "Show the S-57 source attributes");
  g_signal_connect (fold, "clicked", G_CALLBACK (lk_pick_fold_clicked), card);
  gtk_box_append (GTK_BOX (column), fold);

  return column;
}

/* The card grows when an object needs more room and keeps that height after.
 * A card that shrinks under the pointer moves the fold and the chart below it,
 * so the next click lands on something else. The floor is per pick: a new pick
 * builds a new card, and so does a window resize, where a height from the old
 * size would be wrong. */
static void
lk_pick_card_hold_height (LkPickCard *card)
{
  int minimum = 0, natural = 0;

  if (card->root == NULL)
    return;

  /* Measure the content alone, with no request of our own standing. */
  gtk_widget_set_size_request (card->root, card->width, -1);
  gtk_widget_measure (card->root, GTK_ORIENTATION_VERTICAL, card->width,
                      &minimum, &natural, NULL, NULL);

  /* An object that carries a lot scrolls; it does not take the window. The
   * body gives back exactly the overshoot, which is measured rather than
   * assumed — the header and the provenance take a different share for every
   * object, so no fixed reserve is right for all of them. */
  if (natural > card->ceiling && card->body != NULL)
    {
      GtkScrolledWindow *body = GTK_SCROLLED_WINDOW (card->body);
      int cap = gtk_scrolled_window_get_max_content_height (body);

      gtk_scrolled_window_set_max_content_height (body,
                                                  MAX (80, cap - (natural - card->ceiling)));
      gtk_widget_measure (card->root, GTK_ORIENTATION_VERTICAL, card->width,
                          &minimum, &natural, NULL, NULL);
    }

  card->floor = MAX (card->floor, natural);
  gtk_widget_set_size_request (card->root, card->width, MIN (card->floor, card->ceiling));
}

static void
lk_pick_card_show (LkPickCard *card, guint index)
{
  GPtrArray *results = lk_app_model_get_pick_results (card->model);

  if (results == NULL || index >= results->len)
    return;

  GtkWidget *old = gtk_widget_get_first_child (card->detail_slot);
  if (old != NULL)
    gtk_box_remove (GTK_BOX (card->detail_slot), old);

  gtk_box_append (GTK_BOX (card->detail_slot),
                  lk_pick_detail_new (card, g_ptr_array_index (results, index)));
  lk_pick_card_hold_height (card);
}

/* The focus goes to the list on an idle, not in the map handler. The report is
 * built while the click that made the pick is still being delivered, and GTK
 * gives the focus to the widget under the pointer — the chart view — once that
 * delivery finishes. An idle runs after it, so the grab holds. */
static gboolean
lk_pick_focus_idle (gpointer data)
{
  GtkWidget *list = data;
  GtkRoot *root = gtk_widget_get_root (list);
  GtkListBoxRow *row = gtk_list_box_get_selected_row (GTK_LIST_BOX (list));
  GtkWidget *target = row != NULL ? GTK_WIDGET (row) : list;

  /* The focus goes to the ROW, not the box. A GtkListBox is not focusable
   * itself, and handing the focus to it lands on the first row rather than the
   * selected one. gtk_root_set_focus is what makes the window agree. */
  if (root != NULL && gtk_widget_get_mapped (target))
    {
      gtk_widget_grab_focus (target);
      gtk_root_set_focus (root, target);
    }
  return G_SOURCE_REMOVE;
}

static void
lk_pick_focus_on_map (GtkWidget *root, gpointer data)
{
  g_idle_add_full (G_PRIORITY_DEFAULT_IDLE, lk_pick_focus_idle,
                   g_object_ref (data), g_object_unref);
}

/* The row carries the index it stands for: a box holds only the objects of its
 * own kind, so a row's position in it is not the pick's. */
static guint
lk_pick_row_index (GtkListBoxRow *row)
{
  return GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (row), "lk-index"));
}

/* The objects and the notes are two boxes but one control, so a pick reads as
 * one selection. Clearing the other box here is what keeps it that way. */
static void
lk_pick_row_selected (GtkListBox *list, GtkListBoxRow *row, gpointer user_data)
{
  LkPickCard *card = user_data;

  if (row == NULL || card->setting_row)
    return;

  GtkWidget *other = GTK_WIDGET (list) == card->list ? card->notes : card->list;
  if (other != NULL)
    {
      card->setting_row = TRUE;
      gtk_list_box_unselect_all (GTK_LIST_BOX (other));
      card->setting_row = FALSE;
    }

  guint index = lk_pick_row_index (row);
  lk_app_model_set_pick_index (card->model, index);
  lk_pick_card_show (card, index);
}

/* Select the row that stands for `index`, in whichever box holds it, and hand
 * that box back so the keys go where the selection went. */
static GtkWidget *
lk_pick_list_select (LkPickCard *card, guint index)
{
  GtkWidget *boxes[] = { card->list, card->notes };
  GtkWidget *holder = NULL;

  card->setting_row = TRUE;
  for (gsize b = 0; b < G_N_ELEMENTS (boxes); b++)
    {
      if (boxes[b] == NULL)
        continue;

      GtkListBox *box = GTK_LIST_BOX (boxes[b]);
      gtk_list_box_unselect_all (box);

      for (int i = 0;; i++)
        {
          GtkListBoxRow *row = gtk_list_box_get_row_at_index (box, i);

          if (row == NULL)
            break;
          if (lk_pick_row_index (row) == index)
            {
              gtk_list_box_select_row (box, row);
              holder = boxes[b];
            }
        }
    }
  card->setting_row = FALSE;
  return holder;
}

/* A heading over a group of rows. The margin puts it on the same leading edge
 * as a row's text: the row's own 9px margin plus the 11px the highlight pads
 * by. */
static GtkWidget *
lk_pick_column_heading (const char *text)
{
  GtkWidget *label = gtk_label_new (text);

  gtk_label_set_xalign (GTK_LABEL (label), 0);
  gtk_widget_add_css_class (label, "caption-heading");
  gtk_widget_add_css_class (label, "dim-label");
  gtk_widget_set_margin_start (label, 20);
  gtk_widget_set_margin_end (label, 10);
  gtk_widget_set_margin_top (label, 14);
  gtk_widget_set_margin_bottom (label, 6);
  return label;
}

/* A note reads as a different kind of thing from an object: the book mark, the
 * chip rather than the title, and no subtitle under it. */
static GtkWidget *
lk_pick_list_row (const LkPickDecoded *decoded, gboolean note)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 7);
  GtkWidget *lines = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
  GtkWidget *title = gtk_label_new (note ? decoded->chip : decoded->title);

  if (note)
    {
      GtkWidget *icon = gtk_image_new_from_icon_name ("accessories-dictionary-symbolic");

      /* The mark centres on the one line beside it. Left to fill the row it
       * sank below the text, which is what read as crooked. */
      gtk_widget_set_valign (icon, GTK_ALIGN_CENTER);
      gtk_widget_add_css_class (icon, "dim-label");
      gtk_box_append (GTK_BOX (box), icon);
    }

  gtk_label_set_xalign (GTK_LABEL (title), 0);
  gtk_label_set_ellipsize (GTK_LABEL (title), PANGO_ELLIPSIZE_END);
  gtk_widget_add_css_class (title, note ? "dim-label" : "heading");
  gtk_box_append (GTK_BOX (lines), title);

  if (!note && decoded->subtitle[0] != '\0')
    {
      GtkWidget *subtitle = gtk_label_new (decoded->subtitle);
      gtk_label_set_xalign (GTK_LABEL (subtitle), 0);
      gtk_label_set_ellipsize (GTK_LABEL (subtitle), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class (subtitle, "caption");
      gtk_widget_add_css_class (subtitle, "dim-label");
      gtk_box_append (GTK_BOX (lines), subtitle);
    }

  gtk_widget_set_valign (lines, GTK_ALIGN_CENTER);
  gtk_widget_set_hexpand (lines, TRUE);
  gtk_box_append (GTK_BOX (box), lines);
  return box;
}

/* One box of the object column: the objects, or the chart's notes. NULL when
 * the pick found none of that kind — an empty box under a rule reads as a
 * defect. */
static GtkWidget *
lk_pick_list_box (LkPickCard *card, GPtrArray *results, gboolean notes)
{
  GtkWidget *list = gtk_list_box_new ();

  gtk_list_box_set_selection_mode (GTK_LIST_BOX (list), GTK_SELECTION_SINGLE);
  gtk_widget_add_css_class (list, "navigation-sidebar");

  for (guint i = 0; i < results->len; i++)
    {
      const LkPickDecoded *decoded = g_ptr_array_index (results, i);

      if (lk_pick_is_note (decoded) != notes)
        continue;

      GtkWidget *row = gtk_list_box_row_new ();
      gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), lk_pick_list_row (decoded, notes));
      g_object_set_data (G_OBJECT (row), "lk-index", GUINT_TO_POINTER (i));
      gtk_list_box_append (GTK_LIST_BOX (list), row);
    }

  if (gtk_widget_get_first_child (list) == NULL)
    {
      g_object_ref_sink (list);
      g_object_unref (list);
      return NULL;
    }

  g_signal_connect (list, "row-selected", G_CALLBACK (lk_pick_row_selected), card);
  return list;
}

/* The pick's objects stay in sight beside the report. There is no pager to
 * walk blind and nothing to go back from. */
static GtkWidget *
lk_pick_list_new (LkPickCard *card, GPtrArray *results)
{
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  g_autofree char *heading = g_strdup_printf ("%u OBJECTS", results->len);

  gtk_box_append (GTK_BOX (column), lk_pick_column_heading (heading));

  card->list = lk_pick_list_box (card, results, FALSE);
  card->notes = lk_pick_list_box (card, results, TRUE);

  if (card->list != NULL)
    {
      GtkWidget *scroller = gtk_scrolled_window_new ();
      gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), card->list);
      gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                      GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
      gtk_scrolled_window_set_propagate_natural_height (GTK_SCROLLED_WINDOW (scroller), TRUE);
      /* A long list scrolls rather than driving the card past the free area:
       * the detail column decides the card's height, not the object count. */
      gtk_scrolled_window_set_max_content_height (GTK_SCROLLED_WINDOW (scroller),
                                                  MAX (80, card->ceiling - 60));
      gtk_widget_set_vexpand (scroller, TRUE);
      gtk_box_append (GTK_BOX (column), scroller);
    }

  /* The chart's notes sit at the column's floor, outside the scroller. Every
   * pick in the cell carries the same ones, so they keep one place instead of
   * scrolling away under a long list. */
  if (card->notes != NULL)
    {
      GtkWidget *shelf = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
      GtkWidget *rule = gtk_separator_new (GTK_ORIENTATION_HORIZONTAL);

      gtk_widget_set_margin_start (rule, 9);
      gtk_widget_set_margin_end (rule, 9);
      gtk_widget_set_margin_bottom (rule, 5);
      gtk_box_append (GTK_BOX (shelf), rule);
      gtk_box_append (GTK_BOX (shelf), card->notes);

      gtk_widget_set_valign (shelf, GTK_ALIGN_END);
      gtk_widget_set_margin_bottom (shelf, 8);
      gtk_box_append (GTK_BOX (column), shelf);
    }

  gtk_widget_set_size_request (column, LK_PICK_LIST_WIDTH, -1);
  gtk_widget_add_css_class (column, "lk-object-list");
  return column;
}

GtkWidget *
lk_pick_report_new (LkAppModel *model, int width, int room)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  GPtrArray *results = lk_app_model_get_pick_results (model);
  g_return_val_if_fail (results != NULL && results->len > 0, NULL);

  LkPickCard *card = g_new0 (LkPickCard, 1);
  card->model = model;
  card->width = width;
  /* Half the free area is the card's share. A pick report is something the
   * mariner reads beside the chart, not instead of it, so a content-rich
   * object scrolls rather than growing over the view. */
  /* The minimum is a wish, not a floor: on a small panel the free area can be
   * shorter than it, and a card taller than the room it was given hangs off
   * the screen. The room always wins. */
  card->ceiling = MIN (room, MAX (LK_PICK_MIN_HEIGHT, room / 2));

  GtkWidget *root = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  guint index = MIN (lk_app_model_get_pick_index (model), results->len - 1);

  /* The width is the card's; the height comes from the content, capped by the
   * room the placement left, so a long report scrolls instead of growing over
   * the mark it stands beside. The window aligns it against the mark. Both the
   * width and the frame are set before the first object goes in: the card
   * measures itself as it builds, and a border it does not carry yet would
   * make that measurement short. */
  card->root = root;
  gtk_widget_set_size_request (root, width, -1);
  gtk_widget_add_css_class (root, "lk-panel");
  gtk_widget_add_css_class (root, "lk-pick-report");
  /* Name the card, so a screen reader reads it as one thing rather than a loose
     run of labels. */
  gtk_accessible_update_property (GTK_ACCESSIBLE (root),
                                  GTK_ACCESSIBLE_PROPERTY_LABEL, "Pick report", -1);

  if (results->len > 1)
    {
      gtk_box_append (GTK_BOX (root), lk_pick_list_new (card, results));
      gtk_box_append (GTK_BOX (root), gtk_separator_new (GTK_ORIENTATION_VERTICAL));
    }

  card->detail_slot = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_hexpand (card->detail_slot, TRUE);
  gtk_box_append (GTK_BOX (root), card->detail_slot);
  lk_pick_card_show (card, index);

  GtkWidget *keyboard = lk_pick_list_select (card, index);
  if (keyboard != NULL)
    {
      /* The arrows walk the objects the moment the report opens. Without this
       * the focus stays on the chart view, which answers no key at all, and
       * the list is reachable only by a second click on it. */
      g_signal_connect_object (root, "map", G_CALLBACK (lk_pick_focus_on_map),
                               keyboard, 0);
    }

  /* The card's state lives as long as the widget it drives. */
  g_object_set_data_full (G_OBJECT (root), "lk-pick-card", card, g_free);
  return root;
}
