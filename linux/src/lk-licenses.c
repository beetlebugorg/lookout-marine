#include "lk-licenses.h"

#include "lk-json.h"

#include <lookout.h>
#include <string.h>

/* The version this build reports. meson states it (linux/meson.build); a build
 * that does not says so rather than inventing a number. */
#ifndef LK_VERSION
#define LK_VERSION "unknown"
#endif

/* The manifest names one shell per build. Ours is this one. */
#define LK_SHELL "linux"

/* The search field appears above this many components and not below: a list
 * shorter than that is read, not searched. The Mac draws the line at the same
 * number (macos/LookoutMarine/Licenses.swift). */
#define LK_LICENSES_SEARCHABLE 12

/* The window at its own width. A license is hard-wrapped at 80 columns and is
 * not to be wrapped again, so the pane is wide enough to hold one and the list
 * beside it takes the rest. */
#define LK_LICENSES_WIDTH 1080
#define LK_LICENSES_HEIGHT 680
#define LK_LICENSES_LIST_WIDTH 300

/* The width of a row's right column, in characters. The license and the pin
 * are read there; the name is read on the left, and it gets the rest. */
#define LK_LICENSES_TRAILING 14

/* The floor under the name column, in points. Without one a row whose terms
 * wrap is measured for the height that wrapping takes, and at that height the
 * label claims the width of its one long line instead: the name beside it is
 * then crushed to an ellipsis. */
#define LK_LICENSES_NAME_WIDTH 140

/* ---- the manifest ------------------------------------------------------- */

/* Read once and kept for the process. The tree owns a copy of every string in
 * it, so the rows below hand out pointers into it and nothing here is freed. */
static LkJson      *lk_manifest;
static LkLicenseApp lk_app;
static gboolean     lk_app_read;
static GPtrArray   *lk_components; /* LkLicenseComponent * */

/* A member as text. Absent, null and empty all read the same way: empty. */
static const char *
lk_member_text (const LkJson *node, const char *name)
{
  const char *text = lk_json_string (lk_json_member (node, name));

  return text != NULL ? text : "";
}

/* Whether an entry's `shells` array names this build. */
static gboolean
lk_shells_name_this_build (const LkJson *shells)
{
  for (guint i = 0; i < lk_json_length (shells); i++)
    {
      if (g_strcmp0 (lk_json_string (lk_json_at (shells, i)), LK_SHELL) == 0)
        return TRUE;
    }
  return FALSE;
}

static void
lk_licenses_read (void)
{
  static gboolean done;

  if (done)
    return;
  done = TRUE;
  lk_components = g_ptr_array_new_with_free_func (g_free);

  size_t length = 0;
  const char *json = lookout_licenses_json (&length);

  if (json == NULL || length == 0)
    {
      g_warning ("this build carries no license list");
      return;
    }

  /* The core hands over a pointer and a length; the reader takes a string. */
  g_autofree char *text = g_strndup (json, length);

  lk_manifest = lk_json_parse (text);
  if (lk_manifest == NULL)
    {
      g_warning ("the baked license list will not parse");
      return;
    }

  const LkJson *app = lk_json_member (lk_manifest, "app");
  if (app != NULL)
    {
      lk_app.name = lk_member_text (app, "name");
      lk_app.summary = lk_member_text (app, "summary");
      lk_app.license = lk_member_text (app, "license");
      lk_app.copyright = lk_member_text (app, "copyright");
      lk_app.url = lk_member_text (app, "url");
      lk_app.text = lk_member_text (app, "text");
      lk_app_read = TRUE;
    }

  const LkJson *components = lk_json_member (lk_manifest, "components");
  for (guint i = 0; i < lk_json_length (components); i++)
    {
      const LkJson *node = lk_json_at (components, i);

      if (!lk_shells_name_this_build (lk_json_member (node, "shells")))
        continue;

      LkLicenseComponent *component = g_new0 (LkLicenseComponent, 1);

      component->id = lk_member_text (node, "id");
      component->name = lk_member_text (node, "name");
      component->group = lk_member_text (node, "group");
      component->summary = lk_member_text (node, "summary");
      component->license = lk_member_text (node, "license");
      component->license_short = lk_member_text (node, "license_short");
      component->license_note = lk_member_text (node, "license_note");
      component->version = lk_member_text (node, "version");
      component->commit = lk_member_text (node, "commit");
      component->pinned_in = lk_member_text (node, "pinned_in");
      component->copyright = lk_member_text (node, "copyright");
      component->url = lk_member_text (node, "url");
      component->text = lk_member_text (node, "text");
      component->notice = lk_member_text (node, "notice");
      g_ptr_array_add (lk_components, component);
    }
}

