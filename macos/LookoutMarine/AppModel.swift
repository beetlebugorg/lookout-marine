//  AppModel.swift — shared, platform-neutral app state.
//
//  Single source of truth the SwiftUI chrome binds to: chart open/recents, the
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
    /// Every set, with whether it is in view. The pill's menu is built from it.
    @Published var rasterSets: [ChartController.RasterSet] = []
    /// The drawn set's index, or -1.
    @Published var rasterActive = -1
    @Published var chartPath: String?
    @Published var recents: [String] = []
    @Published var openRequest: OpenRequest?
    @Published var openError: String?
    private var openSeq = 0

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
    @Published var cursorLon: Double?
    @Published var cursorLat: Double?
    @Published var scaleDenominator: Double = 0
    @Published var zoomLevel: Double = 0      // fractional web-mercator zoom
    @Published var scheme: Int = 0            // 0 day, 1 dusk, 2 night
    @Published var rotationDeg: Double = 0
    @Published var overscale: Double = 1.0    // >1 = zoomed past the deepest data
    @Published var centerLat: Double = 0
    @Published var centerLon: Double = 0
    /// The cursor pick: the features under the last tap, where it happened (in
    /// the chrome's coordinate space), and which one the report is showing.
    @Published var pickResults: [PickFeature] = []
    @Published var pickPoint: CGPoint?
    @Published var pickIndex = 0
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
    @Published var showSettings = false
    /// Which settings tab shows: 0 Display, 1 Depths, 2 Text, 3 Charts,
    /// 4 Advanced. The screenshot hook sets it.
    @Published var settingsTab = 0

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

    private let recentsKey = "lookout.recents"
    /// The raster charts the mariner installed. Persisted, because a chart set is a
    /// half-gigabyte download they picked deliberately — asking again every
    /// launch would be its own bug.
    private let rasterKey = "lookout.rastercharts"
    private let rasterOffKey = "lookout.rastercharts.off"

    init() {
        recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        // Drop anything that has since been deleted or unplugged, so a stale
        // entry never becomes an error the mariner has to dismiss at every
        // launch.
        rasterPaths = (UserDefaults.standard.stringArray(forKey: rasterKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
        rasterOff = Set(UserDefaults.standard.stringArray(forKey: rasterOffKey) ?? [])
    }

    // MARK: - Opening charts

    /// Paths to open on first appearance: $LOOKOUT_OPEN (a chart or a folder of
    /// cells — dev/CLI convenience), else (iOS) everything in Documents, else
    /// the last recent, else the demo default.
    func initialChartPaths() -> [String] {
        if let p = ProcessInfo.processInfo.environment["LOOKOUT_OPEN"] {
            let cells = cellPaths(for: p)
            if !cells.isEmpty { return cells }
        }
        #if os(iOS)
        // On iOS, Documents IS the chart library (Files.app / Finder-sharing
        // drops and importer copies all land there): compose ALL of it at
        // launch. This must beat recents — a recent is at most a subset of
        // Documents, and launching into it would silently hide the rest of
        // the library (a device that imported a 7k-cell folder would reopen
        // as exactly one cell).
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let dropped = chartPaths(inDirectory: docs.path)
            if !dropped.isEmpty { return dropped }
        }
        #endif
        if let last = recents.first {
            let cells = cellPaths(for: last)
            if !cells.isEmpty { return cells }
        }
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

    /// Request opening a chart path — a single `.pmtiles` file, or a folder of
    /// cells (a recent can be either, so this dispatches on what's on disk).
    func openChart(_ path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            openChartDirectory(path)
        } else {
            requestOpen([path], recent: path)
        }
    }

    /// Request opening every `.pmtiles` under a directory (compose a library).
    func openChartDirectory(_ dir: String) {
        let paths = chartPaths(inDirectory: dir)
        if !paths.isEmpty { requestOpen(paths, recent: dir) }
    }

    /// `recent` is what the USER opened (the folder for a library, the file for
    /// a single cell) — recording the first cell of a folder open would make
    /// the next launch silently reopen one cell instead of the library.
    private func requestOpen(_ paths: [String], recent: String) {
        openSeq += 1
        openRequest = OpenRequest(id: openSeq, paths: paths)
        noteRecent(recent)
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

    private func noteRecent(_ path: String) {
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        UserDefaults.standard.set(recents, forKey: recentsKey)
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

    /// "Add charts" from the SETTINGS sheet (iOS): the importer and the sheet
    /// share one presenting host, so dismiss the sheet first.
    func addChartsFromSettings() {
        #if os(iOS)
        showSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.showImporter = true }
        #else
        presentOpenPanel()
        #endif
    }

    // MARK: - Commands (menu / buttons)

    func zoomIn()   { controller?.zoomCentered(+1.0) }
    func zoomOut()  { controller?.zoomCentered(-1.0) }
    func zoomToFit(){ controller?.fitChart() }
    func northUp()  { controller?.resetRotation() }
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
        rasterName = c.rasterName()
        if !failed.isEmpty {
            openError = failed.count == 1
                ? "Couldn't open \(failed[0]).\nIt may not be a raster chart tile57 reads."
                : "Couldn't open \(failed.count) of \(paths.count) files:\n" + failed.joined(separator: "\n")
        }
    }

    /// Draw one set, or none for -1.
    func selectRasterSet(_ i: Int) {
        guard let c = controller else { return }
        c.rasterSelect(i)
        rasterName = c.rasterName()
        rasterActive = c.rasterActiveIndex()
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
    }

    /// Remove one source. The engine cannot drop a source from a live handle,
    /// so this takes effect the next time a chart opens.
    func removeRasterChart(_ path: String) {
        rasterPaths.removeAll { $0 == path }
        rasterOff.remove(path)
        UserDefaults.standard.set(rasterPaths, forKey: rasterKey)
        UserDefaults.standard.set(Array(rasterOff), forKey: rasterOffKey)
    }

    /// The provider a file name names — what a mariner is choosing between when
    /// the same water ships from several.
    static func providerLabel(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent
        for k in ["ArcGIS", "Bing", "Google", "Navionics", "ESRI", "Esri", "CMap", "C-Map", "Sentinel", "NAIP"] {
            if base.range(of: k, options: .caseInsensitive) != nil { return k }
        }
        return "Raster"
    }

    /// Forget every installed source. The engine has no remove yet, so this
    /// takes effect on the next chart open — say so where it is offered.
    func clearRasterCharts() {
        rasterPaths.removeAll()
        UserDefaults.standard.set(rasterPaths, forKey: rasterKey)
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
        rasterName = c.rasterName()
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
        // A sheet covers part of the chart, so the object can fall under it.
        // Lift the chart until the mark clears the sheet, and move the mark
        // with it. Only a sheet needs this. A callout stands over its object
        // and does not hide it.
        pickLift = 0
        if let p = pickPoint, let lift = sheetLift(for: p), lift > 0 {
            controller?.panRevealingPick(dxPt: 0, dyPt: -lift)
            pickPoint = CGPoint(x: p.x, y: p.y - lift)
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

    /// A hook-driven pick at a fraction of the view — the screenshot
    /// protocol's way of picking away from the centre:
    /// LOOKOUT_SHOW=pick:0.5,0.85.
    func pickAt(fx: Double, fy: Double) {
        guard let controller, let centre = pickCentreHint else { return }
        let p = CGPoint(x: centre.x * 2 * fx, y: centre.y * 2 * fy)
        guard let g = controller.geo(atPoint: p) else { return }
        showPick(controller.pick(lon: g.lon, lat: g.lat), at: p)
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
