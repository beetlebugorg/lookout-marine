/* ui/charts/gallery.c — see ui/charts/gallery.h. */
#include "ui/charts/gallery.h"

#include "ui/charts/preview.h"
#include "ui/charts/catalog.h"

/* The design's tile. A picture narrower than this cannot be told from another
 * publisher's picture of the same water. */
#define LK_TILE_WIDTH 250
#define LK_TILE_ART   132
#define LK_TILE_ADD   176
#define LK_TILE_GAP   10

typedef struct {
  LkAppModel        *model;    /* not owned */
  LkChartPreviews   *previews; /* owned: the pictures for this row */
  GtkWidget         *row;      /* the box the tiles are built into */
  LkChartGalleryAdd  on_add;
  gpointer           on_add_data;

  /* The row as it stands: the tile buttons in order, and the urls they were
   * built for. A report that changes neither is lettered into these. */
  GPtrArray         *tiles;  /* borrowed GtkWidget*, owned by the row */
  char              *shape;

  /* The chart just picked, and held until the core is drawing it. Reading a
   * publisher's style is the core's work and it runs inside a frame: a 389
   * layer style with a 5,354 cell sprite pack holds the main thread for over
   * a second on this machine. The tile says so for the whole of that wait.
   *
   * IT IS NOT DROPPED WHEN THE CORE IS TOLD. An ADD does not set the core's
   * active url until the style has landed, so between the two the snapshot
   * reads "busy, nothing active" — and NO ACTIVE URL IS LOOKOUT'S OWN CHART.
   * The row put the pick back on Lookout's chart for the whole resolve, which
   * reads as the pick being refused. */
  char              *pending;
  gboolean           pending_mine;
  /* The core has begun: from here a resolve that ends retires the pick. */
  gboolean           pending_begun;
  /* A pick the core never reports on must not mark the row for ever. */
  guint              pending_id;
} LkGallery;

static void lk_gallery_fill (LkGallery *self);

static void
lk_gallery_free (gpointer data)
{
  LkGallery *self = data;

  /* The row is going. The core stops drawing its pictures. */
  g_clear_object (&self->previews);
  g_free (self->shape);
  g_ptr_array_unref (self->tiles);
  g_clear_handle_id (&self->pending_id, g_source_remove);
  g_free (self->pending);
  g_free (self);
}

/* ---- what a tile does ---------------------------------------------------- */

/* Long enough for the slowest style this has been pointed at, and short enough
 * that a pick the core says nothing about does not mark the row for ever. */
#define LK_GALLERY_PICK_MS 25000

/* The core never reported on the pick. Give the row back to what is drawing. */
static gboolean
lk_gallery_pick_gave_up (gpointer user_data)
{
  GtkWidget *row = user_data;
  LkGallery *self = g_object_get_data (G_OBJECT (row), "lk-gallery");

  if (self == NULL || gtk_widget_in_destruction (row))
    return G_SOURCE_REMOVE;

  self->pending_id = 0;
  g_clear_pointer (&self->pending, g_free);
  self->pending_begun = FALSE;
  lk_gallery_fill (self);
  return G_SOURCE_REMOVE;
}

/* Pick this chart. A shipped entry the mariner has not taken yet is added
 * first, which the core reads and then picks. */