const LkLicenseApp *
lk_licenses_app (void)
{
  lk_licenses_read ();
  return lk_app_read ? &lk_app : NULL;
}

const GPtrArray *
lk_licenses_components (void)
{
  lk_licenses_read ();
  return lk_components;
}

const LkLicenseComponent *
lk_licenses_component (const char *id)
{
  const GPtrArray *components = lk_licenses_components ();

  for (guint i = 0; id != NULL && i < components->len; i++)
    {
      const LkLicenseComponent *component = g_ptr_array_index (components, i);

      if (g_strcmp0 (component->id, id) == 0)
        return component;
    }
  return NULL;
}

const char *
lk_licenses_app_version (void)
{
  return LK_VERSION;
}

char *
lk_licenses_pin (const LkLicenseComponent *component)
{
  if (component == NULL)
    return g_strdup ("");
  if (component->version[0] != '\0')
    return g_strdup (component->version);
  return g_strndup (component->commit, 7);
}

/* What a detail pane says the terms are. An entry whose terms could not be
 * determined says so rather than showing nothing. */
static const char *
lk_licenses_label (const LkLicenseComponent *component)
{
  return component->license[0] != '\0' ? component->license : "Not resolved";
}

/* What a ROW says: the same terms in short, because the column is narrow. A
 * manifest that names no short form falls back to the long one. */
static const char *
lk_licenses_short_label (const LkLicenseComponent *component)
{
  if (component->license[0] == '\0')
    return "Not resolved";
  return component->license_short[0] != '\0' ? component->license_short : component->license;
}

/* ---- the pieces a detail pane is made of --------------------------------- */

/* Every copy button carries the text it copies. The strings all live in the
 * parsed manifest, which outlives every window, so none of them is copied. */
static void
lk_licenses_copy_clicked (GtkButton *button, gpointer user_data)
{
  gdk_clipboard_set_text (gtk_widget_get_clipboard (GTK_WIDGET (button)), user_data);
}

static GtkWidget *
lk_licenses_copy_button (const char *text, const char *tooltip)
{
  GtkWidget *button = gtk_button_new_from_icon_name ("edit-copy-symbolic");

  gtk_widget_add_css_class (button, "flat");
  gtk_widget_set_valign (button, GTK_ALIGN_CENTER);
  gtk_widget_set_tooltip_text (button, tooltip);
  g_signal_connect (button, "clicked", G_CALLBACK (lk_licenses_copy_clicked),
                    (gpointer) text);
  return button;
}

/* A shaded block. The facts, the NOTICE and the license each sit on one. */
static GtkWidget *
lk_licenses_block (void)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);

  gtk_widget_add_css_class (box, "lk-license-block");
  return box;
}

