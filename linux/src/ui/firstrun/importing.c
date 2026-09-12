/* ui/firstrun/importing.c — the wait, while charts arrive and convert.
 *
 * A cell holds survey data rather than a drawn chart, so each one converts on
 * the way in. SETUP STAYS OPEN THROUGH IT, because the chart opens when the
 * import finishes: closing the card at Download left the mariner waiting on a
 * chart that had yet to open.
 *
 * Two columns. On the left the phases, in the terms the core reports them: a
 * NOAA run downloads before it finds and imports, and a folder the mariner
 * dropped starts at finding. On the right the usage bands.
 * lookout_bake_order runs the bake coarse band first, so the bake's done count
 * says how far down that list it has reached.
 *
 * THE STEP UPDATES IN PLACE. The card is rebuilt when the flow moves, and the
 * bake reports several times a second, so a rebuild per report restarted the
 * spinner on every frame and the phases read as stopped. lk_first_run_flow
 * calls the sync below instead.
 */
#include "ui/firstrun/private.h"

#include "library/bake.h"
#include "ui/charts/band-ramp.h"
#include "library/sets.h"
#include "library/noaa.h"

/* The left column, in the reference's proportion: the phases beside the bands
 * rather than above them. */
#define LK_IMPORT_COLUMN 330

/* One phase of the work, and how far it has got. */
typedef enum { LK_PHASE_WAITING, LK_PHASE_ACTIVE, LK_PHASE_DONE } LkPhaseState;

/* All three marks are built once and one of them is shown, so a state change
 * costs no widgets. */
typedef struct {
  GtkWidget *row;
  GtkWidget *spin;
  GtkWidget *tick;
  GtkWidget *wait;
  GtkWidget *name;
  GtkWidget *count;
} LkPhaseRow;

typedef struct {
  LkFirstRunFlow *flow; /* not owned */

  GtkWidget *name;
  GtkWidget *under;
  GtkWidget *bar;
  GtkWidget *percent;
  GtkWidget *remaining;
  GtkWidget *bands;      /* the box the band rows go in */
  LkPhaseRow download;   /* built only for a NOAA run */
  LkPhaseRow find;
  LkPhaseRow import;
  gboolean   from_noaa;

  /* The last report with charts in it.
   *
   * The progress goes NULL the moment the bake ends, and this step outlives
   * it: the chart opens after the bake, and the flow moves on then. Reading
   * only the live report emptied the counts and the band list on the frame
   * the import finished. */
  LkBakeProgress last;
  LkBakeBand     last_bands[7];
  char          *last_name;
  gboolean       have_last;
} LkImporting;

static void
lk_importing_free (gpointer data)
{
  LkImporting *self = data;

  g_free (self->last_name);
  g_free (self);
}

/* ---- a phase row --------------------------------------------------------- */

static void
lk_phase_row_build (LkPhaseRow *row, const char *title)
{
  GtkWidget *mark = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);

  row->row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 9);
  row->spin = gtk_spinner_new ();
  row->tick = gtk_image_new_from_icon_name ("object-select-symbolic");
  row->wait = gtk_image_new_from_icon_name ("radio-symbolic");
  row->name = gtk_label_new (title);
  row->count = gtk_label_new ("");

  gtk_widget_set_size_request (mark, 14, 14);
  gtk_widget_set_valign (mark, GTK_ALIGN_CENTER);
  gtk_widget_set_size_request (row->spin, 12, 12);
  gtk_image_set_pixel_size (GTK_IMAGE (row->tick), 12);
  gtk_image_set_pixel_size (GTK_IMAGE (row->wait), 12);
  gtk_widget_add_css_class (row->tick, "lk-accent");
  gtk_widget_add_css_class (row->wait, "dim-label");
  gtk_box_append (GTK_BOX (mark), row->spin);
  gtk_box_append (GTK_BOX (mark), row->tick);
  gtk_box_append (GTK_BOX (mark), row->wait);

  gtk_label_set_xalign (GTK_LABEL (row->name), 0.0);
  gtk_widget_add_css_class (row->count, "dim-label");
  gtk_widget_add_css_class (row->count, "caption");
  gtk_widget_set_hexpand (row->count, TRUE);
  gtk_label_set_xalign (GTK_LABEL (row->count), 0.0);

  gtk_box_append (GTK_BOX (row->row), mark);
  gtk_box_append (GTK_BOX (row->row), row->name);
  gtk_box_append (GTK_BOX (row->row), row->count);
}

