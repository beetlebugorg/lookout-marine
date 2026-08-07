/* main.c — the GtkApplication entry point.
 *
 * One window and one LkAppModel for the life of the app. Accelerators mirror
 * the macOS menu bar, Ctrl for Command.
 */

#include <gtk/gtk.h>

#include "lk-app-model.h"
#include "lk-window.h"

#define LK_APP_ID "org.beetlebug.LookoutMarine"

/* The chrome the stock stylesheet has no class for. The sizes and the colours
 * are the ones every shell uses (windows/ui/MainWindow.xaml, Chrome.swift,
 * Chrome.kt), expressed against the theme's own colours so the app follows a
 * light or a dark desktop. Plain GTK lacks libadwaita's @window_bg_color, so
 * these mix against @theme_bg_color. */
static const char *LK_CSS =
    /* The chart window is transparent where the chart-view widget paints nothing,
     * so the below subsurface shows through and the chrome floats over it. */
    ".lk-chart-window { background: transparent; }"
    /* The startup loader and the empty state. They stand over the chart hole,
     * which is transparent until the first frame lands, so the card carries
     * its own opaque surface — a tint of the text colour showed through to the
     * desktop and was barely legible. */
    ".lk-card {"
    "  background: alpha(@theme_bg_color, 0.96);"
    "  border: 1px solid alpha(@borders, 0.5);"
    "  border-radius: 16px;"
    "  padding: 32px 40px;"
    "  box-shadow: 0 4px 16px alpha(black, 0.25);"
    "}"
    /* The readouts, as a capsule at the bottom centre. */
    ".lk-capsule {"
    "  background: alpha(@theme_bg_color, 0.94);"
    "  border: 1px solid alpha(@borders, 0.5);"
    "  border-radius: 999px;"
    "  padding: 0 18px;"
    "  box-shadow: 0 2px 6px alpha(black, 0.18);"
    "}"
    ".lk-capsule.lk-compact { padding: 0 14px; font-size: 90%; }"
    ".lk-capsule separator { background: alpha(@borders, 0.8); }"
    ".lk-amber-dot { background: #f59e0b; border-radius: 999px; }"
    ".lk-accent { color: @accent_color; }"
    /* The 1:N readout is a control, but it must read as a readout: no frame
     * until the pointer finds it. */
    ".lk-scale-button, .lk-scale-button > button {"
    "  padding: 2px 5px;"
    "  min-height: 0;"
    "  min-width: 0;"
    "  border: none;"
    "  border-radius: 6px;"
    "  background: none;"
    "  box-shadow: none;"
    "}"
    ".lk-scale-button > button:hover { background: alpha(currentColor, 0.10); }"
    ".lk-scale-button > button:active { background: alpha(currentColor, 0.16); }"
    /* The band the view is already in, marked among the scale presets. */
    ".lk-preset-current {"
    "  background: alpha(@accent_color, 0.14);"
    "  box-shadow: inset 0 0 0 1px alpha(@accent_color, 0.5);"
    "}"
    /* The build indicator, and any other floating pill. */
    ".lk-pill {"
    "  background: alpha(@theme_bg_color, 0.92);"
    "  border: 1px solid alpha(@borders, 0.5);"
    "  border-radius: 999px;"
    "  padding: 5px 12px;"
    "  box-shadow: 0 1px 4px alpha(black, 0.18);"
    "}"
    /* A floating panel: the pick report. It is opaque — the chart showing
     * through a table of numbers makes both hard to read. */
    ".lk-panel {"
    "  background: @theme_base_color;"
    "  border: 1px solid alpha(@borders, 0.7);"
    "  border-radius: 12px;"
    "  box-shadow: 0 4px 12px alpha(black, 0.22);"
    "}"
    /* The object column is a shaded shelf beside the report. Its scroller and
     * its list paint the base colour by default, which would cover that. */
    ".lk-object-list {"
    "  background: alpha(currentColor, 0.05);"
    /* The shelf is flush with the panel's leading edge, so it carries the
     * panel's corners on that side. */
    "  border-radius: 12px 0 0 12px;"
    "}"
    ".lk-object-list scrolledwindow, .lk-object-list list { background: none; }"
    /* The highlight is a rounded plate, not a band across the shelf: the margin
     * holds it clear of the shelf's edges and the padding keeps the two lines
     * off it. The numbers are PickReport.swift's, so a row stands the same on
     * both, and 9 + 11 puts the title under the heading above it. */
    ".lk-object-list row {"
    "  padding: 9px 11px;"
    "  margin: 1px 9px;"
    "  border-radius: 7px;"
    "}"
    ".lk-object-list row:selected { background: alpha(@accent_color, 0.14); }"
    ".lk-object-list row:selected label { color: @accent_color; }"
    ".lk-fold { border-radius: 0 0 12px 12px; }"
    ".lk-fold label { color: alpha(currentColor, 0.7); }"
    /* A note the mariner reads before the attributes: INFORM, promoted. */
    ".lk-note {"
    "  background: alpha(@warning_color, 0.12);"
    "  border: 1px solid alpha(@warning_color, 0.4);"
    "  border-radius: 8px;"
    "  padding: 9px 10px;"
    "}"
    ".lk-aux-text {"
    "  background: alpha(currentColor, 0.05);"
    "  border-radius: 6px;"
    "  padding: 8px;"
    "}"
    ".lk-aux-picture { border-radius: 6px; }"
    ".lk-bubble {"
    "  min-width: 40px;"
    "  min-height: 40px;"
    "  padding: 0;"
    "  border-radius: 999px;"
    "  background: alpha(@theme_bg_color, 0.92);"
    "  border: 1px solid alpha(@borders, 0.5);"
    "  box-shadow: 0 1px 4px alpha(black, 0.2);"
    "}"
    /* The distance bar's label sits directly on the chart, which can be any
     * colour. The shadow in the window's own background colour keeps it
     * readable on both a light and a dark scheme. */
    ".lk-scale-bar-label {"
    "  font-weight: bold;"
    "  font-size: 90%;"
    "  text-shadow: 0 1px 2px alpha(@theme_bg_color, 0.9);"
    "}"
    ".lk-overscale {"
    "  color: @warning_color;"
    "  font-weight: bold;"
    "  background: alpha(@warning_color, 0.18);"
    "  border-radius: 999px;"
    "  padding: 1px 7px;"
    "}"
    /* The raster chart pill, at the end of the capsule. The COLOUR reports the
     * raster chart, not the ENC: the accent while the picture is drawn, amber
     * while one is here and off. It is a control, so it must not carry a button
     * frame inside a readout. */
    ".lk-raster-pill > button {"
    "  padding: 1px 7px;"
    "  min-height: 0;"
    "  min-width: 0;"
    "  border: none;"
    "  box-shadow: none;"
    "  border-radius: 8px;"
    "  font-size: 90%;"
    "  font-weight: bold;"
    "  color: @accent_color;"
    "  background: alpha(@accent_color, 0.18);"
    "}"
    ".lk-raster-pill.lk-off > button {"
    "  color: @warning_color;"
    "  background: alpha(@warning_color, 0.28);"
    "}"
    ".lk-raster-pill > button:hover { background: alpha(@accent_color, 0.30); }"
    ".lk-raster-pill.lk-off > button:hover { background: alpha(@warning_color, 0.42); }"
    ".lk-raster-bar { opacity: 0.5; }";

