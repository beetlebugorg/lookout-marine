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

/// What picking regions costs: the download, and the cells already installed.
struct NoaaCost {
    var cells: UInt32 = 0
    var bytes: UInt64 = 0
    var held: UInt32 = 0
    var heldBytes: UInt64 = 0
}

/// One region as the core counts it. See lookout_noaa_region_info.
struct NoaaRegionState: Equatable {
    /// The cells the region selects.
    var cells: UInt32 = 0
    /// Of those, the ones the downloader's own set draws now.
    var held: UInt32 = 0
    /// What the cells no set holds cost to fetch.
    var bytes: UInt64 = 0
    /// True when every cell the region selects is held.
    var allHeld = false
    /// True when the region is recorded as downloaded and held whole: the
    /// water the picker ticks.
    var recorded = false
}

/// What the core is doing with NOAA's charts.
struct NoaaState: Equatable {
    enum Phase: UInt8 { case idle = 0, readingCatalog = 1, ready = 2, downloading = 3 }
    /// How the download numbered `run` ended. See LOOKOUT_NOAA_NONE.
    enum Outcome: UInt8 {
        case none = 0, running = 1, finished = 2, empty = 3, cancelled = 4, failed = 5,
             refused = 6
    }

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
    var outcome: Outcome = .none
    /// Counts the downloads ordered, refused ones included.
    var run: UInt32 = 0
    /// True when ordering again can clear the cause of a failed or refused
    /// download. See lookout_noaa_state.retry.
    var retry = false
    /// True while the charts an apply took out of the library are deleted.
    var removing = false
    var removeDone: UInt32 = 0
    var removeTotal: UInt32 = 0
    /// True while the core prepares the downloaded charts. See
    /// lookout_noaa_state.preparing.
    var preparing = false
    var prepared: UInt32 = 0
    var toPrepare: UInt32 = 0
    /// Band 1 first.
    var bandDone: [UInt32] = []
    var bandTotal: [UInt32] = []

    /// True once the download numbered `run` has stopped for any reason.
    var ended: Bool { outcome != .none && outcome != .running }

    /// What the catalog line draws.
    ///
    /// A loaded catalog leads and a read that failed goes under it, because
    /// the picker prices and removes water from the catalog it already holds.
    /// An error in the summary's place describes a picker that cannot work.
    /// With no catalog the error is the whole line.
    enum CatalogLine: Equatable {
        case reading
        case summary(String)
        case summaryThenError(summary: String, error: String)
        case error(String)
        case blank
    }

    var catalogLine: CatalogLine {
        if phase == .readingCatalog { return .reading }
        guard haveCatalog else { return error.isEmpty ? .blank : .error(error) }
        if error.isEmpty { return .summary(catalogSummary) }
        return .summaryThenError(summary: catalogSummary, error: error)
    }

    /// The catalog in the mariner's words.
    var catalogSummary: String {
        var s = "\(catalogCells) charts published"
        if !date.isEmpty { s += ", catalog dated \(date)" }
        return s + "."
    }
}

@MainActor
@Observable
final class NoaaModel {
    /// The regions, read once from the core.
    private(set) var regions: [NoaaRegion] = []
    /// Which regions the mariner picked, by id.
    var picked: Set<String> = []
    private(set) var state = NoaaState()
    /// Called after every read that changed `state`.
    var onChange: (() -> Void)?
    /// Each region's real coverage, read once the catalog is in. A region
    /// drawn as one rectangle claims water it does not cover.
    private(set) var coverage: [String: [GeoBox]] = [:]
    /// What the current pick costs, refreshed whenever the pick changes.
    private(set) var cells: UInt32 = 0
    private(set) var bytes: UInt64 = 0
    /// Cells the pick names that are already installed. The mariner is told,
    /// so a number far under the region's size reads as a saving rather than
    /// a mistake.
    private(set) var held: UInt32 = 0
    /// What fetching the installed ones again costs, for a repair.
    private(set) var heldBytes: UInt64 = 0

    /// Callers waiting in loadCatalog for the catalog read to end.
    private var catalogWaiters: [CheckedContinuation<Void, Never>] = []

