/* test-charts.c — the Charts pane, and the chart gallery in it.
 *
 * One chart draws at a time, so the gallery is a pick-one control. What is
 * checked here is what a mariner sees before they have picked anything: the
 * order of the tiles, which one is marked as drawing, which ones offer to be
 * removed, and that every tile the app ships carries a picture.
 *
 * The engine has no chart open, so the core's chart-link list is empty and the
 * shipped entries are the whole shelf. That is a fresh install, which is the
 * state this pane most has to get right.
 */

#include "lk-test.h"

#include "model/app-model.h"
#include "ui/charts/catalog.h"
#include "ui/charts/gallery.h"
#include "ui/settings/window.h"

static LkAppModel *model;
static GtkWidget  *window;
static guint       add_asked;

static void
on_add (gpointer user_data)
{
  add_asked++;
}

static GtkWidget *
hosted_gallery (void)
{
  GtkWidget *gallery = lk_chart_gallery_new (model, on_add, NULL);

  gtk_window_set_child (GTK_WINDOW (window), gallery);
  lk_test_drain ();
  return gallery;
}

/* The row of tiles, in order. The gallery is a horizontal box inside a
 * scroller, so the tiles are the box's children. */
static GPtrArray *
tiles_of (GtkWidget *gallery)
{
  GtkWidget *row = gtk_scrolled_window_get_child (GTK_SCROLLED_WINDOW (gallery));
  GPtrArray *tiles = g_ptr_array_new ();

  /* The scroller wraps its child in a viewport. */
  if (GTK_IS_VIEWPORT (row))
    row = gtk_viewport_get_child (GTK_VIEWPORT (row));
  g_assert_nonnull (row);

  for (GtkWidget *child = gtk_widget_get_first_child (row);
       child != NULL;
       child = gtk_widget_get_next_sibling (child))
    g_ptr_array_add (tiles, child);
  return tiles;
}

/* Lookout's own chart first, then the charts the app ships, then the way to
 * add one. Holding that order steady is what keeps the cards where they were
 * when a mariner picks one. */
static void
test_tile_order (void)
{
  GtkWidget *gallery = hosted_gallery ();
  g_autoptr (GPtrArray) tiles = tiles_of (gallery);
  guint n_catalog = 0;
  const LkChartCatalogEntry *catalog = lk_chart_catalog_entries (&n_catalog);

  g_assert_cmpuint (tiles->len, ==, 1 + n_catalog + 1);

  g_assert_nonnull (lk_test_find_label (g_ptr_array_index (tiles, 0), "Lookout chart"));
  for (guint i = 0; i < n_catalog; i++)
    g_assert_nonnull (lk_test_find_label (g_ptr_array_index (tiles, i + 1),
                                          catalog[i].name));
  g_assert_nonnull (lk_test_find_label (g_ptr_array_index (tiles, tiles->len - 1),
                                        "Add a chart"));
}

/* With no link picked, Lookout's own chart is the one drawing, and it says so.
 * It is built from the sets and cannot be removed, so it offers no menu. */
static void
test_own_chart_is_active (void)
{
  GtkWidget *gallery = hosted_gallery ();
  g_autoptr (GPtrArray) tiles = tiles_of (gallery);
  GtkWidget *own = g_ptr_array_index (tiles, 0);

  g_assert_true (gtk_widget_has_css_class (own, "lk-chart-tile-active"));
  g_assert_nonnull (lk_test_find_label (own, "ACTIVE"));
  g_assert_nonnull (lk_test_find_label (own, "From your chart sets"));
  g_assert_null (lk_test_find_type (own, GTK_TYPE_MENU_BUTTON));

  /* And nothing else is drawing. */
  for (guint i = 1; i < tiles->len; i++)
    {
      GtkWidget *tile = g_ptr_array_index (tiles, i);

      g_assert_false (gtk_widget_has_css_class (tile, "lk-chart-tile-active"));
      g_assert_null (lk_test_find_label (tile, "ACTIVE"));
    }
}

/* A chart the app ships shows the picture it ships, and names the url its
 * tiles come from. Lookout runs none of these services, so the card has to
 * say whose chart it is. */
static void
test_shipped_tiles (void)
{
  GtkWidget *gallery = hosted_gallery ();
  g_autoptr (GPtrArray) tiles = tiles_of (gallery);
  guint n_catalog = 0;
  const LkChartCatalogEntry *catalog = lk_chart_catalog_entries (&n_catalog);

  for (guint i = 0; i < n_catalog; i++)
    {
      GtkWidget *tile = g_ptr_array_index (tiles, i + 1);
      GtkWidget *picture = lk_test_find_type (tile, GTK_TYPE_PICTURE);

      g_assert_nonnull (picture);
      g_assert_true (gdk_paintable_get_intrinsic_width (
                         gtk_picture_get_paintable (GTK_PICTURE (picture))) > 0);
      g_assert_cmpstr (gtk_widget_get_tooltip_text (tile), ==, catalog[i].url);
      g_assert_nonnull (lk_test_find_label (tile, catalog[i].url));

      /* Not on the mariner's list yet, so there is no link of theirs to drop. */
      g_assert_null (lk_test_find_type (tile, GTK_TYPE_MENU_BUTTON));
    }

  /* Lookout's own chart is pictured too, so the row is never a line of grey
   * boxes on a fresh install. */
  g_assert_nonnull (lk_test_find_type (g_ptr_array_index (tiles, 0), GTK_TYPE_PICTURE));
}

