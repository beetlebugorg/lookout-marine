// The startup loader: launch → first frame as one continuous surface, with a
// named phase so a long open reads as progress, not a hang. Mirrors
// StartupLoader in HUDOverlay.swift (macOS/iOS) and Hud.kt (Android):
//   1. "Baking the symbol atlas"     — first run only (atlas cache cold)
//   2. "Mapping N cells"             — while the synchronous open runs
//   3. "Tessellating the first scene" — until the first build settles
#include "pch.h"
#include "MainWindow.xaml.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::ShowStartupLoader(size_t cells)
    {
        if (!lk_controller_atlas_ready())
        {
            LoaderPhase().Text(L"Baking the symbol atlas");
            LoaderNote().Text(L"First launch only. The atlas is cached.");
            LoaderNote().Visibility(Visibility::Visible);
        }
        else
        {
            if (cells > 1)
            {
                wchar_t t[48];
                swprintf_s(t, L"Mapping %zu cells", cells);
                LoaderPhase().Text(t);
            }
            else
            {
                LoaderPhase().Text(L"Mapping the chart");
            }
            LoaderNote().Visibility(Visibility::Collapsed);
        }
        StartupLoader().Visibility(Visibility::Visible);
    }

    void MainWindow::SetLoaderTessellating()
    {
        LoaderPhase().Text(L"Tessellating the first scene");
        LoaderNote().Visibility(Visibility::Collapsed);
        loader_waiting = true;
        loader_saw_building = false;
        loader_idle_ticks = 0;
    }

    void MainWindow::HideStartupLoader()
    {
        StartupLoader().Visibility(Visibility::Collapsed);
        loader_waiting = false;
    }

    // Called at the ~10 Hz readout tick: the loader stands until the first
    // scene has actually built. A tiny cached scene may never report
    // building, so a short quiet run also releases it.
    void MainWindow::LoaderTick(int building)
    {
        if (!loader_waiting)
            return;
        if (building)
        {
            loader_saw_building = true;
            loader_idle_ticks = 0;
            return;
        }
        if (loader_saw_building || ++loader_idle_ticks >= 8)
            HideStartupLoader();
    }
}
