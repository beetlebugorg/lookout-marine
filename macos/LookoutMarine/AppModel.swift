//  AppModel.swift — shared, platform-neutral app state.
//
//  Single source of truth the SwiftUI chrome binds to: the chart sets aboard, the
//  live HUD readouts the render loop pushes, and the menu/search actions. It
//  holds a weak reference to the one ChartController (owned by ChartView) and
//  funnels every command through it. No AppKit/UIKit here — reused as-is on iOS.

import Foundation
import Combine

/// A request to (re)open one or more chart paths, carried to the chart view.
struct OpenRequest: Equatable {
    let id: Int
    let paths: [String]
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Chart state
    @Published var hasChart = false
    /// The active raster chart set's name, or "" for no picture. Shown at all times
    /// while a picture is on: the chart drops its opaque water and land fills to
    /// let the picture through, and the mariner must never mistake that display
    /// for the full chart.
    @Published var rasterName = ""
    /// Every raster chart file the mariner has installed, in the order added. The
    /// controller replays these into each newly opened chart, so a raster chart
    /// survives switching charts and relaunching.
    @Published var rasterPaths: [String] = []
    /// True only while a picture is really beneath the view and the chart is
    /// therefore drawing without its opaque fills. The HUD badge keys off this,
    /// not off the selected set — a badge that appeared whenever a raster chart was
    /// merely installed would claim the chart was reduced when it was not.
    @Published var rasterInView = false
    /// True while the vector chart is hidden and only the picture shows.
    @Published var chartHidden = false
    /// The set that covers this view, DRAWN OR NOT. Empty when none does. The
    /// pill appears only when this is set: a control that is useless here is
    /// noise, and one that says nothing about what is available teaches nothing.
    @Published var rasterAvailable = ""
    /// The installed charts the mariner has switched OFF. They stay installed:
    /// these are half-gigabyte downloads, and carrying four providers for one
    /// coast means wanting three of them quiet, not deleted.
    @Published var rasterOff: Set<String> = []
    /// The sets the mariner has turned off at the pill, by set name. Read at
    /// launch and applied before the first frame; written whenever the drawn set
    /// changes. Without it the engine's own rule wins every launch — adding a
    /// source draws it — and a chart switched off comes back.
    private(set) var rasterHidden: Set<String> = []
    /// Was the ENC hidden over the picture when the app last quit? Applied at
    /// open; `chartHidden` is the live state.
    private(set) var chartHiddenSaved = false
    /// Every set, with whether it is in view. The pill's menu is built from it.
    @Published var rasterSets: [ChartController.RasterSet] = []
    /// The drawn set's index, or -1.
    @Published var rasterActive = -1
    @Published var chartPath: String?
    /// The folders of charts aboard, in the order added. A set on this list has
    /// been looked through and holds charts, so it always opens.
    @Published var chartSets: [ChartSet] = []
    /// True while a folder is being looked through. The full NOAA library takes
    /// about 3 seconds.
    @Published var scanning = false
    /// The last folder that held no charts, for the panel to say so.
    @Published var emptyPick: String?
    @Published var openRequest: OpenRequest?
    @Published var openError: String?
    private var openSeq = 0

    // MARK: Plugin install
    /// The package on the consent sheet: set by beginPluginInstall, cleared by
    /// Install or Cancel. The sheet presents while this is non-nil.
    @Published var pendingInstall: PluginPackage?
    /// The sentence of the last refused install, for its own alert — an
    /// install refusal is not a chart error.
    @Published var installError: String?
    /// A .lkplug opened before any chart was: kept until the chart (and with
    /// it the plugin layer) is up, then inspected.
    var pendingInstallPath: String?

    /// Start the install flow: read the package, and put what it asks for in
    /// front of the mariner. Every entry point lands here — Finder, a drop on
    /// the window, and Settings > Plugins > Install Plugin….
    func beginPluginInstall(_ path: String) {
        guard hasChart, let controller else {
            pendingInstallPath = path
            return
        }
        guard let json = controller.inspectPlugin(path) else {
            installError = "The plugin layer could not start."
            return
        }
        let pkg = PluginPackage.parse(json, path: path)
        if let err = pkg.error {
            installError = err
            return
        }
        pendingInstall = pkg
    }

    /// The Install button: the consent happened, so the package goes in and
    /// starts drawing. A refusal lands in its own alert.
    func confirmPluginInstall() {
        guard let pkg = pendingInstall else { return }
        pendingInstall = nil
        if let err = controller?.installPlugin(pkg.path) {
            installError = err
        }
    }

    /// A .lkplug that arrived before the chart did, now that the chart is up.
    func drainPendingInstall() {
        guard hasChart, let path = pendingInstallPath else { return }
        pendingInstallPath = nil
        beginPluginInstall(path)
    }

    // MARK: Startup loader state
    /// True from the moment an open is scheduled until lookout_open returns —
    /// covers the synchronous open (a 7k-cell library takes seconds).
    @Published var isOpening = false
    /// True while the FIRST-run one-time symbol/font atlas bake runs (the app
    /// cache is empty). Drives a distinct "Preparing chart symbols" message.
    @Published var preparingSymbols = false
    /// False until the first scene after an open has actually rendered; with
    /// isOpening it drives the big startup loader (later rebuilds only show
    /// the small BuildingPill).
    @Published var firstBuildDone = false
    var showStartupLoader: Bool { isOpening || (hasChart && !firstBuildDone) }

    /// The number of cells the open is mapping. The loader states it.
    @Published var openingCells = 0

    /// The phase the startup loader shows. Each phase is a different wait: the
    /// first-run atlas bake, the library open, and the first tessellation.
    enum LoadPhase: Equatable {
        case bakingAtlas
        case mapping(cells: Int)
        case tessellating

        var title: String {
            switch self {
            case .bakingAtlas:
                return "Baking the symbol atlas"
            case .mapping(let cells):
                return cells > 1 ? "Mapping \(cells.formatted(.number)) cells" : "Mapping the chart"
            case .tessellating:
                return "Tessellating the first scene"
            }
        }

        var note: String? {
            switch self {
            case .bakingAtlas: return "First launch only. The atlas is cached."
            default: return nil
            }
        }
    }

    var loadingPhase: LoadPhase {
        if preparingSymbols { return .bakingAtlas }
        return isOpening ? .mapping(cells: openingCells) : .tessellating
    }

