#pragma once
#include "MainWindow.g.h"

#include "lk_alerts.h"
#include "lk_bake.h"
#include "lk_coastline.h"
#include "lk_firstrun.h"
#include "lk_controller.h"
#include "lk_pick.h"
#include "lk_discovery.h"
#include "lk_plugin_model.h"
#include "lk_table.h"

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
        void ReadPluginSetting(lkw::PluginInfo &info, lookout_plugin_setting const &s);
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
        /* Everything that belongs to the handle about to be destroyed. */
        void CloseChartHandle();
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

        // ---- chart sets (the folders of installed charts) ----------------------
        // A set is a folder — the baked library, a folder of .pmtiles, a
        // folder of pictures — with an on/off switch. What opens is the UNION
        // of the switched-on sets. Mirrors the macOS "installed sets" model.
        struct ChartSetRow
        {
            std::string path;
            bool on{ true };
            // 0 until the background scan has read the folder, and every
            // count below is 0 until then.
            bool scanned{ false };
            size_t charts{ 0 };
            size_t pictures{ 0 };
            // Files that bake before they draw, and what the folder holds on
            // disk. Both are the core's own figures for the set.
            size_t unprepared{ 0 };
            uint64_t bytes{ 0 };
            // How many prepared charts this set holds in each usage band,
            // keyed 1 to 6. A set that stops at Coastal does not draw the
            // harbour a passage ends in, so the row says which scales are in
            // it.
            std::map<int, size_t> bands;
            std::string title; // the agency whose charts these are, else the folder
        };
        lookout_chart_sets *ChartSetsModel();
        void LoadChartSets(std::function<void()> then);
        void PollChartSets();
        /* True while any installed set is still waiting for its scan. */
        bool ChartSetsScanning() const;
        void CloseChartSets();
        std::vector<std::string> ChartSetOpenPaths();
        void AdoptChartSet(std::string const &path);
        void SetChartSetOn(std::string const &path, bool on);
        void RemoveChartSet(std::string const &path);
        /* Whether Lookout made the charts in this set, which decides whether
         * removing it deletes them and asks first. */
        bool ChartSetIsDerived(std::string const &path);
        /* Ask, then remove and delete. The mariner is throwing away work, so
         * the question says how much of it. */
        fire_and_forget ConfirmRemoveChartSet(std::string path, std::string name, size_t charts);
        /* Delete the charts Lookout prepared for one set. Refuses any path it
         * did not make. Call it with the chart CLOSED: the handle holds the
         * files open, and Windows refuses to rename a directory under one. */
        void DeletePreparedCharts(std::string const &path);
        int remove_seq{ 0 };
        /* Open what the switched-on sets compose, or take the chart off the
         * display when nothing is installed. */
        void ReopenChartSets(std::string const &recent);
        std::vector<ChartSetRow> chart_sets;
        lookout_chart_sets *chart_sets_model{ nullptr };

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
        // Which chart draws now, as a url. Empty is Lookout's own.
        std::string ActiveChartUrl();
        // Draw the chart the mariner picked from the shelf. A frame goes out
        // between the pick and the call, so a tile is marked as being read
        // before the core takes the thread to read the style.
        void PickChartTile(std::string const &url, bool mine);
        // The Active chart shelf: one tile per chart, the menu on a tile the
        // mariner added, and the tile that adds one (settings/ui/Settings.cpp).
        /* One tile, registered in chart_tile_ui as it is built. `where` is its
         * detail line at rest; which tile is drawing and which is being read
         * is applied by RefreshChartsPageInPlace, so a pick never rebuilds. */
        Microsoft::UI::Xaml::Controls::Button ChartTile(std::string const &url,
                                                        std::wstring const &name,
                                                        std::wstring const &where,
                                                        wchar_t const *art, bool mine);
        Microsoft::UI::Xaml::Controls::Button ChartTileMenu(std::string const &url,
                                                            std::wstring const &name);
        Microsoft::UI::Xaml::Controls::Button AddChartTile();
        fire_and_forget ShowAddChartDialog();
        fire_and_forget PickChartStyleFile();
        void AddChartLink(std::string const &raw);
        void RefreshChartLink(std::string const &url);
        void RemoveChartLink(std::string const &url);
        void ChartLinksAttach();  // on the handle just opened
        void ChartLinksDetach();  // before the handle closes
        void MigrateChartLinks(); // the old store, handed over once
        void PollChartLinks();    // the snapshot; UI thread, one consumer
        void ChartLinkRespond(uint64_t id, void const *bytes, size_t len, int status);
        // ---- setup (firstrun/) ------------------------------------------
        //
        // The MODEL decides; this half only draws it. See firstrun/lk_firstrun.h.
        void FirstRunAttach(); // wire the pane's three buttons, once
        void FirstRunBegin();  // no chart to draw: put setup up
        // Get charts from NOAA, from the Charts pane: the coverage step alone.
        void ShowNoaaPicker();
        // Open the engine with NO cells so the basemap draws, then begin
        // setup over it. Both of the ways to arrive with nothing to draw.
        void OpenBasemapForSetup();
        void FirstRunRender(); // build the step on screen from the model
        // The chart controls, hidden while setup covers the chart.
        void FirstRunChartChrome(bool shown);
        // The fade and the scrollbar, while a step runs past the card.
        void FirstRunUpdateFold();
        void FirstRunPrimary();
        // The welcome step centers a column; every later step uses a row.
        void FirstRunFooterShape(bool welcome);
        // What to DO once the flow has finished asking: start the NOAA
        // download, add the chart link, or raise the folder picker.
        void FirstRunAct(lkw::ChartSource source);
        fire_and_forget FirstRunShowEncTerms();
        // The two services, read on a timer and handed to the model, which
        // decides what survives their resetting.
        // Hand the core the cells this device holds, so a cost and a download
        // leave them out.
        void FirstRunNoaaHave();
        void FirstRunPollStart();
        /* Start or stop that poll by what there is to watch: a catalog read, a
         * transfer, a bake, or a bake waiting to be handed over. */
        void FirstRunPollAsNeeded();
        void FirstRunPoll();

        // The welcome picture, outside the step inset so it meets the edges.
        void FirstRunHero(Microsoft::UI::Xaml::Controls::StackPanel const &body);
        void FirstRunWelcome(Microsoft::UI::Xaml::Controls::StackPanel const &body);
        void FirstRunSource(Microsoft::UI::Xaml::Controls::StackPanel const &body);
        // The coverage map, above the region list on the coverage step.
        void FirstRunCoverageMap(Microsoft::UI::Xaml::Controls::StackPanel const &body);
        /* One panel of that map: a window on the ground, and the regions in
         * `ids` drawn on it as the water they cover. Each region is one
         * tappable path, so the map picks as well as it shows. */
        Microsoft::UI::Xaml::Controls::Border FirstRunCoveragePanel(
            lkw::MapWindow const &win, std::vector<std::string> const &ids, double width,
            double radius, bool enabled);
        /* The catalog state the coverage step last drew. The catalog lands on
         * its own and the map and the prices come from it, so the step is
         * rendered again when this changes rather than on every tick. */
        std::string noaa_catalog_drawn;
        std::string NoaaCatalogSignature();

        /* The Preparing step's live parts. That step is polled four times a
         * second, and building it again restarted the progress bar's sweep and
         * every phase ring on each tick. The values are written here instead;
         * the step is built again only when its shape changes, which
         * FirstRunImportingShape names. */
        struct FirstRunPhaseUi
        {
            Microsoft::UI::Xaml::Controls::TextBlock name{ nullptr };
            Microsoft::UI::Xaml::Controls::TextBlock detail{ nullptr };
            Microsoft::UI::Xaml::Controls::FontIcon tick{ nullptr };
            Microsoft::UI::Xaml::Controls::ProgressRing ring{ nullptr };
        };
        std::vector<FirstRunPhaseUi> first_run_phase_ui;
        struct FirstRunBandUi
        {
            Microsoft::UI::Xaml::Controls::TextBlock count{ nullptr };
            Microsoft::UI::Xaml::Controls::FontIcon tick{ nullptr };
        };
        std::vector<FirstRunBandUi> first_run_band_ui;
        Microsoft::UI::Xaml::Controls::ProgressBar first_run_bar{ nullptr };
        std::string first_run_importing_shape;
        std::string FirstRunImportingShape();
        /* What the step on screen now says, and whether its action can be
         * taken. Creates nothing, so a poll may call it. */
        void FirstRunRestate();
        void FirstRunCoverage(Microsoft::UI::Xaml::Controls::StackPanel const &body);
        void FirstRunOnline(Microsoft::UI::Xaml::Controls::StackPanel const &body);
        void FirstRunImporting(Microsoft::UI::Xaml::Controls::StackPanel const &body);
        void FirstRunDepths(Microsoft::UI::Xaml::Controls::StackPanel const &body);
        void FirstRunPhase(Microsoft::UI::Xaml::Controls::StackPanel const &body,
                           std::wstring const &name, std::wstring const &detail,
                           bool running, bool done);

        lkw::FirstRun first_run;
        Microsoft::UI::Xaml::DispatcherTimer first_run_timer{ nullptr };
        // The region the coverage step has picked, as the core's id ("d17").
        // The districts picked, as the core's comma separated list ("d5,d8").
        // lookout_noaa_cost and lookout_noaa_download both take it as it
        // stands (lkw::RegionPicked, lkw::RegionToggle).
        std::string noaa_region_id;
        // Whether the coverage step has asked for the catalog. It asks once
        // per page, so a read that failed is not asked for again on every
        // render; the step's Try Again is what asks after that.
        bool noaa_catalog_asked{ false };
        // What the online step has been given, so the button can read Skip
        // until there is something to continue with.
        std::string chart_link_url;
        // Where the district zips go. Beside the library rather than in it:
        // they are the source a bake reads, and the vector open globs the
        // library for .pmtiles.
        std::string noaa_dest_dir;
        // The usage band of every chart the scan found, which with the bake's
        // own count gives the by-band breakdown. See lkw::FirstRunBands.
        std::vector<int> noaa_scan_bands;
        // GSHHG rings for the coverage map, read once and kept: a step
        // rebuild redraws the map and the file is a quarter of a megabyte.
        std::vector<lkw::CoastRing> coastline_;
        // The baked library has been opened and adopted, once per run.
        bool noaa_handed_over{ false };
        bool first_run_footer_welcome{ false };
        bool first_run_footer_shaped{ false };


        // One piece of an answer. `done` marks the last; a large body never
        // exists whole on this side. See lk_controller_http_respond_chunk.
        void ChartLinkRespondChunk(uint64_t id, void const *bytes, size_t len,
                                   int status, int done);
        static void HttpGetThunk(void *user, unsigned long long req_id,
                                 const char *url, int allow_file);
        static void HttpCancelThunk(void *user, unsigned long long req_id);

        std::vector<ChartLink> chart_links;
        std::string active_chart_link; // "" draws the built-in chart
        std::string chart_link_error;
        bool chart_link_busy{ false };
        bool chart_links_imported{ false };
        // The chart the mariner just picked, while the core has yet to be
        // told. Reading a publisher's style is the core's work and it runs
        // inside a frame, so the tile says what is happening before that
        // starts.
        // The url picked, empty for Lookout's own chart, and whether that pick
        // is still in flight. An empty url is a real answer, so the flag says
        // whether there is a pick at all.
        std::string chart_link_pending;
        bool chart_link_picked{ false };
        // True only until the call goes out, which is what keeps a poll
        // landing in between from clearing the pick.
        bool chart_link_picking{ false };
        // Where the mariner had the shelf scrolled. The links poll several
        // times a second while a style resolves, and every report rebuilds
        // the page, which sent the row back home.
        double chart_shelf_offset{ 0 };
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
        // The work the Charts page reports while it runs. The settings window
        // stands over the chart, so a download or a bake begun here otherwise
        // runs behind it. These live on the built page and are updated in
        // place, so the page is not rebuilt several times a second; each
        // BuildSettingsPage clears them. Nothing is polled while they are
        // null, which is whenever no such work is on the page.
        Microsoft::UI::Xaml::Controls::TextBlock noaa_pane_count{ nullptr };
        Microsoft::UI::Xaml::Controls::ProgressBar noaa_pane_bar{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock bake_pane_count{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock bake_pane_eta{ nullptr };
        Microsoft::UI::Xaml::Controls::ProgressBar bake_pane_bar{ nullptr };
        // Read the download the Charts page is reporting, and put the page
        // away once it ends.
        void PollNoaaPane();
        /* What the Charts page draws, as one string, and the rebuild that
         * compares it.
         *
         * The links and the sets are polled off the readout tick, and the core
         * raises its changed flag for work that leaves the page identical: a
         * tile landing for a style that is drawing, a rescan finding what it
         * found before. Rebuilding for those tore down and rebuilt every
         * control ten times a second, which reads as flicker. */
        /* The Charts page is built once and then updated in place.
         *
         * A rebuild destroys every control on the page. The pointer standing
         * on a control loses the hover it was showing, because a fresh control
         * only takes that state on the next pointer move; a press and its
         * release land on two different controls, so the click is either lost
         * or delivered to whatever now sits under the cursor. Both happen
         * while a mariner is picking a chart, which is exactly when the links
         * poll reports something. So a poll updates the page's VALUES and the
         * page is rebuilt only when its STRUCTURE changes: a tile, a set, a
         * raster group or a section coming or going.
         *
         * Every registry below is cleared and filled again by each build. */
        struct ChartTileUi
        {
            std::string url;
            Microsoft::UI::Xaml::Controls::Button button{ nullptr };
            Microsoft::UI::Xaml::Controls::Border badge{ nullptr };
            Microsoft::UI::Xaml::Controls::TextBlock detail{ nullptr };
            /* What the detail line says when this chart is not being read. */
            std::wstring where;
        };
        std::vector<ChartTileUi> chart_tile_ui;
        struct ChartSetRowUi
        {
            std::string path;
            Microsoft::UI::Xaml::Controls::TextBlock name{ nullptr };
            Microsoft::UI::Xaml::Controls::TextBlock summary{ nullptr };
            Microsoft::UI::Xaml::Controls::TextBlock prepare{ nullptr };
            Microsoft::UI::Xaml::Controls::ToggleSwitch on{ nullptr };
            Microsoft::UI::Xaml::Controls::StackPanel ramp{ nullptr };
            /* The bands the ramp was drawn from, so it is redrawn only when
             * they change. */
            std::map<int, size_t> bands;
        };
        std::vector<ChartSetRowUi> chart_set_ui;
        Microsoft::UI::Xaml::Controls::TextBlock chart_sets_total{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock chart_sets_none{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock chart_link_error_ui{ nullptr };
        Microsoft::UI::Xaml::Controls::TextBlock chart_publisher_note{ nullptr };
        /* What every line on the page now says. Cheap, and safe to call from a
         * poll: it creates nothing and destroys nothing. */
        void RefreshChartsPageInPlace();
        /* The page's shape, as one string. A change here is a rebuild. */
        std::string ChartsPageStructure();
        void RefreshChartsPageOnChange();
        std::string charts_page_sig;
        /* Whether the page on screen draws what the network browse found. The
         * browse is a plugin's, its answers come and go on their own, and only
         * the page showing them has a reason to be built again for one. Set
         * while that page is built; false on every other page. */
        bool page_reads_discovery{ false };

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
