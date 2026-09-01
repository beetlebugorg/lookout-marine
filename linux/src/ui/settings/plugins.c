/* ui/settings/plugins.c — the controls a plugin declared.
 *
 * A plugin's manifest names its settings: a number with a unit and a range, a
 * toggle, a text box, and a list the mariner adds rows to. This builds those
 * controls, and puts each one in whatever section the plugin filed it under —
 * so a plugin can add a control to a page the app already has, not only to one
 * the plugins brought into existence.
 */
#include "ui/settings/plugins.h"
#include "ui/settings/widgets.h"

#include <string.h>

/* ---- the plugins' own controls ------------------------------------------- */
/*
 * A plugin declares a settings schema in its manifest and the core hands the
 * whole registry over as JSON; plugins/registry.c turns that into groups, lists and
 * rows, and this draws them with the same builders the app's own settings use.
 * The mariner is never told which of these came from a plugin: an AIS alarm is
 * a chart setting that happens to be served by one.
 */

/* One control's sentence, under the control it explains. */
static void
lk_plugin_desc (GtkWidget *section, const char *desc)
{
  if (desc == NULL || desc[0] == '\0')
    return;

  GtkWidget *label = lk_footer (section, desc);

  /* Tucked under the row above rather than floating between two of them. */
  gtk_widget_set_margin_top (label, -2);
}

typedef struct {
  LkSettings *settings;
  char       *plugin_id;
  char       *key;
} LkPluginBinding;

static void
lk_plugin_binding_free (gpointer data, GClosure *closure)
{
  LkPluginBinding *binding = data;

  g_free (binding->plugin_id);
  g_free (binding->key);
  g_free (binding);
}

static LkPluginBinding *
lk_plugin_binding_new (LkSettings *settings, const char *plugin_id, const char *key)
{
  LkPluginBinding *binding = g_new0 (LkPluginBinding, 1);

  binding->settings = settings;
  /* Copied: every borrowed string in the schema dies with the registry, and a
   * widget outlives a reload. */
  binding->plugin_id = g_strdup (plugin_id);
  binding->key = g_strdup (key);
  return binding;
}

static void
lk_plugin_toggle_changed (GtkCheckButton *button, gpointer user_data)
{
  LkPluginBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_value (binding->settings->plugins, binding->plugin_id, binding->key,
                        gtk_check_button_get_active (button) ? 1 : 0);
}

static void
lk_plugin_number_changed (GtkSpinButton *spin, gpointer user_data)
{
  LkPluginBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_value (binding->settings->plugins, binding->plugin_id, binding->key,
                        gtk_spin_button_get_value (spin));
}

/* A spin button over the range a manifest declared.
 *
 * The step suits the range it covers — metres of CPA move in tens, minutes and
 * knots one at a time — and the digits follow the step, so a whole-number range
 * shows no ".0". A plugin's own control and a cell in one of its lists are both
 * built from this. */
static GtkWidget *
lk_plugin_spin_new (const LkPluginField *field)
{
  double span = field->max - field->min;
  double step = span > 100 ? 10 : (span > 10 ? 1 : 0.5);
  GtkWidget *spin = gtk_spin_button_new_with_range (field->min, field->max, step);

  gtk_spin_button_set_digits (GTK_SPIN_BUTTON (spin), step < 1 ? 1 : 0);
  return spin;
}

