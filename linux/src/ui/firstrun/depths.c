/* ui/firstrun/depths.c — the depth settings, asked as two questions about the
 * boat.
 *
 * The step asks for a draft and a clearance under the keel. It derives the two
 * S-52 numbers the engine draws with, the safety depth and the safety contour,
 * and states what each one does to the chart.
 *
 * The engine is always given metres, so feet convert on the way out.
 */
#include "ui/firstrun/depths.h"

#include "ui/firstrun/water.h"

#include <math.h>

#define LK_FEET_PER_METRE 3.28084

/* The contours an S-57 survey draws. The safety contour is the first of these
 * at or past the safety depth, because the chart shades on a contour the
 * survey HAS. */
static const double lk_ladder_metres[] = { 2, 5, 10, 20, 30, 50, 75, 100 };
static const double lk_ladder_feet[] = { 6, 12, 18, 30, 60, 90, 120, 180, 240, 300 };

/* The clearances offered. Round in both units. */
static const double lk_clearances_metres[] = { 0.3, 0.6, 1, 1.5 };
static const double lk_clearances_feet[] = { 1, 2, 3, 5 };

const double *
lk_depth_ladder (gboolean feet, guint *out_n)
{
  if (out_n != NULL)
    *out_n = feet ? G_N_ELEMENTS (lk_ladder_feet) : G_N_ELEMENTS (lk_ladder_metres);
  return feet ? lk_ladder_feet : lk_ladder_metres;
}

const double *
lk_depth_clearances (gboolean feet, guint *out_n)
{
  if (out_n != NULL)
    *out_n = feet ? G_N_ELEMENTS (lk_clearances_feet)
                  : G_N_ELEMENTS (lk_clearances_metres);
  return feet ? lk_clearances_feet : lk_clearances_metres;
}

double
lk_depth_safety (double draft, double clearance)
{
  /* Rounded up to a whole foot or metre. A chart names its depths in whole
   * numbers, and the fraction belongs to the keel rather than to the water. */
  return ceil (draft + clearance);
}

double
lk_depth_contour (double safety, gboolean feet)
{
  guint n = 0;
  const double *ladder = lk_depth_ladder (feet, &n);

  for (guint i = 0; i < n; i++)
    if (ladder[i] >= safety)
      return ladder[i];
  return ladder[n - 1];
}

double
lk_depth_deep_contour (double contour, gboolean feet)
{
  guint n = 0;
  const double *ladder = lk_depth_ladder (feet, &n);
  double want = contour * 2;

  /* Twice the safety contour, up the same ladder, so it displays round. */
  for (guint i = 0; i < n; i++)
    if (ladder[i] >= want)
      return ladder[i];
  return ladder[n - 1];
}

double
lk_depth_nearest_clearance (double want, gboolean feet)
{
  guint n = 0;
  const double *all = lk_depth_clearances (feet, &n);
  double best = all[0];

  for (guint i = 1; i < n; i++)
    if (fabs (all[i] - want) < fabs (best - want))
      best = all[i];
  return best;
}

/* ---- the step ------------------------------------------------------------ */

/* The boat, in the unit on screen.
 *
 * Held in the unit on screen so every number displays round: a metric list
 * converted into feet gave a 4.9 ft clearance and a 16.4 ft contour. */
typedef struct {
  LkFirstRunFlow *flow;
  double          draft;
  double          clearance;

  GtkWidget *entry;
  GtkWidget *units;
  GtkWidget *pills;
  GtkWidget *derived;
  GtkWidget *water;
} LkDepthStep;

static void
lk_depth_step_free (gpointer data)
{
  g_free (data);
}

static gboolean
lk_depth_feet (LkDepthStep *step)
{
  return lk_mariner_raw (step->flow->mariner)->depth_unit == 1;
}

/* A depth on screen, with its unit on it. */
static char *
lk_depth_measure (LkDepthStep *step, double value)
{
  double rounded = round (value * 10) / 10;
  const char *unit = lk_depth_feet (step) ? "ft" : "m";

  if (rounded == round (rounded))
    return g_strdup_printf ("%d %s", (int) rounded, unit);
  return g_strdup_printf ("%.1f %s", rounded, unit);
}