/* A small heading over a block. */
static GtkWidget *
lk_licenses_caption (const char *text)
{
  GtkWidget *label = gtk_label_new (text);

  gtk_widget_add_css_class (label, "caption-heading");
  gtk_widget_add_css_class (label, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  return label;
}

/* The label-and-value rows. A commit, a path or a version is a literal to be
 * copied, so it is monospaced. */
static GtkWidget *
lk_licenses_facts (void)
{
  GtkWidget *grid = gtk_grid_new ();

  gtk_grid_set_row_spacing (GTK_GRID (grid), 8);
  gtk_grid_set_column_spacing (GTK_GRID (grid), 14);
  gtk_widget_add_css_class (grid, "lk-license-block");
  return grid;
}

static void
lk_licenses_fact (GtkWidget *grid, int row, const char *name, const char *value,
                  gboolean literal)
{
  GtkWidget *label = gtk_label_new (name);
  GtkWidget *text = gtk_label_new (value);

  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_widget_set_valign (label, GTK_ALIGN_START);
  gtk_widget_set_size_request (label, 92, -1);
  gtk_widget_add_css_class (label, "dim-label");

  gtk_label_set_xalign (GTK_LABEL (text), 0.0);
  gtk_label_set_wrap (GTK_LABEL (text), TRUE);
  gtk_label_set_selectable (GTK_LABEL (text), TRUE);
  gtk_widget_set_hexpand (text, TRUE);
  if (literal)
    gtk_widget_add_css_class (text, "monospace");

  gtk_grid_attach (GTK_GRID (grid), label, 0, row, 1, 1);
  gtk_grid_attach (GTK_GRID (grid), text, 1, row, 1, 1);
}

/* The upstream address, selectable and with its own copy button. Opening it
 * needs a connection; copying it does not. */
static GtkWidget *
lk_licenses_upstream (const char *url)
{
  GtkWidget *block = lk_licenses_block ();
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *link = gtk_link_button_new_with_label (url, url);

  gtk_widget_add_css_class (link, "flat");
  gtk_widget_set_halign (link, GTK_ALIGN_START);
  gtk_widget_set_hexpand (link, TRUE);

  gtk_box_append (GTK_BOX (row), link);
  gtk_box_append (GTK_BOX (row), lk_licenses_copy_button (url, "Copy address"));
  gtk_box_append (GTK_BOX (block), lk_licenses_caption ("Upstream"));
  gtk_box_append (GTK_BOX (block), row);
  return block;
}

/* A block of text as it was written: monospaced, selectable, and broken only
 * by the width of the view. */
static GtkWidget *
lk_licenses_verbatim (const char *text)
{
  GtkWidget *label = gtk_label_new (text);

  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_label_set_wrap (GTK_LABEL (label), TRUE);
  /* A license carries addresses and rules no space breaks. Without a character
   * break one of those sets the pane's minimum width. */
  gtk_label_set_wrap_mode (GTK_LABEL (label), PANGO_WRAP_WORD_CHAR);
  gtk_label_set_selectable (GTK_LABEL (label), TRUE);
  gtk_widget_add_css_class (label, "monospace");
  gtk_widget_add_css_class (label, "lk-license-text");
  return label;
}

/* The component's NOTICE. Apache 2.0 section 4(d) makes it travel with the
 * software, and it is a separate obligation from the license, so it stands
 * above it. */
static GtkWidget *
lk_licenses_notice (const char *text)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
  GtkWidget *heading = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *caption = lk_licenses_caption ("NOTICE");
  GtkWidget *block = lk_licenses_block ();

  gtk_widget_set_hexpand (caption, TRUE);
  gtk_box_append (GTK_BOX (heading), caption);
  gtk_box_append (GTK_BOX (heading), lk_licenses_copy_button (text, "Copy this notice"));
  gtk_box_append (GTK_BOX (block), lk_licenses_verbatim (text));
  gtk_box_append (GTK_BOX (box), heading);
  gtk_box_append (GTK_BOX (box), block);
  return box;
}

/* The license itself, whole. `note` is what the manifest says about the terms
 * on top of naming them, and is empty for most entries. */
static GtkWidget *
lk_licenses_body (const char *title, const char *note, const char *text)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);

  if (text[0] == '\0')
    {
      GtkWidget *none = gtk_label_new ("No license text.");

      gtk_widget_add_css_class (none, "dim-label");
      gtk_label_set_xalign (GTK_LABEL (none), 0.0);
      gtk_box_append (GTK_BOX (box), none);
      return box;
    }

  g_autofree char *upper = g_utf8_strup (title, -1);
  GtkWidget *heading = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  GtkWidget *caption = lk_licenses_caption (upper);
  GtkWidget *block = lk_licenses_block ();

  gtk_widget_set_hexpand (caption, TRUE);
  gtk_box_append (GTK_BOX (heading), caption);
  gtk_box_append (GTK_BOX (heading), lk_licenses_copy_button (text, "Copy this license"));
  gtk_box_append (GTK_BOX (box), heading);

  if (note[0] != '\0')
    {
      GtkWidget *label = gtk_label_new (note);

      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_widget_add_css_class (label, "dim-label");
      gtk_box_append (GTK_BOX (box), label);
    }

  gtk_box_append (GTK_BOX (block), lk_licenses_verbatim (text));
  gtk_box_append (GTK_BOX (box), block);
  return box;
}

