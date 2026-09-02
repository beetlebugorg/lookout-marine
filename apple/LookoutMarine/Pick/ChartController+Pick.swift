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

    /// What the chart holds under a point, decoded. The core decides what a
    /// pick reports, in what order, and what each page says (pick.zig), so
    /// every shell shows the same thing.
    func pick(lon: Double, lat: Double) -> [PickDecoded] {
        guard let h = handle, let read = lookout_picks_read(h, lon, lat) else { return [] }
        defer { lookout_picks_free(read) }
        var n = 0
        guard let all = lookout_picks_all(read, &n) else { return [] }
        return (0..<n).compactMap { i in
            guard let f = all[i] else { return nil }
            var count = 0
            var notes: [String] = []
            if let ns = lookout_pick_notes(f, &count) {
                notes = (0..<count).compactMap { ns[$0].map { String(cString: $0) } }
            }
            let rows = lookout_pick_rows(f, &count)
            let page = Self.rows(rows, count)
            let src = lookout_pick_source(f, &count)
            let fold = Self.rows(src, count)
            return PickDecoded(f.pointee, notes: notes, rows: page, source: fold)
        }
    }

    /// One of a feature's row arrays, copied out of the read.
    private static func rows(_ p: UnsafePointer<UnsafePointer<lookout_pick_row>?>?,
                             _ n: Int) -> [PickDecoded.Row] {
        guard let p else { return [] }
        return (0..<n).compactMap { p[$0].map { PickDecoded.Row($0.pointee) } }
    }

    /// A file a picked feature points at, by the cell it came from and the name
    /// the attribute carries. The bytes belong to the engine and stay valid
    /// while the chart is open, so they are copied here.
    func auxFile(cell: String, named name: String) -> (data: Data, mime: String)? {
        guard let h = handle else { return nil }
        var bytes: UnsafePointer<UInt8>?
        var len = 0
        var mime: UnsafePointer<CChar>?
        lookout_aux_file(h, cell, name, &bytes, &len, &mime)
        guard let bytes, len > 0 else { return nil }
        return (Data(bytes: bytes, count: len),
                mime.map { String(cString: $0) } ?? "application/octet-stream")
    }
}