static void
lk_phase_row_set (LkPhaseRow *row, const char *detail, LkPhaseState state)
{
  if (row->row == NULL)
    return;

  gtk_label_set_text (GTK_LABEL (row->count), detail != NULL ? detail : "");
  gtk_widget_set_visible (row->spin, state == LK_PHASE_ACTIVE);
  gtk_spinner_set_spinning (GTK_SPINNER (row->spin), state == LK_PHASE_ACTIVE);
  gtk_widget_set_visible (row->tick, state == LK_PHASE_DONE);
  gtk_widget_set_visible (row->wait, state == LK_PHASE_WAITING);

  if (state == LK_PHASE_ACTIVE)
    gtk_widget_add_css_class (row->name, "heading");
  else
    gtk_widget_remove_css_class (row->name, "heading");
  gtk_widget_set_opacity (row->row, state == LK_PHASE_WAITING ? 0.45 : 1.0);
}

/* ---- the bands ----------------------------------------------------------- */

/* One band: its ramp color, its name, and how much of it is prepared. */
static GtkWidget *
lk_band_row_new (const LkBakeBand *band)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_VERTICAL, 7);
  GtkWidget *head = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *swatch = gtk_drawing_area_new ();
  GtkWidget *name = gtk_label_new (lk_chart_band_name (band->band));
  gboolean complete = band->done >= band->total;
  gboolean waiting = band->done == 0 && !complete;
  g_autofree char *detail = complete  ? g_strdup_printf ("%u charts", band->total)
                            : waiting ? g_strdup_printf ("%u waiting", band->total)
                                      : g_strdup_printf ("%u of %u", band->done, band->total);
  GtkWidget *count = gtk_label_new (detail);

  gtk_widget_set_size_request (swatch, 11, 11);
  gtk_widget_set_valign (swatch, GTK_ALIGN_CENTER);
  g_object_set_data (G_OBJECT (swatch), "lk-band", GINT_TO_POINTER (band->band));
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (swatch), lk_band_swatch_draw, NULL,
                                  NULL);

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

  /* Only the band being worked shows a bar. A finished one has its tick, and
   * one still waiting has its count. */
  if (!complete && !waiting)
    {
      GtkWidget *bar = gtk_progress_bar_new ();

      gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (bar),
                                     band->total > 0 ? (double) band->done / band->total
                                                     : 0.0);
      gtk_widget_set_margin_start (bar, 21);
      gtk_box_append (GTK_BOX (row), bar);
    }

  gtk_widget_set_margin_top (row, 8);
  gtk_widget_set_margin_bottom (row, 8);
  if (waiting)
    gtk_widget_set_opacity (row, 0.45);
  return row;
}

/* The band rows, rebuilt from the report. There are at most seven, and no
 * spinner among them, so a rebuild per report costs little. */
static void
lk_importing_fill_bands (LkImporting *self, const LkBakeProgress *work, gboolean running)
{
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (self->bands)) != NULL)
    gtk_box_remove (GTK_BOX (self->bands), child);

  if (work == NULL || work->n_bands == 0)
    {
      GtkWidget *empty = gtk_label_new ("Counted once the folder has been read.");

      gtk_widget_add_css_class (empty, "dim-label");
      gtk_widget_add_css_class (empty, "caption");
      gtk_label_set_xalign (GTK_LABEL (empty), 0.0);
      gtk_box_append (GTK_BOX (self->bands), empty);
      return;
    }

  for (guint i = 0; i < work->n_bands; i++)
    {
      LkBakeBand band = work->bands[i];

      /* A bake that has stopped has reached all of them. */
      if (!running)
        band.done = band.total;
      gtk_box_append (GTK_BOX (self->bands), lk_band_row_new (&band));
    }
}

/* ---- the numbers --------------------------------------------------------- */

/* Keep a report that has charts in it. The rescan after a bake reports no
 * total and no bands, which emptied the panel at the end. */
static void
lk_importing_remember (LkImporting *self, const LkBakeProgress *bake)
{
  guint n;

  if (bake == NULL || bake->total <= 0 || bake->n_bands == 0)
    return;

  n = MIN (bake->n_bands, G_N_ELEMENTS (self->last_bands));
  memcpy (self->last_bands, bake->bands, n * sizeof (LkBakeBand));
  g_free (self->last_name);
  self->last_name = g_strdup (bake->name);
  self->last = *bake;
  self->last.name = self->last_name;
  self->last.bands = self->last_bands;
  self->last.n_bands = n;
  self->have_last = TRUE;
}

