#include "lk-pick-report.h"

#include "lk-json.h"

#include <math.h>

/* The object column's width, and the detail column's. A report needs the room
 * to read a note; the pair matches PickReport.swift and PickReport.kt. */
#define LK_PICK_LIST_WIDTH   200
#define LK_PICK_DETAIL_WIDTH 430

/* ---- the decode --------------------------------------------------------- */

static void
lk_report_row_free (LkReportRow *row)
{
  if (row == NULL)
    return;
  g_free (row->label);
  g_free (row->value);
  g_free (row);
}

static void
lk_raw_row_free (LkRawRow *row)
{
  if (row == NULL)
    return;
  g_free (row->name);
  g_free (row->value);
  g_free (row);
}

/* The payload flattened depth-first, keys sorted, so the fold reads the same
 * here as it does on the other shells. A container becomes a heading row and
 * its parts indent under it — S-101 nests where S-57 was flat. */
static void
lk_raw_rows_append (const LkJson *node, const char *name, int depth, GPtrArray *out)
{
  switch (lk_json_kind (node))
    {
    case LK_JSON_OBJECT:
      {
        if (name != NULL)
          {
            LkRawRow *row = g_new0 (LkRawRow, 1);
            row->name = g_strdup (name);
            row->value = g_strdup ("");
            row->depth = depth;
            g_ptr_array_add (out, row);
          }

        g_autoptr (GPtrArray) names = lk_json_member_names (node);
        for (guint i = 0; i < names->len; i++)
          {
            const char *key = g_ptr_array_index (names, i);
            lk_raw_rows_append (lk_json_member (node, key), key,
                                name == NULL ? depth : depth + 1, out);
          }
        return;
      }

    case LK_JSON_ARRAY:
      {
        if (name != NULL)
          {
            LkRawRow *row = g_new0 (LkRawRow, 1);
            row->name = g_strdup (name);
            row->value = g_strdup ("");
            row->depth = depth;
            g_ptr_array_add (out, row);
          }

        for (guint i = 0; i < lk_json_length (node); i++)
          lk_raw_rows_append (lk_json_at (node, i), NULL, depth + 1, out);
        return;
      }

    default:
      {
        LkRawRow *row = g_new0 (LkRawRow, 1);
        row->name = g_strdup (name != NULL ? name : "");
        row->value = g_strdup (lk_json_text (node));
        row->depth = depth;
        g_ptr_array_add (out, row);
        return;
      }
    }
}

/* The envelope's raw half, or the whole payload when there is no envelope —
 * the core's fallback when a compose fails. The fold still shows everything. */
static const LkJson *
lk_pick_raw_half (const LkJson *root)
{
  if (lk_json_member (root, "report") != NULL)
    return lk_json_member (root, "s57");
  return root;
}

LkPickDecoded *
lk_pick_decoded_new (const LkPickFeature *feature)
{
  g_return_val_if_fail (feature != NULL, NULL);

  LkPickDecoded *decoded = g_new0 (LkPickDecoded, 1);
  decoded->notes = g_ptr_array_new_with_free_func (g_free);
  decoded->rows = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_report_row_free);
  decoded->raw_rows = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_raw_row_free);

  g_autoptr (LkJson) root = lk_json_parse (feature->s57);
  const LkJson *report = lk_json_member (root, "report");

  const char *title = lk_json_member_string (report, "title");
  const char *chip = lk_json_member_string (report, "chip");
  const char *footnote = lk_json_member_string (report, "footnote");

  decoded->title = g_strdup (title != NULL ? title : feature->cls);
  decoded->subtitle = g_strdup (lk_json_member_string (report, "subtitle"));
  decoded->chip = g_strdup (chip != NULL ? chip : feature->cls);
  decoded->footnote = g_strdup (footnote != NULL ? footnote : feature->chart);

  const LkJson *notes = lk_json_member (report, "notes");
  for (guint i = 0; i < lk_json_length (notes); i++)
    {
      const char *note = lk_json_string (lk_json_at (notes, i));
      if (note != NULL && note[0] != '\0')
        g_ptr_array_add (decoded->notes, g_strdup (note));
    }

  const LkJson *rows = lk_json_member (report, "rows");
  for (guint i = 0; i < lk_json_length (rows); i++)
    {
      const LkJson *item = lk_json_at (rows, i);
      if (lk_json_kind (item) != LK_JSON_OBJECT)
        continue;

      LkReportRow *row = g_new0 (LkReportRow, 1);
      row->label = g_strdup (lk_json_text (lk_json_member (item, "label")));
      row->value = g_strdup (lk_json_text (lk_json_member (item, "value")));
      row->depth = lk_json_member_int (item, "depth", 0);
      row->file = lk_json_member_bool (item, "file", FALSE);
      row->picture = lk_json_member_bool (item, "picture", FALSE);
      g_ptr_array_add (decoded->rows, row);
    }

  const char *empty = lk_json_member_string (report, "empty");
  if (g_strcmp0 (empty, "none") == 0)
    decoded->body = LK_PICK_BODY_NO_ATTRIBUTES;
  else if (g_strcmp0 (empty, "source") == 0)
    decoded->body = LK_PICK_BODY_SOURCE_ONLY;

  lk_raw_rows_append (lk_pick_raw_half (root), NULL, 0, decoded->raw_rows);
  return decoded;
}

