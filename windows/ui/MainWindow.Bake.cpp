// Chart import: raw S-57 cells, from a folder or an exchange-set .zip, baked
// into charts the app can draw — and the panel that reports it.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <shobjidl.h>

#include <filesystem>

#include "lk_bake.h"
#include "lk_paths.h"

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
        if (controller == nullptr || bake_job != nullptr)
            return;

        BakeTitle().Text(winrt::to_hstring("Finding charts in " +
                                           std::filesystem::path(path).filename().string()));
        BakeCount().Text(L"");
        BakeEta().Text(L"");
        BakeBar().IsIndeterminate(true);
        BakePanel().Visibility(Visibility::Visible);

        /* The scan reads only an archive's central directory (about 8 ms for
         * NOAA's 27,680 entries), so it is quick enough to do inline — and it
         * MUST be, because the two scan entry points share one buffer in the
         * core and are not reentrant. */
        auto scan = lkw::ScanCharts(path);
        if (!scan.ok)
        {
            BakePanel().Visibility(Visibility::Collapsed);
            return;
        }

        /* Nothing raw: these are charts already, so open them and skip the bake
         * entirely. */
        if (scan.sources == 0)
        {
            BakePanel().Visibility(Visibility::Collapsed);
            std::vector<std::string> baked;
            for (auto const &c : scan.cells)
                if (!c.NeedsPrepare())
                    baked.push_back(c.path);
            if (baked.empty())
                baked = lkw::CellsFor(path);
            OpenPaths(baked, path);
            return;
        }

        bake_job = std::make_unique<lkw::BakeJob>();
        if (!bake_job->Start(scan, path, BakeOutputDir()))
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
        auto finished = bake_job->Finished();
        bake_job.reset();
        BakePanel().Visibility(Visibility::Collapsed);

        /* Open the whole set at once. Handing each batch over as it finished put
         * a chart up sooner and cost about half the machine, rebuilding the
         * ownership partition over a growing library every time. */
        if (finished.empty())
            finished = lkw::CollectCells(BakeOutputDir());
        if (!finished.empty())
            OpenPaths(finished, bake_source);
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
}