/* Returns the control, which is what "Reset to defaults" has to put back. */
static GtkWidget *
lk_plugin_scalar_row (GtkWidget           *section,
                      LkSettings          *settings,
                      const char          *plugin_id,
                      const LkPluginField *field)
{
  double value = lk_plugins_value (settings->plugins, plugin_id, field->key);

  if (field->kind == LOOKOUT_PLUGIN_SETTING_TOGGLE)
    {
      GtkWidget *check = gtk_check_button_new ();

      gtk_check_button_set_active (GTK_CHECK_BUTTON (check), value != 0);
      gtk_widget_set_valign (check, GTK_ALIGN_CENTER);
      g_signal_connect_data (check, "toggled", G_CALLBACK (lk_plugin_toggle_changed),
                             lk_plugin_binding_new (settings, plugin_id, field->key),
                             lk_plugin_binding_free, 0);
      lk_row (section, field->label, check);
      lk_plugin_desc (section, field->desc);
      return check;
    }

  /* A number. The unit rides on the control rather than in the label, which is
   * where the range the manifest set is legible beside what it means. */
  GtkWidget *spin = lk_plugin_spin_new (field);

  gtk_spin_button_set_value (GTK_SPIN_BUTTON (spin), value);
  gtk_widget_set_valign (spin, GTK_ALIGN_CENTER);
  g_signal_connect_data (spin, "value-changed", G_CALLBACK (lk_plugin_number_changed),
                         lk_plugin_binding_new (settings, plugin_id, field->key),
                         lk_plugin_binding_free, 0);

  if (field->unit[0] == '\0')
    {
      lk_row (section, field->label, spin);
    }
  else
    {
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
      GtkWidget *unit = gtk_label_new (field->unit);

      gtk_widget_add_css_class (unit, "dim-label");
      gtk_widget_set_valign (unit, GTK_ALIGN_CENTER);
      gtk_box_append (GTK_BOX (box), spin);
      gtk_box_append (GTK_BOX (box), unit);
      lk_row (section, field->label, box);
    }
  lk_plugin_desc (section, field->desc);
  return spin;
}

static void
lk_plugin_reset_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const LkPluginGroup *group = g_object_get_data (G_OBJECT (button), "lk-group");

  lk_plugins_reset_group (settings->plugins, group);

  /* The controls hold the old numbers. Reprogramming them must not read back
   * as the mariner moving each one. */
  settings->updating = TRUE;
  for (guint i = 0; i < group->fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (group->fields, i);
      g_autofree char *data_key = g_strdup_printf ("lk-field-%s", field->key);
      GtkWidget *widget = g_object_get_data (G_OBJECT (button), data_key);

      if (widget == NULL)
        continue;
      if (field->kind == LOOKOUT_PLUGIN_SETTING_TOGGLE)
        gtk_check_button_set_active (GTK_CHECK_BUTTON (widget), field->fallback != 0);
      else
        gtk_spin_button_set_value (GTK_SPIN_BUTTON (widget), field->fallback);
    }
  settings->updating = FALSE;
}

/* ---- the rows of a list -------------------------------------------------- */

typedef struct {
  LkSettings         *settings;
  const LkPluginList *list;
  char               *row_id;
  char               *key;
} LkPluginRowBinding;

static void
lk_plugin_row_binding_free (gpointer data, GClosure *closure)
{
  LkPluginRowBinding *binding = data;

  g_free (binding->row_id);
  g_free (binding->key);
  g_free (binding);
}

static LkPluginRowBinding *
lk_plugin_row_binding_new (LkSettings         *settings,
                           const LkPluginList *list,
                           const char         *row_id,
                           const char         *key)
{
  LkPluginRowBinding *binding = g_new0 (LkPluginRowBinding, 1);

  binding->settings = settings;
  binding->list = list;
  binding->row_id = g_strdup (row_id);
  binding->key = g_strdup (key);
  return binding;
}

static void lk_plugin_schedule_refill (LkSettings *settings, const LkPluginList *list);

static void
lk_plugin_cell_text_changed (GtkEditable *editable, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_row_text (binding->settings->plugins, binding->list, binding->row_id,
                           binding->key, gtk_editable_get_text (editable));
}

/* GDestroyNotify shape for the binding, for when it rides on the widget
   rather than a signal closure. */
static void
lk_plugin_row_binding_destroy (gpointer data)
{
  lk_plugin_row_binding_free (data, NULL);
}

/* Commits on Enter or focus loss, never per keystroke: an address pushed
   letter-by-letter dials "1", "10", "10.0"… and the plugin churns through
   partial hosts while the mariner is mid-word (the Mac shell's
   CommitTextField rule). */
static void
lk_plugin_cell_text_commit (GtkEntry *entry, gpointer user_data)
{
  (void) user_data;
  gpointer binding = g_object_get_data (G_OBJECT (entry), "lk-cell-binding");

  if (binding != NULL)
    lk_plugin_cell_text_changed (GTK_EDITABLE (entry), binding);
}

static void
lk_plugin_cell_focus_left (GtkEventControllerFocus *focus, gpointer user_data)
{
  (void) user_data;
  GtkWidget *entry = gtk_event_controller_get_widget (GTK_EVENT_CONTROLLER (focus));

  lk_plugin_cell_text_commit (GTK_ENTRY (entry), NULL);
}

