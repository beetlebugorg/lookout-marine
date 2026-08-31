//  ChartsModel.swift — the charts aboard, and the one being drawn.
//
//  Which paths open at launch, the sets the mariner added, the bake that turns
//  raw cells into charts this app can draw, and the state of the open itself. A
//  folder joins the list only after the core has looked through it and found
//  charts, so a set on the list always opens.

import Foundation

/// A request to (re)open one or more chart paths, carried to the chart view.
struct OpenRequest: Equatable {
    let id: Int
    let paths: [String]
}

@MainActor
@Observable
final class ChartsModel {
    // MARK: The chart that is open, or opening

    var hasChart = false
    var chartPath: String?
    var openRequest: OpenRequest?
    var openError: String?
    private var openSeq = 0

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
    /// The number of cells the open is mapping. The loader states it.
    var openingCells = 0

    var showStartupLoader: Bool { isOpening || (hasChart && !firstBuildDone) }

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

    // MARK: The sets aboard

    /// The folders of charts aboard, in the order added. A set on this list has
    /// been looked through and holds charts, so it always opens.
    var sets: [ChartSet] = []
    /// True while a folder is being looked through. The full NOAA library takes
    /// about 3 seconds.
    var scanning = false
    /// True while the scan running was asked for by the mariner.
    var scanRequested = false
    /// The folder being looked through, for the first-run text.
    var scanningName = ""
    /// The last folder that held no charts, for the panel to say so.
    var emptyPick: String?

    /// The bake running now, if any. The HUD pill watches this.
    var bake: BakeProgress?
    private var bakeJob: ChartBakeJob?
    /// The folder or archive the running bake is preparing, so that removing
    /// that set can stop it and disown what it produces.
    private var bakeSource: String?
    /// The charts of a removed set being deleted, while that is happening.
    var removing: BakeProgress?
    /// The set the mariner asked to remove, held while they are asked whether
    /// they meant it. Only a set Lookout prepared charts for: taking a folder
    /// of the mariner's own files off the list deletes nothing, so it needs no
    /// question.
    var pendingRemoval: ChartSet?

    weak var engine: (any ChartOpenEngine)?

    /// The pictures a set carries are installed as raster charts, so adding
    /// and removing a set writes there too. One direction only: the raster
    /// model knows nothing about sets.
    private let raster: RasterModel

