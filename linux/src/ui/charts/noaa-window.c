/* ui/charts/noaa-window.c — see ui/charts/noaa-window.h. */
#include "ui/charts/noaa-window.h"

#include "ui/charts/coverage-map.h"

/* The size the map was drawn for, and the floor under it. Below about 820 the
 * Alaska inset reaches the west coast and a region cannot be picked through
 * the frame of another one. */
#define LK_NOAA_WINDOW_WIDTH  1040
#define LK_NOAA_WINDOW_HEIGHT 760
#define LK_NOAA_WINDOW_MIN_WIDTH  820
#define LK_NOAA_WINDOW_MIN_HEIGHT 600

typedef struct {
  LkAppModel *model; /* not owned: the app outlives this window */
  LkNoaa     *noaa;  /* not owned: the model owns it */

  GtkWidget *window;
  GtkWidget *cost;
  GtkWidget *download;
  GtkWidget *again;

  /* The water this device already holds, ticked when the picker opens, and the
   * pick as it stood then. Download acts on the difference between the two. */
  gboolean seeded;
  gboolean seeding;
  char    *baseline; /* the picked ids at seed time */
} LkNoaaWindow;

/* One instance. A second ask raises the window that is already up. */
static GtkWidget *lk_noaa_window;

static void
lk_noaa_window_free (gpointer data)
{
  LkNoaaWindow *self = data;

  if (lk_noaa_window == self->window)
    lk_noaa_window = NULL;
  /* The pick is scratch work on a model that outlives this window. Left
   * standing, the next open takes it as the baseline and reads abandoned water
   * as water the mariner holds: the region opens ticked and the button opens
   * dead, so the water cannot be downloaded without unticking it first. The
   * next open builds the pick again from the record. */
  if (LK_IS_NOAA (self->noaa))
    lk_noaa_clear_picks (self->noaa);
  g_free (self->baseline);
  g_free (self);
}

/* Tick the water already on the device, once the catalog has priced each
 * region. A mariner coming back to add more starts from what they have. */
static void
lk_noaa_window_seed (LkNoaaWindow *self, LkNoaa *noaa)
{
  guint n = 0;
  const LkNoaaRegion *regions = lk_noaa_regions (noaa, &n);

  /* The per-region counts arrive with the catalog. What this device holds
   * comes from the background scan, and a set it has yet to reach reports no
   * cells, so the seed waits for both. */
  if (!lk_noaa_state (noaa)->have_catalog || lk_app_model_library_scanning (self->model))
    return;

  /* The regions the core records as downloaded and still held whole. */
  self->seeding = TRUE;
  for (guint i = 0; i < n; i++)
    if (lk_noaa_region_info (noaa, regions[i].id)->recorded &&
        !lk_noaa_is_picked (noaa, regions[i].id))
      lk_noaa_toggle (noaa, regions[i].id);
  self->seeding = FALSE;

  self->seeded = TRUE;
  g_free (self->baseline);
  self->baseline = lk_noaa_picked_ids (noaa);
}

/* The names of the regions the mariner has taken out of the pick since the
 * picker opened. Transfer full. */
static char **
lk_noaa_window_dropped (LkNoaaWindow *self, LkNoaa *noaa)
{
  GPtrArray *out = g_ptr_array_new ();

  if (self->seeded && self->baseline != NULL && self->baseline[0] != '\0')
    {
      g_auto (GStrv) was = g_strsplit (self->baseline, ",", -1);

      for (guint i = 0; was[i] != NULL; i++)
        {
          const LkNoaaRegion *region = lk_noaa_region (noaa, was[i]);

          if (region != NULL && !lk_noaa_is_picked (noaa, was[i]))
            g_ptr_array_add (out, g_strdup (region->name));
        }
    }
  g_ptr_array_add (out, NULL);
  return (char **) g_ptr_array_free (out, FALSE);
}