static void
lk_tile_clicked (GtkButton *button, gpointer user_data)
{
  LkGallery *self = user_data;
  const char *url = g_object_get_data (G_OBJECT (button), "lk-url");

  LkChartLinks *links = lk_app_model_get_chart_links (self->model);
  const char *active = lk_chart_links_active (links);
  const char *want = url != NULL ? url : "";
  gboolean mine = g_object_get_data (G_OBJECT (button), "lk-mine") != NULL;

  /* The chart this tile names is the one drawing, so there is no pick to
   * make. Asking the core for it again reads as a reload of a chart the
   * mariner is already on. */
  if (want[0] == '\0' ? active == NULL : g_strcmp0 (active, want) == 0)
    return;

  g_free (self->pending);
  self->pending = g_strdup (want);
  self->pending_mine = mine;
  self->pending_begun = FALSE;
  g_clear_handle_id (&self->pending_id, g_source_remove);
  self->pending_id = g_timeout_add (LK_GALLERY_PICK_MS, lk_gallery_pick_gave_up,
                                    self->row);

  /* The tile says it is being read before the core is asked. */
  lk_gallery_fill (self);

  /* NULL is how the links object spells "lookout's own chart". */
  if (want[0] == '\0' || mine)
    lk_chart_links_select (links, want[0] != '\0' ? want : NULL);
  else
    lk_chart_links_add (links, want);
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

/* One tile to draw. The row is planned first, and the plan is what each tile
 * is lettered from. */
typedef struct {
  const char *url;    /* NULL for Lookout's own chart */
  const char *name;
  const char *detail;
  GdkTexture *art;    /* borrowed from the picture store */
  gboolean    active;
  gboolean    mine;
} LkTilePlan;

/* The picture at the top of a tile, or the room one will take. The picture
 * arrives later, so the frame, the picture and the stand-in icon are all
 * built here and lk_tile_art_set chooses between them. */
static GtkWidget *
lk_tile_art (void)
{
  GtkWidget *art = gtk_overlay_new ();
  GtkWidget *frame = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  /* The frame requests the tile size, and the picture goes over it.
   *
   * GtkPicture requests the size and shape of its texture, so a 960 by 720
   * render made its tile 720 points tall, and a window-shaped snapshot made
   * a shorter one beside it. GtkOverlay does not measure overlay children,
   * so the frame fixes the size and the cover fit crops the picture. */
  gtk_widget_set_size_request (frame, LK_TILE_WIDTH, LK_TILE_ART);
  gtk_widget_add_css_class (frame, "lk-chart-art");
  gtk_overlay_set_child (GTK_OVERLAY (art), frame);
  gtk_widget_set_overflow (art, GTK_OVERFLOW_HIDDEN);

  GtkWidget *shot = gtk_picture_new ();
  /* A style with no picture yet draws its kind. A publisher's own portrayal
   * needs the style resolved and its tiles fetched, so the icon stands in
   * until the first render arrives. */
  GtkWidget *icon = gtk_image_new_from_icon_name ("network-workgroup-symbolic");

  gtk_picture_set_content_fit (GTK_PICTURE (shot), GTK_CONTENT_FIT_COVER);
  gtk_picture_set_can_shrink (GTK_PICTURE (shot), TRUE);
  gtk_image_set_pixel_size (GTK_IMAGE (icon), 26);
  gtk_widget_add_css_class (icon, "lk-accent");
  gtk_widget_set_valign (icon, GTK_ALIGN_CENTER);
  gtk_widget_set_halign (icon, GTK_ALIGN_CENTER);
  /* Overlay children both, so the frame alone sets the height. */
  gtk_overlay_add_overlay (GTK_OVERLAY (art), shot);
  gtk_overlay_add_overlay (GTK_OVERLAY (art), icon);

  g_object_set_data (G_OBJECT (art), "lk-frame", frame);
  g_object_set_data (G_OBJECT (art), "lk-shot", shot);
  g_object_set_data (G_OBJECT (art), "lk-icon", icon);
  return art;
}

static void
lk_tile_art_set (GtkWidget *art, GdkTexture *picture)
{
  GtkWidget *frame = g_object_get_data (G_OBJECT (art), "lk-frame");
  GtkWidget *shot = g_object_get_data (G_OBJECT (art), "lk-shot");
  GtkWidget *icon = g_object_get_data (G_OBJECT (art), "lk-icon");

  gtk_picture_set_paintable (GTK_PICTURE (shot),
                             picture != NULL ? GDK_PAINTABLE (picture) : NULL);
  gtk_widget_set_visible (shot, picture != NULL);
  gtk_widget_set_visible (icon, picture == NULL);
  if (picture != NULL)
    gtk_widget_remove_css_class (frame, "lk-chart-art-empty");
  else
    gtk_widget_add_css_class (frame, "lk-chart-art-empty");
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
 * mariner's list, which is the only kind that offers a menu.
 *
 * Built once per link list and lettered by lk_tile_apply after that. A tile
 * destroyed and built again for every report took the keyboard and the scroll
 * position with it.
 */
static GtkWidget *
lk_tile_new (LkGallery *self, const char *url, gboolean mine)
{
  GtkWidget *button = gtk_button_new ();
  GtkWidget *column = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *overlay = gtk_overlay_new ();
  GtkWidget *words = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);
  GtkWidget *title = gtk_label_new ("");
  GtkWidget *where = gtk_label_new ("");
  GtkWidget *art = lk_tile_art ();
  GtkWidget *badge = gtk_label_new ("ACTIVE");

  gtk_overlay_set_child (GTK_OVERLAY (overlay), art);

  /* The badge goes over the CLIPPED picture, not inside it: a picture that
   * fills by covering is wider than the tile, and a badge aligned inside it
   * starts left of the tile's own edge. */
  gtk_widget_add_css_class (badge, "lk-chart-badge");
  gtk_widget_set_halign (badge, GTK_ALIGN_START);
  gtk_widget_set_valign (badge, GTK_ALIGN_START);
  gtk_widget_set_margin_top (badge, 7);
  gtk_widget_set_margin_start (badge, 7);
  gtk_overlay_add_overlay (GTK_OVERLAY (overlay), badge);
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

  if (url != NULL)
    {
      g_object_set_data_full (G_OBJECT (button), "lk-url", g_strdup (url), g_free);
      gtk_widget_set_tooltip_text (button, url);
    }
  if (mine)
    g_object_set_data (G_OBJECT (button), "lk-mine", GINT_TO_POINTER (1));
  g_object_set_data (G_OBJECT (button), "lk-title", title);
  g_object_set_data (G_OBJECT (button), "lk-where", where);
  g_object_set_data (G_OBJECT (button), "lk-art", art);
  g_object_set_data (G_OBJECT (button), "lk-badge", badge);
  g_signal_connect (button, "clicked", G_CALLBACK (lk_tile_clicked), self);
  return button;
}

/* What this tile says now: its name, its line, its picture, and whether it is
 * the chart being drawn. */
static void
lk_tile_apply (GtkWidget *button, const LkTilePlan *tile)
{
  GtkWidget *badge = g_object_get_data (G_OBJECT (button), "lk-badge");

  gtk_label_set_text (g_object_get_data (G_OBJECT (button), "lk-title"), tile->name);
  gtk_label_set_text (g_object_get_data (G_OBJECT (button), "lk-where"), tile->detail);
  lk_tile_art_set (g_object_get_data (G_OBJECT (button), "lk-art"), tile->art);

  gtk_widget_set_visible (badge, tile->active);
  if (tile->active)
    gtk_widget_add_css_class (button, "lk-chart-tile-active");
  else
    gtk_widget_remove_css_class (button, "lk-chart-tile-active");
  gtk_accessible_update_state (GTK_ACCESSIBLE (button), GTK_ACCESSIBLE_STATE_SELECTED,
                               tile->active, -1);
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

/* Ask for a picture of every chart on the row.
 *
 * The chart being drawn is captured off the engine, which is the only true
 * picture of a publisher's portrayal. Everything else is a shipped picture or
 * one tile fetched at the mariner's own water. */
static void
lk_gallery_ask_for_pictures (LkGallery *self, GPtrArray *mine,
                             const LkChartCatalogEntry *catalog, guint n_catalog)
{
  g_autoptr (GPtrArray) urls = g_ptr_array_new ();

  /* Lookout's own chart is first, under the empty url. */
  g_ptr_array_add (urls, (gpointer) "");
  for (guint i = 0; i < n_catalog; i++)
    g_ptr_array_add (urls, (gpointer) catalog[i].url);
  for (guint i = 0; i < mine->len; i++)
    {
      const LkChartLink *link = g_ptr_array_index (mine, i);

      if (lk_chart_catalog_entry (link->url) == NULL)
        g_ptr_array_add (urls, link->url);
    }
  g_ptr_array_add (urls, NULL);

  /* In device pixels: the core's second handle draws at no density of its
   * own. */
  int scale = gtk_widget_get_scale_factor (self->row);

  lk_chart_previews_want (self->previews, (const char *const *) urls->pdata,
                          LK_TILE_WIDTH * scale, LK_TILE_ART * scale);
}


static void
lk_gallery_fill (LkGallery *self)
{
  LkChartLinks *links = lk_app_model_get_chart_links (self->model);
  const char *active = lk_chart_links_active (links);
  GPtrArray *mine = lk_chart_links_list (links);
  g_autoptr (GArray) plan = g_array_new (FALSE, TRUE, sizeof (LkTilePlan));
  guint n_catalog = 0;
  const LkChartCatalogEntry *catalog = lk_chart_catalog_entries (&n_catalog);

  /* First, so the tiles below show what the core has drawn by now. */
  lk_gallery_ask_for_pictures (self, mine, catalog, n_catalog);

  /* A chart being read is the one the mariner picked, whatever the core still
   * reports as active, and its line says what is happening. */
  gboolean busy = lk_chart_links_busy (links);

  /* Retire the pick once the core has answered for it: it is the chart being
   * drawn, or the resolve that began for it has ended. Only after the core has
   * BEGUN, because the error and the active url both still read as the last
   * chart's until then. */
  if (self->pending != NULL)
    {
      gboolean landed = self->pending[0] == '\0'
                            ? active == NULL
                            : g_strcmp0 (active, self->pending) == 0;

      if (busy)
        self->pending_begun = TRUE;
      if (landed || (self->pending_begun && !busy))
        {
          g_clear_pointer (&self->pending, g_free);
          self->pending_begun = FALSE;
          g_clear_handle_id (&self->pending_id, g_source_remove);
        }
    }

  const char *picked = self->pending != NULL ? self->pending
                       : busy                ? (active != NULL ? active : "")
                                             : NULL;

  /* Lookout's own chart first. It is built from the sets below and cannot be
   * removed, so it has no menu. */
  g_autofree char *own = lk_gallery_own_detail (self);
  gboolean own_picked = picked != NULL && picked[0] == '\0';
  LkTilePlan first = { NULL, "Lookout chart", own_picked ? "Reading this chart…" : own,
                       lk_chart_previews_get (self->previews, NULL),
                       own_picked || (picked == NULL && active == NULL), FALSE };
  g_array_append_val (plan, first);

  /* Then the charts the app ships, in their own order, so picking one does not
   * move the cards. */
  for (guint i = 0; i < n_catalog; i++)
    {
      const LkChartCatalogEntry *entry = &catalog[i];
      gboolean reading = g_strcmp0 (picked, entry->url) == 0;
      LkTilePlan tile = { entry->url,
                          lk_gallery_name_of (mine, entry->url, entry->name),
                          reading ? "Reading this chart…" : entry->url,
                          lk_chart_previews_get (self->previews, entry->url),
                          reading || (picked == NULL && g_strcmp0 (active, entry->url) == 0),
                          lk_gallery_is_mine (mine, entry->url) };

      g_array_append_val (plan, tile);
    }

  /* Then the links the mariner added themselves. */
  for (guint i = 0; i < mine->len; i++)
    {
      const LkChartLink *link = g_ptr_array_index (mine, i);
      gboolean reading = g_strcmp0 (picked, link->url) == 0;
      LkTilePlan tile = { link->url, link->name,
                          reading ? "Reading this chart…" : link->url,
                          lk_chart_previews_get (self->previews, link->url),
                          reading || (picked == NULL && g_strcmp0 (active, link->url) == 0),
                          TRUE };

      if (lk_chart_catalog_entry (link->url) != NULL)
        continue; /* already planned above, under the publisher's name */
      g_array_append_val (plan, tile);
    }

  /* THE TILES ARE BUILT ONCE PER LINK LIST. A tile destroyed and built again
   * on every report took the keyboard focus and the scroll position with it,
   * and the row jumped home each time a chart was picked. The shape is the
   * urls in order: anything else a report changes is lettered in place. */
  g_autoptr (GString) shape = g_string_new (NULL);

  for (guint i = 0; i < plan->len; i++)
    {
      const LkTilePlan *tile = &g_array_index (plan, LkTilePlan, i);

      g_string_append_printf (shape, "%s\x1f%d\x1e",
                              tile->url != NULL ? tile->url : "", tile->mine);
    }

  if (g_strcmp0 (shape->str, self->shape) != 0)
    {
      GtkWidget *child;

      g_free (self->shape);
      self->shape = g_strdup (shape->str);
      g_ptr_array_set_size (self->tiles, 0);

      while ((child = gtk_widget_get_first_child (self->row)) != NULL)
        gtk_box_remove (GTK_BOX (self->row), child);

      for (guint i = 0; i < plan->len; i++)
        {
          const LkTilePlan *tile = &g_array_index (plan, LkTilePlan, i);
          GtkWidget *button = lk_tile_new (self, tile->url, tile->mine);

          g_ptr_array_add (self->tiles, button);
          gtk_box_append (GTK_BOX (self->row), button);
        }
      gtk_box_append (GTK_BOX (self->row), lk_add_tile_new (self));
    }

  for (guint i = 0; i < plan->len && i < self->tiles->len; i++)
    lk_tile_apply (g_ptr_array_index (self->tiles, i),
                   &g_array_index (plan, LkTilePlan, i));

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
  self->tiles = g_ptr_array_new ();
  self->previews = lk_chart_previews_new (lk_app_model_get_controller (model));

  gtk_widget_set_margin_top (self->row, 2);
  gtk_widget_set_margin_bottom (self->row, 2);
  /* The row keeps its own height, and every tile fills it. The tile that
   * adds a chart has a line of words and no picture, so its own height is
   * less than the height of the tiles beside it. */
  gtk_widget_set_valign (self->row, GTK_ALIGN_START);
  gtk_scrolled_window_set_child (GTK_SCROLLED_WINDOW (scroller), self->row);
  gtk_scrolled_window_set_policy (GTK_SCROLLED_WINDOW (scroller),
                                  GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
  /* gtk_widget_compute_expand reads the children, so the gallery sets the
   * flag itself: a picture inside a tile must not claim the spare height of
   * the page the gallery is on. */
  gtk_widget_set_vexpand (scroller, FALSE);
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
