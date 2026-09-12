/* ui/firstrun/flow.c — the step on screen, and the action under it.
 *
 * See ui/firstrun/flow.h. The card scrolls its step and keeps its footer: a
 * step taller than the window must still be reachable.
 */
#include "ui/firstrun/flow.h"
#include "ui/firstrun/private.h"

#include "library/noaa.h"
#include "ui/open-dialogs.h"

/* The view setup frames behind itself: the lower 48, the ground the coverage
 * step is picked from. */
#define LK_FIRST_RUN_VIEW_LON -96.0
#define LK_FIRST_RUN_VIEW_LAT  38.0
#define LK_FIRST_RUN_VIEW_ZOOM  5.0

static void lk_first_run_rebuild (LkFirstRunFlow *self);

static void
lk_first_run_flow_free (gpointer data)
{
  LkFirstRunFlow *self = data;

  g_clear_object (&self->flow);
  g_clear_object (&self->mariner);
  g_free (self);
}

/* ---- the action under the step ------------------------------------------- */

/* Frame the country behind setup, so the chart under the card shows the
 * coastline the mariner is choosing from.
 *
 * United States charts label depths in feet, and setup is the one moment the
 * unit can be chosen before the first sounding draws. */
static void
lk_first_run_frame_country (LkFirstRunFlow *self)
{
  LkChartController *controller = lk_app_model_get_controller (self->model);
  lookout_view view = { .lon = LK_FIRST_RUN_VIEW_LON,
                        .lat = LK_FIRST_RUN_VIEW_LAT,
                        .zoom = LK_FIRST_RUN_VIEW_ZOOM,
                        .rotation_deg = 0 };
  tile57_mariner mariner;

  if (!lk_chart_controller_is_open (controller))
    return;

  lk_chart_controller_set_view (controller, view);
  mariner = lk_chart_controller_get_mariner (controller);
  mariner.depth_unit = (tile57_depth_unit) 1; /* feet */
  lk_chart_controller_set_mariner (controller, mariner);
}

/* What the mariner asked NOAA for, kept from the moment they asked. */
static void
lk_first_run_place_order (LkFirstRunFlow *self)
{
  LkNoaa *noaa = lk_app_model_get_noaa (self->model);
  guint n = 0;
  const LkNoaaRegion *regions = lk_noaa_regions (noaa, &n);
  g_autoptr (GString) names = g_string_new (NULL);
  gboolean again = lk_noaa_all_installed (noaa);

  for (guint i = 0; i < n; i++)
    {
      if (!lk_noaa_is_picked (noaa, regions[i].id))
        continue;
      if (names->len > 0)
        g_string_append (names, ", ");
      g_string_append (names, regions[i].name);
    }

  lk_first_run_set_order (self->flow, names->str,
                          again ? lk_noaa_held (noaa) : lk_noaa_cells (noaa),
                          again ? lk_noaa_held_bytes (noaa) : lk_noaa_bytes (noaa));
  lk_app_model_start_noaa_download (self->model, again);
}

static void
lk_first_run_primary_clicked (GtkButton *button, gpointer user_data)
{
  LkFirstRunFlow *self = user_data;
  LkFirstRunSource source;

  if (!lk_first_run_advance (self->flow, &source))
    return;

  /* The flow has finished asking. The shell does the part it cannot. */
  switch (source)
    {
    case LK_FIRST_RUN_FILES:
      {
        GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));

        lk_present_open_chart_dialog (GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL,
                                      self->model);
        break;
      }
    case LK_FIRST_RUN_NOAA:
      lk_first_run_place_order (self);
      break;
    case LK_FIRST_RUN_ONLINE_CHART:
      break; /* the chart the mariner picked is already drawing */
    }
}

static void
lk_first_run_back_clicked (GtkButton *button, gpointer user_data)
{
  lk_first_run_back (((LkFirstRunFlow *) user_data)->flow);
}

static void
lk_first_run_later_clicked (GtkButton *button, gpointer user_data)
{
  lk_first_run_finish (((LkFirstRunFlow *) user_data)->flow);
}

