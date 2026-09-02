/* ui/settings/plugins-page.c — the Plugins page.
 *
 * What is loaded, what each one may reach, and how to add or remove one. The
 * controls a plugin declared are on the pages they were filed under; this page
 * is about the plugins themselves.
 */
#include "ui/settings/plugins-page.h"
#include "ui/settings/plugins.h"
#include "ui/settings/widgets.h"

#include "ui/settings/window.h"

#include "plugins/install.h"

/* Anything here changes WHICH plugins are loaded, so the whole window is built
 * again from a fresh registry. Doing it on an idle keeps the rebuild off the
 * signal that asked for it: a switch or a button is still emitting, and
 * destroying it inside its own handler is how a settings window crashes. */
static gboolean
lk_plugins_reopen_window (gpointer user_data)
{
  GtkWindow *window = user_data;
  LkSettings *settings = g_object_get_data (G_OBJECT (window), "lk-settings");
  GtkWindow *parent = gtk_window_get_transient_for (window);
  LkAppModel *model = settings->model;
  /* The mariner was on Plugins when they installed or removed one, so that is
   * where the rebuilt window opens. Copied out: the window dies below, and the
   * settings it carries die with it. */
  g_autofree char *section =
      g_strdup (gtk_stack_get_visible_child_name (GTK_STACK (settings->stack)));

  gtk_window_destroy (window);
  gtk_window_present (GTK_WINDOW (lk_settings_window_new (model, parent, section)));
  return G_SOURCE_REMOVE;
}

static void
lk_plugins_queue_reopen (GtkWidget *any_child)
{
  GtkRoot *root = gtk_widget_get_root (any_child);

  if (GTK_IS_WINDOW (root))
    g_idle_add (lk_plugins_reopen_window, root);
}

/* The install sheet's callback. It arrives with the model, and the settings
 * window it was raised from is the widget the closure carries. */
static void
lk_plugins_installed (gpointer model, gpointer user_data)
{
  lk_plugins_queue_reopen (user_data);
}

static void
lk_plugins_install_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

  lk_plugin_install_choose (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                            settings->model, lk_plugins_installed, GTK_WIDGET (button));
}

/* The dialog is async and outlives the button that raised it. It carries the
   window instead, held by a reference, so a settings window closed while the
   question stands cannot be freed under the answer: the settings struct hangs
   off the window and lives as long as it does. */
typedef struct {
  GtkWindow *window; /* reffed */
  char      *id;
} LkUninstallAsk;

static void
lk_uninstall_ask_free (LkUninstallAsk *ask)
{
  g_clear_object (&ask->window);
  g_free (ask->id);
  g_free (ask);
}

static void
lk_plugins_uninstall_answered (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkUninstallAsk *ask = user_data;
  g_autoptr (GError) error = NULL;
  int chosen = gtk_alert_dialog_choose_finish (GTK_ALERT_DIALOG (source), result, &error);

  /* Cancel is 0, Uninstall is 1. The window may have closed while the question
     stood; act only while it is still standing. */
  if (chosen == 1 && ask->window != NULL &&
      !gtk_widget_in_destruction (GTK_WIDGET (ask->window)))
    {
      LkSettings *settings = g_object_get_data (G_OBJECT (ask->window), "lk-settings");
      if (settings != NULL &&
          lk_chart_controller_plugin_uninstall (lk_app_model_get_controller (settings->model),
                                                ask->id))
        g_idle_add (lk_plugins_reopen_window, ask->window);
    }

  lk_uninstall_ask_free (ask);
}

/* Uninstall takes everything the plugin owns: its instance, the objects it
 * drew, the values it published and the settings it saved. That is not a thing
 * to do on one click, so it is asked about first. */
