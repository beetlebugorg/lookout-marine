#pragma once
#include "MainWindow.g.h"

#include "lk_alerts.h"
#include "lk_bake.h"
#include "lk_controller.h"
#include "lk_pick.h"
#include "lk_discovery.h"
#include "lk_plugin_model.h"

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <set>
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

        // One tile lookout wants. Public: the C tile-provider thunk (a free
        // function — the engine takes a plain function pointer) calls it.
        void TileRequest(std::string source, uint64_t id, int z, int x, int y);

    private:
        void WireChrome();
        void ToggleSettings();
        void LoadSettings();      // reads the live mariner state, shows the current tab
        // the menu bubble (app/ui/Menu.cpp): built fresh on every press,
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
        // The settings live in their own window (see settings/ui/Settings.cpp).
        void ShowSettings();
        void CloseSettings();
        bool SettingsOpen();
        void DetachSettingsPane(); // move the markup out of the chart's tree
        // Every window this app opens wears the app's mark.
        static void ApplyWindowIcon(HWND hwnd);
        Microsoft::UI::Xaml::XamlRoot DialogRoot(); // the window a dialog belongs to
        void BuildSettingsPage(); // rebuilds the rows for the selected tab
        void RefreshBandPreview(); // redraw the depth-band legend in place
        /// The depths tab's band legend, redrawn as the contour fields
        /// change without rebuilding the page (a rebuild would steal the
        /// NumberBox focus mid-typing). Null on every other tab.
        winrt::Microsoft::UI::Xaml::Controls::Grid band_preview{ nullptr };
        /* Refresh the registered status texts and dots in place. The status
         * moves once a second while data flows; rebuilding the page for that
         * flickers every control and resets the expanders. */
        void UpdatePluginStatusUi();
        void ScheduleApply();     // 60 ms debounce, then set + save
        // wasm plugin settings (plugins/ui/PluginSettings.cpp). The registry's own
        // shape, the config object and the status lines are model code, in
        // plugins/lk_plugin_registry.h; what is left here is the drawing.
        bool ReadPluginRegistry(std::vector<lkw::PluginInfo> &out);
        void ReloadPlugins();
        bool RefreshPluginStatus();
        void StartPluginStatusPoll();
        void StopPluginStatusPoll();
        bool PluginTabPopulated(std::string const &tab);
        void BuildPluginSections(std::string const &tab);
        void BuildPluginsPage();
        void BuildPluginRow(Microsoft::UI::Xaml::Controls::StackPanel const &stack,
                            lkw::PluginInfo &p, lkw::PluginList const &list,
                            std::string const &row_id);
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
        // The LOOKOUT_* development and screenshot hooks (app/ui/DevHooks.cpp),
        // read once after the first chart is up.
        void ApplyDevHooks();
        bool OpenChart(std::vector<std::string> const &paths);
        void SyncChartBounds();
        void ApplyPanelScale();
        void StartRenderThread();
        void StopRenderThread();
        void RenderLoop();
        void UpdateReadouts();
        void UpdateScaleBar(double denom);
        // `label` is what Settings ▸ Charts calls the set ("NOAA"); the recent
        // stays a path. Empty falls back to the recent, then the first cell.
        void OpenPaths(std::vector<std::string> const &paths, std::string const &recent,
                       std::string const &label = {});
        void DoOpenPaths(std::vector<std::string> const &paths, std::string const &recent,
                         std::string const &label = {});
        // startup loader (hud/ui/Loader.cpp)
        void ShowStartupLoader(size_t cells);
        void SetLoaderTessellating();
        void HideStartupLoader();
        void LoaderTick(int building);
        fire_and_forget PickChartFile();
        fire_and_forget PickChartFolder();
        // chart import: scan, bake what is raw, then open (library/ui/Bake.cpp)
        fire_and_forget PickChartArchive();
        void ImportCharts(std::string const &path);
        /* The half of an import that runs after the scan came back. */
        void FinishImport(std::string const &path, lkw::ScanResult const &scan);
        /* Bake picked BSB/KAP sheets into the raster library, then add them to
         * the raster underlay. The same BakeJob and panel as a chart import. */
        void BakeRasterSources(std::vector<std::string> const &sources);
        /* Baked sheets join the underlay: noted for the coming open, or added
         * to the chart on screen when no open follows. */
        void AdoptBakedRasters(std::vector<std::string> const &rasters, bool opening);
        void TickBake();
        static std::string BakeOutputDir();
        void SubmitSearch();
        void UpdateSearchResults(); // the live row under the field
        // overlay bubbles, position source, follow lock (hud/ui/Overlay.cpp)
        bool TryPinOverlayAt(double x, double y); // a tap; true = it took it
        void UpdateOverlayBubble();               // per readout tick
        void CloseOverlayBubble();
        void HoverProbe(double x, double y);
        void UpdateGpsPill();
        void UpdateFollowLock();
        void CycleFollowLock();
        void OpenSettingsTab(std::string const &id); // settings/ui/Settings.cpp

        // plugin install + file routing (plugins/ui/PluginInstall.cpp)
        fire_and_forget InstallPluginFromPath(std::string path); // consent first
        // A .lkplug that arrived before any chart was open: installed (with
        // consent) the moment one is, instead of erroring at the empty state.
        std::string pending_plugin_install;
        fire_and_forget PickPluginFile();
        fire_and_forget ShowPluginError(winrt::hstring msg);
        void OpenDroppedPath(std::string const &path);
        fire_and_forget HandleDrop(Microsoft::UI::Xaml::DragEventArgs e);
        fire_and_forget ConfirmUninstallPlugin(std::string id, std::string name);

        // about and licenses (about/ui/Licenses.cpp). Both have their own
        // window: the license text runs at its own width, and About opens the
        // same licenses window rather than a second copy of the list.
        void ShowAbout();
        // The licenses window, on `id`'s entry. An empty id opens on this
        // app's own.
        void ShowLicenses(std::string const &id);
        void BuildLicensesList();
        void BuildLicensesDetail();
        // One label-and-value row of a detail pane. `literal` is a commit, a
        // path or a version: monospaced, to be read character by character.
        struct LicenseFact
        {
            std::wstring label;
            std::string value;
            bool literal;
        };
        Microsoft::UI::Xaml::Controls::Border LicenseCard(
            Microsoft::UI::Xaml::UIElement const &child);
        Microsoft::UI::Xaml::Controls::Border LicenseFacts(std::vector<LicenseFact> const &rows);
        Microsoft::UI::Xaml::Controls::Border LicenseUpstream(std::string const &url);
        Microsoft::UI::Xaml::Controls::StackPanel LicenseTextBlock(winrt::hstring const &heading,
                                                                   std::string const &note,
                                                                   std::string const &text);
        Microsoft::UI::Xaml::Window about_window{ nullptr };
        Microsoft::UI::Xaml::Window licenses_window{ nullptr };
        // The two panels the licenses window fills, null while it is closed.
        Microsoft::UI::Xaml::Controls::StackPanel licenses_list{ nullptr };
        Microsoft::UI::Xaml::Controls::StackPanel licenses_detail{ nullptr };
        // The entry on screen; empty is this app's own. Held here so About can
        // open the window on a named one.
        std::string licenses_selection;
        std::string licenses_search;

        // plugin tables (plugins/ui/Tables.cpp)
        void RefreshPluginTables(); // re-read the declarations at open
        void OpenPluginTable(lkw::TableSpec const &spec);
        void ShowTableHook(std::string const &spec); // LOOKOUT_SHOW=table[:…]
        void CloseVesselWindows(); // the tables belong to the chart handle

        // plugin alerts (plugins/ui/Alerts.cpp)
        void StartAlertWatch();     // 1 s poll, independent of any pane
        void StopAlertWatch();
        void RefreshAlerts();
        void RebuildAlertStrip();
        void AcknowledgeAlert(unsigned long long id);
        void SirenSetSounding(bool on);
        void SirenStrike();

        // raster underlay (library/ui/Raster.cpp)
        void InstallStoredRasters();  // re-add the stored list after each open
        void ForgetRasterCharts();    // clear the stored library; next open loses them
        void RestoreRasterShown();    // put back which sets were drawn, then the saved ENC-hidden
        void SaveRasterShown();       // record the engine's per-set drawn state by name
        void AddRasterPaths(std::vector<std::string> const &paths);
        fire_and_forget AddRasterFiles();
        fire_and_forget AddRasterFolder();
        void CycleRaster();           // Ctrl+I; opens the picker when none installed
        void ShowRasterMenu();
        void UpdateRasterPill(lk_readout const &r);
        fire_and_forget ShowRasterError(winrt::hstring msg);
        fire_and_forget ShowImportError(winrt::hstring msg);

        // The chart context menu and the mariner's markers (right-click).
        void ShowChartMenu(double x, double y);
        fire_and_forget RenameMarkerDialog(uint64_t id, winrt::hstring current);

        // True while the chrome wears the dark (dusk/night) dictionaries.
        // Code-built cards pick their ink through lkw::chrome::Ink(dark).
        bool DarkChrome()
        {
            return Root().ActualTheme() == Microsoft::UI::Xaml::ElementTheme::Dark;
        }

        // The chart's scheme is worn by EVERY window this app opens, not only
        // the chart (hud/ui/Hud.cpp). A window built later asks ChromeTheme()
        // for it, so one opened at night opens dark.
        Microsoft::UI::Xaml::ElementTheme ChromeTheme();
        void ApplyChromeTheme(Microsoft::UI::Xaml::ElementTheme want);
        void ApplyTableTheme(Microsoft::UI::Xaml::ElementTheme want);   // plugins/ui/Tables.cpp
        void ThemeSettingsPane(Microsoft::UI::Xaml::ElementTheme want); // settings/ui/Settings.cpp

        // ---- chart sets (the folders of charts aboard) ----------------------
        // A set is a folder — the baked library, a folder of .pmtiles, a
        // folder of pictures — with an on/off switch. What opens is the UNION
        // of the switched-on sets. Mirrors the macOS "sets aboard" model.
        struct ChartSetRow
        {
            std::string path;
            bool on{ true };
            std::vector<std::string> cells;
            std::vector<std::string> rasters;
            std::string title; // the agency whose charts these are, else the folder
        };
        void LoadChartSets(std::function<void()> then);
        std::vector<std::string> ChartSetOpenPaths() const;
        void AdoptChartSet(std::string const &path);
        void SetChartSetOn(std::string const &path, bool on);
        void RemoveChartSet(std::string const &path);
        std::vector<ChartSetRow> chart_sets;

        // ---- charts by link (an online map AS the chart) --------------------
        // One chart added by link: a MapLibre style url. Picking it renders
        // that style INSTEAD of the built-in chart.
        //
        // THE CORE OWNS ALL OF THIS. It probes the link, inlines TileJSON
        // sources, generates a wrapper style for bare tiles, fetches the
        // sprite packs, builds the credit line, templates the tile urls and
        // persists the list. This shell renders the snapshot and fetches urls
        // (library/ui/ChartLinks.cpp).
        struct ChartLink
        {
            std::string url;
            std::string name;
        };
        void SelectChartLink(std::string const &url); // "" = the built-in chart
        void AddChartLink(std::string const &raw);
        void RefreshChartLink(std::string const &url);
        void RemoveChartLink(std::string const &url);
        void ChartLinksAttach();  // on the handle just opened
        void ChartLinksDetach();  // before the handle closes
        void MigrateChartLinks(); // the old store, handed over once
        void PollChartLinks();    // the snapshot; UI thread, one consumer
        void ChartLinkRespond(uint64_t id, void const *bytes, size_t len, int status);
        static void HttpGetThunk(void *user, unsigned long long req_id,
                                 const char *url, int allow_file);
        static void HttpCancelThunk(void *user, unsigned long long req_id);

        std::vector<ChartLink> chart_links;
        std::string active_chart_link; // "" draws the built-in chart
        std::string chart_link_error;
        bool chart_link_busy{ false };
        bool chart_links_imported{ false };
        // Answers are given under this lock, so a closing handle is never
        // answered into.
        std::mutex link_mu;
        bool link_live{ false };
        // zoom-to-scale panel (hud/ui/Scale.cpp)
        void WireScale();
        void ToggleScalePanel();
        void UpdateScalePanel(lk_readout const &r);
        void UpdateScaleValidity();
        void SubmitScale();
        void ApplyScale(double denom);
        // pick report (chart/ui/Pick.cpp)
        void WirePick();                  // static pick chrome, once, from WireChrome
        void ShowPick(double x_pt, double y_pt);
        void DismissPick();
        void SelectPickObject(int index); // rebuilds the detail column
        void PlacePickCard();             // callout above/below the mark
        void BuildPickBody();
        void CopyPickReport();
        void AddAuxFileView(Microsoft::UI::Xaml::Controls::StackPanel const &into,
                            std::string const &cell, std::string const &name);
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

        /* 10 Hz: the readout poll and the open retry. A DispatcherTimer, not
         * CompositionTarget::Rendering — that subscription ticked the UI
         * thread at refresh rate for the process life, idle or not. */
        Microsoft::UI::Xaml::DispatcherTimer readout_timer{ nullptr };
        // Software (WARP) frames can take tens of ms: rendering runs on its
        // own thread (the core locks internally), never on the UI thread.
        std::thread render_thread;
        std::atomic<bool> render_run{ false };
        std::atomic<int> warmup_frames{ 0 }; // force presents while DWM starts composing us

        // Dev hooks — the interactive-path profile (MainWindow.xaml.cpp):
        // $LOOKOUT_FRAME_PROF rows append on the render thread and the CSV
        // rewrites at every loop exit; $LOOKOUT_GESTURE_BENCH steps a
        // scripted gesture once per tick; $LOOKOUT_HITMAP logs hit tests.
        struct FrameProfRow
        {
            double t, gap;
            int drew, building;
            double zoom, render_ms;
        };
        std::vector<FrameProfRow> frame_prof;
        std::string frame_prof_path;
        long long prof_t0_qpc{ 0 };
        int bench_mode{ 0 };  // 0 off; 1 pan, 2 zoom, 3 both
        int bench_phase{ 0 }; // settle, pan, rest, zoom, fill, done
        int bench_frames{ 0 };
        double bench_fill_t0{ 0 };
        bool hitmap_log{ false };
        void BenchStep();
        void WriteFrameProfile();
        long long last_tick_qpc{ 0 };
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

        // plugin alert state. The list and the rules over it are model code
        // (plugins/lk_alerts.h); the strip and the siren are this shell's.
        std::vector<lkw::Alert> alerts;
        long long alert_seq{ -1 };  // -1 forces the next read to rebuild
        Microsoft::UI::Xaml::DispatcherTimer alert_timer{ nullptr };
        Microsoft::UI::Xaml::DispatcherTimer siren_timer{ nullptr };
        bool siren_on{ false };

        // raster underlay state: the installed paths in the order added,
        // rebuilt from the store at every open (the sources are attached to
        // the lookout handle the open destroyed). UI thread only.
        std::vector<std::string> raster_paths;
        std::wstring raster_pill_shown; // change-detect: last pill text ("" = hidden)
        // Which raster SETS are not drawn, by set name — the saved per-set
        // choice. Entries for sets not installed this launch are kept: a
        // mariner who unplugs the drive holding one has not changed their
        // mind about it.
        std::set<std::string> raster_hidden;

        // startup loader state
        bool open_pending{ false };      // an OpenPaths is deferred/running
        // the running import, its panel timer, and what it was asked to import
        std::unique_ptr<lkw::BakeJob> bake_job;
        bool import_scanning{ false }; // a scan worker is out; one at a time
        Microsoft::UI::Xaml::DispatcherTimer bake_timer{ nullptr };
        std::string bake_source;
        bool bake_rasters_only{ false }; // this job is the raster add flow's
        bool bake_cancel_wired{ false };
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
        // The settings window's last client size, written once at close.
        int settings_size_w{ 0 };
        int settings_size_h{ 0 };
        Microsoft::UI::Xaml::DispatcherTimer apply_timer{ nullptr };

        // wasm plugin settings. The schemas are read when the pane opens; only
        // the status lines are polled after that.
        std::vector<lkw::PluginInfo> plugins;
        Microsoft::UI::Xaml::DispatcherTimer plugin_apply_timer{ nullptr };
        Microsoft::UI::Xaml::DispatcherTimer plugin_poll_timer{ nullptr };
        // The live status texts on the built page, updated in place by the
        // poll. row_id empty = the plugin's own header line (with its dot).
        // Cleared and re-registered by every BuildSettingsPage.
        struct PluginStatusUi
        {
            std::string plugin_id;
            std::string row_id;
            Microsoft::UI::Xaml::Controls::TextBlock text{ nullptr };
            Microsoft::UI::Xaml::Shapes::Ellipse dot{ nullptr };
        };
        std::vector<PluginStatusUi> plugin_status_ui;
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
        // A tap parked one double-tap interval, so the first release of a
        // double-tap never flashes the pick report before the zoom.
        Microsoft::UI::Xaml::DispatcherTimer tap_timer{ nullptr };
        double tap_x{ 0 };
        double tap_y{ 0 };
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