    // MARK: Live HUD readouts (pushed by ChartController / the chart view)
    @Published var scaleDenominator: Double = 0
    @Published var zoomLevel: Double = 0      // fractional web-mercator zoom
    @Published var scheme: Int = 0            // 0 day, 1 dusk, 2 night
    @Published var rotationDeg: Double = 0
    @Published var overscale: Double = 1.0    // >1 = zoomed past the deepest data
    @Published var centerLat: Double = 0
    @Published var centerLon: Double = 0
    /// Follow mode as the core reports it: 0 off, 1 following own ship, 2 on
    /// and waiting for a fix. Polled on the render tick, never remembered from
    /// a tap: the core turns follow off itself when the mariner pans.
    @Published var followState: Int = 0
    /// Course up as the core reports it: 0 off, 1 turning with own ship, 2 on
    /// and waiting for a heading. Polled like followState.
    @Published var courseUpState: Int = 0
    /// True while the plugin layer is up. Own ship comes from a plugin, so the
    /// follow control is only shown when one can supply a position.
    @Published var pluginsActive = false
    /// What the position readout may say, as the core reports it. Polled on
    /// the render tick beside the position itself, so the two can never
    /// disagree: a readout holding the last numbers through a lost fix would
    /// be presenting a stale one as live.
    @Published var fixState: ChartController.FixState = .none
    /// Own ship's reported position. Both nil unless `fixState` is `.live`;
    /// the readout NEVER falls back to the map centre or the cursor.
    @Published var shipLat: Double?
    @Published var shipLon: Double?
    /// The chart menu, while it is up, and the marker rename field, while the
    /// mariner is typing in it. See the actions further down.
    @Published var chartMenu: ChartMenu?
    @Published var renaming: MarkerRename?
    @Published var renamingText = ""
    /// Where the rename field stands, re-projected every frame: it is anchored
    /// to its marker, not to the screen.
    @Published var renamingPoint: CGPoint?
    /// The overlay object the mariner pinned, and where it draws in the
    /// chrome's coordinate space. One at a time.
    @Published var pinned: OverlayPin?
    @Published var pinnedPoint: CGPoint?
    /// What the plugin overlay says about the symbol under the pointer, and
    /// where the pointer is in the chrome's coordinate space. Both nil when the
    /// pointer is over nothing. Set by the chart view after a hover settles.
    @Published var hover: OverlayHover?
    @Published var hoverPoint: CGPoint?

    /// The cursor pick: the features under the last tap, where it happened (in
    /// the chrome's coordinate space), and which one the report is showing.
    @Published var pickResults: [PickFeature] = []
    @Published var pickPoint: CGPoint?
    @Published var pickIndex = 0
    /// Where on the CHART the pick was taken. The mark belongs to the object,
    /// not to the screen: follow moves the chart with no gesture behind it, so
    /// the mark is re-projected from this every frame.
    var pickGeo: (lon: Double, lat: Double)?
    /// Where the REPORT is docked: the mark's position when the pick was
    /// taken, and fixed for as long as the report is open. The panel's frame
    /// must not depend on anything the camera touches, or a chart sliding
    /// under follow re-lays it out every frame.
    @Published var pickAnchor: CGPoint?
    /// Where a hook-driven pick should anchor its report. The chart view sets it
    /// to the centre of its bounds.
    var pickCentreHint: CGPoint?
    /// The chrome's size: the view inset by the safe area. This is the space
    /// the report is laid out in. The chart view sets it with the hint.
    /// `showPick` reads it to find the report's body and the sheet's edge.
    var chromeSize: CGSize = .zero
    /// How far `showPick` lifted the chart to clear the sheet. `closePick`
    /// puts the chart back by the same amount. Points, in the chrome's space.
    private var pickLift: CGFloat = 0
    @Published var isBuilding = false         // a background tessellation is filling in

    // MARK: iOS sheet/picker presentation (unused on macOS, where the file
    // panel and Settings scene are AppKit-native)
    @Published var showImporter = false
    /// The Add Raster Charts picker. Separate from `showImporter` because the
    /// two import different things to different places: an ENC is copied into
    /// the container and opened, a raster chart is added to the underlay.
    @Published var showRasterImporter = false
    /// The same two pickers again, for the SETTINGS sheet. A presented sheet
    /// cannot present another one from the view it came up over — the pair
    /// above hang on the chart view — so the form attaches its own and these
    /// are the flags that raise them. Add Charts used to dismiss the form and
    /// re-present the picker 0.45s later to get around it; Add Raster Charts
    /// never got that treatment and simply did nothing.
    @Published var showSettingsImporter = false
    @Published var showSettingsRasterImporter = false
    @Published var showSettings = false
    /// Which settings section shows, by its core name — "display", "depths",
    /// "text", "charts", "vessels", "alarms", "connections", "advanced". A
    /// name no section answers to falls back to Display. The screenshot hook
    /// sets it.
    @Published var settingsTab = "display"

    // MARK: Search
    @Published var searchOpen = false
    @Published var searchText = ""

    /// A picture from the pick report, shown over the chart at full size.
    struct Picture: Equatable {
        let name: String
        let data: Data
    }
    @Published var picture: Picture?

    // MARK: Scale entry (tapping the 1:N readout)
    @Published var showScaleEntry = false
    @Published var scaleEntryText = ""

    /// The single chart controller (owned by ChartView; referenced for commands).
    weak var controller: ChartController?

    /// The raster charts the mariner installed. Persisted, because a chart set is a
    /// half-gigabyte download they picked deliberately — asking again every
    /// launch would be its own bug.
    private let rasterKey = "lookout.rastercharts"
    private let rasterOffKey = "lookout.rastercharts.off"
    /// Which SETS are not drawn, by set name. Beside the installed list and the
    /// switched-off list, because all three describe the same charts and any one
    /// of them living somewhere else is a way for them to drift apart.
    ///
    /// Not the same thing as rasterOff. Off means "installed and quiet" and
    /// takes a set out of the pill's list entirely; this is the pill's own
    /// choice of which picture covers this water, and a set that is not drawn is
    /// still offered.
    private let rasterHiddenKey = "lookout.rastercharts.hidden"
    private let chartHiddenKey = "lookout.chart.hidden"

