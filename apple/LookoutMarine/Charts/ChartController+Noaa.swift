//  ChartController+Noaa.swift: the calls behind NOAA's charts.
//
//  The core reads NOAA's product catalog, decides which cells a region needs
//  and fetches them through this shell's ChartLinkFetch. These are the calls
//  that start that work and read where it got to.

import Foundation

@MainActor
extension ChartController {

    /// False when no chart is open. Every call here goes through a chart
    /// handle, which lookout_open creates after the first layout, so a refresh
    /// asked for at launch has nothing to run through.
    @discardableResult
    func noaaRefresh() -> Bool {
        guard let h = handle else { return false }
        lookout_noaa_refresh(h)
        kick()
        return true
    }

    func noaaState() -> NoaaState {
        guard let h = handle else { return NoaaState() }
        var raw = lookout_noaa_state()
        lookout_noaa_poll(h, &raw)
        var s = NoaaState()
        s.phase = NoaaState.Phase(rawValue: raw.phase) ?? .idle
        s.haveCatalog = raw.have_catalog != 0
        s.date = withUnsafePointer(to: raw.date) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        s.checkedAt = raw.checked_at > 0
            ? Date(timeIntervalSince1970: TimeInterval(raw.checked_at)) : nil
        s.catalogCells = raw.catalog_cells
        s.total = raw.total
        s.done = raw.done
        s.failed = raw.failed
        s.bytesTotal = raw.bytes_total
        s.bytesDone = raw.bytes_done
        s.error = withUnsafePointer(to: raw.error) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        return s
    }

    func noaaCost(regionIDs: String) -> NoaaCost? {
        guard let h = handle else { return nil }
        var cells: UInt32 = 0
        var bytes: UInt64 = 0
        var held: UInt32 = 0
        var heldBytes: UInt64 = 0
        let ok = regionIDs.withCString {
            lookout_noaa_cost(h, $0, &cells, &bytes, &held, &heldBytes)
        }
        return ok != 0 ? NoaaCost(cells: cells, bytes: bytes,
                                  held: held, heldBytes: heldBytes) : nil
    }

    /// Name the NOAA cells already on this device, so a pick prices what is
    /// missing from the water rather than all of it.
    func noaaHave(_ names: [String]) {
        guard let h = handle else { return }
        let copies = names.map { strdup($0)! }
        defer { for c in copies { free(c) } }
        var pointers = copies.map { UnsafePointer<CChar>?($0) }
        pointers.withUnsafeMutableBufferPointer {
            lookout_noaa_have(h, $0.baseAddress, $0.count)
        }
    }

    /// `again` fetches the cells already installed as well, for a mariner
    /// repairing or refreshing water they hold.
    func noaaDownload(regionIDs: String, destination: String, again: Bool) {
        guard let h = handle else { return }
        regionIDs.withCString { ids in
            destination.withCString { dest in
                lookout_noaa_download(h, ids, dest, again ? 1 : 0)
            }
        }
        kick()
    }

    /// The boxes of one region's coarse cells, as the catalog states them.
    func noaaRegionCoverage(_ regionID: String) -> [GeoBox] {
        guard let h = handle else { return [] }
        return regionID.withCString { id -> [GeoBox] in
            let n = lookout_noaa_region_coverage(h, id, nil, 0)
            guard n > 0 else { return [] }
            var raw = [lookout_noaa_box](repeating: .init(), count: n)
            let got = raw.withUnsafeMutableBufferPointer {
                lookout_noaa_region_coverage(h, id, $0.baseAddress, n)
            }
            return raw.prefix(min(got, n)).map {
                GeoBox(west: $0.west, south: $0.south, east: $0.east, north: $0.north)
            }
        }
    }

    func noaaCancel() {
        guard let h = handle else { return }
        lookout_noaa_cancel(h)
        kick()
    }

    func noaaOutdated(_ have: [NoaaInstalledCell]) -> UInt32 {
        guard let h = handle, !have.isEmpty else { return 0 }
        return withInstalled(have) { lookout_noaa_outdated(h, $0, have.count) }
    }

    func noaaUpdate(_ have: [NoaaInstalledCell], destination: String) {
        guard let h = handle, !have.isEmpty else { return }
        withInstalled(have) { buf in
            destination.withCString { lookout_noaa_update(h, buf, have.count, $0) }
        }
        kick()
    }

    /// Build the C array of installed cells and hand it to `body`. The cell
    /// names are held alive for the call, because the struct holds pointers
    /// into them.
    private func withInstalled<T>(_ have: [NoaaInstalledCell],
                                  _ body: (UnsafePointer<lookout_noaa_installed>) -> T) -> T {
        let names = have.map { strdup($0.name)! }
        defer { for n in names { free(n) } }
        var buf = [lookout_noaa_installed]()
        buf.reserveCapacity(have.count)
        for (i, c) in have.enumerated() {
            buf.append(.init(name: UnsafePointer(names[i]),
                             edition: c.edition, update: c.update))
        }
        return buf.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
