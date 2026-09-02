/* ui/settings/window.c — the settings window itself.
 *
 * The lifecycle, the sidebar that chooses a pane, and the two pages small
 * enough to live here. Every other page is a unit beside this one: it builds
 * itself into the stack and the sidebar, and this file calls it.
 */
#include "ui/settings/window.h"
#include "ui/settings/private.h"

#include "ui/settings/charts.h"
#include "ui/settings/depths.h"
#include "ui/settings/display.h"
#include "ui/settings/plugins.h"
#include "ui/settings/plugins-page.h"
#include "ui/settings/widgets.h"

#include "ui/chrome/licenses.h"

#include <gdk/gdkkeysyms.h>

static void
lk_settings_free (gpointer data)
{
  LkSettings *settings = data;

  lk_deferred_list_clear (&settings->raster);
  lk_deferred_list_clear (&settings->links);
  lk_deferred_list_clear (&settings->sets);
  g_clear_handle_id (&settings->status_poll_id, g_source_remove);
  g_clear_handle_id (&settings->list_refill_id, g_source_remove);
  g_clear_pointer (&settings->discovery, lk_discovery_free);
  g_clear_pointer (&settings->discover_lists, g_ptr_array_unref);
  g_clear_pointer (&settings->status_labels, g_ptr_array_unref);
  g_clear_pointer (&settings->pending_lists, g_ptr_array_unref);
  g_clear_pointer (&settings->list_boxes, g_hash_table_unref);
  g_clear_pointer (&settings->plugins, lk_plugins_free);
  g_clear_object (&settings->mariner);
  g_free (settings);
}

gboolean
lk_settings_feet (LkSettings *settings)
{
  return lk_mariner_raw (settings->mariner)->depth_unit == TILE57_DEPTH_FEET;
}

static void
lk_apply_boundary (LkSettings *settings, int value)
{
  lk_mariner_raw (settings->mariner)->boundary_style = (tile57_boundary_style) value;
}

/* ---- the two small pages ------------------------------------------------- */
/*
 * Text and Advanced are a handful of rows each, so they stay here rather than
 * each taking a unit of its own. Every other page is its own file beside this
 * one, and this file constructs the window and connects it.
 */

static void
lk_build_text_page (LkSettings *settings)
{
  static const char *boundaries[] = { "Symbolized", "Plain", NULL };

  GtkWidget *page = lk_page_new (settings, "text", "Text",
                                 "format-text-rich-symbolic");
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  GtkWidget *text = lk_section (page, "Text");
  lk_switch_row (text, settings, "Feature names", &m->text_names);
  lk_switch_row (text, settings, "Light descriptions", &m->show_light_descriptions);
  lk_switch_row (text, settings, "Other text", &m->text_other);

  GtkWidget *symbols = lk_section (page, "Symbols");
  lk_switch_row (symbols, settings, "Simplified point symbols", &m->simplified_points);
  lk_choice_row (symbols, settings, "Boundaries", boundaries,
                 (int) m->boundary_style, NULL, lk_apply_boundary);
  lk_switch_row (symbols, settings, "Full light-sector lines", &m->show_full_sector_lines);

  lk_plugin_fill_tab (page, settings, "text");
}

/* Commits on Enter or focus loss, never per keystroke — half a date is not a
   date the chart should redraw against. */
static void
lk_date_commit (GtkEntry *entry, gpointer user_data)
{
  LkSettings *settings = user_data;
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  if (settings->updating)
    return;

  memset (m->date_view, 0, sizeof m->date_view);
  g_strlcpy (m->date_view, gtk_editable_get_text (GTK_EDITABLE (entry)), sizeof m->date_view);
  lk_mariner_touch (settings->mariner);
}

static void
lk_date_focus_left (GtkEventControllerFocus *focus, gpointer user_data)
{
  GtkWidget *entry = gtk_event_controller_get_widget (GTK_EVENT_CONTROLLER (focus));
  lk_date_commit (GTK_ENTRY (entry), user_data);
}

static void
lk_settings_licenses_clicked (GtkButton *button, gpointer user_data)
{
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
  GtkWindow *window = GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL;

  /* The MAIN window is the parent, not this panel: the licenses stay open when
   * the settings are closed. */
  lk_licenses_window_present (window != NULL ? gtk_window_get_transient_for (window) : NULL,
                              NULL);
}

/* What this build is: its version, the chart engine it is pinned to, and the
 * way to the terms it and its components carry. It stands at the foot of the
 * last page, as it does on the Mac (macos/LookoutMarine/SettingsView.swift). */
