//
//  Own ship on the table, and the card that answers a tap on the chart.
//
//  Own ship's position comes from the plugin layer, so it appears when a
//  vessel plugin is publishing a fix and stays away when none is.
//

import Foundation
import RealityKit
import UIKit
import simd

/// The boat, standing on the sheet where the chart says it is.
@MainActor
final class OwnShip {
    let root = Entity()
    private let hull = ModelEntity()

    init() {
        root.name = "own-ship"
        root.addChild(hull)
        var m = PhysicallyBasedMaterial()
        // Own ship is the one thing on the table that is not traffic, so it
        // carries its own color and does not share the traffic palette.
        m.baseColor = .init(tint: UIColor(red: 0.18, green: 0.55, blue: 0.92, alpha: 1))
        m.roughness = 0.35
        m.emissiveColor = .init(color: UIColor(red: 0.18, green: 0.55, blue: 0.92, alpha: 1))
        m.emissiveIntensity = 0.35
        hull.model = ModelComponent(
            mesh: .vesselHull(length: 0.06, beam: 0.020, height: 0.012),
            materials: [m])
        root.isEnabled = false
    }

    func update(engine: ChartEngine, sheet: ChartSheet) {
        guard let ship = engine.ownShip,
              let f = engine.fractionFor(lon: ship.lon, lat: ship.lat),
              sheet.onSheet(f)
        else {
            root.isEnabled = false
            return
        }
        root.isEnabled = true
        root.position = sheet.position(fraction: f, height: 0.001)
    }
}

/// Where a pick's report hangs: an anchor over the tapped position with a thin
/// stem down to it. The panel itself is a SwiftUI attachment the view hands
/// over, so the report is a real form and not text drawn into a mesh. The
/// anchor holds its place in chart coordinates, so panning carries it along
/// and it hides when its feature leaves the sheet.
@MainActor
final class PickCard {
    let root = Entity()
    /// Where the view parents its attachment. A SwiftUI attachment is centered
    /// on the entity it hangs from, so this is lifted by half the panel's own
    /// height and the panel ends up entirely above the paper.
    let mount = Entity()
    private let stem = ModelEntity()

    private(set) var lon = 0.0
    private(set) var lat = 0.0

    init() {
        root.name = "pick-card"
        root.addChild(stem)
        root.addChild(mount)
        // The panel turns to face whoever is reading it. A report is text, and
        // text seen edge on from the far side of the table is no report.
        mount.components.set(BillboardComponent())

        var stemMat = UnlitMaterial(color: UIColor(white: 1, alpha: 0.55))
        stemMat.blending = .transparent(opacity: .init(floatLiteral: 1))
        // A unit cylinder, scaled to reach whatever height the panel settles
        // at. Its own origin is its middle, so it is positioned at half.
        stem.model = ModelComponent(
            mesh: .generateCylinder(height: 1, radius: 0.0006),
            materials: [stemMat])
        setLift(PickCard.clearance)
        root.isEnabled = false
    }

    /// How far the bottom of the panel floats above the sheet. Enough to clear
    /// a flag standing over a vessel at the same spot.
    private static let clearance: Float = 0.07

    func show(lon: Double, lat: Double) {
        self.lon = lon
        self.lat = lat
        root.isEnabled = true
    }

    func hide() {
        root.isEnabled = false
    }

    var isShowing: Bool { root.isEnabled }

    func update(engine: ChartEngine, sheet: ChartSheet) {
        guard root.isEnabled else { return }
        guard let f = engine.fractionFor(lon: lon, lat: lat), sheet.onSheet(f) else {
            root.isEnabled = false
            return
        }
        root.position = sheet.position(fraction: f, height: 0)
        // The attachment is laid out by SwiftUI, so its height is only known
        // once it exists, and it changes with the report it holds.
        if let panel = mount.children.first {
            let h = panel.visualBounds(relativeTo: mount).extents.y
            if h > 0 { setLift(PickCard.clearance + h / 2) }
        }
    }

    /// Put the panel's middle at `y`, and run the stem from the paper up to it.
    private func setLift(_ y: Float) {
        guard abs(mount.position.y - y) > 0.001 else { return }
        mount.position = [0, y, 0]
        stem.scale = [1, y, 1]
        stem.position = [0, y / 2, 0]
    }
}