/* The last tile asks the page to raise the form. Adding a chart by link and
 * adding one from a file are the same decision, and the page owns it. */
static void
test_add_tile_asks (void)
{
  GtkWidget *gallery = hosted_gallery ();
  g_autoptr (GPtrArray) tiles = tiles_of (gallery);
  GtkWidget *add = g_ptr_array_index (tiles, tiles->len - 1);

  add_asked = 0;
  g_assert_true (GTK_IS_BUTTON (add));
  g_signal_emit_by_name (add, "clicked");
  lk_test_drain ();
  g_assert_cmpuint (add_asked, ==, 1);
}

/* The pane itself, as the settings window builds it. */
static GtkWidget *
charts_pane (void)
{
  GtkWidget *settings = lk_settings_window_new (model, NULL, "charts");

  g_assert_nonnull (settings);
  lk_test_drain ();
  return settings;
}

/* The sections, in the order a mariner asks: which chart is DRAWN, what it is
 * built from, what is arriving, and where to get more. */
static void
test_pane_order (void)
{
  GtkWidget *pane = charts_pane ();
  GtkWidget *active = lk_test_find_label (pane, "Active chart");
  GtkWidget *sets = lk_test_find_label (pane, "Your chart sets");
  GtkWidget *arriving = lk_test_find_label (pane, "Arriving now");
  GtkWidget *add = lk_test_find_label (pane, "Add charts");

  g_assert_nonnull (active);
  g_assert_nonnull (sets);
  g_assert_nonnull (arriving);
  g_assert_nonnull (add);

  /* Nothing is arriving, so that section is not a heading over empty space. */
  g_assert_false (lk_test_shown (arriving, pane));

  /* ONE list of what is installed. The separate picture list is gone: a
   * mariner had to remember which panel a file went into. */
  g_assert_null (lk_test_find_label (pane, "Raster charts"));
  /* And the gallery says which chart is drawn, so nothing reports the open
   * file a second time. */
  g_assert_null (lk_test_find_label (pane, "Open"));
  g_assert_null (lk_test_find_label (pane, "No chart open"));

  gtk_window_destroy (GTK_WINDOW (pane));
  lk_test_drain ();
}

/* Every way to add charts, each saying what it does. A mariner choosing
 * between NOAA and their own folder is choosing between free official cover
 * and files they already hold. */
static void
test_add_rows (void)
{
  GtkWidget *pane = charts_pane ();
  static const char *rows[] = {
    "Get charts from NOAA…",
    "Add charts from this computer…",
    "Add an archive…",
    "Add pictures…",
  };

  for (gsize i = 0; i < G_N_ELEMENTS (rows); i++)
    {
      GtkWidget *row = lk_test_find_button (pane, rows[i]);

      g_assert_nonnull (row);
      g_assert_true (lk_test_shown (row, pane));
    }

  /* The kinds a file can be, in one place. A mariner with a .kap sheet has to
   * be able to find out that it works. */
  g_assert_nonnull (lk_test_find (pane, lk_test_match_css_class, "dim-label"));

  gtk_window_destroy (GTK_WINDOW (pane));
  lk_test_drain ();
}

/* With nothing installed the library says so, and the gallery still offers the
 * charts the app ships. */
static void
test_empty_library (void)
{
  GtkWidget *pane = charts_pane ();

  g_assert_nonnull (lk_test_find_label (pane, "No chart sets yet"));
  g_assert_nonnull (lk_test_find_label (pane, "Lookout chart"));
  g_assert_nonnull (lk_test_find_label (pane, "Add a chart"));

  gtk_window_destroy (GTK_WINDOW (pane));
  lk_test_drain ();
}

int
main (int argc, char *argv[])
{
  lk_test_gtk_init (&argc, &argv);

  model = lk_app_model_new ();
  window = gtk_window_new ();
  gtk_window_set_default_size (GTK_WINDOW (window), 900, 400);
  gtk_window_present (GTK_WINDOW (window));
  lk_test_drain ();

  g_test_add_func ("/charts/tile-order", test_tile_order);
  g_test_add_func ("/charts/own-chart-is-active", test_own_chart_is_active);
  g_test_add_func ("/charts/shipped-tiles", test_shipped_tiles);
  g_test_add_func ("/charts/add-tile-asks", test_add_tile_asks);
  g_test_add_func ("/charts/pane-order", test_pane_order);
  g_test_add_func ("/charts/add-rows", test_add_rows);
  g_test_add_func ("/charts/empty-library", test_empty_library);

  return g_test_run ();
}