/* Write the numbers the engine draws with.
 *
 * The shallow contour follows the safety depth, which makes the first shade
 * the water the boat cannot cross. */
static void
lk_depth_apply (LkDepthStep *step)
{
  tile57_mariner *mariner = lk_mariner_raw (step->flow->mariner);
  gboolean feet = lk_depth_feet (step);
  double safety = lk_depth_safety (step->draft, step->clearance);
  double contour = lk_depth_contour (safety, feet);
  double deep = lk_depth_deep_contour (contour, feet);
  double scale = feet ? 1.0 / LK_FEET_PER_METRE : 1.0;

  mariner->safety_depth = safety * scale;
  mariner->shallow_contour = safety * scale;
  mariner->safety_contour = contour * scale;
  mariner->deep_contour = deep * scale;
  mariner->four_shade_water = true;
  lk_mariner_touch (step->flow->mariner);
}

static void lk_depth_rebuild (LkDepthStep *step);

static void
lk_depth_entry_changed (GtkEntry *entry, gpointer user_data)
{
  LkDepthStep *step = user_data;
  const char *text = gtk_editable_get_text (GTK_EDITABLE (entry));
  double value = g_ascii_strtod (text, NULL);
  double cap = lk_depth_feet (step) ? 100 : 30;

  if (value > 0)
    step->draft = MIN (value, cap);
  lk_depth_apply (step);
  lk_depth_rebuild (step);
}

static void
lk_depth_unit_changed (GtkDropDown *drop, GParamSpec *pspec, gpointer user_data)
{
  LkDepthStep *step = user_data;
  tile57_mariner *mariner = lk_mariner_raw (step->flow->mariner);
  gboolean to_feet = gtk_drop_down_get_selected (drop) == 1;
  double factor;

  if ((mariner->depth_unit == 1) == to_feet)
    return;

  /* Convert the boat, and snap the clearance to one the new unit offers. */
  factor = to_feet ? LK_FEET_PER_METRE : 1.0 / LK_FEET_PER_METRE;
  mariner->depth_unit = to_feet ? 1 : 0;
  step->draft = round (step->draft * factor * 2) / 2;
  step->clearance = lk_depth_nearest_clearance (step->clearance * factor, to_feet);

  lk_depth_apply (step);
  lk_depth_rebuild (step);
}

static void
lk_depth_pill_clicked (GtkButton *button, gpointer user_data)
{
  LkDepthStep *step = user_data;
  const double *value = g_object_get_data (G_OBJECT (button), "lk-clearance");

  step->clearance = *value;
  lk_depth_apply (step);
  lk_depth_rebuild (step);
}

