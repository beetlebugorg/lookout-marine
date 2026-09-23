// Setup's NOAA half: the service's state, the download and its end, the
// picker's Apply and removal, and the prices of the regions.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <winrt/Microsoft.UI.Xaml.Documents.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cwchar>
#include <filesystem>
#include <limits>
#include <set>
#include <system_error>

#include "lk_bake.h"
#include "lk_firstrun.h"
#include "lk_chrome.h"
#include "lk_format.h"
#include "lk_paths.h"
#include "FirstRunParts.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace lkw::setup;

namespace winrt::LookoutMarine::implementation
{
    // Get charts from NOAA, in the Charts pane. It opens the coverage step on
    // its own over the chart, so the picker, the download and the prepare
    // are the same code setup runs.
    void MainWindow::ShowNoaaPicker()
    {
        CloseSettings();
        noaa_region_id.clear();
        noaa_picked_seeded = false;
        noaa_held_at_open.clear();
        lookout_noaa_refresh(noaa.handle());
        first_run.Restart();
        SetupAct(LOOKOUT_SETUP_BEGIN_PICKER, LOOKOUT_SETUP_STEP_COVERAGE);
        FirstRunRender();
    }

    // ---- the NOAA service and the setup clock ------------------------------

    // The service queued a response, or the readout tick came round. Read its
    // state only when lookout_noaa_changed returns 1.
    void MainWindow::NoaaChanged()
    {
        bool const changed = noaa.Adopt();
        lookout_noaa_state const &st = noaa.state();
        // The update check ends with its catalog read, which may have ended
        // before this call.
        if (noaa.TakeCheckEnd())
            RefreshChartsPageOnChange();
        if (!changed)
            return;
        // A retry waiting on the catalog read it started.
        if (noaa.TakeRetry())
        {
            noaa.Retry(lkw::NoaaDownloadDir());
            NoaaChanged();
            return;
        }

        // The delete behind an apply, for the removal panel. When it ends the
        // core drops its counts, so the note reads the total the job holds.
        if (removal_from_noaa && removal_job != nullptr)
        {
            if (st.removing)
            {
                removal_job->Count(st.remove_total);
                for (uint32_t d = removal_job->Snapshot().done; d < st.remove_done; ++d)
                    removal_job->Step();
            }
            else
            {
                removal_from_noaa = false;
                removal_job->Finish(
                    winrt::to_string(lkw::RemovalNote(removal_job->Snapshot().total, 0)));
            }
        }

        // The end of the run being followed, which comes after the core's
        // prepare. The library opens when the rescan the prepare asked for
        // ends. A run that prepared no chart ends the Preparing step when
        // setup is up. Otherwise a failure, and a refusal that a retry can
        // clear, show an error.
        if (noaa.TakeEnd())
        {
            if (st.outcome == LOOKOUT_NOAA_FINISHED ||
                (st.outcome == LOOKOUT_NOAA_CANCELLED && st.done > 0))
            {
                AwaitSetScan(lkw::NoaaDownloadDir(), false);
                LoadChartSets([this] { FinishPendingSet(); });
            }
            else if (!first_run.showing() &&
                     (st.outcome == LOOKOUT_NOAA_FAILED || (st.outcome == LOOKOUT_NOAA_REFUSED && st.retry)))
                ShowNoaaError(winrt::to_hstring(st.error[0] != '\0'
                                                    ? st.error
                                                    : "The download stopped before any chart arrived."),
                              st.retry != 0);
        }

        if (first_run.showing())
            FirstRunPoll();
        PollNoaaPane();
    }

    // Order a download of `regions` into the download set, or an update when
    // `regions` is empty, and follow the run it starts.
    void MainWindow::NoaaDownload(std::string const &regions, bool again)
    {
        noaa.Order(regions, again, lkw::NoaaDownloadDir());
        NoaaChanged();
    }

    void MainWindow::NoaaConsiderUpdateCheck()
    {
        noaa.ConsiderUpdateCheck();
        NoaaChanged();
    }

    // Retry repeats the order. With no catalog loaded it reads the catalog
    // first, and NoaaChanged repeats the order when the catalog arrives.
    fire_and_forget MainWindow::ShowNoaaError(winrt::hstring msg, bool retry)
    {
        auto lifetime = get_strong();
        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(winrt::box_value(L"NOAA Charts"));
        dialog.Content(winrt::box_value(msg));
        if (retry)
            dialog.PrimaryButtonText(L"Retry");
        dialog.CloseButtonText(L"OK");
        if (co_await dialog.ShowAsync() != Controls::ContentDialogResult::Primary)
            co_return;
        noaa.Retry(lkw::NoaaDownloadDir());
        NoaaChanged();
    }

