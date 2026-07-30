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
    void MainWindow::RebuildOpenFlyout()
    {
        Controls::MenuFlyout fly;
        Controls::MenuFlyoutItem file;
        file.Text(L"Open Chart…");
        file.Click([this](auto &&, auto &&) { PickChartFile(); });
        fly.Items().Append(file);
        Controls::MenuFlyoutItem folder;
        folder.Text(L"Open Folder…");
        folder.Click([this](auto &&, auto &&) { PickChartFolder(); });
        fly.Items().Append(folder);

        char **recents = lk_store_load_recents();
        if (recents != nullptr && recents[0] != nullptr)
        {
            fly.Items().Append(Controls::MenuFlyoutSeparator{});
            for (int i = 0; recents[i] != nullptr; ++i)
            {
                std::string path = recents[i];
                std::string name = std::filesystem::path(path).filename().string();
                if (name.empty())
                    name = path;
                Controls::MenuFlyoutItem item;
                item.Text(winrt::to_hstring(name));
                item.Click([this, path](auto &&, auto &&) { OpenPaths(lkw::CellsFor(path), path); });
                fly.Items().Append(item);
            }
        }
        lk_store_free_recents(recents);

        fly.ShowAt(LayersBtn());
    }

    void MainWindow::TryOpen()
    {
        if (open_attempted || controller == nullptr)
            return;
        if (Root().ActualWidth() < 2 || Root().ActualHeight() < 2)
            return; // pre-layout; retried from the Rendering tick
        open_attempted = true;

        auto paths = lkw::InitialPaths();
        if (paths.empty())
        {
            EmptyState().Visibility(Visibility::Visible);
            return;
        }
        OpenPaths(paths, {});
    }

    void MainWindow::OpenPaths(std::vector<std::string> const &paths, std::string const &recent)
    {
        if (paths.empty() || controller == nullptr)
            return;
        if (!recent.empty())
            lk_store_note_recent(recent.c_str());

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
            EmptyState().Visibility(Visibility::Collapsed);
            warmup_frames.store(30);
            StartRenderThread();
            UpdateReadouts(true);
            if (GetEnvironmentVariableA("LOOKOUT_OPEN_SETTINGS", nullptr, 0) > 0)
                ToggleSettings(); // screenshot/dev hook
        }
        else
        {
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
        auto file = co_await picker.PickSingleFileAsync();
        if (file != nullptr)
        {
            std::string path = winrt::to_string(file.Path());
            OpenPaths({ path }, path);
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
            std::string path = winrt::to_string(folder.Path());
            OpenPaths(lkw::CollectCells(path), path);
        }
    }
}
