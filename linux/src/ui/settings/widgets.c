/* ui/settings/widgets.c — the pieces every settings page is built from.
 *
 * A page is a column of sections; a section is a title over a column of rows;
 * a row is a label and one control. The bindings below carry a pointer to the
 * mariner field a control edits, so a page declares what it edits and nothing
 * more.
 */
#include "ui/settings/widgets.h"

/* Frees a per-widget binding when its closure dies. */
void
lk_binding_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

GtkWidget *
lk_section_titled (GtkWidget *page, const char *title, GtkWidget **out_title)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);

  if (title != NULL)
    {
      GtkWidget *label = gtk_label_new (title);
      gtk_widget_add_css_class (label, "heading");
      gtk_widget_set_halign (label, GTK_ALIGN_START);
      gtk_box_append (GTK_BOX (box), label);
      if (out_title != NULL)
        *out_title = label;
    }

  gtk_widget_set_margin_top (box, 6);
  gtk_box_append (GTK_BOX (page), box);
  return box;
}

GtkWidget *
lk_section (GtkWidget *page, const char *title)
{
  return lk_section_titled (page, title, NULL);
}

GtkWidget *
lk_footer (GtkWidget *section, const char *text)
{
  GtkWidget *label = gtk_label_new (text);

  gtk_widget_add_css_class (label, "dim-label");
  gtk_widget_add_css_class (label, "caption");
  gtk_label_set_wrap (GTK_LABEL (label), TRUE);
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_widget_set_margin_bottom (label, 4);
  gtk_box_append (GTK_BOX (section), label);
  return label;
}

/* A label on the left, a control on the right. */
GtkWidget *
lk_row (GtkWidget *section, const char *title, GtkWidget *control)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  GtkWidget *label = gtk_label_new (title);

  gtk_widget_set_halign (label, GTK_ALIGN_START);
  gtk_widget_set_hexpand (label, TRUE);
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_box_append (GTK_BOX (row), label);
  gtk_box_append (GTK_BOX (row), control);
  gtk_box_append (GTK_BOX (section), row);
  return row;
}

/* One section: a row in the sidebar, and the pane it names in the stack.
 *
 * `id` is the CORE's section name (src/plugin/host.zig, `Tab`), so a plugin
 * and this window mean the same thing by "alarms", and a fix-it elsewhere can
 * ask for a section by the name the core uses. */
GtkWidget *
lk_page_new (LkSettings *settings, const char *id, const char *title, const char *icon_name)
{
  GtkWidget *page = gtk_box_new (GTK_ORIENTATION_VERTICAL, 10);
  GtkWidget *scroller = gtk_scrolled_window_new ();

  gtk_widget_set_margin_start (page, 16);
  gtk_widget_set_margin_end (page, 16);
  gtk_widget_set_margin_top (page, 12);
  gtk_widget_set_margin_bottom (page, 12);

  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), page);
  gtk_stack_add_named (GTK_STACK (settings->stack), scroller, id);

  GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *icon = gtk_image_new_from_icon_name (icon_name);
  GtkWidget *label = gtk_label_new (title);
  GtkWidget *row = gtk_list_box_row_new ();

  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_box_append (GTK_BOX (line), icon);
  gtk_box_append (GTK_BOX (line), label);
  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), line);
  g_object_set_data_full (G_OBJECT (row), "lk-section", g_strdup (id), g_free);
  gtk_list_box_append (GTK_LIST_BOX (settings->sidebar), row);

  return page;
}

/* Engine flags are C `bool` (one byte), not `gboolean`; the binding must carry
 * the real type or a write clobbers the next field. */
typedef struct {
  LkSettings *settings;
  bool       *field;
} LkBoolBinding;

static void
lk_bool_toggled (GtkCheckButton *button, gpointer user_data)
{
  LkBoolBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  *binding->field = gtk_check_button_get_active (button) ? true : false;
  lk_mariner_touch (binding->settings->mariner);
}

