// Model code: no WinRT, so the parse and the projection are reachable from a
// test.
#include "lk_coastline.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>

namespace lkw
{
    namespace
    {
        // Little-endian readers over a buffer, each reporting whether it fit.
        struct Reader
        {
            uint8_t const *p{ nullptr };
            size_t         len{ 0 };
            size_t         at{ 0 };

            bool U8(uint8_t *out)
            {
                if (at + 1 > len)
                    return false;
                *out = p[at];
                at += 1;
                return true;
            }
            bool U32(uint32_t *out)
            {
                if (at + 4 > len)
                    return false;
                *out = (uint32_t)p[at] | ((uint32_t)p[at + 1] << 8) |
                       ((uint32_t)p[at + 2] << 16) | ((uint32_t)p[at + 3] << 24);
                at += 4;
                return true;
            }
            bool F32(float *out)
            {
                uint32_t bits = 0;
                if (!U32(&bits))
                    return false;
                std::memcpy(out, &bits, sizeof bits);
                return true;
            }
        };
    }

    std::vector<CoastRing> ParseCoastline(uint8_t const *bytes, size_t len)
    {
        std::vector<CoastRing> out;
        if (bytes == nullptr)
            return out;

        Reader r{ bytes, len, 0 };
        uint32_t rings = 0;
        if (!r.U32(&rings))
            return out;

        out.reserve(rings);
        for (uint32_t i = 0; i < rings; ++i)
        {
            CoastRing ring;
            uint32_t  n = 0;
            if (!r.U8(&ring.level) || !r.U32(&n))
                break;

            // A count larger than the bytes left is a corrupt or truncated
            // file. Stop rather than reserving on its word.
            if ((size_t)n * 8 > r.len - r.at)
                break;

            ring.points.reserve(n);
            bool ok = true;
            for (uint32_t j = 0; j < n; ++j)
            {
                CoastPoint pt;
                if (!r.F32(&pt.lon) || !r.F32(&pt.lat))
                {
                    ok = false;
                    break;
                }
                ring.points.push_back(pt);
            }
            if (!ok)
                break;
            out.push_back(std::move(ring));
        }
        return out;
    }

    std::vector<CoastRing> LoadCoastline(std::string const &path)
    {
        std::ifstream in(path, std::ios::binary);
        if (!in)
            return {};
        std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)),
                                   std::istreambuf_iterator<char>());
        return ParseCoastline(bytes.data(), bytes.size());
    }

    double MapWindow::Mercator(double lat)
    {
        double const phi = std::max(-85.05, std::min(85.05, lat)) * 3.14159265358979323846 / 180.0;
        return std::log(std::tan(3.14159265358979323846 / 4.0 + phi / 2.0));
    }

    double MapWindow::Aspect() const
    {
        double const h = Mercator(north) - Mercator(south);
        if (h <= 0)
            return 1.0;
        return LonSpan() * 3.14159265358979323846 / 180.0 / h;
    }

    void MapWindow::Point(double lon, double lat, double w, double h, double *out_x,
                          double *out_y) const
    {
        double const top    = Mercator(north);
        double const bottom = Mercator(south);
        double const span   = top - bottom;
        double const dy     = span == 0 ? 0 : (top - Mercator(lat)) / span;
        double const dx     = LonSpan() == 0 ? 0 : (lon - west) / LonSpan();
        if (out_x != nullptr)
            *out_x = dx * w;
        if (out_y != nullptr)
            *out_y = dy * h;
    }
}