/* Stop the download and the bake. Whatever landed stays: a cancelled bake
 * still leaves a library, and the bake runs coarse band first. */
static void
lk_first_run_stop_clicked (GtkButton *button, gpointer user_data)
{
  LkFirstRunFlow *self = user_data;

  lk_noaa_cancel (lk_app_model_get_noaa (self->model));
  lk_app_model_cancel_bake (self->model);
}

/* ---- the footer ---------------------------------------------------------- */

/* True once the charts have arrived, converted, and opened. */
static gboolean
lk_first_run_import_finished (LkFirstRunFlow *self)
{
  const LkNoaaState *noaa = lk_noaa_state (lk_app_model_get_noaa (self->model));

  return lk_first_run_saw_bake (self->flow) &&
         noaa->phase != LK_NOAA_DOWNLOADING &&
         !lk_app_model_get_baking (self->model) &&
         !lk_app_model_get_nothing_to_draw (self->model);
}

/* Whether the primary action has anything to do. */
static gboolean
lk_first_run_primary_ready (LkFirstRunFlow *self)
{
  LkNoaa *noaa = lk_app_model_get_noaa (self->model);

  switch (lk_first_run_step (self->flow))
    {
    case LK_FIRST_RUN_COVERAGE:
      /* Download with no region picked, and with no catalog to price it from,
       * does nothing. */
      return lk_noaa_state (noaa)->have_catalog && lk_noaa_picked_count (noaa) > 0;
    case LK_FIRST_RUN_IMPORTING:
      /* The library opens when the import finishes, so there is nothing to
       * continue to until it has. */
      return lk_first_run_import_finished (self);
    default:
      return TRUE;
    }
}

/* The line beside the primary action. */
static char *
lk_first_run_footnote (LkFirstRunFlow *self)
{
  LkNoaa *noaa = lk_app_model_get_noaa (self->model);
  LkChartLinks *links = lk_app_model_get_chart_links (self->model);

  switch (lk_first_run_step (self->flow))
    {
    case LK_FIRST_RUN_COVERAGE:
      if (!lk_noaa_state (noaa)->have_catalog)
        return NULL;
      /* Held counts as picked, so a region wholly installed prices as that
       * rather than reading as an empty pick. */
      if (lk_noaa_cells (noaa) == 0 && lk_noaa_held (noaa) == 0)
        return g_strdup ("Pick at least one region.");
      return lk_noaa_cost_line (noaa);

    case LK_FIRST_RUN_DEPTHS:
      return g_strdup ("Change any of this later in Mariner settings, in Depths.");

    case LK_FIRST_RUN_ONLINE:
      {
        /* The publisher's credit, and the thing a mariner about to pick a link
         * most wants to know: their own charts are still there. An install
         * with no charts has none to reassure them about. */
        const char *credit = lk_chart_links_attribution (links);
        gboolean own = !lk_app_model_get_nothing_to_draw (self->model);

        if (credit[0] != '\0' && own)
          return g_strdup_printf ("%s · installed charts stay installed", credit);
        if (credit[0] != '\0')
          return g_strdup (credit);
        return own ? g_strdup ("Installed charts stay installed.") : NULL;
      }

    default:
      return NULL;
    }
}