static void
lk_plugin_cell_number_changed (GtkSpinButton *spin, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_row_number (binding->settings->plugins, binding->list, binding->row_id,
                             binding->key, gtk_spin_button_get_value (spin));
}

static void
lk_plugin_cell_toggle_changed (GtkSwitch *widget, GParamSpec *pspec, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  if (binding->settings->updating)
    return;
  lk_plugins_set_row_toggle (binding->settings->plugins, binding->list, binding->row_id,
                             binding->key, gtk_switch_get_active (widget));
}

static void
lk_plugin_row_remove_clicked (GtkButton *button, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  lk_plugins_remove_row (binding->settings->plugins, binding->list, binding->row_id);
  lk_plugin_schedule_refill (binding->settings, binding->list);
}

static void
lk_plugin_row_add_clicked (GtkButton *button, gpointer user_data)
{
  LkPluginRowBinding *binding = user_data;

  lk_plugins_add_row (binding->settings->plugins, binding->list);
  lk_plugin_schedule_refill (binding->settings, binding->list);
}

/* What the mariner named this row, or the address it dials. */
static char *
lk_plugin_row_title (LkSettings *settings, const LkPluginList *list, const char *row_id)
{
  const char *name = lk_plugins_row_text (settings->plugins, list, row_id, "name");

  if (name[0] != '\0')
    return g_strdup (name);

  const char *host = lk_plugins_row_text (settings->plugins, list, row_id, "host");
  if (host[0] == '\0')
    return g_strdup ("New connection");

  return g_strdup_printf ("%s:%d", host,
                          (int) lk_plugins_row_number (settings->plugins, list, row_id, "port"));
}

/* The label that carries a row's live state, remembered so the poll can move it
 * without rebuilding the row under a mariner who is typing in it. */
static GtkWidget *
lk_plugin_status_label (LkSettings *settings, const LkPluginList *list, const char *row_id)
{
  GtkWidget *label = gtk_label_new (NULL);

  gtk_widget_add_css_class (label, "caption");
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  g_object_set_data (G_OBJECT (label), "lk-list", (gpointer) list);
  g_object_set_data_full (G_OBJECT (label), "lk-row-id", g_strdup (row_id), g_free);
  g_ptr_array_add (settings->status_labels, label);
  return label;
}

/* Put one status line on one label: the words, and the colour it reads in. */
static void
lk_plugin_apply_status (GtkWidget *label, char *line, const char *css_class)
{
  const char *previous = g_object_get_data (G_OBJECT (label), "lk-status-class");

  if (previous != NULL)
    gtk_widget_remove_css_class (label, previous);

  if (line == NULL)
    {
      /* The plugin has not spoken for this row yet. An empty line is honest;
       * an invented one would say "connected" about a socket nobody opened. */
      gtk_label_set_text (GTK_LABEL (label), "");
      gtk_widget_add_css_class (label, "dim-label");
      g_object_set_data (G_OBJECT (label), "lk-status-class", (gpointer) "dim-label");
      return;
    }

  gtk_label_set_text (GTK_LABEL (label), line);
  g_free (line);
  gtk_widget_add_css_class (label, css_class);
  g_object_set_data (G_OBJECT (label), "lk-status-class", (gpointer) css_class);
}

void
lk_plugin_refresh_status_labels (LkSettings *settings)
{
  for (guint i = 0; i < settings->status_labels->len; i++)
    {
      GtkWidget *label = g_ptr_array_index (settings->status_labels, i);
      const LkPluginList *list = g_object_get_data (G_OBJECT (label), "lk-list");
      const char *css_class = "dim-label";
      char *line;

      if (list != NULL)
        {
          const char *row_id = g_object_get_data (G_OBJECT (label), "lk-row-id");

          line = lk_plugins_row_status (settings->plugins, list, row_id, &css_class);
        }
      else
        {
          const char *plugin_id = g_object_get_data (G_OBJECT (label), "lk-plugin-id");

          line = lk_plugins_status_line (settings->plugins, plugin_id, &css_class);
        }
      lk_plugin_apply_status (label, line, css_class);
    }
}

/* A connection's line has to move on its own: "Reconnecting" that never becomes
 * "Connected" is how a mariner learns the address is wrong. */
gboolean
lk_plugin_status_poll (gpointer user_data)
{
  LkSettings *settings = user_data;

  if (lk_plugins_refresh_status (settings->plugins))
    lk_plugin_refresh_status_labels (settings);
  return G_SOURCE_CONTINUE;
}

