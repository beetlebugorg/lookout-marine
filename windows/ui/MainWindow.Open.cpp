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

#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

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

        std::string source;
        auto paths = lkw::InitialPaths(&source);
        if (paths.empty())
        {
            EmptyState().Visibility(Visibility::Visible);
            return;
        }
        // Name the set by who made the charts ("NOAA"), not by where the bake
        // happened to put them ("Charts").
        OpenPaths(paths, source, lkw::AgencyForCells(paths));
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

        Microsoft::UI::Xaml::DispatcherTimer defer;
        defer.Interval(std::chrono::milliseconds(50));
        defer.Tick([this, paths, recent, label, defer](auto &&, auto &&) {
            defer.Stop();
            DoOpenPaths(paths, recent, label);
            open_pending = false;
        });
        defer.Start();
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
            StartAlertWatch();      // a collision alarm must not need a pane open
            RefreshPluginTables();  // the Vessels menu follows the declarations
            EmptyState().Visibility(Visibility::Collapsed);
            SetLoaderTessellating(); // the loader stands until the first build
            warmup_frames.store(30);
            StartRenderThread();
            UpdateReadouts(true);
            // Screenshot/dev hooks: the pane, and the section it opens on.
            // LOOKOUT_OPEN_SETTINGS=1 opens Display; LOOKOUT_OPEN_SETTINGS=
            // connections opens the section a plugin filled, which is where
            // a gateway is added.
            char pane[32];
            if (GetEnvironmentVariableA("LOOKOUT_OPEN_SETTINGS", pane, sizeof pane) > 0)
            {
                std::string tab = pane;
                if (tab.empty() || tab == "1")
                    ToggleSettings();
                else
                    OpenSettingsTab(tab);
            }

            // The cross-host screenshot protocol's LOOKOUT_SHOW: "pick" or
            // "pick:0.5x0.85" (a view fraction; 'x' because commas split the
            // list elsewhere), or "scale". Applied after the first scenes
            // settle, like the macOS shell's 3 s delay.
            char show[64];
            if (GetEnvironmentVariableA("LOOKOUT_SHOW", show, sizeof show) > 0)
            {
                bool pick = strncmp(show, "pick", 4) == 0;
                bool scale = strcmp(show, "scale") == 0;
                double fx = 0.5, fy = 0.5;
                if (pick && show[4] == ':')
                    sscanf_s(show + 5, "%lfx%lf", &fx, &fy);
                if (pick || scale)
                {
                    Microsoft::UI::Xaml::DispatcherTimer timer;
                    timer.Interval(std::chrono::milliseconds(3000));
                    timer.Tick([this, pick, fx, fy, timer](auto &&, auto &&) {
                        timer.Stop();
                        if (pick)
                            ShowPick(Root().ActualWidth() * fx, Root().ActualHeight() * fy);
                        else
                            ToggleScalePanel();
                    });
                    timer.Start();
                }
            }
        }
        else
        {
            HideStartupLoader();
            EmptyState().Visibility(Visibility::Visible);
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
        winrt::check_hresult(panel_native->SetSwapChain(sc));
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
