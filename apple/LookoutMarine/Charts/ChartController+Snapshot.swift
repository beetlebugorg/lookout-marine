//  ChartController+Snapshot.swift: a picture of the chart, and where it looks.
//
//  The coverage picker draws the app's own basemap. It needs the picture and
//  the ground it covers together: the picture is frozen, so a projection read
//  from the live camera afterward puts the region boxes somewhere else.

import CoreGraphics
import Foundation
import ImageIO

/// A picture of the chart with the ground it covers, corner to corner.
struct ChartSnapshot {
    /// Nil for the placeholder the picker draws before a picture is taken.
    let image: CGImage?
    /// Top left and bottom right of the picture, in degrees.
    let north: Double, west: Double
    let south: Double, east: Double
}

@MainActor
extension ChartController {

    /// A picture of the chart as it stands, with the ground it covers.
    ///
    /// The corners are read under the same camera as the picture, so the two
    /// describe the same ground however the chart moves afterward.
    func currentSnapshot() -> ChartSnapshot? {
        guard let h = handle, let v = view else { return nil }
        let size = CGSize(width: v.bounds.width, height: v.bounds.height)
        guard size.width > 1, size.height > 1 else { return nil }
        guard let nw = geo(atPoint: .zero),
              let se = geo(atPoint: CGPoint(x: size.width, y: size.height)),
              let image = pngSnapshot(h) else { return nil }
        return ChartSnapshot(image: image, north: nw.lat, west: nw.lon,
                             south: se.lat, east: se.lon)
    }

    /// True when the chart is showing `want`.
    ///
    /// Opening a chart applies its own default view, and that can land after a
    /// caller has asked for another one. A caller asks again until this holds.
    func isShowing(_ want: lookout_view, zoomTolerance: Double = 0.15,
                   lonTolerance: Double = 2) -> Bool {
        let v = currentView
        return abs(v.zoom - want.zoom) < zoomTolerance && abs(v.lon - want.lon) < lonTolerance
    }

    /// lookout_snapshot_png returns 0 for success and -1 for failure. The rest
    /// of the C API uses the opposite convention.
    private func pngSnapshot(_ h: OpaquePointer) -> CGImage? {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lookout-coverage-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }
        guard path.path.withCString({ lookout_snapshot_png(h, $0) }) == 0 else {
            lkLog("coverage map: lookout_snapshot_png failed")
            return nil
        }
        guard let src = CGImageSourceCreateWithURL(path as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            lkLog("coverage map: the snapshot png did not decode")
            return nil
        }
        return image
    }
}
