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
  g_auto (GStrv) downloaded = NULL;

  /* The per-region counts arrive with the catalog, and the seed needs them
   * both to adopt an older library and to drop a region whose charts have
   * gone. The picker says nothing useful before the catalog either. */
  if (!lk_noaa_state (noaa)->have_catalog)
    return;

  /* NOT WHILE THE LIBRARY IS BEING READ. What this device holds comes from
   * the background scan, and a set it has yet to reach reports no cells at
   * all. The prune below then reads every region as gone and writes the
   * record empty, which no later scan puts back: a picker opened in the first
   * seconds after launch left every region unticked for good. */
  if (lk_app_model_library_scanning (self->model))
    return;

  /* A library downloaded before the record existed has none. Take the regions
   * it holds whole, once. */
  lk_noaa_adopt_downloaded (noaa);
  /* And a region whose charts are gone drops out. Removing a set from the
   * Charts pane takes them without the picker hearing of it, and the region
   * read as downloaded ever after. */
  lk_noaa_prune_downloaded (noaa);
  downloaded = lk_noaa_downloaded_regions (noaa);

  /* THE REGIONS THE MARINER DOWNLOADED, and no others. Reading coverage
   * instead ticked districts they never chose: NOAA files cells across
   * district lines, so downloading the Northeast installs some of the
   * Southeast's, and unticking the Southeast then offered to delete charts
   * that every district still picked also covers. Nothing was deletable and
   * the press did nothing. */
  self->seeding = TRUE;
  for (guint i = 0; downloaded != NULL && downloaded[i] != NULL; i++)
    if (!lk_noaa_is_picked (noaa, downloaded[i]) &&
        lk_noaa_region (noaa, downloaded[i]) != NULL)
      lk_noaa_toggle (noaa, downloaded[i]);
  self->seeding = FALSE;

  self->seeded = TRUE;
  g_free (self->baseline);
  self->baseline = lk_noaa_picked_ids (noaa);
}

/* The regions the mariner has taken out of the pick since the picker opened.
 * Transfer full. */
static char **
lk_noaa_window_dropped (LkNoaaWindow *self, LkNoaa *noaa)
{
  GPtrArray *out = g_ptr_array_new ();

  if (self->seeded && self->baseline != NULL && self->baseline[0] != '\0')
    {
      g_auto (GStrv) was = g_strsplit (self->baseline, ",", -1);

      for (guint i = 0; was[i] != NULL; i++)
        if (was[i][0] != '\0' && !lk_noaa_is_picked (noaa, was[i]))
          g_ptr_array_add (out, g_strdup (was[i]));
    }
  g_ptr_array_add (out, NULL);
  return (char **) g_ptr_array_free (out, FALSE);
}

/* The cells a removal deletes: every cell of the dropped regions that is on
 * this device and that no region still picked also covers.
 *
 * Both filters matter. Regions overlap, because NOAA files a cell under one
 * district that covers another's, so dropping one district leaves the cells
 * its neighbour still wants. And a district covers far more cells than a
 * mariner downloaded, so counting the region rather than the disk put 869 in
 * a warning about a device holding 935 across three districts. Transfer
 * full. */
static char **
lk_noaa_window_doomed (LkNoaaWindow *self, LkNoaa *noaa)
{
  g_auto (GStrv) dropped = lk_noaa_window_dropped (self, noaa);
  GPtrArray *out = g_ptr_array_new ();

  /* AN EMPTY PICK TAKES THE WHOLE DOWNLOAD. The cells above come from the
   * catalog's districts, and a device holds cells no recorded district claims:
   * one download of district 5 left 16 cells filed under district 1, 7 under
   * district 7, and one cell the catalog no longer lists. Unticking every
   * region deleted 934 of 958 and left those 24, which no later press could
   * reach. What the downloader holds is what it gives back. */
  if (lk_noaa_picked_count (noaa) == 0)
    {
      g_ptr_array_free (out, TRUE);
      return lk_app_model_noaa_cells_held (self->model);
    }

  if (dropped != NULL && g_strv_length (dropped) > 0)
    {
      g_autofree char *gone_ids = g_strjoinv (",", dropped);
      g_autofree char *kept_ids = lk_noaa_picked_ids (noaa);
      g_auto (GStrv) gone = lk_noaa_region_cells (noaa, gone_ids);
      g_auto (GStrv) kept = lk_noaa_region_cells (noaa, kept_ids);
      g_autoptr (GHashTable) keep = g_hash_table_new (g_str_hash, g_str_equal);

      for (guint i = 0; kept != NULL && kept[i] != NULL; i++)
        g_hash_table_add (keep, kept[i]);
      for (guint i = 0; gone != NULL && gone[i] != NULL; i++)
        if (!g_hash_table_contains (keep, gone[i]))
          g_ptr_array_add (out, g_strdup (gone[i]));
    }
  g_ptr_array_add (out, NULL);

  /* Down to what is on the disk. A district covers far more cells than a
   * mariner downloaded: 869 of Northeast's cells stood outside the districts
   * still picked, against a device holding 935 across three of them. */
  g_auto (GStrv) named = (char **) g_ptr_array_free (out, FALSE);
  return lk_app_model_noaa_cells_present (self->model, (const char *const *) named);
}

