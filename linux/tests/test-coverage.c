/* test-coverage.c — the NOAA coverage picker.
 *
 * The map, the pills and the catalog line all drive one selection and all read
 * it back off the service. With no catalog the picker has nothing to price a
 * pick against, so the controls stand down and say so: that state is the one a
 * mariner meets first, and the one this suite can reach without a network.
 *
 * The geometry a click asks is a pure function, and it is checked against the
 * regions' own extents.
 */

#include "lk-test.h"

#include "model/app-model.h"
#include "ui/charts/coverage-map.h"

static LkAppModel *model;
static LkNoaa     *noaa;
static GtkWidget  *window;

/* Every widget under test lives in one window, so a visibility check means
 * what it means in the app. */
static GtkWidget *
hosted (GtkWidget *child)
{
  gtk_window_set_child (GTK_WINDOW (window), child);
  lk_test_drain ();
  return child;
}

static gboolean
match_drawing_area (GtkWidget *widget, gconstpointer data)
{
  return GTK_IS_DRAWING_AREA (widget);
}

static guint
count (GtkWidget *root, LkTestMatch match)
{
  guint n = match (root, NULL) ? 1 : 0;

  for (GtkWidget *child = gtk_widget_get_first_child (root);
       child != NULL;
       child = gtk_widget_get_next_sibling (child))
    n += count (child, match);
  return n;
}

static gboolean
match_toggle (GtkWidget *widget, gconstpointer data)
{
  return GTK_IS_TOGGLE_BUTTON (widget);
}

/* Three panels: the lower 48, and Alaska and Hawaii inset. One view cannot
 * hold all three. */
static void
test_map_has_three_panels (void)
{
  GtkWidget *map = hosted (lk_coverage_map_new (noaa));

  g_assert_nonnull (map);
  g_assert_cmpuint (count (map, match_drawing_area), ==, 3);
  /* Each inset is named, so neither reads as an island off Oregon. */
  g_assert_nonnull (lk_test_find_label (map, "Alaska"));
  g_assert_nonnull (lk_test_find_label (map, "Hawaii"));
}

/* One pill per region, under the region's own name, and every one of them
 * stood down until a catalog can price the pick. */
static void
test_pills_follow_the_model (void)
{
  GtkWidget *pills = hosted (lk_noaa_region_pills_new (noaa));
  guint n = 0;
  const LkNoaaRegion *regions = lk_noaa_regions (noaa, &n);

  g_assert_cmpuint (count (pills, match_toggle), ==, n);

  for (guint i = 0; i < n; i++)
    {
      GtkWidget *pill = lk_test_find_button (pills, regions[i].name);

      g_assert_nonnull (pill);
      /* No catalog: nothing to pick against. */
      g_assert_false (gtk_widget_get_sensitive (pill));
      g_assert_false (gtk_toggle_button_get_active (GTK_TOGGLE_BUTTON (pill)));
    }

  /* A pick made anywhere shows on the pill. The map and the pills are two
   * views of one selection, so neither may hold state of its own. */
  GtkWidget *first = lk_test_find_button (pills, regions[0].name);
  lk_noaa_toggle (noaa, regions[0].id);
  lk_test_drain ();
  g_assert_true (gtk_toggle_button_get_active (GTK_TOGGLE_BUTTON (first)));
  g_assert_true (gtk_widget_has_css_class (first, "suggested-action"));

  lk_noaa_toggle (noaa, regions[0].id);
  lk_test_drain ();
  g_assert_false (gtk_toggle_button_get_active (GTK_TOGGLE_BUTTON (first)));
  g_assert_false (gtk_widget_has_css_class (first, "suggested-action"));
}

/* The catalog line says nothing until there is something to say. An empty
 * sentence over an empty map is chrome with no content. */
static void
test_catalog_line_quiet_when_idle (void)
{
  GtkWidget *line = hosted (lk_noaa_catalog_line_new (noaa));
  GtkWidget *again = lk_test_find_button (line, "Try Again");

  g_assert_nonnull (again);
  g_assert_false (lk_test_shown (line, window));
  g_assert_false (gtk_widget_get_visible (again));
}

/* What a click asks: the point against a region's own boxes, projected into
 * the panel. The lower-48 window and district 5, whose extent is the
 * Chesapeake and the New Jersey coast. */
