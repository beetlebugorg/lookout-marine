// Open flow: initial open, the layers flyout, the pickers, both present paths.
#include "pch.h"
#include "MainWindow.xaml.h"

#if __has_include(<microsoft.ui.xaml.media.dxinterop.h>)
#include <microsoft.ui.xaml.media.dxinterop.h>
#else
#error "microsoft.ui.xaml.media.dxinterop.h missing (ISwapChainPanelNative)"
#endif
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

        fly.Items().Append(Controls::MenuFlyoutSeparator{});
        Controls::ToggleMenuFlyoutItem dms;
        dms.Text(L"Coordinates as DMS");
        dms.IsChecked(use_dms);
        dms.Click([this](auto &&, auto &&) {
            use_dms = !use_dms;
            lk_store_save_use_dms(use_dms ? 1 : 0);
            UpdateReadouts(true);
        });
        fly.Items().Append(dms);

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
        d3d.destroy();
        if (chart_panel != nullptr)
        {
            uint32_t idx;
            if (Root().Children().IndexOf(chart_panel, idx))
                Root().Children().RemoveAt(idx);
            chart_panel = nullptr;
        }
        mode = Mode::None;

        bool force_hwnd = GetEnvironmentVariableA("LOOKOUT_FORCE_HWND", nullptr, 0) > 0;
        if ((!force_hwnd && OpenDxgi(paths)) || OpenHwnd(paths))
        {
            EmptyState().Visibility(Visibility::Collapsed);
            warmup_frames.store(180);
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

    bool MainWindow::OpenDxgi(std::vector<std::string> const &paths)
    {
        double density = Density();
        UINT wpx = (UINT)std::max(1.0, Root().ActualWidth() * density);
        UINT hpx = (UINT)std::max(1.0, Root().ActualHeight() * density);
        if (!d3d.init(wpx, hpx))
        {
            d3d.destroy();
            return false;
        }
        d3d.fill_target(&target);

        std::vector<const char *> cps;
        for (auto const &p : paths)
            cps.push_back(p.c_str());
        if (!lk_controller_open_dxgi(controller, &target, cps.data(), (int)cps.size(),
                                     (unsigned)(wpx / density), (unsigned)(hpx / density),
                                     (float)density))
        {
            d3d.destroy();
            fprintf(stderr, "shell: no DXGI interop, falling back to HWND\n");
            return false;
        }

        chart_panel = Controls::SwapChainPanel{};
        Root().Children().InsertAt(0, chart_panel);
        auto panel_native = chart_panel.as<ISwapChainPanelNative>();
        winrt::check_hresult(panel_native->SetSwapChain(d3d.swapchain));
        if (chart_hwnd != nullptr)
            ShowWindow(chart_hwnd, SW_HIDE);
        mode = Mode::Dxgi;
        fprintf(stderr, "shell: DXGI composition path up (%ux%u)\n", wpx, hpx);
        return true;
    }

    bool MainWindow::OpenHwnd(std::vector<std::string> const &paths)
    {
        EnsureChartHost();
        if (chart_hwnd == nullptr)
            return false;
        ShowWindow(chart_hwnd, SW_SHOW);

        RECT rc{};
        GetClientRect(top_hwnd, &rc);
        double density = Density();
        std::vector<const char *> cps;
        for (auto const &p : paths)
            cps.push_back(p.c_str());
        if (!lk_controller_open(controller, GetModuleHandleW(nullptr), chart_hwnd,
                                cps.data(), (int)cps.size(),
                                (unsigned)(rc.right / density), (unsigned)(rc.bottom / density),
                                (float)density))
            return false;
        // Above the XAML bridge; the inverse region cuts the chrome holes.
        SetWindowPos(chart_hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        mode = Mode::Hwnd;
        last_pieces.clear();
        return true;
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
