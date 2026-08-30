//  ChartController+Pick.swift — what is under a point.
//
//  Two questions, and not the same one. The overlay answers for what a plugin
//  drew; the pick answers for what the chart holds. The core decides what a
//  pick reports and in what order (pick.zig), so no two shells can drift apart
//  on it.

import Foundation

@MainActor
extension ChartController {
    // MARK: - Overlay hover

    /// What the plugin overlay says about the symbol nearest a point, in
    /// logical points. nil when nothing is near it.
    func overlayInfo(atPoint p: CGPoint) -> OverlayHover? {
        guard let h = handle else { return nil }
        var len = 0
        guard let raw = lookout_overlay_at(h, Float(p.x), Float(p.y), &len), len > 0 else {
            return nil
        }
        // Borrowed until the next call, so copy before anything else runs.
        return OverlayHover(json: Data(bytes: raw, count: len))
    }

    /// The overlay object under a point, with its id and anchor. nil when
    /// nothing is near it. A tap uses this; hover uses `overlayInfo(atPoint:)`.
    func overlayHit(atPoint p: CGPoint) -> OverlayPin? {
        guard let h = handle else { return nil }
        var o = lookout_overlay_obj()
        guard lookout_overlay_hit(h, Float(p.x), Float(p.y), &o) != 0 else { return nil }
        return pin(from: o)
    }

    /// What a pinned object says now, or nil once it is gone.
    func overlayInfo(id: String) -> OverlayPin? {
        guard let h = handle else { return nil }
        var o = lookout_overlay_obj()
        guard id.withCString({ lookout_overlay_info(h, $0, &o) }) != 0 else { return nil }
        return pin(from: o)
    }

    /// Everything in the struct is borrowed until the next overlay call, so
    /// copy both strings out before anything else runs.
    private func pin(from o: lookout_overlay_obj) -> OverlayPin? {
        guard let idp = o.id, let infop = o.info, o.info_len > 0 else { return nil }
        let id = String(cString: idp)
        guard let info = OverlayHover(json: Data(bytes: infop, count: o.info_len)) else { return nil }
        return OverlayPin(id: id, info: info, lon: o.lon, lat: o.lat)
    }

    // CADisplayLink fires on the main run loop; assume main-actor isolation.
    // MARK: - Cursor pick

    func pick(lon: Double, lat: Double) -> [PickFeature] {
        guard let h = handle else { return [] }
        var results: [PickFeature] = []
        withUnsafeMutablePointer(to: &results) { ctx in
            var cb = tile57_query_cb(
                ctx: UnsafeMutableRawPointer(ctx),
                feature: { c, cls, clsLen, s57, s57Len, chart, chartLen in
                    guard let c else { return }
                    let arr = c.assumingMemoryBound(to: [PickFeature].self)
                    func str(_ p: UnsafePointer<CChar>?, _ n: Int) -> String {
                        guard let p, n > 0 else { return "" }
                        return String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
                    }
                    arr.pointee.append(PickFeature(cls: str(cls, clsLen),
                                                   chart: str(chart, chartLen),
                                                   s57: str(s57, s57Len)))
                })
            // The core decides what a pick reports and in what order (pick.zig),
            // so every shell shows the same thing.
            lookout_pick_ranked(h, lon, lat, &cb)
        }
        return results
    }
}
