//  CoverageMap.swift: where the regions are.
//
//  The lower 48, with Alaska and Hawaii inset. One view cannot hold all three:
//  they span 128 degrees of longitude, and at that scale their latitude span is
//  taller than the sheet. An atlas prints them as insets for the same reason.
//
//  The coastline is drawn from Coastline.bin and the boxes project through the
//  same window, so a panel draws the same on every frame.

import SwiftUI

struct CoverageMap: View {
    let regions: [NoaaRegion]
    let picked: Set<String>
    let enabled: Bool
    let toggle: (String) -> Void

    /// One panel: the ground it covers, and the regions drawn on it.
    private struct Panel {
        let window: MapWindow
        let ids: [String]
        let label: String?
    }

    private static let main = Panel(
        window: MapWindow(west: -127, east: -64, south: 22, north: 52),
        ids: ["d1", "d5", "d7", "d8", "d9", "d11", "d13"], label: nil)

    private static let insets = [
        Panel(window: MapWindow(west: -172, east: -128, south: 50.5, north: 72),
              ids: ["d17"], label: "Alaska"),
        Panel(window: MapWindow(west: -161, east: -154, south: 18.3, north: 22.6),
              ids: ["d14"], label: "Hawaii"),
    ]

    /// S-52 shallow blue and GSHHG land, so the picker sits in the app's own
    /// palette.
    private static let water = Color(red: 0.68, green: 0.84, blue: 1.0).opacity(0.55)
    private static let land = Color(red: 0.64, green: 0.59, blue: 0.33).opacity(0.55)

    var body: some View {
        panel(Self.main)
            .aspectRatio(Self.main.window.aspect, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 8) {
                    inset(Self.insets[0], width: 134)
                    inset(Self.insets[1], width: 72)
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Chrome.edge.opacity(0.6), lineWidth: 1))
    }

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
                shapes(p, level: 1, in: geo.size).fill(Self.land)
                shapes(p, level: 2, in: geo.size).fill(Self.water)
                ForEach(regions.filter { p.ids.contains($0.id) }) { r in
                    box(r, p, in: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Chrome.panel)
    }

    /// Every ring of one GSHHG level that reaches into this window, as one
    /// path. GSHHG winds land and lakes opposite ways, so filling them
    /// together under the non-zero rule gives water inside a lake and land
    /// outside it.
    private func shapes(_ p: Panel, level: UInt8, in size: CGSize) -> Path {
        var path = Path()
        for ring in Coastline.rings where ring.level == level {
            guard touches(ring, p) else { continue }
            var first = true
            for v in ring.points {
                let pt = p.window.point(lon: Double(v.x), lat: Double(v.y), in: size)
                if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
            }
            path.closeSubpath()
        }
        return path
    }

    /// True when the ring's own extent reaches into the window.
    ///
    /// A ring spanning more than 180 degrees of longitude is one that crosses
    /// the antimeridian, such as an Aleutian island with points at +172 and
    /// -179. Drawn straight through it spans the width of the map as a band.
    private func touches(_ ring: Coastline.Ring, _ p: Panel) -> Bool {
        var w = 180.0, e = -180.0, s = 90.0, n = -90.0
        for v in ring.points {
            w = min(w, Double(v.x)); e = max(e, Double(v.x))
            s = min(s, Double(v.y)); n = max(n, Double(v.y))
        }
        if e - w > 180 { return false }
        return p.window.intersects(west: w, east: e, south: s, north: n)
    }

    private func box(_ r: NoaaRegion, _ p: Panel, in size: CGSize) -> some View {
        let on = picked.contains(r.id)
        let a = p.window.point(lon: r.west, lat: r.north, in: size)
        let b = p.window.point(lon: r.east, lat: r.south, in: size)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        // The gesture goes on before position(). A view that has been
        // positioned fills its parent, so a contentShape applied after it
        // claims the whole panel and the last box drawn gets every tap.
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Chrome.accent.opacity(on ? 0.45 : 0.14))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(on ? Chrome.accent : Chrome.accent.opacity(0.65),
                              lineWidth: on ? 2 : 1.2))
            .frame(width: max(rect.width, 8), height: max(rect.height, 8))
            .contentShape(Rectangle())
            .onTapGesture { if enabled { toggle(r.id) } }
            .position(x: rect.midX, y: rect.midY)
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
