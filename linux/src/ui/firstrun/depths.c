/* ui/firstrun/depths.c: the depth settings, asked as two questions about the
 * boat.
 *
 * The step asks for a draft and a clearance under the keel. It derives the two
 * S-52 numbers the engine draws with, the safety depth and the safety contour,
 * and states what each one does to the chart.
 *
 * The core derives every number from the draft and the clearance
 * (lookout_depth_plan). The engine is always given metres.
 */
#include "ui/firstrun/private.h"
#include "ui/firstrun/water.h"

#include <math.h>

/* The left column, in the reference's proportion: the boat beside the water
 * rather than above it. */
#define LK_DEPTH_COLUMN 334

/* ---- the step ------------------------------------------------------------ */

/* The boat, in metres. The plan states it in the unit on screen. */
typedef struct {
  LkFirstRunFlow *flow;
  double          draft_m;
  double          clearance_m;

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

static struct lookout_depth_plan
lk_depth_plan (LkDepthStep *step)
{
  struct lookout_depth_plan plan;

  lookout_depth_plan (step->draft_m, step->clearance_m, lk_depth_feet (step), &plan);
  return plan;
}

/* A depth in metres, in the unit on screen. Free with g_free. */
static char *
lk_depth_measure (LkDepthStep *step, double v_m, int bare)
{
  char text[LOOKOUT_DEPTH_MAX];

  lookout_fmt_depth (v_m, (lk_depth_feet (step) ? LOOKOUT_DEPTH_FEET : LOOKOUT_DEPTH_METRES) |
                              bare,
                     text, sizeof text);
  return g_strdup (text);
}

/* Write the numbers the engine draws with. */
static void
lk_depth_apply (LkDepthStep *step)
{
  tile57_mariner *mariner = lk_mariner_raw (step->flow->mariner);
  struct lookout_depth_plan plan = lk_depth_plan (step);

  mariner->safety_depth = plan.safety_depth_m;
  mariner->shallow_contour = plan.shallow_contour_m;
  mariner->safety_contour = plan.safety_contour_m;
  mariner->deep_contour = plan.deep_contour_m;
  mariner->four_shade_water = true;
  lk_mariner_touch (step->flow->mariner);
}

static void lk_depth_rebuild (LkDepthStep *step);

/* The draft alone, for the field, with no unit on it. */
static void
lk_depth_show_draft (LkDepthStep *step)
{
  g_autofree char *text = lk_depth_measure (step, step->draft_m, LOOKOUT_DEPTH_BARE);

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
  double metres_per_unit = lk_depth_feet (step) ? LOOKOUT_METRES_PER_FOOT : 1.0;

  /* An empty field is a number half typed. The step holds the last draft it
   * read and waits. */
  if (step->busy || value <= 0)
    return;

  /* The plan holds the draft between one step and the most the step
   * accepts. */
  step->draft_m = value * metres_per_unit;
  step->draft_m = lk_depth_plan (step).draft_m;
  lk_depth_apply (step);
  lk_depth_rebuild (step);
}

static void
lk_depth_unit_toggled (GtkToggleButton *button, gpointer user_data)
{
  LkDepthStep *step = user_data;
  tile57_mariner *mariner = lk_mariner_raw (step->flow->mariner);
  gboolean to_feet = gtk_toggle_button_get_active (GTK_TOGGLE_BUTTON (step->feet));
  struct lookout_depth_plan plan;

  if (step->busy || (mariner->depth_unit == 1) == to_feet)
    return;

  /* The same boat in the new unit: the draft rounded to a half unit, and the
   * clearance snapped to one the unit offers. */
  mariner->depth_unit = to_feet ? 1 : 0;
  plan = lk_depth_plan (step);
  step->draft_m = plan.draft_rounded_m;
  step->clearance_m = plan.clearance_m;

  lk_depth_show_draft (step);
  lk_depth_apply (step);
  lk_depth_rebuild (step);
}

static void
lk_depth_pill_clicked (GtkButton *button, gpointer user_data)
{
  LkDepthStep *step = user_data;
  const double *value = g_object_get_data (G_OBJECT (button), "lk-clearance");

  step->clearance_m = *value;
  lk_depth_apply (step);
  lk_depth_rebuild (step);
}

/* What the two answers come to, in the engine's own terms. */
static void
lk_depth_fill_derived (LkDepthStep *step)
{
  struct lookout_depth_plan plan = lk_depth_plan (step);
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (step->derived)) != NULL)
    gtk_box_remove (GTK_BOX (step->derived), child);

  g_autofree char *safety_text = lk_depth_measure (step, plan.safety_depth_m, 0);
  g_autofree char *contour_text = lk_depth_measure (step, plan.safety_contour_m, 0);
  g_autofree char *deep_text = lk_depth_measure (step, plan.deep_contour_m, 0);
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
      GtkWidget *why = lk_caption (rows[i].why);

      gtk_widget_add_css_class (name, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (name), 0.0);
      gtk_widget_set_hexpand (name, TRUE);
      gtk_widget_add_css_class (value, "heading");
      gtk_box_append (GTK_BOX (head), name);
      gtk_box_append (GTK_BOX (head), value);

      gtk_label_set_wrap (GTK_LABEL (why), TRUE);

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
  struct lookout_depth_plan plan = lk_depth_plan (step);
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (step->pills)) != NULL)
    gtk_box_remove (GTK_BOX (step->pills), child);

  for (guint i = 0; i < G_N_ELEMENTS (plan.clearances); i++)
    {
      double metres = plan.clearances[i] * plan.metres_per_unit;
      g_autofree char *text = lk_depth_measure (step, metres, 0);
      GtkWidget *pill = gtk_button_new_with_label (text);
      double *value = g_new (double, 1);

      *value = metres;
      gtk_widget_add_css_class (pill, "pill");
      if (fabs (plan.clearances[i] - plan.clearance) < 0.001)
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
  struct lookout_depth_plan plan = lk_depth_plan (step);

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
    lk_depth_water_set (step->water, plan.safety_depth, plan.safety_contour,
                        plan.deep_contour, feet,
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

  /* Start at the core's small keelboat, which a draft of 0 selects. The
   * stored safety depth is no help: it starts at the engine's 10 m, and a
   * draft read back out of that gives 9.7 m. */
  feet = lk_depth_feet (step);
  {
    struct lookout_depth_plan start = lk_depth_plan (step);

    step->draft_m = start.draft_m;
    step->clearance_m = start.clearance_m;
  }

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

  GtkWidget *draft_why = lk_caption ("Deepest point of the hull below the "
                                        "waterline, keel included.");
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
