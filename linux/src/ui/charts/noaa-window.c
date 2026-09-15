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
} LkNoaaWindow;

/* One instance. A second ask raises the window that is already up. */
static GtkWidget *lk_noaa_window;

static void
lk_noaa_window_free (gpointer data)
{
  LkNoaaWindow *self = data;

  if (lk_noaa_window == self->window)
    lk_noaa_window = NULL;
  g_free (self);
}

/* The cost line and the Download button, from the pick.
 *
 * Water already held is fetched again rather than left behind a dead button.
 * It is how a mariner repairs a set, or takes the current edition of one NOAA
 * has reissued. */
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

  ready = state->have_catalog;
  picked = lk_noaa_picked_count (noaa) > 0;
  priced = ready && (lk_noaa_cells (noaa) > 0 || lk_noaa_held (noaa) > 0);

  if (priced)
    {
      g_autofree char *line = lk_noaa_cost_line (noaa);
      gtk_label_set_text (GTK_LABEL (self->cost), line);
    }
  else
    gtk_label_set_text (GTK_LABEL (self->cost), "");
  gtk_widget_set_visible (self->cost, priced);

  gtk_button_set_label (GTK_BUTTON (self->download),
                        lk_noaa_all_installed (noaa) ? "Download Again" : "Download");
  gtk_widget_set_sensitive (self->download, ready && picked);
}

static void
lk_noaa_window_download (GtkButton *button, gpointer user_data)
{
  LkNoaaWindow *self = user_data;

  lk_app_model_start_noaa_download (self->model, lk_noaa_all_installed (self->noaa));
  gtk_window_close (GTK_WINDOW (self->window));
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
                                    "waterway at no cost. Pick the water you sail.");

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
  self->download = gtk_button_new_with_label ("Download");

  gtk_widget_add_css_class (self->cost, "dim-label");
  gtk_widget_add_css_class (self->cost, "caption");
  gtk_label_set_xalign (GTK_LABEL (self->cost), 0.0);
  gtk_widget_set_hexpand (self->cost, TRUE);
  gtk_widget_add_css_class (self->download, "suggested-action");
  gtk_widget_add_css_class (self->download, "pill");
  gtk_widget_add_css_class (cancel, "pill");
  g_signal_connect (self->download, "clicked",
                    G_CALLBACK (lk_noaa_window_download), self);
  g_signal_connect (cancel, "clicked", G_CALLBACK (lk_noaa_window_cancel), self);

  gtk_box_append (GTK_BOX (footer), self->cost);
  gtk_box_append (GTK_BOX (footer), cancel);
  gtk_box_append (GTK_BOX (footer), self->download);
  gtk_widget_set_margin_top (footer, 12);
  gtk_widget_set_margin_bottom (footer, 12);
  gtk_widget_set_margin_start (footer, 18);
  gtk_widget_set_margin_end (footer, 18);
  gtk_box_append (GTK_BOX (root), footer);

  gtk_window_set_child (GTK_WINDOW (self->window), root);

  g_signal_connect_object (noaa, "changed", G_CALLBACK (lk_noaa_window_sync),
                           self->window, 0);
  lk_noaa_window_sync (noaa, self->window);

  lk_noaa_window = self->window;
  gtk_window_present (GTK_WINDOW (self->window));

  /* What the picker needs before it can price anything: where the service
   * stands, what this device already holds, and the catalog itself. */
  lk_noaa_poll (noaa);
  g_auto (GStrv) have = lk_app_model_installed_cell_names (model);
  lk_noaa_note_installed (noaa, (const char *const *) have);
  if (!lk_noaa_state (noaa)->have_catalog)
    lk_noaa_refresh (noaa);
}
