/* ui/charts/catalog.c — see ui/charts/catalog.h. */
#include "ui/charts/catalog.h"

#include "lk-resources.h"

#define LK_FIRSTRUN_RESOURCE "/org/beetlebug/LookoutMarine/firstrun/"

static const LkChartCatalogEntry lk_catalog[] = {
  { "Open Waters Seascape", "https://tiles.openwaters.io/seascape/style.json",
    LK_FIRSTRUN_RESOURCE "seascape-preview.png" },
  { "Open Waters Seamap", "https://tiles.openwaters.io/seamap/style.json",
    LK_FIRSTRUN_RESOURCE "seamap-preview.png" },
};

const LkChartCatalogEntry *
lk_chart_catalog_entries (guint *out_n)
{
  if (out_n != NULL)
    *out_n = G_N_ELEMENTS (lk_catalog);
  return lk_catalog;
}

const LkChartCatalogEntry *
lk_chart_catalog_entry (const char *url)
{
  if (url == NULL)
    return NULL;
  for (gsize i = 0; i < G_N_ELEMENTS (lk_catalog); i++)
    if (g_strcmp0 (lk_catalog[i].url, url) == 0)
      return &lk_catalog[i];
  return NULL;
}

/* ---- the pictures -------------------------------------------------------- */

/* Decoded once each, and kept. A shelf redraws whenever the list moves, and a
 * chart photograph is three quarters of a megabyte to decode. */
static GHashTable *lk_art_cache;

static GdkTexture *
lk_texture_from_resource (const char *path)
{
  g_autoptr (GError) error = NULL;
  g_autoptr (GBytes) bytes = NULL;
  GdkTexture *texture;

  if (lk_art_cache == NULL)
    lk_art_cache = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_object_unref);

  if (g_hash_table_lookup_extended (lk_art_cache, path, NULL, (gpointer *) &texture))
    return texture;

  bytes = g_resources_lookup_data (path, G_RESOURCE_LOOKUP_FLAGS_NONE, &error);
  if (bytes == NULL)
    {
      /* Nothing registered the resources. The app does it at startup; a test
       * binary is a host of its own and has no reason to know that. */
      g_clear_error (&error);
      lk_register_resource ();
      bytes = g_resources_lookup_data (path, G_RESOURCE_LOOKUP_FLAGS_NONE, &error);
    }

  texture = bytes == NULL ? NULL : gdk_texture_new_from_bytes (bytes, &error);
  if (texture == NULL)
    g_warning ("chart picture: %s (%s)", path, error->message);

  /* A failure is cached too. A picture that will not decode will not decode
   * on the next redraw either, and the warning belongs in the log once. */
  g_hash_table_insert (lk_art_cache, g_strdup (path), texture);
  return texture;
}

GdkTexture *
lk_chart_catalog_art (const char *url)
{
  const LkChartCatalogEntry *entry = lk_chart_catalog_entry (url);

  return entry == NULL ? NULL : lk_texture_from_resource (entry->art);
}

GdkTexture *
lk_chart_welcome_picture (void)
{
  return lk_texture_from_resource (LK_FIRSTRUN_RESOURCE "welcome-chart.png");
}
