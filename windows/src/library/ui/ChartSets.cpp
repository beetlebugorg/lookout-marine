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
#include <thread>

#include "lk_firstrun.h" // Thousands and PrepareEstimate, for the question
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
                row.unprepared = all[i]->unprepared;
                row.bytes = all[i]->bytes;
                // What the row says it holds. The engine's own counts split a
                // file that bakes first out of both halves, and this line has
                // always counted a picture waiting to be baked as a picture.
                size_t files = 0;
                std::vector<std::string> names;
                auto found = lookout_chart_set_files(model, all[i]->path, &files);
                for (size_t f = 0; f < files; ++f)
                {
                    switch (found[f]->kind)
                    {
                    case LOOKOUT_FILE_RASTER:
                    case LOOKOUT_FILE_RASTER_SOURCE: row.pictures++; break;
                    case LOOKOUT_FILE_BAKED:
                        row.charts++;
                        names.push_back(found[f]->name);
                        if (found[f]->band >= 1 && found[f]->band <= 6)
                            ++row.bands[found[f]->band];
                        break;
                    default:                         break;
                    }
                }
                // The office whose charts these are, when the core fell back
                // to the folder's own name. A NOAA library baked into the
                // app's chart folder read as "Charts", which names where the
                // files are rather than whose they are.
                std::string const folder =
                    std::filesystem::path(row.path).filename().string();
                if (row.title == folder && !names.empty())
                {
                    std::string agency = lkw::AgencyForCells(names);
                    if (!agency.empty())
                        row.title = agency;
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
            // Only when a row on the page changed. A rescan that finds what it
            // found before raises the same flag.
            RefreshChartsPageOnChange();
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
        if (model == nullptr)
            return;
        // add() scans a path new to the list and returns 0 for one already on
        // it. A path already on the list needs a rescan instead: a bake writes
        // into prepared_root after the last scan, and the row keeps its
        // pre-bake counts until the folder is read again. Returning early on
        // that 0 left a set reading 0 charts with the charts on disk, and
        // nothing else asks for a scan (lookout_chart_sets_rescan,
        // lookout-library.h:386).
        if (!lookout_chart_sets_add(model, path.c_str()))
            lookout_chart_sets_rescan(model, path.c_str());
        LoadChartSets([this] {
            if (SettingsOpen())
                BuildSettingsPage();
        });
    }

    // The switch: open the union that results. Switching the last set off
    // takes the chart off the display, because the charts behind it are not
    // drawing any more.
    void MainWindow::SetChartSetOn(std::string const &path, bool on)
    {
        lookout_chart_sets *model = ChartSetsModel();
        if (model == nullptr || !lookout_chart_sets_set_on(model, path.c_str(), on ? 1 : 0))
            return;
        LoadChartSets(nullptr);
        // In place: the switch the mariner just moved is already showing its
        // new state, and rebuilding the page under their pointer would take
        // the switch away mid-gesture. What the row says and what Lookout's
        // own tile is built from follow here.
        if (SettingsOpen())
            RefreshChartsPageInPlace();
        ReopenChartSets(path);
    }

    // Whether Lookout made the charts in this set.
    //
    // The bake writes into the chart library and the shell adopts that
    // directory as a set, so a set at or under the library holds work this app
    // did and can do again. Every other set is the mariner's own files, and
    // removing one of those only takes it off the list.
    bool MainWindow::ChartSetIsDerived(std::string const &path)
    {
        std::error_code ec;
        auto lib = std::filesystem::weakly_canonical(lkw::ChartLibraryDir(), ec);
        if (ec)
            return false;
        auto p = std::filesystem::weakly_canonical(std::filesystem::path(path), ec);
        if (ec)
            return false;
        auto shared = std::mismatch(lib.begin(), lib.end(), p.begin(), p.end());
        return shared.first == lib.end();
    }

    // Delete the charts Lookout prepared for one set.
    //
    // Renamed first and deleted behind. A NOAA library is thousands of
    // directories, and this runs on the UI thread: the rename is one step, so
    // the charts are gone from where anything looks for them before this
    // returns, and a set added straight back writes into a fresh directory
    // rather than racing the delete.
    void MainWindow::DeletePreparedCharts(std::string const &path)
    {
        if (!ChartSetIsDerived(path))
            return;
        std::error_code ec;
        std::filesystem::path lib = lkw::ChartLibraryDir();
        // The name a delete in flight goes under. Skipped by the sweep below,
        // so two removals in a row do not fight over each other's work.
        std::string const prefix = ".removing-";
        std::filesystem::path trash =
            lib / (prefix + std::to_string(GetCurrentProcessId()) + "-" +
                   std::to_string(++remove_seq));
        std::filesystem::create_directories(trash, ec);
        if (ec)
            return;

        if (std::filesystem::equivalent(std::filesystem::path(path), lib, ec))
        {
            // The set IS the library. Its children are the charts; the
            // directory itself stays, because the next import writes into it.
            for (auto const &entry : std::filesystem::directory_iterator(lib, ec))
            {
                std::string name = entry.path().filename().string();
                if (name.rfind(prefix, 0) == 0)
                    continue;
                std::error_code one;
                std::filesystem::rename(entry.path(), trash / entry.path().filename(), one);
            }
        }
        else
        {
            std::filesystem::path p{ path };
            std::filesystem::rename(p, trash / p.filename(), ec);
        }

        // Behind the rename, off this thread. Nothing waits for it: every
        // chart it holds is already out of the library.
        std::thread([trash] {
            std::error_code gone;
            std::filesystem::remove_all(trash, gone);
        }).detach();
    }

    // Take a set off the list.
    //
    // Charts this app prepared go with it: they were made from the mariner's
    // cells and can be made again, and a library left behind by a set the
    // mariner removed is the app hoarding on their disk. The question is asked
    // before any of that, in ConfirmRemoveChartSet.
    void MainWindow::RemoveChartSet(std::string const &path)
    {
        lookout_chart_sets *model = ChartSetsModel();
        if (model == nullptr || !lookout_chart_sets_remove(model, path.c_str()))
            return;
        LoadChartSets(nullptr);
        // Before the delete: the handle holds every chart file open, and
        // Windows refuses to rename a directory under an open file.
        ReopenChartSets({});
        DeletePreparedCharts(path);
        if (SettingsOpen())
            BuildSettingsPage();
    }

    fire_and_forget MainWindow::ConfirmRemoveChartSet(std::string path, std::string name,
                                                      size_t charts)
    {
        auto lifetime = get_strong();
        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(winrt::box_value(winrt::to_hstring("Remove " + name + "?")));
        dialog.Content(winrt::box_value(
            winrt::hstring{ L"Lookout deletes the " + lkw::Thousands(charts) + L" charts it "
                            L"prepared from this folder. Your original files stay where they "
                            L"are, and you can add the folder again, which takes " +
                            lkw::PrepareEstimate(charts) + L"." }));
        dialog.PrimaryButtonText(L"Remove and delete prepared charts");
        dialog.CloseButtonText(L"Cancel");
        auto result = co_await dialog.ShowAsync();
        if (result != Controls::ContentDialogResult::Primary)
            co_return;
        RemoveChartSet(path);
    }
}