void
lk_first_run_refresh_footer (LkFirstRunFlow *self)
{
  LkFirstRunStep step = lk_first_run_step (self->flow);
  g_autofree char *note = lk_first_run_footnote (self);
  const char *chosen = NULL;
  g_autofree char *use = NULL;

  if (step == LK_FIRST_RUN_ONLINE)
    {
      LkChartLinks *links = lk_app_model_get_chart_links (self->model);
      const char *active = lk_chart_links_active (links);
      GPtrArray *all = lk_chart_links_list (links);

      for (guint i = 0; active != NULL && i < all->len; i++)
        {
          const LkChartLink *link = g_ptr_array_index (all, i);

          if (g_strcmp0 (link->url, active) == 0)
            {
              use = g_strdup_printf ("Use %s", link->name);
              chosen = use;
              break;
            }
        }
    }

  gtk_button_set_label (GTK_BUTTON (self->primary),
                        lk_first_run_primary_title (self->flow, chosen));
  gtk_widget_set_sensitive (self->primary, lk_first_run_primary_ready (self));

  gtk_label_set_text (GTK_LABEL (self->footnote), note != NULL ? note : "");
  gtk_widget_set_visible (self->footnote, note != NULL);

  /* Set Up Later stands on the welcome step alone: past it the mariner is
   * choosing a chart, and Back is what returns them. */
  gtk_widget_set_visible (self->later, step == LK_FIRST_RUN_WELCOME);
  /* Stop applies while the transfer or the bake runs. After that it stood
   * beside Continue with no job to stop. */
  gtk_widget_set_visible (self->stop,
                          step == LK_FIRST_RUN_IMPORTING &&
                              !lk_first_run_import_finished (self));
  gtk_widget_set_visible (self->back,
                          lk_first_run_can_go_back (self->flow) &&
                              !gtk_widget_get_visible (self->stop));
}

/* ---- the card ------------------------------------------------------------ */

static GtkWidget *
lk_first_run_step_body (LkFirstRunFlow *self)
{
  switch (lk_first_run_step (self->flow))
    {
    case LK_FIRST_RUN_WELCOME:   return lk_first_run_welcome_new (self);
    case LK_FIRST_RUN_SOURCE:    return lk_first_run_source_new (self);
    case LK_FIRST_RUN_COVERAGE:  return lk_first_run_coverage_new (self);
    case LK_FIRST_RUN_ONLINE:    return lk_first_run_online_new (self);
    case LK_FIRST_RUN_IMPORTING: return lk_first_run_importing_new (self);
    case LK_FIRST_RUN_DEPTHS:    return lk_first_run_depths_new (self);
    default:                     return gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
    }
}

/* Which footer shape this step takes. The primary action stands in one of the
 * two containers, so it moves between them. */
static void
lk_first_run_footer_shape (LkFirstRunFlow *self, gboolean centered)
{
  if (self->centered == centered)
    return;
  self->centered = centered;

  /* The container holds the only reference while the button is parented. */
  g_object_ref (self->primary);
  if (centered)
    {
      gtk_box_remove (GTK_BOX (self->actions), self->primary);
      gtk_box_prepend (GTK_BOX (self->column), self->primary);
      gtk_widget_set_size_request (self->primary, 300, -1);
    }
  else
    {
      gtk_box_remove (GTK_BOX (self->column), self->primary);
      gtk_box_append (GTK_BOX (self->actions), self->primary);
      gtk_widget_set_size_request (self->primary, -1, -1);
    }
  g_object_unref (self->primary);

  gtk_widget_set_visible (self->bar, !centered);
  gtk_widget_set_visible (self->column, centered);
}

/* Put the step on the card, size the card to it, and read the footer again. */
static void
lk_first_run_rebuild (LkFirstRunFlow *self)
{
  LkFirstRunStep step = lk_first_run_step (self->flow);
  GtkWidget *child;

  gtk_widget_set_visible (self->page, lk_first_run_showing (self->flow));

  /* The step goes with the card. A step holds a chart picture, a map of the
   * United States and a second render engine between them, and none of that
   * is worth keeping for a flow the mariner has put away. */
  while ((child = gtk_widget_get_first_child (self->body)) != NULL)
    gtk_box_remove (GTK_BOX (self->body), child);

  if (!lk_first_run_showing (self->flow))
    return;
  gtk_box_append (GTK_BOX (self->body), lk_first_run_step_body (self));

  gtk_widget_set_size_request (self->card, lk_first_run_sheet_width (step), -1);
  lk_first_run_footer_shape (self, step == LK_FIRST_RUN_WELCOME);
  lk_first_run_refresh_footer (self);
}

static void
lk_first_run_changed (LkFirstRun *flow, gpointer user_data)
{
  GtkWidget *page = user_data;
  LkFirstRunFlow *self = g_object_get_data (G_OBJECT (page), "lk-first-run");

  if (self == NULL || gtk_widget_in_destruction (page))
    return;
  lk_first_run_rebuild (self);
}