/* What the two answers come to, in the engine's own terms. */
static void
lk_depth_fill_derived (LkDepthStep *step)
{
  gboolean feet = lk_depth_feet (step);
  double safety = lk_depth_safety (step->draft, step->clearance);
  double contour = lk_depth_contour (safety, feet);
  double deep = lk_depth_deep_contour (contour, feet);
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (step->derived)) != NULL)
    gtk_box_remove (GTK_BOX (step->derived), child);

  g_autofree char *safety_text = lk_depth_measure (step, safety);
  g_autofree char *contour_text = lk_depth_measure (step, contour);
  g_autofree char *deep_text = lk_depth_measure (step, deep);
  g_autofree char *contour_why =
      g_strdup_printf ("Water shallower than this shades as unsafe. Rounded up to a "
                       "contour the survey draws, so %s reads as %s.",
                       safety_text, contour_text);

  struct { const char *name; const char *value; const char *why; } rows[] = {
    { "Safety depth", safety_text,
      "Soundings at or shallower than this print bold. It does not shade water." },
    { "Safety contour", contour_text, contour_why },
    { "Deep contour", deep_text,
      "Water deeper than this draws in the lightest shade. Twice the safety contour, "
      "up the same ladder the safety contour came off." },
  };

  for (gsize i = 0; i < G_N_ELEMENTS (rows); i++)
    {
      GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 5);
      GtkWidget *head = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
      GtkWidget *name = gtk_label_new (rows[i].name);
      GtkWidget *value = gtk_label_new (rows[i].value);
      GtkWidget *why = gtk_label_new (rows[i].why);

      gtk_widget_add_css_class (name, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (name), 0.0);
      gtk_widget_set_hexpand (name, TRUE);
      gtk_widget_add_css_class (value, "heading");
      gtk_box_append (GTK_BOX (head), name);
      gtk_box_append (GTK_BOX (head), value);

      gtk_widget_add_css_class (why, "dim-label");
      gtk_widget_add_css_class (why, "caption");
      gtk_label_set_wrap (GTK_LABEL (why), TRUE);
      gtk_label_set_xalign (GTK_LABEL (why), 0.0);

      gtk_box_append (GTK_BOX (box), head);
      gtk_box_append (GTK_BOX (box), why);
      gtk_widget_add_css_class (box, "lk-depth-row");
      gtk_box_append (GTK_BOX (step->derived), box);
    }
}

/* The clearance pills, with the chosen one marked. */
static void
lk_depth_fill_pills (LkDepthStep *step)
{
  gboolean feet = lk_depth_feet (step);
  guint n = 0;
  const double *all = lk_depth_clearances (feet, &n);
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (step->pills)) != NULL)
    gtk_box_remove (GTK_BOX (step->pills), child);

  for (guint i = 0; i < n; i++)
    {
      g_autofree char *text = lk_depth_measure (step, all[i]);
      GtkWidget *pill = gtk_button_new_with_label (text);
      double *value = g_new (double, 1);

      *value = all[i];
      gtk_widget_add_css_class (pill, "pill");
      if (fabs (all[i] - step->clearance) < 0.001)
        gtk_widget_add_css_class (pill, "suggested-action");
      g_object_set_data_full (G_OBJECT (pill), "lk-clearance", value, g_free);
      g_signal_connect (pill, "clicked", G_CALLBACK (lk_depth_pill_clicked), step);
      gtk_box_append (GTK_BOX (step->pills), pill);
    }
}

static void
lk_depth_rebuild (LkDepthStep *step)
{
  gboolean feet = lk_depth_feet (step);
  double safety = lk_depth_safety (step->draft, step->clearance);
  double contour = lk_depth_contour (safety, feet);

  lk_depth_fill_pills (step);
  lk_depth_fill_derived (step);
  if (step->water != NULL)
    lk_depth_water_set (step->water, safety, contour,
                        lk_depth_deep_contour (contour, feet), feet,
                        lk_mariner_raw (step->flow->mariner)->scheme);
  lk_first_run_refresh_footer (step->flow);
}

