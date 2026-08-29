/* ui/open-dialogs.c — every file picker the window and the settings raise.
 *
 * Under a portal a GtkFileDialog is asynchronous and can outlive the window
 * that raised it. So no callback here stores an LkWindow: each carries the
 * model, which lives as long as the application, and takes the live window
 * when it needs a parent.
 */
#include "ui/open-dialogs.h"
#include "ui/window-private.h"

#include "library/raster.h"
#include "plugins/install.h"
#include "plugins/registry.h"

/* ---- open dialog -------------------------------------------------------- */

static void
lk_open_finished (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkAppModel *model = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) file =
      gtk_file_dialog_select_folder_finish (GTK_FILE_DIALOG (source), result, &error);

  if (file == NULL)
    return; /* cancelled, or an error GTK already surfaced */

  g_autofree char *path = g_file_get_path (file);
  if (path != NULL)
    lk_app_model_open_chart (model, path);
  else
    lk_app_model_set_open_error (model,
                                 "That location isn't a local folder — the engine mmaps "
                                 "chart cells and needs a real path.");
}

/* Selects a FOLDER (a chart is a folder of baked cells). Starts at the open
 * chart's folder, else the baked-chart cache. */
static void
lk_open_chart_choice (GtkWindow *parent, LkAppModel *model)
{
  GtkFileDialog *dialog = gtk_file_dialog_new ();

  gtk_file_dialog_set_title (dialog, "Open Chart Folder");
  gtk_file_dialog_set_modal (dialog, TRUE);

  g_autofree char *initial = NULL;
  const char *current = lk_app_model_get_chart_path (model);
  if (current != NULL)
    initial = g_file_test (current, G_FILE_TEST_IS_DIR)
                  ? g_strdup (current)
                  : g_path_get_dirname (current);
  else
    {
      char *cache = g_build_filename (g_get_user_cache_dir (), "chartplotter", NULL);
      if (g_file_test (cache, G_FILE_TEST_IS_DIR))
        initial = cache;
      else
        g_free (cache);
    }
  if (initial != NULL)
    {
      g_autoptr (GFile) folder = g_file_new_for_path (initial);
      gtk_file_dialog_set_initial_folder (dialog, folder);
    }

  gtk_file_dialog_select_folder (dialog, parent, NULL, lk_open_finished, model);
  g_object_unref (dialog);
}

void
lk_present_open_chart_dialog (GtkWindow *parent, LkAppModel *model)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));

  lk_open_chart_choice (parent, model);
}

/* ---- one thing the mariner opened --------------------------------------- */

void
lk_window_open_path (GtkWindow *parent, LkAppModel *model, const char *path)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));

  if (path == NULL)
    return;

  /* A plugin package goes to consent and never to the chart engine. The
   * extension is the package's own, so this is routing, not sniffing. */
  if (lk_plugin_package_path (path))
    {
      lk_plugin_install_begin (parent, model, path, NULL, NULL);
      return;
    }

  /* A folder is a chart library. Anything else goes to lk_app_model_open_chart,
   * which offers it to the plugins first and opens it as a chart when none
   * claims it. */
  if (g_file_test (path, G_FILE_TEST_IS_DIR))
    lk_app_model_open_chart_directory (model, path);
  else
    lk_app_model_open_chart (model, path);
}

/* ---- the chart archive ------------------------------------------------- */

/* An exchange set arrives as one .zip as often as a folder: that is the shape a
 * chart agency publishes. GtkFileDialog picks folders or files, never both, so
 * the two are separate ways in rather than one that does both. Nothing is
 * unpacked — the engine bakes each cell where it lies inside the archive. */
static void
lk_open_archive_finished (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkAppModel *model = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) file = gtk_file_dialog_open_finish (GTK_FILE_DIALOG (source), result, &error);

  if (file == NULL)
    return; /* cancelled, or an error GTK already surfaced */

  g_autofree char *path = g_file_get_path (file);
  if (path != NULL)
    lk_app_model_open_chart (model, path);
  else
    lk_app_model_set_open_error (model,
                                 "That isn't a local file. The engine reads charts off "
                                 "the disk and needs a real path.");
}

void
lk_present_open_archive_dialog (GtkWindow *parent, LkAppModel *model)
{
  GtkFileDialog *dialog = gtk_file_dialog_new ();
  g_autoptr (GListStore) filters = g_list_store_new (GTK_TYPE_FILE_FILTER);
  GtkFileFilter *filter = gtk_file_filter_new ();

  gtk_file_filter_set_name (filter, "Chart exchange set (.zip)");
  gtk_file_filter_add_pattern (filter, "*.zip");
  gtk_file_filter_add_pattern (filter, "*.ZIP");
  g_list_store_append (filters, filter);
  g_object_unref (filter);

  gtk_file_dialog_set_title (dialog, "Open Chart Archive");
  gtk_file_dialog_set_modal (dialog, TRUE);
  gtk_file_dialog_set_accept_label (dialog, "Open");
  gtk_file_dialog_set_filters (dialog, G_LIST_MODEL (filters));

  gtk_file_dialog_open (dialog, parent, NULL, lk_open_archive_finished, model);
  g_object_unref (dialog);
}