static void
lk_app_activate (GtkApplication *app, gpointer user_data)
{
  LkAppModel *model = user_data;
  GtkWindow *existing = gtk_application_get_active_window (app);

  if (existing != NULL)
    {
      gtk_window_present (existing);
      return;
    }

  gtk_window_present (GTK_WINDOW (lk_window_new (app, model)));
}

static void
lk_app_startup (GtkApplication *app, gpointer user_data)
{
  g_autoptr (GtkCssProvider) provider = gtk_css_provider_new ();

  gtk_css_provider_load_from_string (provider, LK_CSS);
  gtk_style_context_add_provider_for_display (gdk_display_get_default (),
                                              GTK_STYLE_PROVIDER (provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

  struct { const char *action; const char *accels[3]; } accels[] = {
    { "win.open",             { "<Control>o", NULL } },
    { "win.zoom-in",          { "<Control>plus", "<Control>equal", NULL } },
    { "win.zoom-out",         { "<Control>minus", NULL } },
    { "win.zoom-fit",         { "<Control>0", NULL } },
    { "win.north-up",         { "<Control>Up", NULL } },
    { "win.cycle-scheme",     { "<Control>l", NULL } },
    { "win.toggle-text",      { "<Control>t", NULL } },
    { "win.toggle-soundings", { "<Control><Shift>s", NULL } },
    { "win.toggle-other",     { "<Control>d", NULL } },
    { "win.search",           { "<Control>f", NULL } },
    { "win.close-pick",       { "Escape", NULL } },
    { "win.settings",         { "<Control>comma", NULL } },
    { "win.raster-cycle",     { "<Control>i", NULL } },
    { "win.raster-add",       { "<Control><Shift>i", NULL } },
    { "win.toggle-chart",     { "<Control><Shift>h", NULL } },
  };

  for (gsize i = 0; i < G_N_ELEMENTS (accels); i++)
    gtk_application_set_accels_for_action (app, accels[i].action, accels[i].accels);
}

int
main (int argc, char *argv[])
{
  g_set_application_name ("Lookout Marine");
  /* The icon every window falls back to. The name is the app id, which is what
   * meson installs the hicolor PNGs and the scalable SVG under and what the
   * .desktop file's Icon= names, so the three agree. Wayland takes the icon
   * from the .desktop file matched to the surface's app_id and never asks for
   * this; X11 does, and without it the window carries no icon at all. */
  gtk_window_set_default_icon_name (LK_APP_ID);

  g_autoptr (GtkApplication) app =
      gtk_application_new (LK_APP_ID, G_APPLICATION_DEFAULT_FLAGS);
  g_autoptr (LkAppModel) model = lk_app_model_new ();

  g_signal_connect (app, "startup", G_CALLBACK (lk_app_startup), model);
  g_signal_connect (app, "activate", G_CALLBACK (lk_app_activate), model);

  return g_application_run (G_APPLICATION (app), argc, argv);
}
