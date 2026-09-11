//  NoaaModel.swift: NOAA's charts, as the shell sees them.
//
//  The core owns the catalog, the region selection and the transfers. This
//  renders the snapshot, holds which regions the mariner picked, and reports
//  what the pick costs.

import Foundation

/// A lon/lat box, as the catalog states it.
struct GeoBox: Equatable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double
}

/// One region a mariner picks, as the core lists it.
struct NoaaRegion: Identifiable, Hashable {
    let id: String
    let name: String
    let blurb: String
    let district: Int
    /// Where to draw it on the picker's map, in degrees. A rough extent. What
    /// the region selects comes from the catalog.
    let west: Double
    let south: Double
    let east: Double
    let north: Double
}

/// A cell already installed, for the update check.
struct NoaaInstalledCell: Hashable {
    let name: String
    let edition: UInt32
    let update: UInt32
}

/// What the core is doing with NOAA's charts.
struct NoaaState: Equatable {
    enum Phase: UInt8 { case idle = 0, readingCatalog = 1, ready = 2, downloading = 3 }

    var phase: Phase = .idle
    var haveCatalog = false
    /// NOAA's validity date for the loaded catalog, "20250903".
    var date = ""
    /// The last catalog read that succeeded, or nil for never.
    var checkedAt: Date?
    var catalogCells: UInt32 = 0
    var total: UInt32 = 0
    var done: UInt32 = 0
    var failed: UInt32 = 0
    var bytesTotal: UInt64 = 0
    var bytesDone: UInt64 = 0
    var error = ""
}

@MainActor
@Observable
final class NoaaModel {
    /// The regions, read once from the core.
    private(set) var regions: [NoaaRegion] = []
    /// Which regions the mariner picked, by id.
    var picked: Set<String> = []
    private(set) var state = NoaaState()
    /// Each region's real coverage, read once the catalog is in. A region
    /// drawn as one rectangle claims water it does not cover.
    private(set) var coverage: [String: [GeoBox]] = [:]
    /// What the current pick costs, refreshed whenever the pick changes.
    private(set) var cells: UInt32 = 0
    private(set) var bytes: UInt64 = 0

    /// True when a catalog read was asked for before a chart was open. Every
    /// call here goes through a chart handle, so a read asked for at launch
    /// had nothing to run through.
    private var wantsCatalog = false

    weak var engine: (any NoaaEngine)? {
        didSet {
            guard engine != nil else { return }
            poll()
            if wantsCatalog { refresh() }
        }
    }

    init() {
        regions = NoaaModel.readRegions()
    }

    /// The region table from the core. Static for the life of the process.
    private static func readRegions() -> [NoaaRegion] {
        var out: UnsafePointer<lookout_noaa_region>?
        let n = lookout_noaa_regions(&out)
        guard let base = out, n > 0 else { return [] }
        return (0..<n).map { i in
            let r = base[i]
            return NoaaRegion(id: String(cString: r.id),
                              name: String(cString: r.name),
                              blurb: String(cString: r.blurb),
                              district: Int(r.district),
                              west: r.west, south: r.south,
                              east: r.east, north: r.north)
        }
    }

    /// The picked ids as the core reads them.
    var pickedIDs: String {
        regions.filter { picked.contains($0.id) }.map(\.id).joined(separator: ",")
    }

    func toggle(_ id: String) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        recost()
    }

    /// Read NOAA's catalog. The result arrives through poll().
    func refresh() {
        guard let engine, engine.noaaRefresh() else {
            wantsCatalog = true
            return
        }
        wantsCatalog = false
        poll()
    }

    /// A chart is open. Anything asked for before the handle existed runs now.
    func chartDidOpen() {
        poll()
        if wantsCatalog { refresh() }
    }

    /// Take the core's snapshot and reprice the pick.
    func poll() {
        guard let engine else { return }
        let next = engine.noaaState()
        // Assigning an equal value still invalidates every view reading it,
        // and this polls several times a second.
        guard next != state else { return }
        let gained = next.haveCatalog && !state.haveCatalog
        state = next
        if gained {
            recost()
            loadCoverage()
        }
    }

    /// Read every region's coverage. The catalog holds it and does not change
    /// while it is loaded, so this runs once.
    private func loadCoverage() {
        guard let engine else { return }
        var out: [String: [GeoBox]] = [:]
        for r in regions { out[r.id] = engine.noaaRegionCoverage(r.id) }
        coverage = out
    }

    private func recost() {
        guard let engine, state.haveCatalog else {
            cells = 0
            bytes = 0
            return
        }
        if let c = engine.noaaCost(regionIDs: pickedIDs) {
            cells = c.cells
            bytes = c.bytes
        } else {
            cells = 0
            bytes = 0
        }
    }

    /// Download the picked regions into `destination`.
    func download(to destination: String) {
        guard !picked.isEmpty else { return }
        engine?.noaaDownload(regionIDs: pickedIDs, destination: destination)
        poll()
    }

    func cancel() {
        engine?.noaaCancel()
        poll()
    }

    /// How many of these cells NOAA has reissued.
    func outdatedCount(_ have: [NoaaInstalledCell]) -> UInt32 {
        engine?.noaaOutdated(have) ?? 0
    }

    func update(_ have: [NoaaInstalledCell], to destination: String) {
        engine?.noaaUpdate(have, destination: destination)
        poll()
    }

    /// Where downloaded cells are staged before they bake. One directory, so
    /// the whole download bakes as a single chart set.
    static var downloadDirectory: String? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs
            .appendingPathComponent("Charts", isDirectory: true)
            .appendingPathComponent("NOAA", isDirectory: true).path
    }

    /// A size a mariner reads before agreeing to download it.
    static func sizeText(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = bytes >= 1 << 30 ? [.useGB] : [.useMB]
        return f.string(fromByteCount: Int64(bytes))
    }
}