/* Anything the app does that the footer reads: a catalog landing, a transfer
 * moving, a bake starting or ending, a chart opening. */
static void
lk_first_run_app_moved (GtkWidget *page)
{
  LkFirstRunFlow *self = g_object_get_data (G_OBJECT (page), "lk-first-run");

  if (self == NULL || gtk_widget_in_destruction (page))
    return;
  if (!lk_first_run_showing (self->flow))
    return;

  if (lk_app_model_get_baking (self->model))
    lk_first_run_note_bake (self->flow);

  /* The import step reads the bake several times a second. It updates the
   * step on the card rather than building a new one. */
  if (lk_first_run_step (self->flow) == LK_FIRST_RUN_IMPORTING)
    lk_first_run_importing_sync (gtk_widget_get_first_child (self->body));
  lk_first_run_refresh_footer (self);
}

/* Two shapes reach the same place: a plain ::changed carries the subject, and
 * a ::notify carries the property between it and the data. */
static void
lk_first_run_subject_moved (gpointer subject, gpointer user_data)
{
  lk_first_run_app_moved (GTK_WIDGET (user_data));
}

static void
lk_first_run_property_moved (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  lk_first_run_app_moved (GTK_WIDGET (user_data));
}

GtkWidget *
lk_first_run_page_new (LkAppModel *model)
{
  LkFirstRunFlow *self;
  GtkWidget *page, *card, *footer, *actions;

  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  self = g_new0 (LkFirstRunFlow, 1);
  self->model = model;
  self->flow = lk_first_run_new ();
  /* The depth step's own mariner. Setup runs before the settings window has
   * ever been opened, and it binds to the chart the same way that window
   * does. */
  self->mariner = lk_mariner_new (lk_app_model_get_controller (model));

  /* The card: the step above, the action below. */
  card = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_add_css_class (card, "lk-first-run-card");
  gtk_widget_set_valign (card, GTK_ALIGN_CENTER);
  self->card = card;

  /* The card is as tall as its step and no taller. The step's own content
   * still distributes any slack inside itself, which is what puts the mark at
   * the bottom of a row of cards of unequal length. */
  self->body = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_box_append (GTK_BOX (card), self->body);

  footer = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  self->bar = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_widget_add_css_class (self->bar, "lk-first-run-footer");

  self->footnote = gtk_label_new ("");
  gtk_widget_add_css_class (self->footnote, "dim-label");
  gtk_widget_add_css_class (self->footnote, "caption");
  gtk_label_set_xalign (GTK_LABEL (self->footnote), 0.0);
  gtk_label_set_wrap (GTK_LABEL (self->footnote), TRUE);
  gtk_widget_set_hexpand (self->footnote, TRUE);
  gtk_box_append (GTK_BOX (self->bar), self->footnote);

  actions = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  self->later = gtk_button_new_with_label ("Set Up Later");
  self->back = gtk_button_new_with_label ("Back");
  self->stop = gtk_button_new_with_label ("Stop");
  self->primary = gtk_button_new_with_label ("Continue");

  gtk_button_set_has_frame (GTK_BUTTON (self->later), FALSE);
  gtk_widget_add_css_class (self->later, "lk-accent");
  gtk_widget_add_css_class (self->back, "pill");
  gtk_widget_add_css_class (self->stop, "pill");
  gtk_widget_add_css_class (self->primary, "suggested-action");
  gtk_widget_add_css_class (self->primary, "pill");

  g_signal_connect (self->later, "clicked", G_CALLBACK (lk_first_run_later_clicked), self);
  g_signal_connect (self->back, "clicked", G_CALLBACK (lk_first_run_back_clicked), self);
  g_signal_connect (self->stop, "clicked", G_CALLBACK (lk_first_run_stop_clicked), self);
  g_signal_connect (self->primary, "clicked",
                    G_CALLBACK (lk_first_run_primary_clicked), self);

  gtk_box_append (GTK_BOX (actions), self->back);
  gtk_box_append (GTK_BOX (actions), self->stop);
  gtk_box_append (GTK_BOX (actions), self->primary);
  /* The actions hold the right end of the bar, with or without a footnote
   * beside them. A hidden footnote takes no width and no expansion, which
   * left Back and Continue at the left edge of the card. */
  gtk_widget_set_hexpand (actions, TRUE);
  gtk_widget_set_halign (actions, GTK_ALIGN_END);
  self->actions = actions;
  gtk_box_append (GTK_BOX (self->bar), actions);
  gtk_box_append (GTK_BOX (footer), self->bar);

  self->column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 14);
  gtk_widget_add_css_class (self->column, "lk-first-run-choice");
  gtk_widget_set_halign (self->column, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (self->column), self->later);
  gtk_widget_set_visible (self->column, FALSE);
  gtk_box_append (GTK_BOX (footer), self->column);
  gtk_box_append (GTK_BOX (card), footer);

  /* A step taller than the window must still be reachable, so the card
   * scrolls. valign FILL, not CENTER: an overlay child that is not FILL is
   * allocated its NATURAL height, and a card taller than the window is then
   * centred and clipped at both ends with no way to scroll to what it cut,
   * because the scroller believes it fits. */
  page = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (page), card);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (page),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  /* Do NOT propagate the natural width: a wrapping label reports its
   * UNWRAPPED text as its natural width, which would run the card the whole
   * width of the window instead of the step's own. */
  gtk_scrolled_window_set_propagate_natural_width (GTK_SCROLLED_WINDOW (page), FALSE);
  gtk_widget_set_halign (page, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (page, GTK_ALIGN_FILL);
  gtk_widget_set_margin_top (page, 16);
  gtk_widget_set_margin_bottom (page, 16);
  gtk_widget_set_visible (page, FALSE);

  self->page = page;
  g_object_set_data_full (G_OBJECT (page), "lk-first-run", self, lk_first_run_flow_free);

  g_signal_connect_object (self->flow, "changed",
                           G_CALLBACK (lk_first_run_changed), page, 0);
  /* The footer reads the app as well as the flow. */
  g_signal_connect_object (lk_app_model_get_noaa (model), "changed",
                           G_CALLBACK (lk_first_run_subject_moved), page, 0);
  g_signal_connect_object (lk_app_model_get_chart_links (model), "changed",
                           G_CALLBACK (lk_first_run_subject_moved), page, 0);
  g_signal_connect_object (model, "chart-sets-changed",
                           G_CALLBACK (lk_first_run_subject_moved), page, 0);
  g_signal_connect_object (model, "notify::baking",
                           G_CALLBACK (lk_first_run_property_moved), page, 0);
  g_signal_connect_object (model, "notify::has-chart",
                           G_CALLBACK (lk_first_run_property_moved), page, 0);

  return page;
}

void
lk_first_run_consider (GtkWidget *page)
{
  LkFirstRunFlow *self;
  LkChartLinks *links;

  g_return_if_fail (GTK_IS_WIDGET (page));

  self = g_object_get_data (G_OBJECT (page), "lk-first-run");
  if (self == NULL || lk_first_run_showing (self->flow))
    return;

  links = lk_app_model_get_chart_links (self->model);
  if (!lk_first_run_should_run (self->flow,
                               lk_app_model_get_nothing_to_draw (self->model),
                               lk_chart_links_active (links) != NULL))
    return;

  /* Read the chart's mariner BEFORE the flow starts. Beginning it builds the
   * first step, and the depth step writes the unit it asks in; a reload after
   * that put the engine's own value back under the step. */
  lk_mariner_reload (self->mariner);
  lk_first_run_begin (self->flow);
  lk_first_run_frame_country (self);
}

gboolean
lk_first_run_page_showing (GtkWidget *page)
{
  LkFirstRunFlow *self;

  g_return_val_if_fail (GTK_IS_WIDGET (page), FALSE);

  self = g_object_get_data (G_OBJECT (page), "lk-first-run");
  return self != NULL && lk_first_run_showing (self->flow);
}
