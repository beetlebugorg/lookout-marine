/* The coastline the coverage picker draws.
 *
 * Two things earn tests here. The PARSE, because the file is a fixed wire
 * format shared byte for byte with three other shells, and a reader that
 * disagrees with it draws a wrong coast rather than failing. And the
 * PROJECTION, because Mercator is what makes the drawn coast the shape a
 * mariner sees on the chart.
 *
 * The real coastline.bin is also read, so a change to the file or to the reader
 * that stops them agreeing shows up here rather than on screen.
 */
#include "lk_test.h"

#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "lk_coastline.h"

using namespace lktest;
using namespace lkw;

namespace
{
    /* Build a buffer in the wire format: u32 rings, then per ring u8 level,
     * u32 points, and that many f32 lon/lat pairs, all little-endian. */
    struct Writer
    {
        std::vector<uint8_t> bytes;

        void U8(uint8_t v) { bytes.push_back(v); }
        void U32(uint32_t v)
        {
            bytes.push_back((uint8_t)(v & 0xFF));
            bytes.push_back((uint8_t)((v >> 8) & 0xFF));
            bytes.push_back((uint8_t)((v >> 16) & 0xFF));
            bytes.push_back((uint8_t)((v >> 24) & 0xFF));
        }
        void F32(float v)
        {
            uint32_t bits = 0;
            std::memcpy(&bits, &v, sizeof bits);
            U32(bits);
        }
    };

    /* Where the build puts coastline.bin, and where the source copy lives.
     *
     * From the test executable rather than the working directory. The runner
     * starts this from the repo root and the candidates below read from
     * there, so a run started in windows\test found no file and the whole
     * suite passed on an empty read. */
    std::string CoastlinePath()
    {
        std::vector<std::filesystem::path> roots{ std::filesystem::current_path() };
        {
            wchar_t self[MAX_PATH]{};
            if (GetModuleFileNameW(nullptr, self, MAX_PATH) != 0)
            {
                std::filesystem::path dir = std::filesystem::path(self).parent_path();
                for (int up = 0; up < 5 && !dir.empty(); ++up)
                {
                    roots.push_back(dir);
                    dir = dir.parent_path();
                }
            }
        }
        char const *candidates[] = {
            "windows/data/firstrun/coastline.bin",
            "../windows/data/firstrun/coastline.bin",
            "data/firstrun/coastline.bin",
        };
        for (auto const &root : roots)
            for (auto const *c : candidates)
            {
                std::error_code ec;
                std::filesystem::path p = root / c;
                if (std::filesystem::exists(p, ec))
                    return p.string();
            }
        return "";
    }
}

