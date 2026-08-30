#include "plugins/install.h"

#include "util/json.h"

/* What the core said about one package: everything the consent sheet shows, or
 * the one sentence the package was refused with. Every string borrows from
 * `tree`, which the struct owns. */
typedef struct {
  LkJson *tree;

  const char *path;
  const char *id;
  const char *name;
  const char *version;
  const LkJson *sentences; /* one per capability, in the core's words and order */

  /* The running copy, when this id is already loaded, and the delta against it
   * in the same consent wording. */
  const char   *installed_version;
  const char   *installed_origin;
  const LkJson *adds;
  const LkJson *drops;
  gboolean      downgrade;

  const char *error;
} LkPackage;

typedef struct {
  LkAppModel *model;
  GtkWidget  *window;
  char       *path;
  GFunc       on_installed;
  gpointer    user_data;
} LkInstallFlow;

gboolean
lk_plugin_package_path (const char *path)
{
  g_autofree char *lowered = path == NULL ? NULL : g_ascii_strdown (path, -1);

  return lowered != NULL && g_str_has_suffix (lowered, ".lkplug");
}

static void
lk_package_free (LkPackage *package)
{
  if (package == NULL)
    return;
  lk_json_free (package->tree);
  g_free (package);
}

G_DEFINE_AUTOPTR_CLEANUP_FUNC (LkPackage, lk_package_free)

static LkPackage *
lk_package_read (LkAppModel *model, const char *path)
{
  g_autofree char *json =
      lk_chart_controller_plugin_inspect (lk_app_model_get_controller (model), path);
  LkJson *tree = json == NULL ? NULL : lk_json_parse (json);

  if (tree == NULL)
    return NULL;

  LkPackage *package = g_new0 (LkPackage, 1);
  const LkJson *installed = lk_json_member (tree, "installed");

  package->tree = tree;
  package->path = path;
  package->id = lk_json_member_string (tree, "id");
  package->name = lk_json_member_string (tree, "name");
  package->version = lk_json_member_string (tree, "version");
  package->sentences = lk_json_member (tree, "sentences");
  package->error = lk_json_member_string (tree, "error");

  package->installed_version = lk_json_member_string (installed, "version");
  package->installed_origin = lk_json_member_string (installed, "origin");
  package->adds = lk_json_member (installed, "adds");
  package->drops = lk_json_member (installed, "drops");
  package->downgrade = lk_json_member_bool (installed, "downgrade", FALSE);

  /* A reinstall is what "installed" being present means, whatever else it
   * holds. A version it did not state still replaces a running copy. */
  if (installed != NULL && package->installed_version == NULL)
    package->installed_version = "";
  return package;
}

static void
lk_install_flow_free (gpointer data)
{
  LkInstallFlow *flow = data;

  g_free (flow->path);
  g_free (flow);
}

/* ---- the sheet ----------------------------------------------------------- */

static GtkWidget *
lk_install_heading (const char *text)
{
  GtkWidget *label = gtk_label_new (text);

  gtk_widget_add_css_class (label, "heading");
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_widget_set_margin_top (label, 6);
  return label;
}

/* One list of consent sentences, each behind its own mark. */
static void
lk_install_sentences (GtkWidget *into, const LkJson *list, const char *icon_name,
                      const char *css_class)
{
  for (guint i = 0; i < lk_json_length (list); i++)
    {
      const char *sentence = lk_json_string (lk_json_at (list, i));

      if (sentence == NULL)
        continue;

      GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
      GtkWidget *icon = gtk_image_new_from_icon_name (icon_name);
      GtkWidget *label = gtk_label_new (sentence);

      gtk_image_set_pixel_size (GTK_IMAGE (icon), 14);
      gtk_widget_set_valign (icon, GTK_ALIGN_START);
      gtk_widget_set_margin_top (icon, 3);
      if (css_class != NULL)
        gtk_widget_add_css_class (icon, css_class);

      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_widget_set_hexpand (label, TRUE);

      gtk_box_append (GTK_BOX (line), icon);
      gtk_box_append (GTK_BOX (line), label);
      gtk_box_append (GTK_BOX (into), line);
    }
}

