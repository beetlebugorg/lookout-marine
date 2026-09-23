//  ChartOpen.swift: the chart being drawn, or opening.
//
//  The open request, the state the startup loader reads while it runs, and
//  the error an open or a library change shows. ChartLibrary decides what to
//  open.

import Foundation

/// A request to (re)open one or more chart paths, carried to the chart view.
struct OpenRequest: Equatable {
    let id: Int
    let paths: [String]
}

@MainActor
@Observable
final class ChartOpen {
    var hasChart = false
    /// True when the chart that is open holds no charts: the engine draws the
    /// basemap and the library behind it is empty. An install with no charts
    /// in it still opens, so `hasChart` alone does not mean a chart is drawn.
    var chartIsEmpty = false
    var chartPath: String?
    /// The label languages the OPEN charts state, as ISO 639-2 codes, from
    /// lookout_chart_languages. Empty when no chart is open, or when every
    /// chart names its features in English. Settings offers only these. A
    /// language the charts do not state draws the portrayed name, so any
    /// other entry in the menu has no effect.
    var chartLanguages: [String] = []
    var openRequest: OpenRequest?
    var openError: String? {
        didSet { if openError == nil { openRetry = nil } }
    }
    /// Offered as a Retry button beside openError. Cleared with it.
    var openRetry: (() -> Void)?
    private var openSeq = 0

    /// True from the moment an open is scheduled until lookout_open returns.
    /// This covers the synchronous open, and a 7k-cell library needs seconds.
    var isOpening = false
    /// True while the FIRST-run one-time symbol/font atlas bake runs (the app
    /// cache is empty). Drives a distinct "Preparing chart symbols" message.
    var preparingSymbols = false
    /// False until the first scene after an open has actually rendered; with
    /// isOpening it drives the big startup loader (later rebuilds only show
    /// the small BuildingPill).
    var firstBuildDone = false
    /// The number of cells the open is mapping. The loader states it.
    var openingCells = 0

    /// The phase the startup loader shows. Each phase is a different wait: the
    /// first-run atlas bake, the scan, the library open, and the first
    /// tessellation.
    enum LoadPhase: Equatable {
        case bakingAtlas
        case finding
        case mapping(cells: Int)
        case tessellating

        var title: String {
            switch self {
            case .bakingAtlas:
                return "Baking the symbol atlas"
            case .finding:
                return "Finding your charts"
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
        if isOpening { return .mapping(cells: openingCells) }
        // No chart is open and none is opening, so this is the wait for the
        // scan result.
        if !hasChart { return .finding }
        return .tessellating
    }

    weak var engine: (any ChartOpenEngine)?

    /// A library with no cells still opens while it holds pictures.
    private let raster: RasterModel

    init(raster: RasterModel) {
        self.raster = raster
    }

    /// Open with no cells. A library of pictures alone opens this way too.
    ///
    /// The core draws a chart link, and the core exists only while something
    /// is open, so picking a link with no charts installed needs a chart of no
    /// cells under it.
    func openEmpty() {
        guard !hasChart, !isOpening else { return }
        requestOpen([], evenWithNothingToDraw: true)
    }

    func requestOpen(_ paths: [String], evenWithNothingToDraw: Bool = false) {
        // Nothing left to draw at all. Switching off the last set, or removing
        // it, has to take the chart off the display. Leaving the old one up
        // shows charts that are no longer installed.
        //
        // A set of pictures with no survey in it still draws, so the test is
        // whether anything is installed, rather than whether any CELL is.
        guard evenWithNothingToDraw || !paths.isEmpty || !raster.paths.isEmpty else {
            closeChart()
            return
        }
        openSeq += 1
        let id = openSeq
        openRequest = OpenRequest(id: id, paths: paths)
        // Show the loader BEFORE the (synchronous, possibly seconds-long) open
        // runs: flag now, open on the next runloop turn so SwiftUI paints.
        openingCells = paths.count
        isOpening = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Drive the controller DIRECTLY rather than relying on the SwiftUI
            // update cycle: once the chart view is live the hosting content
            // view stops receiving updates, and a published request then
            // sits unserviced. The update path remains only as the fallback for a
            // request racing the first layout.
            if let e = self.engine, e.reopen(charts: paths, requestID: id) {
                self.openRequest = nil
            }
            self.isOpening = false
        }
    }

    /// Close the chart and go back to the panel that offers to add some.
    /// The files are untouched; only the display and the engine handle go.
    func closeChart() {
        engine?.close()
        openRequest = nil
        chartPath = nil
        hasChart = false
        chartIsEmpty = false
        firstBuildDone = false
        isOpening = false
    }
}