static void
lk_settings_about_section (GtkWidget *page)
{
  const GPtrArray *components = lk_licenses_components ();
  const lookout_license *engine = lk_licenses_component ("tile57");
  GtkWidget *about = lk_section (page, "About");
  GtkWidget *version = gtk_label_new (lk_licenses_app_version ());

  gtk_widget_add_css_class (version, "numeric");
  gtk_widget_add_css_class (version, "dim-label");
  gtk_label_set_selectable (GTK_LABEL (version), TRUE);
  lk_row (about, "Version", version);

  if (engine != NULL)
    {
      g_autofree char *pin = lk_licenses_pin (engine);
      g_autofree char *text = g_strdup_printf ("%s · %s", engine->name, pin);
      GtkWidget *label = gtk_label_new (text);

      gtk_widget_add_css_class (label, "monospace");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_label_set_selectable (GTK_LABEL (label), TRUE);
      lk_row (about, "Chart engine", label);
    }

  /* The ellipsis promises a window, which is where a license has the width to
   * be read whole. */
  GtkWidget *button = gtk_button_new_with_label ("Licenses…");

  gtk_widget_set_halign (button, GTK_ALIGN_START);
  gtk_widget_set_margin_top (button, 6);
  g_signal_connect (button, "clicked", G_CALLBACK (lk_settings_licenses_clicked), NULL);
  gtk_box_append (GTK_BOX (about), button);

  g_autofree char *footer =
      g_strdup_printf ("This app's terms, and the %u components it is built from. "
                       "Every license is carried whole and needs no connection.",
                       components->len);
  lk_footer (about, footer);
}

static void
lk_build_advanced_page (LkSettings *settings)
{
  GtkWidget *page = lk_page_new (settings, "advanced", "Advanced",
                                 "lk-advanced-symbolic");
  tile57_mariner *m = lk_mariner_raw (settings->mariner);

  GtkWidget *safety = lk_section (page, "Safety & Quality");
  lk_switch_row (safety, settings, "Data quality overlay", &m->data_quality);
  lk_switch_row (safety, settings, "Isolated dangers in shallow water", &m->show_isolated_dangers_shallow);
  lk_switch_row (safety, settings, "Information callouts", &m->show_inform_callouts);
  lk_switch_row (safety, settings, "Meta boundaries", &m->show_meta_bounds);
  lk_switch_row (safety, settings, "Overscale indication", &m->show_overscale);

  GtkWidget *sizing = lk_section (page, "Sizing");
  lk_size_row (sizing, settings, "Overall size", &m->size_scale);
  lk_size_row (sizing, settings, "Text size", &m->text_size_scale);
  lk_size_row (sizing, settings, "Sounding size", &m->sounding_size_scale);

  GtkWidget *dates = lk_section (page, "Dates");
  lk_switch_row (dates, settings, "Date-dependent features", &m->date_dependent);
  lk_switch_row (dates, settings, "Highlight date-dependent", &m->highlight_date_dependent);

  GtkWidget *entry = gtk_entry_new ();
  gtk_entry_set_placeholder_text (GTK_ENTRY (entry), "YYYYMMDD");
  gtk_entry_set_max_length (GTK_ENTRY (entry), 8);
  gtk_editable_set_text (GTK_EDITABLE (entry), m->date_view);
  gtk_widget_set_valign (entry, GTK_ALIGN_CENTER);
  g_signal_connect (entry, "activate", G_CALLBACK (lk_date_commit), settings);
  GtkEventController *date_focus = gtk_event_controller_focus_new ();
  g_signal_connect (date_focus, "leave", G_CALLBACK (lk_date_focus_left), settings);
  gtk_widget_add_controller (entry, date_focus);
  lk_row (dates, "View date", entry);
  lk_footer (dates, "Leave the date empty to use today.");

  lk_plugin_fill_tab (page, settings, "advanced");

  /* Last on the page, under whatever a plugin filed here: About says what this
   * build is, and nothing is filed under it. */
  lk_settings_about_section (page);
}

/* The window is going away. The data the window carries is freed at FINALIZE,
 * which is after its children are destroyed, so a poll or a refill that fired
 * in between would write into labels and boxes that are already gone. Both are
 * stopped here, at destroy, while everything is still standing. */