    init(raster: RasterModel) {
        self.raster = raster
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
        var seen = Set(Store.shared.strings(RasterModel.group, RasterModel.pathsKey))
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
        guard !paths.isEmpty || !raster.paths.isEmpty else { closeChart(); return }
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
            if let e = self.engine, e.reopen(charts: paths) {
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
        for set in sets where set.on {
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
                self.sets = found
                self.scanning = false
                self.syncRasterFromSets()
                // The launch walk cannot see a library of pictures: it looks
                // for cells, and finds none. Open what the scan found once it
                // knows, or a mariner carrying only imagery gets the first-run
                // page every time with their charts sitting on the list.
                if !self.hasChart && (!self.openPaths.isEmpty || !self.raster.paths.isEmpty) {
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
            // The scan at launch has no name to give: it is looking through
            // everything saved, not one thing the mariner just picked. Without
            // this the refusal read "Still working on . Wait for it to finish."
            let busy = bake?.name ?? scanningName
            emptyPick = busy.isEmpty
                ? "Still looking through the charts already aboard. Try again in a moment."
                : "Still working on \(busy). Wait for it to finish."
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
                    // By the agency that made them, now that the scan has read
                    // them and knows. Before it ran, the folder was all there
                    // was to go on.
                    self.beginBake(sourceDir: set.path, cells: set.toPrepare, named: set.title)
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
        sets.removeAll { $0.path == set.path }
        sets.append(set)
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
        for set in sets where set.on {
            for p in set.rasterPaths where !seen.contains(p) {
                seen.insert(p)
                wanted.append(p)
            }
        }
        // Anything the mariner added before sets existed stays aboard.
        for p in raster.paths where !seen.contains(p) && !ChartBake.isDerived(p) {
            let inAnySet = sets.contains { $0.rasterPaths.contains(p) }
            if !inAnySet {
                seen.insert(p)
                wanted.append(p)
            }
        }
        guard wanted != raster.paths else { return }
        raster.paths = wanted
        Store.shared.set(raster.paths, RasterModel.group, RasterModel.pathsKey)
    }

    /// Any chart work running now: a scan or a bake. The pill, the first-run
    /// panel and the Charts settings all read this one value, so the work
    /// appears wherever the mariner is looking.
    var chartWork: BakeProgress? {
        if let b = bake { return b }
        // Freeing the disk after a set is removed. It is not the mariner's
        // work and they are not waiting on it, but it is the app doing
        // something to their charts, so it says so.
        if let r = removing { return r }
        // Only work the mariner started. The scan at launch is bookkeeping for
        // the Charts panel and finishes on its own; showing it puts "Finding
        // charts" over the window on every single launch, before a chart the
        // app already knows how to open.
        if scanning && scanRequested { return BakeProgress(kind: .finding, name: scanningName) }
        return nil
    }

    /// The work to show in place of the first-run picker: a scan or a bake,
    /// while there is still no chart to draw. Nil once a chart is up, because
    /// from then on the pill carries it and the chart is the thing to look at.
    var firstRunWork: BakeProgress? { chartWork }

    /// Bake `sourceDir` into the app's own chart directory, then add the
    /// result as the set. The mariner keeps sailing while this runs: it is a
    /// pill in the HUD, not a modal.
    private func beginBake(sourceDir: String, cells: [ScannedCell], named: String? = nil) {
        let job = ChartBakeJob()
        bakeJob = job
        bakeSource = sourceDir
        let total = cells.filter(\.needsPrepare).count
        let title = named ?? (sourceDir as NSString).lastPathComponent
        bake = BakeProgress(done: 0, total: total, name: title)
        job.onProgress = { [weak self, weak job] p in
            // Only the job this model still owns may speak for it. A removed
            // set cancels its bake, but tile57 stops at the next chart
            // boundary and goes on reporting until it does — and each report
            // put the import panel back over the removal.
            guard let self, let job, self.bakeJob === job else { return }
            // The count moves on tile57's thread once per cell. Keep the total
            // from the scan when tile57 has not counted yet, so the bar never
            // starts at an unknown length.
            var shown = p
            if shown.total == 0 { shown.total = total }
            // And keep the name chosen here. The job knows the folder it was
            // given; who made the charts in it is the scan's answer, and every
            // progress tick would otherwise put the folder name back.
            shown.name = title
            self.bake = shown
        }
        ChartBake.run(sourceDir: sourceDir, cells: cells, job: job) { [weak self] outDir in
            guard let self else { return }
            self.bakeJob = nil
            // The set was taken off the list while its charts were baking. What
            // came out is already being deleted, so there is nothing to read
            // back and nothing to put on the list — and reading it back is how
            // a removed set used to reappear.
            guard self.bakeSource == sourceDir else {
                self.bakeSource = nil
                self.bake = nil
                return
            }
            self.bakeSource = nil
            // The panel stays up across the last read of the folder. Clearing
            // it here drops the window back to the first-run page for as long
            // as that takes, and then the chart arrives: the mariner watches
            // their work apparently undone.
            self.scanning = true
            self.scanRequested = true
            self.bake = nil
            // The output directory is not read here. The set is the folder the
            // mariner picked, and it is rescanned below; nil only says the bake
            // failed.
            guard outDir != nil else {
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
        guard let i = sets.firstIndex(where: { $0.path == path }) else { return }
        sets[i].on = on
        ChartSetStore.setOff(path, !on)
        syncRasterFromSets()
        requestOpen(openPaths)
    }

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
        let gone = sets.first { $0.path == path }
        // A set removed while it was still baking never reached the list, so
        // there is no scanned preparedPath to read — and the charts already
        // written would be left on the disk for good. Where its charts would
        // be is knowable from the path alone; deleting is a no-op when it
        // holds nothing.
        let prepared = gone?.preparedPath ?? ChartBake.preparedDirectory(for: path)
        // The pictures the set carried go with it. syncRasterFromSets keeps a
        // picture that belongs to no set — that is how the ones added before
        // sets existed stay aboard — and the moment this set is removed, that
        // describes every picture it carried. Without this, removing every set
        // leaves "No charts" in the list and a chart still on screen.
        let carried = Set(gone?.rasters.map(\.path) ?? [])
        // Baking charts for a set that is going away is work on files about to
        // be deleted, and while it ran the panel went on saying "Importing" over
        // the removal. Stop it, and disown what it has already produced: the
        // delete below takes that with the rest.
        if bakeSource == path {
            bakeJob?.cancel()
            bakeJob = nil
            bake = nil
            bakeSource = nil
        }
        sets.removeAll { $0.path == path }
        ChartSetStore.remove(path)
        if !carried.isEmpty {
            let kept = raster.paths.filter { !carried.contains($0) }
            if kept != raster.paths {
                raster.paths = kept
                Store.shared.set(raster.paths, RasterModel.group, RasterModel.pathsKey)
            }
        }
        syncRasterFromSets()
        if let prepared {
            let name = gone?.title ?? (path as NSString).lastPathComponent
            ChartBake.deleteDerived(prepared) { [weak self] p in
                guard let self else { return }
                // A removal that is over reports one last time with no name;
                // that is what takes the panel away.
                self.removing = p.name.isEmpty ? nil : BakeProgress(
                    kind: .removing, done: p.done, total: p.total, name: name, elapsed: p.elapsed)
            }
        }
        requestOpen(openPaths)
    }

}