void
lk_first_run_importing_sync (GtkWidget *step)
{
  LkImporting *self;
  const LkNoaaState *noaa;
  const LkBakeProgress *bake, *work;
  gboolean downloading, running, finding, importing, pending;
  const char *regions = NULL;
  guint32 ordered = 0;
  guint64 bytes = 0;
  int done = 0, total = 0;

  if (step == NULL)
    return;
  self = g_object_get_data (G_OBJECT (step), "lk-importing");
  if (self == NULL)
    return;

  noaa = lk_noaa_state (lk_app_model_get_noaa (self->flow->model));
  bake = lk_app_model_get_bake_progress (self->flow->model);
  lk_importing_remember (self, bake);
  work = bake != NULL ? bake : (self->have_last ? &self->last : NULL);
  running = bake != NULL;
  downloading = noaa->phase == LK_NOAA_DOWNLOADING;
  self->from_noaa = lk_first_run_order (self->flow->flow, &regions, &ordered, &bytes);

  /* What is being prepared, and what it cost. NOAA states both; a folder the
   * mariner dropped has neither, so the line states what is known. */
  gtk_label_set_text (GTK_LABEL (self->name),
                      self->from_noaa && regions[0] != '\0' ? regions
                      : work != NULL && work->name != NULL && work->name[0] != '\0'
                          ? work->name
                          : "Your charts");

  g_autofree char *subtitle = NULL;
  if (self->from_noaa)
    {
      g_autofree char *size = lk_noaa_size_text (bytes);

      subtitle = g_strdup_printf ("NOAA · %u charts · %s", ordered, size);
    }
  else if (work != NULL && work->total > 0)
    subtitle = g_strdup_printf ("%d charts", work->total);
  else
    subtitle = g_strdup ("Reading the folder");
  gtk_label_set_text (GTK_LABEL (self->under), subtitle);

  /* The bar. Determinate once something has counted the charts, and pulsing
   * until then: a dropped folder has no count until the scan finishes. A
   * finished bake stands at its total. */
  if (downloading)
    {
      done = (int) noaa->done;
      total = (int) noaa->total;
    }
  else if (work != NULL)
    {
      done = running ? work->done : work->total;
      total = work->total;
    }

  if (total > 0)
    gtk_progress_bar_set_fraction (GTK_PROGRESS_BAR (self->bar), (double) done / total);
  else
    gtk_progress_bar_pulse (GTK_PROGRESS_BAR (self->bar));

  g_autofree char *percent =
      total > 0 ? g_strdup_printf ("%d%%", (int) ((double) done / total * 100 + 0.5))
                : g_strdup ("");
  gtk_label_set_text (GTK_LABEL (self->percent), percent);

  g_autofree char *left = running ? lk_bake_progress_remaining (bake) : NULL;
  gtk_label_set_text (GTK_LABEL (self->remaining), left != NULL ? left : "");

  /* The phases.
   *
   * With no bake reported yet, the two import phases have either not started
   * or already finished. Whether a bake has been SEEN tells them apart. */
  pending = work == NULL && !lk_first_run_saw_bake (self->flow->flow);
  finding = running && bake->total == 0;
  importing = running && !finding;

  if (self->from_noaa)
    {
      g_autofree char *detail =
          g_strdup_printf ("%u of %u", downloading ? noaa->done : ordered, ordered);

      lk_phase_row_set (&self->download, detail,
                        downloading ? LK_PHASE_ACTIVE : LK_PHASE_DONE);
    }

  g_autofree char *found = work != NULL && work->total > 0
                               ? g_strdup_printf ("%d found", work->total)
                               : g_strdup ("");
  lk_phase_row_set (&self->find, found,
                    downloading || pending ? LK_PHASE_WAITING
                    : finding              ? LK_PHASE_ACTIVE
                                           : LK_PHASE_DONE);

  g_autofree char *counted =
      work != NULL && work->total > 0
          ? g_strdup_printf ("%d of %d", running ? work->done : work->total, work->total)
          : g_strdup ("");
  lk_phase_row_set (&self->import, counted,
                    importing                          ? LK_PHASE_ACTIVE
                    : downloading || pending || finding ? LK_PHASE_WAITING
                                                        : LK_PHASE_DONE);

  lk_importing_fill_bands (self, work, running);
}

/* ---- the step ------------------------------------------------------------ */

