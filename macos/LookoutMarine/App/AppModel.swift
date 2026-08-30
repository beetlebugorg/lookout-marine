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
@Observable
final class AppModel {
    // MARK: Chart state
    var hasChart = false
    /// The active raster chart set's name, or "" for no picture. Shown at all times
    /// while a picture is on: the chart drops its opaque water and land fills to
    /// let the picture through, and the mariner must never mistake that display
    /// for the full chart.
    var rasterName = ""
    /// Every raster chart file the mariner has installed, in the order added. The
    /// controller replays these into each newly opened chart, so a raster chart
    /// survives switching charts and relaunching.
    var rasterPaths: [String] = []
    /// True only while a picture is really beneath the view and the chart is
    /// therefore drawing without its opaque fills. The HUD badge keys off this,
    /// not off the selected set — a badge that appeared whenever a raster chart was
    /// merely installed would claim the chart was reduced when it was not.
    var rasterInView = false
    /// True while the vector chart is hidden and only the picture shows.
    var chartHidden = false
    /// The set that covers this view, DRAWN OR NOT. Empty when none does. The
    /// pill appears only when this is set: a control that is useless here is
    /// noise, and one that says nothing about what is available teaches nothing.
    var rasterAvailable = ""
    /// The installed charts the mariner has switched OFF. They stay installed:
    /// these are half-gigabyte downloads, and carrying four providers for one
    /// coast means wanting three of them quiet, not deleted.
    var rasterOff: Set<String> = []
    /// The sets the mariner has turned off at the pill, by set name. Read at
    /// launch and applied before the first frame; written whenever the drawn set
    /// changes. Without it the engine's own rule wins every launch — adding a
    /// source draws it — and a chart switched off comes back.
    var rasterHidden: Set<String> = []
    /// Was the ENC hidden over the picture when the app last quit? Applied at
    /// open; `chartHidden` is the live state.
    var chartHiddenSaved = false
    /// Every set, with whether it is in view. The pill's menu is built from it.
    var rasterSets: [ChartController.RasterSet] = []
    /// The drawn set's index, or -1.
    var rasterActive = -1
    var chartPath: String?
    /// The folders of charts aboard, in the order added. A set on this list has
    /// been looked through and holds charts, so it always opens.
    var chartSets: [ChartSet] = []
    /// True while a folder is being looked through. The full NOAA library takes
    /// about 3 seconds.
    var scanning = false
    /// The last folder that held no charts, for the panel to say so.
    var emptyPick: String?
    var openRequest: OpenRequest?
    var openError: String?
    var openSeq = 0

