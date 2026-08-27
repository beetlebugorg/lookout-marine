#include "lk-about.h"

#include "lk-licenses.h"

/* The chart engine is the one component a mariner may be asked which copy of
 * they are sailing on, so the About window states its pin. */
#define LK_ENGINE_ID "tile57"

/* The one on screen, or NULL. A second About command raises it. */
static GtkWidget *lk_about_window;

static void
lk_about_licenses_clicked (GtkButton *button, gpointer user_data)
{
  GtkRoot *root = gtk_widget_get_root (GTK_WIDGET (button));
  GtkWindow *window = GTK_IS_WINDOW (root) ? GTK_WINDOW (root) : NULL;

  /* The main window, not this one: About can be closed while the licenses
   * stay open. */
  lk_licenses_window_present (window != NULL ? gtk_window_get_transient_for (window) : NULL,
                              NULL);
}

/* Esc closes it. A tiling compositor draws no titlebar X. */
static gboolean
lk_about_key_pressed (GtkEventControllerKey *controller, guint keyval, guint keycode,
                      GdkModifierType state, gpointer window)
{
  if (keyval == GDK_KEY_Escape)
    {
      gtk_window_close (GTK_WINDOW (window));
      return GDK_EVENT_STOP;
    }
  return GDK_EVENT_PROPAGATE;
}

static GtkWidget *
lk_about_window_new (GtkWindow *parent)
{
  const LkLicenseApp *app = lk_licenses_app ();
  const LkLicenseComponent *engine = lk_licenses_component (LK_ENGINE_ID);
  const char *name = app != NULL ? app->name : "Lookout Marine";
  GtkWidget *window = gtk_window_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 14);

  gtk_window_set_title (GTK_WINDOW (window), "About Lookout Marine");
  gtk_window_set_transient_for (GTK_WINDOW (window), parent);
  gtk_window_set_destroy_with_parent (GTK_WINDOW (window), TRUE);
  gtk_window_set_resizable (GTK_WINDOW (window), FALSE);
  gtk_window_set_titlebar (GTK_WINDOW (window), gtk_header_bar_new ());

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (lk_about_key_pressed), window);
  gtk_widget_add_controller (window, keys);

  gtk_widget_set_margin_start (box, 24);
  gtk_widget_set_margin_end (box, 24);
  gtk_widget_set_margin_top (box, 12);
  gtk_widget_set_margin_bottom (box, 24);
  gtk_widget_set_size_request (box, 340, -1);

  /* The window's own icon, which main.c set as every window's default and
   * meson installs into hicolor. */
  GtkWidget *icon = gtk_image_new_from_icon_name (gtk_window_get_default_icon_name ());
  gtk_image_set_pixel_size (GTK_IMAGE (icon), 96);
  gtk_box_append (GTK_BOX (box), icon);

  GtkWidget *names = gtk_box_new (GTK_ORIENTATION_VERTICAL, 4);
  GtkWidget *title = gtk_label_new (name);
  g_autofree char *version = g_strdup_printf ("Version %s", lk_licenses_app_version ());
  GtkWidget *version_label = gtk_label_new (version);

  gtk_widget_add_css_class (title, "title-2");
  gtk_widget_add_css_class (version_label, "dim-label");
  gtk_widget_add_css_class (version_label, "numeric");
  gtk_box_append (GTK_BOX (names), title);
  gtk_box_append (GTK_BOX (names), version_label);

  if (engine != NULL)
    {
      g_autofree char *pin = lk_licenses_pin (engine);

      if (pin[0] != '\0')
        {
          g_autofree char *text = g_strdup_printf ("Chart engine %s · %s", engine->name, pin);
          GtkWidget *label = gtk_label_new (text);

          gtk_widget_add_css_class (label, "caption");
          gtk_widget_add_css_class (label, "dim-label");
          gtk_label_set_selectable (GTK_LABEL (label), TRUE);
          gtk_box_append (GTK_BOX (names), label);
        }
    }
  gtk_box_append (GTK_BOX (box), names);

  /* Set apart, in the same amber the first-run page uses. */
  GtkWidget *warn = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *warn_title = gtk_label_new ("NOT FOR NAVIGATION");

  gtk_widget_add_css_class (warn, "lk-not-nav");
  gtk_widget_add_css_class (warn_title, "lk-not-nav-title");
  /* No wider than the words: a block across the window reads as a button, and
     it sits over the two real ones. */
  gtk_widget_set_halign (warn, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (warn), warn_title);
  gtk_box_append (GTK_BOX (box), warn);

  GtkWidget *buttons = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *licenses = gtk_button_new_with_label ("Licenses…");

  g_signal_connect (licenses, "clicked", G_CALLBACK (lk_about_licenses_clicked), NULL);
  gtk_widget_set_halign (buttons, GTK_ALIGN_CENTER);
  gtk_box_append (GTK_BOX (buttons), licenses);

  if (app != NULL && app->url[0] != '\0')
    gtk_box_append (GTK_BOX (buttons), gtk_link_button_new_with_label (app->url, "Source"));
  gtk_box_append (GTK_BOX (box), buttons);

  if (app != NULL && app->copyright[0] != '\0')
    {
      GtkWidget *label = gtk_label_new (app->copyright);

      gtk_widget_add_css_class (label, "caption");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
      gtk_box_append (GTK_BOX (box), label);
    }

  gtk_window_set_child (GTK_WINDOW (window), box);
  /* The button takes the focus, so the window does not open with the engine
     line selected: it is selectable to be copied, not to be highlighted. */
  gtk_window_set_focus (GTK_WINDOW (window), licenses);
  return window;
}

void
lk_about_window_present (GtkWindow *parent)
{
  if (lk_about_window == NULL)
    {
      lk_about_window = lk_about_window_new (parent);
      g_object_add_weak_pointer (G_OBJECT (lk_about_window), (gpointer *) &lk_about_window);
    }

  gtk_window_present (GTK_WINDOW (lk_about_window));
}
