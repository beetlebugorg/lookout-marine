/* test-hud.c — the readouts capsule and its scale entry, as widgets.
 *
 * The model is real and the engine has no chart, so the readouts arrive the
 * way the render loop pushes them: through lk_app_model_push_readouts. Each
 * test pushes a state and reads the labels a mariner would read.
 */

#include "lk-test.h"

#include "model/app-model.h"
#include "lk-hud.h"

static LkAppModel *model;
static GtkWidget *window;
static GtkWidget *capsule;

static void
push (double zoom, double denominator, double overscale)
{
  lookout_view view = { .lon = -76.4767, .lat = 38.9763, .zoom = zoom,
                        .rotation_deg = 0 };
  lk_app_model_push_readouts (model, view, denominator, overscale, 0);
  lk_test_drain ();
}

static void
test_capsule_readouts (void)
{
  push (14.3, 13267, 1.0);

  /* Band, scale and zoom, exactly as the other shells print them. */
  g_assert_nonnull (lk_test_find_label (capsule, "Harbor"));
  g_assert_nonnull (lk_test_find_label (capsule, "1:13,267"));
  g_assert_nonnull (lk_test_find_label (capsule, "z14.3"));

  push (9.0, 320000, 1.0);
  g_assert_nonnull (lk_test_find_label (capsule, "General"));
  g_assert_nonnull (lk_test_find_label (capsule, "1:320,000"));
  g_assert_nonnull (lk_test_find_label (capsule, "z9.0"));
}

static void
test_overscale_badge (void)
{
  /* Amber only past 1.05: a badge that is always up is decoration. */
  push (14.0, 12000, 1.04);
  GtkWidget *badge = lk_test_find_label (capsule, "\303\2271.0");
  g_assert_true (badge == NULL || !lk_test_shown (badge, capsule));

  push (14.0, 12000, 1.5);
  badge = lk_test_find_label (capsule, "\303\2271.5");
  g_assert_nonnull (badge);
  g_assert_true (lk_test_shown (badge, capsule));

  push (14.0, 12000, 1.0);
  badge = lk_test_find_label (capsule, "\303\2271.0");
  g_assert_true (badge == NULL || !lk_test_shown (badge, capsule));
}

static void
test_fix_pill_without_source (void)
{
  /* No position source at all: the pill says how to get one, and the readout
   * shows no numbers — never the view centre. */
  push (14.0, 12000, 1.0);

  GtkWidget *pill = lk_test_find_button (capsule, "Configure GPS");
  g_assert_nonnull (pill);
  g_assert_true (lk_test_shown (pill, capsule));

  /* No coordinate text stands beside it. A label carrying a hemisphere would
   * be a position; there must be none visible. */
  GtkWidget *ghost = lk_test_find_label (capsule, "38\302\26058.578'N 076\302\26028.602'W");
  g_assert_true (ghost == NULL || !lk_test_shown (ghost, capsule));
}

static void
test_compact_mode (void)
{
  /* Below 700 points the capsule drops the band and takes a smaller type.
   * The class lands on the inner lk-capsule box, not the column around it. */
  GtkWidget *box = lk_test_find_css (capsule, "lk-capsule");
  g_assert_nonnull (box);

  lk_app_model_set_view_size (model, 650, 500);
  lk_test_drain ();
  g_assert_true (gtk_widget_has_css_class (box, "lk-compact"));
  GtkWidget *band = lk_test_find_label (capsule, "Harbor");
  g_assert_true (band == NULL || !lk_test_shown (band, capsule));

  lk_app_model_set_view_size (model, 1280, 800);
  lk_test_drain ();
  g_assert_false (gtk_widget_has_css_class (box, "lk-compact"));
  push (14.0, 12000, 1.0);
  band = lk_test_find_label (capsule, "Harbor");
  g_assert_nonnull (band);
  g_assert_true (lk_test_shown (band, capsule));
}

