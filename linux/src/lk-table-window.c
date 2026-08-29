#include "lk-table-window.h"

#include "lk-json.h"

#include <math.h>

/* How often the rows are re-read. The plugins feed a table at their status
 * cadence, which is a second, so this is the same. The timer runs only while a
 * window is open, and the plugin builds no rows until it is told one is. */
#define LK_TABLE_POLL_MS 1000

/* A cell the plugin did not send. It is not a zero, and it never reads as one. */
#define LK_TABLE_MISSING "—"

/* Under a tenth of a mile the metres are what matters: a CPA of "0.07 nm"
 * tells a mariner far less than "124 m". */
#define LK_TABLE_METRES_BELOW 185.2

typedef enum {
  LK_COLUMN_TEXT,
  LK_COLUMN_NUMBER,
  LK_COLUMN_DISTANCE,
  LK_COLUMN_SPEED,
  LK_COLUMN_BEARING,
  LK_COLUMN_DURATION,
  LK_COLUMN_FLAG,
} LkColumnType;

typedef struct {
  char        *key;
  char        *label;
  LkColumnType type;
} LkTableColumn;

typedef struct {
  LkAppModel  *model;
  LkTableSpec *spec;
  GPtrArray   *columns; /* LkTableColumn* */

  GtkWidget   *window;
  GtkWidget   *rows;   /* the GtkListBox the rows are built into */
  GtkWidget   *empty;
  GPtrArray   *widths; /* GtkSizeGroup*, one per column, so the rows line up */

  char     *sort_key;
  gboolean  ascending;
  gint64    seq; /* the batch on screen; -1 forces the next read to rebuild,
                    LK_TABLE_SEQ_DEAD marks the emptied "plugin gone" state */
  guint     poll_id;
} LkTableWindow;

#define LK_TABLE_SEQ_DEAD (-2)

/* Every table window on screen, by "<plugin>/<key>". A second Open finds the
 * window it already has instead of stacking another one on it. */
static GHashTable *lk_table_windows;

void
lk_table_spec_free (LkTableSpec *spec)
{
  if (spec == NULL)
    return;
  g_free (spec->plugin);
  g_free (spec->key);
  g_free (spec->title);
  g_free (spec->menu);
  g_free (spec);
}

static void
lk_table_column_free (gpointer data)
{
  LkTableColumn *column = data;

  g_free (column->key);
  g_free (column->label);
  g_free (column);
}

static LkColumnType
lk_column_type_parse (const char *word)
{
  if (g_strcmp0 (word, "distance") == 0)
    return LK_COLUMN_DISTANCE;
  if (g_strcmp0 (word, "speed") == 0)
    return LK_COLUMN_SPEED;
  if (g_strcmp0 (word, "bearing") == 0)
    return LK_COLUMN_BEARING;
  if (g_strcmp0 (word, "duration") == 0)
    return LK_COLUMN_DURATION;
  if (g_strcmp0 (word, "number") == 0)
    return LK_COLUMN_NUMBER;
  if (g_strcmp0 (word, "flag") == 0)
    return LK_COLUMN_FLAG;
  return LK_COLUMN_TEXT;
}

/* A number is what the mariner scans down a column of, so it is right
 * aligned. */
static gboolean
lk_column_is_numeric (LkColumnType type)
{
  return type != LK_COLUMN_TEXT && type != LK_COLUMN_FLAG;
}

/* ---- what a cell says, in the units of the sea --------------------------- */

/* Seconds as a mariner counts them down: minutes and seconds, and hours once
 * there are any. */
static char *
lk_table_duration (double seconds)
{
  const char *sign = seconds < 0 ? "-" : "";
  int total = (int) (fabs (seconds) + 0.5);

  if (total >= 3600)
    return g_strdup_printf ("%s%d:%02d:%02d", sign, total / 3600,
                            (total % 3600) / 60, total % 60);
  return g_strdup_printf ("%s%d:%02d", sign, total / 60, total % 60);
}

