#pragma once
#include "MainWindow.g.h"

#include "lk_controller.h"

#include <atomic>
#include <string>
#include <thread>
#include <vector>

namespace winrt::LookoutMarine::implementation
{
    struct MainWindow : MainWindowT<MainWindow>
    {
        MainWindow();
        ~MainWindow();

        // Chart input, called from the XAML pointer handlers.
        void GesturePress(double x_pt, double y_pt, bool rotate);
        void GestureMove(double x_pt, double y_pt);
        void GestureRelease(double x_pt, double y_pt);
        void GestureWheel(double delta_notches, double x_pt, double y_pt);
        void GestureDoubleTap(double x_pt, double y_pt);
        void Command(char cmd); // keyboard commands (accelerators)

    private:
        void WireChrome();
        void ToggleSettings();
        void LoadSettings();      // reads the live mariner state, shows the current tab
        void BuildSettingsPage(); // rebuilds the rows for the selected tab
        void ScheduleApply();     // 60 ms debounce, then set + save
        void TryOpen();
        bool OpenChart(std::vector<std::string> const &paths);
        void SyncChartBounds();
        void ApplyPanelScale();
        void StartRenderThread();
        void StopRenderThread();
        void RenderLoop();
        void UpdateReadouts(bool force);
        void UpdateScaleBar(double denom);
        void RebuildOpenFlyout();
        void OpenPaths(std::vector<std::string> const &paths, std::string const &recent);
        fire_and_forget PickChartFile();
        fire_and_forget PickChartFolder();
        void SubmitSearch();
        void ShowPick(double x_pt, double y_pt);
        double Density();
        void OnRendering(Windows::Foundation::IInspectable const &,
                         Windows::Foundation::IInspectable const &);

        HWND top_hwnd{ nullptr };
        // Created in code when a chart opens; carries the core's composition
        // swapchain under the XAML chrome.
        Microsoft::UI::Xaml::Controls::SwapChainPanel chart_panel{ nullptr };
        lk_controller *controller{ nullptr };

        winrt::event_token rendering_token{};
        // Software (WARP) frames can take tens of ms: rendering runs on its
        // own thread (the core locks internally), never on the UI thread.
        std::thread render_thread;
        std::atomic<bool> render_run{ false };
        std::atomic<int> warmup_frames{ 0 }; // force presents while DWM starts composing us
        long long last_tick_qpc{ 0 };
        long long last_readout_qpc{ 0 };
        double scalebar_pt{ 0 }, scalebar_m{ 0 };
        bool open_attempted{ false };
        bool use_dms{ false };

        // settings form
        tile57_mariner pending{};
        bool settings_loading{ false };
        int settings_tab{ 0 };
        Microsoft::UI::Xaml::DispatcherTimer apply_timer{ nullptr };

        // gesture state (logical points)
        bool dragging{ false }, rotating{ false };
        double down_x{ 0 }, down_y{ 0 }, last_x{ 0 }, last_y{ 0 };
        double vx{ 0 }, vy{ 0 };
        long long last_sample_qpc{ 0 };
    };
}

namespace winrt::LookoutMarine::factory_implementation
{
    struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow>
    {
    };
}