static void
lk_settings_window_destroyed (GtkWidget *window, gpointer user_data)
{
  LkSettings *settings = user_data;

  g_clear_handle_id (&settings->status_poll_id, g_source_remove);
  g_clear_handle_id (&settings->list_refill_id, g_source_remove);
  /* Every queued refill too: a toggle or an edit queues one, and a window
     destroyed before the idle runs would have it write into freed rows. */
  lk_deferred_list_clear (&settings->raster);
  lk_deferred_list_clear (&settings->links);
  lk_deferred_list_clear (&settings->sets);
  g_clear_pointer (&settings->discovery, lk_discovery_free);
  g_ptr_array_set_size (settings->discover_lists, 0);
  g_ptr_array_set_size (settings->status_labels, 0);
  g_ptr_array_set_size (settings->pending_lists, 0);
  g_hash_table_remove_all (settings->list_boxes);
}

/* ---- the sidebar and the window ------------------------------------------ */

/* The list IS the navigation, so a row always names a pane. */
static void
lk_settings_section_selected (GtkListBox *box, GtkListBoxRow *row, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *id = row == NULL ? NULL : g_object_get_data (G_OBJECT (row), "lk-section");

  if (id != NULL)
    gtk_stack_set_visible_child_name (GTK_STACK (settings->stack), id);
}

/* Open on one section by name. A name no section carries is ignored, because a
 * section can be absent: a plugin that never came up takes its section with
 * it, and a stale request must not leave the window on nothing. */
static void
lk_settings_select_section (LkSettings *settings, const char *id)
{
  GtkListBoxRow *first = gtk_list_box_get_row_at_index (GTK_LIST_BOX (settings->sidebar), 0);
  GtkListBoxRow *wanted = NULL;

  for (int i = 0; id != NULL && id[0] != '\0'; i++)
    {
      GtkListBoxRow *row = gtk_list_box_get_row_at_index (GTK_LIST_BOX (settings->sidebar), i);

      if (row == NULL)
        break;
      if (g_strcmp0 (g_object_get_data (G_OBJECT (row), "lk-section"), id) == 0)
        {
          wanted = row;
          break;
        }
    }

  if (wanted == NULL)
    wanted = first;
  if (wanted != NULL)
    gtk_list_box_select_row (GTK_LIST_BOX (settings->sidebar), wanted);
}

/* Esc closes it — a tiling compositor draws no titlebar X. */
static gboolean
lk_settings_key_pressed (GtkEventControllerKey *controller,
                         guint keyval, guint keycode,
                         GdkModifierType state, gpointer window)
{
  if (keyval == GDK_KEY_Escape)
    {
      gtk_window_close (GTK_WINDOW (window));
      return GDK_EVENT_STOP;
    }
  return GDK_EVENT_PROPAGATE;
}