static char *
lk_table_cell_text (const LkJson *cell, LkColumnType type)
{
  LkJsonKind kind = lk_json_kind (cell);

  if (cell == NULL || kind == LK_JSON_NULL)
    return g_strdup (LK_TABLE_MISSING);

  if (kind == LK_JSON_STRING)
    {
      const char *text = lk_json_string (cell);

      return type == LK_COLUMN_FLAG ? g_ascii_strup (text, -1) : g_strdup (text);
    }

  double value = lk_json_number (cell, 0);
  if (!isfinite (value))
    return g_strdup (LK_TABLE_MISSING);

  switch (type)
    {
    case LK_COLUMN_DISTANCE:
      return value < LK_TABLE_METRES_BELOW
                 ? g_strdup_printf ("%d m", (int) (value + 0.5))
                 : g_strdup_printf ("%.2f nm", value / 1852.0);
    case LK_COLUMN_SPEED:
      return g_strdup_printf ("%.1f kn", value * 3600.0 / 1852.0);
    case LK_COLUMN_BEARING:
      {
        double degrees = fmod (value, 360.0);

        return g_strdup_printf ("%03.0f°", degrees < 0 ? degrees + 360.0 : degrees);
      }
    case LK_COLUMN_DURATION:
      return lk_table_duration (value);
    default:
      return g_strdup_printf ("%g", value);
    }
}

/* A row's colour comes from its flag column. Alarm takes the chart's own danger
 * colour and a warning takes amber. A row with nothing wrong is left alone. */
static const char *
lk_table_flag_class (const char *flag)
{
  g_autofree char *lowered = flag == NULL ? NULL : g_ascii_strdown (flag, -1);

  if (lowered == NULL)
    return NULL;
  if (g_strcmp0 (lowered, "alarm") == 0)
    return "lk-alarm";
  if (g_strcmp0 (lowered, "warning") == 0)
    return "lk-warning";
  return NULL;
}

/* ---- the declarations ---------------------------------------------------- */

GPtrArray *
lk_table_specs (LkAppModel *model)
{
  GPtrArray *specs = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_table_spec_free);

  g_return_val_if_fail (LK_IS_APP_MODEL (model), specs);

  g_autofree char *json =
      lk_chart_controller_tables_json (lk_app_model_get_controller (model));
  g_autoptr (LkJson) root = json == NULL ? NULL : lk_json_parse (json);
  const LkJson *list = lk_json_member (root, "tables");

  for (guint i = 0; i < lk_json_length (list); i++)
    {
      const LkJson *node = lk_json_at (list, i);
      const char *plugin = lk_json_member_string (node, "plugin");
      const char *key = lk_json_member_string (node, "key");

      if (plugin == NULL || key == NULL)
        continue;

      LkTableSpec *spec = g_new0 (LkTableSpec, 1);

      spec->plugin = g_strdup (plugin);
      spec->key = g_strdup (key);
      spec->title = g_strdup (lk_json_member_string (node, "title") ?: key);
      spec->menu = g_strdup (lk_json_member_string (node, "menu") ?: "Vessels");
      /* `at` names two row keys carrying a position. A table that declared none
       * has no rows to find on the chart. */
      spec->locatable = lk_json_member (node, "at") != NULL;
      g_ptr_array_add (specs, spec);
    }

  return specs;
}

/* The columns, which come from the same declaration the specs did. They are
 * read when the window opens, because a table's shape does not change while it
 * is on screen. */
