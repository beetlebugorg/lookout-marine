/* ui/firstrun/importing.c — the wait, while charts arrive and convert.
 *
 * A cell holds survey data rather than a drawn chart, so each one converts on
 * the way in. SETUP STAYS OPEN THROUGH IT, because the chart opens when the
 * import finishes: closing the card at Download left the mariner waiting on a
 * chart that had yet to open.
 *
 * The phases are named in the terms the core reports them: a NOAA run
 * downloads before it finds and imports, and a folder the mariner dropped
 * starts at finding.
 */
#include "ui/firstrun/private.h"

#include "library/bake.h"
#include "ui/charts/band-ramp.h"
#include "library/sets.h"
#include "library/noaa.h"

/* One phase of the work, and how far it has got. */
typedef enum { LK_PHASE_WAITING, LK_PHASE_ACTIVE, LK_PHASE_DONE } LkPhaseState;

static GtkWidget *
lk_phase_row (const char *title, const char *detail, LkPhaseState state)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 9);
  GtkWidget *mark = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  GtkWidget *name = gtk_label_new (title);
  GtkWidget *count = gtk_label_new (detail);

  gtk_widget_set_size_request (mark, 14, 14);
  gtk_widget_set_valign (mark, GTK_ALIGN_CENTER);
  if (state == LK_PHASE_ACTIVE)
    {
      GtkWidget *spinner = gtk_spinner_new ();

      gtk_spinner_set_spinning (GTK_SPINNER (spinner), TRUE);
      gtk_widget_set_size_request (spinner, 12, 12);
      gtk_box_append (GTK_BOX (mark), spinner);
    }
  else
    {
      GtkWidget *icon = gtk_image_new_from_icon_name (
          state == LK_PHASE_DONE ? "object-select-symbolic" : "radio-symbolic");

      gtk_image_set_pixel_size (GTK_IMAGE (icon), 12);
      gtk_widget_add_css_class (icon, state == LK_PHASE_DONE ? "lk-accent" : "dim-label");
      gtk_box_append (GTK_BOX (mark), icon);
    }

  if (state == LK_PHASE_ACTIVE)
    gtk_widget_add_css_class (name, "heading");
  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_widget_add_css_class (count, "dim-label");
  gtk_widget_add_css_class (count, "caption");
  gtk_widget_set_hexpand (count, TRUE);
  gtk_label_set_xalign (GTK_LABEL (count), 0.0);

  gtk_box_append (GTK_BOX (row), mark);
  gtk_box_append (GTK_BOX (row), name);
  gtk_box_append (GTK_BOX (row), count);
  if (state == LK_PHASE_WAITING)
    gtk_widget_set_opacity (row, 0.45);
  return row;
}

