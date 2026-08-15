//
//  Traffic standing off the sheet.
//
//  The AIS plugin already draws every target flat on the chart: a triangle, a
//  heading line and a speed vector. This adds the part a flat chart cannot
//  show. Each vessel gets a hull sitting on the water at its own position and
//  a flag floating above it with its name, its speed and, when it is closing,
//  its approach. The hull is a fixed physical size at any chart scale, because
//  it is a marker and not a model.
//
//  The roster comes from the plugin's own table, so it is the same set of
//  vessels the chart is drawing, in the plugin's own order, with its own
//  alarm decision already made. Positions come from the chart, which is what
//  keeps a hull over its target while the chart pans.
//

import Foundation
import RealityKit
import UIKit
import simd

@MainActor
final class AISTraffic {
    let root = Entity()

    private var vessels: [String: Vessel] = [:]
    private var lastRosterAt: TimeInterval = 0
    private var opened = false

    /// What is drawn for one target. Entities are the main actor's, and this
    /// holds nothing else.
    @MainActor
    private final class Vessel {
        let root = Entity()
        let body = ModelEntity()
        let flag: FlagEntity
        /// A column of light standing over a vessel the plugin has called a
        /// threat. It is found from anywhere around the table, including from
        /// the far side where the flag faces away.
        let beam = ModelEntity()
        var lastSeen: TimeInterval = 0
        var headingDeg: Float = 0
        var alarm = false
        var label = ""

        init(flag: FlagEntity) {
            self.flag = flag
            root.addChild(body)
            root.addChild(flag.root)
            root.addChild(beam)
            beam.isEnabled = false
        }
    }

    // MARK: - The frame

    /// Bring the traffic up to date. Call it every frame: the roster is only
    /// re-read a few times a second, but positions are recomputed every frame
    /// so a hull stays over its target while the chart moves under it.
    func update(engine: ChartEngine, sheet: ChartSheet, now: TimeInterval) {
        if !opened {
            // A plugin builds table rows only while something is reading them.
            engine.setTableOpen(plugin: AISRows.plugin, key: AISRows.table, open: true)
            opened = true
        }
        if now - lastRosterAt > AISTraffic.rosterInterval {
            lastRosterAt = now
            refreshRoster(engine: engine, now: now)
        }
        place(engine: engine, sheet: sheet)
        retire(now: now)
    }

    func close(engine: ChartEngine) {
        guard opened else { return }
        engine.setTableOpen(plugin: AISRows.plugin, key: AISRows.table, open: false)
        opened = false
    }

    /// How often the roster is re-read. AIS position reports arrive every few
    /// seconds for a vessel under way, so three times a second is already
    /// faster than the data changes.
    private static let rosterInterval: TimeInterval = 0.33

    /// A target with no fresh row for this long has aged out of the plugin's
    /// own set and leaves the table.
    private static let retireAfter: TimeInterval = 6

    // MARK: - The roster

    private func refreshRoster(engine: ChartEngine, now: TimeInterval) {
        guard let data = engine.tableRows(plugin: AISRows.plugin, key: AISRows.table) else { return }
        let rows = AISRows.decode(data)

        for r in rows {
            let v = vessels[r.mmsi] ?? make(r)
            v.lastSeen = now
            // The heading the target reports, from the overlay payload the
            // plugin publishes for the same object. A target that reports
            // neither heading nor course keeps the one it had, so a hull never
            // snaps to north when a single report is missing it.
            if let info = engine.overlayInfo(id: AISRows.overlayID(mmsi: r.mmsi)),
               let deg = AISRows.heading(payload: info.info) {
                v.headingDeg = Float(deg)
            }
            if v.alarm != r.alarm {
                v.alarm = r.alarm
                v.body.model?.materials = [AISTraffic.bodyMaterial(alarm: r.alarm, aid: r.isAid)]
                v.beam.isEnabled = r.alarm
            }
            let label = r.flagLabel
            if label != v.label {
                v.label = label
                v.flag.setText(label, alarm: r.alarm)
            }
            v.root.components.set(TargetPositionComponent(lon: r.lon, lat: r.lat))
            vessels[r.mmsi] = v
        }
    }