static void
lk_noaa_window_sync (LkNoaa *noaa, gpointer user_data)
{
  /* The handler is tied to the WINDOW's life, so the window is what arrives
   * here and the state hangs off it. The same shape the settings pages use. */
  LkNoaaWindow *self = g_object_get_data (G_OBJECT (user_data), "lk-noaa-window");
  const lookout_noaa_state *state = lk_noaa_state (noaa);
  gboolean ready, picked, priced;

  if (self == NULL || gtk_widget_in_destruction (GTK_WIDGET (user_data)))
    return;

  if (self->seeding)
    return;

  ready = state->have_catalog;
  if (!self->seeded)
    lk_noaa_window_seed (self, noaa);

  picked = lk_noaa_picked_count (noaa) > 0;
  priced = ready && (lk_noaa_cells (noaa) > 0 || lk_noaa_held (noaa) > 0);

  /* The footer names the PLAN, so the mariner reads what Apply will do before
   * pressing it: what a pick adds, and the water taking it out removes. */
  g_auto (GStrv) dropped = lk_noaa_window_dropped (self, noaa);
  gboolean removes = g_strv_length (dropped) > 0;
  g_autofree char *plan = NULL;

  if (removes)
    {
      g_autofree char *names = g_strjoinv (", ", dropped);
      g_autofree char *gone = g_strdup_printf ("remove %s", names);

      if (lk_noaa_cells (noaa) > lk_noaa_held (noaa))
        {
          g_autofree char *add = lk_noaa_cost_line (noaa);
          plan = g_strdup_printf ("%s · %s", add, gone);
        }
      else
        {
          gone[0] = g_ascii_toupper (gone[0]);
          plan = g_steal_pointer (&gone);
        }
    }
  else if (priced)
    plan = lk_noaa_cost_line (noaa);

  gtk_label_set_text (GTK_LABEL (self->cost), plan != NULL ? plan : "");
  gtk_widget_set_visible (self->cost, plan != NULL);

  /* The button acts on a CHANGE to the pick. The water already held is ticked
   * when the picker opens, so an untouched pick has nothing to do. Water taken
   * OUT of the pick is water to delete, and the button says so. */
  g_autofree char *now = lk_noaa_picked_ids (noaa);
  gboolean moved = self->seeded && g_strcmp0 (now, self->baseline) != 0;

  gtk_button_set_label (GTK_BUTTON (self->download), removes ? "Apply" : "Download");
  gtk_widget_set_sensitive (self->download, ready && moved);

  /* Water the device holds in full has no cells to add or remove, so the
   * button above is insensitive. Fetching it again repairs a damaged
   * download and picks up any edition NOAA has reissued, so that press has a
   * button of its own (apple/LookoutMarine/Charts/NoaaRegionList.swift). */
  gtk_widget_set_visible (self->again, ready && picked && !removes &&
                                           lk_noaa_cells (noaa) <= lk_noaa_held (noaa));
}

/* Fetch the whole pick again, held cells included. */
static void
lk_noaa_window_again (GtkButton *button, gpointer user_data)
{
  LkNoaaWindow *self = user_data;

  lk_app_model_start_noaa_download (self->model, TRUE);
  gtk_window_close (GTK_WINDOW (self->window));
}

/* Make the download hold the pick: the water given back goes, and what the
 * pick lacks is downloaded. */
static void
lk_noaa_window_apply (LkNoaaWindow *self)
{
  lk_app_model_apply_noaa_pick (self->model);
  gtk_window_close (GTK_WINDOW (self->window));
}

static void
lk_noaa_remove_answered (GObject *source, GAsyncResult *result, gpointer user_data)
{
  g_autoptr (GtkWindow) window = user_data;
  int chosen = gtk_alert_dialog_choose_finish (GTK_ALERT_DIALOG (source), result, NULL);
  LkNoaaWindow *self = g_object_get_data (G_OBJECT (window), "lk-noaa-window");

  /* Cancel is 0, Remove is 1. */
  if (chosen == 1 && self != NULL && !gtk_widget_in_destruction (GTK_WIDGET (window)))
    lk_noaa_window_apply (self);
}

static void
lk_noaa_window_download (GtkButton *button, gpointer user_data)
{
  LkNoaaWindow *self = user_data;
  g_auto (GStrv) dropped = lk_noaa_window_dropped (self, self->noaa);
  guint n = g_strv_length (dropped);

  if (n == 0)
    {
      lk_noaa_window_apply (self);
      return;
    }

  /* Water taken out of the pick is water to delete, and a delete is asked
   * about before it runs. The charts go from the device. NOAA still has
   * them. */
  gboolean all = lk_noaa_picked_count (self->noaa) == 0;
  g_autofree char *question =
      all      ? g_strdup ("Remove all NOAA charts?")
      : n == 1 ? g_strdup_printf ("Remove %s charts?", dropped[0])
               : g_strdup_printf ("Remove charts for %u regions?", n);
  const char *detail =
      all ? "This gives back everything the NOAA downloader holds, and the "
            "folder it downloaded to. Charts you added yourself stay where "
            "they are, and you can download this water again."
          : "These are the charts only the water you took out of the pick "
            "covers. Lookout deletes the charts it downloaded. Charts you "
            "added yourself stay where they are, and you can download this "
            "water again.";
  static const char *answers[] = { "Cancel", "Remove", NULL };

  GtkAlertDialog *dialog = gtk_alert_dialog_new ("%s", question);
  gtk_alert_dialog_set_detail (dialog, detail);
  gtk_alert_dialog_set_buttons (dialog, answers);
  gtk_alert_dialog_set_cancel_button (dialog, 0);
  gtk_alert_dialog_set_default_button (dialog, 0);
  gtk_alert_dialog_choose (dialog, GTK_WINDOW (self->window), NULL,
                           lk_noaa_remove_answered, g_object_ref (self->window));
  g_object_unref (dialog);
}

static void
lk_noaa_window_cancel (GtkButton *button, gpointer user_data)
{
  LkNoaaWindow *self = user_data;

  gtk_window_close (GTK_WINDOW (self->window));
}