    // MARK: Plugin install
    /// The package on the consent sheet: set by beginPluginInstall, cleared by
    /// Install or Cancel. The sheet presents while this is non-nil.
    var pendingInstall: PluginPackage?
    /// The sentence of the last refused install, for its own alert — an
    /// install refusal is not a chart error.
    var installError: String?
    /// A .lkplug opened before any chart was: kept until the chart (and with
    /// it the plugin layer) is up, then inspected.
    var pendingInstallPath: String?
    /// The temporary directory holding a package copied off the Files picker,
    /// deleted once the sheet is answered either way.
    var pendingInstallCopy: URL?

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
        dropPluginCopy()
    }

    /// Throw away a package copied off the Files picker. The core keeps its own
    /// copy of anything it installed, and a cancel keeps nothing.
    func dropPluginCopy() {
        guard let dir = pendingInstallCopy else { return }
        pendingInstallCopy = nil
        try? FileManager.default.removeItem(at: dir)
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
    var isOpening = false
    /// True while the FIRST-run one-time symbol/font atlas bake runs (the app
    /// cache is empty). Drives a distinct "Preparing chart symbols" message.
    var preparingSymbols = false
    /// False until the first scene after an open has actually rendered; with
    /// isOpening it drives the big startup loader (later rebuilds only show
    /// the small BuildingPill).
    var firstBuildDone = false
    var showStartupLoader: Bool { isOpening || (hasChart && !firstBuildDone) }

    /// The number of cells the open is mapping. The loader states it.
    var openingCells = 0

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
    /// True while the plugin layer is up. Own ship comes from a plugin, so the
    /// follow control is only shown when one can supply a position.
    var pluginsActive = false
    /// What the position readout may say, as the core reports it. Polled on
    /// the render tick beside the position itself, so the two can never
    /// disagree: a readout holding the last numbers through a lost fix would
    /// be presenting a stale one as live.
    var fixState: ChartController.FixState = .none
    /// Own ship's reported position. Both nil unless `fixState` is `.live`;
    /// the readout NEVER falls back to the map centre or the cursor.
    var shipLat: Double?
    var shipLon: Double?
    /// The chart menu, while it is up, and the marker rename field, while the
    /// mariner is typing in it. See the actions further down.
    var chartMenu: ChartMenu?
    var renaming: MarkerRename?
    var renamingText = ""
    /// Where the rename field stands, re-projected every frame: it is anchored
    /// to its marker, not to the screen.
    var renamingPoint: CGPoint?
    /// The overlay object the mariner pinned, and where it draws in the
    /// chrome's coordinate space. One at a time.
    var pinned: OverlayPin?
    var pinnedPoint: CGPoint?
    /// What the plugin overlay says about the symbol under the pointer, and
    /// where the pointer is in the chrome's coordinate space. Both nil when the
    /// pointer is over nothing. Set by the chart view after a hover settles.
    var hover: OverlayHover?
    var hoverPoint: CGPoint?

    /// The cursor pick: the features under the last tap, where it happened (in
    /// the chrome's coordinate space), and which one the report is showing.
    var pickResults: [PickFeature] = []
    var pickPoint: CGPoint?
    var pickIndex = 0
    /// Where on the CHART the pick was taken. The mark belongs to the object,
    /// not to the screen: follow moves the chart with no gesture behind it, so
    /// the mark is re-projected from this every frame.
    var pickGeo: (lon: Double, lat: Double)?
    /// Where the REPORT is docked: the mark's position when the pick was
    /// taken, and fixed for as long as the report is open. The panel's frame
    /// must not depend on anything the camera touches, or a chart sliding
    /// under follow re-lays it out every frame.
    var pickAnchor: CGPoint?
    /// Where a hook-driven pick should anchor its report. The chart view sets it
    /// to the centre of its bounds.
    var pickCentreHint: CGPoint?
    /// The chrome's size: the view inset by the safe area. This is the space
    /// the report is laid out in. The chart view sets it with the hint.
    /// `showPick` reads it to find the report's body and the sheet's edge.
    var chromeSize: CGSize = .zero
    /// How far `showPick` lifted the chart to clear the sheet. `closePick`
    /// puts the chart back by the same amount. Points, in the chrome's space.
    var pickLift: CGFloat = 0
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

    /// A picture from the pick report, shown over the chart at full size.
    struct Picture: Equatable {
        let name: String
        let data: Data
    }
    var picture: Picture?

    // MARK: Scale entry (tapping the 1:N readout)
    var showScaleEntry = false
    var scaleEntryText = ""

    /// The single chart controller (owned by ChartView; referenced for commands).
    weak var controller: ChartController? {
        didSet { chartLinks.controller = controller }
    }

    // MARK: The models for each area
    //
    // One per subject, each holding its own state and the calls that act on
    // it. The chrome reads them through this one: model.chartLinks.list.

    let chartLinks = ChartLinksModel()

    /// The raster charts the mariner installed. Persisted, because a chart set is a
    /// half-gigabyte download they picked deliberately — asking again every
    /// launch would be its own bug.
    let rasterKey = "lookout.rastercharts"
    let rasterOffKey = "lookout.rastercharts.off"
    /// Which SETS are not drawn, by set name. Beside the installed list and the
    /// switched-off list, because all three describe the same charts and any one
    /// of them living somewhere else is a way for them to drift apart.
    ///
    /// Not the same thing as rasterOff. Off means "installed and quiet" and
    /// takes a set out of the pill's list entirely; this is the pill's own
    /// choice of which picture covers this water, and a set that is not drawn is
    /// still offered.
    let rasterHiddenKey = "lookout.rastercharts.hidden"
    let chartHiddenKey = "lookout.chart.hidden"


    // MARK: State the extensions own
    //
    // Swift keeps stored properties in the class body, so these sit here while
    // the code that reads them is in AppModel+<subject>.swift beside this file.
    // Each block says which one. They are internal rather than private for the
    // same reason: Swift has no access level meaning "this file and the
    // extensions that go with it".

    // AppModel+ChartSets.swift

    /// The bake running now, if any. The HUD pill watches this.
    var bake: BakeProgress?
    var bakeJob: ChartBakeJob?
    /// True while the scan running was asked for by the mariner.
    var scanRequested = false

    /// The charts of a removed set being deleted, while that is happening.
    var removing: BakeProgress?
    /// The folder being looked through, for the first-run text.
    var scanningName = ""

    /// The folder or archive the running bake is preparing, so that removing
    /// that set can stop it and disown what it produces.
    var bakeSource: String?

    /// The set the mariner asked to remove, held while they are asked whether
    /// they meant it. Only a set Lookout prepared charts for: taking a folder
    /// of the mariner's own files off the list deletes nothing, so it needs no
    /// question.
    var pendingRemoval: ChartSet?

    // AppModel+Alerts.swift

    /// Every alert the plugins have raised, most urgent first. The banner over
    /// the chart is built from this.
    var alerts: [PluginAlert] = []

    var alertTimer: Timer?
    let siren = AlarmSiren()
    /// The last set the core reported. The list is rebuilt only when it moves.
    var alertSeq = -1

    init() {
        // Drop anything that has since been deleted or unplugged, so a stale
        // entry never becomes an error the mariner has to dismiss at every
        // launch.
        rasterPaths = (Store.shared.strings(rasterKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
        rasterOff = Set(Store.shared.strings(rasterOffKey) ?? [])
        rasterHidden = Set(Store.shared.strings(rasterHiddenKey) ?? [])
        chartHiddenSaved = Store.shared.bool(chartHiddenKey)
        // Anything a previous run renamed on its way to being deleted.
        ChartBake.sweepTrash()
        // The panel's list. The open itself does not wait on this: it takes
        // the cheap walk in initialChartPaths and starts drawing.
        loadChartSets()
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

    /// Every table the loaded plugins declare, in declaration order. The
    /// Vessels menu and the settings row are built from this, so what is
    /// offered follows the plugins that are up: a plugin that unloads takes its
    /// item with it.
    var pluginTables: [PluginTableSpec] = []

    /// The tables the loaded plugins declare. The menu and the settings row are
    /// built from this, so setting it is all it takes to make them appear.
    func refreshPluginTables() {
        guard let c = controller else { return }
        pluginTables = c.tableSpecs()
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