void TestCoastline()
{
    Suite("lk_coastline: the wire format");
    {
        Writer w;
        w.U32(2);              /* two rings */
        w.U8(1);               /* land */
        w.U32(3);
        w.F32(-76.5f); w.F32(38.9f);
        w.F32(-76.4f); w.F32(38.9f);
        w.F32(-76.4f); w.F32(39.0f);
        w.U8(2);               /* a lake */
        w.U32(1);
        w.F32(-76.45f); w.F32(38.95f);

        auto rings = ParseCoastline(w.bytes.data(), w.bytes.size());

        Case("both rings, in file order");
        LK_EQ(rings.size(), size_t{ 2 });

        Case("the level comes through, land then lake");
        LK_EQ((int)rings[0].level, 1);
        LK_EQ((int)rings[1].level, 2);

        Case("the points come through, lon first then lat");
        LK_EQ(rings[0].points.size(), size_t{ 3 });
        LK_NEAR(rings[0].points[0].lon, -76.5, 1e-4);
        LK_NEAR(rings[0].points[0].lat, 38.9, 1e-4);
        LK_NEAR(rings[0].points[2].lat, 39.0, 1e-4);
        LK_EQ(rings[1].points.size(), size_t{ 1 });

        /* A file cut mid-ring gives what came before the cut. The picker draws
         * a short coast rather than none. */
        Case("a truncated file keeps the rings before the cut");
        auto cut = ParseCoastline(w.bytes.data(), w.bytes.size() - 6);
        LK_EQ(cut.size(), size_t{ 1 });

        Case("a header on its own gives no rings");
        Writer h;
        h.U32(5);
        LK_EQ(ParseCoastline(h.bytes.data(), h.bytes.size()).size(), size_t{ 0 });

        Case("an empty buffer gives no rings");
        LK_EQ(ParseCoastline(nullptr, 0).size(), size_t{ 0 });
        uint8_t nothing = 0;
        LK_EQ(ParseCoastline(&nothing, 0).size(), size_t{ 0 });

        /* A count larger than the bytes left would reserve on a corrupt file's
         * word. */
        Case("a point count past the end of the buffer is refused");
        Writer big;
        big.U32(1);
        big.U8(1);
        big.U32(1000000);
        big.F32(1.0f); big.F32(2.0f);
        LK_EQ(ParseCoastline(big.bytes.data(), big.bytes.size()).size(), size_t{ 0 });
    }

    Suite("lk_coastline: the real file");
    {
        std::string const path = CoastlinePath();
        Case("coastline.bin is where the build expects it");
        LK_EQ(path.empty(), false);
        if (path.empty())
            return;

        auto rings = LoadCoastline(path);

        Case("it reads as rings");
        LK_EQ(rings.size() > 0, true);

        Case("every ring has points and a GSHHG level of land or lake");
        bool levels_ok = true, points_ok = true;
        size_t total = 0;
        for (auto const &r : rings)
        {
            levels_ok = levels_ok && (r.level == 1 || r.level == 2);
            points_ok = points_ok && !r.points.empty();
            total += r.points.size();
        }
        LK_EQ(levels_ok, true);
        LK_EQ(points_ok, true);

        /* 242,238 bytes is 4 for the count, then 5 per ring and 8 per point. */
        Case("the rings and points account for the whole file");
        LK_EQ(4 + rings.size() * 5 + total * 8, (size_t)std::filesystem::file_size(path));

        Case("every position is on the earth");
        bool bounded = true;
        for (auto const &r : rings)
            for (auto const &p : r.points)
                bounded = bounded && p.lon >= -180.0f && p.lon <= 180.0f && p.lat >= -90.0f &&
                          p.lat <= 90.0f;
        LK_EQ(bounded, true);
    }

    Suite("lk_coastline: the projection");
    {
        MapWindow w{ -80.0, -70.0, 35.0, 42.0 };

        Case("the window's west edge is x 0 and its east edge is the full width");
        double x = 0, y = 0;
        w.Point(-80.0, 38.0, 200.0, 100.0, &x, &y);
        LK_NEAR(x, 0.0, 1e-9);
        w.Point(-70.0, 38.0, 200.0, 100.0, &x, &y);
        LK_NEAR(x, 200.0, 1e-9);

        Case("north is y 0 and south is the full height, so y runs down");
        w.Point(-75.0, 42.0, 200.0, 100.0, &x, &y);
        LK_NEAR(y, 0.0, 1e-9);
        w.Point(-75.0, 35.0, 200.0, 100.0, &x, &y);
        LK_NEAR(y, 100.0, 1e-9);

        /* Mercator stretches toward the pole, so the northern half of this
         * window takes more of the drawing than the southern half and the
         * middle parallel lands below the middle of the box. Equirectangular
         * would put it exactly halfway at 50. The property is what matters:
         * below centre, and near it rather than far. */
        Case("the middle parallel lands below halfway, which is Mercator");
        w.Point(-75.0, 38.5, 200.0, 100.0, &x, &y);
        LK_EQ(y > 50.0, true);
        LK_EQ(y < 53.0, true);

        /* The same window under equirectangular would put it at exactly 50, so
         * this is the check that would fail if the projection were swapped. */
        Case("and not at halfway, which equirectangular would give");
        LK_EQ(y > 50.5, true);

        Case("longitude maps straight through rather than wrapping");
        w.Point(-85.0, 38.0, 200.0, 100.0, &x, &y);
        LK_EQ(x < 0.0, true);

        Case("the equator is Mercator zero and the poles are clamped");
        LK_NEAR(MapWindow::Mercator(0.0), 0.0, 1e-12);
        LK_EQ(MapWindow::Mercator(90.0) == MapWindow::Mercator(85.05), true);
        LK_EQ(MapWindow::Mercator(-90.0) == MapWindow::Mercator(-85.05), true);

        Case("a window taller than it is wide reports an aspect under one");
        MapWindow tall{ -76.0, -75.0, 35.0, 45.0 };
        LK_EQ(tall.Aspect() < 1.0, true);

        Case("a box overlapping the window intersects it");
        LK_EQ(w.Intersects(-78.0, -72.0, 36.0, 40.0), true);
        LK_EQ(w.Intersects(-90.0, -85.0, 36.0, 40.0), false);
        LK_EQ(w.Intersects(-78.0, -72.0, 50.0, 60.0), false);

        Case("a box touching the edge counts as reaching in");
        LK_EQ(w.Intersects(-90.0, -80.0, 36.0, 40.0), true);
    }
}