static void
lk_plugins_uninstall_clicked (GtkButton *button, gpointer user_data)
{
  LkSettings *settings = user_data;
  const char *id = g_object_get_data (G_OBJECT (button), "lk-plugin-id");
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
  g_autofree char *question = g_strdup_printf ("Uninstall %s?",
                                               lk_plugins_name (settings->plugins, id));
  static const char *answers[] = { "Cancel", "Uninstall", NULL };

  GtkAlertDialog *dialog = gtk_alert_dialog_new ("%s", question);
  const char *detail = "Removes the plugin and everything it drew.";
  gtk_alert_dialog_set_detail (dialog, detail);
  gtk_alert_dialog_set_buttons (dialog, answers);
  gtk_alert_dialog_set_cancel_button (dialog, 0);
  gtk_alert_dialog_set_default_button (dialog, 0);

  LkUninstallAsk *ask = g_new0 (LkUninstallAsk, 1);
  ask->window = GTK_IS_WINDOW (root) ? g_object_ref (GTK_WINDOW (root)) : NULL;
  ask->id = g_strdup (id);
  gtk_alert_dialog_choose (dialog, ask->window, NULL,
                           lk_plugins_uninstall_answered, ask);
  g_object_unref (dialog);
}

/* A grant goes off and on while the plugin runs. The core persists it beside
 * the plugin's wasm and reads it back at every load, so nothing is saved here.
 * A refusal puts the switch back rather than lying about the state. */
static void
lk_plugins_grant_toggled (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  LkSettings *settings = user_data;
  GtkSwitch *sw = GTK_SWITCH (object);
  const char *id = g_object_get_data (object, "lk-plugin-id");
  const char *cap = g_object_get_data (object, "lk-plugin-cap");

  if (settings->updating)
    return;

  if (lk_plugins_set_granted (settings->plugins, id, cap, gtk_switch_get_active (sw)))
    return;

  settings->updating = TRUE;
  gtk_switch_set_active (sw, !gtk_switch_get_active (sw));
  settings->updating = FALSE;
}

/* The one section that talks ABOUT plugins rather than about the chart: what
 * the mariner added, what it is doing, what it is allowed to do, and how to add
 * or remove one.
 *
 * ONLY WHAT THE MARINER PUT THERE IS LISTED: installed plugins, and the
 * developer copies LOOKOUT_PLUGINS brings. THE SHIPPED SET IS THE PRODUCT. Own
 * ship, AIS, NMEA 0183, Signal K and laylines are how the app works, not
 * choices somebody made, so they take no consent surface and never appear here.
 * Their settings are chart settings, filed under the sections they belong to. */