void
lk_pick_decoded_free (LkPickDecoded *decoded)
{
  if (decoded == NULL)
    return;

  g_free (decoded->title);
  g_free (decoded->subtitle);
  g_free (decoded->chip);
  g_free (decoded->footnote);
  g_ptr_array_unref (decoded->notes);
  g_ptr_array_unref (decoded->rows);
  g_ptr_array_unref (decoded->raw_rows);
  g_free (decoded);
}

char *
lk_pick_plain_text (const LkPickFeature *feature)
{
  g_return_val_if_fail (feature != NULL, NULL);

  g_autoptr (LkJson) root = lk_json_parse (feature->s57);
  g_autoptr (GPtrArray) rows = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_raw_row_free);
  g_autoptr (GString) text = g_string_new (NULL);

  g_string_append_printf (text, "%s  %s\n", feature->cls, feature->chart);
  lk_raw_rows_append (lk_pick_raw_half (root), NULL, 0, rows);

  for (guint i = 0; i < rows->len; i++)
    {
      const LkRawRow *row = g_ptr_array_index (rows, i);
      g_autofree char *indent = g_strnfill ((gsize) row->depth * 2, ' ');

      if (row->value[0] == '\0')
        g_string_append_printf (text, "%s%s:\n", indent, row->name);
      else
        g_string_append_printf (text, "%s%s: %s\n", indent, row->name, row->value);
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
  GtkWidget  *detail_slot; /* the column rebuilt as the selection moves */
  GtkWidget  *list;        /* GtkListBox, NULL for a single-object pick */
  int         room;        /* the height the card may use */
  gboolean    fold_open;   /* per pick, not per object */
  gboolean    setting_row; /* guards the list's own selection callback */
} LkPickCard;

static void lk_pick_card_show (LkPickCard *card, guint index);

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
lk_pick_row_widget (LkPickCard *card, const LkReportRow *row, const char *cell)
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
lk_pick_append_raw_rows (GtkWidget *body, const LkPickDecoded *decoded)
{
  for (guint i = 0; i < decoded->raw_rows->len; i++)
    {
      const LkRawRow *row = g_ptr_array_index (decoded->raw_rows, i);
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
      g_autofree char *name = row->value[0] == '\0' ? g_strdup (row->name)
                                                    : g_strconcat (row->name, ":", NULL);
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
  return button;
}

/* The detail column for one object: the header, the body that scrolls, and
 * the provenance and the fold pinned under it — a control keeps its place. */
static GtkWidget *
lk_pick_detail_new (LkPickCard *card, const LkPickFeature *feature)
{
  g_autoptr (LkPickDecoded) decoded = lk_pick_decoded_new (feature);
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  /* ---- header ---- */
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *titles = gtk_box_new (GTK_ORIENTATION_VERTICAL, 1);
  GtkWidget *title = gtk_label_new (decoded->title);
  /* The subtitle line is kept even when empty, so the header is the same
   * height for every object and the rows below cannot shift as the selection
   * moves. */
  GtkWidget *subtitle = gtk_label_new (decoded->subtitle != NULL ? decoded->subtitle : " ");

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
  if (decoded->body != LK_PICK_BODY_FULL)
    {
      GtkWidget *empty = gtk_label_new (
          decoded->body == LK_PICK_BODY_NO_ATTRIBUTES
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
                                        feature->chart));

  if (card->fold_open)
    lk_pick_append_raw_rows (body, decoded);

  GtkWidget *scroller = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), body);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  /* The report takes the height its content asks for, and scrolls once that
   * would run over the mark. */
  gtk_scrolled_window_set_propagate_natural_height (GTK_SCROLLED_WINDOW (scroller), TRUE);
  gtk_scrolled_window_set_max_content_height (GTK_SCROLLED_WINDOW (scroller),
                                              MAX (80, card->room - 150));
  gtk_widget_set_vexpand (scroller, TRUE);
  gtk_box_append (GTK_BOX (column), scroller);

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
      g_strdup_printf ("S-57 source attributes (%u)", decoded->raw_rows->len);
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
}