/* The name of the entry, and what it is. */
static GtkWidget *
lk_licenses_heading (const char *name, const char *summary)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 6);
  GtkWidget *title = gtk_label_new (name);

  gtk_widget_add_css_class (title, "title-2");
  gtk_label_set_xalign (GTK_LABEL (title), 0.0);
  gtk_label_set_wrap (GTK_LABEL (title), TRUE);
  gtk_box_append (GTK_BOX (box), title);

  if (summary[0] != '\0')
    {
      GtkWidget *label = gtk_label_new (summary);

      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_widget_add_css_class (label, "dim-label");
      gtk_box_append (GTK_BOX (box), label);
    }
  return box;
}

/* ---- the detail panes ---------------------------------------------------- */

static GtkWidget *
lk_licenses_pane (void)
{
  GtkWidget *pane = gtk_box_new (GTK_ORIENTATION_VERTICAL, 18);

  gtk_widget_set_margin_start (pane, 20);
  gtk_widget_set_margin_end (pane, 20);
  gtk_widget_set_margin_top (pane, 20);
  gtk_widget_set_margin_bottom (pane, 20);
  return pane;
}

/* This app's own terms. */
static GtkWidget *
lk_licenses_app_pane (const LkLicenseApp *app)
{
  GtkWidget *pane = lk_licenses_pane ();
  GtkWidget *facts = lk_licenses_facts ();

  lk_licenses_fact (facts, 0, "License", app->license, FALSE);
  lk_licenses_fact (facts, 1, "Version", lk_licenses_app_version (), TRUE);
  lk_licenses_fact (facts, 2, "Copyright", app->copyright, FALSE);

  gtk_box_append (GTK_BOX (pane), lk_licenses_heading (app->name, app->summary));
  gtk_box_append (GTK_BOX (pane), facts);
  gtk_box_append (GTK_BOX (pane), lk_licenses_upstream (app->url));
  gtk_box_append (GTK_BOX (pane), lk_licenses_body (app->license, "", app->text));
  return pane;
}

/* One component: what it is, how it is pinned, and its terms. */
static GtkWidget *
lk_licenses_component_pane (const LkLicenseComponent *component)
{
  GtkWidget *pane = lk_licenses_pane ();
  GtkWidget *facts = lk_licenses_facts ();
  int row = 0;

  gtk_box_append (GTK_BOX (pane),
                  lk_licenses_heading (component->name, component->summary));

  /* An entry with no terms is not an empty entry. It says so, and says why. */
  if (component->license[0] == '\0')
    {
      GtkWidget *block = lk_licenses_block ();
      GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
      GtkWidget *icon = gtk_image_new_from_icon_name ("dialog-warning-symbolic");
      GtkWidget *title = gtk_label_new ("License not resolved");
      GtkWidget *note = gtk_label_new (component->license_note);

      gtk_widget_add_css_class (title, "heading");
      gtk_widget_set_valign (icon, GTK_ALIGN_START);
      gtk_label_set_xalign (GTK_LABEL (title), 0.0);
      gtk_label_set_wrap (GTK_LABEL (note), TRUE);
      gtk_label_set_xalign (GTK_LABEL (note), 0.0);
      gtk_widget_add_css_class (note, "dim-label");

      gtk_box_append (GTK_BOX (line), icon);
      gtk_box_append (GTK_BOX (line), title);
      gtk_box_append (GTK_BOX (block), line);
      gtk_box_append (GTK_BOX (block), note);
      gtk_box_append (GTK_BOX (pane), block);
    }

  lk_licenses_fact (facts, row++, "License", lk_licenses_label (component), FALSE);
  if (component->version[0] != '\0')
    lk_licenses_fact (facts, row++, "Version", component->version, TRUE);
  if (component->commit[0] != '\0')
    lk_licenses_fact (facts, row++, "Commit", component->commit, TRUE);
  lk_licenses_fact (facts, row++, "Pinned in", component->pinned_in, TRUE);
  lk_licenses_fact (facts, row++, "Copyright", component->copyright, FALSE);
  gtk_box_append (GTK_BOX (pane), facts);

  gtk_box_append (GTK_BOX (pane), lk_licenses_upstream (component->url));
  if (component->notice[0] != '\0')
    gtk_box_append (GTK_BOX (pane), lk_licenses_notice (component->notice));
  gtk_box_append (GTK_BOX (pane),
                  lk_licenses_body (lk_licenses_label (component),
                                    component->license[0] != '\0' ? component->license_note : "",
                                    component->text));
  return pane;
}

/* ---- the window ---------------------------------------------------------- */

