// Chart import: raw S-57 cells, from a folder or an exchange-set .zip, baked
// into charts the app can draw — and the panel that reports it.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <shobjidl.h>

#include <filesystem>
#include <set>

#include "lk_bake.h"
#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    /* Where baked charts land. One library beside the mariner's own data, so a
     * second import of the same exchange set resumes rather than starting over:
     * tile57 skips a cell whose archive is already there and current. */
    std::string MainWindow::BakeOutputDir()
    {
        std::filesystem::path root = lkw::ChartLibraryDir();
        std::error_code ec;
        std::filesystem::create_directories(root, ec);
        return root.string();
    }

    /* The one way charts arrive: scan first, bake what is raw, then open.
     *
     * Scanning before offering anything is the point — a chart folder also holds
     * files that are not charts, and an archive may hold pictures rather than a
     * chart. Both open in a file panel and neither draws, which is what made
     * picking a folder of .000 cells look like it did nothing: the old path
     * collected .pmtiles only, found none, and opened an empty list. */
    void MainWindow::ImportCharts(std::string const &path)
    {
        if (controller == nullptr || bake_job != nullptr || import_scanning)
            return;

        BakeTitle().Text(winrt::to_hstring("Finding charts in " +
                                           std::filesystem::path(path).filename().string()));
        BakeCount().Text(L"");
        BakeEta().Text(L"");
        BakeBar().IsIndeterminate(true);
        BakePanel().Visibility(Visibility::Visible);

        /* Scanned off the UI thread: an archive's central directory is 8 ms,
         * but a FOLDER scan walks the filesystem and opens every archive it
         * finds — seconds on a network share, with the window frozen for all
         * of it. One scan at a time (`import_scanning`): the two scan entry
         * points share one buffer in the core and are not reentrant. */
        import_scanning = true;
        auto queue = DispatcherQueue();
        std::thread([this, queue, path] {
            auto scan = std::make_shared<lkw::ScanResult>(lkw::ScanCharts(path));
            queue.TryEnqueue([this, path, scan] {
                import_scanning = false;
                FinishImport(path, *scan);
            });
        }).detach();
    }

    void MainWindow::FinishImport(std::string const &path, lkw::ScanResult const &scan)
    {
        if (controller == nullptr || bake_job != nullptr)
        {
            BakePanel().Visibility(Visibility::Collapsed);
            return;
        }
        if (!scan.ok)
        {
            BakePanel().Visibility(Visibility::Collapsed);
            return;
        }

        /* Scan-merge, the reference's ChartSets.scan: a cell whose archive is
         * already in the library needs no prepare, so importing the same
         * exchange set twice OPENS instead of re-running the job. tile57
         * would skip each such cell anyway, but the panel would still rise
         * and count finished work as work to do. */
        unsigned dropped_ready = 0;
        lkw::ScanResult merged = scan;
        {
            std::set<std::string> ready;
            auto note = [&ready](std::filesystem::path const &root) {
                std::error_code ec;
                if (!std::filesystem::is_directory(root, ec))
                    return;
                for (auto it = std::filesystem::recursive_directory_iterator(root, ec);
                     !ec && it != std::filesystem::recursive_directory_iterator();
                     it.increment(ec))
                    if (it->is_regular_file(ec))
                        ready.insert(it->path().stem().string());
            };
            note(BakeOutputDir());
            note(std::filesystem::path(lkw::RasterLibraryDir()) /
                 std::filesystem::path(path).stem());
            merged.cells.clear();
            for (auto const &c : scan.cells)
            {
                if (c.NeedsPrepare() &&
                    ready.count(std::filesystem::path(c.name).stem().string()) != 0)
                {
                    ++dropped_ready;
                    continue;
                }
                merged.cells.push_back(c);
            }
        }

        /* Nothing raw: these are charts already, so open them and skip the bake
         * entirely. Ready pictures (.mbtiles, baked sheets) go to the raster
         * underlay, never to the vector open, which has no use for them.
         * Counted from the cells, not scan.sources: that counter is the
         * VECTOR sources alone, and a folder of BSB/KAP sheets must bake. */
        unsigned to_prepare = 0;
        for (auto const &c : merged.cells)
            if (c.NeedsPrepare())
                ++to_prepare;
        if (to_prepare == 0)
        {
            BakePanel().Visibility(Visibility::Collapsed);
            std::vector<std::string> baked;
            std::vector<std::string> pictures;
            for (auto const &c : merged.cells)
            {
                if (c.NeedsPrepare())
                    continue;
                (c.kind == "raster" ? pictures : baked).push_back(c.path);
            }
            if (dropped_ready > 0)
            {
                /* Part (or all) of this set was prepared by an earlier
                 * import: open the whole library plus whatever ready charts
                 * the folder holds itself, exactly as the bake's finish
                 * does. The recent is the library, never the source. */
                auto lib = lkw::CollectCells(BakeOutputDir());
                lib.insert(lib.end(), baked.begin(), baked.end());
                AdoptBakedRasters(pictures, !lib.empty());
                OpenPaths(lib, lkw::ChartLibraryDir(), lkw::AgencyForCells(lib));
                return;
            }
            if (baked.empty() && pictures.empty())
                baked = lkw::CellsFor(path);
            AdoptBakedRasters(pictures, !baked.empty());
            OpenPaths(baked, path, lkw::AgencyForCells(baked));
            return;
        }

        bake_job = std::make_unique<lkw::BakeJob>();
        bake_rasters_only = false;
        /* Sheets bake beside the charts but into their own root, named after
         * the source so they group into one set (Rasters\<name>\...). */
        std::string raster_out =
            (std::filesystem::path(lkw::RasterLibraryDir()) /
             std::filesystem::path(path).stem()).string();
        if (!bake_job->Start(merged, path, BakeOutputDir(), raster_out))
        {
            bake_job.reset();
            BakePanel().Visibility(Visibility::Collapsed);
            return;
        }
        bake_source = path;

        // Registered once. Wiring it per import would stack a handler on every
        // one and cancel the job as many times as the mariner had imported.
        if (!bake_cancel_wired)
        {
            bake_cancel_wired = true;
            BakeCancel().Click([this](auto &&, auto &&) {
                if (bake_job != nullptr)
                {
                    bake_job->Cancel();
                    BakeEta().Text(L"Stopping after the cells already started…");
                }
            });
        }

        /* The engine's callbacks fire from worker threads and XAML is not
         * thread-affine-safe, so the panel reads the job's snapshot on a timer
         * rather than being called. It also keeps a 7,000 cell import from
         * laying out the panel 7,000 times. */
        if (bake_timer == nullptr)
        {
            bake_timer = DispatcherTimer{};
            bake_timer.Interval(std::chrono::milliseconds(200));
            bake_timer.Tick([this](auto &&, auto &&) { TickBake(); });
        }
        bake_timer.Start();
    }

    void MainWindow::TickBake()
    {
        if (bake_job == nullptr)
        {
            bake_timer.Stop();
            return;
        }
        auto p = bake_job->Snapshot();

        BakeTitle().Text(winrt::to_hstring(p.Title()));
        if (p.total > 0)
        {
            BakeBar().IsIndeterminate(false);
            BakeBar().Value(p.Fraction());
            std::string line = std::to_string(p.done) + " of " + std::to_string(p.total);
            if (!p.cell.empty())
                line += "  ·  " + p.cell;
            BakeCount().Text(winrt::to_hstring(line));
        }
        if (!p.cancelled)
            BakeEta().Text(winrt::to_hstring(p.Remaining()));

        if (p.running)
            return;

        /* Done, or stopped. What landed is a library either way: every archive
         * written is complete, and a later import resumes from them. */
        bake_timer.Stop();
        auto rasters = bake_job->FinishedRasters();
        auto error = bake_job->Error();
        bake_job.reset();
        BakePanel().Visibility(Visibility::Collapsed);

        /* An import that produced nothing says why. Anything partial opens
         * below without a dialog: what landed is a usable library. */
        if (!error.empty())
        {
            ShowImportError(winrt::to_hstring("Couldn't prepare those charts.\n" + error));
            return;
        }

        /* Open the whole LIBRARY at once, not this import's output alone: an
         * import adds to what earlier imports baked, a resume skips what is
         * already there, and a restart reopens the same whole set. Opening it
         * once at the end (rather than batch by batch) is deliberate — each
         * handover rebuilt the ownership partition over a growing library.
         *
         * The recent is the library too, never the source: the source is what
         * the charts were baked FROM, and reopening it hands the vector open a
         * file it can only skip. The label is the office whose charts these
         * are — "All_ENCs.zip" is what a download happened to be called. */
        auto charts = bake_rasters_only ? std::vector<std::string>{}
                                        : lkw::CollectCells(BakeOutputDir());
        AdoptBakedRasters(rasters, !charts.empty());
        if (!charts.empty())
            OpenPaths(charts, lkw::ChartLibraryDir(), lkw::AgencyForCells(charts));
    }

    /* Baked sheets join the raster underlay. When a vector open is about to
     * happen they only need noting — the open re-installs the stored list
     * (InstallStoredRasters) on the new handle. With no open coming they are
     * added to the chart on screen right away. */
    void MainWindow::AdoptBakedRasters(std::vector<std::string> const &rasters, bool opening)
    {
        if (rasters.empty())
            return;
        if (!opening)
        {
            AddRasterPaths(rasters);
            return;
        }
        std::vector<const char *> cps;
        for (auto const &p : rasters)
            cps.push_back(p.c_str());
        lk_store_note_rasters(cps.data(), (int)cps.size());
    }

    /* The raster add flow's bake: sheets the mariner picked by hand, no scan.
     * The same job and panel as a chart import; the finish path above sees a
     * raster-only job and routes the output to the underlay. */
    void MainWindow::BakeRasterSources(std::vector<std::string> const &sources)
    {
        if (sources.empty() || bake_job != nullptr)
            return;

        lkw::ScanResult scan;
        scan.ok = true;
        for (auto const &p : sources)
        {
            lkw::ScannedCell c;
            c.path = p;
            c.name = std::filesystem::path(p).filename().string();
            c.kind = "raster_source";
            scan.cells.push_back(std::move(c));
        }

        /* Group under the sheets' own folder name, so a set of 968 KAPs is
         * one entry in the pill, named for the folder they came in. */
        std::string folder = std::filesystem::path(sources.front()).parent_path().filename().string();
        if (folder.empty())
            folder = "Raster charts";
        std::string raster_out = (std::filesystem::path(lkw::RasterLibraryDir()) / folder).string();

        bake_job = std::make_unique<lkw::BakeJob>();
        bake_rasters_only = true;
        if (!bake_job->Start(scan, folder, BakeOutputDir(), raster_out))
        {
            bake_job.reset();
            return;
        }
        bake_source.clear();

        if (!bake_cancel_wired)
        {
            bake_cancel_wired = true;
            BakeCancel().Click([this](auto &&, auto &&) {
                if (bake_job != nullptr)
                {
                    bake_job->Cancel();
                    BakeEta().Text(L"Stopping after the cells already started…");
                }
            });
        }

        BakeTitle().Text(winrt::to_hstring("Importing " + folder));
        BakeCount().Text(L"");
        BakeEta().Text(L"");
        BakeBar().IsIndeterminate(false);
        BakePanel().Visibility(Visibility::Visible);

        if (bake_timer == nullptr)
        {
            bake_timer = DispatcherTimer{};
            bake_timer.Interval(std::chrono::milliseconds(200));
            bake_timer.Tick([this](auto &&, auto &&) { TickBake(); });
        }
        bake_timer.Start();
    }

    /* An exchange set as a chart agency publishes it: one .zip. Nothing is
     * unpacked — each cell is inflated as its turn comes, so importing NOAA's
     * 792 MB All_ENCs.zip never costs the disk a second copy of the 2.1 GB of
     * source it holds. */
    fire_and_forget MainWindow::PickChartArchive()
    {
        auto lifetime = get_strong();
        Windows::Storage::Pickers::FileOpenPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(top_hwnd);
        picker.FileTypeFilter().Append(L".zip");
        auto file = co_await picker.PickSingleFileAsync();
        if (file != nullptr)
            ImportCharts(winrt::to_string(file.Path()));
    }

    fire_and_forget MainWindow::ShowImportError(winrt::hstring msg)
    {
        auto lifetime = get_strong();
        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(winrt::box_value(L"Import Charts"));
        dialog.Content(winrt::box_value(msg));
        dialog.CloseButtonText(L"OK");
        co_await dialog.ShowAsync();
    }
}