static void
lk_pick_row_selected (GtkListBox *list, GtkListBoxRow *row, gpointer user_data)
{
  LkPickCard *card = user_data;

  if (row == NULL || card->setting_row)
    return;

  guint index = (guint) gtk_list_box_row_get_index (row);
  lk_app_model_set_pick_index (card->model, index);
  lk_pick_card_show (card, index);
}

/* The pick's objects stay in sight beside the report. There is no pager to
 * walk blind and nothing to go back from. */
static GtkWidget *
lk_pick_list_new (LkPickCard *card, GPtrArray *results)
{
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  g_autofree char *heading = g_strdup_printf ("%u OBJECTS", results->len);
  GtkWidget *heading_label = gtk_label_new (heading);

  gtk_label_set_xalign (GTK_LABEL (heading_label), 0);
  gtk_widget_add_css_class (heading_label, "caption-heading");
  gtk_widget_add_css_class (heading_label, "dim-label");
  gtk_widget_set_margin_start (heading_label, 14);
  gtk_widget_set_margin_end (heading_label, 10);
  gtk_widget_set_margin_top (heading_label, 14);
  gtk_widget_set_margin_bottom (heading_label, 6);
  gtk_box_append (GTK_BOX (column), heading_label);

  card->list = gtk_list_box_new ();
  gtk_list_box_set_selection_mode (GTK_LIST_BOX (card->list), GTK_SELECTION_SINGLE);
  gtk_widget_add_css_class (card->list, "navigation-sidebar");

  for (guint i = 0; i < results->len; i++)
    {
      g_autoptr (LkPickDecoded) decoded =
          lk_pick_decoded_new (g_ptr_array_index (results, i));
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
      GtkWidget *title = gtk_label_new (decoded->title);

      gtk_label_set_xalign (GTK_LABEL (title), 0);
      gtk_label_set_ellipsize (GTK_LABEL (title), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class (title, "heading");
      gtk_box_append (GTK_BOX (box), title);

      if (decoded->subtitle != NULL)
        {
          GtkWidget *subtitle = gtk_label_new (decoded->subtitle);
          gtk_label_set_xalign (GTK_LABEL (subtitle), 0);
          gtk_label_set_ellipsize (GTK_LABEL (subtitle), PANGO_ELLIPSIZE_END);
          gtk_widget_add_css_class (subtitle, "caption");
          gtk_widget_add_css_class (subtitle, "dim-label");
          gtk_box_append (GTK_BOX (box), subtitle);
        }

      gtk_list_box_append (GTK_LIST_BOX (card->list), box);
    }

  g_signal_connect (card->list, "row-selected", G_CALLBACK (lk_pick_row_selected), card);

  GtkWidget *scroller = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), card->list);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_propagate_natural_height (GTK_SCROLLED_WINDOW (scroller), TRUE);
  /* A long list scrolls rather than driving the card past the free area: the
   * detail column decides the card's height, not the object count. */
  gtk_scrolled_window_set_max_content_height (GTK_SCROLLED_WINDOW (scroller),
                                              MAX (80, card->room - 60));
  gtk_widget_set_vexpand (scroller, TRUE);
  gtk_box_append (GTK_BOX (column), scroller);

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
  card->room = room;

  GtkWidget *root = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  guint index = MIN (lk_app_model_get_pick_index (model), results->len - 1);

  if (results->len > 1)
    {
      gtk_box_append (GTK_BOX (root), lk_pick_list_new (card, results));
      gtk_box_append (GTK_BOX (root), gtk_separator_new (GTK_ORIENTATION_VERTICAL));
    }

  card->detail_slot = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_hexpand (card->detail_slot, TRUE);
  gtk_box_append (GTK_BOX (root), card->detail_slot);
  lk_pick_card_show (card, index);

  if (card->list != NULL)
    {
      card->setting_row = TRUE;
      gtk_list_box_select_row (GTK_LIST_BOX (card->list),
                               gtk_list_box_get_row_at_index (GTK_LIST_BOX (card->list),
                                                              (int) index));
      card->setting_row = FALSE;
    }

  /* The width is the card's; the height comes from the content, capped by the
   * room the placement left, so a long report scrolls instead of growing over
   * the mark it stands beside. The window aligns it against the mark. */
  gtk_widget_set_size_request (root, width, -1);
  gtk_widget_add_css_class (root, "lk-panel");
  gtk_widget_add_css_class (root, "lk-pick-report");

  /* The card's state lives as long as the widget it drives. */
  g_object_set_data_full (G_OBJECT (root), "lk-pick-card", card, g_free);
  return root;
}
