/* Finding the charts, and naming what was found.
 *
 * Two rules earn their tests here. A chart the mariner has on the drive must
 * be FOUND — a walk that misses a cell because its extension is upper case is
 * a chart that does not exist as far as the app is concerned. And a set must
 * be NAMED honestly: an office's name on the wrong charts is worse than a dull
 * folder name, so the agency is reported only when every cell agrees.
 */
#include "lk_test.h"

#include <filesystem>
#include <fstream>
#include <string>

#include "lk_paths.h"

using namespace lktest;
using namespace lkw;

namespace
{
    namespace fs = std::filesystem;

    /* A directory of empty files, thrown away when the case ends. */
    struct TempTree
    {
        fs::path root;

        explicit TempTree(char const *name)
        {
            std::error_code ec;
            root = fs::temp_directory_path(ec) / ("lk-test-" + std::string(name));
            fs::remove_all(root, ec);
            fs::create_directories(root, ec);
        }

        ~TempTree()
        {
            std::error_code ec;
            fs::remove_all(root, ec);
        }

        /* `rel` may name directories; they are made. */
        void Touch(std::string const &rel) const
        {
            fs::path p = root / rel;
            std::error_code ec;
            fs::create_directories(p.parent_path(), ec);
            std::ofstream out(p, std::ios::binary);
            out << "not really a chart";
        }

        std::string Str() const { return root.string(); }
    };

    bool Has(std::vector<std::string> const &v, std::string const &tail)
    {
        for (auto const &s : v)
            if (s.size() >= tail.size() && s.compare(s.size() - tail.size(), tail.size(), tail) == 0)
                return true;
        return false;
    }
}