static void
test_region_hit (void)
{
  const LkMapWindow window48 = { .west = -132, .east = -64, .south = 20, .north = 52 };
  const LkNoaaRegion *d5 = lk_noaa_region (noaa, "d5");
  LkNoaaBox box;
  double x = 0, y = 0;

  g_assert_nonnull (d5);
  box = (LkNoaaBox) { d5->west, d5->south, d5->east, d5->north };

  /* The middle of the region's own water is a hit. */
  lk_map_window_point (&window48, (d5->west + d5->east) / 2, (d5->south + d5->north) / 2,
                       680, 320, &x, &y);
  g_assert_true (lk_region_box_hit (&box, 1, &window48, 680, 320, x, y));

  /* Each corner, which is where a box's tolerance matters. */
  lk_map_window_point (&window48, d5->west, d5->north, 680, 320, &x, &y);
  g_assert_true (lk_region_box_hit (&box, 1, &window48, 680, 320, x, y));

  /* Open water off California is not district 5. */
  lk_map_window_point (&window48, -126, 36, 680, 320, &x, &y);
  g_assert_false (lk_region_box_hit (&box, 1, &window48, 680, 320, x, y));

  /* Nor is a point north of it. */
  lk_map_window_point (&window48, (d5->west + d5->east) / 2, 48, 680, 320, &x, &y);
  g_assert_false (lk_region_box_hit (&box, 1, &window48, 680, 320, x, y));

  /* No boxes is no hit, however the caller asks. */
  g_assert_false (lk_region_box_hit (NULL, 0, &window48, 680, 320, 10, 10));
  g_assert_false (lk_region_box_hit (&box, 0, &window48, 680, 320, x, y));
}

/* The click gesture on a panel. GTK4 offers no way to synthesize a press, so
 * the gesture is driven where the panel wired it. */
static GtkGesture *
click_gesture_of (GtkWidget *area)
{
  g_autoptr (GListModel) controllers = gtk_widget_observe_controllers (area);
  guint n = g_list_model_get_n_items (controllers);

  for (guint i = 0; i < n; i++)
    {
      g_autoptr (GtkEventController) c = g_list_model_get_item (controllers, i);

      if (GTK_IS_GESTURE_CLICK (c))
        return GTK_GESTURE (g_steal_pointer (&c));
    }
  return NULL;
}

/* A click with no catalog changes nothing. The map draws the regions' rough
 * extents until the catalog lands, and a pick made against those would be
 * priced against water the catalog has not described yet. */
static void
test_click_needs_a_catalog (void)
{
  GtkWidget *map = hosted (lk_coverage_map_new (noaa));
  GtkWidget *area = lk_test_find (map, match_drawing_area, NULL);
  const LkNoaaRegion *d5 = lk_noaa_region (noaa, "d5");
  const LkMapWindow window48 = { .west = -132, .east = -64, .south = 20, .north = 52 };
  double x = 0, y = 0;

  g_assert_nonnull (area);
  g_assert_nonnull (d5);
  g_assert_cmpuint (lk_noaa_picked_count (noaa), ==, 0);

  g_autoptr (GtkGesture) click = click_gesture_of (area);
  g_assert_nonnull (click);

  /* Squarely on district 5's own water. */
  lk_map_window_point (&window48, (d5->west + d5->east) / 2, (d5->south + d5->north) / 2,
                       gtk_widget_get_width (area), gtk_widget_get_height (area), &x, &y);
  g_signal_emit_by_name (click, "pressed", 1, x, y);
  lk_test_drain ();

  g_assert_cmpuint (lk_noaa_picked_count (noaa), ==, 0);
}

int
main (int argc, char *argv[])
{
  lk_test_gtk_init (&argc, &argv);

  model = lk_app_model_new ();
  noaa = lk_app_model_get_noaa (model);
  window = gtk_window_new ();
  gtk_window_set_default_size (GTK_WINDOW (window), 900, 700);
  gtk_window_present (GTK_WINDOW (window));
  lk_test_drain ();

  g_test_add_func ("/coverage/map-has-three-panels", test_map_has_three_panels);
  g_test_add_func ("/coverage/pills-follow-the-model", test_pills_follow_the_model);
  g_test_add_func ("/coverage/catalog-line-quiet", test_catalog_line_quiet_when_idle);
  g_test_add_func ("/coverage/region-hit", test_region_hit);
  g_test_add_func ("/coverage/click-needs-a-catalog", test_click_needs_a_catalog);

  return g_test_run ();
}