/* One row: what it is called and what it is doing, a switch that pauses it, and
 * — folded away until it is wanted — the address behind it. The mariner reads
 * the first line and touches nothing else most days. */
static void
lk_plugin_fill_row (LkSettings *settings, GtkWidget *box,
                    const LkPluginList *list, const char *row_id)
{
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *expander = gtk_expander_new (NULL);
  GtkWidget *summary = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  g_autofree char *title = lk_plugin_row_title (settings, list, row_id);
  GtkWidget *name = gtk_label_new (title);
  GtkWidget *status = lk_plugin_status_label (settings, list, row_id);

  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_widget_add_css_class (name, "heading");
  gtk_box_append (GTK_BOX (summary), name);
  gtk_box_append (GTK_BOX (summary), status);

  gtk_expander_set_label_widget (GTK_EXPANDER (expander), summary);
  /* A row with no address cannot work yet, so it opens itself: the mariner has
   * to type one, and hunting for a disclosure triangle to find that out is not
   * a task. */
  gtk_expander_set_expanded (GTK_EXPANDER (expander),
                             lk_plugins_row_text (settings->plugins, list, row_id, "host")[0] == '\0');
  gtk_widget_set_hexpand (expander, TRUE);
  gtk_box_append (GTK_BOX (header), expander);

  /* The row's own on/off switch stands OUTSIDE the expander, on the line where
   * it is read at a glance: pausing a connection must not need it opened. */
  if (list->switch_key[0] != '\0')
    {
      GtkWidget *toggle = gtk_switch_new ();

      gtk_switch_set_active (GTK_SWITCH (toggle),
                             lk_plugins_row_toggle (settings->plugins, list, row_id,
                                                    list->switch_key));
      gtk_widget_set_valign (toggle, GTK_ALIGN_CENTER);
      g_signal_connect_data (toggle, "notify::active",
                             G_CALLBACK (lk_plugin_cell_toggle_changed),
                             lk_plugin_row_binding_new (settings, list, row_id, list->switch_key),
                             lk_plugin_row_binding_free, 0);
      gtk_box_append (GTK_BOX (header), toggle);
    }

  gtk_widget_set_margin_top (header, 6);
  gtk_box_append (GTK_BOX (box), header);

  GtkWidget *fields = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  gtk_widget_set_margin_start (fields, 22);
  gtk_widget_set_margin_top (fields, 6);
  gtk_expander_set_child (GTK_EXPANDER (expander), fields);

  for (guint i = 0; i < list->item_fields->len; i++)
    {
      const LkPluginField *field = g_ptr_array_index (list->item_fields, i);

      /* Every column but the one already drawn on the row's line. */
      if (g_strcmp0 (field->key, list->switch_key) == 0)
        continue;

      GtkWidget *control = NULL;

      switch (field->kind)
        {
        case LOOKOUT_PLUGIN_SETTING_TEXT:
          control = gtk_entry_new ();
          gtk_editable_set_text (GTK_EDITABLE (control),
                                 lk_plugins_row_text (settings->plugins, list, row_id, field->key));
          if (field->placeholder[0] != '\0')
            gtk_entry_set_placeholder_text (GTK_ENTRY (control), field->placeholder);
          else if (field->optional)
            gtk_entry_set_placeholder_text (GTK_ENTRY (control), "Optional");
          g_object_set_data_full (G_OBJECT (control), "lk-cell-binding",
                                  lk_plugin_row_binding_new (settings, list, row_id, field->key),
                                  lk_plugin_row_binding_destroy);
          g_signal_connect (control, "activate",
                            G_CALLBACK (lk_plugin_cell_text_commit), NULL);
          {
            GtkEventController *cell_focus = gtk_event_controller_focus_new ();
            g_signal_connect (cell_focus, "leave",
                              G_CALLBACK (lk_plugin_cell_focus_left), NULL);
            gtk_widget_add_controller (control, cell_focus);
          }
          break;

        case LOOKOUT_PLUGIN_SETTING_NUMBER:
          {
            control = lk_plugin_spin_new (field);
            gtk_spin_button_set_value (GTK_SPIN_BUTTON (control),
                                       lk_plugins_row_number (settings->plugins, list,
                                                              row_id, field->key));
            g_signal_connect_data (control, "value-changed",
                                   G_CALLBACK (lk_plugin_cell_number_changed),
                                   lk_plugin_row_binding_new (settings, list, row_id, field->key),
                                   lk_plugin_row_binding_free, 0);
          }
          break;

        case LOOKOUT_PLUGIN_SETTING_TOGGLE:
        default:
          control = gtk_switch_new ();
          gtk_switch_set_active (GTK_SWITCH (control),
                                 lk_plugins_row_toggle (settings->plugins, list,
                                                        row_id, field->key));
          g_signal_connect_data (control, "notify::active",
                                 G_CALLBACK (lk_plugin_cell_toggle_changed),
                                 lk_plugin_row_binding_new (settings, list, row_id, field->key),
                                 lk_plugin_row_binding_free, 0);
          break;
        }

      gtk_widget_set_valign (control, GTK_ALIGN_CENTER);
      lk_row (fields, field->label, control);
      lk_plugin_desc (fields, field->desc);
    }

  GtkWidget *remove = gtk_button_new_with_label ("Remove");
  gtk_widget_add_css_class (remove, "destructive-action");
  gtk_widget_set_halign (remove, GTK_ALIGN_START);
  g_signal_connect_data (remove, "clicked", G_CALLBACK (lk_plugin_row_remove_clicked),
                         lk_plugin_row_binding_new (settings, list, row_id, ""),
                         lk_plugin_row_binding_free, 0);
  gtk_box_append (GTK_BOX (fields), remove);
}

