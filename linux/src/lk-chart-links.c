/* lk-chart-links.c — charts by link. See lk-chart-links.h.
 *
 * WHY THE STYLE IS REWRITTEN ON THE WAY IN. A source may name its tiles
 * inline ("tiles": [...]) or point at a TileJSON document ("url": ...). Only
 * the first is something lookout can act on, so a TileJSON source is resolved
 * HERE, once, and its answer inlined before the style goes down. */
#include "lk-chart-links.h"

#include "lk-store.h"

#include <json-glib/json-glib.h>
#include <libsoup/soup.h>
#include <string.h>

/* A unique, identifiable agent with a way to reach the developer: public tile
 * hosts (openstreetmap.org's tile usage policy, osm.wiki/Blocked_tiles) serve
 * "access blocked" placeholder tiles to anonymous or platform-default agents. */
#define LK_LINKS_USER_AGENT \
  "LookoutMarine/1.0 (Linux; org.beetlebug.lookout; contact jeremy.collins@beetlebug.org)"
#define LK_LINKS_REFERER "https://beetlebug.org/"

/* status codes lk_chart_controller_tile_respond takes. */
enum {
  LK_TILE_BYTES = 0,
  LK_TILE_NONE = 1,   /* no tile there — remembered, not re-asked */
  LK_TILE_FAILED = 2, /* tried and failed — also remembered */
};

/* One source of the active style: its url templates and whether y counts from
 * the south. */
typedef struct {
  char   **templates; /* NULL-terminated */
  guint    n;
  gboolean tms;
} LkTileSource;

static void
lk_tile_source_free (gpointer data)
{
  LkTileSource *source = data;

  g_strfreev (source->templates);
  g_free (source);
}

/* One sprite pack a style declares: the pack id as the icon-name prefix (""
 * for the spec's "default"), and the base url `.json`/`.png` append to. */
typedef struct {
  char *prefix;
  char *url;
} LkSpritePackRef;

static void
lk_sprite_pack_ref_free (gpointer data)
{
  LkSpritePackRef *ref = data;

  g_free (ref->prefix);
  g_free (ref->url);
  g_free (ref);
}

/* A pack fetched whole, ready for the engine. */
typedef struct {
  char   *prefix;
  GBytes *json;
  GBytes *png;
} LkSpritePack;

static void
lk_sprite_pack_free (gpointer data)
{
  LkSpritePack *pack = data;

  g_free (pack->prefix);
  g_clear_pointer (&pack->json, g_bytes_unref);
  g_clear_pointer (&pack->png, g_bytes_unref);
  g_free (pack);
}

static void
lk_chart_link_free (gpointer data)
{
  LkChartLink *link = data;

  g_free (link->url);
  g_free (link->name);
  g_free (link->doc);
  g_free (link);
}

struct _LkChartLinks {
  GObject parent_instance;

  LkChartController *controller; /* strong: a late fetch must find it alive */

  GPtrArray *links;  /* LkChartLink* */
  char      *active; /* url, or NULL for lookout's own chart */
  char      *attribution;
  char      *error;

  /* The active style's sources, for the tile provider. Owned and read on the
   * main thread only — the render tick runs there, so no lock. */
  GHashTable *sources; /* name → LkTileSource */
  gboolean    live;
  GHashTable *logged; /* the source names already logged, so once each */

  SoupSession  *tile_session; /* main-thread async fetches */
  GCancellable *tile_cancel;  /* one generation of tile fetches */

  /* Guards the race the mariner can cause: picking a second chart while the
   * first is still being fetched. The slower fetch must not win. */
  guint64 epoch;
};

enum {
  SIGNAL_CHANGED,
  N_SIGNALS
};

static guint signals[N_SIGNALS];

G_DEFINE_FINAL_TYPE (LkChartLinks, lk_chart_links, G_TYPE_OBJECT)

static void lk_chart_links_push (LkChartLinks *self);

/* ---- fetching ------------------------------------------------------------ */

/* A session for one resolve worker. Sync soup wants the thread that made it,
 * so each worker builds its own and drops it with the thread. */
static SoupSession *
lk_links_worker_session (void)
{
  /* A stalled fetch must not hold the worker forever: the chart is drawn from
   * whatever HAS landed, so a slow answer costs only itself. */
  return soup_session_new_with_options ("user-agent", LK_LINKS_USER_AGENT,
                                        "timeout", 20,
                                        "idle-timeout", 10,
                                        NULL);
}

/* One GET. NULL unless the answer was a 200; `out_status` (optional) carries
 * the HTTP status either way, 0 on transport failure. */
static GBytes *
lk_links_fetch_url (SoupSession *session, const char *url, guint *out_status)
{
  if (out_status != NULL)
    *out_status = 0;

  g_autoptr (SoupMessage) msg = soup_message_new (SOUP_METHOD_GET, url);
  if (msg == NULL)
    return NULL;
  soup_message_headers_append (soup_message_get_request_headers (msg),
                               "Referer", LK_LINKS_REFERER);

  g_autoptr (GBytes) bytes = soup_session_send_and_read (session, msg, NULL, NULL);
  guint status = soup_message_get_status (msg);

  if (out_status != NULL)
    *out_status = status;
  if (bytes == NULL || status != SOUP_STATUS_OK)
    return NULL;
  return g_steal_pointer (&bytes);
}

/* A style document off the disk, for a file path or file:// link; NULL when
 * the link is not a file. A mariner's own style.json is a real way to get a
 * chart aboard — offline, or one they wrote themselves. */
static char *
lk_links_read_file_link (const char *link)
{
  const char *path = link;
  char *text = NULL;

  if (g_str_has_prefix (path, "file://"))
    path += strlen ("file://");
  else if (path[0] != '/')
    return NULL;
  if (!g_file_get_contents (path, &text, NULL, NULL))
    return NULL;
  return text;
}

/* True for a path or file url — something the mariner keeps on disk, whose
 * style may in turn name files beside it. */
static gboolean
lk_links_is_file_link (const char *link)
{
  return g_str_has_prefix (link, "file://") || link[0] == '/';
}

/* `allow_file` marks a link the MARINER typed, or one derived from it. Only
 * those may read the disk: a url found inside a document fetched from the
 * network must never reach the file branch, or a hostile style gets the
 * shell reading arbitrary local files as its "TileJSON". */
static char *
lk_links_fetch_text (SoupSession *session, const char *link, gboolean allow_file)
{
  char *from_file = allow_file ? lk_links_read_file_link (link) : NULL;

  if (from_file != NULL)
    return from_file;

  g_autoptr (GBytes) bytes = lk_links_fetch_url (session, link, NULL);
  if (bytes == NULL)
    return NULL;

  gsize length = 0;
  const char *data = g_bytes_get_data (bytes, &length);
  return g_strndup (data, length);
}