    init() {
        // Drop anything that has since been deleted or unplugged, so a stale
        // entry never becomes an error the mariner has to dismiss at every
        // launch.
        rasterPaths = (UserDefaults.standard.stringArray(forKey: rasterKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
        rasterOff = Set(UserDefaults.standard.stringArray(forKey: rasterOffKey) ?? [])
        rasterHidden = Set(UserDefaults.standard.stringArray(forKey: rasterHiddenKey) ?? [])
        chartHiddenSaved = UserDefaults.standard.bool(forKey: chartHiddenKey)
        // The panel's list. The open itself does not wait on this: it takes
        // the cheap walk in initialChartPaths and starts drawing.
        loadChartSets()
    }

    // MARK: - Opening charts

    /// Paths to open on first appearance: $LOOKOUT_OPEN (a chart or a folder of
    /// cells, for the CLI and the screenshot protocol), else (iOS) everything
    /// in Documents, else the sets that are switched on, else the demo default.
    func initialChartPaths() -> [String] {
        if let p = ProcessInfo.processInfo.environment["LOOKOUT_OPEN"] {
            let cells = cellPaths(for: p)
            if !cells.isEmpty { return cells }
        }
        #if os(iOS)
        // On iOS, Documents IS the chart library (Files.app / Finder-sharing
        // drops and importer copies all land there): compose ALL of it at
        // launch. This must beat the saved sets, which are at most a subset of
        // Documents; launching into one would silently hide the rest of the
        // library (a device that imported a 7k-cell folder would reopen as
        // exactly one cell).
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let dropped = chartPaths(inDirectory: docs.path)
            if !dropped.isEmpty { return dropped }
        }
        #endif
        // The cheap walk, not the scan. Launch must not wait on tile57 opening
        // every archive (3 seconds over the full NOAA library); the engine
        // skips a chart it cannot read anyway. The verified scan runs behind
        // this and fills the Charts panel.
        let off = ChartSetStore.savedOff()
        var aboard: [String] = []
        // The pictures aboard are NOT charts to compose. This walk cannot tell
        // a raster archive from a vector one without opening it, so it takes
        // the answer the last scan already worked out: anything installed as a
        // raster stays out. Opening one as a vector chart composes nonsense.
        var seen = Set(UserDefaults.standard.stringArray(forKey: rasterKey) ?? [])
        for dir in ChartSetStore.savedPaths() where !off.contains(dir) {
            for p in cellPaths(for: dir) where !seen.contains(p) {
                seen.insert(p)
                aboard.append(p)
            }
        }
        if !aboard.isEmpty { return aboard.sorted() }
        if let def = Self.defaultChartPath { return [def] }
        return []
    }

    /// An open target as its concrete cell list: a folder of cells expands to
    /// every baked cell under it, a chart file is itself, a dangling path is
    /// empty (callers fall through to their next candidate).
    private func cellPaths(for target: String) -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else { return [] }
        return isDir.boolValue ? chartPaths(inDirectory: target) : [target]
    }

    /// All baked cells under a directory, sorted (the compose library set).
    func chartPaths(inDirectory dir: String) -> [String] {
        guard let en = FileManager.default.enumerator(atPath: dir) else { return [] }
        var paths: [String] = []
        for case let rel as String in en where rel.hasSuffix(".pmtiles") {
            paths.append((dir as NSString).appendingPathComponent(rel))
        }
        return paths.sorted()
    }

    /// The Zig demo's built-in default, if it happens to exist on this machine.
    static var defaultChartPath: String? {
        let p = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache/chartplotter/NOAA/tiles/d5/US5MD1MC.pmtiles")
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Request opening a chart path: one `.pmtiles` file, or a folder of cells.
    /// The path becomes a set, so opening a chart and adding it to the library
    /// are one act.
    func openChart(_ path: String) {
        addChartSet(path)
    }

    /// Request opening every `.pmtiles` under a directory (compose a library).
    func openChartDirectory(_ dir: String) {
        addChartSet(dir)
    }

    private func requestOpen(_ paths: [String]) {
        // Nothing left to draw at all. Switching off the last set, or removing
        // it, has to take the chart off the display: leaving the old one up
        // says the charts are still aboard when they are not.
        //
        // A set of pictures with no survey in it still draws, so the test is
        // whether anything is aboard, not whether any CELL is.
        guard !paths.isEmpty || !rasterPaths.isEmpty else { closeChart(); return }
        openSeq += 1
        openRequest = OpenRequest(id: openSeq, paths: paths)
        // Show the loader BEFORE the (synchronous, possibly seconds-long) open
        // runs: flag now, open on the next runloop turn so SwiftUI paints.
        openingCells = paths.count
        isOpening = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Drive the controller DIRECTLY rather than relying on the SwiftUI
            // update cycle: once the chart view is live the hosting content
            // view stops receiving updates, so a published request would sit
            // unserviced. The update path remains only as the fallback for a
            // request racing the first layout.
            if let c = self.controller, c.reopen(charts: paths) {
                self.openRequest = nil
            }
            self.isOpening = false
        }
    }

    /// Close the chart and go back to the panel that offers to add some.
    /// The files are untouched; only the display and the engine handle go.
    func closeChart() {
        controller?.close()
        openRequest = nil
        chartPath = nil
        hasChart = false
        firstBuildDone = false
        isOpening = false
    }

    // MARK: - The sets aboard

