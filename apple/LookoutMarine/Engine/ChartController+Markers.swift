//  ChartController+Markers.swift — the mariner's own marks.
//
//  The core owns the list and the file it lives in. Everything here is a
//  snapshot for the UI, or a call that changes what the core holds.

import Foundation

@MainActor
extension ChartController {
    // MARK: - Markers

    private func marker(from m: lookout_marker) -> ChartMarker {
        ChartMarker(id: m.id,
               lon: m.lon,
               lat: m.lat,
               name: m.name.map(String.init(cString:)) ?? "",
               droppedAt: Date(timeIntervalSince1970: Double(m.dropped_ms) / 1000))
    }

    /// Drop a marker at a geographic point. It is named in the same call, so
    /// nothing waits for typing. Nil when the core would not take it.
    @discardableResult
    func dropMarker(lon: Double, lat: Double) -> ChartMarker? {
        guard let h = handle else { return nil }
        let id = lookout_marker_add(h, lon, lat)
        guard id != 0 else { return nil }
        kick()
        var m = lookout_marker()
        guard lookout_marker_by_id(h, id, &m) != 0 else { return nil }
        return marker(from: m)
    }

    /// Every marker, in drop order.
    func markers() -> [ChartMarker] {
        guard let h = handle else { return [] }
        let n = Int(lookout_marker_count(h))
        return (0..<n).compactMap { i in
            var m = lookout_marker()
            guard lookout_marker_get(h, UInt32(i), &m) != 0 else { return nil }
            return marker(from: m)
        }
    }

    /// The marker under a point, in logical points, or nil when none is near.
    func marker(atPoint p: CGPoint) -> ChartMarker? {
        guard let h = handle else { return nil }
        var m = lookout_marker()
        guard lookout_marker_at(h, Float(p.x), Float(p.y), &m) != 0 else { return nil }
        return marker(from: m)
    }

    func marker(id: UInt64) -> ChartMarker? {
        guard let h = handle else { return nil }
        var m = lookout_marker()
        guard lookout_marker_by_id(h, id, &m) != 0 else { return nil }
        return marker(from: m)
    }

    /// Rename a marker. An empty name keeps the old one, which the core
    /// decides so every shell agrees.
    @discardableResult
    func renameMarker(_ id: UInt64, to name: String) -> Bool {
        guard let h = handle else { return false }
        let ok = name.withCString { lookout_marker_rename(h, id, $0) } == 0
        if ok { kick() }
        return ok
    }

    @discardableResult
    func removeMarker(_ id: UInt64) -> Bool {
        guard let h = handle else { return false }
        let ok = lookout_marker_remove(h, id) == 0
        if ok { kick() }
        return ok
    }
}
