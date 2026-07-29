#include "lk-mariner.h"

#include "lk-store.h"

/* Coalesce a slider drag / typed number into one apply, still feels live. */
#define LK_APPLY_DEBOUNCE_MS 60

struct _LkMariner {
  GObject parent_instance;

  LkChartController *controller; /* not owned */
  tile57_mariner     raw;
  guint              apply_id;
};

G_DEFINE_FINAL_TYPE (LkMariner, lk_mariner, G_TYPE_OBJECT)

static void
lk_mariner_dispose (GObject *object)
{
  LkMariner *self = LK_MARINER (object);

  g_clear_handle_id (&self->apply_id, g_source_remove);

  G_OBJECT_CLASS (lk_mariner_parent_class)->dispose (object);
}

static void
lk_mariner_class_init (LkMarinerClass *klass)
{
  G_OBJECT_CLASS (klass)->dispose = lk_mariner_dispose;
}

static void
lk_mariner_init (LkMariner *self)
{
  lookout_mariner_defaults (&self->raw);
}

LkMariner *
lk_mariner_new (LkChartController *controller)
{
  LkMariner *self = g_object_new (LK_TYPE_MARINER, NULL);

  self->controller = controller;
  lk_mariner_reload (self);
  return self;
}

void
lk_mariner_reload (LkMariner *self)
{
  g_return_if_fail (LK_IS_MARINER (self));

  if (self->controller != NULL)
    self->raw = lk_chart_controller_get_mariner (self->controller);
  else
    lookout_mariner_defaults (&self->raw);
}

tile57_mariner *
lk_mariner_raw (LkMariner *self)
{
  g_return_val_if_fail (LK_IS_MARINER (self), NULL);
  return &self->raw;
}

static gboolean
lk_mariner_apply (gpointer user_data)
{
  LkMariner *self = user_data;

  self->apply_id = 0;

  if (self->controller != NULL)
    lk_chart_controller_set_mariner (self->controller, self->raw);
  lk_store_save_mariner (&self->raw);

  return G_SOURCE_REMOVE;
}

void
lk_mariner_touch (LkMariner *self)
{
  g_return_if_fail (LK_IS_MARINER (self));

  if (self->apply_id != 0)
    g_source_remove (self->apply_id);
  self->apply_id = g_timeout_add (LK_APPLY_DEBOUNCE_MS, lk_mariner_apply, self);
}

/* ---- display category --------------------------------------------------- */

int
lk_mariner_get_display_category (LkMariner *self)
{
  g_return_val_if_fail (LK_IS_MARINER (self), 1);

  if (self->raw.display_other)
    return 2;
  if (self->raw.display_standard)
    return 1;
  return 0;
}

void
lk_mariner_set_display_category (LkMariner *self, int category)
{
  g_return_if_fail (LK_IS_MARINER (self));

  /* Base ⊂ Standard ⊂ Other. */
  self->raw.display_base = TRUE;
  self->raw.display_standard = category != 0;
  self->raw.display_other = category == 2;
}
