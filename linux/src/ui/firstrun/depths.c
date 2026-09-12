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

/* The left column, in the reference's proportion: the boat beside the water
 * rather than above it. */
#define LK_DEPTH_COLUMN 334

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
  GtkWidget *metres;   /* the two unit toggles, one group */
  GtkWidget *feet;
  GtkWidget *pills;
  GtkWidget *derived;
  GtkWidget *water;

  /* TRUE while the step writes its own widgets. The draft field and the unit
   * toggles both report a change the step has just made, and reading it back
   * converted the boat a second time. */
  gboolean   busy;
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

/* The draft alone, for the field, with no unit on it. */
static void
lk_depth_show_draft (LkDepthStep *step)
{
  double rounded = round (step->draft * 10) / 10;
  g_autofree char *text = rounded == round (rounded)
                              ? g_strdup_printf ("%d", (int) rounded)
                              : g_strdup_printf ("%.1f", rounded);

  if (g_strcmp0 (gtk_editable_get_text (GTK_EDITABLE (step->entry)), text) == 0)
    return;

  step->busy = TRUE;
  gtk_editable_set_text (GTK_EDITABLE (step->entry), text);
  step->busy = FALSE;
}

static void
lk_depth_entry_changed (GtkEntry *entry, gpointer user_data)
{
  LkDepthStep *step = user_data;
  const char *text = gtk_editable_get_text (GTK_EDITABLE (entry));
  double value = g_ascii_strtod (text, NULL);
  double cap = lk_depth_feet (step) ? 100 : 30;

  /* An empty field is a number half typed. The step holds the last draft it
   * read and waits. */
  if (step->busy || value <= 0)
    return;

  step->draft = MIN (value, cap);
  lk_depth_apply (step);
  lk_depth_rebuild (step);
}

