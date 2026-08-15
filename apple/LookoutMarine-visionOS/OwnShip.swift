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
    /// Where the view parents its attachment. It floats above the spot, clear
    /// of the traffic standing on the sheet.
    let mount = Entity()
    private let stem = ModelEntity()

    private(set) var lon = 0.0
    private(set) var lat = 0.0

    init() {
        root.name = "pick-card"
        root.addChild(stem)
        root.addChild(mount)
        mount.position = [0, PickCard.height, 0]

        var stemMat = UnlitMaterial(color: UIColor(white: 1, alpha: 0.55))
        stemMat.blending = .transparent(opacity: .init(floatLiteral: 1))
        stem.model = ModelComponent(
            mesh: .generateCylinder(height: PickCard.height, radius: 0.0006),
            materials: [stemMat])
        stem.position = [0, PickCard.height / 2, 0]
        root.isEnabled = false
    }

    /// High enough to clear a flag over a vessel at the same spot.
    private static let height: Float = 0.14

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
    }
}
