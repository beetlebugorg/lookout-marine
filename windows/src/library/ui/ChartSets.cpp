// Chart sets: the folders of charts the mariner has installed, each with an
// on/off switch. A set is a folder — the baked library, a folder of .pmtiles,
// a folder of pictures — and what the engine opens is the UNION of the
// switched-on sets, deduplicated and sorted. A set whose water is not today's
// water is switched off, not removed.
//
// THE CORE OWNS ALL OF IT (lookout_chart_sets): the list, the switches, their
// persistence in the settings store, the union, and the background scan that
// reads each folder one at a time. The rows below are a copy of what it holds,
// taken whenever it says something changed.
//
// A folder that did not answer STAYS LISTED: a folder that did not answer is a
// drive that is not plugged in, not a folder the mariner threw away.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <algorithm>
#include <filesystem>

#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    // The model, opened on the first ask and kept for the window. It needs no
    // chart handle: the sets exist before anything is open, and the empty
    // state is drawn from them.
    lookout_chart_sets *MainWindow::ChartSetsModel()
    {
        if (chart_sets_model == nullptr)
            chart_sets_model =
                lookout_chart_sets_open(lk_store_handle(), lkw::ChartLibraryDir().c_str());
        return chart_sets_model;
    }

    // Copy the list out. `then` runs at once: the list itself is there
    // immediately and it is the metadata that arrives later, announced by
    // lookout_chart_sets_changed.
    void MainWindow::LoadChartSets(std::function<void()> then)
    {
        chart_sets.clear();
        if (lookout_chart_sets *model = ChartSetsModel())
        {
            size_t n = 0;
            lookout_chart_set const *const *all = lookout_chart_sets_all(model, &n);
            for (size_t i = 0; i < n; ++i)
            {
                ChartSetRow row;
                row.path = all[i]->path;
                row.title = all[i]->title;
                row.on = all[i]->on != 0;
                row.scanned = all[i]->scanned != 0;
                // What the row says it holds. The engine's own counts split a
                // file that bakes first out of both halves, and this line has
                // always counted a picture waiting to be baked as a picture.
                size_t files = 0;
                auto found = lookout_chart_set_files(model, all[i]->path, &files);
                for (size_t f = 0; f < files; ++f)
                {
                    switch (found[f]->kind)
                    {
                    case LOOKOUT_FILE_RASTER:
                    case LOOKOUT_FILE_RASTER_SOURCE: row.pictures++; break;
                    case LOOKOUT_FILE_BAKED:         row.charts++; break;
                    default:                         break;
                    }
                }
                chart_sets.push_back(std::move(row));
            }
        }
        if (then)
            then();
    }

    // A background scan landing is the only change the model announces on its
    // own, and the counts a row shows are what it landed. Polled beside the
    // chart links, off the readout tick.
    void MainWindow::PollChartSets()
    {
        if (chart_sets_model == nullptr || !lookout_chart_sets_changed(chart_sets_model))
            return;
        LoadChartSets([this] {
            if (SettingsOpen())
                BuildSettingsPage();
        });
    }

    bool MainWindow::ChartSetsScanning() const
    {
        for (auto const &s : chart_sets)
            if (!s.scanned)
                return true;
        return false;
    }

    void MainWindow::CloseChartSets()
    {
        if (chart_sets_model == nullptr)
            return;
        lookout_chart_sets_close(chart_sets_model);
        chart_sets_model = nullptr;
    }

    // Every chart the switched-on sets carry, ready for the engine: sorted,
    // duplicates dropped (two sets may overlap, and the same cell twice
    // would be composed twice).
    std::vector<std::string> MainWindow::ChartSetOpenPaths()
    {
        std::vector<std::string> out;
        lookout_chart_sets *model = ChartSetsModel();
        if (model == nullptr)
            return out;
        size_t n = 0;
        char const *const *paths = lookout_chart_sets_compose(model, &n);
        for (size_t i = 0; i < n; ++i)
            out.push_back(paths[i]);
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
        lookout_chart_sets *model = ChartSetsModel();
        if (model == nullptr || !lookout_chart_sets_add(model, path.c_str()))
            return;
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
        lookout_chart_sets *model = ChartSetsModel();
        if (model == nullptr || !lookout_chart_sets_set_on(model, path.c_str(), on ? 1 : 0))
            return;
        LoadChartSets(nullptr);
        auto paths = ChartSetOpenPaths();
        if (!paths.empty())
            OpenPaths(paths, path, lkw::AgencyForCells(paths));
        if (SettingsOpen())
            BuildSettingsPage();
    }

    void MainWindow::RemoveChartSet(std::string const &path)
    {
        lookout_chart_sets *model = ChartSetsModel();
        if (model == nullptr || !lookout_chart_sets_remove(model, path.c_str()))
            return;
        LoadChartSets(nullptr);
        auto paths = ChartSetOpenPaths();
        if (!paths.empty())
            OpenPaths(paths, paths.front(), lkw::AgencyForCells(paths));
        if (SettingsOpen())
            BuildSettingsPage();
    }
}