/* Drop the status labels of one list, so a refill does not leave the poll
 * writing into widgets that are no longer on the screen. */
static void
lk_plugin_forget_status_labels (LkSettings *settings, const LkPluginList *list)
{
  for (guint i = settings->status_labels->len; i > 0; i--)
    {
      GtkWidget *label = g_ptr_array_index (settings->status_labels, i - 1);

      if (g_object_get_data (G_OBJECT (label), "lk-list") == list)
        g_ptr_array_remove_index (settings->status_labels, i - 1);
    }
}

/* One find, and the list it would be added to. */
typedef struct {
  LkSettings         *settings;
  const LkPluginList *list;
  char               *service;
  char               *name;
  char               *host;
  int                 port;
} LkNearbyBinding;

static void
lk_nearby_binding_free (gpointer data, GClosure *closure)
{
  LkNearbyBinding *binding = data;

  g_free (binding->service);
  g_free (binding->name);
  g_free (binding->host);
  g_free (binding);
}

static void
lk_plugin_nearby_add_clicked (GtkButton *button, gpointer user_data)
{
  LkNearbyBinding *binding = user_data;

  lk_plugins_add_row_from (binding->settings->plugins, binding->list, binding->service,
                           binding->name, binding->host, binding->port);
  lk_plugin_schedule_refill (binding->settings, binding->list);
}

/* Is this find already in the list?
 *
 * A HOST the list points at is not offered again, whatever port the row uses.
 * One machine announces the port it wants to be reached on and is often
 * reachable on another — a Signal K server announces its websocket on 3000 and
 * carries the same boat on 8375 — so a second row to it would send everything
 * twice. */
static gboolean
lk_plugin_holds_host (LkSettings *settings, const LkPluginList *list, const char *host)
{
  g_autoptr (GPtrArray) rows = lk_plugins_rows (settings->plugins, list);

  for (guint i = 0; i < rows->len; i++)
    {
      const char *row_id = g_ptr_array_index (rows, i);
      const char *held = lk_plugins_row_text (settings->plugins, list, row_id, "host");

      if (g_ascii_strcasecmp (held, host) == 0)
        return TRUE;
    }
  return FALSE;
}

/* What is answering on the network for this list's service types, offered ready
 * to add. Nothing found draws nothing: at a desk that is the ordinary case, and
 * an empty heading is a question nobody asked. */