static void
lk_depth_unit_toggled (GtkToggleButton *button, gpointer user_data)
{
  LkDepthStep *step = user_data;
  tile57_mariner *mariner = lk_mariner_raw (step->flow->mariner);
  gboolean to_feet = gtk_toggle_button_get_active (GTK_TOGGLE_BUTTON (step->feet));
  double factor;

  if (step->busy || (mariner->depth_unit == 1) == to_feet)
    return;

  /* Convert the boat, and snap the clearance to one the new unit offers. A
   * draft the mariner typed in one unit is the same boat in the other. */
  factor = to_feet ? LK_FEET_PER_METRE : 1.0 / LK_FEET_PER_METRE;
  mariner->depth_unit = to_feet ? 1 : 0;
  step->draft = round (step->draft * factor * 2) / 2;
  step->clearance = lk_depth_nearest_clearance (step->clearance * factor, to_feet);

  lk_depth_show_draft (step);
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

  /* The toggles, and NOT the draft field: writing the field from here fought
   * the mariner's own typing. Clearing it put the old number back mid-edit,
   * and the digits that followed landed on the end of that. The unit change
   * writes the field itself, because there the number is the step's. */
  step->busy = TRUE;
  gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON (feet ? step->feet : step->metres), TRUE);
  step->busy = FALSE;
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
  GtkWidget *columns = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 26);
  GtkWidget *boat = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  LkDepthStep *step = g_new0 (LkDepthStep, 1);
  tile57_mariner *mariner = lk_mariner_raw (flow->mariner);
  gboolean feet;

  step->flow = flow;
  g_object_set_data_full (G_OBJECT (body), "lk-depth-step", step, lk_depth_step_free);

  /* Setup asks in feet. The engine's own default is metres, and these charts
   * are sailed where a boat is measured in feet. The unit is the mariner's
   * from the second time the step is built, so switching it holds. */
  if (!lk_first_run_asked_depths (flow->flow) && mariner->depth_unit != 1)
    {
      mariner->depth_unit = 1;
      lk_mariner_touch (flow->mariner);
    }

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

  /* ---- the left column: the boat ---- */

  GtkWidget *draft_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 14);
  GtkWidget *draft_label = gtk_label_new ("Draft");

  step->entry = gtk_entry_new ();
  gtk_entry_set_input_purpose (GTK_ENTRY (step->entry), GTK_INPUT_PURPOSE_NUMBER);
  gtk_entry_set_alignment (GTK_ENTRY (step->entry), 1.0);
  gtk_editable_set_width_chars (GTK_EDITABLE (step->entry), 7);
  g_signal_connect (step->entry, "changed", G_CALLBACK (lk_depth_entry_changed), step);

  gtk_widget_add_css_class (draft_label, "heading");
  gtk_widget_set_size_request (draft_label, 62, -1);
  gtk_label_set_xalign (GTK_LABEL (draft_label), 0.0);
  gtk_box_append (GTK_BOX (draft_row), draft_label);
  gtk_box_append (GTK_BOX (draft_row), step->entry);
  gtk_box_append (GTK_BOX (boat), draft_row);

  /* The unit, under the field it reads. Two linked toggles, which is the
   * shape a segmented picker has. */
  GtkWidget *unit_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 14);
  GtkWidget *unit_label = gtk_label_new ("Units");
  GtkWidget *unit_group = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);

  step->metres = gtk_toggle_button_new_with_label ("Metres");
  step->feet = gtk_toggle_button_new_with_label ("Feet");
  gtk_toggle_button_set_group (GTK_TOGGLE_BUTTON (step->feet),
                               GTK_TOGGLE_BUTTON (step->metres));
  gtk_toggle_button_set_active (GTK_TOGGLE_BUTTON (feet ? step->feet : step->metres),
                                TRUE);
  g_signal_connect (step->metres, "toggled", G_CALLBACK (lk_depth_unit_toggled), step);
  g_signal_connect (step->feet, "toggled", G_CALLBACK (lk_depth_unit_toggled), step);

  gtk_widget_add_css_class (unit_group, "linked");
  gtk_box_append (GTK_BOX (unit_group), step->metres);
  gtk_box_append (GTK_BOX (unit_group), step->feet);
  gtk_widget_set_halign (unit_group, GTK_ALIGN_START);

  gtk_widget_add_css_class (unit_label, "dim-label");
  gtk_widget_set_size_request (unit_label, 62, -1);
  gtk_label_set_xalign (GTK_LABEL (unit_label), 0.0);
  gtk_widget_set_valign (unit_label, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (unit_row), unit_label);
  gtk_box_append (GTK_BOX (unit_row), unit_group);
  gtk_widget_set_margin_top (unit_row, 9);
  gtk_box_append (GTK_BOX (boat), unit_row);

  GtkWidget *draft_why = gtk_label_new ("Deepest point of the hull below the "
                                        "waterline, keel included.");
  gtk_widget_add_css_class (draft_why, "dim-label");
  gtk_widget_add_css_class (draft_why, "caption");
  gtk_label_set_xalign (GTK_LABEL (draft_why), 0.0);
  gtk_label_set_wrap (GTK_LABEL (draft_why), TRUE);
  gtk_widget_set_margin_top (draft_why, 8);
  gtk_box_append (GTK_BOX (boat), draft_why);

  /* The clearance. */
  GtkWidget *clearance_label = gtk_label_new ("Clearance under the keel");
  gtk_widget_add_css_class (clearance_label, "heading");
  gtk_label_set_xalign (GTK_LABEL (clearance_label), 0.0);
  gtk_widget_set_margin_top (clearance_label, 18);
  gtk_box_append (GTK_BOX (boat), clearance_label);

  step->pills = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_set_margin_top (step->pills, 9);
  gtk_box_append (GTK_BOX (boat), step->pills);

  GtkWidget *clearance_why =
      gtk_label_new ("How much water you want left under the keel at the shallowest "
                     "point of a passage.");
  gtk_widget_add_css_class (clearance_why, "dim-label");
  gtk_widget_add_css_class (clearance_why, "caption");
  gtk_label_set_xalign (GTK_LABEL (clearance_why), 0.0);
  gtk_label_set_wrap (GTK_LABEL (clearance_why), TRUE);
  gtk_widget_set_margin_top (clearance_why, 9);
  gtk_box_append (GTK_BOX (boat), clearance_why);

  /* What it comes to. */
  step->derived = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_margin_top (step->derived, 16);
  gtk_box_append (GTK_BOX (boat), step->derived);

  gtk_widget_set_size_request (boat, LK_DEPTH_COLUMN, -1);
  gtk_box_append (GTK_BOX (columns), boat);

  /* ---- the right column: what it does to a chart ---- */

  step->water = lk_depth_water_new ();
  gtk_widget_set_hexpand (step->water, TRUE);
  gtk_widget_set_valign (step->water, GTK_ALIGN_START);
  gtk_box_append (GTK_BOX (columns), step->water);

  gtk_widget_set_margin_top (columns, 24);
  gtk_box_append (GTK_BOX (body), columns);

  GtkWidget *warning = lk_step_warning (
      "Shading is not a depth sounder.",
      "Soundings are not corrected for tide, surge or squat, and a survey can be "
      "decades old. Keep your own margin.");
  gtk_widget_set_margin_top (warning, 18);
  gtk_box_append (GTK_BOX (body), warning);

  gtk_widget_set_margin_start (body, 48);
  gtk_widget_set_margin_end (body, 48);
  gtk_widget_set_margin_bottom (body, 22);

  lk_depth_show_draft (step);
  lk_depth_apply (step);
  lk_depth_rebuild (step);
  return body;
}
