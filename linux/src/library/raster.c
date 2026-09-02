#include "library/raster.h"

#include "engine/controller.h"
#include "library/scan.h"

#include "model/store.h"

#include <string.h>

struct _LkRasterCharts {
  GPtrArray  *paths;  /* char*, in the order added; NULL-terminated for callers */
  GHashTable *off;    /* the paths switched off, as a set */
  GHashTable *hidden; /* the SET NAMES not drawn, as a set */
};

/* ---- set names ---------------------------------------------------------- */

/* What a raster chart's set is called. The ENGINE decides, because it is what
 * names the sets it draws by: a shell grouping by anything else disagrees with
 * what the pill then shows. Transfer full. */
char *
lk_raster_set_name_for (const char *path)
{
  size_t length = 0;
  const char *name;

  g_return_val_if_fail (path != NULL, g_strdup (""));

  name = lookout_raster_set_name_for (path, &length);
  return name != NULL ? g_strndup (name, length) : g_strdup ("");
}

/* ---- the installed list ------------------------------------------------- */

/* Close a borrowed pointer array so the store can read it as a strv. Every
 * list written from here is gathered first and terminated last, so this is the
 * one place that terminator is added. */
static const char *const *
lk_raster_strv (GPtrArray *borrowed)
{
  g_ptr_array_add (borrowed, NULL);
  return (const char *const *) borrowed->pdata;
}

/* The keys of a set table. Borrowed: the strings belong to the table. */
static GPtrArray *
lk_raster_keys (GHashTable *table)
{
  GPtrArray *keys = g_ptr_array_new ();
  GHashTableIter iter;
  gpointer key;

  g_hash_table_iter_init (&iter, table);
  while (g_hash_table_iter_next (&iter, &key, NULL))
    g_ptr_array_add (keys, key);

  return keys;
}

static void
lk_raster_charts_save (LkRasterCharts *self)
{
  g_autoptr (GPtrArray) off = lk_raster_keys (self->off);
  g_autoptr (GPtrArray) hidden = lk_raster_keys (self->hidden);

  lk_store_save_raster_all (lk_raster_charts_paths (self),
                            lk_raster_strv (off),
                            lk_raster_strv (hidden));
}

/* Forget every installed raster chart: the list, the off set, and the hidden
   set. The engine holds live pictures until the next open, so this takes effect
   then. */
void
lk_raster_charts_clear (LkRasterCharts *self)
{
  g_return_if_fail (self != NULL);

  g_ptr_array_set_size (self->paths, 0);
  g_ptr_array_add (self->paths, NULL); /* keep the strv terminator */
  g_hash_table_remove_all (self->off);
  g_hash_table_remove_all (self->hidden);
  lk_raster_charts_save (self);
}

LkRasterCharts *
lk_raster_charts_new (void)
{
  LkRasterCharts *self = g_new0 (LkRasterCharts, 1);

  self->paths = g_ptr_array_new_with_free_func (g_free);
  self->off = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  self->hidden = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);

  g_auto (GStrv) saved = lk_store_load_raster_paths ();
  for (guint i = 0; saved[i] != NULL; i++)
    g_ptr_array_add (self->paths, g_strdup (saved[i]));
  g_ptr_array_add (self->paths, NULL); /* the strv terminator callers read */

  g_auto (GStrv) off = lk_store_load_raster_off ();
  for (guint i = 0; off[i] != NULL; i++)
    g_hash_table_add (self->off, g_strdup (off[i]));

  g_auto (GStrv) hidden = lk_store_load_raster_hidden ();
  for (guint i = 0; hidden[i] != NULL; i++)
    g_hash_table_add (self->hidden, g_strdup (hidden[i]));

  return self;
}

void
lk_raster_charts_free (LkRasterCharts *self)
{
  if (self == NULL)
    return;

  g_ptr_array_unref (self->paths);
  g_hash_table_unref (self->off);
  g_hash_table_unref (self->hidden);
  g_free (self);
}