static void
lk_plugin_fill_nearby (LkSettings *settings, const LkPluginList *list, GtkWidget *box)
{
  if (settings->discovery == NULL || list->discover->len == 0
      || lk_plugins_list_is_full (settings->plugins, list))
    return;

  const GPtrArray *found = lk_discovery_found (settings->discovery);

  for (guint i = 0; i < found->len; i++)
    {
      const LkDiscovered *service = g_ptr_array_index (found, i);
      gboolean wanted = FALSE;

      for (guint d = 0; d < list->discover->len; d++)
        {
          const LkPluginDiscover *want = g_ptr_array_index (list->discover, d);

          if (g_strcmp0 (want->service, service->service) == 0)
            {
              wanted = TRUE;
              break;
            }
        }
      if (!wanted || lk_plugin_holds_host (settings, list, service->host))
        continue;

      GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
      GtkWidget *text = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
      GtkWidget *name = gtk_label_new (service->name);
      g_autofree char *where = g_strdup_printf ("%s:%d", service->host, service->port);
      GtkWidget *address = gtk_label_new (where);
      GtkWidget *add = gtk_button_new_from_icon_name ("list-add-symbolic");
      LkNearbyBinding *binding = g_new0 (LkNearbyBinding, 1);

      gtk_label_set_xalign (GTK_LABEL (name), 0.0);
      gtk_label_set_xalign (GTK_LABEL (address), 0.0);
      gtk_widget_add_css_class (address, "dim-label");
      gtk_box_append (GTK_BOX (text), name);
      gtk_box_append (GTK_BOX (text), address);
      gtk_widget_set_hexpand (text, TRUE);
      gtk_box_append (GTK_BOX (line), text);

      binding->settings = settings;
      binding->list = list;
      binding->service = g_strdup (service->service);
      binding->name = g_strdup (service->name);
      binding->host = g_strdup (service->host);
      binding->port = service->port;

      gtk_widget_set_tooltip_text (add, "Add this source");
      gtk_widget_set_valign (add, GTK_ALIGN_CENTER);
      g_signal_connect_data (add, "clicked", G_CALLBACK (lk_plugin_nearby_add_clicked), binding,
                             lk_nearby_binding_free, 0);
      gtk_box_append (GTK_BOX (line), add);
      gtk_box_append (GTK_BOX (box), line);
    }
}

static void
lk_plugin_fill_rows (LkSettings *settings, const LkPluginList *list, GtkWidget *box)
{
  GtkWidget *child;

  lk_plugin_forget_status_labels (settings, list);
  while ((child = gtk_widget_get_first_child (box)) != NULL)
    gtk_box_remove (GTK_BOX (box), child);

  g_autoptr (GPtrArray) rows = lk_plugins_rows (settings->plugins, list);

  if (rows->len == 0)
    {
      GtkWidget *empty = gtk_label_new (list->empty);

      gtk_widget_add_css_class (empty, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (empty), 0.0);
      gtk_box_append (GTK_BOX (box), empty);
    }

  for (guint i = 0; i < rows->len; i++)
    lk_plugin_fill_row (settings, box, list, g_ptr_array_index (rows, i));

  lk_plugin_fill_nearby (settings, list, box);

  GtkWidget *add = gtk_button_new_with_label (list->add_label);
  gboolean full = lk_plugins_list_is_full (settings->plugins, list);

  gtk_widget_set_halign (add, GTK_ALIGN_START);
  gtk_widget_set_margin_top (add, 8);
  /* AT THE CAP THERE IS NOTHING TO ADD: the core keeps max_rows and drops the
   * rest, so a mariner who typed a ninth gateway address would be left with a
   * row that looks like the other eight and never connects. */
  gtk_widget_set_sensitive (add, !full);
  g_signal_connect_data (add, "clicked", G_CALLBACK (lk_plugin_row_add_clicked),
                         lk_plugin_row_binding_new (settings, list, "", ""),
                         lk_plugin_row_binding_free, 0);
  gtk_box_append (GTK_BOX (box), add);

  if (full)
    {
      g_autofree char *note = g_strdup_printf ("%d is the most this list holds. "
                                               "Remove one to add another.",
                                               list->max_rows);
      lk_footer (box, note);
    }

  lk_plugin_refresh_status_labels (settings);
}

/* A button in a list changes the model, which brings us straight back here.
 * Rebuilding now would free the button that is still emitting, so the refill
 * waits for the next idle. */
static gboolean
lk_plugin_refill_lists (gpointer user_data)
{
  LkSettings *settings = user_data;

  settings->list_refill_id = 0;
  for (guint i = 0; i < settings->pending_lists->len; i++)
    {
      const LkPluginList *list = g_ptr_array_index (settings->pending_lists, i);
      g_autofree char *key = g_strdup_printf ("%s/%s", list->plugin_id, list->key);
      GtkWidget *box = g_hash_table_lookup (settings->list_boxes, key);

      if (box != NULL)
        lk_plugin_fill_rows (settings, list, box);
    }
  g_ptr_array_set_size (settings->pending_lists, 0);
  return G_SOURCE_REMOVE;
}