typedef struct {
  GtkWidget *window;
  GtkWidget *list;
  GtkWidget *detail;   /* the scroller a pane is set into */
  GtkWidget *search;   /* NULL while the list is short enough to read whole */
  GtkWidget *no_match;
} LkLicensesWindow;

/* The one on screen, or NULL. A second Licenses command raises it. */
static GtkWidget *lk_licenses_window;

/* One row: what it is on the left, its license and its pin on the right. */
static GtkWidget *
lk_licenses_row (const char *name, const char *summary, const char *trailing,
                 const char *pin, gboolean strong, gboolean unresolved)
{
  GtkWidget *row = gtk_list_box_row_new ();
  GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 10);
  GtkWidget *left = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
  GtkWidget *right = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
  GtkWidget *title = gtk_label_new (name);
  GtkWidget *license = gtk_label_new (trailing);

  gtk_label_set_xalign (GTK_LABEL (title), 0.0);
  gtk_label_set_ellipsize (GTK_LABEL (title), PANGO_ELLIPSIZE_END);
  if (strong)
    gtk_widget_add_css_class (title, "heading");
  gtk_box_append (GTK_BOX (left), title);

  if (summary[0] != '\0')
    {
      GtkWidget *label = gtk_label_new (summary);

      gtk_label_set_xalign (GTK_LABEL (label), 0.0);
      gtk_label_set_ellipsize (GTK_LABEL (label), PANGO_ELLIPSIZE_END);
      gtk_widget_add_css_class (label, "caption");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_box_append (GTK_BOX (left), label);
    }

  /* The name is what the reader is looking down the list for, so the terms
     beside it wrap rather than take the row. */
  gtk_label_set_xalign (GTK_LABEL (license), 1.0);
  gtk_label_set_wrap (GTK_LABEL (license), TRUE);
  gtk_label_set_wrap_mode (GTK_LABEL (license), PANGO_WRAP_WORD_CHAR);
  /* Pinned to a column, not merely capped: a label free to take its natural
     width takes it out of the name beside it. */
  gtk_label_set_width_chars (GTK_LABEL (license), LK_LICENSES_TRAILING);
  gtk_label_set_max_width_chars (GTK_LABEL (license), LK_LICENSES_TRAILING);
  gtk_label_set_justify (GTK_LABEL (license), GTK_JUSTIFY_RIGHT);
  gtk_widget_add_css_class (license, "caption");
  /* Terms nobody could determine are the one thing in this list a reader has
   * to see from the list itself. */
  gtk_widget_add_css_class (license, unresolved ? "warning" : "dim-label");
  gtk_box_append (GTK_BOX (right), license);

  if (pin[0] != '\0')
    {
      GtkWidget *label = gtk_label_new (pin);

      gtk_label_set_xalign (GTK_LABEL (label), 1.0);
      gtk_label_set_wrap (GTK_LABEL (label), TRUE);
      gtk_label_set_wrap_mode (GTK_LABEL (label), PANGO_WRAP_WORD_CHAR);
      gtk_label_set_width_chars (GTK_LABEL (label), LK_LICENSES_TRAILING);
      gtk_label_set_max_width_chars (GTK_LABEL (label), LK_LICENSES_TRAILING);
      gtk_label_set_justify (GTK_LABEL (label), GTK_JUSTIFY_RIGHT);
      /* A pin is an identifier. Pango writes a hyphen where it breaks a word,
         which would put a character inside a version that is not in it. */
      g_autoptr (PangoAttrList) attrs = pango_attr_list_new ();
      pango_attr_list_insert (attrs, pango_attr_insert_hyphens_new (FALSE));
      gtk_label_set_attributes (GTK_LABEL (label), attrs);
      gtk_widget_add_css_class (label, "caption");
      gtk_widget_add_css_class (label, "dim-label");
      gtk_box_append (GTK_BOX (right), label);
    }

  gtk_widget_set_hexpand (left, TRUE);
  gtk_widget_set_size_request (left, LK_LICENSES_NAME_WIDTH, -1);
  gtk_widget_set_margin_start (line, 4);
  gtk_widget_set_margin_end (line, 4);
  gtk_widget_set_margin_top (line, 4);
  gtk_widget_set_margin_bottom (line, 4);
  gtk_box_append (GTK_BOX (line), left);
  gtk_box_append (GTK_BOX (line), right);
  gtk_list_box_row_set_child (GTK_LIST_BOX_ROW (row), line);
  return row;
}

