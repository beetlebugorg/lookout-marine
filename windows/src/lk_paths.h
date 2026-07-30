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
}
