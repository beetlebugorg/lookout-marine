/* model/first-run.c: setup's state. See model/first-run.h. */
#include "model/first-run.h"

struct _LkFirstRun {
  GObject parent_instance;

  /* The core's state machine, and the state it last reported. */
  lookout_setup      *core;
  lookout_setup_state state;

  /* The source card picked on the source step. */
  LkFirstRunSource source;

  /* The names of the regions ordered, for the import step. */
  char *order_regions;
};

enum {
  SIGNAL_CHANGED,
  N_SIGNALS
};

static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE (LkFirstRun, lk_first_run, G_TYPE_OBJECT)

/* ---- the dev hook -------------------------------------------------------- */

/* LOOKOUT_FIRST_RUN=1 runs setup whatever the library says, and =0 keeps it
 * down. A screenshot run and a test both need to choose, because the answer
 * otherwise comes from what is installed on this machine.
 *
 * A step name in place of 1 opens setup on that step. A screenshot run has no
 * pointer to click Continue with. */
static const char *
lk_first_run_setting (void)
{
  return g_getenv ("LOOKOUT_FIRST_RUN");
}

static LkFirstRunStep
lk_first_run_opening_step (void)
{
  const char *spec = lk_first_run_setting ();

  if (spec == NULL)
    return LK_FIRST_RUN_WELCOME;
  if (g_str_equal (spec, "source"))
    return LK_FIRST_RUN_SOURCE;
  if (g_str_equal (spec, "coverage"))
    return LK_FIRST_RUN_COVERAGE;
  if (g_str_equal (spec, "online"))
    return LK_FIRST_RUN_ONLINE;
  if (g_str_equal (spec, "importing"))
    return LK_FIRST_RUN_IMPORTING;
  if (g_str_equal (spec, "depths"))
    return LK_FIRST_RUN_DEPTHS;
  return LK_FIRST_RUN_WELCOME;
}

/* ---- where the flow is --------------------------------------------------- */

/* TRUE when every field of the two states is equal. A byte compare of the
 * structs is wrong: the padding between the uint8_t fields and order_charts is
 * not a field, and a Debug build of the core writes it with no fixed value. */
static gboolean
lk_setup_state_equal (const lookout_setup_state *a, const lookout_setup_state *b)
{
  return a->step == b->step && a->showing == b->showing && a->should_run == b->should_run &&
         a->can_go_back == b->can_go_back && a->primary_enabled == b->primary_enabled &&
         a->terms_showing == b->terms_showing && a->picker_only == b->picker_only &&
         a->ordered == b->ordered && a->import_ended == b->import_ended &&
         a->saw_work == b->saw_work && a->order_charts == b->order_charts &&
         a->order_bytes == b->order_bytes;
}

/* Read the core's state, and emit ::changed when a field moved. The flow
 * rebuilds the step on ::changed, so a false change destroys the step's
 * widgets under whoever holds them. */
static void
lk_first_run_read (LkFirstRun *self)
{
  lookout_setup_state was = self->state;

  lookout_setup_read (self->core, &self->state);
  if (!lk_setup_state_equal (&was, &self->state))
    g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

const lookout_setup_state *
lk_first_run_state (LkFirstRun *self)
{
  static const lookout_setup_state none = { 0 };

  g_return_val_if_fail (LK_IS_FIRST_RUN (self), &none);
  return &self->state;
}

LkFirstRunStep
lk_first_run_step (LkFirstRun *self)
{
  return (LkFirstRunStep) lk_first_run_state (self)->step;
}

gboolean
lk_first_run_showing (LkFirstRun *self)
{
  return lk_first_run_state (self)->showing;
}

LkFirstRunSource
lk_first_run_source (LkFirstRun *self)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), LK_FIRST_RUN_NOAA);
  return self->source;
}