/* What a row is filtered and headed by. */
static void
lk_licenses_row_tag (GtkWidget *row, const char *id, const char *group,
                     const char *haystack)
{
  g_object_set_data_full (G_OBJECT (row), "lk-id", g_strdup (id), g_free);
  g_object_set_data_full (G_OBJECT (row), "lk-group", g_strdup (group), g_free);
  g_object_set_data_full (G_OBJECT (row), "lk-haystack",
                          g_utf8_strdown (haystack, -1), g_free);
}

static void
lk_licenses_show (LkLicensesWindow *self, const char *id)
{
  GtkWidget *pane = NULL;

  if (id != NULL && id[0] != '\0')
    {
      const LkLicenseComponent *component = lk_licenses_component (id);

      if (component != NULL)
        pane = lk_licenses_component_pane (component);
    }
  else
    {
      const LkLicenseApp *app = lk_licenses_app ();

      if (app != NULL)
        pane = lk_licenses_app_pane (app);
    }

  if (pane == NULL)
    {
      pane = gtk_label_new ("Nothing to show.");
      gtk_widget_add_css_class (pane, "dim-label");
      gtk_widget_set_valign (pane, GTK_ALIGN_CENTER);
    }

  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (self->detail), pane);
  /* A new entry is read from its first line. */
  gtk_adjustment_set_value (
      gtk_scrolled_window_get_vadjustment (GTK_SCROLLED_WINDOW (self->detail)), 0);
}

static void
lk_licenses_row_selected (GtkListBox *box, GtkListBoxRow *row, gpointer user_data)
{
  LkLicensesWindow *self = user_data;

  if (row == NULL)
    return;
  lk_licenses_show (self, g_object_get_data (G_OBJECT (row), "lk-id"));
}

/* The app's own entry is never filtered out: it is this app's terms, not one
 * of the components being searched. */
static gboolean
lk_licenses_filter (GtkListBoxRow *row, gpointer user_data)
{
  LkLicensesWindow *self = user_data;
  const char *id = g_object_get_data (G_OBJECT (row), "lk-id");
  const char *haystack = g_object_get_data (G_OBJECT (row), "lk-haystack");

  if (self->search == NULL || id == NULL || id[0] == '\0')
    return TRUE;

  const char *typed = gtk_editable_get_text (GTK_EDITABLE (self->search));
  if (typed == NULL || typed[0] == '\0')
    return TRUE;

  g_autofree char *term = g_utf8_strdown (typed, -1);
  g_strstrip (term);
  return term[0] == '\0' || strstr (haystack, term) != NULL;
}

static void
lk_licenses_header (GtkListBoxRow *row, GtkListBoxRow *before, gpointer user_data)
{
  const char *group = g_object_get_data (G_OBJECT (row), "lk-group");
  const char *previous = before == NULL ? NULL
                                        : g_object_get_data (G_OBJECT (before), "lk-group");

  if (g_strcmp0 (group, previous) == 0)
    {
      gtk_list_box_row_set_header (row, NULL);
      return;
    }

  GtkWidget *label = gtk_label_new (group);

  gtk_widget_add_css_class (label, "heading");
  gtk_widget_add_css_class (label, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (label), 0.0);
  gtk_widget_set_margin_start (label, 6);
  gtk_widget_set_margin_top (label, before == NULL ? 6 : 14);
  gtk_widget_set_margin_bottom (label, 2);
  gtk_list_box_row_set_header (row, label);
}

static void
lk_licenses_search_changed (GtkEditable *entry, gpointer user_data)
{
  LkLicensesWindow *self = user_data;
  gboolean matched = FALSE;

  gtk_list_box_invalidate_filter (GTK_LIST_BOX (self->list));

  /* Whether the search found a component, asked of the filter itself: GTK
   * offers no way to read back which rows it kept. */
  for (int i = 0; !matched; i++)
    {
      GtkListBoxRow *row = gtk_list_box_get_row_at_index (GTK_LIST_BOX (self->list), i);
      const char *id;

      if (row == NULL)
        break;
      id = g_object_get_data (G_OBJECT (row), "lk-id");
      matched = id != NULL && id[0] != '\0' && lk_licenses_filter (row, self);
    }

  gtk_widget_set_visible (self->no_match, !matched);
}