/* ---- JSON ---------------------------------------------------------------- */

/* Parse `text` as a JSON object. The object is borrowed from the returned
 * parser; NULL when the text is not an object. */
static JsonParser *
lk_links_parse_object (const char *text, JsonObject **out)
{
  *out = NULL;
  if (text == NULL)
    return NULL;

  JsonParser *parser = json_parser_new ();
  JsonNode *root = NULL;

  if (!json_parser_load_from_data (parser, text, -1, NULL) ||
      (root = json_parser_get_root (parser)) == NULL ||
      !JSON_NODE_HOLDS_OBJECT (root))
    {
      g_object_unref (parser);
      return NULL;
    }
  *out = json_node_get_object (root);
  return parser;
}

/* A string member, or `fallback` when absent or another type — a style off
 * the network earns no assumptions. */
static const char *
lk_links_member_string (JsonObject *object, const char *name, const char *fallback)
{
  JsonNode *node = object != NULL ? json_object_get_member (object, name) : NULL;

  if (node == NULL || !JSON_NODE_HOLDS_VALUE (node) ||
      json_node_get_value_type (node) != G_TYPE_STRING)
    return fallback;
  return json_node_get_string (node);
}

/* Serialize an object this file built. Takes ownership. */
static char *
lk_links_stringify_object (JsonObject *object)
{
  JsonNode *node = json_node_new (JSON_NODE_OBJECT);

  json_node_take_object (node, object);

  g_autoptr (JsonGenerator) generator = json_generator_new ();
  json_generator_set_root (generator, node);
  json_node_free (node);
  return json_generator_to_data (generator, NULL);
}

/* ---- the style, read and rewritten --------------------------------------- */

/* The style's `sprite` root: one base url, or the array form of {id, url}
 * packs whose icons resolve as "id:name" ("default" gives bare names). */
static GPtrArray *
lk_links_sprite_packs_of (JsonObject *top)
{
  GPtrArray *out = g_ptr_array_new_with_free_func (lk_sprite_pack_ref_free);
  JsonNode *node = json_object_get_member (top, "sprite");

  if (node == NULL)
    return out;
  if (JSON_NODE_HOLDS_VALUE (node) && json_node_get_value_type (node) == G_TYPE_STRING)
    {
      const char *url = json_node_get_string (node);
      if (url != NULL && url[0] != '\0')
        {
          LkSpritePackRef *ref = g_new0 (LkSpritePackRef, 1);
          ref->prefix = g_strdup ("");
          ref->url = g_strdup (url);
          g_ptr_array_add (out, ref);
        }
      return out;
    }
  if (!JSON_NODE_HOLDS_ARRAY (node))
    return out;

  JsonArray *array = json_node_get_array (node);
  for (guint i = 0; i < json_array_get_length (array); i++)
    {
      JsonNode *element = json_array_get_element (array, i);
      if (!JSON_NODE_HOLDS_OBJECT (element))
        continue;

      JsonObject *pack = json_node_get_object (element);
      const char *url = lk_links_member_string (pack, "url", "");
      if (url[0] == '\0')
        continue;

      const char *id = lk_links_member_string (pack, "id", "");
      LkSpritePackRef *ref = g_new0 (LkSpritePackRef, 1);
      ref->prefix = g_strdup (g_str_equal (id, "default") ? "" : id);
      ref->url = g_strdup (url);
      g_ptr_array_add (out, ref);
    }
  return out;
}

/* Fetch a style's sprite packs whole, into `out` (LkSpritePack). @2x first —
 * the sheets draw at their authored logical size whatever the ratio, and
 * every display that matters is dense — with the 1x pack as the fallback for
 * a publisher who ships only one. A pack that will not fetch is skipped, not
 * fatal: the chart draws, short its icons. */
/* "\xe2\x80\xa6/sprite" + "@2x" + ".json", keeping a query string at the end: an
 * API-keyed host serves \xe2\x80\xa6/sprite@2x.json?key=K, never \xe2\x80\xa6?key=K@2x.json. */
static char *
lk_links_sprite_variant (const char *base, const char *density, const char *ext)
{
  const char *q = strchr (base, '?');

  if (q == NULL)
    return g_strconcat (base, density, ext, NULL);

  g_autofree char *stem = g_strndup (base, q - base);
  return g_strconcat (stem, density, ext, q, NULL);
}

static void
lk_links_fetch_sprite_packs (SoupSession *session, GPtrArray *refs, GPtrArray *out)
{
  static const char *densities[] = { "@2x", "" };

  for (guint i = 0; refs != NULL && i < refs->len; i++)
    {
      LkSpritePackRef *ref = g_ptr_array_index (refs, i);
      gboolean got = FALSE;

      for (gsize d = 0; d < G_N_ELEMENTS (densities) && !got; d++)
        {
          g_autofree char *json_url = lk_links_sprite_variant (ref->url, densities[d], ".json");
          g_autofree char *png_url = lk_links_sprite_variant (ref->url, densities[d], ".png");
          g_autoptr (GBytes) json = lk_links_fetch_url (session, json_url, NULL);
          g_autoptr (GBytes) png =
              json != NULL ? lk_links_fetch_url (session, png_url, NULL) : NULL;

          if (json == NULL || png == NULL)
            continue;

          LkSpritePack *pack = g_new0 (LkSpritePack, 1);
          pack->prefix = g_strdup (ref->prefix);
          pack->json = g_steal_pointer (&json);
          pack->png = g_steal_pointer (&png);
          g_ptr_array_add (out, pack);
          got = TRUE;
        }
      if (!got)
        g_warning ("sprite pack %s: fetch failed; its icons will be missing", ref->url);
    }
}

static void
lk_links_wrapper_layer (JsonArray *layers, const char *lid, const char *suffix,
                        const char *type, const char *kind, JsonObject *paint)
{
  JsonObject *layer = json_object_new ();
  g_autofree char *id = g_strconcat (lid, suffix, NULL);

  json_object_set_string_member (layer, "id", id);
  json_object_set_string_member (layer, "type", type);
  json_object_set_string_member (layer, "source", "tiles");
  json_object_set_string_member (layer, "source-layer", lid);

  JsonArray *filter = json_array_new ();
  JsonArray *getter = json_array_new ();
  json_array_add_string_element (filter, "==");
  json_array_add_string_element (getter, "geometry-type");
  json_array_add_array_element (filter, getter);
  json_array_add_string_element (filter, kind);
  json_object_set_array_member (layer, "filter", filter);

  json_object_set_object_member (layer, "paint", paint);
  json_array_add_object_element (layers, layer);
}