/* What replacing a running copy will do, said before the mariner agrees to it. */
static char *
lk_install_reinstall_note (const LkPackage *package)
{
  g_autofree char *what =
      package->installed_version[0] == '\0'
          ? g_strdup ("the installed copy")
          : g_strdup_printf ("the installed version %s", package->installed_version);
  g_autoptr (GString) note = g_string_new (NULL);

  g_string_append_printf (note, package->downgrade ? "Replaces %s. This is a downgrade."
                                                   : "Replaces %s.",
                          what);

  /* A developer override outranks an installed copy, so the files land and
   * nothing on screen changes. Saying so beats looking broken. */
  if (g_strcmp0 (package->installed_origin, "developer") == 0)
    g_string_append (note, " The developer copy keeps running until its override is dropped.");

  return g_string_free (g_steal_pointer (&note), FALSE);
}

static void
lk_install_confirm (GtkButton *button, gpointer user_data)
{
  LkInstallFlow *flow = user_data;
  g_autofree char *problem =
      lk_chart_controller_plugin_install (lk_app_model_get_controller (flow->model),
                                          flow->path);

  /* Destroying the sheet frees `flow` with it, so everything the rest of this
   * needs is taken off it first. */
  LkAppModel *model = flow->model;
  GFunc on_installed = flow->on_installed;
  gpointer data = flow->user_data;
  GtkWindow *parent = gtk_window_get_transient_for (GTK_WINDOW (flow->window));

  gtk_window_destroy (GTK_WINDOW (flow->window));

  if (problem != NULL)
    {
      /* The core's sentence is ready to show, so it is shown as it stands. */
      GtkAlertDialog *alert = gtk_alert_dialog_new ("Couldn't install the plugin");

      gtk_alert_dialog_set_detail (alert, problem);
      gtk_alert_dialog_show (alert, parent);
      g_object_unref (alert);
      return;
    }

  if (on_installed != NULL)
    on_installed (model, data);
}

static void
lk_install_cancel (GtkButton *button, gpointer user_data)
{
  gtk_window_destroy (GTK_WINDOW (user_data));
}