    /// Every chart the switched-on sets carry, ready to hand to the engine.
    /// Sorted, and with duplicates dropped: two sets may overlap, and the same
    /// cell twice would be composed twice.
    var openPaths: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for set in chartSets where set.on {
            for p in set.openablePaths where !seen.contains(p) {
                seen.insert(p)
                out.append(p)
            }
        }
        return out.sorted()
    }

    /// Look through the folders saved from the last run. The cells are scanned
    /// again rather than stored, because a folder changes underneath the app.
    func loadChartSets(completion: (() -> Void)? = nil) {
        let paths = ChartSetStore.savedPaths()
        let off = ChartSetStore.savedOff()
        guard !paths.isEmpty, !scanning else { completion?(); return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = paths.compactMap { p -> ChartSet? in
                // Either kind counts. A folder of pictures is a set.
                guard var s = ChartScan.scan(p),
                      !s.cells.isEmpty || !s.rasters.isEmpty else { return nil }
                s.on = !off.contains(p)
                return s
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.chartSets = found
                self.scanning = false
                self.syncRasterFromSets()
                // The launch walk cannot see a library of pictures: it looks
                // for cells, and finds none. Open what the scan found once it
                // knows, or a mariner carrying only imagery gets the first-run
                // page every time with their charts sitting on the list.
                if !self.hasChart && (!self.openPaths.isEmpty || !self.rasterPaths.isEmpty) {
                    self.requestOpen(self.openPaths)
                }
                // The saved list is NOT rewritten here. A folder that did not
                // answer this time is a drive that is not plugged in, not a
                // folder the mariner threw away, and writing the shorter list
                // back would lose their charts for good. Only an explicit add
                // or remove changes what is saved.
                completion?()
            }
        }
    }

    /// Look through `path` and put it on the list. A folder with no charts in
    /// it never joins the list, which is what kept dead entries out of reach
    /// of the mariner in the first place.
    func addChartSet(_ path: String) {
        // One at a time. A second bake started while the first runs gets its
        // own job, and then Cancel stops only the one the pill happens to
        // hold: the mariner presses stop and the machine keeps working.
        guard bake == nil, !scanning else {
            emptyPick = "Still working on \(bake?.name ?? scanningName). Wait for it to finish."
            return
        }
        scanning = true
        scanRequested = true
        scanningName = (path as NSString).lastPathComponent
        emptyPick = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ChartScan.scan(path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                // A folder of pictures is a chart folder. There is one list
                // and one way in, so the test is whether the folder holds
                // anything Lookout can draw, of either kind.
                guard let set = found, !set.cells.isEmpty || !set.rasters.isEmpty else {
                    let name = (path as NSString).lastPathComponent
                    self.emptyPick = "\(name) holds no charts Lookout can read."
                    return
                }
                // Raw cells cannot be drawn. Bake them first, then take the
                // baked folder as the set.
                // S-57 and S-101 cells, and BSB/KAP sheets, are all prepared
                // the same way and by the same engine call.
                if set.needsBake > 0 {
                    self.beginBake(sourceDir: set.path, cells: set.toPrepare)
                    return
                }
                self.adopt(set)
            }
        }
    }

    /// Put a set on the list.
    ///
    /// `reopen` is false when the charts are already drawing. A bake hands
    /// each batch to the open library as it finishes, so by the end there is
    /// nothing left to open: reopening would tear down a chart that is
    /// already correct and show the startup loader over it for a moment.
    private func adopt(_ set: ChartSet, reopen: Bool = true) {
        chartSets.removeAll { $0.path == set.path }
        chartSets.append(set)
        ChartSetStore.add(set.path)
        syncRasterFromSets()
        if reopen { requestOpen(openPaths) }
    }

    /// The pictures the switched-on sets carry, installed as the raster charts.
    ///
    /// A set is a folder of charts, and a folder can hold both kinds. The
    /// mariner adds it once and switches it on once; which of its files are
    /// the survey and which are photographs is the app's problem, not theirs.
    private func syncRasterFromSets() {
        var seen = Set<String>()
        var wanted: [String] = []
        for set in chartSets where set.on {
            for p in set.rasterPaths where !seen.contains(p) {
                seen.insert(p)
                wanted.append(p)
            }
        }
        // Anything the mariner added before sets existed stays aboard.
        for p in rasterPaths where !seen.contains(p) && !ChartBake.isDerived(p) {
            let inAnySet = chartSets.contains { $0.rasterPaths.contains(p) }
            if !inAnySet {
                seen.insert(p)
                wanted.append(p)
            }
        }
        guard wanted != rasterPaths else { return }
        rasterPaths = wanted
        UserDefaults.standard.set(rasterPaths, forKey: rasterKey)
    }

    // MARK: - Baking raw cells

    /// The bake running now, if any. The HUD pill watches this.
    @Published var bake: BakeProgress?
    private var bakeJob: ChartBakeJob?

    /// Any chart work running now: a scan or a bake. The pill, the first-run
    /// panel and the Charts settings all read this one value, so the work
    /// appears wherever the mariner is looking.
    var chartWork: BakeProgress? {
        if let b = bake { return b }
        // Only work the mariner started. The scan at launch is bookkeeping for
        // the Charts panel and finishes on its own; showing it puts "Finding
        // charts" over the window on every single launch, before a chart the
        // app already knows how to open.
        if scanning && scanRequested { return BakeProgress(name: scanningName) }
        return nil
    }
    /// True while the scan running was asked for by the mariner.
    @Published var scanRequested = false

    /// The work to show in place of the first-run picker: a scan or a bake,
    /// while there is still no chart to draw. Nil once a chart is up, because
    /// from then on the pill carries it and the chart is the thing to look at.
    var firstRunWork: BakeProgress? { chartWork }
    /// The folder being looked through, for the first-run text.
    @Published var scanningName = ""

    /// Bake `sourceDir` into the app's own chart directory, then add the
    /// result as the set. The mariner keeps sailing while this runs: it is a
    /// pill in the HUD, not a modal.
    private func beginBake(sourceDir: String, cells: [ScannedCell]) {
        let job = ChartBakeJob()
        bakeJob = job
        let total = cells.filter(\.needsBake).count
        bake = BakeProgress(done: 0, total: total,
                            name: (sourceDir as NSString).lastPathComponent)
        job.onProgress = { [weak self] p in
            guard let self else { return }
            // The count moves on tile57's thread once per cell. Keep the total
            // from the scan when tile57 has not counted yet, so the bar never
            // starts at an unknown length.
            var shown = p
            if shown.total == 0 { shown.total = total }
            self.bake = shown
        }
        ChartBake.run(sourceDir: sourceDir, cells: cells, job: job) { [weak self] outDir in
            guard let self else { return }
            self.bakeJob = nil
            // The panel stays up across the last read of the folder. Clearing
            // it here drops the window back to the first-run page for as long
            // as that takes, and then the chart arrives: the mariner watches
            // their work apparently undone.
            self.scanning = true
            self.scanRequested = true
            self.bake = nil
            guard let outDir else {
                self.scanning = false
                self.emptyPick = "Could not bake \((sourceDir as NSString).lastPathComponent)."
                return
            }
            // Read the folder again, not the output directory. The set is the
            // folder the mariner picked; what was prepared is part of it, and
            // so is everything that needed no preparing.
            DispatchQueue.global(qos: .userInitiated).async {
                let whole = ChartScan.scan(sourceDir)
                DispatchQueue.main.async {
                    self.scanning = false
                    self.scanRequested = false
                    guard let whole, !whole.cells.isEmpty || !whole.rasters.isEmpty else {
                        self.emptyPick = "Nothing could be prepared from \((sourceDir as NSString).lastPathComponent)."
                        return
                    }
                    self.adopt(whole)
                }
            }
        }
    }

    /// Stop the bake. What has already been baked is kept and opened.
    func cancelBake() {
        bakeJob?.cancel()
    }

    /// Switch a set on or off. It stays aboard either way. The library is
    /// composed at open, so this reopens with the new set of charts.
    func setChartSetOn(_ path: String, _ on: Bool) {
        guard let i = chartSets.firstIndex(where: { $0.path == path }) else { return }
        chartSets[i].on = on
        ChartSetStore.setOff(path, !on)
        syncRasterFromSets()
        requestOpen(openPaths)
    }

    /// The set the mariner asked to remove, held while they are asked whether
    /// they meant it. Only a set Lookout prepared charts for: taking a folder
    /// of the mariner's own files off the list deletes nothing, so it needs no
    /// question.
    @Published var pendingRemoval: ChartSet?

    /// About how long re-importing a set would take, from what it holds. The
    /// mariner is deciding whether to throw away work, so the size of that
    /// work is the fact they need.
    func rebuildEstimate(_ set: ChartSet) -> String {
        let n = max(set.cells.count + set.rasters.count, 1)
        // Measured on this machine over a mixed Chesapeake set: about a fifth
        // of a second a chart with every core working.
        let seconds = Double(n) * 0.2
        if seconds < 60 { return "under a minute" }
        if seconds < 3600 { return "about \(Int((seconds / 60).rounded())) minutes" }
        return String(format: "about %.1f hours", seconds / 3600)
    }

    /// Take a set off the list.
    ///
    /// Charts this app prepared are deleted with it: they were made from the
    /// mariner's cells and can be made again, and a 3 GB library left behind
    /// by a set the mariner removed is the app hoarding on their disk. A
    /// folder of the mariner's OWN charts is only taken off the list.
    func removeChartSet(_ path: String) {
        let prepared = chartSets.first { $0.path == path }?.preparedPath
        chartSets.removeAll { $0.path == path }
        ChartSetStore.remove(path)
        syncRasterFromSets()
        if let prepared { ChartBake.deleteDerived(prepared) }
        requestOpen(openPaths)
    }

    /// Show the chart picker: the AppKit open panel on macOS, the document
    /// importer on iOS. The charts bubble, the empty state and the File menu all
    /// use it.
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

    // MARK: - Commands (menu / buttons)

    func zoomIn()   { controller?.zoomCentered(+1.0) }
    func zoomOut()  { controller?.zoomCentered(-1.0) }
    func zoomToFit(){ controller?.fitChart() }
    func northUp()  { controller?.resetRotation() }

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

    // MARK: - The chart menu, and markers

    /// The menu raised at a point on the water. Every item acts on THIS point:
    /// not the map centre, and not where the cursor drifts to afterwards, so
    /// the coordinates are taken once, when the menu opens, and carried here.
    struct ChartMenu: Equatable {
        /// Where the menu stands, in the chrome's coordinate space.
        let at: CGPoint
        let lon: Double
        let lat: Double
        /// The mark under the press, when there is one. Over a marker the menu
        /// offers Rename and Remove in place of Drop.
        let marker: ChartController.Marker?
    }

    /// Which marker is being renamed, and where it is. The name being typed is
    /// `renamingText`.
    struct MarkerRename: Equatable {
        let id: UInt64
        let lon: Double
        let lat: Double
    }

    /// Raise the menu at a point on the chart, in the chrome's coordinate
    /// space. A pinned bubble goes: one thing at a time over the chart.
    func openChartMenu(at p: CGPoint) {
        guard let c = controller, let g = c.geo(atPoint: p) else { return }
        closePin()
        cancelRename()
        chartMenu = ChartMenu(at: p, lon: g.lon, lat: g.lat, marker: c.marker(atPoint: p))
    }

    func closeChartMenu() {
        if chartMenu != nil { chartMenu = nil }
    }

    /// "Pick report": the report for the point the menu was raised at.
    /// The report itself is unchanged; only how it is raised has.
    func chartMenuPick() {
        guard let m = chartMenu, let c = controller else { return }
        chartMenu = nil
        showPick(c.pick(lon: m.lon, lat: m.lat), at: m.at)
    }

    /// "Drop marker": placed at once, named by the core, and the menu closes.
    /// The drop never waits for typing: a mariner drops a mark one-handed on a
    /// moving boat, often to record something they have just seen.
    func chartMenuDropMarker() {
        guard let m = chartMenu, let c = controller else { return }
        chartMenu = nil
        c.dropMarker(lon: m.lon, lat: m.lat)
    }

    /// "Copy position": the point's coordinates in the mariner's own format,
    /// the one the readout, the deck log and the radio all use.
    func chartMenuCopyPosition() {
        guard let m = chartMenu else { return }
        chartMenu = nil
        Pasteboard.copy(CoordFormat.position(lat: m.lat, lon: m.lon))
    }

    func chartMenuRenameMarker() {
        guard let mark = chartMenu?.marker else { return }
        chartMenu = nil
        beginRename(mark)
    }

    func chartMenuRemoveMarker() {
        guard let mark = chartMenu?.marker, let c = controller else { return }
        chartMenu = nil
        _ = c.removeMarker(mark.id)
    }

    /// Open the rename field on a marker, with its current name in it.
    func beginRename(_ mark: ChartController.Marker) {
        renaming = MarkerRename(id: mark.id, lon: mark.lon, lat: mark.lat)
        renamingText = mark.name
        renamingPoint = controller?.screenPoint(forGeoLon: mark.lon, lat: mark.lat)
    }

    /// Return commits. An empty field keeps the old name, which the core
    /// decides, so every shell agrees on what an emptied field means.
    func commitRename() {
        guard let r = renaming else { return }
        controller?.renameMarker(r.id, to: renamingText)
        cancelRename()
    }

    /// Escape abandons.
    func cancelRename() {
        if renaming != nil { renaming = nil }
        if !renamingText.isEmpty { renamingText = "" }
        if renamingPoint != nil { renamingPoint = nil }
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

    /// Pin an overlay object's bubble. It replaces any bubble already up, and
    /// a hover tooltip never shares the screen with one.
    func pin(_ p: OverlayPin) {
        hover = nil
        hoverPoint = nil
        pinned = p
        pinnedPoint = controller?.screenPoint(forGeoLon: p.lon, lat: p.lat)
    }

    func closePin() {
        if pinned != nil { pinned = nil }
        if pinnedPoint != nil { pinnedPoint = nil }
    }

    #if os(macOS)
    /// Every table the loaded plugins declare, in declaration order. The
    /// Vessels menu is built from this, so the items follow the plugins that
    /// are up: a plugin that unloads takes its item with it.
    @Published var pluginTables: [PluginTableSpec] = []

    /// The tables the loaded plugins declare. The menu is built from this, so
    /// setting it is all it takes to make the items appear.
    func refreshPluginTables() {
        guard let c = controller else { return }
        pluginTables = c.tableSpecs()
    }

    #endif

    // MARK: Plugin alerts
    //
    // Cross-platform: the banner, the poll and the siren all run on iOS too,
    // so the plugins reach an iPad mariner. Only the declared-table windows
    // above (NSWindow) and the reveal-on-chart paths stay macOS-only.

    /// Every alert the plugins have raised, most urgent first. The banner over
    /// the chart is built from this.
    @Published var alerts: [PluginAlert] = []

    /// How often the core is asked for its alerts. The plugins raise them from
    /// their own threads with no gesture behind them, so nothing else would
    /// bring one to the screen.
    private static let alertPollInterval: TimeInterval = 1.0

    private var alertTimer: Timer?
    private let siren = AlarmSiren()
    /// The last set the core reported. The list is rebuilt only when it moves.
    private var alertSeq = -1

    /// Start watching for alerts. Called once the plugin layer is up.
    func startAlertWatch() {
        guard alertTimer == nil else { return }
        refreshAlerts()
        alertTimer = Timer.scheduledTimer(withTimeInterval: Self.alertPollInterval,
                                          repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAlerts() }
        }
    }

    /// Stop watching, and stop sounding. The chart is going away with the
    /// plugins that raised the alarms.
    func stopAlertWatch() {
        alertTimer?.invalidate()
        alertTimer = nil
        alertSeq = -1
        siren.setSounding(false)
        if !alerts.isEmpty { alerts = [] }
    }

    private func refreshAlerts() {
        guard let got = controller?.pluginAlerts() else {
            // Nothing readable from the core. The polling continues, because
            // stopping it would leave the boat deaf for the rest of the
            // session over one unanswered read.
            alertSeq = -1
            if !alerts.isEmpty { alerts = [] }
            siren.setSounding(false)
            return
        }
        if got.seq != alertSeq {
            alertSeq = got.seq
            alerts = got.alerts
        }
        // An alarm nobody has answered keeps sounding. A warning is shown and
        // never sounded, so it is not counted here.
        siren.setSounding(alerts.contains { $0.severity.audible && !$0.acknowledged })
    }

    /// Silence one alert, and show the change without waiting for the next
    /// poll: the mariner pressed a control and must see it answer.
    func acknowledgeAlert(_ alert: PluginAlert) {
        guard controller?.acknowledgeAlert(alert.id) == true else { return }
        alertSeq = -1
        refreshAlerts()
    }

    #if os(macOS)
    /// Open one declared table's window, or bring it forward.
    func showPluginTable(_ spec: PluginTableSpec) {
        _ = PluginTableWindowController.show(spec, model: self)
    }

    /// Pin one declared table row on the chart by its id, for the screenshot
    /// protocol's LOOKOUT_SHOW=target:<id>. The empty id takes the first row
    /// of the declared sort, which for the AIS targets is the nearest
    /// approach. This is the locate-on-chart path a double-click takes, minus
    /// the dialog, so the frame holds the chart and the bubble alone.
    func revealTableRow(_ id: String) {
        guard let c = controller, let spec = c.tableSpecs().first(where: { $0.locatable })
        else { return }
        // A plugin builds no rows until it is told the dialog is open, so the
        // dialog is opened to make them, read, and shut again. What is wanted
        // is the bubble on the chart, not the dialog over it.
        let window = PluginTableWindowController.show(spec, model: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            defer { window.dismiss() }
            guard let self,
                  let got = c.tableRows(plugin: spec.plugin, key: spec.key,
                                        sortKey: spec.sortKey, ascending: spec.sortAscending,
                                        columns: spec.columns.count) else { return }
            let row = id.isEmpty ? got.rows.first : got.rows.first { $0.id == id }
            guard let row, let lat = row.lat, let lon = row.lon else { return }
            self.revealOnChart(lon: lon, lat: lat)
        }
    }

    /// Show a place a plugin table row named: centre the chart on it and pin
    /// the bubble of whatever the plugin draws there. A row with no position
    /// never gets here.
    func revealOnChart(lon: Double, lat: Double) {
        guard let c = controller else { return }
        if let hit = c.reveal(lon: lon, lat: lat) { pin(hit) } else { closePin() }
    }

    /// Open one declared table, for the screenshot protocol's
    /// LOOKOUT_SHOW=table[:key[:sort[:asc|desc[:activate]]]]. The first
    /// declaration when no key is named, and the declared sort unless one is
    /// asked for — which is the same choice a mariner makes by clicking a
    /// column heading. `activate` opens the top row the way a double-click
    /// does, so the locate-on-chart path can be photographed.
    func openPluginTable(_ spec: String) {
        guard let c = controller else { return }
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let key = parts.first ?? ""
        let specs = c.tableSpecs()
        let want = key.isEmpty ? specs.first : specs.first { $0.key == key }
        guard let want else { return }
        let window = PluginTableWindowController.show(want, model: self,
                                                      sortKey: parts.count > 1 ? parts[1] : nil,
                                                      ascending: parts.count < 3 || parts[2] != "desc")
        guard parts.count > 3, parts[3] == "activate" else { return }
        // A moment for the plugin's first batch: it builds no rows until it is
        // told the dialog is open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { window.activateTopRow() }
    }
    #endif
    /// Scheme changes from the MENU must persist like ones from the settings
    /// form (the form saves in its own apply path).
    func cycleScheme() {
        guard let c = controller else { return }
        c.cycleScheme()
        MarinerSettings.save(c.getMariner())
    }
    /// Hide or show the vector chart, leaving the picture beneath it.
    func toggleChart() {
        guard let c = controller else { return }
        c.toggleChart()
        chartHidden = c.chartHidden()
        chartHiddenSaved = chartHidden
        UserDefaults.standard.set(chartHidden, forKey: chartHiddenKey)
    }

    /// Install the raster charts the mariner chose. Files that will not open are reported
    /// together rather than one alert at a time — picking a folder of twenty and
    /// being asked twenty times would be unusable.
    func addRasterCharts(_ paths: [String]) {
        guard let c = controller else { return }
        var failed: [String] = []
        for p in paths where !rasterPaths.contains(p) {
            if c.addRaster(p) {
                rasterPaths.append(p)
            } else {
                failed.append((p as NSString).lastPathComponent)
            }
        }
        UserDefaults.standard.set(rasterPaths, forKey: rasterKey)

        // Read the whole state back, not just the name. The pill is built from
        // rasterSets and rasterAvailable, and those reach it through the frame
        // readouts — which never come while the chart sits idle behind the open
        // panel. Without this, adding a chart over the water you are looking at
        // appeared to do nothing at all.
        refreshRasterState()

        // Draw what was just added, if it covers this view. The mariner picked
        // these files deliberately while looking at this water; showing them is
        // the obvious answer, and the pill takes them back in one click.
        if let added = paths.last(where: { rasterPaths.contains($0) }) {
            let name = AppModel.providerLabel(added)
            if let set = rasterSets.first(where: { $0.name == name && $0.inView }) {
                selectRasterSet(set.id)
            }
        }

        if !failed.isEmpty {
            openError = failed.count == 1
                ? "Couldn't open \(failed[0]).\nIt may not be a raster chart tile57 reads."
                : "Couldn't open \(failed.count) of \(paths.count) files:\n" + failed.joined(separator: "\n")
        }
    }

    /// Pull every published raster field off the controller at once. Anything
    /// that changes the set list or the selection outside a frame must call
    /// this: the readouts only run while the chart renders.
    func refreshRasterState() {
        guard let c = controller else { return }
        rasterName = c.rasterName()
        rasterActive = c.rasterActiveIndex()
        rasterSets = c.rasterSets()
        rasterAvailable = c.rasterAvailableName()
        chartHidden = c.chartHidden()
        saveRasterShown()
    }

    /// Write down which sets are drawn. Everything that can move the selection
    /// comes through refreshRasterState, so this is the one place it is saved:
    /// the pill's menu, the Chart menu, the cycle key, and switching a chart off
    /// in Settings, which can move the selection on its own.
    ///
    /// Read back from the engine rather than tracked here. The engine owns the
    /// election — showing one set turns off the sets covering the same water —
    /// so what it says after the change is the only account that can be right.
    ///
    /// Sets that are not installed this launch keep their entry: a mariner who
    /// unplugs the drive holding one has not changed their mind about it.
    private func saveRasterShown() {
        guard let sets = controller?.rasterSets(), !sets.isEmpty else { return }
        var hidden = rasterHidden
        for s in sets {
            if s.shown { hidden.remove(s.name) } else { hidden.insert(s.name) }
        }
        guard hidden != rasterHidden else { return }
        rasterHidden = hidden
        UserDefaults.standard.set(Array(hidden), forKey: rasterHiddenKey)
    }

    /// Draw one set, or none for -1.
    func selectRasterSet(_ i: Int) {
        guard let c = controller else { return }
        c.rasterSelect(i)
        refreshRasterState()
    }

    /// The installed files grouped by the provider their name gives — the same
    /// grouping the engine uses for a set, so what Settings shows and what the
    /// pill cycles are the same thing.
    var rasterGroups: [(name: String, paths: [String])] {
        var order: [String] = []
        var byName: [String: [String]] = [:]
        for p in rasterPaths {
            let n = AppModel.providerLabel(p)
            if byName[n] == nil { order.append(n) }
            byName[n, default: []].append(p)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }

    /// Is any file of this set on?
    func rasterGroupOn(_ paths: [String]) -> Bool {
        paths.contains { !rasterOff.contains($0) }
    }

    /// Turn a whole set on or off. Off keeps every file installed.
    func setRasterGroupEnabled(_ paths: [String], _ on: Bool) {
        for p in paths { setRasterEnabled(p, on) }
    }

    /// Turn one raster chart on or off. It stays installed either way.
    func setRasterEnabled(_ path: String, _ on: Bool) {
        if on { rasterOff.remove(path) } else { rasterOff.insert(path) }
        UserDefaults.standard.set(Array(rasterOff), forKey: rasterOffKey)
        controller?.setRasterEnabled(path, on)
        // Read the selection back: switching off the last file of the drawn set
        // moves the selection, and the pill must not keep naming a chart that
        // is off. Settings can be open while the chart is idle, so this cannot
        // wait for the next frame's readouts.
        refreshRasterState()
    }

    /// Remove one source. The engine cannot drop a source from a live handle,
    /// so this takes effect the next time a chart opens.
    func removeRasterChart(_ path: String) {
        rasterPaths.removeAll { $0 == path }
        rasterOff.remove(path)
        UserDefaults.standard.set(rasterPaths, forKey: rasterKey)
        UserDefaults.standard.set(Array(rasterOff), forKey: rasterOffKey)
    }

    /// What to call the set a file belongs to — mirrors the engine's rule.
    ///
    /// A community MBTiles names its provider, and that is what a mariner
    /// chooses between. A baked sheet does not: `tile57 bake` writes one
    /// directory per sheet under a bake root, and a bundle holds hundreds, so
    /// they belong to the bake they came from.
    static func providerLabel(_ path: String) -> String {
        let ns = path as NSString
        let base = ns.lastPathComponent
        for k in ["ArcGIS", "Bing", "Google", "Navionics", "ESRI", "Esri",
                  "CMap", "C-Map", "Sentinel", "NAIP", "OSM", "Imagery"] {
            if base.range(of: k, options: .caseInsensitive) != nil { return k }
        }
        let stem = (base as NSString).deletingPathExtension
        if base.lowercased().hasSuffix(".pmtiles") {
            let dir = ns.deletingLastPathComponent
            if (dir as NSString).lastPathComponent == stem {
                let root = ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if !root.isEmpty { return root }
            }
        }
        return stem.isEmpty ? base : stem
    }

    /// Forget every installed source. The engine has no remove yet, so this
    /// takes effect on the next chart open — say so where it is offered.
    ///
    /// The switched-off and not-drawn lists go with it. They are keyed by path
    /// and set name, so leaving them behind means the same file added again
    /// months later comes back switched off with nothing on screen to say why.
    func clearRasterCharts() {
        rasterPaths.removeAll()
        rasterOff.removeAll()
        rasterHidden.removeAll()
        UserDefaults.standard.set(rasterPaths, forKey: rasterKey)
        UserDefaults.standard.set(Array(rasterOff), forKey: rasterOffKey)
        UserDefaults.standard.set(Array(rasterHidden), forKey: rasterHiddenKey)
    }

    /// Step to the next raster chart set, with "no picture" as one position — so the
    /// same control also reaches the full chart.
    func cycleRaster() {
        guard let c = controller else { return }
        // Nothing installed: the cycle has nowhere to go, so offer the picker
        // rather than letting the key press do nothing at all.
        if rasterPaths.isEmpty {
            #if os(macOS)
            presentRasterPanel()
            #endif
            return
        }
        c.cycleRaster()
        // The whole state, not just the name: the cycle moves which set is drawn,
        // and that has to reach the pill's mark and the saved selection at once
        // rather than waiting on the next frame's readouts.
        refreshRasterState()
    }
    /// Set the color scheme directly (0 day / 1 dusk / 2 night).
    func setScheme(_ s: Int) {
        guard let c = controller else { return }
        var m = c.getMariner()
        m.scheme = tile57_scheme(UInt32(s))
        c.setMariner(m)
        MarinerSettings.save(m)
    }
    func toggleText() { controller?.toggleText() }
    func toggleSoundings() { controller?.toggleSoundings() }
    func toggleOtherCategory() { controller?.toggleOtherCategory() }

    // MARK: - Search: coordinate go-to (feature/place search deferred)

    /// Parse the search text as a coordinate and recenter. Returns true if it was
    /// a recognizable coordinate (so the UI can clear/collapse results).
    @discardableResult
    func submitSearch() -> Bool {
        guard let controller, let coord = CoordinateParser.parse(searchText) else { return false }
        let cur = controller.currentView
        // Keep the current zoom & rotation; a fresh chart-less view uses a sensible
        // harbour-ish zoom.
        let zoom = cur.zoom > 0 ? cur.zoom : 12
        controller.setView(lookout_view(lon: coord.lon, lat: coord.lat,
                                        zoom: zoom, rotation_deg: cur.rotation_deg))
        return true
    }

    /// Show a pick report for `results` at `point`. An empty result closes it:
    /// a tap on bare water is how a mariner dismisses the report.
    ///
    /// The order and the filtering belong to the core (lookout_pick_ranked), so
    /// the shells cannot drift apart on what a pick reports.
    func showPick(_ results: [PickFeature], at point: CGPoint) {
        pickResults = results
        pickPoint = results.isEmpty ? nil : point
        pickIndex = 0
        pickGeo = results.isEmpty ? nil : controller?.geo(atPoint: point)
        pickAnchor = pickPoint
        // A sheet covers part of the chart, so the object can fall under it.
        // Lift the chart until the mark clears the sheet, and move the mark
        // with it. Only a sheet needs this. A callout stands over its object
        // and does not hide it.
        pickLift = 0
        if let p = pickPoint, let lift = sheetLift(for: p), lift > 0 {
            controller?.panRevealingPick(dxPt: 0, dyPt: -lift)
            pickPoint = CGPoint(x: p.x, y: p.y - lift)
            pickGeo = controller?.geo(atPoint: pickPoint!)
            pickAnchor = pickPoint
            pickLift = lift
        }
        // The screenshot protocol's view of a pick: where, and what came
        // back. What a pick MISSES is diagnosed from here.
        if ProcessInfo.processInfo.environment["LOOKOUT_HITMAP"] != nil {
            let classes = results.map(\.cls).joined(separator: ",")
            NSLog("[pick] at (%.0f, %.0f) -> [%@]", point.x, point.y, classes)
        }
    }

    func closePick() {
        // Put the chart back where the mariner left it (§2.5). This undoes
        // only the lift the app made.
        if pickLift != 0 {
            controller?.panRevealingPick(dxPt: 0, dyPt: pickLift)
            pickLift = 0
        }
        pickResults = []
        pickPoint = nil
        pickGeo = nil
        pickAnchor = nil
        pickIndex = 0
    }

    /// How far the chart must rise for a mark at `point` to clear the bottom
    /// sheet. Returns nil when the view does not use a sheet.
    ///
    /// The test is the report's body, not the device, because the body
    /// decides what covers the object. The sheet is the narrow-screen body,
    /// so this is the phone in practice. Only the iOS chart view sets
    /// `chromeSize`, so a narrow Mac window does not move.
    private func sheetLift(for point: CGPoint) -> CGFloat? {
        guard chromeSize.width > 0, chromeSize.height > 0 else { return nil }
        guard OverlayLayer.pickForm(for: chromeSize) == .bottomSheet else { return nil }
        let sheetTop = chromeSize.height - OverlayLayer.bottomSheetSize(in: chromeSize).height
        // The whole mark must clear the sheet's edge, not just its centre.
        let clear = PickMarker.size / 2 + Chrome.gap
        return max(0, (point.y + clear) - sheetTop)
    }

    /// A point at a fraction of the view. The hooks below have no pointer to
    /// press with, so they name a fraction instead.
    private func viewPoint(fx: Double, fy: Double) -> CGPoint? {
        guard let centre = pickCentreHint else { return nil }
        return CGPoint(x: centre.x * 2 * fx, y: centre.y * 2 * fy)
    }

    /// A hook-driven pick at a fraction of the view: the screenshot protocol's
    /// way of picking away from the centre, LOOKOUT_SHOW=pick:0.5x0.85.
    func pickAt(fx: Double, fy: Double) {
        guard let controller, let p = viewPoint(fx: fx, fy: fy),
              let g = controller.geo(atPoint: p) else { return }
        showPick(controller.pick(lon: g.lon, lat: g.lat), at: p)
    }

    /// Raise the chart menu at a fraction of the view, as a right-click there
    /// would: LOOKOUT_SHOW=menu:0.5x0.5.
    func showChartMenu(fx: Double, fy: Double) {
        guard let p = viewPoint(fx: fx, fy: fy) else { return }
        openChartMenu(at: p)
    }

    /// Drop a marker at a fraction of the view: LOOKOUT_SHOW=marker:0.45x0.5.
    func showDropMarker(fx: Double, fy: Double) {
        guard let c = controller, let p = viewPoint(fx: fx, fy: fy),
              let g = c.geo(atPoint: p) else { return }
        c.dropMarker(lon: g.lon, lat: g.lat)
    }

    /// Open the rename field on the newest mark: LOOKOUT_SHOW=rename.
    func showRenameNewestMarker() {
        guard let mark = controller?.markers().last else { return }
        beginRename(mark)
    }

    /// Run a cursor pick at the view centre. A tap on the chart runs the same
    /// pick; the screenshot hook has no cursor to tap with.
    func pickAtCentre() {
        guard let controller else { return }
        guard let point = pickCentreHint else { return }
        showPick(controller.pick(lon: centerLon, lat: centerLat), at: point)
    }

    var schemeName: String {
        switch scheme { case 1: return "Dusk"; case 2: return "Night"; default: return "Day" }
    }

    // MARK: - Go to a scale (tap the 1:N readout)

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

/// The scale parser. It accepts "25000", "25,000", "1:25000", "25k" and
/// "1:2.5M".
enum ScaleParser {
    static func parse(_ raw: String) -> Double? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // In "1:25k", the text before the colon is the 1.
        if let colon = s.lastIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
        s = s.filter { !$0.isWhitespace && $0 != "," }
        var multiplier = 1.0
        if s.hasSuffix("k") { multiplier = 1_000; s.removeLast() }
        else if s.hasSuffix("m") { multiplier = 1_000_000; s.removeLast() }
        guard let n = Double(s), n.isFinite else { return nil }
        let denominator = n * multiplier
        // A value outside this range is not a chart scale.
        guard denominator >= 100, denominator <= 100_000_000 else { return nil }
        return denominator
    }
}