static GPtrArray *
lk_table_read_columns (LkAppModel *model, const LkTableSpec *spec,
                       char **out_sort_key, gboolean *out_ascending)
{
  GPtrArray *columns = g_ptr_array_new_with_free_func (lk_table_column_free);
  g_autofree char *json =
      lk_chart_controller_tables_json (lk_app_model_get_controller (model));
  g_autoptr (LkJson) root = json == NULL ? NULL : lk_json_parse (json);
  const LkJson *list = lk_json_member (root, "tables");

  for (guint i = 0; i < lk_json_length (list); i++)
    {
      const LkJson *node = lk_json_at (list, i);

      if (g_strcmp0 (lk_json_member_string (node, "plugin"), spec->plugin) != 0 ||
          g_strcmp0 (lk_json_member_string (node, "key"), spec->key) != 0)
        continue;

      const LkJson *declared = lk_json_member (node, "columns");
      for (guint c = 0; c < lk_json_length (declared); c++)
        {
          const LkJson *entry = lk_json_at (declared, c);
          const char *key = lk_json_member_string (entry, "key");

          if (key == NULL)
            continue;

          LkTableColumn *column = g_new0 (LkTableColumn, 1);

          column->key = g_strdup (key);
          column->label = g_strdup (lk_json_member_string (entry, "label") ?: key);
          column->type = lk_column_type_parse (lk_json_member_string (entry, "type"));
          g_ptr_array_add (columns, column);
        }

      const LkJson *sort = lk_json_member (node, "sort");
      *out_sort_key = g_strdup (lk_json_member_string (sort, "key"));
      *out_ascending = lk_json_member_bool (sort, "ascending", TRUE);
      break;
    }

  return columns;
}

/* ---- the rows ------------------------------------------------------------ */

static void
lk_table_reload (LkTableWindow *self, gboolean force)
{
  g_autofree char *json =
      lk_chart_controller_table_rows (lk_app_model_get_controller (self->model),
                                      self->spec->plugin, self->spec->key,
                                      self->sort_key, self->ascending);
  g_autoptr (LkJson) root = json == NULL ? NULL : lk_json_parse (json);

  if (root == NULL)
    {
      /* The plugin has gone, and the table with it. An empty window beats a
       * picture nobody is keeping up to date. Clear it once, then hold: redoing
       * it every second is work with nothing to show. Keep polling, so the
       * table refills if the plugin restarts. */
      if (self->seq == LK_TABLE_SEQ_DEAD)
        return;
      self->seq = LK_TABLE_SEQ_DEAD;
      gtk_list_box_remove_all (GTK_LIST_BOX (self->rows));
      gtk_widget_set_visible (self->empty, TRUE);
      return;
    }

  /* seq bumps on every accepted batch. The rows are rebuilt only when it moves,
   * so a table nobody is feeding does not flicker once a second. */
  gint64 seq = (gint64) lk_json_number (lk_json_member (root, "seq"), 0);
  if (!force && seq == self->seq)
    return;
  self->seq = seq;

  gtk_list_box_remove_all (GTK_LIST_BOX (self->rows));

  const LkJson *list = lk_json_member (root, "rows");
  guint count = lk_json_length (list);

  for (guint i = 0; i < count; i++)
    {
      const LkJson *node = lk_json_at (list, i);
      const LkJson *cells = lk_json_member (node, "cells");
      GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      const char *tint = NULL;

      for (guint c = 0; c < self->columns->len; c++)
        {
          const LkTableColumn *column = g_ptr_array_index (self->columns, c);
          const LkJson *cell = lk_json_at (cells, c);
          g_autofree char *text = lk_table_cell_text (cell, column->type);
          GtkWidget *label = gtk_label_new (text);

          gtk_label_set_xalign (GTK_LABEL (label),
                                lk_column_is_numeric (column->type) ? 1.0 : 0.0);
          gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
          gtk_widget_add_css_class (label, "numeric");

          /* A cell the plugin never sent is greyed, so the mariner can tell a
           * value that is missing from one that is small. */
          if (lk_json_kind (cell) == LK_JSON_NULL || cell == NULL)
            gtk_widget_add_css_class (label, "dim-label");
          else if (column->type == LK_COLUMN_FLAG)
            {
              const char *flag = lk_table_flag_class (lk_json_string (cell));

              if (flag != NULL)
                {
                  gtk_widget_add_css_class (label, flag);
                  tint = flag;
                }
            }

          gtk_size_group_add_widget (g_ptr_array_index (self->widths, c), label);
          gtk_box_append (GTK_BOX (line), label);
        }

      GtkWidget *row = gtk_list_box_row_new ();
      gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), line);
      gtk_list_box_row_set_activatable (GTK_LIST_BOX_ROW (row), self->spec->locatable);
      if (tint != NULL)
        {
          gtk_widget_add_css_class (row, "lk-table-flagged");
          gtk_widget_add_css_class (row, tint);
        }

      /* Where the row is, for the activation below. A table that declared `at`
       * may still hold a row nobody has heard a position from. */
      const LkJson *at = lk_json_member (node, "at");
      if (lk_json_length (at) == 2)
        {
          double *point = g_new (double, 2);

          point[0] = lk_json_number (lk_json_at (at, 0), 0);
          point[1] = lk_json_number (lk_json_at (at, 1), 0);
          g_object_set_data_full (G_OBJECT (row), "lk-table-at", point, g_free);
        }

      gtk_list_box_append (GTK_LIST_BOX (self->rows), row);
    }

  gtk_widget_set_visible (self->empty, count == 0);
}

