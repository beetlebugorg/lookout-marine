//  NoaaService.swift: the calls behind NOAA's charts.
//
//  The core reads NOAA's product catalog, decides which cells a region needs
//  and fetches them through a ChartLinkFetch of this service's own. The
//  service has a core handle of its own, so a chart closing or reopening
//  leaves a download running. It lives as long as the app.

import Foundation

@MainActor
final class NoaaService: NoaaEngine {
    private let handle: OpaquePointer?
    private let fetch = ChartLinkFetch()

    /// `changed` is called on the main thread whenever a response may have
    /// moved the state. The owner reads noaaChanged from it.
    init(changed: @escaping () -> Void) {
        handle = lookout_noaa_open(Store.shared.handle, ChartSetStore.handle)
        if let handle { fetch.attach(noaa: handle, wake: changed) }
    }

    deinit {
        fetch.detach()
        lookout_noaa_close(handle)
    }

    @discardableResult
    func noaaRefresh() -> Bool {
        guard let handle else { return false }
        lookout_noaa_refresh(handle)
        return true
    }

    func noaaChanged() -> Bool {
        lookout_noaa_changed(handle) != 0
    }

    func noaaState() -> NoaaState {
        var raw = lookout_noaa_state()
        lookout_noaa_poll(handle, &raw)
        var s = NoaaState()
        s.phase = NoaaState.Phase(rawValue: raw.phase) ?? .idle
        s.haveCatalog = raw.have_catalog != 0
        s.date = withUnsafePointer(to: raw.date) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        s.checkedAt = raw.checked_at > 0
            ? Date(timeIntervalSince1970: TimeInterval(raw.checked_at)) : nil
        s.updateChecking = raw.update_checking != 0
        s.updateCheckedAt = raw.update_checked_at > 0
            ? Date(timeIntervalSince1970: TimeInterval(raw.update_checked_at)) : nil
        s.catalogCells = raw.catalog_cells
        s.total = raw.total
        s.done = raw.done
        s.failed = raw.failed
        s.bytesTotal = raw.bytes_total
        s.bytesDone = raw.bytes_done
        s.error = withUnsafePointer(to: raw.error) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        s.catalogError = withUnsafePointer(to: raw.catalog_error) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        s.outcome = NoaaState.Outcome(rawValue: raw.outcome) ?? .none
        s.run = raw.run
        s.retry = raw.retry != 0
        s.removing = raw.removing != 0
        s.removeDone = raw.remove_done
        s.removeTotal = raw.remove_total
        s.preparing = raw.preparing != 0
        s.prepared = raw.prepared
        s.toPrepare = raw.to_prepare
        s.bandDone = withUnsafeBytes(of: raw.band_done) { Array($0.bindMemory(to: UInt32.self)) }
        s.bandTotal = withUnsafeBytes(of: raw.band_total) { Array($0.bindMemory(to: UInt32.self)) }
        return s
    }

    func noaaCost(regionIDs: String) -> NoaaCost? {
        var cells: UInt32 = 0
        var bytes: UInt64 = 0
        var held: UInt32 = 0
        var heldBytes: UInt64 = 0
        let ok = regionIDs.withCString {
            lookout_noaa_cost(handle, $0, &cells, &bytes, &held, &heldBytes)
        }
        return ok != 0 ? NoaaCost(cells: cells, bytes: bytes,
                                  held: held, heldBytes: heldBytes) : nil
    }

    /// `again` fetches the cells already installed as well, for a mariner
    /// repairing or refreshing water they hold.
    func noaaDownload(regionIDs: String, destination: String, again: Bool) {
        regionIDs.withCString { ids in
            destination.withCString { dest in
                lookout_noaa_download(handle, ids, dest, again ? 1 : 0)
            }
        }
    }

    func noaaApply(regionIDs: String, destination: String, again: Bool) -> UInt32 {
        regionIDs.withCString { ids in
            destination.withCString { dest in
                lookout_noaa_apply(handle, ids, dest, again ? 1 : 0)
            }
        }
    }

    func noaaGivesBack(regionIDs: String) -> [String] {
        regionIDs.withCString { ids in
            let n = lookout_noaa_gives_back(handle, ids, nil, 0)
            var out = [UnsafePointer<CChar>?](repeating: nil, count: n)
            let got = out.withUnsafeMutableBufferPointer {
                lookout_noaa_gives_back(handle, ids, $0.baseAddress, n)
            }
            return out.prefix(min(got, n)).compactMap { $0.map { String(cString: $0) } }
        }
    }

    func noaaRegionState(_ regionID: String) -> NoaaRegionState? {
        var raw = lookout_noaa_region_info()
        guard regionID.withCString({ lookout_noaa_region_state(handle, $0, &raw) }) != 0
        else { return nil }
        return NoaaRegionState(cells: raw.cells, held: raw.held, bytes: raw.bytes,
                               allHeld: raw.all_held != 0, recorded: raw.recorded != 0)
    }

    /// The boxes of one region's coarse cells, as the catalog states them.
    func noaaRegionCoverage(_ regionID: String) -> [GeoBox] {
        regionID.withCString { id -> [GeoBox] in
            let n = lookout_noaa_region_coverage(handle, id, nil, 0)
            guard n > 0 else { return [] }
            var raw = [lookout_noaa_box](repeating: .init(), count: n)
            let got = raw.withUnsafeMutableBufferPointer {
                lookout_noaa_region_coverage(handle, id, $0.baseAddress, n)
            }
            return raw.prefix(min(got, n)).map {
                GeoBox(west: $0.west, south: $0.south, east: $0.east, north: $0.north)
            }
        }
    }

    func noaaCancel() {
        lookout_noaa_cancel(handle)
    }

    func noaaOutdated() -> UInt32 {
        lookout_noaa_outdated(handle)
    }

    func noaaUpdate(destination: String) {
        destination.withCString { lookout_noaa_update(handle, $0) }
    }

    func noaaUpdateDue() -> Bool {
        lookout_noaa_update_due(handle) != 0
    }

    func noaaUpdateCheck() -> Int32 {
        lookout_noaa_update_check(handle)
    }

    func noaaSetUpdateCheck(_ cadence: Int32) {
        lookout_noaa_set_update_check(handle, cadence)
    }
}
