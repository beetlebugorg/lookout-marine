/* ui/charts/coastline.c — see ui/charts/coastline.h. */
#include "ui/charts/coastline.h"

#include "lk-resources.h"

#include <math.h>
#include <string.h>

#define LK_COASTLINE_RESOURCE "/org/beetlebug/LookoutMarine/firstrun/coastline.bin"

/* The file: a ring count, then per ring a level byte, a point count, and the
 * points as pairs of little-endian floats.
 *
 * The points are copied out rather than pointed at. A ring's floats start at
 * an odd offset in the file, and reading a float through a cast to an
 * unaligned address is not something to rely on. */

typedef struct {
  LkCoastRing *rings;
  guint        n;
  float       *points; /* every ring's points, one block */
} LkCoastline;

static LkCoastline *coastline;

static gboolean
lk_read_u32 (GBytes *bytes, gsize *at, guint32 *out)
{
  gsize size = 0;
  const guint8 *data = g_bytes_get_data (bytes, &size);
  guint32 raw;

  if (*at + 4 > size)
    return FALSE;
  memcpy (&raw, data + *at, 4);
  *at += 4;
  *out = GUINT32_FROM_LE (raw);
  return TRUE;
}

static gboolean
lk_read_u8 (GBytes *bytes, gsize *at, guint8 *out)
{
  gsize size = 0;
  const guint8 *data = g_bytes_get_data (bytes, &size);

  if (*at + 1 > size)
    return FALSE;
  *out = data[*at];
  *at += 1;
  return TRUE;
}

static gboolean
lk_read_f32 (GBytes *bytes, gsize *at, float *out)
{
  guint32 raw;

  if (!lk_read_u32 (bytes, at, &raw))
    return FALSE;
  /* The bits are the float's. A union, not a pointer cast: the value has
   * already been brought into a local. */
  union { guint32 u; float f; } bits = { .u = raw };
  *out = bits.f;
  return TRUE;
}

static void
lk_coastline_load (void)
{
  g_autoptr (GError) error = NULL;
  g_autoptr (GBytes) bytes = NULL;
  LkCoastline *loaded;
  guint32 count = 0;
  gsize at = 0;

  coastline = g_new0 (LkCoastline, 1);

  bytes = g_resources_lookup_data (LK_COASTLINE_RESOURCE, G_RESOURCE_LOOKUP_FLAGS_NONE,
                                   &error);
  if (bytes == NULL)
    {
      /* Nothing registered the resources. The app does it at startup, for the
       * icon theme's sake; a test binary is a host of its own and has no
       * reason to know that. Register them and ask again. */
      g_clear_error (&error);
      lk_register_resource ();
      bytes = g_resources_lookup_data (LK_COASTLINE_RESOURCE,
                                       G_RESOURCE_LOOKUP_FLAGS_NONE, &error);
    }
  if (bytes == NULL)
    {
      g_warning ("coverage map: no coastline (%s)", error->message);
      return;
    }

  if (!lk_read_u32 (bytes, &at, &count) || count == 0)
    {
      g_warning ("coverage map: the coastline states no rings");
      return;
    }

  loaded = coastline;
  loaded->rings = g_new0 (LkCoastRing, count);
  /* One block for every ring's points. The file's own length caps it, so a
   * truncated file cannot ask for more than it holds. */
  loaded->points = g_new0 (float, g_bytes_get_size (bytes) / sizeof (float) + 2);

  gsize used = 0;
  for (guint32 i = 0; i < count; i++)
    {
      guint8 level = 0;
      guint32 n = 0;

      if (!lk_read_u8 (bytes, &at, &level) || !lk_read_u32 (bytes, &at, &n) || n == 0)
        break;

      float *points = loaded->points + used;
      double west = 180, east = -180, south = 90, north = -90;
      gboolean ok = TRUE;

      for (guint32 p = 0; p < n; p++)
        {
          float lon = 0, lat = 0;

          if (!lk_read_f32 (bytes, &at, &lon) || !lk_read_f32 (bytes, &at, &lat))
            {
              ok = FALSE;
              break;
            }
          points[p * 2] = lon;
          points[p * 2 + 1] = lat;
          west = MIN (west, lon);
          east = MAX (east, lon);
          south = MIN (south, lat);
          north = MAX (north, lat);
        }
      if (!ok)
        break;

      used += (gsize) n * 2;

      /* A ring that crosses the antimeridian draws as a band across the whole
       * panel, so it is left out. There are three of them, all Aleutian. */
      if (east - west > 180)
        continue;

      loaded->rings[loaded->n++] = (LkCoastRing) {
        .level = level,
        .n = n,
        .points = points,
        .west = west,
        .south = south,
        .east = east,
        .north = north,
      };
    }

  if (loaded->n == 0)
    g_warning ("coverage map: the coastline holds no rings this picker can draw");
}

const LkCoastRing *
lk_coastline_rings (guint *out_n)
{
  static gsize once = 0;

  if (g_once_init_enter (&once))
    {
      lk_coastline_load ();
      g_once_init_leave (&once, 1);
    }

  if (out_n != NULL)
    *out_n = coastline->n;
  return coastline->n > 0 ? coastline->rings : NULL;
}

/* ---- the projection ------------------------------------------------------ */

double
lk_mercator_y (double lat)
{
  double phi = CLAMP (lat, -85.05, 85.05) * G_PI / 180.0;

  return log (tan (G_PI / 4.0 + phi / 2.0));
}

double
lk_map_window_aspect (const LkMapWindow *window)
{
  double height;

  g_return_val_if_fail (window != NULL, 1.0);

  height = lk_mercator_y (window->north) - lk_mercator_y (window->south);
  if (height <= 0)
    return 1.0;
  return (window->east - window->west) * G_PI / 180.0 / height;
}

void
lk_map_window_point (const LkMapWindow *window, double lon, double lat,
                     double width, double height, double *out_x, double *out_y)
{
  double top, bottom, span, lon_span;

  g_return_if_fail (window != NULL);

  lon_span = window->east - window->west;
  top = lk_mercator_y (window->north);
  bottom = lk_mercator_y (window->south);
  span = top - bottom;

  if (out_x != NULL)
    *out_x = lon_span == 0 ? 0 : (lon - window->west) / lon_span * width;
  if (out_y != NULL)
    *out_y = span == 0 ? 0 : (top - lk_mercator_y (lat)) / span * height;
}

gboolean
lk_map_window_intersects (const LkMapWindow *window,
                          double west, double east, double south, double north)
{
  g_return_val_if_fail (window != NULL, FALSE);

  return east >= window->west && west <= window->east &&
         north >= window->south && south <= window->north;
}
