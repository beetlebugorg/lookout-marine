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

    // MARK: Live HUD readouts (pushed by ChartController / the chart view)
    @Published var cursorLon: Double?
    @Published var cursorLat: Double?
    @Published var scaleDenominator: Double = 0
    @Published var zoomLevel: Double = 0      // fractional web-mercator zoom
    @Published var scheme: Int = 0            // 0 day, 1 dusk, 2 night
    @Published var rotationDeg: Double = 0
    @Published var pickResults: [PickFeature] = []
    @Published var isBuilding = false         // a background tessellation is filling in

    // MARK: Preferences
    @Published var useDMS = UserDefaults.standard.bool(forKey: "hud.useDMS") {
        didSet { UserDefaults.standard.set(useDMS, forKey: "hud.useDMS") }
    } // HUD coordinate format

    // MARK: iOS sheet/picker presentation (unused on macOS, where the file
    // panel and Settings scene are AppKit-native)
    @Published var showImporter = false
    @Published var showSettings = false

    // MARK: Search
    @Published var searchText = ""

    /// The single chart controller (owned by ChartView; referenced for commands).
    weak var controller: ChartController?

    private let recentsKey = "lookout.recents"

    init() {
        recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
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

    var schemeName: String {
        switch scheme { case 1: return "Dusk"; case 2: return "Night"; default: return "Day" }
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
