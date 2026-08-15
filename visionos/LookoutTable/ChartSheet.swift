//
//  The chart sheet: a sheet of paper lying on the table with the chart printed
//  inside its margin.
//
//  The entity tree, and what each part is for:
//
//    sheetRoot          the mariner's handle on the whole thing. Moving,
//    │                  turning and resizing the sheet moves this.
//    ├── paper          the sheet itself, a thin white slab. Its exposed rim
//    │                  IS the margin, and the margin is what a hand grabs.
//    ├── face           the printed chart, a plane just above the paper.
//    │                  A hand on the face moves the CHART, not the sheet.
//    ├── titleBlock     chart name and scale, printed on the bottom margin.
//    └── overlays       everything standing off the sheet: traffic, own ship,
//                       the pick card. Positioned from chart fractions, so
//                       they follow the chart as it pans.
//
//  Sizes are in meters and everything derives from the sheet's width. A larger
//  sheet shows MORE chart at the same scale, the way unrolling a larger sheet
//  of paper does, so the chart's logical size grows with it and the texture
//  grows to match.
//

import Foundation
import RealityKit
import UIKit
import simd

/// Marks the printed chart. A hand here moves the chart.
struct ChartFaceTag: Component {}

/// Marks the paper margin. A hand here moves the sheet.
struct SheetBorderTag: Component {}

enum SheetMetrics {
    /// Points of chart per meter of sheet. 1 pt is half a millimeter of paper,
    /// which puts a chart symbol at about the size S-52 prints it and a label
    /// within reading distance of a table.
    static let pointsPerMeter: Float = 2000

    /// Pixels per point. The headset resolves about 3.4 px/mm at half a meter,
    /// and 1.5 px/pt is 3 px/mm, so more pixels than this buys nothing the eye
    /// can see and costs texture memory in every drawable.
    static let density: Float = 1.5

    /// The paper margin, as a fraction of sheet width. A NOAA sheet's margin
    /// is about 4% of its width and carries the scale bar and the notes.
    static let marginFraction: Float = 0.045

    /// How thick the sheet is. Paper is thinner; at this thickness the edge
    /// catches the room's light and the sheet reads as an object.
    static let thickness: Float = 0.0015

    /// The chart floats this far above the paper's top face so the two never
    /// fight for the same depth.
    static let faceLift: Float = 0.0004

    /// What a sheet may be resized to, corner to corner in meters of width.
    static let minWidth: Float = 0.35
    static let maxWidth: Float = 1.8

    /// A chart sheet is wider than it is deep, as printed charts are.
    static let aspect: Float = 0.72

    /// Sheet width to chart face size, in meters.
    static func faceSize(sheetWidth w: Float) -> SIMD2<Float> {
        let margin = w * marginFraction
        return SIMD2<Float>(w - 2 * margin, w * aspect - 2 * margin)
    }

    /// The chart's logical viewport for a sheet of this width, in whole even
    /// points so that points times the density is a whole number of pixels.
    /// A texture whose aspect differs from the viewport's stretches the chart.
    static func points(sheetWidth w: Float) -> SIMD2<Float> {
        let f = faceSize(sheetWidth: w)
        func even(_ v: Float) -> Float { max(64, (v / 2).rounded() * 2) }
        return SIMD2<Float>(even(f.x * pointsPerMeter), even(f.y * pointsPerMeter))
    }

    /// The texture size for a sheet of this width.
    static func pixels(sheetWidth w: Float) -> SIMD2<Int> {
        let p = points(sheetWidth: w)
        return SIMD2<Int>(Int(p.x * density), Int(p.y * density))
    }
}

@MainActor
final class ChartSheet {
    let root = Entity()
    let paper = ModelEntity()
    let face = ModelEntity()
    let overlays = Entity()
    private let titleBlock = ModelEntity()
    private let scaleBar = ModelEntity()
    private let scaleLabel = ModelEntity()
    private let northArrow = ModelEntity()
    private let northLabel = ModelEntity()