void
lk_build_plugins_page (LkSettings *settings)
{
  g_autoptr (GPtrArray) ids = lk_plugins_all (settings->plugins);
  GtkWidget *page = lk_page_new (settings, "plugins", "Plugins",
                                 "application-x-addon-symbolic");
  GtkWidget *section = lk_section (page, NULL);
  guint managed = 0;

  for (guint i = 0; i < ids->len; i++)
    {
      const char *id = g_ptr_array_index (ids, i);
      const char *version = lk_plugins_version (settings->plugins, id);
      const char *from = lk_plugins_origin (settings->plugins, id);

      if (g_strcmp0 (from, "bundled") == 0)
        continue;
      managed++;
      GtkWidget *summary = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
      GtkWidget *name = gtk_label_new (lk_plugins_name (settings->plugins, id));
      GtkWidget *status = gtk_label_new (NULL);
      /* One quiet line saying which copy this is: the version, where it came
       * from, and what it reads. The same line the macOS row prints. */
      g_autoptr (GString) about = g_string_new (NULL);
      if (version[0] != '\0')
        g_string_append_printf (about, "Version %s · ", version);
      g_string_append (about, g_strcmp0 (from, "developer") == 0
                                  ? "developer copy from LOOKOUT_PLUGINS"
                                  : "installed from a plugin file");
      g_autofree char *types = lk_plugins_file_types_for (settings->plugins, id);
      if (types != NULL)
        g_string_append_printf (about, " · reads %s files you open", types);
      about->str[0] = g_ascii_toupper (about->str[0]);
      GtkWidget *where = gtk_label_new (about->str);

      gtk_widget_add_css_class (name, "heading");
      gtk_label_set_xalign (GTK_LABEL (name), 0.0);
      gtk_widget_add_css_class (where, "dim-label");
      gtk_widget_add_css_class (where, "caption");
      gtk_label_set_wrap (GTK_LABEL (where), TRUE);
      gtk_label_set_xalign (GTK_LABEL (where), 0.0);
      gtk_widget_add_css_class (status, "caption");
      gtk_label_set_xalign (GTK_LABEL (status), 0.0);

      /* Keyed by plugin rather than by row, which is what tells the poll to ask
       * for the plugin's own line. */
      g_object_set_data_full (G_OBJECT (status), "lk-plugin-id", g_strdup (id), g_free);
      g_ptr_array_add (settings->status_labels, status);

      /* AT REST, ONE CALM ROW: the name and what it is doing, and nothing
       * else. Everything about MANAGING it stands behind the disclosure, so a
       * mariner reading down the list reads five plugins rather than thirty
       * switches. The provenance goes in there too: it answers "which copy is
       * this", which is a question somebody asks once. */
      GtkWidget *expander = gtk_expander_new (NULL);
      GtkWidget *body = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);

      gtk_box_append (GTK_BOX (summary), name);
      gtk_box_append (GTK_BOX (summary), status);
      gtk_expander_set_label_widget (GTK_EXPANDER (expander), summary);
      gtk_widget_set_margin_top (expander, 6);
      gtk_widget_set_margin_start (body, 6);
      gtk_widget_set_margin_top (body, 6);
      gtk_box_append (GTK_BOX (body), where);

      /* What the manifest asked for, one switch each, in the same sentences
       * the consent sheet used. A grant can never exceed the manifest, so this
       * list only ever takes something away. */
      GPtrArray *caps = lk_plugins_capabilities (settings->plugins, id);
      for (guint c = 0; caps != NULL && c < caps->len; c++)
        {
          const LkPluginCapability *cap = g_ptr_array_index (caps, c);
          GtkWidget *sw = gtk_switch_new ();
          g_autofree char *title =
              cap->hosts != NULL ? g_strdup_printf ("%s (%s)", cap->sentence, cap->hosts)
                                 : g_strdup (cap->sentence);

          gtk_widget_set_valign (sw, GTK_ALIGN_CENTER);
          gtk_switch_set_active (GTK_SWITCH (sw), cap->granted);
          g_object_set_data_full (G_OBJECT (sw), "lk-plugin-id", g_strdup (id), g_free);
          g_object_set_data_full (G_OBJECT (sw), "lk-plugin-cap", g_strdup (cap->name), g_free);
          g_signal_connect (sw, "notify::active", G_CALLBACK (lk_plugins_grant_toggled),
                            settings);
          lk_row (body, title, sw);
        }

      /* Uninstall acts only on what install wrote. A bundled copy belongs to
       * the application and a developer copy to LOOKOUT_PLUGINS, and the core
       * refuses both, so neither is offered. */
      if (lk_plugins_is_installed (settings->plugins, id))
        {
          GtkWidget *remove = gtk_button_new_with_label ("Uninstall…");

          gtk_widget_add_css_class (remove, "destructive-action");
          gtk_widget_set_halign (remove, GTK_ALIGN_START);
          gtk_widget_set_margin_top (remove, 4);
          g_object_set_data_full (G_OBJECT (remove), "lk-plugin-id", g_strdup (id), g_free);
          g_object_set_data (G_OBJECT (remove), "lk-settings", settings);
          g_signal_connect (remove, "clicked", G_CALLBACK (lk_plugins_uninstall_clicked),
                            settings);
          gtk_box_append (GTK_BOX (body), remove);
        }

      gtk_expander_set_child (GTK_EXPANDER (expander), body);
      gtk_box_append (GTK_BOX (section), expander);
    }

  /* Nothing added is the ordinary state: the shipped set is not listed, so a
   * mariner who has installed nothing sees this and the button. */
  if (managed == 0)
    {
      GtkWidget *none = gtk_label_new ("No plugins installed.");

      gtk_widget_add_css_class (none, "dim-label");
      gtk_label_set_wrap (GTK_LABEL (none), TRUE);
      gtk_label_set_xalign (GTK_LABEL (none), 0.0);
      gtk_box_append (GTK_BOX (section), none);
    }

  GtkWidget *install = gtk_button_new_with_label ("Install Plugin…");

  gtk_widget_set_halign (install, GTK_ALIGN_START);
  gtk_widget_set_margin_top (install, 6);
  g_signal_connect (install, "clicked", G_CALLBACK (lk_plugins_install_clicked), settings);
  gtk_box_append (GTK_BOX (section), install);

  /* The same sentence the macOS panel prints under this button. */
  lk_footer (section,
             "A plugin file (.lkplug) can also be opened from the file manager or "
             "dropped on the chart. Nothing is installed before its permissions "
             "are shown.");

  lk_plugin_refresh_status_labels (settings);
}