static gboolean
lk_table_poll (gpointer user_data)
{
  lk_table_reload (user_data, FALSE);
  return G_SOURCE_CONTINUE;
}

/* The row the mariner opened: centre the chart on it. Entirely shell-side. The
 * plugin is not told, and does not need to be. */
static void
lk_table_row_activated (GtkListBox *box, GtkListBoxRow *row, gpointer user_data)
{
  LkTableWindow *self = user_data;
  const double *point = g_object_get_data (G_OBJECT (row), "lk-table-at");

  if (!self->spec->locatable || point == NULL)
    return;

  lookout_view view = lk_chart_controller_get_view (lk_app_model_get_controller (self->model));

  view.lon = point[0];
  view.lat = point[1];
  lk_chart_controller_set_view (lk_app_model_get_controller (self->model), view);
}

/* A header click reorders WITHIN each band. The core does the sorting; this
 * only says which column and which way. Clicking the sorted column again
 * reverses it, as every table does. */
static void
lk_table_header_clicked (GtkButton *button, gpointer user_data)
{
  LkTableWindow *self = user_data;
  const char *key = g_object_get_data (G_OBJECT (button), "lk-column-key");

  if (g_strcmp0 (key, self->sort_key) == 0)
    self->ascending = !self->ascending;
  else
    {
      g_free (self->sort_key);
      self->sort_key = g_strdup (key);
      self->ascending = TRUE;
    }

  lk_table_reload (self, TRUE);
}

static void
lk_table_window_free (gpointer data)
{
  LkTableWindow *self = data;

  g_clear_handle_id (&self->poll_id, g_source_remove);
  /* The plugin builds rows only while somebody is looking. Saying the window
   * has gone is what stops it. */
  lk_chart_controller_table_open (lk_app_model_get_controller (self->model),
                                  self->spec->plugin, self->spec->key, FALSE);

  g_autofree char *id = g_strdup_printf ("%s/%s", self->spec->plugin, self->spec->key);
  if (lk_table_windows != NULL)
    g_hash_table_remove (lk_table_windows, id);

  g_ptr_array_unref (self->columns);
  g_ptr_array_unref (self->widths);
  lk_table_spec_free (self->spec);
  g_free (self->sort_key);
  g_free (self);
}

