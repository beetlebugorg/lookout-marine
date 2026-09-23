/* ui/firstrun/model.c — setup's state. See ui/firstrun/private.h. */
#include "ui/firstrun/private.h"

#include <string.h>

struct _LkFirstRun {
  GObject parent_instance;

  /* The core's state machine, and the state it last reported. */
  lookout_setup      *core;
  lookout_setup_state state;

  /* The source card picked on the source step. */
  LkFirstRunSource source;
  gboolean         asked_depths;

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

/* Read the core's state, and emit ::changed when it moved. */
static void
lk_first_run_read (LkFirstRun *self)
{
  lookout_setup_state was = self->state;

  lookout_setup_read (self->core, &self->state);
  if (memcmp (&was, &self->state, sizeof was) != 0)
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

gboolean
lk_first_run_asked_depths (LkFirstRun *self)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), TRUE);

  if (self->asked_depths)
    return TRUE;
  self->asked_depths = TRUE;
  return FALSE;
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
