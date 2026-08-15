//
//  The water under the chart, as a cut block of the earth.
//
//  The sheet is the sea surface with the chart printed on it. Under it hangs a
//  block: its bottom is the seabed, its sides are the cut through the water,
//  and the cut is banded the way the chart is shaded. Tilt the table and the
//  block reads the way a cross-section of a coast reads. Where the chart shows
//  land the block comes up to the surface, so the coastline is a wall of crust
//  and the channel beside it is a trough.
//
//  Every color is decided by DEPTH and nothing else, so a wall shows its bands
//  as horizontal layers, not as one tint. One ramp texture carries them: a
//  vertex is given a v coordinate of its own depth over the deepest, and the
//  ramp does the rest.
//
//  The relief is vertical exaggeration, not scale. A harbor is tens of meters
//  deep over a mile of water, so a true-scale seabed would be flat to the eye.
//  The block is a fixed depth in meters of sheet whatever the deepest sounding
//  is: the SHAPE is honest, the depth is not, and the numbers stay on the
//  chart above it.
//

import RealityKit
import UIKit
import simd

@MainActor
final class Seabed {
    let root = Entity()
    private let model = ModelEntity()

    /// The field the current block was built from.
    private(set) var field: DepthField?

    init() {
        root.name = "seabed"
        root.addChild(model)
        root.isEnabled = false
    }

    /// How far the deepest water hangs below the paper. Deep enough to read
    /// the shape across the table, shallow enough that the sheet still reads
    /// as a sheet rather than a fish tank.
    static let relief: Float = 0.08

    var isShowing: Bool { root.isEnabled }

    func setShowing(_ on: Bool) {
        root.isEnabled = on
    }

    /// Build the block for a sampled field, sized to the chart face.
    func rebuild(field: DepthField, face: SIMD2<Float>, thickness: Float) {
        self.field = field
        guard let mesh = MeshResource.seabed(field: field, face: face, relief: Seabed.relief) else { return }
        model.model = ModelComponent(mesh: mesh, materials: [Seabed.crustMaterial(deepest: field.deepest)])
        // Hung from the underside of the paper.
        model.position = [0, -thickness / 2, 0]
    }

    /// The chart's depth shading, as a ramp the block samples by depth.
    private static func crustMaterial(deepest: Float) -> RealityKit.Material {
        var m = PhysicallyBasedMaterial()
        m.roughness = 0.9
        m.metallic = 0.0
        // The block is looked at from below and from the side, and a cut face
        // has no back to hide.
        m.faceCulling = .none
        if let texture = try? TextureResource(image: DepthBands.ramp(deepest: deepest),
                                              options: .init(semantic: .color, mipmapsMode: .none)) {
            m.baseColor = .init(tint: .white, texture: .init(texture))
        } else {
            m.baseColor = .init(tint: DepthBands.color(for: deepest))
        }
        return m
    }
}

extension MeshResource {
    /// The seabed, and the four walls of the cut down to it.
    ///
    /// A vertex's v coordinate is its own depth over the deepest, so the ramp
    /// paints the bands: level across the seabed, and layered down a wall.
    static func seabed(field: DepthField, face: SIMD2<Float>, relief: Float) -> MeshResource? {
        guard field.columns > 1, field.rows > 1 else { return nil }
        let deepest = max(field.deepest, 1)

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        /// A node's depth, and land as zero: the crust comes to the surface.
        func depth(_ row: Int, _ col: Int) -> Float {
            max(0, field[row, col] ?? 0)
        }
        /// Where a node sits on the face. The grid's nodes are cell middles,
        /// and the outermost are pulled out to the edge so the block fills the
        /// sheet rather than stopping a cell short of it.
        func plan(_ row: Int, _ col: Int) -> SIMD2<Float> {
            var u = (Float(col) + 0.5) / Float(field.columns)
            var v = (Float(row) + 0.5) / Float(field.rows)
            if col == 0 { u = 0 } else if col == field.columns - 1 { u = 1 }
            if row == 0 { v = 0 } else if row == field.rows - 1 { v = 1 }
            return SIMD2<Float>((u - 0.5) * face.x, (v - 0.5) * face.y)
        }
        func at(_ row: Int, _ col: Int) -> SIMD3<Float> {
            let p = plan(row, col)
            return SIMD3<Float>(p.x, -relief * (depth(row, col) / deepest), p.y)
        }
        /// The ramp is sampled by depth alone, so u is anything.
        func band(_ d: Float) -> SIMD2<Float> {
            SIMD2<Float>(0.5, min(max(d / deepest, 0), 1))
        }

        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                  _ ta: SIMD2<Float>, _ tb: SIMD2<Float>, _ tc: SIMD2<Float>, _ td: SIMD2<Float>) {
            let base = UInt32(positions.count)
            positions += [a, b, c, d]
            uvs += [ta, tb, tc, td]
            let n = normalize(cross(b - a, d - a))
            normals += [n, n, n, n]
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }

        // The seabed itself.
        for r in 0..<(field.rows - 1) {
            for c in 0..<(field.columns - 1) {
                quad(at(r, c), at(r, c + 1), at(r + 1, c + 1), at(r + 1, c),
                     band(depth(r, c)), band(depth(r, c + 1)),
                     band(depth(r + 1, c + 1)), band(depth(r + 1, c)))
            }
        }

        // The four walls, each running from the surface down to the seabed.
        // The top of a wall is at depth zero and its foot at the node's own, so
        // the bands lie across it in layers.
        let top = band(0)
        func wall(_ a: (Int, Int), _ b: (Int, Int)) {
            let pa = plan(a.0, a.1), pb = plan(b.0, b.1)
            let surfaceA = SIMD3<Float>(pa.x, 0, pa.y)
            let surfaceB = SIMD3<Float>(pb.x, 0, pb.y)
            quad(surfaceA, surfaceB, at(b.0, b.1), at(a.0, a.1),
                 top, top, band(depth(b.0, b.1)), band(depth(a.0, a.1)))
        }
        let lastRow = field.rows - 1, lastCol = field.columns - 1
        for c in 0..<lastCol {
            wall((0, c), (0, c + 1))               // the far edge
            wall((lastRow, c + 1), (lastRow, c))   // the near edge
        }
        for r in 0..<lastRow {
            wall((r + 1, 0), (r, 0))               // the left edge
            wall((r, lastCol), (r + 1, lastCol))   // the right edge
        }

        var d = MeshDescriptor(name: "seabed")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        d.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [d])
    }
}

/// The chart's own depth shading, as a ramp a block can be painted with.
///
/// S-52 shades in bands and the mariner's safety contour decides where two of
/// them meet. These are the day palette's, so the block matches the paper above
/// it; a night chart keeps them, because the block is lit by the room and not
/// by the palette.
enum DepthBands {
    /// The depth each band reaches, shallow to deep. Land and anything that
    /// dries takes the first.
    static let bands: [(limit: Float, color: UIColor)] = [
        (0, UIColor(red: 0.78, green: 0.72, blue: 0.55, alpha: 1)),   // land and drying
        (2, UIColor(red: 0.55, green: 0.75, blue: 0.78, alpha: 1)),   // very shallow
        (5, UIColor(red: 0.67, green: 0.83, blue: 0.87, alpha: 1)),   // shallow
        (10, UIColor(red: 0.79, green: 0.90, blue: 0.93, alpha: 1)),  // safe water
        (.greatestFiniteMagnitude, UIColor(red: 0.88, green: 0.95, blue: 0.97, alpha: 1)),
    ]

    static func color(for depth: Float) -> UIColor {
        for band in bands where depth <= band.limit { return band.color }
        return bands[bands.count - 1].color
    }

    /// A column of pixels from the surface at the top to the deepest water at
    /// the bottom. A vertex samples it at its own depth, so a cut face shows
    /// the bands as the layers they are.
    static func ramp(deepest: Float, height: Int = 256) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: height * 4)
        for y in 0..<height {
            let d = deepest * Float(y) / Float(height - 1)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color(for: d).getRed(&r, green: &g, blue: &b, alpha: &a)
            let i = y * 4
            bytes[i] = UInt8(r * 255)
            bytes[i + 1] = UInt8(g * 255)
            bytes[i + 2] = UInt8(b * 255)
            bytes[i + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: 1, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}