/* Open on one entry by id. An id this build carries no entry for falls back to
 * this app's own, so a stale request never leaves the window on nothing. */
static void
lk_licenses_select (LkLicensesWindow *self, const char *id)
{
  GtkListBoxRow *wanted = NULL;

  /* A row the search has filtered out cannot be selected, and the caller asked
   * for it by name. */
  if (self->search != NULL)
    gtk_editable_set_text (GTK_EDITABLE (self->search), "");

  for (int i = 0; id != NULL && id[0] != '\0'; i++)
    {
      GtkListBoxRow *row = gtk_list_box_get_row_at_index (GTK_LIST_BOX (self->list), i);

      if (row == NULL)
        break;
      if (g_strcmp0 (g_object_get_data (G_OBJECT (row), "lk-id"), id) == 0)
        {
          wanted = row;
          break;
        }
    }

  if (wanted == NULL)
    wanted = gtk_list_box_get_row_at_index (GTK_LIST_BOX (self->list), 0);
  if (wanted != NULL)
    gtk_list_box_select_row (GTK_LIST_BOX (self->list), wanted);
}

/* Esc closes it. A tiling compositor draws no titlebar X. */
static gboolean
lk_licenses_key_pressed (GtkEventControllerKey *controller, guint keyval, guint keycode,
                         GdkModifierType state, gpointer window)
{
  if (keyval == GDK_KEY_Escape)
    {
      gtk_window_close (GTK_WINDOW (window));
      return GDK_EVENT_STOP;
    }
  return GDK_EVENT_PROPAGATE;
}

/* The list: this app's own entry, then the components, in manifest order. It
 * is one list and not a list per group: the manifest's groups are not
 * headings, on this shell or on the Mac. */
static void
lk_licenses_fill_list (LkLicensesWindow *self)
{
  const LkLicenseApp *app = lk_licenses_app ();
  const GPtrArray *components = lk_licenses_components ();

  if (app != NULL)
    {
      GtkWidget *row = lk_licenses_row (app->name, app->copyright, app->license,
                                        lk_licenses_app_version (), TRUE, FALSE);

      lk_licenses_row_tag (row, "", "This app", app->name);
      gtk_list_box_append (GTK_LIST_BOX (self->list), row);
    }

  for (guint i = 0; i < components->len; i++)
    {
      const LkLicenseComponent *c = g_ptr_array_index (components, i);
      g_autofree char *pin = lk_licenses_pin (c);
      g_autofree char *haystack = g_strjoin (" ", c->name, c->id, c->summary,
                                             c->license, NULL);
      GtkWidget *row = lk_licenses_row (c->name, c->summary, lk_licenses_short_label (c),
                                        pin, FALSE, c->license[0] == '\0');

      lk_licenses_row_tag (row, c->id, "Components", haystack);
      gtk_list_box_append (GTK_LIST_BOX (self->list), row);
    }
}

/* A build whose list will not parse says so. A Licenses command that opened an
 * empty window would hide it. */
static GtkWidget *
lk_licenses_unavailable (void)
{
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
  GtkWidget *title = gtk_label_new ("License list unavailable");
  GtkWidget *body = gtk_label_new ("This build's list could not be read.");

  gtk_widget_add_css_class (title, "title-2");
  gtk_widget_add_css_class (body, "dim-label");
  gtk_widget_set_valign (box, GTK_ALIGN_CENTER);
  gtk_widget_set_vexpand (box, TRUE);
  gtk_box_append (GTK_BOX (box), title);
  gtk_box_append (GTK_BOX (box), body);
  return box;
}