void
lk_noaa_window_present (GtkWindow *parent, LkAppModel *model)
{
  LkNoaaWindow *self;
  LkNoaa *noaa;

  g_return_if_fail (LK_IS_APP_MODEL (model));

  if (lk_noaa_window != NULL)
    {
      gtk_window_present (GTK_WINDOW (lk_noaa_window));
      return;
    }

  noaa = lk_app_model_get_noaa (model);
  g_return_if_fail (LK_IS_NOAA (noaa));

  self = g_new0 (LkNoaaWindow, 1);
  self->model = model;
  self->noaa = noaa;
  self->window = gtk_window_new ();

  gtk_window_set_title (GTK_WINDOW (self->window), "NOAA Charts");
  gtk_window_set_transient_for (GTK_WINDOW (self->window), parent);
  gtk_window_set_default_size (GTK_WINDOW (self->window),
                               LK_NOAA_WINDOW_WIDTH, LK_NOAA_WINDOW_HEIGHT);
  gtk_widget_set_size_request (self->window,
                              LK_NOAA_WINDOW_MIN_WIDTH, LK_NOAA_WINDOW_MIN_HEIGHT);
  g_object_set_data_full (G_OBJECT (self->window), "lk-noaa-window", self,
                          lk_noaa_window_free);

  GtkWidget *root = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *scroller = gtk_scrolled_window_new ();
  GtkWidget *page = gtk_box_new (GTK_ORIENTATION_VERTICAL, 14);
  GtkWidget *blurb = gtk_label_new ("NOAA publishes an ENC for every United States "
                                    "waterway at no cost. Tick the water you sail. "
                                    "Unticking water you hold removes those charts.");

  gtk_label_set_wrap (GTK_LABEL (blurb), TRUE);
  gtk_label_set_xalign (GTK_LABEL (blurb), 0.0);
  gtk_widget_add_css_class (blurb, "dim-label");

  gtk_widget_set_margin_top (page, 18);
  gtk_widget_set_margin_bottom (page, 18);
  gtk_widget_set_margin_start (page, 18);
  gtk_widget_set_margin_end (page, 18);
  gtk_box_append (GTK_BOX (page), blurb);
  gtk_box_append (GTK_BOX (page), lk_noaa_catalog_line_new (noaa));
  gtk_box_append (GTK_BOX (page), lk_coverage_map_new (noaa, model));
  gtk_box_append (GTK_BOX (page), lk_coverage_key_new ());
  gtk_box_append (GTK_BOX (page), lk_noaa_region_pills_new (noaa));

  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), page);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_vexpand (scroller, TRUE);
  gtk_box_append (GTK_BOX (root), scroller);

  /* The footer: what the pick costs, and the two answers. */
  GtkWidget *footer = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  GtkWidget *cancel = gtk_button_new_with_label ("Cancel");

  self->cost = gtk_label_new ("");
  self->again = gtk_button_new_with_label ("Download Again");
  self->download = gtk_button_new_with_label ("Download");

  gtk_widget_add_css_class (self->cost, "dim-label");
  gtk_widget_add_css_class (self->cost, "caption");
  gtk_label_set_xalign (GTK_LABEL (self->cost), 0.0);
  gtk_widget_set_hexpand (self->cost, TRUE);
  gtk_widget_add_css_class (self->download, "suggested-action");
  gtk_widget_add_css_class (self->download, "pill");
  gtk_widget_add_css_class (self->again, "pill");
  gtk_widget_add_css_class (cancel, "pill");
  gtk_widget_set_tooltip_text (self->again, "Download this water again, including the "
                                            "charts already here. This repairs a damaged "
                                            "download and gets any edition NOAA has "
                                            "reissued.");
  gtk_widget_set_visible (self->again, FALSE);
  g_signal_connect (self->download, "clicked",
                    G_CALLBACK (lk_noaa_window_download), self);
  g_signal_connect (self->again, "clicked", G_CALLBACK (lk_noaa_window_again), self);
  g_signal_connect (cancel, "clicked", G_CALLBACK (lk_noaa_window_cancel), self);

  gtk_box_append (GTK_BOX (footer), self->cost);
  gtk_box_append (GTK_BOX (footer), cancel);
  gtk_box_append (GTK_BOX (footer), self->again);
  gtk_box_append (GTK_BOX (footer), self->download);
  gtk_widget_set_margin_top (footer, 12);
  gtk_widget_set_margin_bottom (footer, 12);
  gtk_widget_set_margin_start (footer, 18);
  gtk_widget_set_margin_end (footer, 18);
  gtk_box_append (GTK_BOX (root), footer);

  gtk_window_set_child (GTK_WINDOW (self->window), root);

  /* BEFORE THE HANDLER IS CONNECTED. The sync seeds the pick from the
   * per-region counts this call reads again. The call also emits ::changed,
   * and a handler connected first seeds the pick from stale counts. */
  if (!lk_app_model_library_scanning (model))
    lk_noaa_reprice (noaa);

  g_signal_connect_object (noaa, "changed", G_CALLBACK (lk_noaa_window_sync),
                           self->window, 0);
  lk_noaa_window_sync (noaa, self->window);

  lk_noaa_window = self->window;
  gtk_window_present (GTK_WINDOW (self->window));

  if (!lk_noaa_state (noaa)->have_catalog)
    lk_noaa_refresh (noaa);
}
