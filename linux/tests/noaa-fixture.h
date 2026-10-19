/* noaa-fixture.h: a NOAA catalog in the cache and a fetcher with no network.
 *
 * The core reads a cached catalog on the first catalog read, so a test has a
 * catalog with no network. The fake fetcher counts requests and cancels, keeps
 * the id of the last request, and sends no response.
 */
#pragma once

#include <glib/gstdio.h>
#include <lookout.h>

/* A catalog of one cell in district 5, as NOAA publishes it. */
static const char lk_fixture_catalog[] =
    "<ENC_Product_Catalog><date_valid>20250903</date_valid>"
    "<cell><name>US5MD1MC</name><lname>Chesapeake Bay Entrance</lname>"
    "<cscale>20000</cscale><edtn>27</edtn><updn>3</updn><isdt>20250801</isdt>"
    "<zipfile_location>https://charts.noaa.gov/ENCs/US5MD1MC.zip</zipfile_location>"
    "<zipfile_size>1048576</zipfile_size><coast_guard_district>5</coast_guard_district>"
    "<panel><vertex><lat>36.0</lat><long>-76.5</long></vertex>"
    "<vertex><lat>37.0</lat><long>-75.5</long></vertex></panel></cell>"
    "</ENC_Product_Catalog>";

/* Where the core caches the catalog under $XDG_CACHE_HOME. Free with g_free. */
static inline char *
lk_fixture_catalog_path (void)
{
  return g_build_filename (g_getenv ("XDG_CACHE_HOME"), "lookout", "fetched",
                           "ENCProdCat.xml", NULL);
}

/* Write the catalog to the cache. Remove it with g_remove when done. */
static inline void
lk_fixture_cache_catalog (void)
{
  g_autofree char *path = lk_fixture_catalog_path ();
  g_autofree char *dir = g_path_get_dirname (path);

  g_assert_cmpint (g_mkdir_with_parents (dir, 0700), ==, 0);
  g_assert_true (g_file_set_contents (path, lk_fixture_catalog, -1, NULL));
}

typedef struct {
  guint    gets;
  guint    cancels;
  uint64_t last;
} LkFakeFetch;

static inline void
lk_fake_get (void *user, uint64_t req_id, const char *url, int allow_file)
{
  LkFakeFetch *fake = user;

  fake->gets++;
  fake->last = req_id;
}

static inline void
lk_fake_cancel (void *user, uint64_t req_id)
{
  ((LkFakeFetch *) user)->cancels++;
}