static GtkWidget *
lk_licenses_window_new (GtkWindow *parent)
{
  LkLicensesWindow *self = g_new0 (LkLicensesWindow, 1);
  const GPtrArray *components = lk_licenses_components ();

  self->window = gtk_window_new ();
  gtk_window_set_title (GTK_WINDOW (self->window), "Licenses");
  gtk_window_set_default_size (GTK_WINDOW (self->window),
                               LK_LICENSES_WIDTH, LK_LICENSES_HEIGHT);
  /* Wide enough that a license hard-wrapped at 80 columns needs no wrapping
   * of ours. */
  gtk_widget_set_size_request (self->window, 820, 480);
  gtk_window_set_transient_for (GTK_WINDOW (self->window), parent);
  gtk_window_set_destroy_with_parent (GTK_WINDOW (self->window), TRUE);
  gtk_window_set_titlebar (GTK_WINDOW (self->window), gtk_header_bar_new ());
  g_object_set_data_full (G_OBJECT (self->window), "lk-licenses", self, g_free);

  GtkEventController *keys = gtk_event_controller_key_new ();
  g_signal_connect (keys, "key-pressed", G_CALLBACK (lk_licenses_key_pressed), self->window);
  gtk_widget_add_controller (self->window, keys);

  if (lk_licenses_app () == NULL && components->len == 0)
    {
      gtk_window_set_child (GTK_WINDOW (self->window), lk_licenses_unavailable ());
      return self->window;
    }

  /* THE LIST BESIDE THE ENTRY IT NAMES, as the settings window and the Mac
   * both stand. */
  GtkWidget *split = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  GtkWidget *rail = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *rail_scroller = gtk_scrolled_window_new ();

  self->list = gtk_list_box_new ();
  gtk_list_box_set_selection_mode (GTK_LIST_BOX (self->list), GTK_SELECTION_BROWSE);
  gtk_widget_add_css_class (self->list, "navigation-sidebar");
  gtk_widget_set_vexpand (self->list, TRUE);
  gtk_list_box_set_header_func (GTK_LIST_BOX (self->list), lk_licenses_header, NULL, NULL);
  g_signal_connect (self->list, "row-selected", G_CALLBACK (lk_licenses_row_selected), self);

  /* Searching a list this short costs more than reading it. */
  if (components->len > LK_LICENSES_SEARCHABLE)
    {
      g_autofree char *prompt = g_strdup_printf ("Search %u components", components->len);

      self->search = gtk_search_entry_new ();
      gtk_search_entry_set_placeholder_text (GTK_SEARCH_ENTRY (self->search), prompt);
      gtk_widget_set_margin_start (self->search, 8);
      gtk_widget_set_margin_end (self->search, 8);
      gtk_widget_set_margin_top (self->search, 8);
      gtk_widget_set_margin_bottom (self->search, 4);
      g_signal_connect (self->search, "search-changed",
                        G_CALLBACK (lk_licenses_search_changed), self);
      gtk_box_append (GTK_BOX (rail), self->search);
      gtk_list_box_set_filter_func (GTK_LIST_BOX (self->list), lk_licenses_filter,
                                    self, NULL);
    }

  self->no_match = gtk_label_new ("Nothing matches.");
  gtk_widget_add_css_class (self->no_match, "dim-label");
  gtk_widget_set_margin_start (self->no_match, 14);
  gtk_widget_set_margin_bottom (self->no_match, 10);
  gtk_label_set_xalign (GTK_LABEL (self->no_match), 0.0);
  gtk_widget_set_visible (self->no_match, FALSE);

  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (rail_scroller),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (rail_scroller), self->list);
  gtk_widget_set_vexpand (rail_scroller, TRUE);
  gtk_box_append (GTK_BOX (rail), rail_scroller);
  gtk_box_append (GTK_BOX (rail), self->no_match);
  gtk_widget_set_size_request (rail, LK_LICENSES_LIST_WIDTH, -1);

  self->detail = gtk_scrolled_window_new ();
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (self->detail),
                                  GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_hexpand (self->detail, TRUE);

  gtk_box_append (GTK_BOX (split), rail);
  gtk_box_append (GTK_BOX (split), gtk_separator_new (GTK_ORIENTATION_VERTICAL));
  gtk_box_append (GTK_BOX (split), self->detail);
  gtk_window_set_child (GTK_WINDOW (self->window), split);

  lk_licenses_fill_list (self);
  return self->window;
}

void
lk_licenses_window_present (GtkWindow *parent, const char *id)
{
  lk_licenses_read ();

  if (lk_licenses_window == NULL)
    {
      lk_licenses_window = lk_licenses_window_new (parent);
      g_object_add_weak_pointer (G_OBJECT (lk_licenses_window),
                                 (gpointer *) &lk_licenses_window);
    }

  LkLicensesWindow *self = g_object_get_data (G_OBJECT (lk_licenses_window), "lk-licenses");

  if (self != NULL && self->list != NULL)
    lk_licenses_select (self, id);
  gtk_window_present (GTK_WINDOW (lk_licenses_window));
}