void
lk_switch_row (GtkWidget *section, LkSettings *settings, const char *title, bool *field)
{
  GtkWidget *check = gtk_check_button_new ();
  LkBoolBinding *binding = g_new0 (LkBoolBinding, 1);

  binding->settings = settings;
  binding->field = field;

  gtk_check_button_set_active (GTK_CHECK_BUTTON (check), *field);
  gtk_widget_set_valign (check, GTK_ALIGN_CENTER);
  g_signal_connect_data (check, "toggled", G_CALLBACK (lk_bool_toggled), binding,
                         lk_binding_free, 0);
  lk_row (section, title, check);
}

typedef struct {
  LkSettings *settings;
  int        *field;      /* for plain int-backed enums */
  void      (*apply) (LkSettings *settings, int value);
} LkChoiceBinding;

static void
lk_choice_changed (GtkDropDown *dropdown, GParamSpec *pspec, gpointer user_data)
{
  LkChoiceBinding *binding = user_data;
  int value = (int) gtk_drop_down_get_selected (dropdown);

  if (binding->settings->updating || value < 0)
    return;

  if (binding->apply != NULL)
    binding->apply (binding->settings, value);
  else if (binding->field != NULL)
    *binding->field = value;
  else
    return;

  lk_mariner_touch (binding->settings->mariner);
}

GtkWidget *
lk_choice_row (GtkWidget          *section,
               LkSettings         *settings,
               const char         *title,
               const char *const  *options,
               int                 selected,
               int                *field,
               void              (*apply) (LkSettings *, int))
{
  GtkWidget *dropdown = gtk_drop_down_new_from_strings (options);
  LkChoiceBinding *binding = g_new0 (LkChoiceBinding, 1);

  binding->settings = settings;
  binding->field = field;
  binding->apply = apply;

  gtk_drop_down_set_selected (GTK_DROP_DOWN (dropdown), selected);
  gtk_widget_set_valign (dropdown, GTK_ALIGN_CENTER);
  g_signal_connect_data (dropdown, "notify::selected", G_CALLBACK (lk_choice_changed),
                         binding, lk_binding_free, 0);
  lk_row (section, title, dropdown);
  return dropdown;
}

typedef struct {
  LkSettings *settings;
  double     *field;
} LkScaleBinding;

static void
lk_scale_changed (GtkRange *range, gpointer user_data)
{
  LkScaleBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  *binding->field = gtk_range_get_value (range);
  lk_mariner_touch (binding->settings->mariner);
}

static char *
lk_scale_format (GtkScale *scale, double value, gpointer user_data)
{
  return g_strdup_printf ("%.2f×", value);
}

void
lk_size_row (GtkWidget *section, LkSettings *settings, const char *title, double *field)
{
  GtkWidget *scale = gtk_scale_new_with_range (GTK_ORIENTATION_HORIZONTAL, 0.5, 2.0, 0.05);
  LkScaleBinding *binding = g_new0 (LkScaleBinding, 1);

  binding->settings = settings;
  binding->field = field;

  gtk_range_set_value (GTK_RANGE (scale), *field > 0 ? *field : 1.0);
  gtk_scale_set_draw_value (GTK_SCALE (scale), TRUE);
  gtk_scale_set_format_value_func (GTK_SCALE (scale), lk_scale_format, NULL, NULL);
  gtk_widget_set_size_request (scale, 220, -1);
  g_signal_connect_data (scale, "value-changed", G_CALLBACK (lk_scale_changed), binding,
                         lk_binding_free, 0);
  lk_row (section, title, scale);
}

/* A section header with a right-aligned shortcut hint, as the reference's has. */
GtkWidget *
lk_section_hinted (GtkWidget *page, const char *title, const char *hint)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *label = gtk_label_new (title);
  GtkWidget *tip = gtk_label_new (hint);

  gtk_widget_add_css_class (label, "heading");
  gtk_widget_set_halign (label, GTK_ALIGN_START);
  gtk_widget_set_hexpand (label, TRUE);
  gtk_widget_add_css_class (tip, "dim-label");
  gtk_widget_add_css_class (tip, "caption");
  gtk_box_append (GTK_BOX (header), label);
  gtk_box_append (GTK_BOX (header), tip);
  gtk_box_append (GTK_BOX (box), header);
  gtk_widget_set_margin_top (box, 6);
  gtk_box_append (GTK_BOX (page), box);
  return box;
}