/* A style for a bare tile source. Raster tiles draw as imagery; vector tiles
 * draw each advertised layer in a legible generic scheme — honest geometry,
 * not the publisher's portrayal (a tile source doesn't carry one). The look
 * matches the other shells' wrappers, hue for hue. */
static char *
lk_links_tilejson_wrapper_style (const char *link, JsonObject *tilejson)
{
  JsonArray *layers = json_array_new ();

  {
    JsonObject *bg = json_object_new ();
    JsonObject *paint = json_object_new ();
    json_object_set_string_member (bg, "id", "bg");
    json_object_set_string_member (bg, "type", "background");
    json_object_set_string_member (paint, "background-color", "#c9e2f0");
    json_object_set_object_member (bg, "paint", paint);
    json_array_add_object_element (layers, bg);
  }

  JsonObject *source = json_object_new ();
  json_object_set_string_member (source, "url", link);

  JsonNode *vlayers = json_object_get_member (tilejson, "vector_layers");
  gboolean vector = vlayers != NULL && JSON_NODE_HOLDS_ARRAY (vlayers) &&
                    json_array_get_length (json_node_get_array (vlayers)) > 0;

  if (!vector)
    {
      json_object_set_string_member (source, "type", "raster");
      JsonObject *tiles = json_object_new ();
      json_object_set_string_member (tiles, "id", "tiles");
      json_object_set_string_member (tiles, "type", "raster");
      json_object_set_string_member (tiles, "source", "tiles");
      json_array_add_object_element (layers, tiles);
    }
  else
    {
      json_object_set_string_member (source, "type", "vector");

      static const double hues[] = { 210, 30, 120, 275, 0, 165, 55, 320 };
      JsonArray *array = json_node_get_array (vlayers);
      for (guint i = 0; i < json_array_get_length (array); i++)
        {
          JsonNode *element = json_array_get_element (array, i);
          if (!JSON_NODE_HOLDS_OBJECT (element))
            continue;
          const char *lid =
              lk_links_member_string (json_node_get_object (element), "id", "");
          if (lid[0] == '\0')
            continue;

          g_autofree char *low = g_ascii_strdown (lid, -1);
          double point_radius = 2.5;
          char *fill, *line, *point;
          if (strstr (low, "depare") != NULL || strstr (low, "depth") != NULL ||
              strstr (low, "bathy") != NULL)
            {
              fill = g_strdup ("hsla(205,60%,70%,0.5)");
              line = g_strdup ("hsl(205,45%,55%)");
              point = g_strdup ("hsl(205,45%,45%)");
            }
          else if (strstr (low, "contour") != NULL)
            {
              fill = g_strdup ("hsla(205,30%,60%,0.15)");
              line = g_strdup ("hsl(205,35%,55%)");
              point = g_strdup ("hsl(205,35%,45%)");
            }
          else if (strstr (low, "sound") != NULL)
            {
              point_radius = 1.5;
              fill = g_strdup ("hsla(210,25%,55%,0.2)");
              line = g_strdup ("hsl(210,25%,55%)");
              point = g_strdup ("hsl(210,25%,35%)");
            }
          else if (strstr (low, "land") != NULL || strstr (low, "coast") != NULL)
            {
              fill = g_strdup ("hsla(45,45%,70%,0.9)");
              line = g_strdup ("hsl(45,30%,40%)");
              point = g_strdup ("hsl(45,30%,40%)");
            }
          else
            {
              double hue = hues[i % G_N_ELEMENTS (hues)];
              fill = g_strdup_printf ("hsla(%g,55%%,62%%,0.35)", hue);
              line = g_strdup_printf ("hsl(%g,60%%,38%%)", hue);
              point = g_strdup_printf ("hsl(%g,65%%,40%%)", hue);
            }

          JsonObject *pf = json_object_new ();
          json_object_set_string_member (pf, "fill-color", fill);
          lk_links_wrapper_layer (layers, lid, "-fill", "fill", "Polygon", pf);

          JsonObject *pl = json_object_new ();
          json_object_set_string_member (pl, "line-color", line);
          json_object_set_double_member (pl, "line-width", 1.0);
          lk_links_wrapper_layer (layers, lid, "-line", "line", "LineString", pl);

          JsonObject *pp = json_object_new ();
          json_object_set_double_member (pp, "circle-radius", point_radius);
          json_object_set_string_member (pp, "circle-color", point);
          lk_links_wrapper_layer (layers, lid, "-pt", "circle", "Point", pp);

          g_free (fill);
          g_free (line);
          g_free (point);
        }
    }

  JsonObject *style = json_object_new ();
  JsonObject *sources = json_object_new ();
  json_object_set_int_member (style, "version", 8);
  json_object_set_string_member (style, "name",
                                 lk_links_member_string (tilejson, "name", "Tiles"));
  json_object_set_object_member (sources, "tiles", source);
  json_object_set_object_member (style, "sources", sources);
  json_object_set_array_member (style, "layers", layers);
  return lk_links_stringify_object (style);
}

/* The style.json living beside a TileJSON, when the publisher shipped one:
 * that is the look the mariner pasted the link expecting. Only if it parses
 * as a MapLibre style. */
static gboolean
lk_links_sibling_style (SoupSession *session, const char *link,
                        char **out_url, char **out_name)
{
  const char *cut = strrchr (link, '/');

  if (cut == NULL)
    return FALSE;

  g_autofree char *candidate =
      g_strdup_printf ("%.*s/style.json", (int) (cut - link), link);
  if (g_str_equal (candidate, link))
    return FALSE;

  g_autofree char *text = lk_links_fetch_text (session, candidate, FALSE);
  JsonObject *style = NULL;
  g_autoptr (JsonParser) parser = lk_links_parse_object (text, &style);
  if (parser == NULL || !json_object_has_member (style, "layers") ||
      !json_object_has_member (style, "version"))
    return FALSE;

  const char *name = lk_links_member_string (style, "name", "");
  *out_name = g_strdup (name[0] != '\0' ? name : candidate);
  *out_url = g_steal_pointer (&candidate);
  return TRUE;
}

/* Read a link and work out what chart it is: a whole MapLibre style (keep the
 * url and fetch it each time), a TileJSON (tiles with no style of their own —
 * a wrapper is generated), or a mariner's style file (its TEXT is carried,
 * since the path may not answer next launch the same way). FALSE when nothing
 * chart-like is there. */