GtkWidget *
lk_settings_window_new (LkAppModel *model, GtkWindow *parent, const char *tab)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkSettings *settings = g_new0 (LkSettings, 1);
  settings->model = model;
  settings->mariner = lk_mariner_new (lk_app_model_get_controller (model));

  /* The plugin schemas are read once, here: what a plugin declares does not
   * change while the window is open, and re-reading it would fight the
   * keyboard. Only the status lines are polled after this. */
  settings->plugins = lk_plugins_new (lk_app_model_get_controller (model));
  settings->status_labels = g_ptr_array_new ();
  settings->pending_lists = g_ptr_array_new ();
  settings->discover_lists = g_ptr_array_new ();
  settings->list_boxes = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);

  GtkWidget *window = gtk_window_new ();
  gtk_window_set_title (GTK_WINDOW (window), "Mariner Settings");
  /* Two columns need the room the Mac window takes: 720 by 560. */
  gtk_window_set_default_size (GTK_WINDOW (window), 760, 580);
  gtk_widget_set_size_request (window, 640, 480);
  gtk_window_set_transient_for (GTK_WINDOW (window), parent);
  gtk_window_set_destroy_with_parent (GTK_WINDOW (window), TRUE);
  /* A live panel, not a modal: the chart stays usable while it is open. */
  gtk_window_set_modal (GTK_WINDOW (window), FALSE);
  g_object_set_data_full (G_OBJECT (window), "lk-settings", settings, lk_settings_free);
  g_signal_connect (window, "destroy", G_CALLBACK (lk_settings_window_destroyed), settings);

  /* A real titlebar (close button + move handle) the compositor won't draw. */
  gtk_window_set_titlebar (GTK_WINDOW (window), gtk_header_bar_new ());

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (lk_settings_key_pressed), window);
  gtk_widget_add_controller (window, keys);

  /* The panel outlives none of its own edits, but a raster chart added from the
   * pill's list while the panel is open must appear in it. connect_object drops
   * the handler with the window. */
  g_signal_connect_object (model, "raster-changed",
                           G_CALLBACK (lk_settings_raster_changed), window, 0);
  /* Likewise a chart link resolving (or failing) while the panel is open. */
  g_signal_connect_object (lk_app_model_get_chart_links (model), "changed",
                           G_CALLBACK (lk_settings_links_changed), window, 0);
  /* And the library, whose titles fill in as the background scans land. */
  g_signal_connect_object (model, "chart-sets-changed",
                           G_CALLBACK (lk_settings_sets_changed), window, 0);

  /* A SIDEBAR OF SECTIONS beside the pane it chooses, as on the Mac. It is a
   * slot list, not a fixed menu: the four core sections, Plugins and Advanced
   * always exist, and the rest appear only while they hold something. */
  GtkWidget *split = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  GtkWidget *rail = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  settings->sidebar = gtk_list_box_new ();
  settings->stack = gtk_stack_new ();

  gtk_list_box_set_selection_mode (GTK_LIST_BOX (settings->sidebar), GTK_SELECTION_BROWSE);
  gtk_widget_add_css_class (settings->sidebar, "navigation-sidebar");
  gtk_widget_set_vexpand (settings->sidebar, TRUE);
  g_signal_connect (settings->sidebar, "row-selected",
                    G_CALLBACK (lk_settings_section_selected), settings);

  gtk_widget_set_hexpand (settings->stack, TRUE);
  gtk_stack_set_transition_type (GTK_STACK (settings->stack), GTK_STACK_TRANSITION_TYPE_NONE);

  /* The one thing the whole window promises. It stands under the list of
   * sections rather than repeating itself inside every one of them. */
  GtkWidget *promise = gtk_label_new ("Applies at once · kept for next launch");
  gtk_widget_add_css_class (promise, "dim-label");
  gtk_widget_add_css_class (promise, "caption");
  gtk_label_set_wrap (GTK_LABEL (promise), TRUE);
  gtk_label_set_xalign (GTK_LABEL (promise), 0.0);
  gtk_widget_set_margin_start (promise, 14);
  gtk_widget_set_margin_end (promise, 14);
  gtk_widget_set_margin_bottom (promise, 10);
  gtk_widget_set_margin_top (promise, 6);

  GtkWidget *rail_scroller = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (rail_scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (rail_scroller), settings->sidebar);
  gtk_widget_set_vexpand (rail_scroller, TRUE);

  gtk_box_append (GTK_BOX (rail), rail_scroller);
  gtk_box_append (GTK_BOX (rail), promise);
  gtk_widget_set_size_request (rail, 190, -1);
  gtk_widget_add_css_class (rail, "lk-settings-rail");

  gtk_box_append (GTK_BOX (split), rail);
  gtk_box_append (GTK_BOX (split), gtk_separator_new (GTK_ORIENTATION_VERTICAL));
  gtk_box_append (GTK_BOX (split), settings->stack);
  gtk_window_set_child (GTK_WINDOW (window), split);

  lk_build_display_page (settings);
  lk_build_depths_page (settings);
  lk_build_text_page (settings);
  lk_build_charts_page (settings);

  /* Vessels, Alarms and Connections exist only while something puts settings in
   * them, and today that something is a plugin. The section ids are the core's
   * (src/plugin/host.zig, `Tab`), so a plugin and this window mean the same
   * thing by "alarms". Advanced is last: it is where anything unclaimed lands. */
  static const struct { const char *tab, *title, *icon; } plugin_pages[] = {
    { "vessels", "Vessels", "lk-vessels-symbolic" },
    { "alarms", "Alarms", "lk-alarms-symbolic" },
    { "connections", "Connections", "network-wireless-symbolic" },
  };

  for (gsize i = 0; i < G_N_ELEMENTS (plugin_pages); i++)
    {
      if (!lk_plugins_tab_populated (settings->plugins, plugin_pages[i].tab))
        continue;
      lk_plugin_fill_tab (lk_page_new (settings, plugin_pages[i].tab, plugin_pages[i].title,
                                       plugin_pages[i].icon),
                          settings, plugin_pages[i].tab);
    }

  lk_build_plugins_page (settings);
  lk_build_advanced_page (settings);

  lk_settings_select_section (settings, tab);

  /* While the window is up, the connection lines move on their own — but only
     when a plugin shows a status line. With nothing to watch the poll would
     read the whole registry once a second to change nothing. A hot install
     rebuilds this window, so a plugin added later starts the poll then. */
  if (settings->status_labels->len > 0)
    settings->status_poll_id = g_timeout_add_seconds (1, lk_plugin_status_poll, settings);

  lk_settings_start_discovery (settings);

  return window;
}