    private func make(_ r: AISRow) -> Vessel {
        let flag = FlagEntity()
        let v = Vessel(flag: flag)
        v.body.model = ModelComponent(
            mesh: r.isAid ? .aidBuoy() : .vesselHull(),
            materials: [AISTraffic.bodyMaterial(alarm: r.alarm, aid: r.isAid)])
        v.root.name = "target-\(r.mmsi)"
        flag.root.position = [0, AISTraffic.flagHeight, 0]
        var beamMat = UnlitMaterial(color: UIColor(red: 1, green: 0.22, blue: 0.18, alpha: 0.30))
        beamMat.blending = .transparent(opacity: .init(floatLiteral: 1))
        v.beam.model = ModelComponent(
            mesh: .generateCylinder(height: AISTraffic.beamHeight, radius: 0.006),
            materials: [beamMat])
        v.beam.position = [0, AISTraffic.beamHeight / 2, 0]
        v.beam.isEnabled = r.alarm
        root.addChild(v.root)
        return v
    }

    /// Where each target's hull stands on the sheet. A target the chart has
    /// panned off the paper is hidden rather than removed: it is still a
    /// target, it is just not on this sheet.
    private func place(engine: ChartEngine, sheet: ChartSheet) {
        for (_, v) in vessels {
            guard let at = v.root.components[TargetPositionComponent.self],
                  let f = engine.fractionFor(lon: at.lon, lat: at.lat)
            else {
                v.root.isEnabled = false
                continue
            }
            let on = sheet.onSheet(f)
            v.root.isEnabled = on
            guard on else { continue }
            v.root.position = sheet.position(fraction: f, height: 0.001)
            // The hull points where the target is heading. Chart north is -Z
            // on the sheet, and a compass turns clockwise, so the yaw is the
            // negative of the heading.
            let north = Float(engine.rotationDegrees)
            v.body.orientation = simd_quatf(
                angle: -(v.headingDeg + north) * .pi / 180,
                axis: [0, 1, 0])
        }
    }

    private func retire(now: TimeInterval) {
        for (mmsi, v) in vessels where now - v.lastSeen > AISTraffic.retireAfter {
            v.root.removeFromParent()
            vessels.removeValue(forKey: mmsi)
        }
    }

    // MARK: - Look

    /// How high the flag floats above the water.
    private static let flagHeight: Float = 0.055

    /// How far the alarm beam reaches above the sheet. Taller than the flags,
    /// so it clears them and is seen across the table.
    private static let beamHeight: Float = 0.22

    private static func bodyMaterial(alarm: Bool, aid: Bool) -> RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        let tint: UIColor
        if alarm {
            tint = UIColor(red: 0.86, green: 0.16, blue: 0.16, alpha: 1)
        } else if aid {
            tint = UIColor(red: 0.95, green: 0.76, blue: 0.14, alpha: 1)
        } else {
            tint = UIColor(red: 0.90, green: 0.92, blue: 0.94, alpha: 1)
        }
        m.baseColor = .init(tint: tint)
        m.roughness = 0.45
        m.metallic = 0.0
        // An alarmed vessel glows, so it is found without reading a flag.
        if alarm { m.emissiveColor = .init(color: tint); m.emissiveIntensity = 0.6 }
        return m
    }
}

/// Where a target is, carried on its entity so a frame can place it without
/// going back to the plugin.
struct TargetPositionComponent: Component {
    var lon: Double
    var lat: Double
}

/// The flag above a target: a pole, a panel and the text on it, turned to face
/// whoever is reading it.
@MainActor
final class FlagEntity {
    let root = Entity()
    private let pole = ModelEntity()
    private let panel = Entity()
    private let text = ModelEntity()
    private let backing = ModelEntity()