static gboolean
lk_links_probe (SoupSession *session, const char *raw,
                char **out_url, char **out_name, char **out_doc)
{
  g_autofree char *file_text = lk_links_read_file_link (raw);
  if (file_text != NULL)
    {
      JsonObject *style = NULL;
      g_autoptr (JsonParser) parser = lk_links_parse_object (file_text, &style);
      if (parser == NULL || !json_object_has_member (style, "layers") ||
          !json_object_has_member (style, "version"))
        return FALSE;

      const char *name = lk_links_member_string (style, "name", "");
      if (name[0] != '\0')
        {
          *out_name = g_strdup (name);
        }
      else
        {
          char *base = g_path_get_basename (raw);
          char *dot = strrchr (base, '.');
          if (dot != NULL && dot != base)
            *dot = '\0';
          *out_name = base;
        }
      *out_url = g_strdup (raw);
      *out_doc = g_steal_pointer (&file_text);
      return TRUE;
    }

  g_autofree char *text = lk_links_fetch_text (session, raw, TRUE);
  JsonObject *top = NULL;
  g_autoptr (JsonParser) parser = lk_links_parse_object (text, &top);
  if (parser == NULL)
    return FALSE;

  if (json_object_has_member (top, "layers") && json_object_has_member (top, "version"))
    {
      const char *name = lk_links_member_string (top, "name", "");
      *out_name = g_strdup (name[0] != '\0' ? name : raw);
      *out_url = g_strdup (raw);
      *out_doc = g_strdup ("");
      return TRUE;
    }
  if (json_object_has_member (top, "tiles") || json_object_has_member (top, "tilejson"))
    {
      if (lk_links_sibling_style (session, raw, out_url, out_name))
        {
          *out_doc = g_strdup ("");
          return TRUE;
        }
      const char *name = lk_links_member_string (top, "name", "");
      *out_name = g_strdup (name[0] != '\0' ? name : raw);
      *out_url = g_strdup (raw);
      *out_doc = lk_links_tilejson_wrapper_style (raw, top);
      return TRUE;
    }
  return FALSE;
}

/* The credit line a style's sources ask for, HTML markup reduced to its
 * text. Public tile hosts make the visible credit a condition of service
 * (openstreetmap.org's tile usage policy among them). */
static char *
lk_links_strip_attribution (const char *raw)
{
  GString *out = g_string_new (NULL);
  gboolean in_tag = FALSE;

  for (const char *p = raw; *p != '\0'; p++)
    {
      if (*p == '<') { in_tag = TRUE; continue; }
      if (*p == '>') { in_tag = FALSE; continue; }
      if (in_tag)
        continue;
      if (g_str_has_prefix (p, "&copy;")) { g_string_append (out, "\xC2\xA9"); p += 5; continue; }
      if (g_str_has_prefix (p, "&lt;")) { g_string_append_c (out, '<'); p += 3; continue; }
      if (g_str_has_prefix (p, "&gt;")) { g_string_append_c (out, '>'); p += 3; continue; }
      if (g_str_has_prefix (p, "&quot;")) { g_string_append_c (out, '"'); p += 5; continue; }
      if (g_str_has_prefix (p, "&#39;")) { g_string_append_c (out, '\''); p += 4; continue; }
      if (g_str_has_prefix (p, "&nbsp;")) { g_string_append_c (out, ' '); p += 5; continue; }
      if (g_str_has_prefix (p, "&amp;")) { g_string_append_c (out, '&'); p += 4; continue; }
      g_string_append_c (out, *p);
    }
  /* Trim the whitespace the markup leaves behind. */
  return g_strstrip (g_string_free (out, FALSE));
}

/* Resolve a style: inline every TileJSON source, collect each source's url
 * templates and TMS flag for the tile provider, and gather the sources'
 * attribution for display. Fills `out_json` with the rewritten style; FALSE
 * when the text is not a style. */
static gboolean
lk_links_resolve_style (SoupSession *session, const char *raw, char **out_json,
                        GHashTable *out_sources, char **out_attribution,
                        GPtrArray **out_pack_refs, gboolean local_style)
{
  JsonObject *top = NULL;
  g_autoptr (JsonParser) parser = lk_links_parse_object (raw, &top);

  if (parser == NULL)
    return FALSE;
  *out_pack_refs = lk_links_sprite_packs_of (top);

  JsonNode *declared = json_object_get_member (top, "sources");
  if (declared == NULL || !JSON_NODE_HOLDS_OBJECT (declared))
    return FALSE;

  JsonObject *sources = json_node_get_object (declared);
  g_autoptr (GPtrArray) credits = g_ptr_array_new_with_free_func (g_free);
  g_autoptr (GList) names = json_object_get_members (sources);

  for (GList *l = names; l != NULL; l = l->next)
    {
      JsonNode *node = json_object_get_member (sources, l->data);
      if (!JSON_NODE_HOLDS_OBJECT (node))
        continue;
      JsonObject *src = json_node_get_object (node);

      if (!json_object_has_member (src, "tiles"))
        {
          const char *link = lk_links_member_string (src, "url", "");
          g_autofree char *text =
              link[0] != '\0' ? lk_links_fetch_text (session, link, local_style) : NULL;
          JsonObject *doc = NULL;
          g_autoptr (JsonParser) doc_parser = lk_links_parse_object (text, &doc);
          if (doc_parser != NULL)
            {
              static const char *keys[] = { "tiles", "minzoom", "maxzoom",
                                            "bounds", "scheme", "attribution" };
              for (gsize k = 0; k < G_N_ELEMENTS (keys); k++)
                {
                  if (json_object_has_member (doc, keys[k]))
                    json_object_set_member (src, keys[k],
                                            json_node_copy (json_object_get_member (doc, keys[k])));
                }
              /* TileJSON says tileSize nowhere; raster tiles are 256 unless
               * the style already said otherwise, and getting this wrong
               * draws the imagery one zoom level off. */
              if (!json_object_has_member (src, "tileSize") &&
                  g_str_equal (lk_links_member_string (src, "type", ""), "raster"))
                json_object_set_int_member (src, "tileSize", 256);
              json_object_remove_member (src, "url");
            }
        }

      JsonNode *tiles = json_object_get_member (src, "tiles");
      if (tiles == NULL || !JSON_NODE_HOLDS_ARRAY (tiles))
        continue;
      JsonArray *array = json_node_get_array (tiles);
      g_autoptr (GPtrArray) templates = g_ptr_array_new_with_free_func (g_free);
      for (guint i = 0; i < json_array_get_length (array); i++)
        {
          JsonNode *e = json_array_get_element (array, i);
          if (JSON_NODE_HOLDS_VALUE (e) && json_node_get_value_type (e) == G_TYPE_STRING)
            g_ptr_array_add (templates, g_strdup (json_node_get_string (e)));
        }
      if (templates->len == 0)
        continue;

      g_autofree char *scheme =
          g_ascii_strdown (lk_links_member_string (src, "scheme", ""), -1);
      LkTileSource *source = g_new0 (LkTileSource, 1);
      source->tms = g_str_equal (scheme, "tms");
      source->n = templates->len;
      g_ptr_array_add (templates, NULL);
      source->templates = (char **) g_ptr_array_free (g_steal_pointer (&templates), FALSE);
      g_hash_table_replace (out_sources, g_strdup (l->data), source);

      char *credit =
          lk_links_strip_attribution (lk_links_member_string (src, "attribution", ""));
      if (credit[0] != '\0')
        g_ptr_array_add (credits, credit);
      else
        g_free (credit);
    }

  /* Distinct, and an attribution CONTAINED in another is dropped — sources
   * repeat each other's credits inside composite strings, and keeping both
   * made the line longer than the scale readout it sits beside. */
  GString *attribution = g_string_new (NULL);
  for (guint i = 0; i < credits->len; i++)
    {
      const char *credit = g_ptr_array_index (credits, i);
      gboolean drop = FALSE;
      for (guint k = 0; k < credits->len && !drop; k++)
        {
          const char *other = g_ptr_array_index (credits, k);
          if (k == i)
            continue;
          if (g_str_equal (other, credit))
            drop = k < i; /* exact duplicate: the first one speaks */
          else if (strstr (other, credit) != NULL)
            drop = TRUE; /* contained in a longer credit */
        }
      if (drop)
        continue;
      if (attribution->len > 0)
        g_string_append (attribution, " \xC2\xB7 ");
      g_string_append (attribution, credit);
    }
  *out_attribution = g_string_free (attribution, FALSE);

  g_autoptr (JsonGenerator) generator = json_generator_new ();
  json_generator_set_root (generator, json_parser_get_root (parser));
  *out_json = json_generator_to_data (generator, NULL);
  return TRUE;
}

