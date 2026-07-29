/* main.c — the GtkApplication entry point.
 *
 * One window and one LkAppModel for the life of the app. Accelerators mirror
 * the macOS menu bar, Ctrl for Command.
 */

#include <gtk/gtk.h>

#include "lk-app-model.h"
#include "lk-window.h"

#define LK_APP_ID "org.beetlebug.LookoutMarine"

/* A little chrome the stock stylesheet has no class for. */
static const char *LK_CSS =
    /* The chart window is transparent where the chart-view widget paints nothing,
     * so the below subsurface shows through and the chrome floats over it. */
    ".lk-chart-window { background: transparent; }"
    ".lk-card {"
    "  background: alpha(currentColor, 0.06);"
    "  border-radius: 16px;"
    "  padding: 32px 40px;"
    "}"
    /* Plain GTK lacks libadwaita's @window_bg_color, so mix against @theme_bg_color. */
    ".lk-hud-floating {"
    "  background: alpha(@theme_bg_color, 0.85);"
    "  border-top: 1px solid alpha(@borders, 0.6);"
    "  border-radius: 0;"
    "}"
    ".lk-bubble {"
    "  min-width: 40px;"
    "  min-height: 40px;"
    "  padding: 0;"
    "  border-radius: 999px;"
    "  background: alpha(@theme_bg_color, 0.92);"
    "  border: 1px solid alpha(@borders, 0.5);"
    "  box-shadow: 0 1px 4px alpha(black, 0.2);"
    "}"
    ".lk-overscale {"
    "  color: @warning_color;"
    "  font-weight: bold;"
    "  background: alpha(@warning_color, 0.18);"
    "  border-radius: 999px;"
    "  padding: 1px 7px;"
    "}";

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
    { "win.settings",         { "<Control>comma", NULL } },
  };

  for (gsize i = 0; i < G_N_ELEMENTS (accels); i++)
    gtk_application_set_accels_for_action (app, accels[i].action, accels[i].accels);
}

int
main (int argc, char *argv[])
{
  g_set_application_name ("Lookout Marine");

  g_autoptr (GtkApplication) app =
      gtk_application_new (LK_APP_ID, G_APPLICATION_DEFAULT_FLAGS);
  g_autoptr (LkAppModel) model = lk_app_model_new ();

  g_signal_connect (app, "startup", G_CALLBACK (lk_app_startup), model);
  g_signal_connect (app, "activate", G_CALLBACK (lk_app_activate), model);

  return g_application_run (G_APPLICATION (app), argc, argv);
}
