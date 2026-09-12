/* ui/charts/gallery.c — see ui/charts/gallery.h. */
#include "ui/charts/gallery.h"

#include "ui/charts/catalog.h"

/* The design's tile. A picture narrower than this cannot be told from another
 * publisher's picture of the same water. */
#define LK_TILE_WIDTH 250
#define LK_TILE_ART   132
#define LK_TILE_ADD   176
#define LK_TILE_GAP   10

typedef struct {
  LkAppModel        *model; /* not owned */
  GtkWidget         *row;   /* the box the tiles are built into */
  LkChartGalleryAdd  on_add;
  gpointer           on_add_data;
} LkGallery;

static void lk_gallery_fill (LkGallery *self);

static void
lk_gallery_free (gpointer data)
{
  g_free (data);
}

/* ---- what a tile does ---------------------------------------------------- */

/* Draw this chart. A shipped entry the mariner has not taken yet is added
 * first, which the core reads and then picks. */
static void
lk_tile_clicked (GtkButton *button, gpointer user_data)
{
  LkGallery *self = user_data;
  LkChartLinks *links = lk_app_model_get_chart_links (self->model);
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");
  gboolean mine = g_object_get_data (G_OBJECT (button), "lk-mine") != NULL;

  /* NULL is how the links object spells "lookout's own chart". */
  if (url == NULL || mine)
    lk_chart_links_select (links, url);
  else
    lk_chart_links_add (links, url);
}

static void
lk_tile_refresh (GtkButton *button, gpointer user_data)
{
  LkGallery *self = user_data;
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");

  lk_chart_links_refresh (lk_app_model_get_chart_links (self->model), url);
}

static void
lk_tile_remove (GtkButton *button, gpointer user_data)
{
  LkGallery *self = user_data;
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");

  lk_chart_links_remove (lk_app_model_get_chart_links (self->model), url);
}

static void
lk_add_tile_clicked (GtkButton *button, gpointer user_data)
{
  LkGallery *self = user_data;

  if (self->on_add != NULL)
    self->on_add (self->on_add_data);
}

/* ---- one tile ------------------------------------------------------------ */

/* The picture at the top of a tile, or the room one will take.
 *
 * A style with no picture yet draws its kind. A publisher's own portrayal
 * needs the style resolved and its tiles fetched, so a chart the app ships no
 * render of has nothing to show until one arrives. */
static GtkWidget *
lk_tile_art (GdkTexture *picture)
{
  GtkWidget *frame = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *content;

  if (picture != NULL)
    {
      content = gtk_picture_new_for_paintable (GDK_PAINTABLE (picture));
      gtk_picture_set_content_fit (GTK_PICTURE (content), GTK_CONTENT_FIT_COVER);
      gtk_picture_set_can_shrink (GTK_PICTURE (content), TRUE);
    }
  else
    {
      content = gtk_image_new_from_icon_name ("network-workgroup-symbolic");
      gtk_image_set_pixel_size (GTK_IMAGE (content), 26);
      gtk_widget_add_css_class (content, "lk-accent");
      gtk_widget_set_valign (content, GTK_ALIGN_CENTER);
      gtk_widget_set_halign (content, GTK_ALIGN_CENTER);
      gtk_widget_add_css_class (frame, "lk-chart-art-empty");
    }

  gtk_widget_set_size_request (frame, LK_TILE_WIDTH, LK_TILE_ART);
  gtk_widget_set_overflow (frame, GTK_OVERFLOW_HIDDEN);
  gtk_widget_set_vexpand (content, TRUE);
  gtk_box_append (GTK_BOX (frame), content);
  gtk_widget_add_css_class (frame, "lk-chart-art");
  return frame;
}

/* Read this chart again, or take it off the list. Lookout's own chart has
 * neither: it is built from the sets below and cannot be removed. */
