/* ui/charts/coastline.h — the coastline the coverage picker draws, and the
 * projection it draws through.
 *
 * Baked from vendor/gshhg/coastline.geojson.gz, the same GSHHG data the
 * engine's own basemap is baked from, clipped to the waters the picker shows
 * and simplified to 0.02 degrees. data/firstrun/coastline.bin holds it and the
 * binary carries it as a resource.
 *
 * The picker DRAWS this rather than photographing the chart. A picture of the
 * chart has to be taken at a view the camera has visited, because tiles load
 * on the frame loop, and it then needs the projection it was taken under
 * carried beside it. This is a static table and a projection the picker owns,
 * so a panel draws the same on the first frame every time.
 */
#pragma once

#include <gio/gio.h>

G_BEGIN_DECLS

/* One closed ring. GSHHG winds land and lakes opposite ways, so a lake is its
 * own polygon rather than a hole and draws OVER the land. */
typedef struct {
  guint8       level;  /* 1 land, 2 lake */
  guint        n;      /* how many points */
  const float *points; /* 2 * n floats, longitude then latitude */
  /* The ring's own extent, in degrees, worked out once at load. A panel skips
   * a ring that does not reach into it, and there are 1,538 of them. */
  double west, south, east, north;
} LkCoastRing;

/* Every ring, borrowed and static for the life of the process. Read once, on
 * the first call. Answers NULL and warns once when the resource will not
 * parse, which leaves the picker drawing water and its regions.
 *
 * A ring whose own longitude extent spans more than 180 degrees crosses the
 * antimeridian, such as an Aleutian island with points at +172 and -179. Drawn
 * through a linear projection it spans the whole width of a panel as a band, so
 * those rings are left out of this table. */
const LkCoastRing *lk_coastline_rings (guint *out_n);

/* A longitude and latitude window, and the flat rectangle it draws into.
 *
 * Mercator, the projection the chart draws, so a coastline here has the shape
 * a mariner sees on the chart.
 *
 * Longitude maps straight through. Wrapping it puts every point west of the
 * window far to the east, which draws a ring that leaves the frame as a band
 * across the whole map. */
typedef struct {
  double west, east, south, north;
} LkMapWindow;

/* Width over height for this window, so a panel is never stretched. */
double lk_map_window_aspect (const LkMapWindow *window);

/* Where a longitude and latitude fall inside a `width` by `height` panel. */
void lk_map_window_point (const LkMapWindow *window, double lon, double lat,
                          double width, double height, double *out_x, double *out_y);

/* TRUE when any part of this box reaches into the window. */
gboolean lk_map_window_intersects (const LkMapWindow *window,
                                   double west, double east,
                                   double south, double north);

/* Mercator y, clamped clear of the poles. */
double lk_mercator_y (double lat);

G_END_DECLS