GtkWidget *
lk_first_run_depths_new (LkFirstRunFlow *flow)
{
  GtkWidget *body = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  LkDepthStep *step = g_new0 (LkDepthStep, 1);
  gboolean feet;
  static const char *const units[] = { "Metres", "Feet", NULL };

  step->flow = flow;
  g_object_set_data_full (G_OBJECT (body), "lk-depth-step", step, lk_depth_step_free);

  /* Start at a small keelboat. The stored safety depth is no help: it starts
   * at the engine's 10 m, and a draft read back out of that gives 9.7 m. */
  feet = lk_depth_feet (step);
  step->draft = feet ? 5.5 : 1.7;
  step->clearance = feet ? 2.0 : 0.6;

  GtkWidget *heading =
      lk_step_heading ("How deep does your boat sit?",
                       "Lookout shades water your boat cannot cross. It needs one "
                       "number to do that, and everything else follows from it.");
  gtk_widget_set_margin_top (heading, 34);
  gtk_box_append (GTK_BOX (body), heading);

  /* The draft, and the unit it is read in. */
  GtkWidget *draft_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 14);
  GtkWidget *draft_label = gtk_label_new ("Draft");
  g_autofree char *draft_text = g_strdup_printf ("%.1f", step->draft);

  step->entry = gtk_entry_new ();
  gtk_editable_set_text (GTK_EDITABLE (step->entry), draft_text);
  gtk_entry_set_input_purpose (GTK_ENTRY (step->entry), GTK_INPUT_PURPOSE_NUMBER);
  gtk_editable_set_width_chars (GTK_EDITABLE (step->entry), 7);
  g_signal_connect (step->entry, "changed", G_CALLBACK (lk_depth_entry_changed), step);

  step->units = gtk_drop_down_new_from_strings (units);
  gtk_drop_down_set_selected (GTK_DROP_DOWN (step->units), feet ? 1 : 0);
  g_signal_connect (step->units, "notify::selected",
                    G_CALLBACK (lk_depth_unit_changed), step);

  gtk_widget_add_css_class (draft_label, "heading");
  gtk_widget_set_size_request (draft_label, 62, -1);
  gtk_label_set_xalign (GTK_LABEL (draft_label), 0.0);
  gtk_box_append (GTK_BOX (draft_row), draft_label);
  gtk_box_append (GTK_BOX (draft_row), step->entry);
  gtk_box_append (GTK_BOX (draft_row), step->units);
  gtk_widget_set_margin_top (draft_row, 24);
  gtk_box_append (GTK_BOX (body), draft_row);

  GtkWidget *draft_why = gtk_label_new ("Deepest point of the hull below the "
                                        "waterline, keel included.");
  gtk_widget_add_css_class (draft_why, "dim-label");
  gtk_widget_add_css_class (draft_why, "caption");
  gtk_label_set_xalign (GTK_LABEL (draft_why), 0.0);
  gtk_label_set_wrap (GTK_LABEL (draft_why), TRUE);
  gtk_widget_set_margin_top (draft_why, 8);
  gtk_box_append (GTK_BOX (body), draft_why);

  /* The clearance. */
  GtkWidget *clearance_label = gtk_label_new ("Clearance under the keel");
  gtk_widget_add_css_class (clearance_label, "heading");
  gtk_label_set_xalign (GTK_LABEL (clearance_label), 0.0);
  gtk_widget_set_margin_top (clearance_label, 18);
  gtk_box_append (GTK_BOX (body), clearance_label);

  step->pills = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_set_margin_top (step->pills, 9);
  gtk_box_append (GTK_BOX (body), step->pills);

  GtkWidget *clearance_why =
      gtk_label_new ("How much water you want left under the keel at the shallowest "
                     "point of a passage.");
  gtk_widget_add_css_class (clearance_why, "dim-label");
  gtk_widget_add_css_class (clearance_why, "caption");
  gtk_label_set_xalign (GTK_LABEL (clearance_why), 0.0);
  gtk_label_set_wrap (GTK_LABEL (clearance_why), TRUE);
  gtk_widget_set_margin_top (clearance_why, 9);
  gtk_box_append (GTK_BOX (body), clearance_why);

  /* What it comes to. */
  step->derived = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_margin_top (step->derived, 16);
  gtk_box_append (GTK_BOX (body), step->derived);

  /* And what it does to a chart. */
  step->water = lk_depth_water_new ();
  gtk_widget_set_margin_top (step->water, 18);
  gtk_box_append (GTK_BOX (body), step->water);

  GtkWidget *warning = lk_step_warning (
      "Shading is not a depth sounder.",
      "Soundings are not corrected for tide, surge or squat, and a survey can be "
      "decades old. Keep your own margin.");
  gtk_widget_set_margin_top (warning, 18);
  gtk_box_append (GTK_BOX (body), warning);

  gtk_widget_set_margin_start (body, 48);
  gtk_widget_set_margin_end (body, 48);
  gtk_widget_set_margin_bottom (body, 22);

  lk_depth_apply (step);
  lk_depth_rebuild (step);
  return body;
}
