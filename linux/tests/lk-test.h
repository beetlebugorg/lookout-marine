/* lk-test.h — the shared harness for the widget suites.
 *
 * Each widget test runs the real widgets against the real model. The engine
 * has no chart open, so every lookout_* call answers its documented empty
 * value; what the test drives is the shell.
 *
 * lk_test_gtk_init isolates the run (a throwaway HOME, so no recents, no
 * settings.ini, no demo chart is found) and skips the suite with exit 77 when
 * no display can be opened. run-headless.sh supplies Xvfb where the session
 * has none.
 */
#pragma once

#include <gtk/gtk.h>
#include <stdlib.h>

/* Exit code meson reads as "skipped". */
#define LK_TEST_SKIP 77

static inline void
lk_test_isolate (void)
{
  g_autofree char *home = g_dir_make_tmp ("lk-widget-test-XXXXXX", NULL);

  g_assert_nonnull (home);
  g_setenv ("HOME", home, TRUE);
  g_setenv ("XDG_CONFIG_HOME", g_build_filename (home, ".config", NULL), TRUE);
  g_setenv ("XDG_DATA_HOME", g_build_filename (home, ".local", "share", NULL), TRUE);
  g_setenv ("XDG_CACHE_HOME", g_build_filename (home, ".cache", NULL), TRUE);
  g_unsetenv ("LOOKOUT_OPEN");
  g_unsetenv ("LOOKOUT_VIEW");
  g_unsetenv ("LOOKOUT_SHOW");
  g_setenv ("LOOKOUT_CLEAN", "1", TRUE);
  /* The chrome, not the chart, is under test: no GPU. */
  g_setenv ("GSK_RENDERER", "cairo", TRUE);
}

static inline void
lk_test_gtk_init (int *argc, char ***argv)
{
  lk_test_isolate ();

  if (!gtk_init_check ())
    exit (LK_TEST_SKIP);

  g_test_init (argc, argv, NULL);
}

/* Run the loop until it goes quiet, so idles and notifies land. */
static inline void
lk_test_drain (void)
{
  while (g_main_context_iteration (NULL, FALSE))
    ;
}

/* ---- widget tree lookups ------------------------------------------------- */

typedef gboolean (*LkTestMatch) (GtkWidget *widget, gconstpointer data);

static inline GtkWidget *
lk_test_find (GtkWidget *root, LkTestMatch match, gconstpointer data)
{
  if (root == NULL)
    return NULL;
  if (match (root, data))
    return root;

  for (GtkWidget *child = gtk_widget_get_first_child (root);
       child != NULL;
       child = gtk_widget_get_next_sibling (child))
    {
      GtkWidget *found = lk_test_find (child, match, data);
      if (found != NULL)
        return found;
    }

  return NULL;
}

static inline gboolean
lk_test_match_label (GtkWidget *widget, gconstpointer data)
{
  return GTK_IS_LABEL (widget) &&
         g_strcmp0 (gtk_label_get_text (GTK_LABEL (widget)), data) == 0;
}

/* The label with exactly `text`, anywhere under `root`. */
static inline GtkWidget *
lk_test_find_label (GtkWidget *root, const char *text)
{
  return lk_test_find (root, lk_test_match_label, text);
}

static inline gboolean
lk_test_match_type (GtkWidget *widget, gconstpointer data)
{
  return G_TYPE_CHECK_INSTANCE_TYPE (widget, *(const GType *) data);
}

static inline GtkWidget *
lk_test_find_type (GtkWidget *root, GType type)
{
  return lk_test_find (root, lk_test_match_type, &type);
}

static inline gboolean
lk_test_match_css_class (GtkWidget *widget, gconstpointer data)
{
  return gtk_widget_has_css_class (widget, data);
}

/* The widget carrying the CSS class `name`, anywhere under `root`. */
static inline GtkWidget *
lk_test_find_css (GtkWidget *root, const char *name)
{
  return lk_test_find (root, lk_test_match_css_class, name);
}

static inline gboolean
lk_test_match_button_label (GtkWidget *widget, gconstpointer data)
{
  return GTK_IS_BUTTON (widget) &&
         lk_test_find_label (widget, data) != NULL;
}

/* The button whose face carries the label `text`. */
static inline GtkWidget *
lk_test_find_button (GtkWidget *root, const char *text)
{
  return lk_test_find (root, lk_test_match_button_label, text);
}

/* Visible along the whole ancestry up to `root` — the widget's own flag and
 * every parent's. */
static inline gboolean
lk_test_shown (GtkWidget *widget, GtkWidget *root)
{
  for (GtkWidget *w = widget; w != NULL && w != root; w = gtk_widget_get_parent (w))
    {
      if (!gtk_widget_get_visible (w))
        return FALSE;
    }
  return TRUE;
}