/* Fill a source's url template for one tile. The subdomain pick is
 * deterministic, so the same tile keeps hitting the same host and stays
 * cached there. TMS counts y from the south. */
static char *
lk_links_tile_url (LkTileSource *source, int z, int x, int y)
{
  if (source == NULL || source->n == 0)
    return NULL;

  int ty = source->tms ? (1 << z) - 1 - y : y;
  g_autofree char *zs = g_strdup_printf ("%d", z);
  g_autofree char *xs = g_strdup_printf ("%d", x);
  g_autofree char *ys = g_strdup_printf ("%d", ty);
  GString *url = g_string_new (source->templates[(guint) ABS (x + y) % source->n]);

  g_string_replace (url, "{z}", zs, 0);
  g_string_replace (url, "{x}", xs, 0);
  g_string_replace (url, "{y}", ys, 0);
  return g_string_free (url, FALSE);
}

/* ---- the tile provider --------------------------------------------------- */

typedef struct {
  LkChartLinks *self; /* strong */
  SoupMessage  *msg;  /* to read the status in the completion */
  guint64       id;
} LkTileFetch;

static void
lk_links_tile_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkTileFetch *fetch = user_data;
  g_autoptr (GError) error = NULL;
  g_autoptr (GBytes) bytes =
      soup_session_send_and_read_finish (SOUP_SESSION (source_object), result, &error);

  if (error != NULL && g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    {
      /* The style was replaced or cleared; the ask died with it. */
    }
  else
    {
      guint status = soup_message_get_status (fetch->msg);
      gsize length = 0;
      const void *data = bytes != NULL ? g_bytes_get_data (bytes, &length) : NULL;

      if (status == SOUP_STATUS_OK && data != NULL && length > 0)
        lk_chart_controller_tile_respond (fetch->self->controller, fetch->id,
                                          data, length, LK_TILE_BYTES);
      else if (status == SOUP_STATUS_NOT_FOUND || status == SOUP_STATUS_NO_CONTENT ||
               status == SOUP_STATUS_OK)
        /* The publisher genuinely has no tile there — a hole in their
         * coverage, not a fault, and remembered as one. */
        lk_chart_controller_tile_respond (fetch->self->controller, fetch->id,
                                          NULL, 0, LK_TILE_NONE);
      else
        lk_chart_controller_tile_respond (fetch->self->controller, fetch->id,
                                          NULL, 0, LK_TILE_FAILED);
    }
  g_object_unref (fetch->self);
  g_object_unref (fetch->msg);
  g_free (fetch);
}

/* The C entry point: fired on the render tick — the main thread here — with
 * lookout's lock held. Look the source up, START the fetch, return; nothing
 * blocks, and no lookout call is made but tile_respond. Every ask is
 * ANSWERED — bytes, "no tile there", or "failed" — because a tile nobody
 * answers is a hole in the chart that never fills. */
static void
lk_links_tile_thunk (void *user, const char *source, uint64_t req_id,
                     int z, int x, int y)
{
  LkChartLinks *self = user;
  g_autofree char *url = NULL;

  if (self->live && self->sources != NULL && source != NULL)
    url = lk_links_tile_url (g_hash_table_lookup (self->sources, source), z, x, y);
  if (url == NULL)
    {
      if (self->live && source != NULL &&
          g_hash_table_add (self->logged, g_strconcat ("fail:", source, NULL)))
        g_warning ("alt tiles: %s - no url template; failing its tiles", source);
      lk_chart_controller_tile_respond (self->controller, req_id, NULL, 0, LK_TILE_FAILED);
      return;
    }
  if (g_hash_table_add (self->logged, g_strconcat ("ask:", source, NULL)))
    g_message ("alt tiles: %s -> %s", source, url);

  g_autoptr (SoupMessage) msg = soup_message_new (SOUP_METHOD_GET, url);
  if (msg == NULL)
    {
      lk_chart_controller_tile_respond (self->controller, req_id, NULL, 0, LK_TILE_FAILED);
      return;
    }
  soup_message_headers_append (soup_message_get_request_headers (msg),
                               "Referer", LK_LINKS_REFERER);

  LkTileFetch *fetch = g_new0 (LkTileFetch, 1);
  fetch->self = g_object_ref (self);
  fetch->msg = g_steal_pointer (&msg);
  fetch->id = req_id;
  soup_session_send_and_read_async (self->tile_session, fetch->msg, G_PRIORITY_DEFAULT,
                                    self->tile_cancel, lk_links_tile_done, fetch);
}

/* Stop answering. In-flight fetches are cancelled; the wrapper drops a late
 * answer either way. */
static void
lk_links_detach (LkChartLinks *self)
{
  self->live = FALSE;
  g_clear_pointer (&self->sources, g_hash_table_unref);
  g_hash_table_remove_all (self->logged);
  g_cancellable_cancel (self->tile_cancel);
  g_clear_object (&self->tile_cancel);
  self->tile_cancel = g_cancellable_new ();
  lk_chart_controller_set_tile_provider (self->controller, NULL, NULL);
}

/* ---- persistence --------------------------------------------------------- */