    // Whether the setup clock has anything to watch, and the timer started or
    // stopped to match: the set scan the library opens after. NoaaChanged
    // follows the service, and its prepare, itself.
    void MainWindow::FirstRunPollAsNeeded()
    {
        bool const want = first_run.showing() && !pending_set.empty();
        if (want)
            FirstRunPollStart();
        else if (first_run_timer != nullptr)
            first_run_timer.Stop();
    }

    void MainWindow::FirstRunPollStart()
    {
        if (first_run_timer == nullptr)
        {
            first_run_timer = DispatcherTimer();
            first_run_timer.Interval(std::chrono::milliseconds(250));
            first_run_timer.Tick([this](auto &&, auto &&) { FirstRunPoll(); });
        }
        first_run_timer.Start();
    }

    void MainWindow::FirstRunPoll()
    {
        // PollChartSets runs here while setup holds the screen and the
        // readout tick is stopped.
        PollChartSets();

        lkw::FirstRunLive live;
        live.downloading = noaa.state().phase == LOOKOUT_NOAA_DOWNLOADING;
        live.fetched     = noaa.state().done;
        live.expected    = noaa.state().total;

        // The core's prepare of the download, by usage band, coarse first.
        live.baking = noaa.state().preparing != 0;
        live.found  = noaa.state().to_prepare;
        live.baked  = noaa.state().prepared;
        for (int b = 0; b < 6; ++b)
            if (noaa.state().band_total[b] > 0)
                live.bands.push_back({ b + 1, lkw::FirstRunBandName(b + 1),
                                       noaa.state().band_done[b], noaa.state().band_total[b] });

        first_run.Observe(live);
        SetupNote();

        // The Preparing step moves four times a second. Its values are
        // restated; it is built again only when its shape changes, which is
        // the bands arriving and the Stop button going.
        if (first_run.step() == lkw::FirstRunStep::Importing)
        {
            if (FirstRunImportingShape() != first_run_importing_shape)
                FirstRunRender();
            else
                FirstRunRestate();
        }

        // The catalog lands on its own, and the coverage map's boxes, the
        // prices and whether a region can be picked at all come from it. So
        // the step follows it once, when it changes. Rendering on every tick
        // would rebuild the map four times a second.
        if (first_run.step() == lkw::FirstRunStep::Coverage)
        {
            std::string now = NoaaCatalogSignature();
            if (now != noaa_catalog_drawn)
            {
                noaa_catalog_drawn = now;
                FirstRunRender(); // which sets the clock again
                return;
            }
        }
        // Nothing left to watch: stop rather than tick over finished work.
        FirstRunPollAsNeeded();
    }

    // Whether every chart the pick covers is installed already. The cost call
    // leaves held cells out, so it prices nothing when there is nothing new.
    bool MainWindow::NoaaAllHeld()
    {
        if (noaa_region_id.empty() || controller == nullptr)
            return false;
        uint32_t cells = 0, held = 0;
        uint64_t bytes = 0, held_bytes = 0;
        if (!lookout_noaa_cost(noaa.handle(), noaa_region_id.c_str(), &cells, &bytes, &held,
                                     &held_bytes))
            return false;
        return cells == 0 && held > 0;
    }

    // ---- the picker's two halves ------------------------------------------

    // The regions ticked when the picker opened and unticked since.
    std::vector<std::string> MainWindow::NoaaRemoving()
    {
        if (!first_run.picker_only())
            return {};
        return lkw::Removed(noaa_held_at_open, noaa_region_id);
    }

    std::vector<std::wstring> MainWindow::NoaaRegionNames(std::vector<std::string> const &ids)
    {
        std::vector<std::wstring> out;
        lookout_noaa_region const *regions = nullptr;
        size_t const n = lookout_noaa_regions(&regions);
        for (auto const &id : ids)
            for (size_t i = 0; i < n && regions != nullptr; ++i)
                if (id == regions[i].id)
                    out.push_back(std::wstring{ winrt::to_hstring(regions[i].name) });
        return out;
    }

    // Apply: give back what was unticked, then fetch what was ticked.
    void MainWindow::FirstRunApply()
    {
        auto const gone = NoaaRemoving();
        if (gone.empty())
        {
            FirstRunPrimary(); // adding only, which is the flow's own path
            return;
        }
        // Deleting charts is asked about. Adding them is not: it costs time
        // and disk, and the line beside the button says how much of both.
        FirstRunConfirmRemoval(gone, lkw::RemovalTitle(NoaaRegionNames(gone)));
    }