static void
lk_plugin_schedule_refill (LkSettings *settings, const LkPluginList *list)
{
  if (!g_ptr_array_find (settings->pending_lists, list, NULL))
    g_ptr_array_add (settings->pending_lists, (gpointer) list);

  if (settings->list_refill_id == 0)
    settings->list_refill_id = g_idle_add (lk_plugin_refill_lists, settings);
}

/* ---- what a plugin put in one settings section --------------------------- */

/* Append the groups and lists a plugin filed under `tab`. Draws nothing when it
 * filed none, which is what keeps a section the app owns looking untouched. */
void
lk_plugin_fill_tab (GtkWidget *page, LkSettings *settings, const char *tab)
{
  if (settings->plugins == NULL)
    return;

  g_autoptr (GPtrArray) groups = lk_plugins_groups (settings->plugins, tab);

  for (guint i = 0; i < groups->len; i++)
    {
      const LkPluginGroup *group = g_ptr_array_index (groups, i);
      GtkWidget *section = lk_section (page, group->title);
      GtkWidget *reset = gtk_button_new_with_label ("Reset to defaults");

      for (guint f = 0; f < group->fields->len; f++)
        {
          const LkPluginField *field = g_ptr_array_index (group->fields, f);
          GtkWidget *control = lk_plugin_scalar_row (section, settings,
                                                     group->plugin_id, field);

          /* The reset has to put each control back where the manifest had it,
           * so it carries them, keyed by the field they belong to. The key is
           * prefixed: a manifest field named "lk-group" would otherwise land on
           * the shell's own data key and hand Reset a widget where it reads a
           * group. */
          g_autofree char *data_key = g_strdup_printf ("lk-field-%s", field->key);
          g_object_set_data (G_OBJECT (reset), data_key, control);
        }

      gtk_widget_set_halign (reset, GTK_ALIGN_START);
      gtk_widget_set_margin_top (reset, 4);
      g_object_set_data (G_OBJECT (reset), "lk-group", (gpointer) group);
      g_signal_connect (reset, "clicked", G_CALLBACK (lk_plugin_reset_clicked), settings);
      gtk_box_append (GTK_BOX (section), reset);
    }

  g_autoptr (GPtrArray) lists = lk_plugins_lists (settings->plugins, tab);

  for (guint i = 0; i < lists->len; i++)
    {
      const LkPluginList *list = g_ptr_array_index (lists, i);
      GtkWidget *section = lk_section (page, list->title);
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);

      gtk_box_append (GTK_BOX (section), box);
      g_hash_table_insert (settings->list_boxes,
                           g_strdup_printf ("%s/%s", list->plugin_id, list->key), box);
      if (list->discover->len > 0)
        g_ptr_array_add (settings->discover_lists, (gpointer) list);
      lk_plugin_fill_rows (settings, list, box);

      /* The plugin's own sentence, never the window's. Connections holds two
       * lists — NMEA gateways and Signal K servers — and a line about WiFi
       * gateways under a list of Signal K servers sends the mariner to the
       * wrong port. */
      if (list->footer[0] != '\0')
        lk_footer (section, list->footer);
    }
}

/* What was found moved, so every list that browses shows it again. */
static void
lk_settings_discovery_changed (gpointer user_data)
{
  LkSettings *settings = user_data;

  for (guint i = 0; i < settings->discover_lists->len; i++)
    lk_plugin_schedule_refill (settings, g_ptr_array_index (settings->discover_lists, i));
}

/* Browse for what the loaded lists declare, and for nothing else. A window with
 * no list that browses starts nothing at all. */
void
lk_settings_start_discovery (LkSettings *settings)
{
  if (settings->discover_lists->len == 0)
    return;

  g_autoptr (GPtrArray) services = g_ptr_array_new ();

  for (guint i = 0; i < settings->discover_lists->len; i++)
    {
      const LkPluginList *list = g_ptr_array_index (settings->discover_lists, i);

      for (guint d = 0; d < list->discover->len; d++)
        {
          const LkPluginDiscover *want = g_ptr_array_index (list->discover, d);

          g_ptr_array_add (services, (gpointer) want->service);
        }
    }

  settings->discovery = lk_discovery_new (lk_settings_discovery_changed, settings);
  lk_discovery_browse (settings->discovery, services);
}