static void
lk_chart_links_save (LkChartLinks *self)
{
  JsonArray *array = json_array_new ();

  for (guint i = 0; i < self->links->len; i++)
    {
      LkChartLink *link = g_ptr_array_index (self->links, i);
      JsonObject *o = json_object_new ();
      json_object_set_string_member (o, "url", link->url);
      json_object_set_string_member (o, "name", link->name);
      if (link->doc != NULL && link->doc[0] != '\0')
        json_object_set_string_member (o, "doc", link->doc);
      json_array_add_object_element (array, o);
    }

  JsonNode *node = json_node_new (JSON_NODE_ARRAY);
  json_node_take_array (node, array);
  g_autoptr (JsonGenerator) generator = json_generator_new ();
  json_generator_set_root (generator, node);
  json_node_free (node);
  g_autofree char *json = json_generator_to_data (generator, NULL);

  lk_store_save_chart_links (self->links->len > 0 ? json : NULL);
  lk_store_save_chart_link_active (self->active);
}

static void
lk_chart_links_load (LkChartLinks *self)
{
  g_autofree char *raw = lk_store_load_chart_links ();

  if (raw != NULL)
    {
      g_autoptr (JsonParser) parser = json_parser_new ();
      JsonNode *root = NULL;
      if (json_parser_load_from_data (parser, raw, -1, NULL) &&
          (root = json_parser_get_root (parser)) != NULL && JSON_NODE_HOLDS_ARRAY (root))
        {
          JsonArray *array = json_node_get_array (root);
          for (guint i = 0; i < json_array_get_length (array); i++)
            {
              JsonNode *element = json_array_get_element (array, i);
              if (!JSON_NODE_HOLDS_OBJECT (element))
                continue;
              JsonObject *o = json_node_get_object (element);
              const char *url = lk_links_member_string (o, "url", "");
              if (url[0] == '\0')
                continue;
              LkChartLink *link = g_new0 (LkChartLink, 1);
              link->url = g_strdup (url);
              link->name = g_strdup (lk_links_member_string (o, "name", url));
              link->doc = g_strdup (lk_links_member_string (o, "doc", ""));
              g_ptr_array_add (self->links, link);
            }
        }
    }

  /* The active url only counts while its link is still on the list. */
  g_autofree char *active = lk_store_load_chart_link_active ();
  for (guint i = 0; active != NULL && i < self->links->len; i++)
    {
      LkChartLink *link = g_ptr_array_index (self->links, i);
      if (g_str_equal (link->url, active))
        {
          self->active = g_strdup (active);
          break;
        }
    }
}

/* ---- the operations, resolved on a worker -------------------------------- */

typedef struct {
  char   *link;
  char   *doc;
  guint64 epoch;
} LkLinkOp;

static void
lk_link_op_free (gpointer data)
{
  LkLinkOp *op = data;

  g_free (op->link);
  g_free (op->doc);
  g_free (op);
}

typedef struct {
  gboolean found;
  char    *url;
  char    *name;
  char    *doc;
} LkProbeResult;

static void
lk_probe_result_free (gpointer data)
{
  LkProbeResult *result = data;

  g_free (result->url);
  g_free (result->name);
  g_free (result->doc);
  g_free (result);
}

static void
lk_links_probe_thread (GTask *task, gpointer source_object, gpointer task_data,
                       GCancellable *cancellable)
{
  LkLinkOp *op = task_data;
  LkProbeResult *result = g_new0 (LkProbeResult, 1);

  /* The session's sync calls iterate the thread-default context captured at
   * its creation. This worker has none, and the GLOBAL default belongs to the
   * GTK main loop — so the worker gets a private context for the session's
   * lifetime, and never contends for the UI's. */
  GMainContext *context = g_main_context_new ();
  g_main_context_push_thread_default (context);
  {
    g_autoptr (SoupSession) session = lk_links_worker_session ();
    result->found = lk_links_probe (session, op->link,
                                    &result->url, &result->name, &result->doc);
  }
  g_main_context_pop_thread_default (context);
  g_main_context_unref (context);
  g_task_return_pointer (task, result, lk_probe_result_free);
}

typedef struct {
  gboolean    ok;
  char       *style_json;
  GHashTable *sources; /* name → LkTileSource */
  char       *attribution;
  GPtrArray  *packs; /* LkSpritePack */
} LkPushResult;

static void
lk_push_result_free (gpointer data)
{
  LkPushResult *result = data;

  g_free (result->style_json);
  g_clear_pointer (&result->sources, g_hash_table_unref);
  g_free (result->attribution);
  g_clear_pointer (&result->packs, g_ptr_array_unref);
  g_free (result);
}

static void
lk_links_push_thread (GTask *task, gpointer source_object, gpointer task_data,
                      GCancellable *cancellable)
{
  LkLinkOp *op = task_data;
  LkPushResult *result = g_new0 (LkPushResult, 1);

  result->sources = g_hash_table_new_full (g_str_hash, g_str_equal,
                                           g_free, lk_tile_source_free);
  result->packs = g_ptr_array_new_with_free_func (lk_sprite_pack_free);

  /* A private context for the sync session — see lk_links_probe_thread. */
  GMainContext *context = g_main_context_new ();
  g_main_context_push_thread_default (context);
  {
    g_autoptr (SoupSession) session = lk_links_worker_session ();

    /* A carried doc (file link, TileJSON wrapper) is the style; a style link
     * is fetched fresh on every push, which is also what keeps a publisher's
     * edits showing up. */
    g_autofree char *raw = op->doc[0] != '\0'
                               ? g_strdup (op->doc)
                               : lk_links_fetch_text (session, op->link, TRUE);
    g_autoptr (GPtrArray) pack_refs = NULL;
    /* Only a style the mariner keeps on disk may read files its sources
     * name; one off the network may not. */
    result->ok = raw != NULL &&
                 lk_links_resolve_style (session, raw, &result->style_json,
                                         result->sources, &result->attribution,
                                         &pack_refs, lk_links_is_file_link (op->link));
    /* The sprite packs ride along: fetched here, off the main thread, so
     * applying is instant. */
    if (result->ok)
      lk_links_fetch_sprite_packs (session, pack_refs, result->packs);
  }
  g_main_context_pop_thread_default (context);
  g_main_context_unref (context);
  g_task_return_pointer (task, result, lk_push_result_free);
}

/* ---- state changes, applied on the main thread --------------------------- */

static void
lk_links_set_error (LkChartLinks *self, const char *message)
{
  g_free (self->error);
  self->error = g_strdup (message != NULL ? message : "");
}

static void
lk_links_set_attribution (LkChartLinks *self, const char *credit)
{
  g_free (self->attribution);
  self->attribution = g_strdup (credit != NULL ? credit : "");
}

static void
lk_links_emit_changed (LkChartLinks *self)
{
  g_signal_emit (self, signals[SIGNAL_CHANGED], 0);
}

