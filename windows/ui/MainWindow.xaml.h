#pragma once
#include "MainWindow.g.h"

#include "lk_controller.h"
#include "lk_pick.h"

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
        void OpenPaths(std::vector<std::string> const &paths, std::string const &recent);
        void DoOpenPaths(std::vector<std::string> const &paths, std::string const &recent);
        // startup loader (MainWindow.Loader.cpp)
        void ShowStartupLoader(size_t cells);
        void SetLoaderTessellating();
        void HideStartupLoader();
        void LoaderTick(int building);
        fire_and_forget PickChartFile();
        fire_and_forget PickChartFolder();
        void SubmitSearch();
        // zoom-to-scale panel (MainWindow.Scale.cpp)
        void WireScale();
        void ToggleScalePanel();
        void UpdateScalePanel(lk_readout const &r);
        void UpdateScaleValidity();
        void SubmitScale();
        void ApplyScale(double denom);
        // pick report (MainWindow.Pick.cpp)
        void WirePick();                  // static pick chrome, once, from WireChrome
        void ShowPick(double x_pt, double y_pt);
        void DismissPick();
        void SelectPickObject(int index); // rebuilds the detail column
        void PlacePickCard();             // callout above/below the mark
        void BuildPickBody();
        void CopyPickReport();
        void AddAuxFileView(Microsoft::UI::Xaml::Controls::StackPanel const &into,
                            std::string const &cell, winrt::hstring const &name);
        fire_and_forget LoadAuxImage(Microsoft::UI::Xaml::Controls::Image image,
                                     std::vector<uint8_t> bytes, winrt::hstring name);
        void ShowPicture(Microsoft::UI::Xaml::Media::ImageSource const &src,
                         winrt::hstring const &name);
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
        std::string open_chart_label; // what Settings ▸ Charts names as open

        // startup loader state
        bool open_pending{ false };      // an OpenPaths is deferred/running
        bool loader_waiting{ false };    // loader up, waiting on the first build
        bool loader_saw_building{ false };
        int loader_idle_ticks{ 0 };

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

        // pick report state
        lk_pick_feature *pick_feats{ nullptr }; // freed with lk_controller_pick_free
        int pick_count{ 0 };
        std::vector<lkw::PickDecoded> pick_decoded;
        int pick_index{ -1 };
        bool pick_fold_open{ false };
        double pick_x{ 0 }, pick_y{ 0 }; // the mark, logical points
        lk_readout pick_pose{};          // the camera pose the report describes
        bool pick_pose_valid{ false };
        // The tallest the card has stood for this pick; it never shrinks
        // below this (capped by the placement room), so the controls and the
        // chart under the pointer never move as the selection changes.
        double pick_height_floor{ 0 };
    };
}

namespace winrt::LookoutMarine::factory_implementation
{
    struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow>
    {
    };
}