void
lk_table_window_present (GtkWindow *parent, LkAppModel *model, const LkTableSpec *spec)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));
  g_return_if_fail (spec != NULL);

  g_autofree char *id = g_strdup_printf ("%s/%s", spec->plugin, spec->key);

  if (lk_table_windows == NULL)
    lk_table_windows = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);

  GtkWidget *existing = g_hash_table_lookup (lk_table_windows, id);
  if (existing != NULL)
    {
      gtk_window_present (GTK_WINDOW (existing));
      return;
    }

  LkTableWindow *self = g_new0 (LkTableWindow, 1);

  self->model = model;
  self->seq = -1;
  self->spec = g_new0 (LkTableSpec, 1);
  self->spec->plugin = g_strdup (spec->plugin);
  self->spec->key = g_strdup (spec->key);
  self->spec->title = g_strdup (spec->title);
  self->spec->menu = g_strdup (spec->menu);
  self->spec->locatable = spec->locatable;
  self->columns = lk_table_read_columns (model, spec, &self->sort_key, &self->ascending);

  if (self->columns->len == 0)
    {
      /* A declaration with no columns has no table in it. */
      g_ptr_array_unref (self->columns);
      lk_table_spec_free (self->spec);
      g_free (self->sort_key);
      g_free (self);
      return;
    }

  self->widths = g_ptr_array_new_with_free_func (g_object_unref);
  self->window = gtk_window_new ();

  gtk_window_set_title (GTK_WINDOW (self->window), spec->title);
  gtk_window_set_transient_for (GTK_WINDOW (self->window), parent);
  gtk_window_set_default_size (GTK_WINDOW (self->window),
                               MIN (200 + (int) self->columns->len * 110, 1100), 420);
  g_object_set_data_full (G_OBJECT (self->window), "lk-table-window", self,
                          lk_table_window_free);

  GtkWidget *root = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);

  gtk_widget_add_css_class (header, "lk-table-header");
  for (guint c = 0; c < self->columns->len; c++)
    {
      const LkTableColumn *column = g_ptr_array_index (self->columns, c);
      GtkWidget *button = gtk_button_new_with_label (column->label);
      GtkSizeGroup *width = gtk_size_group_new (GTK_SIZE_GROUP_HORIZONTAL);

      gtk_widget_add_css_class (button, "flat");
      gtk_widget_add_css_class (button, "lk-table-heading");
      gtk_widget_set_tooltip_text (button, "Sort by this column");
      g_object_set_data_full (G_OBJECT (button), "lk-column-key", g_strdup (column->key),
                              g_free);
      g_signal_connect (button, "clicked", G_CALLBACK (lk_table_header_clicked), self);

      /* The size group is what lines the header up with the rows: GTK gives
       * every widget in it the same width, and each column has its own. */
      gtk_size_group_add_widget (width, button);
      g_ptr_array_add (self->widths, width);
      gtk_box_append (GTK_BOX (header), button);
    }
  gtk_box_append (GTK_BOX (root), header);

  self->rows = gtk_list_box_new ();
  gtk_list_box_set_selection_mode (GTK_LIST_BOX (self->rows), GTK_SELECTION_SINGLE);
  gtk_widget_add_css_class (self->rows, "lk-table-rows");
  g_signal_connect (self->rows, "row-activated", G_CALLBACK (lk_table_row_activated), self);

  GtkWidget *scroller = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), self->rows);
  gtk_widget_set_vexpand (scroller, TRUE);

  self->empty = gtk_label_new ("Nothing to show yet.");
  gtk_widget_add_css_class (self->empty, "dim-label");
  gtk_widget_set_valign (self->empty, GTK_ALIGN_CENTER);
  gtk_widget_set_vexpand (self->empty, TRUE);

  GtkWidget *stack = gtk_overlay_new ();
  gtk_overlay_set_child (GTK_OVERLAY (stack), scroller);
  gtk_overlay_add_overlay (GTK_OVERLAY (stack), self->empty);
  gtk_box_append (GTK_BOX (root), stack);
  gtk_window_set_child (GTK_WINDOW (self->window), root);

  g_hash_table_insert (lk_table_windows, g_strdup (id), self->window);

  /* The plugin is told BEFORE the first read: it builds no rows until somebody
   * is looking, so the first read would otherwise find none. */
  lk_chart_controller_table_open (lk_app_model_get_controller (model),
                                  spec->plugin, spec->key, TRUE);
  lk_table_reload (self, TRUE);
  self->poll_id = g_timeout_add (LK_TABLE_POLL_MS, lk_table_poll, self);

  gtk_window_present (GTK_WINDOW (self->window));
}
