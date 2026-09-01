/* pick-fixture.h — a decoded pick built by hand.
 *
 * lookout_picks_read needs an open chart, and these suites have none, so they
 * build the decoded feature the card draws. The fields are the ones
 * lookout_pick_feature carries, and the rows are the ones lookout_pick_rows
 * and lookout_pick_source hand over.
 */
#pragma once

#include "ui/chart/pick-report.h"

static inline void
lk_fixture_row_free (gpointer data)
{
  LkPickRow *row = data;

  g_free (row->label);
  g_free (row->value);
  g_free (row);
}

static inline LkPickRow *
lk_fixture_row (const char *label, const char *value, int depth)
{
  LkPickRow *row = g_new0 (LkPickRow, 1);

  row->label = g_strdup (label);
  row->value = g_strdup (value);
  row->depth = depth;
  return row;
}

static inline LkPickDecoded *
lk_fixture_feature (const char *cls, const char *chart, const char *title,
                    const char *subtitle, const char *chip, const char *footnote)
{
  LkPickDecoded *decoded = g_new0 (LkPickDecoded, 1);

  decoded->cls = g_strdup (cls);
  decoded->chart = g_strdup (chart);
  decoded->title = g_strdup (title);
  decoded->subtitle = g_strdup (subtitle);
  decoded->chip = g_strdup (chip);
  decoded->footnote = g_strdup (footnote);
  decoded->raw = g_strdup ("");
  decoded->notes = g_ptr_array_new_with_free_func (g_free);
  decoded->rows = g_ptr_array_new_with_free_func (lk_fixture_row_free);
  decoded->source = g_ptr_array_new_with_free_func (lk_fixture_row_free);
  return decoded;
}
