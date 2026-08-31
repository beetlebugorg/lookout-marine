//  AppModel.swift — the models for each area, and the chart controller.
//
//  It holds no state of its own. Each subject has a model beside this one, and
//  the chrome reads them through it: model.raster.paths, model.overlay.pickPoint.
//  What is left here is the controller, the commands that forward to it, and the
//  few actions that reach across two areas.
//
//  It holds a weak reference to the one ChartController (owned by ChartView) and
//  hands each model the seam it uses. No AppKit/UIKit here — reused as-is on iOS.

import Foundation

@MainActor
@Observable
final class AppModel {
    /// The single chart controller (owned by ChartView; referenced for commands).
    weak var controller: ChartController? {
        didSet {
            // Each model gets the one seam it uses, not the controller. See
            // ChartEngine.swift.
            charts.engine = controller
            chartLinks.engine = controller
            raster.engine = controller
            readouts.engine = controller
            plugins.engine = controller
            overlay.engine = controller
        }
    }

    // MARK: The models for each area
    //
    // One per subject, each holding its own state and the calls that act on it.

    let chartLinks = ChartLinksModel()
    let raster = RasterModel()
    let plugins = PluginsModel()
    let overlay = OverlayModel()
    let readouts = ReadoutsModel()
    let chrome = ChromeModel()
    /// Adding a set installs the pictures it carries, so this one is built
    /// with the raster model rather than beside it.
    let charts: ChartsModel

    // MARK: Across two areas

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

    init() {
        // What the mariner already has, out of the defaults domain and into
        // the core store. Once, before anything reads a setting.
        Store.shared.importDefaults()
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
        chrome.showSettingsStyleImporter = true
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

    /// The compass bubble's tap. It always locks the chart to own ship, and
    /// once locked it cycles north up and course up.
    func cycleOrientation() {
        guard let c = controller else { return }
        if readouts.followState == 0 {
            c.setFollow(true)          // lock, leaving the chart as it lies
        } else if readouts.courseUpState == 0 {
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

    /// Parse the search text as a coordinate and recenter. True when it was a
    /// coordinate, so the field can clear itself.
    @discardableResult
    func submitSearch() -> Bool {
        guard let controller, let coord = CoordinateParser.parse(chrome.searchText) else { return false }
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
        chrome.settingsTab = "connections"
    }

    /// Show the chart picker: the AppKit open panel on macOS, the document
    /// importer on iOS. The charts bubble, the empty state and the File menu
    /// all use it.
    func requestOpenPicker() {
        #if os(macOS)
        presentOpenPanel()
        #else
        chrome.showImporter = true
        #endif
    }

    /// "Add charts" from the SETTINGS sheet (iOS): the form's own importer,
    /// which comes up over the sheet and leaves it where it was. It used to
    /// dismiss the sheet and re-present the chart view's importer 0.45s later,
    /// because that one cannot appear while the sheet is over it.
    func addChartsFromSettings() {
        #if os(iOS)
        chrome.showSettingsImporter = true
        #else
        presentOpenPanel()
        #endif
    }

    /// Open the scale entry. The field starts at the current scale.
    func beginScaleEntry() {
        chrome.scaleEntryText = readouts.scaleDenominator > 0
            ? String(Int(readouts.scaleDenominator.rounded())) : ""
        chrome.showScaleEntry = true
    }

    var scaleEntryIsValid: Bool { ScaleParser.parse(chrome.scaleEntryText) != nil }

    /// Apply the scale in the field. Returns false if the text is not a scale.
    @discardableResult
    func submitScaleEntry() -> Bool {
        guard let denominator = ScaleParser.parse(chrome.scaleEntryText) else { return false }
        zoomToScale(denominator)
        chrome.showScaleEntry = false
        return true
    }

    /// Zoom to a 1:N display scale, about the view centre.
    ///
    /// A scale is a zoom delta, and the engine zoom does the work. The engine
    /// keeps its zoom limits and eases the movement.
    func zoomToScale(_ denominator: Double) {
        guard let controller, denominator > 0, readouts.scaleDenominator > 0 else { return }
        controller.zoomCentered(
            lookout_zoom_delta_for_scale(readouts.scaleDenominator, denominator))
    }
}
