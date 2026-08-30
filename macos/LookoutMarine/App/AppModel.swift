//  AppModel.swift — shared, platform-neutral app state.
//
//  Single source of truth the SwiftUI chrome binds to: the chart sets aboard, the
//  live HUD readouts the render loop pushes, and the menu/search actions. It
//  holds a weak reference to the one ChartController (owned by ChartView) and
//  funnels every command through it. No AppKit/UIKit here — reused as-is on iOS.

import Foundation
import Combine

@MainActor
@Observable
final class AppModel {
    /// Start the install flow: read the package, and put what it asks for in
    /// front of the mariner. Every entry point lands here — Finder, a drop on
    /// the window, and Settings > Plugins > Install Plugin….
    func beginPluginInstall(_ path: String) {
        guard charts.hasChart else {
            plugins.pendingInstallPath = path
            return
        }
        plugins.begin(path)
    }

    /// A .lkplug that arrived before the chart did, now that the chart is up.
    func drainPendingInstall() {
        guard charts.hasChart, let path = plugins.pendingInstallPath else { return }
        plugins.pendingInstallPath = nil
        plugins.begin(path)
    }

    // MARK: Live HUD readouts (pushed by ChartController / the chart view)
    var scaleDenominator: Double = 0
    var zoomLevel: Double = 0      // fractional web-mercator zoom
    var scheme: Int = 0            // 0 day, 1 dusk, 2 night
    var rotationDeg: Double = 0
    var overscale: Double = 1.0    // >1 = zoomed past the deepest data
    var centerLat: Double = 0
    var centerLon: Double = 0
    /// Follow mode as the core reports it: 0 off, 1 following own ship, 2 on
    /// and waiting for a fix. Polled on the render tick, never remembered from
    /// a tap: the core turns follow off itself when the mariner pans.
    var followState: Int = 0
    /// Course up as the core reports it: 0 off, 1 turning with own ship, 2 on
    /// and waiting for a heading. Polled like followState.
    var courseUpState: Int = 0
    /// What the position readout may say, as the core reports it. Polled on
    /// the render tick beside the position itself, so the two can never
    /// disagree: a readout holding the last numbers through a lost fix would
    /// be presenting a stale one as live.
    var fixState: FixState = .none
    /// Own ship's reported position. Both nil unless `fixState` is `.live`;
    /// the readout NEVER falls back to the map centre or the cursor.
    var shipLat: Double?
    var shipLon: Double?
    var isBuilding = false         // a background tessellation is filling in

    // MARK: iOS sheet/picker presentation (unused on macOS, where the file
    // panel and Settings scene are AppKit-native)
    var showImporter = false
    /// The Add Raster Charts picker. Separate from `showImporter` because the
    /// two import different things to different places: an ENC is copied into
    /// the container and opened, a raster chart is added to the underlay.
    var showRasterImporter = false
    /// The same two pickers again, for the SETTINGS sheet. A presented sheet
    /// cannot present another one from the view it came up over — the pair
    /// above hang on the chart view — so the form attaches its own and these
    /// are the flags that raise them. Add Charts used to dismiss the form and
    /// re-present the picker 0.45s later to get around it; Add Raster Charts
    /// never got that treatment and simply did nothing.
    var showSettingsImporter = false
    var showSettingsRasterImporter = false
    var showSettingsStyleImporter = false
    /// Install Plugin… on iOS. A plugin file arrives through the Files app.
    var showSettingsPluginImporter = false
    var showSettings = false
    /// Which settings section shows, by its core name — "display", "depths",
    /// "text", "charts", "vessels", "alarms", "connections", "advanced". A
    /// name no section answers to falls back to Display. The screenshot hook
    /// sets it.
    var settingsTab = "display"

    // MARK: Search
    var searchOpen = false
    var searchText = ""

    // MARK: Scale entry (tapping the 1:N readout)
    var showScaleEntry = false
    var scaleEntryText = ""