GtkWidget *
lk_first_run_importing_new (LkFirstRunFlow *flow)
{
  GtkWidget *step = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *columns = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 26);
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *phases = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
  GtkWidget *numbers = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  LkImporting *self = g_new0 (LkImporting, 1);
  const char *regions = NULL;
  guint32 ordered = 0;
  guint64 bytes = 0;

  self->flow = flow;
  self->from_noaa = lk_first_run_order (flow->flow, &regions, &ordered, &bytes);
  g_object_set_data_full (G_OBJECT (step), "lk-importing", self, lk_importing_free);

  GtkWidget *heading =
      lk_step_heading ("Preparing your charts",
                       "A cell holds survey data, not a drawn chart, so Lookout "
                       "converts each one on the way in. This happens once per set.");
  gtk_widget_set_margin_top (heading, 30);
  gtk_box_append (GTK_BOX (step), heading);

  /* ---- the left column: what is arriving, and how far in ---- */

  self->name = gtk_label_new ("");
  gtk_widget_add_css_class (self->name, "heading");
  gtk_label_set_xalign (GTK_LABEL (self->name), 0.0);
  gtk_label_set_ellipsize (GTK_LABEL (self->name), PANGO_ELLIPSIZE_MIDDLE);
  gtk_box_append (GTK_BOX (column), self->name);

  self->under = gtk_label_new ("");
  gtk_widget_add_css_class (self->under, "dim-label");
  gtk_widget_add_css_class (self->under, "caption");
  gtk_label_set_xalign (GTK_LABEL (self->under), 0.0);
  gtk_widget_set_margin_top (self->under, 3);
  gtk_box_append (GTK_BOX (column), self->under);

  self->bar = gtk_progress_bar_new ();
  gtk_widget_set_margin_top (self->bar, 16);
  gtk_box_append (GTK_BOX (column), self->bar);

  self->percent = gtk_label_new ("");
  self->remaining = gtk_label_new ("");
  gtk_widget_add_css_class (self->percent, "caption");
  gtk_widget_add_css_class (self->percent, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (self->percent), 0.0);
  gtk_widget_set_hexpand (self->percent, TRUE);
  gtk_widget_add_css_class (self->remaining, "caption");
  gtk_widget_add_css_class (self->remaining, "dim-label");
  gtk_box_append (GTK_BOX (numbers), self->percent);
  gtk_box_append (GTK_BOX (numbers), self->remaining);
  gtk_widget_set_margin_top (numbers, 8);
  gtk_box_append (GTK_BOX (column), numbers);

  if (self->from_noaa)
    {
      lk_phase_row_build (&self->download, "Downloading charts");
      gtk_box_append (GTK_BOX (phases), self->download.row);
    }
  lk_phase_row_build (&self->find, "Finding charts");
  gtk_box_append (GTK_BOX (phases), self->find.row);
  lk_phase_row_build (&self->import, "Importing charts");
  gtk_box_append (GTK_BOX (phases), self->import.row);
  gtk_widget_set_margin_top (phases, 18);
  gtk_box_append (GTK_BOX (column), phases);

  GtkWidget *note = gtk_label_new ("Lookout stores the prepared charts in its own "
                                   "folder and never writes to your download.");
  gtk_widget_add_css_class (note, "dim-label");
  gtk_widget_add_css_class (note, "caption");
  gtk_label_set_wrap (GTK_LABEL (note), TRUE);
  gtk_label_set_xalign (GTK_LABEL (note), 0.0);
  gtk_widget_set_margin_top (note, 18);
  gtk_box_append (GTK_BOX (column), note);

  gtk_widget_set_size_request (column, LK_IMPORT_COLUMN, -1);
  gtk_box_append (GTK_BOX (columns), column);

  /* ---- the right column: the bands ---- */

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

  self->bands = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_box_append (GTK_BOX (panel), self->bands);

  gtk_widget_add_css_class (panel, "lk-band-panel");
  gtk_widget_set_hexpand (panel, TRUE);
  gtk_widget_set_valign (panel, GTK_ALIGN_START);
  gtk_box_append (GTK_BOX (columns), panel);

  gtk_widget_set_margin_top (columns, 24);
  gtk_box_append (GTK_BOX (step), columns);

  gtk_widget_set_margin_start (step, 40);
  gtk_widget_set_margin_end (step, 40);
  gtk_widget_set_margin_bottom (step, 22);

  lk_first_run_importing_sync (step);
  return step;
}