GtkWidget *
lk_first_run_importing_new (LkFirstRunFlow *flow)
{
  GtkWidget *step = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  const LkNoaaState *noaa = lk_noaa_state (lk_app_model_get_noaa (flow->model));
  const LkBakeProgress *bake = lk_app_model_get_bake_progress (flow->model);
  gboolean downloading = noaa->phase == LK_NOAA_DOWNLOADING;
  const char *regions = NULL;
  guint32 ordered = 0;
  guint64 bytes = 0;
  gboolean from_noaa = lk_first_run_order (flow->flow, &regions, &ordered, &bytes);

  GtkWidget *heading =
      lk_step_heading ("Preparing your charts",
                       "A cell holds survey data, not a drawn chart, so Lookout "
                       "converts each one on the way in. This happens once per set.");
  gtk_widget_set_margin_top (heading, 30);
  gtk_box_append (GTK_BOX (step), heading);

  /* What is being prepared, and what it cost. NOAA states both; a folder the
   * mariner dropped has neither, so it states what is known. */
  GtkWidget *name = gtk_label_new (from_noaa && regions[0] != '\0' ? regions
                                   : bake != NULL && bake->name != NULL ? bake->name
                                                                        : "Your charts");
  gtk_widget_add_css_class (name, "heading");
  gtk_label_set_xalign (GTK_LABEL (name), 0.0);
  gtk_label_set_ellipsize (GTK_LABEL (name), PANGO_ELLIPSIZE_MIDDLE);
  gtk_widget_set_margin_top (name, 24);
  gtk_box_append (GTK_BOX (step), name);

  g_autofree char *subtitle = NULL;
  if (from_noaa)
    {
      g_autofree char *size = lk_noaa_size_text (bytes);
      subtitle = g_strdup_printf ("NOAA · %u charts · %s", ordered, size);
    }
  else if (bake != NULL && bake->total > 0)
    subtitle = g_strdup_printf ("%d charts", bake->total);
  else
    subtitle = g_strdup ("Reading the folder");

  GtkWidget *under = gtk_label_new (subtitle);
  gtk_widget_add_css_class (under, "dim-label");
  gtk_widget_add_css_class (under, "caption");
  gtk_label_set_xalign (GTK_LABEL (under), 0.0);
  gtk_box_append (GTK_BOX (step), under);

  /* The bar. Determinate once something has counted the charts, and pulsing
   * until then: a dropped folder has no count until the scan finishes. */
  GtkWidget *bar = gtk_progress_bar_new ();
  int done = 0, total = 0;

  if (downloading)
    {
      done = (int) noaa->done;
      total = (int) noaa->total;
    }
  else if (bake != NULL)
    {
      done = bake->done;
      total = bake->total;
    }

  if (total > 0)
    gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (bar), (double) done / total);
  else
    gtk_progress_bar_pulse (GTK_PROGRESS_BAR (bar));
  gtk_widget_set_margin_top (bar, 16);
  gtk_box_append (GTK_BOX (step), bar);

  GtkWidget *numbers = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  g_autofree char *percent =
      total > 0 ? g_strdup_printf ("%d%%", (int) ((double) done / total * 100 + 0.5))
                : g_strdup ("");
  GtkWidget *left = gtk_label_new (percent);
  g_autofree char *remaining = bake != NULL ? lk_bake_progress_remaining (bake) : NULL;
  GtkWidget *right = gtk_label_new (remaining != NULL ? remaining : "");

  gtk_widget_add_css_class (left, "caption");
  gtk_widget_add_css_class (left, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (left), 0.0);
  gtk_widget_set_hexpand (left, TRUE);
  gtk_widget_add_css_class (right, "caption");
  gtk_widget_add_css_class (right, "dim-label");
  gtk_box_append (GTK_BOX (numbers), left);
  gtk_box_append (GTK_BOX (numbers), right);
  gtk_widget_set_margin_top (numbers, 8);
  gtk_box_append (GTK_BOX (step), numbers);

  /* The phases.
   *
   * With no bake reported yet, the two import phases have either not started
   * or already finished. Whether a bake has been SEEN tells them apart. */
  GtkWidget *phases = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
  gboolean pending = bake == NULL && !lk_first_run_saw_bake (flow->flow);
  gboolean finding = bake != NULL && bake->total == 0;
  gboolean importing = bake != NULL && !finding;

  if (from_noaa)
    {
      g_autofree char *detail =
          g_strdup_printf ("%u of %u", downloading ? noaa->done : ordered, ordered);

      gtk_box_append (GTK_BOX (phases),
                      lk_phase_row ("Downloading charts", detail,
                                    downloading ? LK_PHASE_ACTIVE : LK_PHASE_DONE));
    }

  g_autofree char *found =
      bake != NULL && bake->total > 0 ? g_strdup_printf ("%d found", bake->total)
                                      : g_strdup ("");
  gtk_box_append (GTK_BOX (phases),
                  lk_phase_row ("Finding charts", found,
                                downloading || pending ? LK_PHASE_WAITING
                                : finding              ? LK_PHASE_ACTIVE
                                                       : LK_PHASE_DONE));

  g_autofree char *counted =
      bake != NULL && bake->total > 0
          ? g_strdup_printf ("%d of %d", bake->done, bake->total)
          : g_strdup ("");
  gtk_box_append (GTK_BOX (phases),
                  lk_phase_row ("Importing charts", counted,
                                importing                                ? LK_PHASE_ACTIVE
                                : downloading || pending || finding      ? LK_PHASE_WAITING
                                                                         : LK_PHASE_DONE));
  gtk_widget_set_margin_top (phases, 18);
  gtk_box_append (GTK_BOX (step), phases);

  /* By band.
   *
   * lookout_bake_order runs the bake coarse band first, so the done count
   * says how far down that list it has reached. A mariner who stops part way
   * keeps charts that cover the whole passage. */
  GtkWidget *panel = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *panel_head = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);
  GtkWidget *panel_title = gtk_label_new ("By band");
  GtkWidget *panel_why =
      gtk_label_new ("Wide-area charts are prepared first, so stopping partway still "
                     "leaves charts that cover the whole passage.");

  gtk_widget_add_css_class (panel_title, "heading");
  gtk_label_set_xalign (GTK_LABEL (panel_title), 0.0);
  gtk_widget_add_css_class (panel_why, "dim-label");
  gtk_widget_add_css_class (panel_why, "caption");
  gtk_label_set_wrap (GTK_LABEL (panel_why), TRUE);
  gtk_label_set_xalign (GTK_LABEL (panel_why), 0.0);
  gtk_box_append (GTK_BOX (panel_head), panel_title);
  gtk_box_append (GTK_BOX (panel_head), panel_why);
  gtk_widget_set_margin_bottom (panel_head, 11);
  gtk_box_append (GTK_BOX (panel), panel_head);

  if (bake == NULL || bake->n_bands == 0)
    {
      GtkWidget *empty = gtk_label_new ("Counted once the folder has been read.");

      gtk_widget_add_css_class (empty, "dim-label");
      gtk_widget_add_css_class (empty, "caption");
      gtk_label_set_xalign (GTK_LABEL (empty), 0.0);
      gtk_box_append (GTK_BOX (panel), empty);
    }
  else
    {
      for (guint i = 0; i < bake->n_bands; i++)
        {
          const LkBakeBand *band = &bake->bands[i];
          GtkWidget *row = gtk_box_new (GTK_ORIENTATION_VERTICAL, 7);
          GtkWidget *head = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
          GtkWidget *swatch = gtk_drawing_area_new ();
          GtkWidget *name = gtk_label_new (lk_chart_band_name (band->band));
          gboolean complete = band->done >= band->total;
          gboolean waiting = band->done == 0;
          g_autofree char *detail =
              complete  ? g_strdup_printf ("%u charts", band->total)
              : waiting ? g_strdup_printf ("%u waiting", band->total)
                        : g_strdup_printf ("%u of %u", band->done, band->total);
          GtkWidget *count = gtk_label_new (detail);

          gtk_widget_set_size_request (swatch, 11, 11);
          gtk_widget_set_valign (swatch, GTK_ALIGN_CENTER);
          g_object_set_data (G_OBJECT (swatch), "lk-band", GINT_TO_POINTER (band->band));
          gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (swatch),
                                          lk_band_swatch_draw, NULL, NULL);

          if (!complete && !waiting)
            gtk_widget_add_css_class (name, "heading");
          gtk_label_set_xalign (GTK_LABEL (name), 0.0);
          gtk_widget_set_hexpand (name, TRUE);
          gtk_widget_add_css_class (count, "dim-label");
          gtk_widget_add_css_class (count, "caption");

          gtk_box_append (GTK_BOX (head), swatch);
          gtk_box_append (GTK_BOX (head), name);
          gtk_box_append (GTK_BOX (head), count);
          if (complete)
            {
              GtkWidget *tick = gtk_image_new_from_icon_name ("object-select-symbolic");

              gtk_image_set_pixel_size (GTK_IMAGE (tick), 11);
              gtk_widget_add_css_class (tick, "lk-accent");
              gtk_box_append (GTK_BOX (head), tick);
            }
          gtk_box_append (GTK_BOX (row), head);

          /* Only the band being worked shows a bar. A finished one has its
           * tick, and one still waiting has its count. */
          if (!complete && !waiting)
            {
              GtkWidget *bar = gtk_progress_bar_new ();

              gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (bar),
                                             band->total > 0
                                                 ? (double) band->done / band->total
                                                 : 0.0);
              gtk_widget_set_margin_start (bar, 21);
              gtk_box_append (GTK_BOX (row), bar);
            }

          gtk_widget_set_margin_top (row, 8);
          gtk_widget_set_margin_bottom (row, 8);
          if (waiting)
            gtk_widget_set_opacity (row, 0.45);
          gtk_box_append (GTK_BOX (panel), row);
        }
    }

  gtk_widget_add_css_class (panel, "lk-band-panel");
  gtk_widget_set_margin_top (panel, 20);
  gtk_box_append (GTK_BOX (step), panel);

  GtkWidget *note = gtk_label_new ("Lookout stores the prepared charts in its own "
                                   "folder and never writes to your download.");
  gtk_widget_add_css_class (note, "dim-label");
  gtk_widget_add_css_class (note, "caption");
  gtk_label_set_wrap (GTK_LABEL (note), TRUE);
  gtk_label_set_xalign (GTK_LABEL (note), 0.0);
  gtk_widget_set_margin_top (note, 18);
  gtk_box_append (GTK_BOX (step), note);

  gtk_widget_set_margin_start (step, 40);
  gtk_widget_set_margin_end (step, 40);
  gtk_widget_set_margin_bottom (step, 22);
  return step;
}