static void
lk_links_push_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkChartLinks *self = LK_CHART_LINKS (source_object);
  LkLinkOp *op = g_task_get_task_data (G_TASK (result));
  LkPushResult *push = g_task_propagate_pointer (G_TASK (result), NULL);

  if (push == NULL)
    return;
  if (op->epoch != self->epoch || g_strcmp0 (self->active, op->link) != 0)
    {
      lk_push_result_free (push);
      return;
    }

  if (!push->ok)
    {
      /* A lost connection must not cost the mariner the chart they are
       * sailing on: the PICK STAYS — the next open replays it — and the
       * Lookout chart stands in meanwhile. */
      lk_links_set_error (self,
                          "That chart didn't answer. Showing the Lookout chart until it does.");
      lk_links_detach (self);
      lk_chart_controller_alt_style_set (self->controller, NULL);
      lk_links_set_attribution (self, "");
      lk_links_emit_changed (self);
      lk_push_result_free (push);
      return;
    }

  lk_links_set_error (self, "");
  lk_links_set_attribution (self, push->attribution);

  g_clear_pointer (&self->sources, g_hash_table_unref);
  self->sources = g_steal_pointer (&push->sources);
  g_hash_table_remove_all (self->logged);
  self->live = TRUE;

  lk_chart_controller_set_tile_provider (self->controller, lk_links_tile_thunk, self);
  if (!lk_chart_controller_alt_style_set (self->controller, push->style_json))
    {
      g_warning ("alt chart style refused");
    }
  else
    {
      /* AFTER the style: setting one clears the previous style's packs, so
       * this order is what makes the icons stick. */
      for (guint i = 0; i < push->packs->len; i++)
        {
          LkSpritePack *pack = g_ptr_array_index (push->packs, i);
          gsize json_len = 0, png_len = 0;
          const char *json = g_bytes_get_data (pack->json, &json_len);
          const char *png = g_bytes_get_data (pack->png, &png_len);
          int cells = lk_chart_controller_alt_sprite_pack (self->controller, pack->prefix,
                                                           json, json_len, png, png_len);
          g_message ("sprite pack '%s': %d cells", pack->prefix, cells);
        }
    }
  lk_links_emit_changed (self);
  lk_push_result_free (push);
}

/* Draw whatever is picked now. */
static void
lk_chart_links_push (LkChartLinks *self)
{
  guint64 epoch = ++self->epoch;

  if (self->active == NULL)
    {
      lk_links_detach (self);
      lk_chart_controller_alt_style_set (self->controller, NULL);
      lk_links_set_attribution (self, "");
      lk_links_emit_changed (self);
      return;
    }

  LkLinkOp *op = g_new0 (LkLinkOp, 1);
  op->link = g_strdup (self->active);
  op->doc = g_strdup ("");
  op->epoch = epoch;
  for (guint i = 0; i < self->links->len; i++)
    {
      LkChartLink *link = g_ptr_array_index (self->links, i);
      if (g_str_equal (link->url, self->active) && link->doc != NULL)
        {
          g_free (op->doc);
          op->doc = g_strdup (link->doc);
        }
    }

  GTask *task = g_task_new (self, NULL, lk_links_push_done, NULL);
  g_task_set_task_data (task, op, lk_link_op_free);
  g_task_run_in_thread (task, lk_links_push_thread);
  g_object_unref (task);
}

static void
lk_links_add_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkChartLinks *self = LK_CHART_LINKS (source_object);
  LkLinkOp *op = g_task_get_task_data (G_TASK (result));
  LkProbeResult *probe = g_task_propagate_pointer (G_TASK (result), NULL);

  if (probe == NULL)
    return;
  if (!probe->found)
    {
      lk_links_set_error (self, "No chart style or tile source at that link.");
      lk_links_emit_changed (self);
      lk_probe_result_free (probe);
      return;
    }

  gboolean have = FALSE;
  for (guint i = 0; i < self->links->len; i++)
    {
      LkChartLink *link = g_ptr_array_index (self->links, i);
      have = have || g_str_equal (link->url, probe->url);
    }
  if (!have)
    {
      LkChartLink *link = g_new0 (LkChartLink, 1);
      link->url = g_strdup (probe->url);
      link->name = g_strdup (probe->name);
      link->doc = g_strdup (probe->doc);
      g_ptr_array_add (self->links, link);
    }
  if (op->epoch == self->epoch)
    {
      /* Adding it was the request to sail on it. */
      lk_chart_links_select (self, probe->url);
    }
  else
    {
      /* The mariner picked something else while this probe was out: the
       * chart goes on the list, and the pick they made stands. */
      lk_chart_links_save (self);
      lk_links_emit_changed (self);
    }
  lk_probe_result_free (probe);
}

static void
lk_links_refresh_done (GObject *source_object, GAsyncResult *result, gpointer user_data)
{
  LkChartLinks *self = LK_CHART_LINKS (source_object);
  LkLinkOp *op = g_task_get_task_data (G_TASK (result));
  LkProbeResult *probe = g_task_propagate_pointer (G_TASK (result), NULL);

  if (probe == NULL)
    return;
  if (!probe->found)
    {
      lk_links_set_error (self, "That link didn't answer. The chart is unchanged.");
      lk_links_emit_changed (self);
      lk_probe_result_free (probe);
      return;
    }

  for (guint i = 0; i < self->links->len; i++)
    {
      LkChartLink *link = g_ptr_array_index (self->links, i);
      if (!g_str_equal (link->url, op->link))
        continue;
      g_free (link->url);
      g_free (link->name);
      g_free (link->doc);
      link->url = g_strdup (probe->url);
      link->name = g_strdup (probe->name);
      link->doc = g_strdup (probe->doc);
    }
  /* A refresh can resolve to the sibling style.json another entry already
   * carries. One url is one chart: the first copy absorbs the refreshed
   * document rather than a twin appearing. */
  {
    guint first = G_MAXUINT;
    for (guint i = 0; i < self->links->len; )
      {
        LkChartLink *link = g_ptr_array_index (self->links, i);
        if (!g_str_equal (link->url, probe->url))
          {
            i++;
            continue;
          }
        if (first == G_MAXUINT)
          {
            first = i++;
            continue;
          }
        LkChartLink *keep = g_ptr_array_index (self->links, first);
        g_free (keep->name);
        g_free (keep->doc);
        keep->name = g_strdup (link->name);
        keep->doc = g_strdup (link->doc);
        g_ptr_array_remove_index (self->links, i);
      }
  }
  if (g_strcmp0 (self->active, op->link) == 0)
    {
      /* Re-picking pushes the rebuilt document and persists both. */
      lk_chart_links_select (self, probe->url);
    }
  else
    {
      lk_chart_links_save (self);
      lk_links_emit_changed (self);
    }
  lk_probe_result_free (probe);
}