static GtkWidget *
lk_tile_menu (LkGallery *self, const char *url)
{
  GtkWidget *menu = gtk_menu_button_new ();
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
  GtkWidget *popover = gtk_popover_new ();
  GtkWidget *again = gtk_button_new_with_label ("Read This Chart Again");
  GtkWidget *remove = gtk_button_new_with_label ("Remove");

  gtk_widget_add_css_class (again, "flat");
  gtk_widget_add_css_class (remove, "flat");
  gtk_button_set_has_frame (GTK_BUTTON (again), FALSE);
  gtk_button_set_has_frame (GTK_BUTTON (remove), FALSE);
  gtk_widget_set_halign (gtk_button_get_child (GTK_BUTTON (again)), GTK_ALIGN_START);
  gtk_widget_set_halign (gtk_button_get_child (GTK_BUTTON (remove)), GTK_ALIGN_START);

  g_object_set_data_full (G_OBJECT (again), "lk-url", g_strdup (url), g_free);
  g_object_set_data_full (G_OBJECT (remove), "lk-url", g_strdup (url), g_free);
  g_signal_connect (again, "clicked", G_CALLBACK (lk_tile_refresh), self);
  g_signal_connect (remove, "clicked", G_CALLBACK (lk_tile_remove), self);

  gtk_box_append (GTK_BOX (box), again);
  gtk_box_append (GTK_BOX (box), remove);
  gtk_popover_set_child (GTK_POPOVER (popover), box);
  gtk_menu_button_set_popover (GTK_MENU_BUTTON (menu), popover);
  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (menu), "view-more-symbolic");
  gtk_widget_add_css_class (menu, "lk-chart-more");
  gtk_widget_set_halign (menu, GTK_ALIGN_END);
  gtk_widget_set_valign (menu, GTK_ALIGN_START);
  gtk_widget_set_margin_top (menu, 7);
  gtk_widget_set_margin_end (menu, 7);
  return menu;
}

/* One chart: a picture of it, its name, and where it comes from.
 *
 * `url` NULL is Lookout's own chart. `mine` marks a link already on the
 * mariner's list, which is the only kind that offers a menu. */
static GtkWidget *
lk_tile_new (LkGallery *self, const char *url, const char *name, const char *detail,
             GdkTexture *picture, gboolean active, gboolean mine)
{
  GtkWidget *button = gtk_button_new ();
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *overlay = gtk_overlay_new ();
  GtkWidget *words = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);
  GtkWidget *title = gtk_label_new (name);
  GtkWidget *where = gtk_label_new (detail);

  gtk_overlay_set_child (GTK_OVERLAY (overlay), lk_tile_art (picture));

  /* The badge goes over the CLIPPED picture, not inside it: a picture that
   * fills by covering is wider than the tile, and a badge aligned inside it
   * starts left of the tile's own edge. */
  if (active)
    {
      GtkWidget *badge = gtk_label_new ("ACTIVE");

      gtk_widget_add_css_class (badge, "lk-chart-badge");
      gtk_widget_set_halign (badge, GTK_ALIGN_START);
      gtk_widget_set_valign (badge, GTK_ALIGN_START);
      gtk_widget_set_margin_top (badge, 7);
      gtk_widget_set_margin_start (badge, 7);
      gtk_overlay_add_overlay (GTK_OVERLAY (overlay), badge);
    }
  if (mine)
    gtk_overlay_add_overlay (GTK_OVERLAY (overlay), lk_tile_menu (self, url));

  gtk_widget_add_css_class (title, "heading");
  gtk_label_set_xalign (GTK_LABEL (title), 0.0);
  gtk_label_set_ellipsize (GTK_LABEL (title), PANGO_ELLIPSIZE_END);
  gtk_widget_add_css_class (where, "caption");
  gtk_widget_add_css_class (where, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (where), 0.0);
  /* A style link holds the publisher, the style and often a key, and those are
   * the parts an end ellipsis removes first. */
  gtk_label_set_ellipsize (GTK_LABEL (where), PANGO_ELLIPSIZE_MIDDLE);

  gtk_box_append (GTK_BOX (words), title);
  gtk_box_append (GTK_BOX (words), where);
  gtk_widget_set_margin_start (words, 11);
  gtk_widget_set_margin_end (words, 11);
  gtk_widget_set_margin_top (words, 9);
  gtk_widget_set_margin_bottom (words, 11);

  gtk_box_append (GTK_BOX (column), overlay);
  gtk_box_append (GTK_BOX (column), words);

  gtk_button_set_child (GTK_BUTTON (button), column);
  gtk_widget_set_size_request (button, LK_TILE_WIDTH, -1);
  gtk_widget_add_css_class (button, "lk-chart-tile");
  if (active)
    gtk_widget_add_css_class (button, "lk-chart-tile-active");
  gtk_widget_set_valign (button, GTK_ALIGN_START);

  if (url != NULL)
    {
      g_object_set_data_full (G_OBJECT (button), "lk-url", g_strdup (url), g_free);
      gtk_widget_set_tooltip_text (button, url);
    }
  if (mine)
    g_object_set_data (G_OBJECT (button), "lk-mine", GINT_TO_POINTER (1));
  g_signal_connect (button, "clicked", G_CALLBACK (lk_tile_clicked), self);

  gtk_accessible_update_state (GTK_ACCESSIBLE (button), GTK_ACCESSIBLE_STATE_SELECTED,
                               active, -1);
  return button;
}

