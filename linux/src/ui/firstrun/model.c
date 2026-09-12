/* ui/firstrun/model.c — setup's state. See ui/firstrun/private.h. */
#include "ui/firstrun/private.h"

struct _LkFirstRun {
  GObject parent_instance;

  LkFirstRunStep   step;
  LkFirstRunSource source;
  gboolean         showing;

  /* TRUE once the mariner has put setup away for this run. Set Up Later is
   * "not now", not an answer, so it holds only until the app is next started
   * with nothing to draw. */
  gboolean put_away;

  /* A bake has been seen running. */
  gboolean saw_bake;

  /* The NOAA download as it was ordered. */
  char    *order_regions;
  guint32  order_charts;
  guint64  order_bytes;
  gboolean ordered;
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

LkFirstRunStep
lk_first_run_step (LkFirstRun *self)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), LK_FIRST_RUN_WELCOME);
  return self->step;
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

gboolean
lk_first_run_showing (LkFirstRun *self)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), FALSE);
  return self->showing;
}

gboolean
lk_first_run_should_run (LkFirstRun *self, gboolean nothing_to_draw, gboolean on_a_link)
{
  const char *spec = lk_first_run_setting ();

  g_return_val_if_fail (LK_IS_FIRST_RUN (self), FALSE);

  if (spec != NULL)
    return !g_str_equal (spec, "0");
  if (self->put_away || on_a_link)
    return FALSE;
  return nothing_to_draw;
}

void
lk_first_run_begin (LkFirstRun *self)
{
  g_return_if_fail (LK_IS_FIRST_RUN (self));

  self->step = lk_first_run_opening_step ();
  self->showing = TRUE;
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

/* ---- moving through it --------------------------------------------------- */

gboolean
lk_first_run_advance (LkFirstRun *self, LkFirstRunSource *out_source)
{
  gboolean act = FALSE;

  g_return_val_if_fail (LK_IS_FIRST_RUN (self), FALSE);

  if (out_source != NULL)
    *out_source = self->source;

  switch (self->step)
    {
    case LK_FIRST_RUN_WELCOME:
      self->step = LK_FIRST_RUN_SOURCE;
      break;

    case LK_FIRST_RUN_SOURCE:
      switch (self->source)
        {
        case LK_FIRST_RUN_NOAA:
          self->step = LK_FIRST_RUN_COVERAGE;
          break;
        case LK_FIRST_RUN_ONLINE_CHART:
          self->step = LK_FIRST_RUN_ONLINE;
          break;
        case LK_FIRST_RUN_FILES:
          /* The app has nothing more to ask: the mariner is going to their own
           * files, and that is the end of setup. */
          lk_first_run_finish (self);
          return TRUE;
        }
      break;

    case LK_FIRST_RUN_COVERAGE:
      self->step = LK_FIRST_RUN_IMPORTING;
      act = TRUE;
      break;

    case LK_FIRST_RUN_ONLINE:
      /* The chart the mariner picked is already drawing. */
      self->step = LK_FIRST_RUN_DEPTHS;
      break;

    case LK_FIRST_RUN_IMPORTING:
      self->step = LK_FIRST_RUN_DEPTHS;
      break;

    case LK_FIRST_RUN_DEPTHS:
      lk_first_run_finish (self);
      return FALSE;
    }

  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
  return act;
}

gboolean
lk_first_run_can_go_back (LkFirstRun *self)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), FALSE);

  switch (self->step)
    {
    case LK_FIRST_RUN_SOURCE:
    case LK_FIRST_RUN_COVERAGE:
    case LK_FIRST_RUN_ONLINE:
      return TRUE;
    default:
      /* The welcome step offers Set Up Later instead. The import and the depth
       * steps have no step to return to: the charts are already arriving, and
       * Back would offer a second import of them. */
      return FALSE;
    }
}

void
lk_first_run_back (LkFirstRun *self)
{
  g_return_if_fail (LK_IS_FIRST_RUN (self));

  switch (self->step)
    {
    case LK_FIRST_RUN_SOURCE:
      self->step = LK_FIRST_RUN_WELCOME;
      break;
    case LK_FIRST_RUN_COVERAGE:
    case LK_FIRST_RUN_ONLINE:
      self->step = LK_FIRST_RUN_SOURCE;
      break;
    default:
      return;
    }
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

void
lk_first_run_finish (LkFirstRun *self)
{
  g_return_if_fail (LK_IS_FIRST_RUN (self));

  self->put_away = TRUE;
  self->showing = FALSE;
  self->step = LK_FIRST_RUN_WELCOME;
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

/* ---- what each step says ------------------------------------------------- */

const char *
lk_first_run_primary_title (LkFirstRun *self, const char *chosen)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), "Continue");

  switch (self->step)
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

const char *
lk_first_run_step_title (LkFirstRunStep step)
{
  switch (step)
    {
    case LK_FIRST_RUN_WELCOME:   return "Welcome";
    case LK_FIRST_RUN_SOURCE:    return "Add charts";
    case LK_FIRST_RUN_COVERAGE:  return "Coverage";
    case LK_FIRST_RUN_ONLINE:    return "Online chart";
    case LK_FIRST_RUN_IMPORTING: return "Preparing";
    case LK_FIRST_RUN_DEPTHS:    return "Depths";
    default:                     return "Setup";
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
lk_first_run_set_order (LkFirstRun *self, const char *regions, guint32 charts,
                        guint64 bytes)
{
  g_return_if_fail (LK_IS_FIRST_RUN (self));

  g_free (self->order_regions);
  self->order_regions = g_strdup (regions != NULL ? regions : "");
  self->order_charts = charts;
  self->order_bytes = bytes;
  self->ordered = TRUE;
}

gboolean
lk_first_run_order (LkFirstRun *self, const char **out_regions, guint32 *out_charts,
                    guint64 *out_bytes)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), FALSE);

  if (!self->ordered)
    return FALSE;
  if (out_regions != NULL)
    *out_regions = self->order_regions;
  if (out_charts != NULL)
    *out_charts = self->order_charts;
  if (out_bytes != NULL)
    *out_bytes = self->order_bytes;
  return TRUE;
}

gboolean
lk_first_run_saw_bake (LkFirstRun *self)
{
  g_return_val_if_fail (LK_IS_FIRST_RUN (self), FALSE);
  return self->saw_bake;
}

void
lk_first_run_note_bake (LkFirstRun *self)
{
  g_return_if_fail (LK_IS_FIRST_RUN (self));

  if (self->saw_bake)
    return;
  self->saw_bake = TRUE;
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

/* ---- GObject ------------------------------------------------------------- */

static void
lk_first_run_dispose (GObject *object)
{
  LkFirstRun *self = LK_FIRST_RUN (object);

  g_clear_pointer (&self->order_regions, g_free);

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
}

LkFirstRun *
lk_first_run_new (void)
{
  return g_object_new (LK_TYPE_FIRST_RUN, NULL);
}