void
lk_first_run_set_source (LkFirstRun *self, LkFirstRunSource source)
{
  g_return_if_fail (LK_IS_FIRST_RUN (self));

  if (self->source == source)
    return;
  self->source = source;
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

void
lk_first_run_note (LkFirstRun *self, const lookout_setup_facts *facts)
{
  g_return_if_fail (LK_IS_FIRST_RUN (self));

  lookout_setup_note (self->core, facts);
  lk_first_run_read (self);
}

int
lk_first_run_act (LkFirstRun *self, int action, int arg)
{
  int source;

  g_return_val_if_fail (LK_IS_FIRST_RUN (self), -1);

  source = lookout_setup_act (self->core, action, arg);
  lk_first_run_read (self);
  return source;
}

gboolean
lk_first_run_should_run (LkFirstRun *self)
{
  const char *spec = lk_first_run_setting ();

  g_return_val_if_fail (LK_IS_FIRST_RUN (self), FALSE);

  if (spec != NULL)
    return !g_str_equal (spec, "0") && !self->state.showing;
  return self->state.should_run;
}

void
lk_first_run_begin (LkFirstRun *self)
{
  lk_first_run_act (self, LOOKOUT_SETUP_BEGIN, lk_first_run_opening_step ());
}

/* ---- what each step says ------------------------------------------------- */

const char *
lk_first_run_primary_title (LkFirstRun *self, const char *chosen)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), "Continue");

  switch (self->state.step)
    {
    case LK_FIRST_RUN_COVERAGE:
      return "Download";
    case LK_FIRST_RUN_DEPTHS:
      return "Start Sailing";
    case LK_FIRST_RUN_ONLINE:
      /* The button states what the choice does, by naming the chart it keeps.
       * The caller owns the string it passes. */
      return chosen != NULL ? chosen : "Continue";
    default:
      return "Continue";
    }
}


int
lk_first_run_sheet_width (LkFirstRunStep step)
{
  switch (step)
    {
    case LK_FIRST_RUN_WELCOME:   return 640;
    case LK_FIRST_RUN_SOURCE:    return 760;
    case LK_FIRST_RUN_COVERAGE:  return 1040;
    /* Wide enough for the whole gallery: the charts the app ships, plus the
     * tile that adds one. */
    case LK_FIRST_RUN_ONLINE:    return 1060;
    case LK_FIRST_RUN_IMPORTING: return 940;
    case LK_FIRST_RUN_DEPTHS:    return 920;
    default:                     return 760;
    }
}

/* ---- the order, and the import ------------------------------------------- */

void
lk_first_run_set_order_regions (LkFirstRun *self, const char *regions)
{
  g_return_if_fail (LK_IS_FIRST_RUN (self));

  g_free (self->order_regions);
  self->order_regions = g_strdup (regions != NULL ? regions : "");
}

gboolean
lk_first_run_order (LkFirstRun *self, const char **out_regions, guint32 *out_charts,
                    guint64 *out_bytes)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), FALSE);

  if (!self->state.ordered)
    return FALSE;
  if (out_regions != NULL)
    *out_regions = self->order_regions != NULL ? self->order_regions : "";
  if (out_charts != NULL)
    *out_charts = self->state.order_charts;
  if (out_bytes != NULL)
    *out_bytes = self->state.order_bytes;
  return TRUE;
}

/* ---- GObject ------------------------------------------------------------- */

static void
lk_first_run_dispose (GObject *object)
{
  LkFirstRun *self = LK_FIRST_RUN (object);

  g_clear_pointer (&self->order_regions, g_free);
  g_clear_pointer (&self->core, lookout_setup_free);

  G_OBJECT_CLASS (lk_first_run_parent_class)->dispose (object);
}

static void
lk_first_run_class_init (LkFirstRunClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = lk_first_run_dispose;

  /* The step moved, the source moved, or setup went away. One signal: the
   * flow rebuilds the card and the footer from the model. */
  signals[SIGNAL_CHANGED] =
      g_signal_new ("changed", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

static void
lk_first_run_init (LkFirstRun *self)
{
  /* NOAA is the recommended source and the one the app preselects: official
   * cover for every United States waterway, at no cost. */
  self->source = LK_FIRST_RUN_NOAA;
  self->core = lookout_setup_new ();
  lookout_setup_read (self->core, &self->state);
}

LkFirstRun *
lk_first_run_new (void)
{
  return g_object_new (LK_TYPE_FIRST_RUN, NULL);
}