    /// The single chart controller (owned by ChartView; referenced for commands).
    weak var controller: ChartController? {
        didSet {
            // Each model gets the one seam it uses, not the controller. See
            // ChartEngine.swift.
            charts.engine = controller
            chartLinks.engine = controller
            raster.engine = controller
            plugins.engine = controller
            overlay.engine = controller
        }
    }

    // MARK: The models for each area
    //
    // One per subject, each holding its own state and the calls that act on
    // it. The chrome reads them through this one: model.chartLinks.list.

    let chartLinks = ChartLinksModel()
    let raster = RasterModel()
    let plugins = PluginsModel()
    let overlay = OverlayModel()
    /// Adding a set installs the pictures it carries, so this one is built
    /// with the raster model rather than beside it.
    let charts: ChartsModel


    init() {
        charts = ChartsModel(raster: raster)
        // Anything a previous run renamed on its way to being deleted.
        ChartBake.sweepTrash()
        // The panel's list. The open itself does not wait on this: it takes
        // the cheap walk in initialChartPaths and starts drawing.
        charts.loadChartSets()
        // Chart links live in the core (chartlinks.json beside the marks), so
        // nothing to read here. The old UserDefaults store is handed over in
        // chartDidOpen, which has a handle.
    }

    /// A chart handle has just been created. The core reads its chart-link
    /// list at open and resolves the selected one as soon as the shell installs
    /// its fetcher, so nothing has to be replayed here — only the mariner's old
    /// UserDefaults list handed over, once.
    func chartDidOpen() {
        chartLinks.migrate()
        // Dev hook, mirroring $LOOKOUT_OPEN: a style url or a path to a style
        // file draws as the chart at launch. Adding one otherwise needs a
        // form, a paste and a click, which no screenshot run can do.
        if let spec = ProcessInfo.processInfo.environment["LOOKOUT_CHART_LINK"],
           !spec.isEmpty {
            lkLog("chart link: $LOOKOUT_CHART_LINK=\(spec)")
            chartLinks.add(spec)
        }
    }

    /// Add a chart style the mariner has on disk. macOS opens a panel; iOS
    /// raises the form's own importer.
    func addChartStyleFile() {
        #if os(iOS)
        showSettingsStyleImporter = true
        #else
        presentChartStylePanel()
        #endif
    }

    /// Install the raster charts the mariner chose. What would not open is
    /// reported as a chart error, which is the alert the shell already has.
    func addRasterCharts(_ picked: [String]) {
        if let err = raster.add(picked) { charts.openError = err }
    }

    /// Step to the next picture. Nothing installed: the cycle has nowhere to
    /// go, so offer the picker rather than letting the key press do nothing.
    func cycleRaster() {
        guard !raster.cycle() else { return }
        #if os(macOS)
        presentRasterPanel()
        #endif
    }

    // MARK: The chart commands
    //
    // One line each: the menu bar, the keyboard and the chrome bubbles all
    // reach the controller through here, so none of them has to hold it or
    // check whether a chart is up.

    func zoomIn()   { controller?.zoomCentered(+1.0) }
    func zoomOut()  { controller?.zoomCentered(-1.0) }
    func zoomToFit(){ controller?.fitChart() }
    func northUp()  { controller?.resetRotation() }
    func toggleText() { controller?.toggleText() }
    func toggleSoundings() { controller?.toggleSoundings() }
    func toggleOtherCategory() { controller?.toggleOtherCategory() }

    /// What the compass bubble shows. The core owns both parts: it drops
    /// follow on a pan and course up on a hand rotation, so this is read, not
    /// remembered.
    var orientation: Orientation {
        if followState == 0 { return .unlocked }
        if followState == 2 { return .armed }   // on, no fix to follow yet
        return courseUpState == 0 ? .northUp : .courseUp
    }

