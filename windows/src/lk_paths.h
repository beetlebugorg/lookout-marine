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

    /* Every .mbtiles under dir (case-insensitive), recursive, sorted. BSB/KAP
     * sheets are deliberately not matched: they must be baked first. */
    std::vector<std::string> CollectRasterCharts(std::string const &dir);
    /* The engine's set name for a raster chart (raster.zig setNameFor),
     * replicated so Settings' groups and the post-add auto-select agree with
     * the sets the pill offers. */
    std::string RasterSetNameFor(std::string const &path);
}
