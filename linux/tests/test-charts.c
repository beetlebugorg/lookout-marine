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

/* The Charts PAGE, not the whole window: every page is in the one stack, so a
 * search from the window reaches the controls of all of them. */
static GtkWidget *
charts_page (GtkWidget *pane)
{
  GtkWidget *stack = lk_test_find_type (pane, GTK_TYPE_STACK);

  g_assert_nonnull (stack);
  return gtk_stack_get_child_by_name (GTK_STACK (stack), "charts");
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
 * and files they already hold.
 *
 * TWO ROWS, and the second covers everything on the disk: a folder of cells,
 * an archive, a prepared chart, a picture. One GtkFileDialog picks files or
 * folders and never both, so that row offers the two pickers. */
static void
test_add_rows (void)
{
  GtkWidget *pane = charts_pane ();
  static const char *rows[] = {
    "Get charts from NOAA…",
    "Add charts from this computer…",
  };

  for (gsize i = 0; i < G_N_ELEMENTS (rows); i++)
    {
      GtkWidget *row = lk_test_find_label (pane, rows[i]);

      g_assert_nonnull (row);
      g_assert_true (lk_test_shown (row, pane));
    }

  g_assert_nonnull (lk_test_find_button (pane, "Choose a Folder…"));
  g_assert_nonnull (lk_test_find_button (pane, "Choose a File…"));

  /* The rows the merge replaced. A second way in to the same files is what
   * made a mariner remember which row a file had gone in by. */
  g_assert_null (lk_test_find_label (pane, "Add an archive…"));
  g_assert_null (lk_test_find_label (pane, "Add pictures…"));

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

/* A pick says so before the core is told.
 *
 * Reading a publisher's style is the core's work and it runs inside a frame:
 * a 389 layer style with a 5,354 cell sprite pack holds the main thread for
 * over a second. The row is rebuilt in the click itself, so the tile carries
 * the line while that happens; the call to the core waits for the frame that
 * draws it. */
static void
test_a_pick_says_it_is_reading (void)
{
  GtkWidget *pane = charts_pane ();
  GtkWidget *tile = lk_test_find_button (pane, "Open Waters Seascape");

  g_assert_nonnull (tile);
  g_assert_null (lk_test_find_label (pane, "Reading this chart…"));

  /* No drain: the line has to be there the moment the click returns. */
  g_signal_emit_by_name (tile, "clicked");
  g_assert_nonnull (lk_test_find_label (pane, "Reading this chart…"));

  gtk_window_destroy (GTK_WINDOW (pane));
  lk_test_drain ();
}

/* The link field is NOT on the pane. It stood open on every visit with the
 * sentence explaining what a chart link is beside it, and most visits add no
 * link. The gallery's last tile raises both instead. */
static void
test_link_field_is_not_on_the_pane (void)
{
  GtkWidget *pane = charts_pane ();
  GtkWidget *page = charts_page (pane);

  g_assert_nonnull (page);
  g_assert_null (lk_test_find_type (page, GTK_TYPE_ENTRY));
  g_assert_null (lk_test_find_label (page, "Add Chart Link"));

  gtk_window_destroy (GTK_WINDOW (pane));
  lk_test_drain ();
}

/* The Add tile raises the form. Add stays out of reach until a link is typed:
 * the window has one thing to do and nothing to do it with yet. */
static void
test_add_tile_raises_the_form (void)
{
  GtkWidget *pane = charts_pane ();
  GtkWidget *tile = lk_test_find_button (pane, "Add a chart");
  GtkWidget *entry, *add;
  GtkWindow *form = NULL;

  g_assert_nonnull (tile);
  g_signal_emit_by_name (tile, "clicked");
  lk_test_drain ();

  g_autoptr (GList) windows = g_list_copy (gtk_window_list_toplevels ());
  for (GList *l = windows; l != NULL; l = l->next)
    if (g_strcmp0 (gtk_window_get_title (l->data), "Add a Chart") == 0)
      form = l->data;
  g_assert_nonnull (form);

  entry = lk_test_find_type (GTK_WIDGET (form), GTK_TYPE_ENTRY);
  add = lk_test_find_button (GTK_WIDGET (form), "Add");
  g_assert_nonnull (entry);
  g_assert_nonnull (add);
  g_assert_false (gtk_widget_get_sensitive (add));

  gtk_editable_set_text (GTK_EDITABLE (entry), "https://example.org/style.json");
  g_assert_true (gtk_widget_get_sensitive (add));

  /* And whitespace alone is not a link. */
  gtk_editable_set_text (GTK_EDITABLE (entry), "   ");
  g_assert_false (gtk_widget_get_sensitive (add));

  gtk_window_destroy (form);
  gtk_window_destroy (GTK_WINDOW (pane));
  lk_test_drain ();
}

/* The row stays where the mariner scrolled it. A tile off the left edge cannot
 * be picked if a rebuild puts the row home under the pointer, and a pick is
 * exactly what rebuilds it. */
static void
test_pick_holds_the_scroll (void)
{
  GtkWidget *gallery = lk_chart_gallery_new (model, on_add, NULL);
  GtkAdjustment *adjustment;
  double room = 0;

  /* Narrower than the tiles need, so the row can scroll at all. halign START
   * holds it to the width asked for inside a much wider window. */
  gtk_widget_set_size_request (gallery, 500, -1);
  gtk_widget_set_halign (gallery, GTK_ALIGN_START);
  gtk_window_set_child (GTK_WINDOW (window), gallery);
  adjustment = gtk_scrolled_window_get_hadjustment (GTK_SCROLLED_WINDOW (gallery));

  for (int i = 0; i < 400; i++)
    {
      room = gtk_adjustment_get_upper (adjustment) - gtk_adjustment_get_page_size (adjustment);
      if (room > 60)
        break;
      g_main_context_iteration (NULL, FALSE);
      g_usleep (5000);
    }
  g_assert_cmpfloat (room, >, 60);

  gtk_adjustment_set_value (adjustment, 60);
  lk_test_drain ();
  g_assert_cmpfloat (gtk_adjustment_get_value (adjustment), ==, 60);

  /* A pick rebuilds the row: the tile picked says it is being read. A real
   * click focuses the button first, and the rebuild destroys what it focused. */
  g_autoptr (GPtrArray) tiles = tiles_of (gallery);
  gtk_widget_grab_focus (g_ptr_array_index (tiles, 1));
  lk_test_drain ();
  g_signal_emit_by_name (g_ptr_array_index (tiles, 1), "clicked");
  for (int i = 0; i < 80; i++)
    {
      g_main_context_iteration (NULL, FALSE);
      g_usleep (5000);
    }

  g_assert_cmpfloat (gtk_adjustment_get_value (adjustment), ==, 60);
}

/* The pick STAYS on the tile the mariner picked while the core reads it.
 *
 * An add does not set the core's active url until the style has landed, and no
 * active url means Lookout's own chart — so a row that drops the pick the
 * moment the core is told puts the ACTIVE ring straight back on the Lookout
 * tile, which reads as the pick being refused. */
static void
test_pick_stays_on_the_tile (void)
{
  GtkWidget *gallery = hosted_gallery ();
  g_autoptr (GPtrArray) tiles = tiles_of (gallery);
  GtkWidget *own = g_ptr_array_index (tiles, 0);
  GtkWidget *tile = g_ptr_array_index (tiles, 1);

  g_signal_emit_by_name (tile, "clicked");

  /* Past the frame the row waits for, so the core has been told. */
  for (int i = 0; i < 40; i++)
    {
      g_main_context_iteration (NULL, FALSE);
      g_usleep (5000);
    }

  /* And a rebuild after that, which is where the pick used to be lost. */
  g_signal_emit_by_name (lk_app_model_get_chart_links (model), "changed");
  lk_test_drain ();

  g_autoptr (GPtrArray) after = tiles_of (gallery);
  own = g_ptr_array_index (after, 0);
  tile = g_ptr_array_index (after, 1);

  g_assert_nonnull (lk_test_find_label (tile, "Reading this chart…"));
  g_assert_true (gtk_widget_has_css_class (tile, "lk-chart-tile-active"));
  g_assert_null (lk_test_find_label (own, "Reading this chart…"));
  g_assert_false (gtk_widget_has_css_class (own, "lk-chart-tile-active"));
}

/* Clicking the tile of the chart already drawing does nothing at all.
 *
 * The click stores the pick and rebuilds the row, and the rebuild retires a
 * pick the core has already answered for. A pick of the chart on screen is
 * answered at once, so the act that ran 25 ms later read a pick that had
 * gone and dereferenced NULL. */
static void
test_clicking_the_active_tile_is_ignored (void)
{
  GtkWidget *gallery = hosted_gallery ();
  g_autoptr (GPtrArray) tiles = tiles_of (gallery);
  GtkWidget *own = g_ptr_array_index (tiles, 0);

  /* Lookout's own chart draws when no link is active, which is this suite. */
  g_assert_null (lk_chart_links_active (lk_app_model_get_chart_links (model)));
  g_assert_true (gtk_widget_has_css_class (own, "lk-chart-tile-active"));

  g_signal_emit_by_name (own, "clicked");

  /* Past the 25 ms the act waits, where the crash was. */
  for (int i = 0; i < 40; i++)
    {
      g_main_context_iteration (NULL, FALSE);
      g_usleep (5000);
    }

  /* The row still reads as it did, and the core was never asked. */
  g_autoptr (GPtrArray) after = tiles_of (gallery);
  own = g_ptr_array_index (after, 0);
  g_assert_true (gtk_widget_has_css_class (own, "lk-chart-tile-active"));
  g_assert_null (lk_test_find_label (own, "Reading this chart…"));
  g_assert_null (lk_chart_links_active (lk_app_model_get_chart_links (model)));
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
  g_test_add_func ("/charts/a-pick-says-it-is-reading", test_a_pick_says_it_is_reading);
  g_test_add_func ("/charts/empty-library", test_empty_library);
  g_test_add_func ("/charts/clicking-the-active-tile-is-ignored",
                   test_clicking_the_active_tile_is_ignored);
  g_test_add_func ("/charts/pick-stays-on-the-tile", test_pick_stays_on_the_tile);
  g_test_add_func ("/charts/pick-holds-the-scroll", test_pick_holds_the_scroll);
  g_test_add_func ("/charts/link-field-off-the-pane", test_link_field_is_not_on_the_pane);
  g_test_add_func ("/charts/add-tile-raises-the-form", test_add_tile_raises_the_form);

  return g_test_run ();
}