    /// The sheet's width in meters. Setting it rebuilds the meshes; the chart
    /// texture is rebuilt by the owner, which knows the engine.
    private(set) var width: Float = 0.9

    init() {
        root.name = "sheet"
        paper.name = "paper"
        face.name = "face"
        overlays.name = "overlays"
        root.addChild(paper)
        root.addChild(face)
        root.addChild(overlays)
        root.addChild(titleBlock)
        root.addChild(scaleBar)
        root.addChild(scaleLabel)
        root.addChild(northArrow)
        northArrow.addChild(northLabel)

        paper.components.set(SheetBorderTag())
        paper.components.set(InputTargetComponent())
        // The sheet is a real object in the room: it casts a shadow onto the
        // table it lies on.
        paper.components.set(GroundingShadowComponent(castsShadow: true))
        // A pool of light follows the mariner's eyes across the margin. It is
        // the app's only signal that the margin is the part a hand grabs.
        paper.components.set(HoverEffectComponent(.spotlight(.default)))

        face.components.set(ChartFaceTag())
        face.components.set(InputTargetComponent())

        rebuild()
    }

    // MARK: - Geometry

    /// Rebuild the meshes for the current width.
    func rebuild() {
        let depth = width * SheetMetrics.aspect
        let t = SheetMetrics.thickness
        let f = SheetMetrics.faceSize(sheetWidth: width)

        paper.model = ModelComponent(
            mesh: .generateBox(width: width, height: t, depth: depth),
            materials: [ChartSheet.paperMaterial()])
        paper.collision = CollisionComponent(shapes: [
            .generateBox(width: width, height: t, depth: depth)
        ])

        face.model = ModelComponent(
            mesh: .chartFace(width: f.x, depth: f.y),
            materials: [face.model?.materials.first ?? UnlitMaterial(color: .white)])
        face.position = [0, t / 2 + SheetMetrics.faceLift, 0]
        // Thin, so a hand aiming at the chart cannot hit the paper behind it,
        // and the two targets never overlap.
        face.collision = CollisionComponent(shapes: [
            .generateBox(width: f.x, height: 0.0008, depth: f.y)
        ])
    }

    /// Set the sheet's width, clamped to what a table can hold.
    func setWidth(_ w: Float) {
        width = min(max(w, SheetMetrics.minWidth), SheetMetrics.maxWidth)
        rebuild()
    }

