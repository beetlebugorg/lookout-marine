#pragma once
#include "MainWindow.g.h"

#include "lk_controller.h"
#include "lk_pick.h"
#include "lk_discovery.h"
#include "lk_plugin_model.h"

#include <atomic>
#include <string>
#include <thread>
#include <functional>
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
        // Centre the chart on a vessel a table row named (follow comes off
        // first). Public: the table windows live outside this class.
        void RevealOnChart(double lon, double lat);

    private:
        void WireChrome();
        void ToggleSettings();
        void LoadSettings();      // reads the live mariner state, shows the current tab
        // the menu bubble (MainWindow.Menu.cpp): built fresh on every press,
        // because most of it names things that come and go
        void ShowMainMenu();
        Microsoft::UI::Xaml::Controls::MenuFlyoutItem MenuItem(
            winrt::hstring const &label, winrt::hstring const &chord,
            std::function<void()> action);
        Microsoft::UI::Xaml::Controls::MenuFlyoutSubItem ChartMenu();
        Microsoft::UI::Xaml::Controls::MenuFlyoutSubItem VesselsMenu();
        void ToggleFullScreen(); // F11
        bool full_screen{ false };

        void BuildSettingsTabs(); // the section list; plugin sections come and go
        // The settings live in their own window (see MainWindow.Settings.cpp).
        void ShowSettings();
        void CloseSettings();
        bool SettingsOpen();
        void DetachSettingsPane(); // move the markup out of the chart's tree
        // Every window this app opens wears the app's mark.
        static void ApplyWindowIcon(HWND hwnd);
        Microsoft::UI::Xaml::XamlRoot DialogRoot(); // the window a dialog belongs to
        void BuildSettingsPage(); // rebuilds the rows for the selected tab
        void ScheduleApply();     // 60 ms debounce, then set + save
        // wasm plugin settings (MainWindow.Plugins.cpp)
        bool ReadPluginRegistry(std::vector<lkw::PluginInfo> &out);
        void ReloadPlugins();
        bool RefreshPluginStatus();
        void StartPluginStatusPoll();
        void StopPluginStatusPoll();
        // The plugin's own status line, and the state word behind its colour.
        std::string PluginStatusLine(lkw::PluginInfo const &p, std::string *state_out);
        bool PluginTabPopulated(std::string const &tab);
        void BuildPluginSections(std::string const &tab);
        void BuildPluginsPage();
        void BuildPluginRow(Microsoft::UI::Xaml::Controls::StackPanel const &stack,
                            lkw::PluginInfo &p, lkw::PluginList const &list,
                            std::string const &row_id);
        std::string PluginConfigJson(lkw::PluginInfo const &p);
        void SchedulePluginApply();
        lkw::PluginInfo *FindPlugin(std::string const &id);
        lkw::PluginCell *FindCell(std::string const &plugin_id, std::string const &list_key,
                                  std::string const &row_id, std::string const &key);
        void SetPluginValue(std::string const &plugin_id, std::string const &key, double v);
        void ResetPluginGroup(std::string const &plugin_id, std::vector<std::string> const &keys,
                              std::vector<double> const &defaults);
        void SetPluginCellText(std::string const &plugin_id, std::string const &list_key,
                               std::string const &row_id, std::string const &key,
                               std::string const &text);
        void SetPluginCellNumber(std::string const &plugin_id, std::string const &list_key,
                                 std::string const &row_id, std::string const &key, double value);
        void SetPluginCellToggle(std::string const &plugin_id, std::string const &list_key,
                                 std::string const &row_id, std::string const &key, bool on);
        void AddPluginRow(std::string const &plugin_id, std::string const &list_key);
        void AddPluginRowFrom(std::string const &plugin_id, std::string const &list_key,
                              lkw::Discovered const &found);
        std::vector<lkw::Discovered> NearbyFor(lkw::PluginInfo const &p,
                                               lkw::PluginList const &list);
        void StartPluginDiscovery();
        void StopPluginDiscovery();
        void RemovePluginRow(std::string const &plugin_id, std::string const &list_key,
                             std::string const &row_id);
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
        // overlay bubbles, position source, follow lock (MainWindow.Overlay.cpp)
        bool TryPinOverlayAt(double x, double y); // a tap; true = it took it
        void UpdateOverlayBubble();               // per readout tick
        void CloseOverlayBubble();
        void HoverProbe(double x, double y);
        void UpdateGpsPill();
        void UpdateFollowLock();
        void CycleFollowLock();
        void OpenSettingsTab(std::string const &id); // MainWindow.Settings.cpp

        // plugin install + file routing (MainWindow.PluginInstall.cpp)
        fire_and_forget InstallPluginFromPath(std::string path); // consent first
        fire_and_forget PickPluginFile();
        fire_and_forget ShowPluginError(winrt::hstring msg);
        void OpenDroppedPath(std::string const &path);
        fire_and_forget HandleDrop(Microsoft::UI::Xaml::DragEventArgs e);
        fire_and_forget ConfirmUninstallPlugin(std::string id, std::string name);

        // plugin tables (MainWindow.Vessels.cpp)
        void RefreshPluginTables(); // re-read the declarations at open
        void OpenPluginTable(lkw::TableSpec const &spec);
        void CloseVesselWindows(); // the tables belong to the chart handle

        // plugin alerts (MainWindow.Alerts.cpp)
        void StartAlertWatch();     // 1 s poll, independent of any pane
        void StopAlertWatch();
        void RefreshAlerts();
        void RebuildAlertStrip();
        void AcknowledgeAlert(unsigned long long id);
        void SirenSetSounding(bool on);
        void SirenStrike();

        // raster underlay (MainWindow.Raster.cpp)
        void InstallStoredRasters();  // re-add the stored list after each open
        void AddRasterPaths(std::vector<std::string> const &paths);
        fire_and_forget AddRasterFiles();
        fire_and_forget AddRasterFolder();
        void CycleRaster();           // Ctrl+I; opens the picker when none installed
        void ShowRasterMenu();
        void UpdateRasterPill(lk_readout const &r);
        fire_and_forget ShowRasterError(winrt::hstring msg);
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

        // the declared plugin tables, refreshed at every chart open
        std::vector<lkw::TableSpec> tables;

        // overlay bubble + hover + readout-pill change detection
        std::string overlay_pin_id;   // "" = no bubble pinned
        std::string overlay_pin_info; // last payload built, to skip rebuilds
        std::string hover_payload;
        long long hover_qpc{ 0 };
        int fix_state_shown{ -2 };    // -2 = never drawn
        int follow_state_shown{ -1 };

        // plugin alert state. severity: 2 alarm, 1 warning, 0 notice — an
        // unknown word reads as alarm, because silence is never the fallback.
        struct AlertItem
        {
            unsigned long long id;
            int severity;
            std::wstring title, body;
            bool acknowledged;
        };
        std::vector<AlertItem> alerts;
        long long alert_seq{ -1 };  // -1 forces the next read to rebuild
        Microsoft::UI::Xaml::DispatcherTimer alert_timer{ nullptr };
        Microsoft::UI::Xaml::DispatcherTimer siren_timer{ nullptr };
        bool siren_on{ false };

        // raster underlay state: the installed paths in the order added,
        // rebuilt from the store at every open (the sources are attached to
        // the lookout handle the open destroyed). UI thread only.
        std::vector<std::string> raster_paths;
        std::wstring raster_pill_shown; // change-detect: last pill text ("" = hidden)

        // startup loader state
        bool open_pending{ false };      // an OpenPaths is deferred/running
        bool loader_waiting{ false };    // loader up, waiting on the first build
        bool loader_saw_building{ false };
        int loader_idle_ticks{ 0 };

        // settings form
        tile57_mariner pending{};
        bool settings_loading{ false };
        // The section list is a slot list, not a fixed menu: the app's own
        // sections are always there, and Vessels, Alarms and Connections
        // appear only while a plugin puts something in them. `settings_tab`
        // indexes it.
        struct SettingsTab
        {
            std::string id;      // the core's section name, so a plugin and this agree
            std::wstring label;
            std::wstring glyph;  // the section's mark in the list
        };
        std::vector<SettingsTab> settings_tabs;
        int settings_tab{ 0 };
        Microsoft::UI::Xaml::Window settings_window{ nullptr };
        Microsoft::UI::Xaml::DispatcherTimer apply_timer{ nullptr };

        // wasm plugin settings. The schemas are read when the pane opens; only
        // the status lines are polled after that.
        std::vector<lkw::PluginInfo> plugins;
        Microsoft::UI::Xaml::DispatcherTimer plugin_apply_timer{ nullptr };
        Microsoft::UI::Xaml::DispatcherTimer plugin_poll_timer{ nullptr };
        // What is answering on the boat's network, browsed only while the
        // settings window is up.
        lkw::Discovery discovery;
        // The generation of finds the pane last drew, so the status poll knows
        // when something new answered.
        uint64_t discovery_drawn{ 0 };

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