/* ---- the raster chart pickers ------------------------------------------- */

static void
lk_raster_files_chosen (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkAppModel *model = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GListModel) files =
      gtk_file_dialog_open_multiple_finish (GTK_FILE_DIALOG (source), result, &error);

  if (files == NULL)
    return; /* cancelled, or an error GTK already surfaced */

  g_autoptr (GPtrArray) paths = g_ptr_array_new_with_free_func (g_free);
  guint n = g_list_model_get_n_items (files);

  for (guint i = 0; i < n; i++)
    {
      g_autoptr (GFile) file = g_list_model_get_item (files, i);
      char *path = g_file_get_path (file);

      if (path != NULL)
        g_ptr_array_add (paths, path);
    }

  if (paths->len == 0)
    {
      lk_app_model_set_open_error (model,
                                   "Those aren't local files — the engine reads a raster "
                                   "chart off the disk and needs a real path.");
      return;
    }

  g_ptr_array_add (paths, NULL);
  lk_app_model_add_raster_charts (model, (const char *const *) paths->pdata);
}

void
lk_present_add_raster_dialog (GtkWindow *parent, LkAppModel *model)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));

  GtkFileDialog *dialog = gtk_file_dialog_new ();
  g_autoptr (GtkFileFilter) raster = gtk_file_filter_new ();
  g_autoptr (GListStore) filters = g_list_store_new (GTK_TYPE_FILE_FILTER);

  gtk_file_dialog_set_title (dialog, "Add Raster Charts");
  gtk_file_dialog_set_modal (dialog, TRUE);
  gtk_file_dialog_set_accept_label (dialog, "Add");

  /* The extension is a hint only: the engine decides by what the file IS. The
   * "All files" filter is there so a chart with an odd name is still reachable. */
  gtk_file_filter_set_name (raster, "Raster charts");
  gtk_file_filter_add_suffix (raster, "mbtiles"); /* a suffix rule ignores case */
  g_list_store_append (filters, raster);

  g_autoptr (GtkFileFilter) all = gtk_file_filter_new ();
  gtk_file_filter_set_name (all, "All files");
  gtk_file_filter_add_pattern (all, "*");
  g_list_store_append (filters, all);

  gtk_file_dialog_set_filters (dialog, G_LIST_MODEL (filters));
  gtk_file_dialog_set_default_filter (dialog, raster);

  gtk_file_dialog_open_multiple (dialog, parent, NULL, lk_raster_files_chosen, model);
  g_object_unref (dialog);
}

static void
lk_raster_folder_chosen (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkAppModel *model = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) folder =
      gtk_file_dialog_select_folder_finish (GTK_FILE_DIALOG (source), result, &error);

  if (folder == NULL)
    return;

  g_autofree char *path = g_file_get_path (folder);
  if (path == NULL)
    return;

  g_auto (GStrv) paths = lk_raster_charts_in_dir (path);
  if (g_strv_length (paths) == 0)
    {
      lk_app_model_set_open_error (model, "That folder holds no .mbtiles raster charts.");
      return;
    }

  lk_app_model_add_raster_charts (model, (const char *const *) paths);
}

void
lk_present_add_raster_folder_dialog (GtkWindow *parent, LkAppModel *model)
{
  g_return_if_fail (LK_IS_APP_MODEL (model));

  GtkFileDialog *dialog = gtk_file_dialog_new ();

  gtk_file_dialog_set_title (dialog, "Add a Folder of Raster Charts");
  gtk_file_dialog_set_modal (dialog, TRUE);
  gtk_file_dialog_set_accept_label (dialog, "Add");
  gtk_file_dialog_select_folder (dialog, parent, NULL, lk_raster_folder_chosen, model);
  g_object_unref (dialog);
}

/* ---- one file ----------------------------------------------------------- */

/* One FILE, rather than a folder of cells: a single baked chart, a data file a
 * plugin reads, or a plugin package. GtkFileDialog takes files or folders and
 * never both, so the two live on separate items, as the two raster pickers do.
 *
 * No content-type filter. Naming types would grey out the mariner's own charts
 * where the system does not know the extension, and the core decides what a
 * file is anyway. */
void
lk_open_file_chosen (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkAppModel *model = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GFile) file = gtk_file_dialog_open_finish (GTK_FILE_DIALOG (source), result, &error);

  if (file == NULL)
    return; /* cancelled, or an error GTK already surfaced */

  g_autofree char *path = g_file_get_path (file);
  if (path == NULL)
    {
      lk_app_model_set_open_error (model, "That isn't a local file.");
      return;
    }

  /* Under a portal the dialog is async and can outlive the window that raised
     it, so the callback keeps no window pointer. A chosen plugin package opens
     a consent dialog that needs a parent; take whatever window is live now. */
  GtkWindow *parent =
      gtk_application_get_active_window (GTK_APPLICATION (g_application_get_default ()));
  lk_window_open_path (parent, model, path);
}