const char *const *
lk_raster_charts_paths (LkRasterCharts *self)
{
  g_return_val_if_fail (self != NULL, NULL);
  return (const char *const *) self->paths->pdata;
}

guint
lk_raster_charts_count (LkRasterCharts *self)
{
  g_return_val_if_fail (self != NULL, 0);
  return self->paths->len - 1; /* the terminator is not a chart */
}

static gboolean
lk_raster_charts_holds (LkRasterCharts *self, const char *path)
{
  for (guint i = 0; i + 1 < self->paths->len; i++)
    {
      if (g_strcmp0 (g_ptr_array_index (self->paths, i), path) == 0)
        return TRUE;
    }
  return FALSE;
}

gboolean
lk_raster_charts_add (LkRasterCharts *self, const char *path)
{
  g_return_val_if_fail (self != NULL && path != NULL, FALSE);

  if (lk_raster_charts_holds (self, path))
    return FALSE;

  /* Insert before the terminator, so the array stays a valid strv. */
  g_ptr_array_insert (self->paths, self->paths->len - 1, g_strdup (path));
  lk_raster_charts_save (self);
  return TRUE;
}

/* Is any installed file still part of the set called `name`? */
static gboolean
lk_raster_charts_holds_set (LkRasterCharts *self, const char *name)
{
  for (guint i = 0; i + 1 < self->paths->len; i++)
    {
      g_autofree char *other = lk_raster_set_name_for (g_ptr_array_index (self->paths, i));
      if (g_strcmp0 (other, name) == 0)
        return TRUE;
    }
  return FALSE;
}

void
lk_raster_charts_remove (LkRasterCharts *self, const char *path)
{
  g_return_if_fail (self != NULL && path != NULL);

  g_autofree char *name = lk_raster_set_name_for (path);
  gboolean had = FALSE;

  for (guint i = 0; i + 1 < self->paths->len; i++)
    {
      if (g_strcmp0 (g_ptr_array_index (self->paths, i), path) == 0)
        {
          g_ptr_array_remove_index (self->paths, i);
          had = TRUE;
          break;
        }
    }
  /* Forgotten means forgotten. The two lists are keyed by path and by set name,
   * so leaving an entry behind means the same file installed again months later
   * comes back switched off, or its set not drawn, with nothing on screen to
   * say why. The name goes with the LAST file of its set: while the mariner
   * still carries the others, it is still the set they switched off. */
  gboolean changed = had;
  if (g_hash_table_remove (self->off, path))
    changed = TRUE;
  if (!lk_raster_charts_holds_set (self, name) &&
      g_hash_table_remove (self->hidden, name))
    changed = TRUE;

  /* Removing a path that was never installed moves nothing, and settings.ini
   * is not rewritten for it. */
  if (changed)
    lk_raster_charts_save (self);
}

void
lk_raster_charts_set_enabled (LkRasterCharts *self, const char *path, gboolean on)
{
  g_return_if_fail (self != NULL && path != NULL);

  /* Only a real move is written. Setting a chart to the state it is already in
   * is what the settings form does on every rebuild of its list. */
  gboolean changed = on ? g_hash_table_remove (self->off, path)
                        : g_hash_table_add (self->off, g_strdup (path));
  if (changed)
    lk_raster_charts_save (self);
}

gboolean
lk_raster_charts_enabled (LkRasterCharts *self, const char *path)
{
  g_return_val_if_fail (self != NULL && path != NULL, TRUE);
  return !g_hash_table_contains (self->off, path);
}

gboolean
lk_raster_charts_shown (LkRasterCharts *self, const char *name)
{
  g_return_val_if_fail (self != NULL && name != NULL, TRUE);
  return !g_hash_table_contains (self->hidden, name);
}

