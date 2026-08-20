/* lk_paths — chart path discovery for the shell. */
#pragma once

#include <string>
#include <vector>

namespace lkw
{
    /* Every .pmtiles under dir, recursive, sorted. */
    std::vector<std::string> CollectCells(std::string const &dir);
    /* A folder expands to its cells; a file is itself; a dangling path is empty. */
    std::vector<std::string> CellsFor(std::string const &path);
    /* Startup chart: $LOOKOUT_OPEN, then the last recent, then the repo test cell. */
    std::vector<std::string> InitialPaths();

    /* Where an import writes the charts it bakes:
     * %LOCALAPPDATA%\lookout-marine\Charts. LOCAL rather than roaming — a baked
     * NOAA library is gigabytes, which has no business following a profile onto
     * another machine. Created on first use. */
    std::string ChartLibraryDir();

    /* Every raster chart under dir (case-insensitive, recursive, sorted):
     * .mbtiles, and .pmtiles for baked BSB/KAP sheets (tile57 bake writes
     * <root>/<stem>/<stem>.pmtiles). Raw .kap is not matched: it must be
     * baked first. The extension is a hint; the engine decides per file. */
    std::vector<std::string> CollectRasterCharts(std::string const &dir);
    /* The engine's set name for a raster chart (raster.zig setNameFor),
     * replicated so Settings' groups and the post-add auto-select agree with
     * the sets the pill offers. */
    std::string RasterSetNameFor(std::string const &path);
}
