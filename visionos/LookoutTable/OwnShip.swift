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

/// What the chart holds where the mariner tapped, on a card floating over the
/// spot with a line down to it. The card stays put on the chart, so panning
/// the chart carries it along and it leaves the sheet when its feature does.
@MainActor
final class PickCard {
    let root = Entity()
    private let panel = Entity()
    private let text = ModelEntity()
    private let backing = ModelEntity()
    private let stem = ModelEntity()

    private var lon = 0.0
    private var lat = 0.0

    init() {
        root.name = "pick-card"
        root.addChild(stem)
        root.addChild(panel)
        panel.addChild(backing)
        panel.addChild(text)
        panel.components.set(BillboardComponent())
        panel.position = [0, PickCard.height, 0]

        var stemMat = UnlitMaterial(color: UIColor(white: 1, alpha: 0.55))
        stemMat.blending = .transparent(opacity: .init(floatLiteral: 1))
        stem.model = ModelComponent(
            mesh: .generateCylinder(height: PickCard.height, radius: 0.0006),
            materials: [stemMat])
        stem.position = [0, PickCard.height / 2, 0]
        root.isEnabled = false
    }

    private static let height: Float = 0.09

    /// Show the report. An empty pick closes the card: a tap on open water
    /// means the mariner is done reading, not that the card should stay.
    func show(features: [PickFeature], lon: Double, lat: Double) {
        guard !features.isEmpty else {
            root.isEnabled = false
            return
        }
        self.lon = lon
        self.lat = lat
        let lines = features.prefix(4).map(\.headline)
        setText(lines.joined(separator: "\n"))
        root.isEnabled = true
    }

    func hide() {
        root.isEnabled = false
    }

    func update(engine: ChartEngine, sheet: ChartSheet) {
        guard root.isEnabled else { return }
        guard let f = engine.fractionFor(lon: lon, lat: lat), sheet.onSheet(f) else {
            root.isEnabled = false
            return
        }
        root.position = sheet.position(fraction: f, height: 0)
    }

    private func setText(_ s: String) {
        let mesh = MeshResource.generateText(
            s,
            extrusionDepth: 0.0002,
            font: .systemFont(ofSize: 0.010, weight: .regular),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byWordWrapping)
        var ink = UnlitMaterial()
        ink.color = .init(tint: .white)
        text.model = ModelComponent(mesh: mesh, materials: [ink])
        let b = mesh.bounds
        text.position = [-b.center.x, -b.center.y, 0.0006]

        var panelMat = UnlitMaterial(color: UIColor(white: 0.06, alpha: 0.82))
        panelMat.blending = .transparent(opacity: .init(floatLiteral: 1))
        let pad: Float = 0.006
        backing.model = ModelComponent(
            mesh: .generatePlane(width: b.extents.x + pad * 2,
                                 height: b.extents.y + pad * 2,
                                 cornerRadius: 0.004),
            materials: [panelMat])
    }
}
