// Chart sets: the folders of charts the mariner has installed, each with an
// on/off switch. Mirrors the macOS model (ChartSets.swift / AppModel
// "installed sets"): a set is a folder — the baked library, a folder of .pmtiles, a
// folder of pictures — and what the engine opens is the UNION of the
// switched-on sets, deduplicated and sorted. A set whose water is not
// today's water is switched off, not removed.
//
// The folders are scanned again at every load rather than their contents
// stored: a folder changes underneath the app. The saved list is NOT
// rewritten by a scan — a folder that did not answer is a drive that is not
// plugged in, not a folder the mariner threw away; only an explicit add or
// remove changes what is saved.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <algorithm>
#include <filesystem>
#include <set>

#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    // Re-read the saved list and walk each folder, off the UI thread (a set
    // on a network share walks slowly). `then` runs on the UI thread with
    // the rows in place.
    void MainWindow::LoadChartSets(std::function<void()> then)
    {
        int *on = nullptr;
        char **paths = lk_store_load_chartsets(&on);
        auto saved = std::make_shared<std::vector<std::pair<std::string, bool>>>();
        for (int i = 0; paths != nullptr && paths[i] != nullptr; ++i)
            saved->push_back({ paths[i], on[i] != 0 });
        lk_store_free_rasters(paths, on);

        if (saved->empty())
        {
            chart_sets.clear();
            if (then)
                then();
            return;
        }

        auto queue = DispatcherQueue();
        auto done = std::make_shared<std::function<void()>>(std::move(then));
        // The window is HELD for the whole walk, and again across the hop
        // back. A set on a network share walks slowly, the mariner can close
        // the window while it does, and both the thread body and the
        // continuation write to this object — a bare `this` here is a
        // use-after-free waiting for a slow drive.
        auto lifetime = get_strong();
        std::thread([this, lifetime, queue, saved, done] {
            auto rows = std::make_shared<std::vector<ChartSetRow>>();
            for (auto const &[path, is_on] : *saved)
            {
                ChartSetRow row;
                row.path = path;
                row.on = is_on;
                row.cells = lkw::CellsFor(path);
                row.rasters = lkw::CollectRasterCharts(path);
                // The agency whose charts these are ("NOAA"), else the folder.
                std::string agency = lkw::AgencyForCells(row.cells);
                row.title = !agency.empty()
                                ? agency
                                : std::filesystem::path(path).filename().string();
                if (row.title.empty())
                    row.title = path;
                // A folder that answered nothing STAYS LISTED (see the file
                // comment) — it simply opens nothing while it is away.
                rows->push_back(std::move(row));
            }
            queue.TryEnqueue([this, lifetime, rows, done] {
                chart_sets = *rows;
                if (*done)
                    (*done)();
            });
        }).detach();
    }

    // Every chart the switched-on sets carry, ready for the engine: sorted,
    // duplicates dropped (two sets may overlap, and the same cell twice
    // would be composed twice).
    std::vector<std::string> MainWindow::ChartSetOpenPaths() const
    {
        std::set<std::string> seen;
        std::vector<std::string> out;
        for (auto const &s : chart_sets)
        {
            if (!s.on)
                continue;
            for (auto const &p : s.cells)
                if (seen.insert(p).second)
                    out.push_back(p);
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    // Put `path` on the list (switched on; an existing entry keeps its
    // switch) and refresh the rows. Called after an open or a bake landed a
    // library, so the set list follows what the mariner actually opened.
    void MainWindow::AdoptChartSet(std::string const &path)
    {
        std::error_code ec;
        if (path.empty() || !std::filesystem::is_directory(path, ec))
            return;
        lk_store_note_chartset(path.c_str());
        LoadChartSets([this] {
            if (SettingsOpen())
                BuildSettingsPage();
        });
    }

    // The switch: reopen on the union that results. Switching the LAST set
    // off keeps the chart on screen — a blank sea helps nobody — but the
    // next launch honors the switches.
    void MainWindow::SetChartSetOn(std::string const &path, bool on)
    {
        lk_store_set_chartset_on(path.c_str(), on ? 1 : 0);
        for (auto &s : chart_sets)
            if (s.path == path)
                s.on = on;
        auto paths = ChartSetOpenPaths();
        if (!paths.empty())
            OpenPaths(paths, path, lkw::AgencyForCells(paths));
        if (SettingsOpen())
            BuildSettingsPage();
    }

    void MainWindow::RemoveChartSet(std::string const &path)
    {
        lk_store_forget_chartset(path.c_str());
        chart_sets.erase(std::remove_if(chart_sets.begin(), chart_sets.end(),
                                        [&](ChartSetRow const &s) { return s.path == path; }),
                         chart_sets.end());
        auto paths = ChartSetOpenPaths();
        if (!paths.empty())
            OpenPaths(paths, paths.front(), lkw::AgencyForCells(paths));
        if (SettingsOpen())
            BuildSettingsPage();
    }
}