static void
test_scale_entry_validation (void)
{
  /* The 1:N readout opens the scale entry. Its Go button follows the parse,
   * and the hint names the band a valid scale lands in. */
  GtkWidget *menu_button = lk_test_find_type (capsule, GTK_TYPE_MENU_BUTTON);
  g_assert_nonnull (menu_button);
  GtkWidget *popover = GTK_WIDGET (gtk_menu_button_get_popover (GTK_MENU_BUTTON (menu_button)));
  g_assert_nonnull (popover);

  GtkWidget *entry = lk_test_find_type (popover, GTK_TYPE_ENTRY);
  GtkWidget *go = lk_test_find_button (popover, "Go");
  g_assert_nonnull (entry);
  g_assert_nonnull (go);

  gtk_editable_set_text (GTK_EDITABLE (entry), "not a scale");
  lk_test_drain ();
  g_assert_false (gtk_widget_get_sensitive (go));
  g_assert_nonnull (lk_test_find_label (popover,
      "Type a scale, for example 25,000 or 1:25k."));

  gtk_editable_set_text (GTK_EDITABLE (entry), "12,000");
  lk_test_drain ();
  g_assert_true (gtk_widget_get_sensitive (go));
  g_assert_nonnull (lk_test_find_label (popover,
      "Harbor band. The chart holds the nearest scale it has."));

  /* Out of range reads as not a scale: below 1:100 no chart exists. */
  gtk_editable_set_text (GTK_EDITABLE (entry), "99");
  lk_test_drain ();
  g_assert_false (gtk_widget_get_sensitive (go));
}

static void
test_scale_entry_presets (void)
{
  /* One usual scale for each band, as every shell offers. */
  GtkWidget *menu_button = lk_test_find_type (capsule, GTK_TYPE_MENU_BUTTON);
  GtkWidget *popover = GTK_WIDGET (gtk_menu_button_get_popover (GTK_MENU_BUTTON (menu_button)));

  const char *bands[] = { "Berthing", "Harbor", "Approach", "Coastal", "General" };
  const char *shorthands[] = { "1:2k", "1:12k", "1:50k", "1:150k", "1:700k" };
  for (gsize i = 0; i < G_N_ELEMENTS (bands); i++)
    {
      g_assert_nonnull (lk_test_find_label (popover, bands[i]));
      g_assert_nonnull (lk_test_find_label (popover, shorthands[i]));
    }
}

static void
test_north_bubble_tooltip (void)
{
  /* Unlocked reads as the invitation to follow. */
  GtkWidget *bubble = lk_north_bubble_new (model);
  g_object_ref_sink (bubble);
  lk_test_drain ();
  g_assert_cmpstr (gtk_widget_get_tooltip_text (bubble), ==, "Follow own ship");
  g_object_unref (bubble);
}

static void
test_scale_bar_hidden_without_scale (void)
{
  GtkWidget *bar = lk_scale_bar_new (model);
  g_object_ref_sink (bar);
  push (0, 0, 1.0);
  g_assert_false (gtk_widget_get_visible (bar));
  push (14.0, 12000, 1.0);
  g_assert_true (gtk_widget_get_visible (bar));
  g_object_unref (bar);
}

int
main (int argc, char *argv[])
{
  lk_test_gtk_init (&argc, &argv);

  model = lk_app_model_new ();
  capsule = lk_hud_capsule_new (model);

  window = gtk_window_new ();
  gtk_window_set_child (GTK_WINDOW (window), capsule);
  lk_app_model_set_view_size (model, 1280, 800);
  lk_test_drain ();

  g_test_add_func ("/hud/capsule-readouts", test_capsule_readouts);
  g_test_add_func ("/hud/overscale-badge", test_overscale_badge);
  g_test_add_func ("/hud/fix-pill-without-source", test_fix_pill_without_source);
  g_test_add_func ("/hud/compact-mode", test_compact_mode);
  g_test_add_func ("/hud/scale-entry-validation", test_scale_entry_validation);
  g_test_add_func ("/hud/scale-entry-presets", test_scale_entry_presets);
  g_test_add_func ("/hud/north-bubble-tooltip", test_north_bubble_tooltip);
  g_test_add_func ("/hud/scale-bar-hidden", test_scale_bar_hidden_without_scale);

  return g_test_run ();
}