/* The last tile: add a chart by link or from a file. */
static GtkWidget *
lk_add_tile_new (LkGallery *self)
{
  GtkWidget *button = gtk_button_new ();
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 8);
  GtkWidget *plus = gtk_image_new_from_icon_name ("list-add-symbolic");
  GtkWidget *title = gtk_label_new ("Add a chart");
  GtkWidget *detail = gtk_label_new ("Style link, TileJSON, or a file");

  gtk_image_set_pixel_size (GTK_IMAGE (plus), 20);
  gtk_widget_add_css_class (plus, "lk-accent");
  gtk_widget_add_css_class (title, "heading");
  gtk_widget_add_css_class (detail, "caption");
  gtk_widget_add_css_class (detail, "dim-label");
  gtk_label_set_wrap (GTK_LABEL (detail), TRUE);
  gtk_label_set_justify (GTK_LABEL (detail), GTK_JUSTIFY_CENTER);

  gtk_box_append (GTK_BOX (column), plus);
  gtk_box_append (GTK_BOX (column), title);
  gtk_box_append (GTK_BOX (column), detail);
  gtk_widget_set_valign (column, GTK_ALIGN_CENTER);

  gtk_button_set_child (GTK_BUTTON (button), column);
  gtk_widget_set_size_request (button, LK_TILE_ADD, -1);
  gtk_widget_add_css_class (button, "lk-add-tile");
  g_signal_connect (button, "clicked", G_CALLBACK (lk_add_tile_clicked), self);
  return button;
}

/* ---- the row ------------------------------------------------------------- */

/* What Lookout's own chart is built from. */
static char *
lk_gallery_own_detail (LkGallery *self)
{
  g_autoptr (GPtrArray) rows = lk_app_model_get_chart_sets (self->model);
  guint cells = 0;

  for (guint i = 0; i < rows->len; i++)
    {
      const LkChartSetRow *set = g_ptr_array_index (rows, i);

      if (set->on)
        cells += set->charts;
    }

  if (cells == 0)
    return g_strdup ("From your chart sets");
  return g_strdup_printf ("From your chart sets · %u cells", cells);
}

/* True when this url is on the mariner's own list. */
static gboolean
lk_gallery_is_mine (GPtrArray *links, const char *url)
{
  for (guint i = 0; i < links->len; i++)
    if (g_strcmp0 (((const LkChartLink *) g_ptr_array_index (links, i))->url, url) == 0)
      return TRUE;
  return FALSE;
}

