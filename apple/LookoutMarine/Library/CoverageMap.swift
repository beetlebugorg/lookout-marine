//  CoverageMap.swift: where the regions are.
//
//  The lower 48, with Alaska and Hawaii inset. One view cannot hold all three:
//  they span 128 degrees of longitude, and at that scale their latitude span is
//  taller than the sheet. An atlas prints them as insets for the same reason.
//
//  The core projects the coastline and the boxes through the same window, so a
//  panel draws the same on every frame.

import SwiftUI

struct CoverageMap: View {
    let regions: [NoaaRegion]
    let picked: Set<String>
    let enabled: Bool
    /// Each region's real coverage from the catalog. A region with none yet
    /// falls back to its rough extent.
    var coverage: [String: [GeoBox]] = [:]
    let toggle: (String) -> Void

    /// One panel: the ground it covers, and which regions are drawn on it.
    private struct Panel {
        let window: MapWindow
        let panel: Int32
        let label: String?
    }

    private static let main = Panel(
        window: MapWindow(west: -132, east: -64, south: 20, north: 52),
        panel: LOOKOUT_NOAA_PANEL_LOWER48, label: nil)

    private static let insets = [
        Panel(window: MapWindow(west: -172, east: -128, south: 50.5, north: 72),
              panel: LOOKOUT_NOAA_PANEL_ALASKA, label: "Alaska"),
        Panel(window: MapWindow(west: -161, east: -154, south: 18.3, north: 22.6),
              panel: LOOKOUT_NOAA_PANEL_HAWAII, label: "Hawaii"),
    ]

    /// S-52 very shallow water and land, so the picker sits in the app's own
    /// palette.
    private static let water = Chrome.s52("DEPMD").opacity(0.55)
    private static let land = Chrome.s52("LANDA").opacity(0.55)

    var body: some View {
        #if os(macOS)
        // Room for the insets to sit in the Pacific without reaching the
        // coast, at the width the sheet gives the map.
        lower48.overlay(alignment: .bottomLeading) { corners.padding(8) }
        #else
        // Under the map rather than on it. On a screen this narrow the Alaska
        // frame reached the west coast, and a region cannot be picked through
        // the frame of another one.
        VStack(alignment: .leading, spacing: 8) {
            lower48
            corners
        }
        #endif
    }

    private var lower48: some View {
        panel(Self.main)
            .aspectRatio(Self.main.window.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Chrome.edge.opacity(0.6), lineWidth: 1))
    }

    private var corners: some View {
        HStack(alignment: .bottom, spacing: 8) {
            inset(Self.insets[0], width: cornerWidth)
            inset(Self.insets[1], width: cornerWidth * 0.54)
        }
    }

    #if os(macOS)
    private var cornerWidth: CGFloat { 134 }
    #else
    /// Smaller than the Mac's. These sit under the map on a phone rather than
    /// in a corner of it, so every point they are tall is a point the regions
    /// below them lose.
    private var cornerWidth: CGFloat { 100 }
    #endif

    /// Alaska and Hawaii keep their own frames, so each reads as itself rather
    /// than as something floating off the coast of Oregon.
    private func inset(_ p: Panel, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label = p.label {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Chrome.muted)
            }
            panel(p)
                .frame(width: width, height: width / p.window.aspect)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Chrome.edge.opacity(0.7), lineWidth: 1))
        }
    }

    private func panel(_ p: Panel) -> some View {
        GeometryReader { geo in
            ZStack {
                Self.water
                p.window.coast(LOOKOUT_COAST_LAND, in: geo.size).fill(Self.land)
                p.window.coast(LOOKOUT_COAST_LAKE, in: geo.size).fill(Self.water)
                ForEach(regions.filter { $0.panel == p.panel }) { r in
                    box(r, p, in: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Chrome.panel)
    }

    private func box(_ r: NoaaRegion, _ p: Panel, in size: CGSize) -> some View {
        let on = picked.contains(r.id)
        let shape = RegionShape(boxes: boxes(r), window: p.window)
        // The gesture goes on the shape, so a tap lands on the region's own
        // water rather than on a rectangle around it.
        // Filled, with no stroke. Outlining the path draws every cell box in
        // it, which reads as a mesh over the coast rather than one region.
        return shape
            .fill(Chrome.accent.opacity(on ? 0.5 : 0.16))
            .contentShape(shape)
            .onTapGesture { if enabled { toggle(r.id) } }
    }

    /// The catalog's boxes for a region, or its rough extent until the catalog
    /// is in.
    private func boxes(_ r: NoaaRegion) -> [GeoBox] {
        if let c = coverage[r.id], !c.isEmpty { return c }
        return [GeoBox(west: r.west, south: r.south, east: r.east, north: r.north)]
    }
}


/// A lon/lat window, and the flat rectangle it draws into, in Mercator. The
/// core projects every point.
struct MapWindow {
    let west, east, south, north: Double

    /// Width over height for this window.
    var aspect: CGFloat { CGFloat(lookout_map_aspect(west, east, south, north)) }

    /// Longitude and latitude pairs as points in a rectangle of `size`.
    func points(_ lonlat: [Double], in size: CGSize) -> [CGPoint] {
        let n = lonlat.count / 2
        var xy = [Float](repeating: 0, count: n * 2)
        lookout_map_project(west, east, south, north,
                            Double(size.width), Double(size.height), lonlat, &xy, n)
        return (0..<n).map { CGPoint(x: CGFloat(xy[$0 * 2]), y: CGFloat(xy[$0 * 2 + 1])) }
    }

    /// The coastline rings of one level that reach into this window, as one
    /// path.
    func coast(_ level: Int32, in size: CGSize) -> Path {
        let w = Double(size.width), h = Double(size.height)
        let n = lookout_coastline_rings(level, west, east, south, north, w, h, nil, 0, nil, 0)
        var xy = [Float](repeating: 0, count: n * 2)
        var ends = [UInt32](repeating: 0, count: n / 4)
        lookout_coastline_rings(level, west, east, south, north, w, h, &xy, n, &ends, ends.count)
        func pt(_ i: Int) -> CGPoint { CGPoint(x: CGFloat(xy[i * 2]), y: CGFloat(xy[i * 2 + 1])) }
        var path = Path()
        var start = 0
        for end in ends.map(Int.init) where start < n {
            path.move(to: pt(start))
            for i in start + 1 ..< end { path.addLine(to: pt(i)) }
            path.closeSubpath()
            start = end
        }
        return path
    }
}