static void
lk_links_run_probe (LkChartLinks *self, const char *link, GAsyncReadyCallback done)
{
  LkLinkOp *op = g_new0 (LkLinkOp, 1);

  op->link = g_strdup (link);
  op->doc = g_strdup ("");
  /* What the pick looked like when the probe left: a slow add landing after
   * the mariner picked something else must not steal the chart back. */
  op->epoch = self->epoch;

  GTask *task = g_task_new (self, NULL, done, NULL);
  g_task_set_task_data (task, op, lk_link_op_free);
  g_task_run_in_thread (task, lk_links_probe_thread);
  g_object_unref (task);
}

/* ---- public -------------------------------------------------------------- */

void
lk_chart_links_add (LkChartLinks *self, const char *link)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));
  g_return_if_fail (link != NULL);

  g_autofree char *trimmed = g_strdup (link);
  g_strstrip (trimmed);
  if (trimmed[0] == '\0')
    return;
  for (guint i = 0; i < self->links->len; i++)
    {
      LkChartLink *known = g_ptr_array_index (self->links, i);
      if (g_str_equal (known->url, trimmed))
        {
          lk_chart_links_select (self, trimmed);
          return;
        }
    }
  lk_links_set_error (self, "");
  lk_links_run_probe (self, trimmed, lk_links_add_done);
}

void
lk_chart_links_remove (LkChartLinks *self, const char *url)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));
  g_return_if_fail (url != NULL);

  for (guint i = 0; i < self->links->len; i++)
    {
      LkChartLink *link = g_ptr_array_index (self->links, i);
      if (g_str_equal (link->url, url))
        {
          g_ptr_array_remove_index (self->links, i);
          break;
        }
    }
  if (g_strcmp0 (self->active, url) == 0)
    g_clear_pointer (&self->active, g_free);
  lk_chart_links_save (self);
  lk_chart_links_push (self);
  lk_links_emit_changed (self);
}

void
lk_chart_links_refresh (LkChartLinks *self, const char *url)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));
  g_return_if_fail (url != NULL);

  gboolean known = FALSE;
  for (guint i = 0; i < self->links->len; i++)
    {
      LkChartLink *link = g_ptr_array_index (self->links, i);
      known = known || g_str_equal (link->url, url);
    }
  if (!known)
    return;
  lk_links_set_error (self, "");
  lk_links_run_probe (self, url, lk_links_refresh_done);
}

void
lk_chart_links_select (LkChartLinks *self, const char *url)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));

  g_free (self->active);
  self->active = url != NULL && url[0] != '\0' ? g_strdup (url) : NULL;
  lk_chart_links_save (self);
  lk_chart_links_push (self);
  lk_links_emit_changed (self);
}

void
lk_chart_links_reapply (LkChartLinks *self)
{
  g_return_if_fail (LK_IS_CHART_LINKS (self));

  /* The handle this replays into is NEW, and it numbers tile requests from 1
   * exactly as the old one did: a fetch started for the old handle and
   * landing late would answer one of the new handle's ids with the old
   * style's bytes. The new handle has asked for nothing yet — the open runs
   * whole on this thread before any render tick — so cancelling here closes
   * the race completely. */
  g_cancellable_cancel (self->tile_cancel);
  g_clear_object (&self->tile_cancel);
  self->tile_cancel = g_cancellable_new ();

  if (self->active != NULL)
    lk_chart_links_push (self);
}

GPtrArray *
lk_chart_links_list (LkChartLinks *self)
{
  g_return_val_if_fail (LK_IS_CHART_LINKS (self), NULL);
  return self->links;
}

const char *
lk_chart_links_active (LkChartLinks *self)
{
  g_return_val_if_fail (LK_IS_CHART_LINKS (self), NULL);
  return self->active;
}

const char *
lk_chart_links_attribution (LkChartLinks *self)
{
  g_return_val_if_fail (LK_IS_CHART_LINKS (self), "");
  return self->attribution;
}

const char *
lk_chart_links_error (LkChartLinks *self)
{
  g_return_val_if_fail (LK_IS_CHART_LINKS (self), "");
  return self->error;
}

/* ---- GObject ------------------------------------------------------------- */

static void
lk_chart_links_dispose (GObject *object)
{
  LkChartLinks *self = LK_CHART_LINKS (object);

  self->live = FALSE;
  if (self->tile_cancel != NULL)
    g_cancellable_cancel (self->tile_cancel);
  g_clear_object (&self->tile_cancel);
  if (self->tile_session != NULL)
    soup_session_abort (self->tile_session);
  g_clear_object (&self->tile_session);
  if (self->controller != NULL)
    lk_chart_controller_set_tile_provider (self->controller, NULL, NULL);
  g_clear_object (&self->controller);
  g_clear_pointer (&self->sources, g_hash_table_unref);
  g_clear_pointer (&self->logged, g_hash_table_unref);
  g_clear_pointer (&self->links, g_ptr_array_unref);
  g_clear_pointer (&self->active, g_free);
  g_clear_pointer (&self->attribution, g_free);
  g_clear_pointer (&self->error, g_free);

  G_OBJECT_CLASS (lk_chart_links_parent_class)->dispose (object);
}

static void
lk_chart_links_class_init (LkChartLinksClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->dispose = lk_chart_links_dispose;

  /* The list, the pick, the credit or the error moved. One signal: the
   * settings section and the HUD credit are each rebuilt as a whole. */
  signals[SIGNAL_CHANGED] =
      g_signal_new ("changed", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_FIRST,
                    0, NULL, NULL, NULL, G_TYPE_NONE, 0);
}

static void
lk_chart_links_init (LkChartLinks *self)
{
  self->links = g_ptr_array_new_with_free_func (lk_chart_link_free);
  self->attribution = g_strdup ("");
  self->error = g_strdup ("");
  self->logged = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  self->tile_cancel = g_cancellable_new ();
  /* Tiles arrive in bursts of dozens; the per-host cap keeps the burst inside
   * the connection budget a public tile host expects from one client. */
  self->tile_session = soup_session_new_with_options ("user-agent", LK_LINKS_USER_AGENT,
                                                      "timeout", 20,
                                                      "idle-timeout", 10,
                                                      "max-conns", 8,
                                                      "max-conns-per-host", 4,
                                                      NULL);
}

LkChartLinks *
lk_chart_links_new (LkChartController *controller)
{
  g_return_val_if_fail (LK_IS_CHART_CONTROLLER (controller), NULL);

  LkChartLinks *self = g_object_new (LK_TYPE_CHART_LINKS, NULL);
  self->controller = g_object_ref (controller);
  lk_chart_links_load (self);
  return self;
}
