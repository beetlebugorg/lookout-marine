//
//  The seabed under the sheet, sampled off the chart.
//
//  The chart shades depth in bands, and every band is a depth AREA that states
//  the range it covers: DRVAL1 at its shallow edge, DRVAL2 at its deep one. So
//  a grid of picks across the face reads a depth at every node, and the sheet
//  can be given a real underside: a slab whose bottom follows the seabed, with
//  the same colors on it that the chart uses on top. Seen from the side, the
//  bands are the contours.
//
//  Sampling costs about 0.75 ms a node, so a grid is built on a worker and
//  handed over when it is done. It is only rebuilt when the view has actually
//  moved: panning by a pixel does not change what the seabed looks like.
//

import Foundation

/// Depths on a regular grid over the chart face, shallow to deep in meters.
/// `nil` at a node the chart gives no depth for, which is land, or a gap
/// between cells.
struct DepthField {
    let columns: Int
    let rows: Int
    /// Row-major, `rows * columns` long. Index (r, c) is r * columns + c.
    let depths: [Float?]
    /// The view this was sampled at, so a later frame can tell whether it
    /// still describes what the sheet is showing.
    let lon: Double
    let lat: Double
    let zoom: Double

    subscript(row: Int, column: Int) -> Float? {
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        return depths[row * columns + column]
    }

    var deepest: Float {
        depths.compactMap { $0 }.max() ?? 0
    }

    /// How many nodes the chart answered for.
    var known: Int { depths.compactMap { $0 }.count }

    /// The same field with every gap filled from its nearest known node.
    ///
    /// A pick answers with the features worth reporting at a point, and a
    /// depth area drawn under a pier or a buoy is not always among them, so a
    /// raw field is holed. The water itself has no holes: the depth between
    /// two soundings is between those soundings. Filling makes the block a
    /// surface rather than a set of islands, and it is honest about being an
    /// interpolation because the numbers stay on the chart.
    func filled() -> DepthField {
        guard known > 0, known < depths.count else { return self }
        var out = depths
        // A breadth-first flood from every known node at once, so each gap
        // takes the value of the nearest one and the whole grid is one pass.
        var frontier: [Int] = []
        for i in depths.indices where depths[i] != nil { frontier.append(i) }
        while !frontier.isEmpty {
            var next: [Int] = []
            for i in frontier {
                let r = i / columns, c = i % columns
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                    let j = nr * columns + nc
                    guard out[j] == nil else { continue }
                    out[j] = out[i]
                    next.append(j)
                }
            }
            frontier = next
        }
        return DepthField(columns: columns, rows: rows, depths: out,
                          lon: lon, lat: lat, zoom: zoom)
    }

    /// True while this still describes the view. Zoom moves the ground the
    /// grid covers, so any change there is a resample; a pan of less than a
    /// tenth of the view is not worth one.
    func matches(lon: Double, lat: Double, zoom: Double, spanDegrees: Double) -> Bool {
        guard abs(zoom - self.zoom) < 0.01 else { return false }
        return abs(lon - self.lon) < spanDegrees * 0.1 && abs(lat - self.lat) < spanDegrees * 0.1
    }
}

extension DepthField {
    /// The depth a pick's features state at one position: the shallow edge of
    /// the shallowest depth area found there. The shallow edge is what a
    /// mariner navigates by, and the shallowest area is the one that matters
    /// where two overlap.
    ///
    /// A sounding is used when no area answers. It is a spot depth rather than
    /// a band, so it is the better number where it exists and the only one
    /// over a chart that carries no depth areas at all.
    static func depth(from features: [PickFeature]) -> Float? {
        var shallowest: Float?
        var sounding: Float?
        for f in features {
            guard let root = (try? JSONSerialization.jsonObject(with: Data(f.s57.utf8)))
                as? [String: Any] else { continue }
            // The payload is either the report envelope with the raw object
            // beside it, or the raw object alone.
            let raw = (root["s57"] as? [String: Any]) ?? root
            switch f.cls {
            case "DEPARE", "DRGARE":
                if let v = number(raw["DRVAL1"]) {
                    shallowest = shallowest.map { Swift.min($0, v) } ?? v
                }
            case "SOUNDG":
                if let v = number(raw["VALSOU"]) ?? number(raw["depth"]) {
                    sounding = sounding.map { Swift.min($0, v) } ?? v
                }
            case "LNDARE", "SLCONS", "COALNE", "PONTON", "DAMCON":
                // Land, a pier, a bulkhead, a pontoon: crust at the surface,
                // not a hole in it. A harbor is largely built waterfront, and
                // a block with holes where the docks are reads as damage.
                return 0
            default:
                continue
            }
        }
        return shallowest ?? sounding
    }

    /// S-57 numbers arrive as strings as often as numbers.
    private static func number(_ any: Any?) -> Float? {
        if let d = any as? Double { return Float(d) }
        if let i = any as? Int { return Float(i) }
        if let s = any as? String { return Float(s) }
        return nil
    }
}
