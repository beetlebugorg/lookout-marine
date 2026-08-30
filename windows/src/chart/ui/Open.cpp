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
        // picker makes, so a scripted run exercises the real path — which is
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

        // The sets aboard decide the startup open: the UNION of the
        // switched-on ones. With none saved (or none answering — a drive not
        // plugged in), fall through to the recents-based walk.
        LoadChartSets([this] {
            auto set_paths = ChartSetOpenPaths();
            if (!set_paths.empty())
            {
                OpenPaths(set_paths, set_paths.front(), lkw::AgencyForCells(set_paths));
                return;
            }
            std::string source;
            auto paths = lkw::InitialPaths(&source);
            if (paths.empty())
            {
                EmptyState().Visibility(Visibility::Visible);
                return;
            }
            // Name the set by who made the charts ("NOAA"), not by where the
            // bake happened to put them ("Charts").
            OpenPaths(paths, source, lkw::AgencyForCells(paths));
        });
    }

    // The open itself is synchronous on the UI thread (the core mmaps and
    // builds its device), so the loader is shown first and the real open is
    // deferred one timer tick — XAML gets a frame to paint the loader card
    // before the thread blocks.
    void MainWindow::OpenPaths(std::vector<std::string> const &paths, std::string const &recent,
                               std::string const &label)
    {
        if (paths.empty() || controller == nullptr || open_pending)
            return;
        open_pending = true;
        ShowStartupLoader(paths.size());

        // The handler holds the timer so it survives this scope, and the
        // registration is REMOVED when it fires — Stop() alone leaves the
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

    void MainWindow::DoOpenPaths(std::vector<std::string> const &paths, std::string const &recent,
                                 std::string const &label)
    {
        if (!recent.empty())
            lk_store_note_recent(recent.c_str());
        // What Settings ▸ Charts names as open: the office whose charts these
        // are when the caller worked that out ("NOAA"), else the folder or
        // file the user chose, else the first cell (a startup open).
        open_chart_label = !label.empty() ? label : !recent.empty() ? recent : paths.front();

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

        if (OpenChart(paths))
        {
            InstallStoredRasters(); // the open destroyed the handle they rode on
            RestoreRasterShown();   // which sets were drawn, and the ENC-hidden switch
            StartAlertWatch();      // a collision alarm must not need a pane open
            // A folder the mariner opened is aboard: it joins the set list
            // (an existing entry keeps its switch). A single file or a cell
            // path is not a folder and adopts nothing.
            AdoptChartSet(recent);
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
            // needs — a style url or file drawn at launch with nobody
            // clicking.
            ChartLinksAttach();
            {
                char spec[2048];
                DWORD link_n = GetEnvironmentVariableA("LOOKOUT_CHART_LINK", spec, sizeof spec);
                if (link_n > 0 && link_n < sizeof spec && spec[0] != '\0')
                    AddChartLink(spec);
            }
            RefreshPluginTables();  // the Vessels menu follows the declarations
            EmptyState().Visibility(Visibility::Collapsed);
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
            ApplyDevHooks();
        }
        else
        {
            HideStartupLoader();
            EmptyState().Visibility(Visibility::Visible);
            // Nothing to read out, so nothing to poll for.
            readout_timer.Stop();
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
        auto file = co_await picker.PickSingleFileAsync();
        if (file != nullptr)
        {
            std::string path = winrt::to_string(file.Path());
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
