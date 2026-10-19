//  RegionShape.swift: one region's coverage, as a path on the map.

import SwiftUI

/// One region's coverage, as the boxes the catalog states for its coarse
/// cells. Drawn as a single path, so overlapping cells do not stack their fill.
struct RegionShape: Shape {
    let boxes: [GeoBox]
    let window: MapWindow

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let corners = window.points(boxes.flatMap { [$0.west, $0.north, $0.east, $0.south] },
                                    in: rect.size)
        for i in stride(from: 0, to: corners.count - 1, by: 2) {
            let a = corners[i], c = corners[i + 1]
            p.addRect(CGRect(x: min(a.x, c.x), y: min(a.y, c.y),
                             width: max(abs(c.x - a.x), 1.5),
                             height: max(abs(c.y - a.y), 1.5)))
        }
        return p
    }
}
