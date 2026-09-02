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
    /* Startup chart: $LOOKOUT_OPEN, then `most_recent` (the head of the store's
     * recents, or NULL when there is none), then the repo test cell. A recent
     * that names raw source (the .zip an import was baked FROM) stands for its
     * baked library: restarting must reopen the charts, never hand the zip to
     * the vector open, which skips it and draws nothing. `source_out`, when
     * given, receives the path the choice came from (the env value, the
     * recent, or empty for the fallback cell). */
    std::vector<std::string> InitialPaths(char const *most_recent,
                                          std::string *source_out = nullptr);

    /* The set's display name from the charts themselves: the hydrographic
     * office whose S-57 producer code opens every cell name (US* -> "NOAA"),
     * or "" when the cells disagree or the office is not one we can name — a
     * wrong agency on a chart set is worse than a dull one. Mirrors
     * ChartSet.agency in the macOS shell. */
    std::string AgencyForCells(std::vector<std::string> const &cells);

    /* Where an import writes the charts it bakes:
     * %LOCALAPPDATA%\lookout-marine\Charts. LOCAL rather than roaming — a baked
     * NOAA library is gigabytes, which has no business following a profile onto
     * another machine. Created on first use. */
    std::string ChartLibraryDir();

    /* Where baked BSB/KAP sheets land: %LOCALAPPDATA%\lookout-marine\Rasters.
     * Separate from ChartLibraryDir on purpose — the vector open globs that
     * directory for .pmtiles, and a picture archive it swallowed would join
     * the composed chart library. Created on first use. */
    std::string RasterLibraryDir();

    /* A raster SOURCE: a BSB/KAP sheet that must bake before it draws. */
    bool IsRasterSource(std::string const &path);

    /* Every raster chart under dir (case-insensitive, recursive, sorted):
     * .mbtiles, .pmtiles for baked BSB/KAP sheets (tile57 bake writes
     * <root>/<stem>/<stem>.pmtiles), and raw .kap/.bsb sheets, which the add
     * flow bakes on the way in. The extension is a hint; the engine decides
     * per file. */
    std::vector<std::string> CollectRasterCharts(std::string const &dir);
    /* The engine's set name for a raster chart (raster.zig setNameFor),
     * replicated so Settings' groups and the post-add auto-select agree with
     * the sets the pill offers. */
    std::string RasterSetNameFor(std::string const &path);
}