gboolean
lk_raster_charts_note_shown (LkRasterCharts    *self,
                             const char *const *shown,
                             const char *const *hidden)
{
  gboolean changed = FALSE;

  g_return_val_if_fail (self != NULL, FALSE);

  for (guint i = 0; shown != NULL && shown[i] != NULL; i++)
    {
      if (g_hash_table_remove (self->hidden, shown[i]))
        changed = TRUE;
    }

  for (guint i = 0; hidden != NULL && hidden[i] != NULL; i++)
    {
      if (g_hash_table_contains (self->hidden, hidden[i]))
        continue;
      g_hash_table_add (self->hidden, g_strdup (hidden[i]));
      changed = TRUE;
    }

  /* Only on a real change: this is read back after every frame that moves the
   * raster state, and rewriting settings.ini as the mariner sails in and out of
   * coverage would be a file write for nothing. */
  if (changed)
    lk_raster_charts_save (self);
  return changed;
}

static void
lk_raster_group_free (gpointer data)
{
  LkRasterGroup *group = data;

  g_free (group->name);
  g_ptr_array_unref (group->paths);
  g_free (group);
}

GPtrArray *
lk_raster_charts_groups (LkRasterCharts *self)
{
  GPtrArray *groups = g_ptr_array_new_with_free_func (lk_raster_group_free);

  g_return_val_if_fail (self != NULL, groups);

  for (guint i = 0; i + 1 < self->paths->len; i++)
    {
      char *path = g_ptr_array_index (self->paths, i);
      g_autofree char *name = lk_raster_set_name_for (path);
      LkRasterGroup *group = NULL;

      for (guint j = 0; j < groups->len; j++)
        {
          LkRasterGroup *candidate = g_ptr_array_index (groups, j);
          if (g_strcmp0 (candidate->name, name) == 0)
            {
              group = candidate;
              break;
            }
        }

      if (group == NULL)
        {
          group = g_new0 (LkRasterGroup, 1);
          group->name = g_steal_pointer (&name);
          group->paths = g_ptr_array_new ();
          g_ptr_array_add (groups, group);
        }

      g_ptr_array_add (group->paths, path);
    }

  return groups;
}

/* ---- finding them on disk ------------------------------------------------ */

char **
lk_raster_charts_in_dir (const char *dir)
{
  return lk_files_under (dir, ".mbtiles");
}

/* ---- the engine's election ----------------------------------------------- */
/*
 * Which set is drawn, which one covers this view, and whether the ENC is
 * hidden under it: all of that is the engine's account, read back after every
 * change. The engine owns the election — showing one set turns off the sets
 * covering the same water — so what it says after a change is the only account
 * that can be right.
 */

struct _LkRasterState {
  GPtrArray *sets;      /* LkRasterSet*, as the engine last reported them */
  int        active;
  char      *available; /* the set covering this view, "" when none does */
  gboolean   over_chart;
  gboolean   chart_hidden;
};

LkRasterState *
lk_raster_state_new (void)
{
  LkRasterState *self = g_new0 (LkRasterState, 1);

  self->sets = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_raster_set_free);
  self->active = -1;
  self->available = g_strdup ("");
  return self;
}

void
lk_raster_state_free (LkRasterState *self)
{
  if (self == NULL)
    return;
  g_clear_pointer (&self->sets, g_ptr_array_unref);
  g_clear_pointer (&self->available, g_free);
  g_free (self);
}

static gboolean
lk_raster_sets_equal (GPtrArray *a, GPtrArray *b)
{
  if (a->len != b->len)
    return FALSE;

  for (guint i = 0; i < a->len; i++)
    {
      const LkRasterSet *one = g_ptr_array_index (a, i);
      const LkRasterSet *other = g_ptr_array_index (b, i);

      if (one->id != other->id || one->in_view != other->in_view ||
          one->shown != other->shown || g_strcmp0 (one->name, other->name) != 0)
        return FALSE;
    }

  return TRUE;
}

/* Write down which sets are drawn. Everything that can move the selection comes
 * through the sync below, so this is the one place it is saved: the pill's
 * menu, the Chart menu, the cycle key, and switching a chart off in the
 * settings, which can move the selection on its own.
 *
 * Read back from the engine rather than tracked here. The engine owns the
 * election — showing one set turns off the sets covering the same water — so
 * what it says after the change is the only account that can be right. */
