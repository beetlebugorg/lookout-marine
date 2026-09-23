// Open flow: initial open, the layers flyout, the pickers, the chart panel.
#include "pch.h"
#include "MainWindow.xaml.h"

#if __has_include(<microsoft.ui.xaml.media.dxinterop.h>)
#include <microsoft.ui.xaml.media.dxinterop.h>
#else
#error "microsoft.ui.xaml.media.dxinterop.h missing (ISwapChainPanelNative)"
#endif
#include <dxgi1_3.h>
#include <shobjidl.h>

#include <filesystem>
#include <memory>

#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    // A flag put down however the scope is left, a throw included.
    struct ClearOnExit
    {
        bool *flag;
        ~ClearOnExit()
        {
            if (flag != nullptr)
                *flag = false;
        }
    };
}

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::TryOpen()
    {
        if (open_attempted || controller == nullptr)
            return;
        if (Root().ActualWidth() < 2 || Root().ActualHeight() < 2)
            return; // pre-layout; retried from the Rendering tick
        open_attempted = true;

        // LOOKOUT_IMPORT=<folder|.zip> drives the import at startup, the way
        // LOOKOUT_OPEN drives the open. It is the same call the Open Charts
        // picker makes, so a scripted run exercises the real path, which is
        // the only way to test an import on a machine where nobody can click.
        {
            char env[1024];
            DWORD n = GetEnvironmentVariableA("LOOKOUT_IMPORT", env, sizeof env);
            if (n > 0 && n < sizeof env)
            {
                ImportCharts(env);
                return;
            }
        }

        // The installed sets decide the startup open: the UNION of the
        // switched-on ones. With none saved (or none answering: a drive not
        // plugged in), fall through to the recents-based walk.
        LoadChartSets([this] {
            auto set_paths = sets.Compose();
            sets.opened = set_paths;
            if (!set_paths.empty())
            {
                OpenPaths(set_paths, set_paths.front(), lkw::AgencyForCells(set_paths));
                return;
            }
            std::string source;
            char **recents = lk_store_load_recents();
            char const *most_recent =
                recents != nullptr && recents[0] != nullptr ? recents[0] : nullptr;
            auto paths = lkw::InitialPaths(most_recent, &source);
            lk_store_free_recents(recents);
            if (paths.empty())
            {
                // Nothing configured to open. Setup is where an empty chart
                // area goes, on this launch and every later one that finds it
                // empty (T-005), with the basemap drawing behind it.
                OpenBasemapForSetup();
                return;
            }
            // Name the set by who made the charts ("NOAA"), not by where the
            // bake happened to put them ("Charts").
            OpenPaths(paths, source, lkw::AgencyForCells(paths));
        });
    }

    // The open itself is synchronous on the UI thread (the core mmaps and
    // builds its device), so the loader is shown first and the real open is
    // deferred one timer tick: XAML gets a frame to paint the loader card
    // before the thread blocks.
    void MainWindow::OpenPaths(std::vector<std::string> const &paths, std::string const &recent,
                               std::string const &label)
    {
        if (paths.empty() || controller == nullptr || open_pending)
        {
            // An open that does not happen leaves no rescan to ask for.
            open_after_write = false;
            return;
        }
        open_pending = true;
        // The loader stands over the setup card, which is up for the open that
        // ends an import: the card went behind it and came back when the open
        // finished. The Preparing step reports that work itself.
        if (!first_run.showing())
            ShowStartupLoader(paths.size());

        // The handler holds the timer so it survives this scope, and the
        // registration is REMOVED when it fires: Stop() alone leaves the
        // handler registered, and a handler that holds its own timer is a
        // cycle nothing collects. One leaked timer per chart open, otherwise.
        auto defer = std::make_shared<Microsoft::UI::Xaml::DispatcherTimer>();
        defer->Interval(std::chrono::milliseconds(50));
        auto token = std::make_shared<winrt::event_token>();
        *token = defer->Tick([this, paths, recent, label, defer, token](auto &&, auto &&) {
            defer->Stop();
            defer->Tick(*token);
            // Cleared whatever happens: a throw out of the open must not
            // leave the flag set and refuse every open after it.
            ClearOnExit clear{ &open_pending };
            DoOpenPaths(paths, recent, label);
        });
        defer->Start();
    }

    void MainWindow::CloseChartHandle()
    {
        StopAlertWatch();     // the alerts belong to the handle this close destroys
        CloseVesselWindows(); // so do the tables
        ChartLinksDetach();   // and the chart-link fetcher
        StopRenderThread();
        lk_controller_close(controller);
        if (chart_panel != nullptr)
        {
            uint32_t idx;
            if (Root().Children().IndexOf(chart_panel, idx))
                Root().Children().RemoveAt(idx);
            chart_panel = nullptr;
        }
    }

    // Open what the switched-on sets compose. With nothing composed the chart
    // comes OFF the display: it was drawn from charts that are no longer
    // installed, and leaving it up says they still are.
    //
    // A set of pictures with no survey in it still draws, so what decides
    // whether setup comes up is whether anything at all is installed.
    void MainWindow::ReopenChartSets(std::string const &recent)
    {
        auto paths = sets.Compose();
        sets.opened = paths;
        if (!paths.empty())
        {
            OpenPaths(paths, recent.empty() ? paths.front() : recent,
                      lkw::AgencyForCells(paths));
            return;
        }

        CloseChartHandle();
        open_chart_label.clear();
        chart_has_cells = false; // the basemap draws, and no cells with it
        if (OpenChart({}))
        {
            ChartLinksAttach();
            InstallStoredRasters(); // the pictures, when they are what is left
            RestoreRasterShown();
            StartAlertWatch();
            StartRenderThread();
        }
        if (raster_paths.empty())
        {
            // A mariner who picked an online chart has a chart, so setup has no
            // reason to stand over it. The pick counts from the first frame,
            // and the style it names resolves several frames later.
            setup_nothing_to_draw = true;
            if (SetupShouldRun())
            {
                readout_timer.Stop(); // a basemap under a setup card reads out nothing
                FirstRunBegin();
            }
        }
    }

    void MainWindow::DoOpenPaths(std::vector<std::string> const &paths, std::string const &recent,
                                 std::string const &label)
    {
        if (!recent.empty())
            lk_store_note_recent(recent.c_str());
        // What Settings ▸ Charts names as open: the office whose charts these
        // are when the caller worked that out ("NOAA"), else the folder or
        // file the user chose, else the first cell (a startup open).
        open_chart_label = !label.empty() ? label : !recent.empty() ? recent : paths.front();

        CloseChartHandle();

        if (OpenChart(paths))
        {
            chart_has_cells = !paths.empty();
            setup_nothing_to_draw = paths.empty();
            InstallStoredRasters(); // the open destroyed the handle they rode on
            RestoreRasterShown();   // which sets were drawn, and the ENC-hidden switch
            NoaaConsiderUpdateCheck();
            StartAlertWatch();      // a collision alarm must not need a pane open
            // A folder the mariner opened joins the set list
            // (an existing entry keeps its switch). A single file or a cell
            // path is not a folder and adopts nothing.
            // Without a rescan: this open wrote nothing. The bake and the
            // first run ask for one through open_after_write.
            AdoptChartSet(recent, open_after_write);
            open_after_write = false;
            // What this open composed, when it composed a set. The scan that
            // lands after an import reads this: with it empty, the poll opens
            // the library a second time, and that close ends a NOAA transfer
            // in flight.
            auto composed = sets.Compose();
            if (!composed.empty() && paths == composed)
                sets.opened = composed;
            if (!pending_plugin_install.empty())
            {
                // The .lkplug that arrived at the empty state, now that a
                // plugin layer exists to inspect it.
                std::string parked = pending_plugin_install;
                pending_plugin_install.clear();
                InstallPluginFromPath(parked);
            }
            // The core reads its chart-link list at open and resolves the
            // selected one as soon as this installs the fetcher.
            // $LOOKOUT_CHART_LINK is the dev hook the screenshot protocol
            // needs: a style url or file drawn at launch with nobody
            // clicking.
            ChartLinksAttach();
            {
                char spec[2048];
                DWORD link_n = GetEnvironmentVariableA("LOOKOUT_CHART_LINK", spec, sizeof spec);
                if (link_n > 0 && link_n < sizeof spec && spec[0] != '\0')
                    AddChartLink(spec);
            }
            RefreshPluginTables();  // the Vessels menu follows the declarations
            // A chart opened. Setup is still up when this is the handover at
            // the end of its own download, and down otherwise. The chart
            // controls follow it either way: hiding them for setup and not
            // restoring them here left the mariner with a drawn chart and no
            // search, menu, zoom, gear or readout.
            FirstRunPane().Visibility(first_run.showing() ? Visibility::Visible
                                                          : Visibility::Collapsed);
            FirstRunChartChrome(!first_run.showing());
            // This open is what the Preparing step was waiting for, and it
            // lands 50 ms after the step was last stated: the open is
            // deferred, so the step said "nothing to continue to" and the
            // clock that would have said otherwise had already stopped.
            if (first_run.showing())
                FirstRunRestate();
            SetLoaderTessellating(); // the loader stands until the first build
            warmup_frames.store(30);
            StartRenderThread();
            // The readout poll runs while there is a chart to read out and
            // not before: idle means idle (app/ui/MainWindow.xaml.cpp).
            readout_timer.Start();
            UpdateReadouts();
            // The development and screenshot hooks (app/ui/DevHooks.cpp):
            // LOOKOUT_WINDOW, LOOKOUT_OPEN_SETTINGS, LOOKOUT_ADD,
            // LOOKOUT_REMOVE and LOOKOUT_SHOW. Read once, now that there
            // is a chart for them to act on.
#if defined(LOOKOUT_DEV_HOOKS)
            ApplyDevHooks();
#endif
        }
        else
        {
            HideStartupLoader();
            // The open failed or found nothing. Same page as a fresh install:
            // the source step is where a mariner re-points at their charts.
            OpenBasemapForSetup();
            // Nothing to read out, so nothing to poll for.
            readout_timer.Stop();
        }
    }

    // No chart to draw, for any reason: a fresh install, or an open that
    // returned nothing. Open the engine with no cells so the basemap draws
    // from the first frame, then put setup over it.
    //
    // Without this the mariner meets a flat empty window behind the welcome
    // card and reads the app as broken. The other shells warn about opening
    // at a chart-scale zoom over empty water. Opening nothing at all puts
    // even less on screen.
    //
    // An open with n 0 is supported. Apple uses the same path when its list
    // is empty (ChartController.swift), and the core draws its own basemap
    // on the handle it hands back.
    void MainWindow::OpenBasemapForSetup()
    {
        chart_has_cells = false;
        bool const opened = OpenChart({});
        if (!opened)
        {
            // The basemap failed to open, so setup stands over an empty view.
            // The mariner can still answer every question, and the difference
            // is a chart under the card, so log it.
            fprintf(stderr, "shell: basemap-only open failed; setup stands over an empty view\n");
        }
        if (opened)
        {
            // The chart link fetcher, before the online step resolves a style,
            // and the NOAA catalog the coverage step prices regions from.
            ChartLinksAttach();
            lookout_noaa_refresh(noaa.handle());
            StartRenderThread();
        }
        // Either way the loader comes down: there is no chart coming, and a
        // spinner over the welcome card says one is.
        HideStartupLoader();
        // The screenshot hooks apply here as well as after a chart opens.
        // $LOOKOUT_WINDOW is what makes a capture the same size on any
        // machine, and setup is a page that needs capturing. It is the page a
        // mariner with no charts sees.
#if defined(LOOKOUT_DEV_HOOKS)
        ApplyDevHooks();
#endif
        setup_nothing_to_draw = true;
        if (SetupShouldRun())
        {
            readout_timer.Stop(); // nothing to read out under a setup card
            FirstRunBegin();
        }
    }

    // The core makes its own D3D12 device and composition swapchain; the shell
    // only attaches that swapchain to a SwapChainPanel under the XAML chrome.
    bool MainWindow::OpenChart(std::vector<std::string> const &paths)
    {
        double density = Density();
        unsigned wpt = (unsigned)std::max(1.0, Root().ActualWidth());
        unsigned hpt = (unsigned)std::max(1.0, Root().ActualHeight());

        std::vector<const char *> cps;
        for (auto const &p : paths)
            cps.push_back(p.c_str());
        if (!lk_controller_open(controller, cps.data(), (int)cps.size(), wpt, hpt, (float)density))
            return false;

        auto *sc = (IDXGISwapChain *)lk_controller_swapchain(controller);
        if (sc == nullptr)
        {
            lk_controller_close(controller);
            return false;
        }
        chart_panel = Controls::SwapChainPanel{};
        Root().Children().InsertAt(0, chart_panel);
        auto panel_native = chart_panel.as<ISwapChainPanelNative>();
        // Not check_hresult: this can run inside a DispatcherTimer tick, where
        // a throw (device removed at exactly this moment) is uncaught and
        // takes the app down. A failed attach is an ordinary failed open.
        if (FAILED(panel_native->SetSwapChain(sc)))
        {
            uint32_t idx;
            if (Root().Children().IndexOf(chart_panel, idx))
                Root().Children().RemoveAt(idx);
            chart_panel = nullptr;
            lk_controller_close(controller);
            return false;
        }
        ApplyPanelScale();
        fprintf(stderr, "shell: D3D12 swapchain up (%u x %u pt @ %.2f)\n", wpt, hpt, density);
        return true;
    }

    // The panel's visual is scaled by the composition scale; the swapchain is
    // already in device pixels, so present it through the inverse.
    void MainWindow::ApplyPanelScale()
    {
        if (controller == nullptr)
            return;
        auto *unk = (IUnknown *)lk_controller_swapchain(controller);
        if (unk == nullptr)
            return;
        winrt::com_ptr<IDXGISwapChain2> sc2;
        if (SUCCEEDED(unk->QueryInterface(__uuidof(IDXGISwapChain2), sc2.put_void())))
        {
            float inv = (float)(1.0 / Density());
            DXGI_MATRIX_3X2_F m{ inv, 0.0f, 0.0f, inv, 0.0f, 0.0f };
            sc2->SetMatrixTransform(&m);
        }
    }

    fire_and_forget MainWindow::PickChartFile()
    {
        auto lifetime = get_strong();
        Windows::Storage::Pickers::FileOpenPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(top_hwnd);
        picker.FileTypeFilter().Append(L".pmtiles");
        // An exchange set as an agency publishes it: one .zip, baked on the way
        // in without ever being unpacked.
        picker.FileTypeFilter().Append(L".zip");
        picker.FileTypeFilter().Append(L".000");
        // A picture is a chart to the mariner who holds it, and the Charts
        // page offers one way in for everything on the disk.
        picker.FileTypeFilter().Append(L".mbtiles");
        picker.FileTypeFilter().Append(L".kap");
        picker.FileTypeFilter().Append(L".bsb");
        auto file = co_await picker.PickSingleFileAsync();
        if (file != nullptr)
        {
            std::string path = winrt::to_string(file.Path());
            // Pictures go to the underlay, which bakes a BSB/KAP sheet and
            // installs an .mbtiles as it is. The vector open has no use for
            // either.
            std::string ext = std::filesystem::path(path).extension().string();
            for (auto &c : ext)
                c = (char)tolower((unsigned char)c);
            if (ext == ".mbtiles" || lkw::IsRasterSource(path))
            {
                AddRasterPaths({ path });
                co_return;
            }
            // A .pmtiles is already a chart; a .zip or a raw cell has to bake.
            // ImportCharts tells them apart by scanning, so both routes are one.
            ImportCharts(path);
        }
    }

    fire_and_forget MainWindow::PickChartFolder()
    {
        auto lifetime = get_strong();
        Windows::Storage::Pickers::FolderPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(top_hwnd);
        picker.FileTypeFilter().Append(L"*");
        auto folder = co_await picker.PickSingleFolderAsync();
        if (folder != nullptr)
        {
            // Through the import, not straight to open: a folder the mariner
            // picks may hold raw S-57 cells, which have to bake before anything
            // can draw them. ImportCharts scans first and skips the bake when
            // the folder already holds charts.
            ImportCharts(winrt::to_string(folder.Path()));
        }
    }
}