/// Tolerant lat/lon parser: decimal pairs ("38.98, -76.48") and DMS with
/// hemispheres ("38°58.8'N 076°29.0'W", "38 58 30 N, 76 29 W").
enum CoordinateParser {
    static func parse(_ raw: String) -> (lat: Double, lon: Double)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.uppercased().contains(where: { "NSEW".contains($0) }) {
            return parseHemispheres(s)
        }
        // Decimal pair, comma- or whitespace-separated (lat first).
        let parts = s.split { $0 == "," || $0 == " " }.map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return (lat, lon)
    }

    private static func parseHemispheres(_ s: String) -> (lat: Double, lon: Double)? {
        // deg [min [sec]] hemisphere — minutes/seconds optional.
        let pattern = #"(\d+(?:\.\d+)?)\s*[°\s]\s*(?:(\d+(?:\.\d+)?)\s*['′\s]\s*)?(?:(\d+(?:\.\d+)?)\s*["″\s]\s*)?([NSEW])"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var lat: Double?, lon: Double?
        for m in matches {
            func grp(_ i: Int) -> Double? {
                let r = m.range(at: i); guard r.location != NSNotFound else { return nil }
                return Double(ns.substring(with: r))
            }
            guard let deg = grp(1) else { continue }
            var value = deg + (grp(2) ?? 0) / 60 + (grp(3) ?? 0) / 3600
            let hemi = ns.substring(with: m.range(at: 4)).uppercased()
            if hemi == "S" || hemi == "W" { value = -value }
            if hemi == "N" || hemi == "S" { lat = value } else { lon = value }
        }
        if let lat, let lon { return (lat, lon) }
        return nil
    }
}
