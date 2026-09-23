/* lk_chart_sets: the installed chart sets, as the core's lookout_chart_sets
 * model holds them, and the rows a page draws from.
 *
 * A set is a folder, which may be the baked library, a folder of .pmtiles or
 * a folder of pictures, with an on/off switch. What opens is the UNION of the
 * switched-on sets. Mirrors the macOS "installed sets" model. */
#pragma once

#include <lookout-library.h>

#include <array>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace lkw
{
    struct ChartSetRow
    {
        std::string path;
        bool on{ true };
        /* The downloader's own set rather than the mariner's: the
         * folder NOAA charts are downloaded and prepared into. The
         * picker states what THIS set holds, so a mariner holding an
         * archive that merely lists cells does not read as holding
         * every region (lookout_chart_sets_set_managed). */
        bool managed{ false };
        // 0 until the background scan has read the folder, and every
        // count below is 0 until then.
        bool scanned{ false };
        size_t charts{ 0 };
        size_t pictures{ 0 };
        // Files that bake before they draw, and what the folder holds on
        // disk. Both are the core's own figures for the set.
        size_t unprepared{ 0 };
        /* What the core lists to prepare for this set, and the files a
         * finished bake did not prepare. `to_prepare` is `unprepared`
         * less `refused`, and band_todo splits it by usage band. */
        size_t to_prepare{ 0 };
        size_t refused{ 0 };
        std::array<size_t, 6> band_todo{};
        uint64_t bytes{ 0 };
        // How many prepared charts this set holds in each usage band,
        // keyed 1 to 6. A set that stops at Coastal does not draw the
        // harbour a passage ends in, so the row says which scales are in
        // it.
        std::map<int, size_t> bands;
        std::string title; // the agency whose charts these are, else the folder
    };

    class ChartSets
    {
    public:
        /* The model, opened on the first call and kept until Close. */
        lookout_chart_sets *Model();
        /* The model if it is open, else NULL. Opens nothing. */
        lookout_chart_sets *Handle() const { return model_; }
        void Load();
        std::vector<ChartSetRow> const &Rows() const { return rows_; }
        bool Scanning() const;
        std::vector<std::string> Compose();
        void Close();

        /* The composed paths the chart was last opened from. Empty when the
         * chart draws something else: a recent, the basemap, or nothing. */
        std::vector<std::string> opened;

    private:
        lookout_chart_sets      *model_{ nullptr };
        std::vector<ChartSetRow> rows_;
    };
}