    /// Show the chart texture on the face.
    func setChartTexture(_ texture: TextureResource) {
        // Unlit: the chart's colors are the mariner's own day, dusk and night
        // palettes, and a light in the room must not restate them. The paper
        // around it is lit, so the sheet still sits in the room.
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(texture))
        face.model?.materials = [m]
    }

    private static func paperMaterial() -> RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        // Warm white, the color of chart paper rather than office white.
        m.baseColor = .init(tint: UIColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1))
        m.roughness = 0.88
        m.metallic = 0.0
        return m
    }

    // MARK: - The title block

    private var titleText = ""

    /// Print the chart's name and scale on the bottom margin, the way a paper
    /// chart carries them. Regenerating the text mesh is not free, so it only
    /// runs when the words change.
    func setTitle(_ text: String) {
        guard text != titleText else { return }
        titleText = text
        let height = width * SheetMetrics.marginFraction * 0.42
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.0001,
            font: .systemFont(ofSize: CGFloat(height), weight: .medium),
            containerFrame: .zero,
            alignment: .left,
            lineBreakMode: .byTruncatingTail)
        var ink = UnlitMaterial()
        ink.color = .init(tint: UIColor(white: 0.22, alpha: 1))
        titleBlock.model = ModelComponent(mesh: mesh, materials: [ink])
        // Text is generated standing up in the XY plane; lay it flat on the
        // margin, reading from the near edge.
        titleBlock.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        let depth = width * SheetMetrics.aspect
        let margin = width * SheetMetrics.marginFraction
        titleBlock.position = [
            -width / 2 + margin * 0.6,
            SheetMetrics.thickness / 2 + SheetMetrics.faceLift,
            depth / 2 - margin * 0.30,
        ]
    }

    // MARK: - The scale bar and the north arrow

    private var scaleBarMeters: Double = 0

    /// Print a scale bar on the bottom margin, the way a chart carries one.
    /// `groundPerSheetMeter` is how many meters of sea one meter of paper
    /// covers, measured off the chart itself rather than derived from the
    /// scale denominator, so it stays right whatever the projection is doing
    /// at this latitude.
    func setScale(groundPerSheetMeter: Double) {
        guard groundPerSheetMeter > 0, groundPerSheetMeter.isFinite else {
            scaleBar.isEnabled = false
            scaleLabel.isEnabled = false
            return
        }
        scaleBar.isEnabled = true
        scaleLabel.isEnabled = true
        let face = SheetMetrics.faceSize(sheetWidth: width)
        // The bar wants to be a round number of miles about a quarter of the
        // sheet wide. Walk the choices and take the last one that fits.
        let want = Double(face.x) * 0.25 * groundPerSheetMeter
        var miles = ChartSheet.barMiles.first ?? 1
        for m in ChartSheet.barMiles where m * ChartSheet.metersPerMile <= want { miles = m }
        let meters = miles * ChartSheet.metersPerMile
        guard meters != scaleBarMeters else { return }
        scaleBarMeters = meters

        let length = Float(meters / groundPerSheetMeter)
        let thickness = width * SheetMetrics.marginFraction * 0.10
        var ink = UnlitMaterial()
        ink.color = .init(tint: UIColor(white: 0.22, alpha: 1))
        scaleBar.model = ModelComponent(
            mesh: .generatePlane(width: length, depth: thickness),
            materials: [ink])
        let depth = width * SheetMetrics.aspect
        let margin = width * SheetMetrics.marginFraction
        let y = SheetMetrics.thickness / 2 + SheetMetrics.faceLift
        scaleBar.position = [width / 2 - margin * 0.6 - length / 2, y, depth / 2 - margin * 0.55]

        let text = miles < 1
            ? String(format: "%.1f nm", miles)
            : String(format: "%.0f nm", miles)
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.0001,
            font: .systemFont(ofSize: CGFloat(margin * 0.38), weight: .regular),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byClipping)
        scaleLabel.model = ModelComponent(mesh: mesh, materials: [ink])
        scaleLabel.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        let b = mesh.bounds
        scaleLabel.position = [
            scaleBar.position.x - b.extents.x / 2,
            y,
            depth / 2 - margin * 0.22,
        ]
    }

    /// Nautical miles a scale bar is willing to be.
    private static let barMiles: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100]
    private static let metersPerMile: Double = 1852

    /// Turn the north arrow to where north is now. The chart turns under the
    /// paper, so the arrow is the only thing on the sheet that says which way
    /// the chart is lying.
    func setNorth(rotationDegrees: Double) {
        let margin = width * SheetMetrics.marginFraction
        let depth = width * SheetMetrics.aspect
        let y = SheetMetrics.thickness / 2 + SheetMetrics.faceLift
        if northArrow.model == nil {
            var ink = UnlitMaterial()
            ink.color = .init(tint: UIColor(white: 0.22, alpha: 1))
            northArrow.model = ModelComponent(
                mesh: .northArrow(length: margin * 1.3),
                materials: [ink])
            let mesh = MeshResource.generateText(
                "N",
                extrusionDepth: 0.0001,
                font: .systemFont(ofSize: CGFloat(margin * 0.42), weight: .semibold),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byClipping)
            northLabel.model = ModelComponent(mesh: mesh, materials: [ink])
            northLabel.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            let b = mesh.bounds
            northLabel.position = [-b.extents.x / 2, 0, -margin * 0.95]
        }
        northArrow.position = [width / 2 - margin * 0.55, y, -depth / 2 + margin * 0.75]
        // A chart rotated clockwise puts north anticlockwise of the sheet's
        // own up, which is -Z.
        northArrow.orientation = simd_quatf(angle: Float(rotationDegrees * .pi / 180), axis: [0, 1, 0])
    }

    // MARK: - Placing things on the chart

    /// Where a chart fraction (0,0 top left to 1,1 bottom right) lands in the
    /// sheet's own space, at a given height above the paper.
    func position(fraction f: SIMD2<Float>, height: Float = 0) -> SIMD3<Float> {
        let size = SheetMetrics.faceSize(sheetWidth: width)
        return SIMD3<Float>(
            (f.x - 0.5) * size.x,
            SheetMetrics.thickness / 2 + SheetMetrics.faceLift + height,
            (f.y - 0.5) * size.y)
    }

    /// The reverse: what chart fraction a point in the sheet's space is over.
    func fraction(at p: SIMD3<Float>) -> SIMD2<Float> {
        let size = SheetMetrics.faceSize(sheetWidth: width)
        return SIMD2<Float>(p.x / size.x + 0.5, p.z / size.y + 0.5)
    }

    /// True while a fraction is on the printed chart. Traffic outside this is
    /// off the sheet and is not drawn.
    func onSheet(_ f: SIMD2<Float>) -> Bool {
        f.x >= 0 && f.x <= 1 && f.y >= 0 && f.y <= 1
    }
}