static void
lk_raster_state_note_shown (LkRasterState *self, LkRasterCharts *charts)
{
  if (self->sets->len == 0)
    return; /* no chart open, or no raster charts in it: nothing to say */

  g_autoptr (GPtrArray) shown = g_ptr_array_new ();
  g_autoptr (GPtrArray) hidden = g_ptr_array_new ();

  for (guint i = 0; i < self->sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (self->sets, i);
      g_ptr_array_add (set->shown ? shown : hidden, set->name);
    }

  lk_raster_charts_note_shown (charts, lk_raster_strv (shown), lk_raster_strv (hidden));
}

/* Read the engine's raster state into the model. TRUE when something moved —
 * the caller decides whether that alone warrants rebuilding the chrome. */
gboolean
lk_raster_state_sync (LkRasterState *self, LkChartController *controller,
                      LkRasterCharts *charts)
{
  int active = lk_chart_controller_raster_active_index (controller);
  gboolean over = lk_chart_controller_raster_over_chart (controller);
  gboolean hidden = lk_chart_controller_chart_hidden (controller);
  g_autofree char *available = lk_chart_controller_raster_available_name (controller);
  g_autoptr (GPtrArray) sets = lk_chart_controller_raster_sets (controller);

  gboolean changed = active != self->active ||
                     over != self->over_chart ||
                     hidden != self->chart_hidden ||
                     g_strcmp0 (available, self->available) != 0 ||
                     !lk_raster_sets_equal (sets, self->sets);

  if (!changed)
    return FALSE;

  self->active = active;
  self->over_chart = over;
  self->chart_hidden = hidden;
  g_free (self->available);
  self->available = g_steal_pointer (&available);
  g_clear_pointer (&self->sets, g_ptr_array_unref);
  self->sets = g_ptr_array_ref (sets);
  lk_raster_state_note_shown (self, charts);
  return TRUE;
}

/* Put back which sets the mariner had drawn. Adding a source draws its set,
 * which is right for a chart just picked and wrong for one being re-installed
 * at launch, so every open has to correct it — after every source is in,
 * because switching one chart off can move which set is drawn, and before the
 * first frame, or a set the mariner switched off flashes on screen.
 *
 * Two passes. Hiding first and showing second is what keeps the election: where
 * two providers cover one coast, the sources were added in an order that drew
 * the first of them, so showing the mariner's pick before hiding its rival
 * would leave the rival to turn the pick straight back off. */
void
lk_raster_state_restore (LkRasterCharts *charts, LkChartController *controller)
{
  g_autoptr (GPtrArray) sets = lk_chart_controller_raster_sets (controller);

  for (guint i = 0; i < sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (sets, i);

      if (!lk_raster_charts_shown (charts, set->name))
        lk_chart_controller_raster_set_shown (controller, set->id, FALSE);
    }

  for (guint i = 0; i < sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (sets, i);

      if (lk_raster_charts_shown (charts, set->name))
        lk_chart_controller_raster_set_shown (controller, set->id, TRUE);
    }
}

GPtrArray *
lk_raster_state_sets (LkRasterState *self)
{
  g_return_val_if_fail (self != NULL, NULL);
  return self->sets;
}

int
lk_raster_state_active (LkRasterState *self)
{
  g_return_val_if_fail (self != NULL, -1);
  return self->active;
}

const char *
lk_raster_state_available (LkRasterState *self)
{
  g_return_val_if_fail (self != NULL, "");
  return self->available;
}

gboolean
lk_raster_state_over_chart (LkRasterState *self)
{
  g_return_val_if_fail (self != NULL, FALSE);
  return self->over_chart;
}

gboolean
lk_raster_state_chart_hidden (LkRasterState *self)
{
  g_return_val_if_fail (self != NULL, FALSE);
  return self->chart_hidden;
}