void TestPaths()
{
    Suite("lk_paths: what is a raster source");

    LK_CASE("a BSB or KAP sheet has to bake before it draws");
    {
        LK_EQ(IsRasterSource("C:\\charts\\13207.KAP"), true);
        LK_EQ(IsRasterSource("C:\\charts\\13207.kap"), true);
        LK_EQ(IsRasterSource("C:\\charts\\13207.bsb"), true);
        LK_EQ(IsRasterSource("C:\\charts\\13207.BSB"), true);
        LK_EQ(IsRasterSource("C:\\charts\\13207.mbtiles"), false);
        LK_EQ(IsRasterSource("C:\\charts\\13207.pmtiles"), false);
        LK_EQ(IsRasterSource("C:\\charts\\13207"), false);
    }

    Suite("lk_paths: walking a drive");

    /* A cell whose extension is upper case is still a cell. Missing it is a
     * chart that does not exist as far as the app is concerned. */
    LK_CASE("cells are found whatever case the extension is in");
    {
        TempTree tree("cells");
        tree.Touch("US5MD1MC.pmtiles");
        tree.Touch("US4MD1AA.PMTILES");
        tree.Touch("deep\\US3MD1BB.PmTiles");
        tree.Touch("notes.txt");
        tree.Touch("picture.mbtiles");

        auto cells = CollectCells(tree.Str());
        LK_EQ(cells.size(), (size_t)3);
        LK_EQ(Has(cells, "US5MD1MC.pmtiles"), true);
        LK_EQ(Has(cells, "US4MD1AA.PMTILES"), true);
        LK_EQ(Has(cells, "US3MD1BB.PmTiles"), true);
    }

    LK_CASE("the walk is recursive and sorted");
    {
        TempTree tree("sorted");
        tree.Touch("b.pmtiles");
        tree.Touch("a\\a.pmtiles");
        auto cells = CollectCells(tree.Str());
        LK_EQ(cells.size(), (size_t)2);
        if (cells.size() == 2)
            LK_CHECK(cells[0] < cells[1]);
    }

    LK_CASE("a directory that is not there is no charts, not a fault");
    {
        LK_EQ(CollectCells("Z:\\no\\such\\place").size(), (size_t)0);
        LK_EQ(CollectRasterCharts("Z:\\no\\such\\place").size(), (size_t)0);
    }

    LK_CASE("raster charts: baked, tiled and raw sheets, any case");
    {
        TempTree tree("raster");
        tree.Touch("a.mbtiles");
        tree.Touch("b.MBTILES");
        tree.Touch("c.pmtiles");
        tree.Touch("d.KAP");
        tree.Touch("e.bsb");
        tree.Touch("f.png");
        LK_EQ(CollectRasterCharts(tree.Str()).size(), (size_t)5);
    }

    LK_CASE("a folder expands to its cells; a cell is itself");
    {
        TempTree tree("cellsfor");
        tree.Touch("US5MD1MC.pmtiles");
        LK_EQ(CellsFor(tree.Str()).size(), (size_t)1);
        LK_EQ(CellsFor((tree.root / "US5MD1MC.pmtiles").string()).size(), (size_t)1);
        LK_EQ(CellsFor("Z:\\no\\such\\chart.pmtiles").size(), (size_t)0);
    }

    Suite("lk_paths: naming a raster set");

    /* Longest first, so "OpenSeaMap" is not reported as "OSM". */
    LK_CASE("a producer the file name carries");
    {
        LK_EQ(RasterSetNameFor("C:\\r\\OpenSeaMap-west.mbtiles"), std::string("OpenSeaMap"));
        LK_EQ(RasterSetNameFor("C:\\r\\navionics_2024.mbtiles"), std::string("Navionics"));
        /* Case does not matter: one spelling of each in the table. */
        LK_EQ(RasterSetNameFor("C:\\r\\ESRI-world.mbtiles"), std::string("Esri"));
        LK_EQ(RasterSetNameFor("C:\\r\\esri-world.mbtiles"), std::string("Esri"));
    }

    /* Longest first, so a name that carries two is reported as the longer:
     * "OpenSeaMap" over "OSM", "Imagery" over "Esri". */
    LK_CASE("a name that carries two producers takes the longer");
    {
        LK_EQ(RasterSetNameFor("C:\\r\\OSM-OpenSeaMap.mbtiles"), std::string("OpenSeaMap"));
        LK_EQ(RasterSetNameFor("C:\\r\\ESRI-imagery.mbtiles"), std::string("Imagery"));
    }

    LK_CASE("a file that names no producer keeps its own stem");
    {
        LK_EQ(RasterSetNameFor("C:\\r\\13207.mbtiles"), std::string("13207"));
        LK_EQ(RasterSetNameFor("C:\\r\\Chesapeake.mbtiles"), std::string("Chesapeake"));
    }

    /* The bake writes <root>/<stem>/<stem>.pmtiles: a sheet belongs to its
     * bake, and the bake's own name is the set's. */
    LK_CASE("a baked sheet takes the name of the bake it came out of");
    {
        LK_EQ(RasterSetNameFor("C:\\r\\NOAA-BSB\\13207\\13207.pmtiles"), std::string("NOAA-BSB"));
        LK_EQ(RasterSetNameFor("C:\\r\\OpenSeaMap\\13207\\13207.pmtiles"),
              std::string("OpenSeaMap"));
        /* Upper case is the same layout. */
        LK_EQ(RasterSetNameFor("C:\\r\\NOAA-BSB\\13207\\13207.PMTILES"), std::string("NOAA-BSB"));
        /* Not that layout: the stem stands for itself. */
        LK_EQ(RasterSetNameFor("C:\\r\\loose\\13207.pmtiles"), std::string("13207"));
    }

    Suite("lk_paths: naming a chart set");

    LK_CASE("the office whose producer code every cell carries");
    {
        LK_EQ(AgencyForCells({ "C:\\c\\US5MD1MC.pmtiles", "C:\\c\\US4MD1AA.pmtiles" }),
              std::string("NOAA"));
        LK_EQ(AgencyForCells({ "C:\\c\\GB5X01SE.pmtiles" }), std::string("UKHO"));
        LK_EQ(AgencyForCells({ "C:\\c\\CA476011.pmtiles" }), std::string("CHS"));
        LK_EQ(AgencyForCells({ "C:\\c\\us5md1mc.pmtiles" }), std::string("NOAA")); /* any case */
    }

    /* An office's name on the wrong charts is worse than a dull folder name. */
    LK_CASE("cells that disagree get no name at all");
    {
        LK_EQ(AgencyForCells({ "C:\\c\\US5MD1MC.pmtiles", "C:\\c\\GB5X01SE.pmtiles" }),
              std::string(""));
    }

    LK_CASE("an office this shell cannot name is not given one");
    {
        LK_EQ(AgencyForCells({ "C:\\c\\XX5MD1MC.pmtiles" }), std::string(""));
    }

    LK_CASE("a name that is not a producer code is not read as one");
    {
        LK_EQ(AgencyForCells({ "C:\\c\\1.pmtiles" }), std::string(""));
        LK_EQ(AgencyForCells({ "C:\\c\\12345678.pmtiles" }), std::string(""));
        LK_EQ(AgencyForCells({}), std::string(""));
    }
}