extension MeshResource {
    /// A flat arrow in the XZ plane pointing at -Z, which is the sheet's own
    /// up. Turning the entity turns the arrow to wherever north has gone.
    static func northArrow(length: Float) -> MeshResource {
        let w = length * 0.26
        let headLength = length * 0.42
        let tail = length / 2
        var d = MeshDescriptor(name: "northArrow")
        d.positions = MeshBuffers.Positions([
            // The head.
            [0, 0, -tail], [w, 0, -tail + headLength], [-w, 0, -tail + headLength],
            // The shaft.
            [w * 0.32, 0, -tail + headLength], [w * 0.32, 0, tail],
            [-w * 0.32, 0, tail], [-w * 0.32, 0, -tail + headLength],
        ])
        d.normals = MeshBuffers.Normals(Array(repeating: [0, 1, 0], count: 7))
        d.primitives = .triangles([0, 1, 2, 3, 4, 5, 3, 5, 6])
        return (try? MeshResource.generate(from: [d]))
            ?? .generatePlane(width: w, depth: length)
    }

    /// A flat rectangle in the XZ plane, facing up, carrying the chart.
    ///
    /// The chart's north lands at the sheet's far edge (-Z) and its west at
    /// the near-left (-X), which is where the overlay positions put traffic
    /// and own ship as well. Reaching that takes v=1 at the far edge, not v=0:
    /// the row the renderer draws chart north into is the row this samples
    /// last. Mapping it the other way shows the chart mirrored top to bottom,
    /// which reads as text seen from behind the paper, and leaves every
    /// overlay on the wrong side of the chart it belongs to.
    ///
    /// Generated rather than taken from generatePlane so the mapping is stated
    /// here and cannot drift.
    static func chartFace(width: Float, depth: Float) -> MeshResource {
        let hw = width / 2
        let hd = depth / 2
        var d = MeshDescriptor(name: "chartFace")
        d.positions = MeshBuffers.Positions([
            [-hw, 0, -hd], [hw, 0, -hd], [hw, 0, hd], [-hw, 0, hd],
        ])
        d.normals = MeshBuffers.Normals([[0, 1, 0], [0, 1, 0], [0, 1, 0], [0, 1, 0]])
        d.textureCoordinates = MeshBuffers.TextureCoordinates([
            [0, 1], [1, 1], [1, 0], [0, 0],
        ])
        d.primitives = .triangles([0, 2, 1, 0, 3, 2])
        return (try? MeshResource.generate(from: [d])) ?? .generatePlane(width: width, depth: depth)
    }
}
