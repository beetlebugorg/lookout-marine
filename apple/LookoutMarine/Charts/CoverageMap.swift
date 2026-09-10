//  CoverageMap.swift: where the regions are.
//
//  A small equirectangular map of the United States with a box per region.
//  It shows where a name is, so a mariner who knows the water but not NOAA's
//  district numbers can pick by looking. The coastline is a coarse outline
//  (USOutline.swift) and the boxes are rough extents. The catalog decides
//  which cells download.

import CoreGraphics
import SwiftUI

/// The pictures the picker draws: the lower 48, with Alaska and Hawaii inset.
struct CoverageBasemaps {
    var main: ChartSnapshot?
    var alaska: ChartSnapshot?
    var hawaii: ChartSnapshot?
}

struct CoverageMap: View {
    let regions: [NoaaRegion]
    let picked: Set<String>
    let enabled: Bool
    /// The app's own basemap. A missing main picture draws the coarse outline
    /// in USOutline.swift instead.
    var basemaps = CoverageBasemaps()
    let toggle: (String) -> Void

    /// The window the fallback outline draws.
    private static let fallback = ChartSnapshot(image: nil, north: 51, west: -140,
                                                south: 17.5, east: -64)

    private static let mainIDs = ["d1", "d5", "d7", "d8", "d9", "d11", "d13"]

    var body: some View {
        panel(basemaps.main ?? Self.fallback, ids: Self.mainIDs,
              outlineWhenBlank: basemaps.main == nil)
            .aspectRatio(shape, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 8) {
                    inset(basemaps.alaska, ids: ["d17"], label: "Alaska", width: 132)
                    inset(basemaps.hawaii, ids: ["d14"], label: "Hawaii", width: 76)
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Chrome.edge.opacity(0.6), lineWidth: 1))
    }

    private var shape: CGFloat {
        guard let m = basemaps.main, let image = m.image else {
            let mid = (Self.fallback.south + Self.fallback.north) / 2 * .pi / 180
            return CGFloat((Self.fallback.east - Self.fallback.west) * cos(mid)
                           / (Self.fallback.north - Self.fallback.south))
        }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    /// Alaska and Hawaii keep their own frames, so each reads as itself rather
    /// than as something floating off the coast of Oregon.
    @ViewBuilder
    private func inset(_ shot: ChartSnapshot?, ids: [String],
                       label: String, width: CGFloat) -> some View {
        if let shot, let image = shot.image {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Chrome.muted)
                panel(shot, ids: ids, outlineWhenBlank: false)
                    .frame(width: width,
                           height: width * CGFloat(image.height) / CGFloat(image.width))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Chrome.edge.opacity(0.7), lineWidth: 1))
            }
        }
    }

    private func panel(_ shot: ChartSnapshot, ids: [String],
                       outlineWhenBlank: Bool) -> some View {
        GeometryReader { geo in
            ZStack {
                if let image = shot.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(red: 0.68, green: 0.84, blue: 1.0).opacity(0.55)
                    if outlineWhenBlank { outline(shot, in: geo.size) }
                }
                ForEach(regions.filter { ids.contains($0.id) }) { r in
                    box(r, shot, in: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Chrome.panel)
    }

    private func outline(_ shot: ChartSnapshot, in size: CGSize) -> some View {
        Path { path in
            for ring in USOutline.rings {
                guard let first = ring.first else { continue }
                path.move(to: point(Double(first.x), Double(first.y), shot, size))
                for v in ring.dropFirst() {
                    path.addLine(to: point(Double(v.x), Double(v.y), shot, size))
                }
                path.closeSubpath()
            }
        }
        .fill(Color(red: 0.64, green: 0.59, blue: 0.33).opacity(0.55))
    }

    private func box(_ r: NoaaRegion, _ shot: ChartSnapshot, in size: CGSize) -> some View {
        let on = picked.contains(r.id)
        let a = point(r.west, r.north, shot, size)
        let b = point(r.east, r.south, shot, size)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        // The gesture goes on before position(). A view that has been
        // positioned fills its parent, so a contentShape applied after it
        // claims the whole panel and the last box drawn gets every tap.
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Chrome.accent.opacity(on ? 0.42 : 0.10))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(on ? Chrome.accent : Chrome.ink.opacity(0.45),
                              lineWidth: on ? 1.8 : 1))
            .frame(width: max(rect.width, 8), height: max(rect.height, 8))
            .contentShape(Rectangle())
            .onTapGesture { if enabled { toggle(r.id) } }
            .position(x: rect.midX, y: rect.midY)
    }

    /// A lon/lat in one panel, from the corners recorded with its picture.
    /// Reading the live camera instead moves the boxes off a frozen picture as
    /// soon as the chart is touched.
    private func point(_ lon: Double, _ lat: Double,
                       _ shot: ChartSnapshot, _ size: CGSize) -> CGPoint {
        var span = shot.east - shot.west
        if span <= 0 { span += 360 }
        var dx = lon - shot.west
        if dx < 0 { dx += 360 }

        // Latitude is linear in mercator. The chart draws mercator.
        let top = Self.mercator(shot.north), bottom = Self.mercator(shot.south)
        let height = top - bottom
        let dy = height == 0 ? 0 : (top - Self.mercator(lat)) / height

        return CGPoint(x: dx / span * size.width, y: dy * size.height)
    }

    /// Mercator y for a latitude, clamped clear of the poles.
    private static func mercator(_ lat: Double) -> Double {
        let phi = max(-85.05, min(85.05, lat)) * .pi / 180
        return log(tan(.pi / 4 + phi / 2))
    }
}


/// The regions as pills under the map: the name, and the mark for a chosen one.
struct NoaaRegionPills: View {
    let regions: [NoaaRegion]
    let picked: Set<String>
    let enabled: Bool
    let toggle: (String) -> Void

    var body: some View {
        FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(regions) { r in
                pill(r)
            }
        }
    }

    private func pill(_ r: NoaaRegion) -> some View {
        let on = picked.contains(r.id)
        return Button { toggle(r.id) } label: {
            HStack(spacing: 6) {
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(r.name)
                    .font(.system(size: 12.5, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Color.white : Chrome.ink)
            .padding(.horizontal, 13)
            .frame(height: pillHeight)
            .background(on ? Chrome.accent : Chrome.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? .clear : Chrome.edge.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(r.blurb)
        .accessibilityLabel("\(r.name). \(r.blurb)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("region-\(r.id)")
    }

    #if os(macOS)
    private var pillHeight: CGFloat { 30 }
    #else
    // A thumb needs the full target.
    private var pillHeight: CGFloat { 44 }
    #endif
}