    fire_and_forget MainWindow::FirstRunConfirmRemoval(std::vector<std::string> gone,
                                                       std::wstring title)
    {
        auto lifetime = get_strong();
        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(box_value(winrt::hstring{ title }));
        dialog.Content(box_value(winrt::hstring{
            L"Lookout deletes the charts it downloaded for this water. Charts you added "
            L"yourself stay where they are, and you can download this water again." }));
        dialog.PrimaryButtonText(L"Remove");
        dialog.CloseButtonText(L"Cancel");
        auto result = co_await dialog.ShowAsync();
        if (result != Controls::ContentDialogResult::Primary)
            co_return;

        // With water to fetch, the flow's own path applies the pick, which
        // gives back the unticked water and downloads the rest.
        uint32_t cells = 0;
        if (!noaa_region_id.empty())
            lookout_noaa_cost(noaa.handle(), noaa_region_id.c_str(), &cells, nullptr, nullptr, nullptr);
        if (cells > 0)
        {
            FirstRunPrimary();
            co_return;
        }
        uint32_t const moved = NoaaApply(noaa_region_id, false);
        // Nothing to fetch: the picker has done what it was opened for.
        SetupAct(LOOKOUT_SETUP_LATER, 0);
        FirstRunRender();

        // Nothing matched: the page has the same line, but the picker just
        // closed the settings window, so it would be said to an empty screen.
        // Every other outcome reports inline, where the other shells report
        // it (lkw::RemovalNote).
        if (moved == 0)
            FirstRunSayRemoval(lkw::RemovalNote(0, 0));
    }

    // Make the download hold `picked`, through lookout_noaa_apply: the core
    // deletes the water given back and downloads what the pick lacks. The
    // removal panel follows the delete through the state's remove counts.
    //
    // The chart handle closes first when water goes back, because Windows
    // does not rename a directory while a file in it is mapped.
    uint32_t MainWindow::NoaaApply(std::string const &picked, bool again)
    {
        auto const gone = NoaaRemoving();
        std::wstring water = picked.empty() ? L"NOAA" : L"";
        for (auto const &one : NoaaRegionNames(gone))
            water += (water.empty() ? L"" : L", ") + one;
        if (!gone.empty())
            CloseChartHandle();

        uint32_t const moved = noaa.Apply(picked, again, lkw::NoaaDownloadDir());
        if (moved > 0)
        {
            removal_job = std::make_shared<lkw::RemovalJob>();
            removal_job->Begin(winrt::to_string(water), moved);
            removal_from_noaa = true;
        }
        NoaaChanged();
        noaa_held_at_open = picked; // the removal has run
        FirstRunRepriceRegions();
        if (!gone.empty())
            ReopenChartSets({});
        return moved;
    }

    // One line about a removal, when there is something to say.
    fire_and_forget MainWindow::FirstRunSayRemoval(std::wstring says)
    {
        auto lifetime = get_strong();
        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(box_value(L"Remove charts"));
        dialog.Content(box_value(winrt::hstring{ says }));
        dialog.CloseButtonText(L"OK");
        co_await dialog.ShowAsync();
    }

    // What the coverage step draws from. The counters of a download are left
    // out: they move every tick and the step states them from its own poll.
    std::string MainWindow::NoaaCatalogSignature()
    {
        lookout_noaa_state const &st = noaa.state();
        return std::to_string(st.phase) + "|" + std::to_string(st.have_catalog) + "|" +
               std::to_string(st.catalog_cells) + "|" + st.date + "|" + st.error;
    }

    // What of each region the download holds, for the pills, and the regions
    // the core recorded as downloaded, comma separated, which the picker opens
    // ticked. The core counts only the managed set's prepared charts, so an
    // archive that lists every cell does not read as every region held.
    std::string MainWindow::FirstRunRepriceRegions()
    {
        noaa_region_hold.clear();
        std::string recorded;
        lookout_noaa_region const *regions = nullptr;
        size_t const n = lookout_noaa_regions(&regions);
        for (size_t i = 0; i < n && regions != nullptr; ++i)
        {
            lookout_noaa_region_info info{};
            if (!lookout_noaa_region_state(noaa.handle(), regions[i].id, &info) || info.cells == 0)
                continue;
            noaa_region_hold.push_back(
                { regions[i].id, lkw::RegionHold{ info.cells - info.held, info.held } });
            if (info.recorded)
                recorded += (recorded.empty() ? "" : ",") + std::string(regions[i].id);
        }
        return recorded;
    }
}
