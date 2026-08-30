/* main.c — the GtkApplication entry point.
 *
 * One window and one LkAppModel for the life of the app. Accelerators mirror
 * the macOS menu bar, Ctrl for Command.
 */

#include <gtk/gtk.h>

#include "model/app-model.h"
#include "library/bake.h"
#include "ui/window.h"

#include "lk-resources.h"

#define LK_APP_ID "org.beetlebug.LookoutMarine"

/* The chrome the stock stylesheet has no class for. The sizes and the colours
 * are the ones every shell uses (windows/ui/MainWindow.xaml, Chrome.swift,
 * Chrome.kt), expressed against the theme's own colours so the app follows a
 * light or a dark desktop. Plain GTK lacks libadwaita's @window_bg_color, so
 * these mix against @theme_bg_color. */
static const char *LK_CSS =
    /* The accent, pinned. @accent_color is a libadwaita name, and where it
     * resolves at all under plain GTK it comes back pale; the chrome uses it
     * as a FILL under @accent_fg_color text, so the readouts came out white on
     * near-white. A chartplotter is read in sunlight, so the accent is stated
     * here instead of inherited: dark enough to carry white text, and to be
     * read as text itself on the capsule. */
    "@define-color accent_color #0a5bb5;"
    "@define-color accent_fg_color #ffffff;"
    /* Adwaita dims by opacity, which on the capsule's own light fill leaves the
     * secondary readouts at about 1:1. They are secondary, not decorative. */
    ".lk-capsule .dim-label { opacity: 1.0; color: #5f6b76; }"
    /* The chart window is transparent where the chart-view widget paints nothing,
     * so the below subsurface shows through and the chrome floats over it. */
    ".lk-chart-window { background: transparent; }"
    /* No chart, no chart window. The loader, the import panel and the first-run
     * page each stand on a plain page rather than over the water, and this fill
     * is what makes it a page: it covers the whole window, and the floating
     * bubbles with it, because a zoom control over a view with nothing to zoom
     * is chrome offering work it cannot do. The reference paints the same fill
     * (Chrome.panel, #F8F8F8) and its loader carries it too. Opaque: the chart
     * window is transparent, so anything less shows the desktop through it. */
    ".lk-page { background: @theme_bg_color; }"
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
    /* The position source, beside the position it qualifies. A solid pill reads
     * as a state that is good and settled, an outlined one as a state waiting
     * on the mariner, and the two bad states carry different colours as well as
     * different words: the readout has to be legible at a glance in bad light. */
    ".lk-fix-pill {"
    "  padding: 2px 7px;"
    "  min-height: 0;"
    "  min-width: 0;"
    "  border: 1px solid transparent;"
    "  box-shadow: none;"
    "  border-radius: 8px;"
    "}"
    ".lk-fix-pill.lk-fix-live {"
    "  color: @accent_fg_color;"
    "  background: @accent_color;"
    "}"
    ".lk-fix-pill.lk-fix-lost {"
    "  color: @error_color;"
    "  background: alpha(@error_color, 0.16);"
    "  border-color: alpha(@error_color, 0.55);"
    "}"
    ".lk-fix-pill.lk-fix-none {"
    "  color: @accent_color;"
    "  background: alpha(@accent_color, 0.16);"
    "  border-color: alpha(@accent_color, 0.55);"
    "}"
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
    /* The bubble pinned to a plugin's symbol. It is the pick report's panel at
     * a smaller size: a vessel's name and a handful of values, not a page. */
    ".lk-overlay-bubble { padding: 8px 10px; border-radius: 10px; }"
    /* A plugin's table window: a heading row that sorts, and rows the plugin's
     * own flag column colours. The tint is a wash behind the row, so the
     * system's selection still reads over it. */
    ".lk-table-header {"
    "  padding: 4px 8px;"
    "  border-bottom: 1px solid alpha(@borders, 0.7);"
    "}"
    ".lk-table-heading { padding: 2px 6px; min-height: 0; font-weight: bold; }"
    ".lk-table-rows row { padding: 3px 8px; }"
    ".lk-table-flagged.lk-alarm { background: alpha(@error_color, 0.22); }"
    ".lk-table-flagged.lk-warning { background: alpha(@warning_color, 0.20); }"
    ".lk-table-rows label.lk-alarm { color: @error_color; font-weight: bold; }"
    ".lk-table-rows label.lk-warning { color: @warning_color; font-weight: bold; }"
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
    /* The licenses screen. The facts, the NOTICE and each license text sit on
     * their own shaded block, so a page of terms reads as a page of blocks and
     * not as a wall. */
    ".lk-license-block {"
    "  background: alpha(currentColor, 0.05);"
    "  border-radius: 8px;"
    "  padding: 12px;"
    "}"
    /* A license is hard-wrapped at 80 columns by whoever wrote it. This is the
     * size at which the pane holds one without wrapping it again. */
    ".lk-license-text { font-size: 0.8em; }"
    /* The plugin alert strip, at the top centre. It is opaque, like the pick
     * report: an alarm read through the chart is an alarm somebody misses. The
     * severity colours are the chrome's own tokens, so the strip follows a
     * light or a dark desktop and never burns a night-adapted eye. */
    ".lk-alert-strip {"
    "  background: @theme_base_color;"
    "  border: 1px solid alpha(@borders, 0.7);"
    "  border-radius: 10px;"
    "  box-shadow: 0 4px 12px alpha(black, 0.22);"
    "}"
    ".lk-alert-strip separator { background: alpha(@borders, 0.6); }"
    /* The bar is the leading edge of a row. It carries the severity, so the
     * mariner reads which kind of alert it is before reading a word of it. */
    ".lk-alert-bar.lk-alarm   { background: @error_color; }"
    ".lk-alert-bar.lk-warning { background: @warning_color; }"
    ".lk-alert-bar.lk-notice  { background: @accent_color; }"
    ".lk-alert-strip .lk-alarm   { color: @error_color; }"
    ".lk-alert-strip .lk-warning { color: @warning_color; }"
    ".lk-alert-strip .lk-notice  { color: @accent_color; }"
    /* The first row carries the panel's top corners and the last its bottom
     * ones, so the severity bar never squares off the strip's edge. */
    ".lk-alert-strip > box:first-child .lk-alert-bar { border-radius: 10px 0 0 0; }"
    ".lk-alert-strip > box:last-child .lk-alert-bar { border-radius: 0 0 0 10px; }"
    ".lk-alert-ack {"
    "  padding: 3px 10px;"
    "  min-height: 0;"
    "  border-radius: 6px;"
    "  font-size: 90%;"
    "}"
    /* The chart menu header: a mark's name, and the coordinate under it. */
    ".lk-menu-title { font-weight: bold; padding: 4px 10px 0 10px; }"
    ".lk-menu-coord { padding: 2px 10px 6px 10px; font-size: 90%; }"
    /* The display settings' scheme swatches: a rounded palette, with a ring on
       the chosen one. */
    ".lk-swatch { border-radius: 8px; border: 1px solid alpha(@borders, 0.5); }"
    ".lk-swatch-current .lk-swatch { border: 3px solid @accent_color; }"
    /* The chosen scheme's name carries the choice with the ring. */
    ".lk-swatch-current label { font-weight: bold; }"
    /* The floating search capsule beside the top-left bubble, and its result
       row below the field. */
    ".lk-search-capsule {"
    "  padding: 4px 12px;"
    "  border-radius: 999px;"
    "  background: alpha(@theme_bg_color, 0.92);"
    "  border: 1px solid alpha(@borders, 0.5);"
    "  box-shadow: 0 1px 4px alpha(black, 0.2);"
    "}"
    ".lk-search-result {"
    "  padding: 6px 12px;"
    "  border-radius: 10px;"
    "  background: alpha(@theme_bg_color, 0.92);"
    "  border: 1px solid alpha(@borders, 0.5);"
    "}"
    ".lk-search-result.lk-search-go { color: @accent_color; }"
    /* 48px is LK_CHROME_BUBBLE, the bubble diameter Chrome.swift and Chrome.kt
       use. The layout reserves the same, so the two agree. */
    ".lk-bubble {"
    "  min-width: 48px;"
    "  min-height: 48px;"
    "  padding: 0;"
    "  border-radius: 999px;"
    "  background: alpha(@theme_bg_color, 0.92);"
    "  border: 1px solid alpha(@borders, 0.5);"
    "  box-shadow: 0 1px 4px alpha(black, 0.2);"
    "}"
    /* A menu bubble is a GtkMenuButton, which wraps its own button and draws a
     * second frame inside the bubble. The bubble is the only frame there is, so
     * the inner one is taken off and the round shape carries through to it. */
    "menubutton.lk-bubble > button {"
    "  min-width: 48px;"
    "  min-height: 48px;"
    "  padding: 0;"
    "  border-radius: 999px;"
    "  background: none;"
    "  border: none;"
    "  box-shadow: none;"
    "}"
    "menubutton.lk-bubble > button:hover { background: alpha(currentColor, 0.10); }"
    /* The compass bubble carries the FOLLOW LOCK. A ring while follow is on
     * and waiting for a fix, because nothing is being followed yet; a fill
     * once it has one. The mariner has to be able to tell those apart at a
     * glance: one of them means the instrument feed is the thing to look at. */
    ".lk-bubble.lk-mode-armed {"
    "  color: @accent_color;"
    "  border: 2px solid @accent_color;"
    "}"
    ".lk-bubble.lk-mode-on {"
    "  background: @accent_color;"
    "  color: @accent_fg_color;"
    "  border-color: alpha(@accent_color, 0.7);"
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
    ".lk-raster-bar { opacity: 0.5; }"
    /* Night. The dark-theme flip (ui/window.c, lk_window_apply_scheme) does
     * most of the work — every chrome fill above rides @theme_bg_color — and
     * this class quiets the surfaces further, so the brightest thing on deck
     * is the chart, never the readouts floating over it. The fix pill keeps
     * its state tints: they are the readout. */
    ".lk-night .lk-capsule, .lk-night .lk-bubble, .lk-night .lk-card,"
    ".lk-night .lk-pill, .lk-night .lk-panel {"
    "  background: alpha(#0d1117, 0.92);"
    "  border-color: alpha(#2c343f, 0.8);"
    "}"
    ".lk-night menubutton.lk-bubble > button { background: none; }"
    ".lk-night .lk-capsule .dim-label { color: #7f8894; }"
    /* The NOT FOR NAVIGATION block of the first-run page: amber, bordered,
     * set apart from everything about getting started. */
    ".lk-not-nav {"
    "  background: alpha(#f59e0b, 0.14);"
    "  border: 1px solid alpha(#f59e0b, 0.55);"
    "  border-radius: 9px;"
    "  padding: 12px;"
    "}"
    ".lk-not-nav-title { font-weight: bold; letter-spacing: 0.5px; font-size: 90%; }";

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

  /* The app's own icons, compiled into the binary. The settings sections draw
   * water, a chart, a boat and a bell, and the stock theme carries none of
   * them. This runs at STARTUP rather than in main: there is no display to ask
   * for a theme until GTK is up. */
  lk_register_resource ();
  gtk_icon_theme_add_resource_path (gtk_icon_theme_get_for_display (gdk_display_get_default ()),
                                    "/org/beetlebug/LookoutMarine/icons");

  gtk_css_provider_load_from_string (provider, LK_CSS);
  gtk_style_context_add_provider_for_display (gdk_display_get_default (),
                                              GTK_STYLE_PROVIDER (provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

  struct { const char *action; const char *accels[3]; } accels[] = {
    { "win.open",             { "<Control>o", NULL } },
    { "win.open-file",        { "<Control><Shift>o", NULL } },
    { "win.zoom-in",          { "<Control>plus", "<Control>equal", NULL } },
    { "win.zoom-out",         { "<Control>minus", NULL } },
    { "win.zoom-fit",         { "<Control>0", NULL } },
    { "win.north-up",         { "<Control>Up", NULL } },
    { "win.cycle-scheme",     { "<Control>l", NULL } },
    { "win.toggle-text",      { "<Control>t", NULL } },
    { "win.toggle-soundings", { "<Control><Shift>s", NULL } },
    { "win.toggle-other",     { "<Control>d", NULL } },
    { "win.search",           { "<Control>f", NULL } },
    /* Escape is a cascade, not one action: the window handles it in the capture
       phase (lk_window_escape), so it is not bound to close-pick here. */
    { "win.settings",         { "<Control>comma", NULL } },
    { "win.raster-cycle",     { "<Control>i", NULL } },
    { "win.raster-add",       { "<Control><Shift>i", NULL } },
    { "win.toggle-chart",     { "<Control><Shift>h", NULL } },
    /* The desktop convention; macOS keeps the system's own fullscreen key. */
    { "win.full-screen",      { "F11", NULL } },
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

  /* Throw away what a previous run renamed but did not finish deleting.
     Without this, quitting mid-delete leaves gigabytes on the disk that
     nothing will ever mention again. */
  lk_chart_bake_sweep_trash ();

  /* One instance is the rule — a dock click focuses the chart already
   * sailing. LOOKOUT_MULTI is the development escape hatch every shell keeps:
   * a second live window for side-by-side comparison and recording. */
  GApplicationFlags flags = G_APPLICATION_DEFAULT_FLAGS;
  if (g_getenv ("LOOKOUT_MULTI") != NULL)
    flags |= G_APPLICATION_NON_UNIQUE;

  g_autoptr (GtkApplication) app = gtk_application_new (LK_APP_ID, flags);
  g_autoptr (LkAppModel) model = lk_app_model_new ();

  g_signal_connect (app, "startup", G_CALLBACK (lk_app_startup), model);
  g_signal_connect (app, "activate", G_CALLBACK (lk_app_activate), model);

  return g_application_run (G_APPLICATION (app), argc, argv);
}