    weak var engine: (any NoaaEngine)? {
        didSet {
            guard engine != nil else { return }
            poll()
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

    /// Read NOAA's catalog. The result arrives through pull().
    func refresh() {
        engine?.noaaRefresh()
        pull()
    }

    /// Read NOAA's catalog when none is loaded, and wait for the read to end.
    func loadCatalog() async {
        guard !state.haveCatalog else { return }
        refresh()
        if state.phase == .readingCatalog {
            await withCheckedContinuation { catalogWaiters.append($0) }
        }
    }

    /// Read the core's state when it has changed. The frame loop calls this,
    /// and so does the service each time a response arrives.
    func pull() {
        guard let engine, engine.noaaChanged() else { return }
        poll()
    }

    /// Take the core's snapshot and reprice the pick.
    func poll() {
        guard let engine else { return }
        let next = engine.noaaState()
        // Assigning an equal value still invalidates every view reading it.
        guard next != state else { return }
        let gained = next.haveCatalog && !state.haveCatalog
        let reread = next.checkedAt != state.checkedAt
        state = next
        if gained {
            recost()
            readRegionState()
            loadCoverage()
        }
        if state.phase != .readingCatalog, !catalogWaiters.isEmpty {
            let waiting = catalogWaiters
            catalogWaiters = []
            for w in waiting { w.resume() }
        }
        finishCheck()
        if reread { recount() }
        onChange?()
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
            held = 0
            heldBytes = 0
            return
        }
        if let c = engine.noaaCost(regionIDs: pickedIDs) {
            cells = c.cells
            bytes = c.bytes
            held = c.held
            heldBytes = c.heldBytes
        } else {
            cells = 0
            bytes = 0
            held = 0
            heldBytes = 0
        }
    }

    /// Price the pick and each region again. The core reads the cells held
    /// off the chart sets, so a set added by hand counts the same as one this
    /// app downloaded.
    func reprice() {
        recost()
        readRegionState()
    }

    // MARK: - What water is held

    /// Each region as the core counts it. Empty before a catalog is read.
    private(set) var regionState: [String: NoaaRegionState] = [:]

    private func readRegionState() {
        guard let engine, state.haveCatalog else {
            regionState = [:]
            return
        }
        var out: [String: NoaaRegionState] = [:]
        for r in regions { out[r.id] = engine.noaaRegionState(r.id) }
        regionState = out
    }

    /// Pick the water the mariner downloaded and still holds.
    ///
    /// The picker states what a mariner HOLDS. Opening it with everything
    /// unticked said they held nothing, and ticking a region they had already
    /// downloaded read as a second download of the same water.
    func pickRecorded() {
        picked = Set(regions.filter { regionState[$0.id]?.recorded ?? false }.map(\.id))
        recost()
    }

    /// True when every cell the pick names is already on the device. The
    /// download then repairs or refreshes them rather than adding any.
    var allInstalled: Bool { cells == 0 && held > 0 }

    /// What a pick costs, in the mariner's words.
    var costLine: String {
        if allInstalled {
            return "\(held) charts, all installed · \(NoaaModel.sizeText(heldBytes)) to fetch again"
        }
        var s = "\(cells) charts, \(NoaaModel.sizeText(bytes))"
        if held > 0 { s += " · \(held) already installed" }
        return s
    }

    /// Download the picked regions into `destination`. The core adds them to
    /// its record.
    func download(to destination: String, again: Bool = false) {
        guard !picked.isEmpty else { return }
        engine?.noaaDownload(regionIDs: pickedIDs, destination: destination, again: again)
        pull()
    }

    /// Make the download at `destination` hold the pick. Returns how many
    /// directories the core took out of the library.
    func apply(to destination: String) -> UInt32 {
        let moved = engine?.noaaApply(regionIDs: pickedIDs, destination: destination,
                                      again: false) ?? 0
        pull()
        return moved
    }

    func cancel() {
        engine?.noaaCancel()
        pull()
    }

    /// Download the reissues of the cells this app downloaded.
    func update(to destination: String) {
        engine?.noaaUpdate(destination: destination)
        pull()
    }

    // MARK: - Checking for reissued charts

    /// How often to look. The wording an app uses for its own updates, because
    /// this is the same question about the charts.
    enum UpdateCheck: String, CaseIterable, Identifiable {
        case never, startup, daily

        var id: String { rawValue }
        var label: String {
            switch self {
            case .never:   return "Never"
            case .startup: return "At startup"
            case .daily:   return "Daily"
            }
        }
    }

    /// How many downloaded cells NOAA has reissued, as the last check counted
    /// them. Zero before a check has run.
    private(set) var outdated: UInt32 = 0
    /// True while a check reads the catalog.
    private(set) var checking = false
    /// True once a check has run, so the count follows the library after it.
    private var checked = false

    private static let group = Store.Group.chartsets
    private static let cadenceKey = "noaa-update-check"

    var updateCheck: UpdateCheck {
        get {
            guard let raw = Store.shared.string(NoaaModel.group, NoaaModel.cadenceKey),
                  let v = UpdateCheck(rawValue: raw) else { return .daily }
            return v
        }
        set {
            Store.shared.set(newValue.rawValue, NoaaModel.group, NoaaModel.cadenceKey)
        }
    }

    /// Start an update check when the core finds one due. The core reads the
    /// cadence and the last check from the store, and makes no request while
    /// the library holds no downloaded cell. Called when a chart opens and
    /// when the set list changes.
    func considerUpdateCheck() {
        guard let engine, engine.noaaUpdateDue() else { return }
        checking = true
        pull()
        finishCheck()
    }

    /// End the check once its catalog read has ended, and count.
    private func finishCheck() {
        guard checking, state.phase != .readingCatalog else { return }
        checking = false
        checked = true
        recount()
    }

    /// Count the reissued charts again. The core counts against the library
    /// as it is now, so an update that has baked clears its charts from the
    /// count.
    func recount() {
        guard checked, let engine else { return }
        outdated = engine.noaaOutdated()
    }

    /// Where downloaded cells are staged before they bake. One directory, so
    /// the whole download bakes as a single chart set.
    /// nonisolated: the chart set model marks this path as it opens, off the
    /// main actor, and one definition of the directory keeps the mark and the
    /// download on the same folder.
    nonisolated static var downloadDirectory: String? {
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