static void
lk_noaa_window_sync (LkNoaa *noaa, gpointer user_data)
{
  /* The handler is tied to the WINDOW's life, so the window is what arrives
   * here and the state hangs off it. The same shape the settings pages use. */
  LkNoaaWindow *self = g_object_get_data (G_OBJECT (user_data), "lk-noaa-window");
  const LkNoaaState *state = lk_noaa_state (noaa);
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
   * pressing it: what a pick adds, and what taking water out of it removes. */
  g_auto (GStrv) dropped_now = lk_noaa_window_dropped (self, noaa);
  g_autofree char *plan = NULL;

  if (dropped_now != NULL && g_strv_length (dropped_now) > 0)
    {
      /* HOW MANY CHARTS GO, as the spec states it. The region names read as a
       * list of water, and a mariner cannot weigh that against the charts a
       * pick adds. This is the count the warning states as well. */
      g_auto (GStrv) doomed = lk_noaa_window_doomed (self, noaa);
      guint n = doomed != NULL ? g_strv_length (doomed) : 0;
      g_autofree char *gone =
          g_strdup_printf (n == 1 ? "remove %u chart" : "remove %u charts", n);

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
  gboolean removes = dropped_now != NULL && g_strv_length (dropped_now) > 0;

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

/* Fetch what the pick added. The cells this device holds are left out, so a
 * pick that still has the water it opened with fetches only what is new. */
static void
lk_noaa_window_fetch (LkNoaaWindow *self)
{
  if (lk_noaa_picked_count (self->noaa) > 0)
    lk_app_model_start_noaa_download (self->model, FALSE);
  gtk_window_close (GTK_WINDOW (self->window));
}

/* The question outlives the press that raised it, so it holds the window by a
 * reference and the model separately. The window's own state hangs off the
 * window, and a picker closed under the question is not read. */
typedef struct {
  GtkWindow  *window; /* reffed */
  LkAppModel *model;  /* not owned: the app outlives this */
  LkNoaa     *noaa;   /* not owned: the model owns it */
  GStrv       cells;
  GStrv       regions; /* the ids whose charts are going */
  gboolean    all;     /* the pick is empty: the whole download goes */
} LkNoaaRemoveAsk;

static void
lk_noaa_remove_ask_free (LkNoaaRemoveAsk *ask)
{
  g_clear_object (&ask->window);
  g_strfreev (ask->cells);
  g_strfreev (ask->regions);
  g_free (ask);
}

static void
lk_noaa_remove_answered (GObject *source, GAsyncResult *result, gpointer user_data)
{
  LkNoaaRemoveAsk *ask = user_data;
  g_autoptr (GError) error = NULL;
  int chosen = gtk_alert_dialog_choose_finish (GTK_ALERT_DIALOG (source), result, &error);

  /* Cancel is 0, Remove is 1. */
  if (chosen == 1)
    {
      LkNoaaWindow *self = ask->window != NULL
                               ? g_object_get_data (G_OBJECT (ask->window),
                                                    "lk-noaa-window")
                               : NULL;

      /* Out of the record as well, or the picker opens them ticked again and
       * reads as holding water it has just deleted. */
      lk_noaa_forget_downloaded (ask->noaa, (const char *const *) ask->regions);
      if (ask->all)
        lk_app_model_remove_noaa_download (ask->model);
      else
        lk_app_model_remove_noaa_cells (ask->model, (const char *const *) ask->cells);
      if (self != NULL && !gtk_widget_in_destruction (GTK_WIDGET (ask->window)))
        lk_noaa_window_fetch (self);
    }
  lk_noaa_remove_ask_free (ask);
}

static void
lk_noaa_window_download (GtkButton *button, gpointer user_data)
{
  LkNoaaWindow *self = user_data;
  g_auto (GStrv) doomed = lk_noaa_window_doomed (self, self->noaa);
  guint n = doomed != NULL ? g_strv_length (doomed) : 0;

  if (n == 0)
    {
      /* The pick dropped water whose every chart another district still picked
       * also covers, so there is none to delete. */
      g_auto (GStrv) dropped = lk_noaa_window_dropped (self, self->noaa);
      gboolean removes = dropped != NULL && g_strv_length (dropped) > 0;

      /* Drop the region from the record anyway. The picker ticks from the
       * record, so a region left in it opens ticked again on the next open.
       * No file is deleted, so no confirmation dialog appears
       * (apple/LookoutMarine/Charts/NoaaRegionList.swift, apply). */
      if (removes)
        lk_noaa_forget_downloaded (self->noaa, (const char *const *) dropped);

      if (removes && lk_noaa_cells (self->noaa) <= lk_noaa_held (self->noaa))
        {
          /* Show a message, so the press has a visible result. */
          GtkAlertDialog *none = gtk_alert_dialog_new ("Nothing to remove");

          gtk_alert_dialog_set_detail (
              none, "Every chart that water covers is also covered by a region "
                    "still picked, so removing it would delete none of them. The "
                    "water is off your pick.");
          gtk_alert_dialog_show (none, GTK_WINDOW (self->window));
          g_object_unref (none);
          /* Seed again from the record this press just wrote. The baseline
           * still named the dropped regions, so Apply stayed armed over a
           * press that had already done all it could. */
          self->seeded = FALSE;
          lk_noaa_window_seed (self, self->noaa);
          lk_noaa_window_sync (self->noaa, self->window);
          return;
        }
      lk_noaa_window_fetch (self);
      return;
    }

  /* Water taken out of the pick is water to delete, and a delete is asked
   * about before it runs. The charts go from the device. NOAA still has
   * them. */
  gboolean all = lk_noaa_picked_count (self->noaa) == 0;
  g_autofree char *question =
      all ? g_strdup_printf (n == 1 ? "Remove the %u NOAA chart on this device?"
                                    : "Remove all %u NOAA charts on this device?", n)
          : g_strdup_printf (n == 1 ? "Remove %u chart from this device?"
                                    : "Remove %u charts from this device?", n);
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

  LkNoaaRemoveAsk *ask = g_new0 (LkNoaaRemoveAsk, 1);
  ask->window = g_object_ref (GTK_WINDOW (self->window));
  ask->model = self->model;
  ask->noaa = self->noaa;
  ask->cells = g_steal_pointer (&doomed);
  ask->regions = lk_noaa_window_dropped (self, self->noaa);
  ask->all = lk_noaa_picked_count (self->noaa) == 0;
  gtk_alert_dialog_choose (dialog, GTK_WINDOW (self->window), NULL,
                           lk_noaa_remove_answered, ask);
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
  gtk_box_append (GTK_BOX (page), lk_coverage_map_new (noaa));
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

  /* What the picker needs before it can price anything: where the service
   * stands and what this device already holds.
   *
   * BOTH BEFORE THE HANDLER IS CONNECTED. The sync seeds the pick, and the
   * seed reads the per-region counts these calls recompute. Each call also
   * emits ::changed, so connecting first ran the seed on the counts the
   * FIRST of the two left: a picker opened after the charts had gone seeded
   * from a device that still held them, and opened ticked on water it had
   * deleted. */
  lk_noaa_poll (noaa);
  if (!lk_app_model_library_scanning (model))
    {
      g_auto (GStrv) have = lk_app_model_installed_cell_names (model);
      g_auto (GStrv) mine = lk_app_model_managed_cell_names (model);

      lk_noaa_note_installed (noaa, (const char *const *) have);
      lk_noaa_note_managed (noaa, (const char *const *) mine);
    }

  g_signal_connect_object (noaa, "changed", G_CALLBACK (lk_noaa_window_sync),
                           self->window, 0);
  lk_noaa_window_sync (noaa, self->window);

  lk_noaa_window = self->window;
  gtk_window_present (GTK_WINDOW (self->window));

  if (!lk_noaa_state (noaa)->have_catalog)
    lk_noaa_refresh (noaa);
}