/* The publisher's own name for a chart, once the core has read its style. */
static const char *
lk_gallery_name_of (GPtrArray *links, const char *url, const char *fallback)
{
  for (guint i = 0; i < links->len; i++)
    {
      const LkChartLink *link = g_ptr_array_index (links, i);

      if (g_strcmp0 (link->url, url) == 0 && link->name != NULL && link->name[0] != '\0')
        return link->name;
    }
  return fallback;
}

static void
lk_gallery_fill (LkGallery *self)
{
  LkChartLinks *links = lk_app_model_get_chart_links (self->model);
  const char *active = lk_chart_links_active (links);
  GPtrArray *mine = lk_chart_links_list (links);
  GtkWidget *child;
  guint n_catalog = 0;
  const LkChartCatalogEntry *catalog = lk_chart_catalog_entries (&n_catalog);

  while ((child = gtk_widget_get_first_child (self->row)) != NULL)
    gtk_box_remove (GTK_BOX (self->row), child);

  /* Lookout's own chart first. It is built from the sets below and cannot be
   * removed, so it carries no menu. */
  g_autofree char *own = lk_gallery_own_detail (self);
  gtk_box_append (GTK_BOX (self->row),
                  lk_tile_new (self, NULL, "Lookout chart", own,
                               lk_chart_welcome_picture (), active == NULL, FALSE));

  /* Then the charts the app ships, in their own order, so picking one does not
   * move the cards. */
  for (guint i = 0; i < n_catalog; i++)
    {
      const LkChartCatalogEntry *entry = &catalog[i];

      gtk_box_append (GTK_BOX (self->row),
                      lk_tile_new (self, entry->url,
                                   lk_gallery_name_of (mine, entry->url, entry->name),
                                   entry->url, lk_chart_catalog_art (entry->url),
                                   g_strcmp0 (active, entry->url) == 0,
                                   lk_gallery_is_mine (mine, entry->url)));
    }

  /* Then the links the mariner added themselves. */
  for (guint i = 0; i < mine->len; i++)
    {
      const LkChartLink *link = g_ptr_array_index (mine, i);

      if (lk_chart_catalog_entry (link->url) != NULL)
        continue; /* already drawn above, under the publisher's name */
      gtk_box_append (GTK_BOX (self->row),
                      lk_tile_new (self, link->url, link->name, link->url,
                                   lk_chart_catalog_art (link->url),
                                   g_strcmp0 (active, link->url) == 0, TRUE));
    }

  gtk_box_append (GTK_BOX (self->row), lk_add_tile_new (self));
}

static void
lk_gallery_changed (gpointer subject, gpointer user_data)
{
  GtkWidget *row = user_data;
  LkGallery *self = g_object_get_data (G_OBJECT (row), "lk-gallery");

  if (self == NULL || gtk_widget_in_destruction (row))
    return;
  lk_gallery_fill (self);
}

GtkWidget *
lk_chart_gallery_new (LkAppModel *model, LkChartGalleryAdd on_add, gpointer user_data)
{
  GtkWidget *scroller = gtk_scrolled_window_new ();
  LkGallery *self;

  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  self = g_new0 (LkGallery, 1);
  self->model = model;
  self->on_add = on_add;
  self->on_add_data = user_data;
  self->row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, LK_TILE_GAP);

  gtk_widget_set_margin_top (self->row, 2);
  gtk_widget_set_margin_bottom (self->row, 2);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), self->row);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
  /* The row is as tall as its tiles and no taller. */
  gtk_scrolled_window_set_propagate_natural_height (GTK_SCROLLED_WINDOW (scroller), TRUE);
  g_object_set_data_full (G_OBJECT (self->row), "lk-gallery", self, lk_gallery_free);

  /* A style the core has just read, a link added or dropped, and a set
   * switched on or off all change what this row says. */
  g_signal_connect_object (lk_app_model_get_chart_links (model), "changed",
                           G_CALLBACK (lk_gallery_changed), self->row, 0);
  g_signal_connect_object (model, "chart-sets-changed",
                           G_CALLBACK (lk_gallery_changed), self->row, 0);

  lk_gallery_fill (self);
  return scroller;
}