void
lk_plugin_install_begin (GtkWindow  *parent,
                         LkAppModel *model,
                         const char *path,
                         GFunc       on_installed,
                         gpointer    user_data)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));
  g_return_if_fail (path != NULL);

  g_autoptr (LkPackage) package = lk_package_read (model, path);

  if (package == NULL)
    {
      GtkAlertDialog *alert = gtk_alert_dialog_new ("Couldn't read the plugin");

      gtk_alert_dialog_set_detail (alert,
                                   "Open a chart first: a plugin is installed into the "
                                   "plugin layer, and that comes up with the chart.");
      gtk_alert_dialog_show (alert, parent);
      g_object_unref (alert);
      return;
    }

  /* A package the core refuses shows the reason and offers nothing. */
  if (package->error != NULL)
    {
      GtkAlertDialog *alert = gtk_alert_dialog_new ("This plugin can't be installed");

      gtk_alert_dialog_set_detail (alert, package->error);
      gtk_alert_dialog_show (alert, parent);
      g_object_unref (alert);
      return;
    }

  GtkWidget *window = gtk_window_new ();
  LkInstallFlow *flow = g_new0 (LkInstallFlow, 1);

  flow->model = model;
  flow->window = window;
  flow->path = g_strdup (path);
  flow->on_installed = on_installed;
  flow->user_data = user_data;
  g_object_set_data_full (G_OBJECT (window), "lk-install-flow", flow, lk_install_flow_free);

  gtk_window_set_title (GTK_WINDOW (window), "Install Plugin");
  gtk_window_set_transient_for (GTK_WINDOW (window), parent);
  gtk_window_set_modal (GTK_WINDOW (window), TRUE);
  gtk_window_set_default_size (GTK_WINDOW (window), 460, -1);

  GtkWidget *root = gtk_box_new (GTK_ORIENTATION_VERTICAL, 14);
  gtk_widget_set_margin_start (root, 20);
  gtk_widget_set_margin_end (root, 20);
  gtk_widget_set_margin_top (root, 20);
  gtk_widget_set_margin_bottom (root, 20);

  /* Who this is. */
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *icon = gtk_image_new_from_icon_name ("application-x-addon-symbolic");
  GtkWidget *titles = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
  GtkWidget *name = gtk_label_new (package->name != NULL ? package->name : package->id);
  GtkWidget *id = gtk_label_new (package->id);

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 32);
  gtk_widget_add_css_class (icon, "dim-label");
  gtk_widget_set_valign (icon, GTK_ALIGN_START);
  gtk_widget_add_css_class (name, "title-4");
  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_label_set_wrap (GTK_LABEL (name), TRUE);
  gtk_widget_add_css_class (id, "dim-label");
  gtk_widget_add_css_class (id, "caption");
  gtk_label_set_xalign (GTK_LABEL (id), 0.0);
  gtk_label_set_selectable (GTK_LABEL (id), TRUE);

  gtk_box_append (GTK_BOX (titles), name);
  gtk_box_append (GTK_BOX (titles), id);
  gtk_widget_set_hexpand (titles, TRUE);
  gtk_box_append (GTK_BOX (header), icon);
  gtk_box_append (GTK_BOX (header), titles);

  if (package->version != NULL)
    {
      g_autofree char *text = g_strdup_printf ("Version %s", package->version);
      GtkWidget *version = gtk_label_new (text);

      gtk_widget_add_css_class (version, "dim-label");
      gtk_widget_add_css_class (version, "caption");
      gtk_widget_set_valign (version, GTK_ALIGN_START);
      gtk_box_append (GTK_BOX (header), version);
    }
  gtk_box_append (GTK_BOX (root), header);

  if (package->installed_version != NULL)
    {
      g_autofree char *text = lk_install_reinstall_note (package);
      GtkWidget *note = gtk_label_new (text);

      gtk_label_set_wrap (GTK_LABEL (note), TRUE);
      gtk_label_set_xalign (GTK_LABEL (note), 0.0);
      if (package->downgrade)
        gtk_widget_add_css_class (note, "lk-note");
      gtk_box_append (GTK_BOX (root), note);
    }

  gtk_box_append (GTK_BOX (root), gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));

  /* What it will be able to do. The sentences are the core's, so every shell
   * asks for consent in the same words. */
  GtkWidget *sentences = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  gtk_box_append (GTK_BOX (root),
                  lk_install_heading (package->installed_version != NULL
                                          ? "After this install it can:"
                                          : "This plugin can:"));

  if (lk_json_length (package->sentences) == 0)
    {
      GtkWidget *none = gtk_label_new ("This plugin only draws its own settings pages.");

      gtk_widget_add_css_class (none, "dim-label");
      gtk_label_set_wrap (GTK_LABEL (none), TRUE);
      gtk_label_set_xalign (GTK_LABEL (none), 0.0);
      gtk_box_append (GTK_BOX (sentences), none);
    }
  else
    {
      lk_install_sentences (sentences, package->sentences, "emblem-ok-symbolic", "dim-label");
    }
  gtk_box_append (GTK_BOX (root), sentences);

  /* The delta against the running copy, which is the part a reinstall is
   * actually asking about. */
  if (lk_json_length (package->adds) > 0)
    {
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);

      gtk_box_append (GTK_BOX (root), lk_install_heading ("New since the installed version:"));
      lk_install_sentences (box, package->adds, "list-add-symbolic", "lk-warning");
      gtk_box_append (GTK_BOX (root), box);
    }
  if (lk_json_length (package->drops) > 0)
    {
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);

      gtk_box_append (GTK_BOX (root), lk_install_heading ("No longer asks to:"));
      lk_install_sentences (box, package->drops, "list-remove-symbolic", "dim-label");
      gtk_box_append (GTK_BOX (root), box);
    }

  gtk_box_append (GTK_BOX (root), gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));

  /* Nothing touches the disk until Install, and Cancel deletes nothing. */
  GtkWidget *buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *cancel = gtk_button_new_with_label ("Cancel");
  GtkWidget *install = gtk_button_new_with_label ("Install");

  gtk_widget_add_css_class (install, "suggested-action");
  gtk_widget_set_halign (buttons, GTK_ALIGN_END);
  g_signal_connect (cancel, "clicked", G_CALLBACK (lk_install_cancel), window);
  g_signal_connect (install, "clicked", G_CALLBACK (lk_install_confirm), flow);
  gtk_box_append (GTK_BOX (buttons), cancel);
  gtk_box_append (GTK_BOX (buttons), install);
  gtk_box_append (GTK_BOX (root), buttons);

  /* A long consent list scrolls rather than growing past the screen. */
  GtkWidget *scroller = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_propagate_natural_height (GTK_SCROLLED_WINDOW (scroller), TRUE);
  gtk_scrolled_window_set_max_content_height (GTK_SCROLLED_WINDOW (scroller), 620);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), root);
  gtk_window_set_child (GTK_WINDOW (window), scroller);

  gtk_widget_grab_focus (install);
  gtk_window_present (GTK_WINDOW (window));
}

