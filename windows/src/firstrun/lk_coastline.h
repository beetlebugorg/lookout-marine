// The coastline the coverage picker draws, and the projection it draws under.
//
// Baked from vendor/gshhg/coastline.geojson.gz, the same GSHHG data the
// engine's basemap comes from, clipped to the waters the picker shows and
// simplified to 0.02 degrees. `coastline.bin` holds it, byte for byte the same
// file Apple, Android and Linux each carry.
//
// The picker draws this rather than photographing the chart. A picture of the
// chart has to be taken at a view the camera has visited, because tiles load on
// the frame loop, and it then needs the projection it was taken under carried
// alongside it. A static array and a projection the picker owns draw the same
// on the first frame every time.
//
// Model only: no WinRT and no XAML, so windows/test/test_coastline.cpp covers
// the parse and the projection.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace lkw
{
    struct CoastPoint
    {
        float lon{ 0 };
        float lat{ 0 };
    };

    // One ring. GSHHG level 1 is land and 2 is a lake. A lake is its own
    // polygon rather than a hole in the land, so it draws over the land and
    // fill order matters.
    struct CoastRing
    {
        uint8_t                 level{ 0 };
        std::vector<CoastPoint> points;
    };

    // The wire format, little-endian throughout:
    //
    //   u32   ring count
    //   per ring:
    //     u8    GSHHG level
    //     u32   point count
    //     f32 pairs, lon then lat
    //
    // Returns what it could read. A truncated file gives the rings before the
    // cut rather than nothing, and a file that is missing or too short gives an
    // empty list, which the picker draws as an empty sea.
    std::vector<CoastRing> LoadCoastline(std::string const &path);

    // Same, from bytes already in hand. The test uses this.
    std::vector<CoastRing> ParseCoastline(uint8_t const *bytes, size_t len);

    // A lon/lat window and the flat rectangle it draws into.
    //
    // Mercator, the projection the chart draws, so a coastline here has the
    // shape a mariner sees on the chart.
    //
    // Longitude maps straight through. Wrapping it put every point west of the
    // window far to the east, which drew a ring leaving the frame as a band
    // across the whole map.
    struct MapWindow
    {
        double west{ 0 }, east{ 0 }, south{ 0 }, north{ 0 };

        double LonSpan() const { return east - west; }

        // Mercator y, clamped clear of the poles.
        static double Mercator(double lat);

        // Width over height for this window.
        double Aspect() const;

        // Where a position falls in a rectangle of `w` by `h`, with y down.
        void Point(double lon, double lat, double w, double h, double *out_x,
                   double *out_y) const;

        // True when any part of this box reaches into the window.
        bool Intersects(double w, double e, double s, double n) const
        {
            return e >= west && w <= east && n >= south && s <= north;
        }
    };
}
