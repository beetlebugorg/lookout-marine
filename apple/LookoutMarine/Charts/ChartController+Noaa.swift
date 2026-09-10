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

    func noaaCost(regionIDs: String) -> (cells: UInt32, bytes: UInt64)? {
        guard let h = handle else { return nil }
        var cells: UInt32 = 0
        var bytes: UInt64 = 0
        let ok = regionIDs.withCString { lookout_noaa_cost(h, $0, &cells, &bytes) }
        return ok != 0 ? (cells, bytes) : nil
    }

    func noaaDownload(regionIDs: String, destination: String) {
        guard let h = handle else { return }
        regionIDs.withCString { ids in
            destination.withCString { dest in
                lookout_noaa_download(h, ids, dest)
            }
        }
        kick()
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