    init() {
        root.addChild(pole)
        root.addChild(panel)
        panel.addChild(backing)
        panel.addChild(text)

        var poleMat = PhysicallyBasedMaterial()
        poleMat.baseColor = .init(tint: UIColor(white: 0.75, alpha: 1))
        poleMat.roughness = 0.4
        pole.model = ModelComponent(
            mesh: .generateCylinder(height: FlagEntity.poleHeight, radius: 0.0007),
            materials: [poleMat])
        // The pole runs from the water up to the panel, so its middle is half
        // its height below the flag.
        pole.position = [0, -FlagEntity.poleHeight / 2, 0]

        // The panel turns to face the reader. Only the panel does: a pole that
        // spun with it would look wrong from any angle.
        panel.components.set(BillboardComponent())
    }

    private static let poleHeight: Float = 0.055

    func setText(_ s: String, alarm: Bool) {
        let size: CGFloat = 0.009
        let mesh = MeshResource.generateText(
            s,
            extrusionDepth: 0.0002,
            font: .systemFont(ofSize: size, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byWordWrapping)
        var ink = UnlitMaterial()
        ink.color = .init(tint: alarm ? UIColor(red: 1, green: 0.86, blue: 0.86, alpha: 1) : .white)
        text.model = ModelComponent(mesh: mesh, materials: [ink])
        // Text is generated with its origin at the baseline of the first line,
        // running right and up. Center the block on the pole.
        let b = mesh.bounds
        text.position = [-b.center.x, -b.center.y, 0.0006]

        var panelMat = UnlitMaterial(
            color: alarm
                ? UIColor(red: 0.42, green: 0.05, blue: 0.05, alpha: 0.88)
                : UIColor(white: 0.08, alpha: 0.78))
        panelMat.blending = .transparent(opacity: .init(floatLiteral: 1))
        let pad: Float = 0.004
        backing.model = ModelComponent(
            mesh: .generatePlane(width: b.extents.x + pad * 2,
                                 height: b.extents.y + pad * 2,
                                 cornerRadius: 0.003),
            materials: [panelMat])
        backing.position = [0, 0, 0]
    }
}

extension MeshResource {
    /// A hull: a pointed bow, straight sides and a square stern, extruded to a
    /// deck. Small enough to read as a marker rather than a model of the ship.
    static func vesselHull(length: Float = 0.05, beam: Float = 0.017, height: Float = 0.010) -> MeshResource {
        let l = length / 2
        let b = beam / 2
        // The deck outline, bow first, going clockwise seen from above. +Z is
        // the bow, which is where the hull's own heading points.
        let outline: [SIMD2<Float>] = [
            [0, l], [b, l * 0.35], [b, -l], [-b, -l], [-b, l * 0.35],
        ]
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        // The deck, at full height.
        let deckStart = UInt32(positions.count)
        for p in outline {
            positions.append([p.x, height, p.y])
            normals.append([0, 1, 0])
        }
        for i in 1..<(outline.count - 1) {
            indices += [deckStart, deckStart + UInt32(i), deckStart + UInt32(i + 1)]
        }

        // The sides, from the waterline up to the deck. Each side is its own
        // pair of triangles with its own normal, so the hull keeps hard edges.
        for i in 0..<outline.count {
            let a = outline[i]
            let c = outline[(i + 1) % outline.count]
            let base = UInt32(positions.count)
            positions += [
                [a.x, 0, a.y], [c.x, 0, c.y],
                [c.x, height, c.y], [a.x, height, a.y],
            ]
            let edge = SIMD3<Float>(c.x - a.x, 0, c.y - a.y)
            let n = normalize(SIMD3<Float>(edge.z, 0, -edge.x))
            normals += [n, n, n, n]
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }

        var d = MeshDescriptor(name: "hull")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [d]))
            ?? .generateBox(width: beam, height: height, depth: length)
    }

    /// An aid to navigation: a float with a light on a short mast. Aids do not
    /// move, so they carry no heading and need no hull.
    static func aidBuoy(height: Float = 0.028, radius: Float = 0.006) -> MeshResource {
        .generateCone(height: height, radius: radius)
    }
}