/* ---- the picker ---------------------------------------------------------- */

static void
lk_install_file_chosen (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkInstallFlow *flow = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) file = gtk_file_dialog_open_finish (GTK_FILE_DIALOG (source), result, &error);

  if (file != NULL)
    {
      g_autofree char *path = g_file_get_path (file);

      /* The picker is async and can outlive the window that raised it. The flow
         holds a reference to that window, so it cannot be freed here; a window
         closed while the picker stood takes no install. */
      if (path != NULL && flow->window != NULL &&
          !gtk_widget_in_destruction (flow->window))
        lk_plugin_install_begin (GTK_WINDOW (flow->window), flow->model, path,
                                 flow->on_installed, flow->user_data);
    }

  g_clear_object (&flow->window);
  lk_install_flow_free (flow);
}

void
lk_plugin_install_choose (GtkWindow  *parent,
                          LkAppModel *model,
                          GFunc       on_installed,
                          gpointer    user_data)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));

  GtkFileDialog *dialog = gtk_file_dialog_new ();
  g_autoptr (GtkFileFilter) filter = gtk_file_filter_new ();
  g_autoptr (GListStore) filters = g_list_store_new (GTK_TYPE_FILE_FILTER);
  LkInstallFlow *flow = g_new0 (LkInstallFlow, 1);

  flow->model = model;
  /* Hold the parent for the picker's life. The file dialog is async, and the
     window that raised it can close before the mariner picks a file. */
  flow->window = parent != NULL ? GTK_WIDGET (g_object_ref (parent)) : NULL;
  flow->on_installed = on_installed;
  flow->user_data = user_data;

  gtk_file_filter_set_name (filter, "Plugin packages");
  gtk_file_filter_add_suffix (filter, "lkplug");
  g_list_store_append (filters, filter);

  gtk_file_dialog_set_title (dialog, "Install Plugin");
  gtk_file_dialog_set_modal (dialog, TRUE);
  gtk_file_dialog_set_accept_label (dialog, "Open");
  gtk_file_dialog_set_filters (dialog, G_LIST_MODEL (filters));
  gtk_file_dialog_set_default_filter (dialog, filter);

  gtk_file_dialog_open (dialog, parent, NULL, lk_install_file_chosen, flow);
  g_object_unref (dialog);
}
