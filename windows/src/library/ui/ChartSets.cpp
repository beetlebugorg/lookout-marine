// Chart sets: the folders of charts the mariner has installed, each with an
// on/off switch. A set is a folder: the baked library, a folder of
// .pmtiles, or a folder of pictures. What the engine opens is the UNION of
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
        {
            chart_sets_model =
                lookout_chart_sets_open(lk_store_handle(), lkw::ChartLibraryDir().c_str());
            // The download directory is the downloader's set. The core skips
            // the mark when the directory is not on the saved list yet, and
            // PrepareChartSet marks it when a download adds it.
            // The library directory was the managed set before it became
            // prepared_root. Its row stays listed as a set the mariner can
            // remove.
            if (chart_sets_model != nullptr)
            {
                lookout_chart_sets_set_managed(chart_sets_model, lkw::NoaaDownloadDir().c_str(), 1);
                lookout_chart_sets_set_managed(chart_sets_model, lkw::ChartLibraryDir().c_str(), 0);
            }
            SweepRemovedCharts();
        }
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
                row.managed = all[i]->managed != 0;
                row.scanned = all[i]->scanned != 0;
                row.unprepared = all[i]->unprepared;
                row.to_prepare = all[i]->to_prepare;
                row.refused = all[i]->refused;
                for (size_t b = 0; b < 6; ++b)
                    row.band_todo[b] = all[i]->band_todo[b];
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


    // Bake what the core lists for one set.
    //
    // The list is every file of the set that bakes before it draws and has no
    // prepared chart, or whose chart is older than the file. An update
    // leaves a cell in that state. Files a finished bake refused are left
    // out, so a bake started here has work to do.
    //
    // False when the list is empty or the bake does not start.
    bool MainWindow::BakeSetToPrepare(std::string const &path)
    {
        lookout_chart_sets *model = ChartSetsModel();
        if (model == nullptr || bake_job != nullptr || path.empty())
            return false;

        size_t n = 0;
        auto const *files = lookout_chart_set_to_prepare(model, path.c_str(), &n);
        if (files == nullptr || n == 0)
            return false;

        lkw::ScanResult scan;
        scan.root = path;
        scan.ok = true;
        noaa_scan_bands.clear();
        for (size_t i = 0; i < n; ++i)
        {
            if (files[i] == nullptr)
                continue;
            lkw::ScannedCell cell;
            cell.path = files[i]->path;
            cell.name = files[i]->name;
            cell.kind = files[i]->kind;
            cell.band = files[i]->band;
            noaa_scan_bands.push_back(cell.band);
            scan.cells.push_back(std::move(cell));
            ++scan.sources;
        }
        if (scan.cells.empty())
            return false;

        // Charts go in the set's prepared directory, where the core's scan
        // reads them. Sheets go in a raster directory of the same name, as an
        // archive import writes them.
        std::string const raster_out =
            (std::filesystem::path(lkw::RasterLibraryDir()) /
             std::filesystem::path(PreparedDirFor(path)).filename())
                .string();
        bake_job = std::make_unique<lkw::BakeJob>();
        if (!bake_job->Start(scan, path, PreparedDirFor(path), raster_out))
        {
            bake_job.reset();
            return false;
        }
        bake_source = path;
        bake_for_set = true;
        WatchBake();
        return true;
    }

    // Where a bake of the set at `path` writes: the library directory named
    // by lookout_bake_prepared_name. The core scans the same directory beside
    // the set.
    std::string MainWindow::PreparedDirFor(std::string const &path)
    {
        char name[512];
        if (lookout_bake_prepared_name(path.c_str(), name, sizeof name) == 0)
            return {};
        return (std::filesystem::path(lkw::ChartLibraryDir()) / name).string();
    }

    // Put a folder on the list and prepare it when the core's scan of it
    // ends. PollChartSets finishes it in FinishPendingSet.
    void MainWindow::PrepareChartSet(std::string const &path)
    {
        lookout_chart_sets *model = ChartSetsModel();
        if (model == nullptr || path.empty())
            return;
        if (!lookout_chart_sets_add(model, path.c_str()))
            lookout_chart_sets_rescan(model, path.c_str());
        if (path == lkw::NoaaDownloadDir())
            lookout_chart_sets_set_managed(model, path.c_str(), 1);
        AwaitSetScan(path, true);
        LoadChartSets(nullptr);
    }

    // Finish the set at `path` in FinishPendingSet when its scan ends.
    // PollChartSets runs on the readout tick, which is stopped while no chart
    // is open, so this starts it. Setup polls from FirstRunPoll.
    void MainWindow::AwaitSetScan(std::string const &path, bool bake)
    {
        pending_set = path;
        pending_set_bake = bake;
        if (!first_run.showing())
            readout_timer.Start();
    }

    // The pending set's scan has ended. Bake its to_prepare list, or open
    // the switched-on sets when the list is empty or a bake of it just ended.
    // A folder that holds no charts leaves the list.
    void MainWindow::FinishPendingSet()
    {
        auto row = std::find_if(chart_sets.begin(), chart_sets.end(),
                                [this](ChartSetRow const &r) { return r.path == pending_set; });
        if (row == chart_sets.end())
        {
            pending_set.clear();
            return;
        }
        if (!row->scanned || bake_job != nullptr)
            return;
        std::string const path = pending_set;
        bool const bake = pending_set_bake;
        pending_set.clear();
        BakePanel().Visibility(Visibility::Collapsed);

        bool const importing =
            first_run.showing() && first_run.step() == lkw::FirstRunStep::Importing;
        if (bake && BakeSetToPrepare(path))
        {
            if (importing)
            {
                first_run.NoteBakeStarted();
                FirstRunRender();
            }
            return;
        }

        if (row->charts == 0 && row->pictures == 0 && row->to_prepare == 0 && !row->managed)
        {
            if (lookout_chart_sets_remove(chart_sets_model, path.c_str()))
                LoadChartSets(nullptr);
            return;
        }

        std::vector<std::string> pictures;
        size_t n = 0;
        auto const *files = lookout_chart_set_files(chart_sets_model, path.c_str(), &n);
        for (size_t i = 0; files != nullptr && i < n; ++i)
            if (files[i] != nullptr && files[i]->kind == LOOKOUT_FILE_RASTER)
                pictures.push_back(files[i]->path);
        auto charts = ChartSetOpenPaths();
        AdoptBakedRasters(pictures, !charts.empty());
        if (!charts.empty())
            OpenPaths(charts, charts.front(), lkw::AgencyForCells(charts));
        if (importing)
        {
            if (charts.empty())
            {
                first_run.NoteImportStalled("The download produced no charts.");
                first_run_import_idle = true;
            }
            else
                noaa_handed_over = true;
            FirstRunRender();
        }
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

            // A scan completing is often the first moment the library composes
            // at all. The open at startup asks the model what the switched-on
            // sets hold, and before the scan the answer is empty, so the chart
            // opened a recent and the library stayed shut for the rest of the
            // run. The release build loses that race every time: it reaches
            // the open sooner than the debug build does.
            //
            // Only when the composition differs from what is open. An open
            // that already composed the library records it, and reopening on
            // top of that ends a NOAA transfer in flight.
            if (!pending_set.empty())
            {
                FinishPendingSet();
                return;
            }
            auto composed = ChartSetOpenPaths();
            if (!composed.empty() && composed != opened_set_paths)
                ReopenChartSets({});

            // A set with files still to prepare and no stop recorded since it
            // changed. An import cut short by a quit or a crash finishes here,
            // on the first scan after the app opens.
            if (bake_job == nullptr && chart_sets_model != nullptr)
            {
                if (char const *resume = lookout_chart_sets_resume(chart_sets_model))
                    BakeSetToPrepare(resume);
            }
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

    // What an interrupted removal left behind.
    //
    // A removal renames the charts into a holding directory beside the library
    // and deletes behind the rename on a thread of its own. An app that goes
    // down before that thread finishes leaves the directory on the disk, with
    // every chart still in it. Nothing else would ever take it out.
    //
    // Once a session, off the UI thread, and only names this app writes.
    void MainWindow::SweepRemovedCharts()
    {
        std::error_code ec;
        std::filesystem::path lib = lkw::ChartLibraryDir();
        std::filesystem::path const holding =
            lib.has_parent_path() ? lib.parent_path() : lib;
        std::vector<std::filesystem::path> old;
        for (auto const &entry : std::filesystem::directory_iterator(holding, ec))
        {
            std::error_code one;
            if (!entry.is_directory(one))
                continue;
            if (lookout_bake_is_trash(entry.path().filename().string().c_str()))
                old.push_back(entry.path());
        }
        if (old.empty())
            return;
        std::thread([old] {
            for (auto const &dir : old)
            {
                std::error_code done;
                std::filesystem::remove_all(dir, done);
            }
        }).detach();
    }

    // The cells the library holds, read off the disk.
    //
    // The safe source while a scan is in flight. The core hands out its file
    // list as pointers into an arena, and a scan LANDING on its own worker
    // frees that arena (Sets.land: files_arena.deinit and reads.reset), so a
    // read racing a landing walks freed memory. Every chart this shell
    // prepared is under the library directory.
    std::set<std::string> MainWindow::LibraryCellsOnDisk()
    {
        std::set<std::string> out;
        std::error_code ec;
        std::filesystem::path root(lkw::ChartLibraryDir());
        if (!std::filesystem::is_directory(root, ec))
            return out;
        for (auto it = std::filesystem::recursive_directory_iterator(root, ec);
             !ec && it != std::filesystem::recursive_directory_iterator(); it.increment(ec))
        {
            std::error_code one;
            if (!it->is_regular_file(one))
                continue;
            auto ext = it->path().extension().string();
            for (auto &ch : ext)
                ch = (char)tolower((unsigned char)ch);
            if (ext != ".pmtiles")
                continue;
            std::string stem = it->path().stem().string();
            for (auto &ch : stem)
                ch = (char)toupper((unsigned char)ch);
            if (!stem.empty())
                out.insert(stem);
        }
        return out;
    }

    // The cells a set holds, by dataset name.
    //
    // `managed_only` answers for the downloader's own set: the folder NOAA
    // charts are prepared into. That is what the picker's ticks come from. The
    // whole list, every set, is what a PRICE skips: a cell the mariner already
    // holds in a folder of their own is a cell a download has no reason to
    // fetch again.
    //
    // A prepared chart stands in for the cell it was made from here, so this
    // reads one entry per cell whether or not the source .000 is still beside
    // it (lookout_chart_set_files).
    //
    // While a scan is in flight this reads the disk instead. See
    // LibraryCellsOnDisk for why.
    std::set<std::string> MainWindow::ChartSetCells(bool managed_only)
    {
        std::set<std::string> out;
        lookout_chart_sets *model = ChartSetsModel();
        if (model == nullptr)
            return out;
        if (ChartSetsScanning())
            return LibraryCellsOnDisk();
        for (auto const &row : chart_sets)
        {
            if (managed_only && !row.managed)
                continue;
            size_t files = 0;
            auto found = lookout_chart_set_files(model, row.path.c_str(), &files);
            if (found == nullptr)
                continue;
            for (size_t f = 0; f < files; ++f)
            {
                if (found[f] == nullptr || found[f]->kind != LOOKOUT_FILE_BAKED)
                    continue;
                std::string name = std::filesystem::path(found[f]->name).stem().string();
                for (auto &ch : name)
                    ch = (char)std::toupper((unsigned char)ch);
                if (!name.empty())
                    out.insert(name);
            }
        }
        // A library with charts on it and nothing to report means the model has
        // yet to read them.
        if (out.empty())
            return LibraryCellsOnDisk();
        return out;
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
    void MainWindow::AdoptChartSet(std::string const &path, bool after_write)
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
        // A path new to the list is scanned by the add. One already on it
        // is read again only after something wrote into it, which is a bake
        // finishing. Rescanning on every open returned the row to unscanned
        // while it read, and the page was rebuilt each time.
        if (!lookout_chart_sets_add(model, path.c_str()) && after_write)
            lookout_chart_sets_rescan(model, path.c_str());
        LoadChartSets([this] {
            if (SettingsOpen())
                RefreshChartsPageOnChange();
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

    // Delete a holding directory, a chart at a time, saying where it has got
    // to.
    //
    // The count is the mariner's own unit: a bake writes a directory per
    // chart, so removing one is a chart gone, and the panel counts the same
    // things coming out that it counted going in. One listing, not a walk of
    // every file under them.
    //
    // A set moved aside whole arrives as one directory holding the charts, and
    // an archive's charts arrive under ENC_ROOT. Descending past a lone child
    // counts charts rather than the skeleton above them.
    //
    // Static, and it takes the job by value: this runs on a thread of its own
    // that outlives the window's call. `failed` is what the caller could not
    // move aside, for the line at the end.
    static void EmptyAndRemove(std::filesystem::path trash,
                               std::shared_ptr<lkw::RemovalJob> job, size_t failed)
    {
        std::error_code ec;
        std::filesystem::path level = trash;
        for (;;)
        {
            std::vector<std::filesystem::path> kids;
            for (auto const &entry : std::filesystem::directory_iterator(level, ec))
                kids.push_back(entry.path());
            if (kids.size() != 1)
                break;
            std::error_code one;
            if (!std::filesystem::is_directory(kids[0], one))
                break;
            level = kids[0];
        }

        std::vector<std::filesystem::path> kids;
        for (auto const &entry : std::filesystem::directory_iterator(level, ec))
            kids.push_back(entry.path());
        if (job != nullptr)
            job->Count((unsigned)kids.size());

        size_t gone = 0;
        for (auto const &kid : kids)
        {
            std::error_code one;
            std::filesystem::remove_all(kid, one);
            if (!one)
                ++gone;
            if (job != nullptr)
                job->Step();
        }
        std::filesystem::remove_all(trash, ec);
        if (job != nullptr)
            job->Finish(winrt::to_string(lkw::RemovalNote(gone, failed)));
    }

    // Delete the charts Lookout prepared for one set: the set itself when it
    // is under the library, else its prepared directory.
    //
    // Renamed first and deleted behind. A NOAA library is thousands of
    // directories, and this runs on the UI thread: the rename is one step, so
    // the charts are gone from where anything looks for them before this
    // returns, and a set added straight back writes into a fresh directory
    // rather than racing the delete.
    void MainWindow::DeletePreparedCharts(std::string const &set_path, std::string const &name)
    {
        std::string const path =
            lookout_bake_is_derived(lkw::ChartLibraryDir().c_str(), set_path.c_str())
                ? set_path
                : PreparedDirFor(set_path);
        std::error_code ec;
        if (path.empty() || !std::filesystem::is_directory(path, ec))
            return;
        std::filesystem::path lib = lkw::ChartLibraryDir();
        // The name a delete in flight goes under. Skipped by the sweep below,
        // so two removals in a row do not fight over each other's work.
        std::string const prefix = lookout_bake_trash_prefix();
        std::filesystem::path trash =
            lib / (prefix + std::to_string(GetCurrentProcessId()) + "-" +
                   std::to_string(++remove_seq));
        std::filesystem::create_directories(trash, ec);
        if (ec)
            return;

        // What a rename refused. Windows returns one for a directory still
        // mapped by an open handle, and the removal states the count.
        size_t refused = 0;
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
                if (one)
                    ++refused;
            }
        }
        else
        {
            std::filesystem::path p{ path };
            std::filesystem::rename(p, trash / p.filename(), ec);
            if (ec)
                ++refused;
        }

        // Report it while it runs, in the panel an import reports in: a NOAA
        // library is thousands of directories and seconds of disk work, and a
        // removal that says nothing looks like nothing happening.
        removal_job = std::make_shared<lkw::RemovalJob>();
        removal_job->Begin(name, 0);

        // Behind the rename, off this thread. Nothing waits for it: every
        // chart it holds is already out of the library.
        std::thread(EmptyAndRemove, trash, removal_job, refused).detach();
    }

    // Give back the water a mariner unticked in the NOAA picker.
    //
    // Only what this app downloaded and prepared, and only inside its own two
    // directories: a mariner's own folders are their files, and a set they
    // added is removed a set at a time in the Charts pane.
    //
    // BOTH HALVES of every cell, resolved by name:
    //   <prepared>/<CELL>           the prepared chart, under PreparedDirFor
    //                               the download directory
    //   <downloads>/**/<CELL>       the cell it was made from, a level down
    //                               under ENC_ROOT
    // A prepared chart stands in for its source in a set's file list, so a
    // loop over that list deletes the chart, leaves the .000 beside it and the
    // next scan reads the cell straight back.
    //
    // Both halves are renamed into ONE trash directory and deleted behind it,
    // off the UI thread. The library is correct the moment the rename returns.
    MainWindow::NoaaRemoval MainWindow::RemoveNoaaCells(std::set<std::string> const &names,
                                                        std::string const &water)
    {
        NoaaRemoval took;
        if (names.empty())
            return took;
        std::error_code ec;
        std::filesystem::path lib = lkw::ChartLibraryDir();
        std::string const downloads = lkw::NoaaDownloadDir();
        std::filesystem::path const prepared = PreparedDirFor(downloads);
        if (!std::filesystem::is_directory(lib, ec))
            return took;

        // The core holds every chart in the library open, and Windows refuses
        // to move a directory out from under an open file. Nothing is drawn
        // while this runs; the reopen at the end puts the rest back up.
        CloseChartHandle();

        std::string const prefix = lookout_bake_trash_prefix();
        // BESIDE the library, not in it. A rename is instant and the delete
        // behind it takes a while; with the trash inside the library the scan
        // asked for below counted every chart still sitting in it, so the pane
        // read 935 charts with 5 on disk.
        std::filesystem::path const holding =
            lib.has_parent_path() ? lib.parent_path() : lib;
        std::filesystem::path trash =
            holding / (prefix + std::to_string(GetCurrentProcessId()) + "-" +
                       std::to_string(++remove_seq));
        std::filesystem::create_directories(trash, ec);
        if (ec)
            return took;

        // `into` keeps the two halves of one cell apart inside the trash.
        auto take = [&](std::filesystem::path const &what, std::string const &into) {
            std::error_code one;
            std::filesystem::rename(what, trash / into, one);
            if (one)
            {
                ++took.failed;
                return false;
            }
            return true;
        };
        auto cell_of = [&names](std::filesystem::directory_entry const &entry) {
            std::error_code one;
            std::string stem = entry.is_directory(one) ? entry.path().filename().string()
                                                       : entry.path().stem().string();
            for (auto &ch : stem)
                ch = (char)std::toupper((unsigned char)ch);
            return names.find(stem) != names.end() ? stem : std::string{};
        };

        // The prepared half: one directory per cell, named after it.
        for (auto const &entry : std::filesystem::directory_iterator(prepared, ec))
        {
            std::string const cell = cell_of(entry);
            if (cell.empty())
                continue;
            if (take(entry.path(), cell))
                ++took.prepared;
        }

        // The source half, under the download directory. NOAA's zips unpack to
        // ENC_ROOT/<CELL>/, so this walks rather than assuming the depth.
        ec.clear();
        if (std::filesystem::is_directory(downloads, ec))
        {
            std::vector<std::filesystem::path> hits;
            for (auto it = std::filesystem::recursive_directory_iterator(downloads, ec);
                 !ec && it != std::filesystem::recursive_directory_iterator(); it.increment(ec))
            {
                std::error_code one;
                if (!it->is_directory(one))
                    continue;
                std::string const cell = cell_of(*it);
                if (cell.empty())
                    continue;
                hits.push_back(it->path());
                // Its own children are this cell's as well, and the walk must
                // not follow a directory that is about to be renamed away.
                it.disable_recursion_pending();
            }
            for (auto const &hit : hits)
            {
                std::string cell = hit.filename().string();
                for (auto &ch : cell)
                    ch = (char)std::toupper((unsigned char)ch);
                if (take(hit, "src-" + cell))
                    ++took.sources;
            }
        }

        // Report it while it runs, in the panel an import reports in.
        removal_job = std::make_shared<lkw::RemovalJob>();
        removal_job->Begin(water, 0);

        // Behind the rename, off this thread. Every chart it holds is already
        // out of the library.
        std::thread(EmptyAndRemove, trash, removal_job, took.failed).detach();

        // PollChartSets copies the row's counts when the rescan ends. The
        // rescan frees the file lists a copy made here reads.
        if (took.prepared != 0 || took.sources != 0)
            if (lookout_chart_sets *model = ChartSetsModel())
                lookout_chart_sets_rescan(model, downloads.c_str());
        ReopenChartSets({});
        return took;
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
        if (model == nullptr)
            return;
        // What it is called, before the row that knows goes. The removal says
        // this while it runs, and by then the set is off the list.
        std::string name = std::filesystem::path(path).filename().string();
        for (auto const &row : chart_sets)
            if (row.path == path && !row.title.empty())
                name = row.title;
        if (!lookout_chart_sets_remove(model, path.c_str()))
            return;
        LoadChartSets(nullptr);
        // CLOSE, DELETE, THEN OPEN. The handle maps every archive it opened,
        // and Windows refuses to rename a directory under a mapped file. A
        // reopen in place of the close opens through OpenPaths with another
        // set still on, and that defers the close by 50 ms: the rename then
        // runs under the old handle, fails, and the charts stay on the disk
        // for the next import to find.
        CloseChartHandle();
        DeletePreparedCharts(path, name);
        ReopenChartSets({});
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
