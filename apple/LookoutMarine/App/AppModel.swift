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
    /// NOAA's catalog, the regions a mariner picks, and the downloads run from
    /// them. See src/noaa.zig for what a region selects.
    let noaa = NoaaModel()
    /// The core's NOAA service. It has no chart handle under it, so a chart
    /// reopening leaves its download running.
    private var noaaService: NoaaService?
    /// The download being followed to its end: its run number, and how to
    /// order it again. A new order replaces it.
    private var noaaWatch: (run: UInt32, order: () -> Void)?
    let raster = RasterModel()
    let plugins = PluginsModel()
    let overlay = OverlayModel()
    let readouts = ReadoutsModel()
    let chrome = ChromeModel()
    /// Setup. It runs over an app that has settled on having no chart to
    /// draw, on every launch that finds one. See lookout_setup_note.
    let firstRun = FirstRunModel()
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

    /// Download the picked NOAA regions. The core prepares what arrives into
    /// the managed set.
    func startNoaaDownload(again: Bool = false) {
        guard let dest = NoaaModel.downloadDirectory else {
            charts.openError = "Couldn't find a place to download charts to."
            return
        }
        let before = noaa.state.run
        noaa.download(to: dest, again: again)
        watchNoaaDownload(after: before) { [weak self] in
            self?.startNoaaDownload(again: again)
        }
    }

    /// Apply the picker's pick: the core deletes the water given back and
    /// fetches what is missing, and what arrives is prepared as a download is.
    /// `givesBack` is true when the pick unticks water that was held.
    func applyNoaaPick(givesBack: Bool) {
        guard let dest = NoaaModel.downloadDirectory else {
            charts.openError = "Couldn't find a place to download charts to."
            return
        }
        // An empty pick deletes the whole download. A stopped download's end
        // must not add the folder back.
        let whole = noaa.picked.isEmpty
        if whole { noaaWatch = nil }
        let before = noaa.state.run
        let moved = noaa.apply(to: dest)
        watchNoaaDownload(after: before) { [weak self] in
            self?.startNoaaDownload()
        }
        if givesBack { charts.noaaApplied(moved: moved, whole: whole) }
    }

    /// Fetch the reissued editions of every installed cell. The core prepares
    /// them as it does a download.
    func startNoaaUpdate() {
        guard let dest = NoaaModel.downloadDirectory else {
            charts.openError = "Couldn't find a place to download charts to."
            return
        }
        let before = noaa.state.run
        noaa.update(to: dest)
        watchNoaaDownload(after: before) { [weak self] in
            self?.startNoaaUpdate()
        }
    }

    /// Follow the download just ordered to its end, which comes once the
    /// core has prepared what arrived. noaaChanged checks it each time the
    /// state changes. `before` is the run number read before ordering: an
    /// order the model did not pass on leaves it as it was, and there is no
    /// download to follow.
    private func watchNoaaDownload(after before: UInt32, order: @escaping () -> Void) {
        guard noaa.state.run != before else { return }
        noaaWatch = (noaa.state.run, order)
        noaaChanged()
    }

    /// The NOAA state changed. Open what a prepare made, and end the watched
    /// download if it has ended.
    private func noaaChanged() {
        let st = noaa.state
        charts.noteNoaaRemoval(st)
        // True when a prepare has just ended. One the core resumed has no
        // download to watch, so its end opens the charts as well.
        var open = charts.noteNoaaPrepare(st)
        defer { if open { charts.adoptNoaaPrepare() } }
        guard let w = noaaWatch, st.run == w.run, st.ended else { return }
        noaaWatch = nil
        switch st.outcome {
        case .finished:
            open = true
        case .cancelled:
            // A stop is the mariner's own. What arrived before it is kept.
            if st.done > 0 { open = true }
        case .failed, .refused:
            // The Charts pane shows the end here. Setup shows it in its own
            // step. A refusal a retry cannot clear raises no alert.
            if !firstRun.showing, st.outcome == .failed || st.retry {
                charts.openError = st.error.isEmpty
                    ? "The download stopped before any chart arrived." : st.error
                if st.retry {
                    let order = w.order
                    charts.openRetry = { [weak self] in self?.retryNoaa(order) }
                }
            }
        case .empty, .none, .running:
            break
        }
    }

    /// Order a download again. With no catalog loaded, read it first.
    private func retryNoaa(_ order: @escaping () -> Void) {
        guard !noaa.state.haveCatalog else { return order() }
        Task {
            await noaa.loadCatalog()
            order()
        }
    }

    /// What setup reads from the app. The overlay notes it on every change.
    var setupFacts: FirstRunModel.Facts {
        let n = noaa
        return .init(
            catalogReady: n.state.haveCatalog,
            picked: !n.picked.isEmpty,
            onLink: chartLinks.active != nil,
            nothingToDraw: charts.nothingToDraw,
            hasCharts: charts.sets.contains { $0.on && $0.hasSomethingToDraw },
            workRunning: charts.chartWork != nil,
            downloading: n.state.phase == .downloading,
            chartOpen: charts.hasChart && !charts.chartIsEmpty,
            noaaOutcome: n.state.outcome.rawValue,
            noaaRun: n.state.run,
            pickCharts: n.allInstalled ? n.held : n.cells,
            pickBytes: n.allInstalled ? n.heldBytes : n.bytes)
    }

    /// Note the facts, and raise setup when the core has it come up.
    func noteSetup() {
        firstRun.note(setupFacts)
        guard firstRun.shouldBegin else { return }
        firstRun.begin()
        showWholeCountry()
    }

    /// The three views the coverage picker photographs.
    ///
    /// One view cannot hold the lower 48, Alaska and Hawaii. The three need
    /// 128 degrees of longitude, and at that scale their latitude span is
    /// taller than the window. An atlas prints Alaska and Hawaii as insets for
    /// the same reason.
    static let countryView = lookout_view(lon: -96, lat: 38, zoom: 5.0, rotation_deg: 0)
    static let alaskaView = lookout_view(lon: -152, lat: 63, zoom: 4.6, rotation_deg: 0)
    static let hawaiiView = lookout_view(lon: -157.3, lat: 20.5, zoom: 7.0, rotation_deg: 0)

    /// Frame the lower 48 behind setup, so the chart under the sheet shows the
    /// coastline the mariner is choosing from.
    func showWholeCountry() {
        guard let controller else { return }
        controller.setView(Self.countryView)
        // United States charts label depths in feet, and setup is the one
        // moment the unit can be chosen before the first sounding draws.
        var mariner = controller.getMariner()
        mariner.depth_unit = tile57_depth_unit(UInt32(MarinerDepthUnit.feet.rawValue))
        controller.setMariner(mariner)
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
        // The core prepares a download, so its Stop is the NOAA service's.
        charts.cancelNoaaPrepare = { [weak self] in self?.noaa.cancel() }
        charts.onSetsChanged = { [weak self] in
            guard let self else { return }
            // The core reads the held cells and the editions off the sets.
            self.noaa.reprice()
            self.noaa.recount()
            self.noaa.considerUpdateCheck()
        }
        // Anything a previous run renamed on its way to being deleted.
        ChartBake.sweepTrash()
        // The panel's list. The open itself does not wait on this: it takes
        // the cheap walk in initialChartPaths and starts drawing.
        charts.loadChartSets()
        // Chart links live in the core (chartlinks.json beside the marks), so
        // nothing to read here. The old UserDefaults store is handed over in
        // chartDidOpen, which has a handle.
        //
        // Every chart-link call goes through a lookout handle, which exists
        // only while a chart is open. Open a chart of no cells so a link
        // picked with no charts installed has a core to run through.
        chartLinks.openChartForLink = { [weak self] in self?.charts.openEmpty() }
        // NOAA's service needs no chart, so setup reads the catalog before
        // the mariner has one.
        let service = NoaaService { [weak self] in self?.noaa.pull() }
        noaaService = service
        noaa.engine = service
        noaa.onChange = { [weak self] in self?.noaaChanged() }
    }

    /// A chart handle has just been created. The core reads its chart-link
    /// list at open and resolves the selected one as soon as the shell installs
    /// its fetcher, so nothing has to be replayed here — only the mariner's old
    /// UserDefaults list handed over, once.
    func chartDidOpen() {
        // Setup frames the country, which goes through the chart handle.
        if firstRun.showing { showWholeCountry() }
        noaa.considerUpdateCheck()
        chartLinks.migrate()
        // The chart-link calls held while no chart was open.
        chartLinks.chartDidOpen()
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

    /// Scheme changes from the MENU persist like ones from the settings form:
    /// the engine writes every mariner change down.
    func cycleScheme() {
        controller?.cycleScheme()
    }

    /// Set the color scheme directly (0 day / 1 dusk / 2 night).
    func setScheme(_ s: Int) {
        guard let c = controller else { return }
        var m = c.getMariner()
        m.scheme = tile57_scheme(UInt32(s))
        c.setMariner(m)
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