    /// The compass bubble's tap. It always locks the chart to own ship, and
    /// once locked it cycles north up and course up.
    func cycleOrientation() {
        guard let c = controller else { return }
        if followState == 0 {
            c.setFollow(true)          // lock, leaving the chart as it lies
        } else if courseUpState == 0 {
            c.setCourseUp(true)        // turn with own ship
        } else {
            c.resetRotation()          // back to north up, still locked
        }
    }

    /// Scheme changes from the MENU must persist like ones from the settings
    /// form (the form saves in its own apply path).
    func cycleScheme() {
        guard let c = controller else { return }
        c.cycleScheme()
        MarinerSettings.save(c.getMariner())
    }

    /// Set the color scheme directly (0 day / 1 dusk / 2 night).
    func setScheme(_ s: Int) {
        guard let c = controller else { return }
        var m = c.getMariner()
        m.scheme = tile57_scheme(UInt32(s))
        c.setMariner(m)
        MarinerSettings.save(m)
    }

    var schemeName: String {
        switch scheme { case 1: return "Dusk"; case 2: return "Night"; default: return "Day" }
    }

    /// Parse the search text as a coordinate and recenter. True when it was a
    /// coordinate, so the field can clear itself.
    @discardableResult
    func submitSearch() -> Bool {
        guard let controller, let coord = CoordinateParser.parse(searchText) else { return false }
        let cur = controller.currentView
        // Keep the current zoom and rotation; a chart-less view uses a
        // harbor-ish zoom.
        let zoom = cur.zoom > 0 ? cur.zoom : 12
        controller.setView(lookout_view(lon: coord.lon, lat: coord.lat,
                                        zoom: zoom, rotation_deg: cur.rotation_deg))
        return true
    }

    /// The Configure GPS button. This is the one place in the app where a
    /// mariner is told they have no position, so it carries the fix: Settings,
    /// Connections, where a gateway or a Signal K server is added. (A phone
    /// has a receiver of its own and will ask for permission here instead;
    /// that is a later pass.)
    func configurePosition() {
        openSettings()
        settingsTab = "connections"
    }

    /// Show the chart picker: the AppKit open panel on macOS, the document
    /// importer on iOS. The charts bubble, the empty state and the File menu
    /// all use it.
    func requestOpenPicker() {
        #if os(macOS)
        presentOpenPanel()
        #else
        showImporter = true
        #endif
    }

    /// "Add charts" from the SETTINGS sheet (iOS): the form's own importer,
    /// which comes up over the sheet and leaves it where it was. It used to
    /// dismiss the sheet and re-present the chart view's importer 0.45s later,
    /// because that one cannot appear while the sheet is over it.
    func addChartsFromSettings() {
        #if os(iOS)
        showSettingsImporter = true
        #else
        presentOpenPanel()
        #endif
    }

    /// Open the scale entry. The field starts at the current scale.
    func beginScaleEntry() {
        scaleEntryText = scaleDenominator > 0 ? String(Int(scaleDenominator.rounded())) : ""
        showScaleEntry = true
    }

    var scaleEntryIsValid: Bool { ScaleParser.parse(scaleEntryText) != nil }

    /// Apply the scale in the field. Returns false if the text is not a scale.
    @discardableResult
    func submitScaleEntry() -> Bool {
        guard let denominator = ScaleParser.parse(scaleEntryText) else { return false }
        zoomToScale(denominator)
        showScaleEntry = false
        return true
    }

    /// Zoom to a 1:N display scale, about the view centre.
    ///
    /// At one latitude the denominator is C·cos(lat)/2^zoom. A scale is
    /// therefore a zoom delta, and the engine zoom can do the work. The engine
    /// keeps its zoom limits and eases the movement.
    func zoomToScale(_ denominator: Double) {
        guard let controller, denominator > 0, scaleDenominator > 0 else { return }
        controller.zoomCentered(log2(scaleDenominator / denominator))
    }
}
