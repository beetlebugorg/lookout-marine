//  HUDOverlay.swift — native, translucent readouts drawn OVER the chart.
//
//  Deliberately NOT drawn by lookout (that stays the chart surface). These are
//  small, self-sized badges placed with `.overlay(alignment:)` in ContentView so
//  they only capture hits on their own footprint — the rest of the chart stays
//  fully interactive. Platform-neutral.

import SwiftUI

/// Lat/lon (cursor when hovering, else the view centre), 1:N scale, zoom,
/// scheme, and — when zoomed past the data — an amber OVERSCALE badge. One
/// row, pinned at the bottom of the chart. Non-interactive.
struct ReadoutsBadge: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.cursorLat != nil ? "cursorarrow" : "location")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(coordString)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .fixedSize()
            if model.overscale > 1.05 {
                Text(String(format: "×%.1f", model.overscale))
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.25), in: Capsule())
                    .foregroundStyle(.orange)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Label(scaleString, systemImage: "ruler")
                Label(zoomString, systemImage: "plus.magnifyingglass")
                #if os(macOS)
                Label(model.schemeName, systemImage: "circle.lefthalf.filled")
                #endif
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        // A full-width BAR (not a floating capsule): the material extends
        // through the bottom safe area so the chart never peeks under it.
        .background { Rectangle().fill(.regularMaterial).ignoresSafeArea(edges: [.bottom, .horizontal]) }
        .overlay(alignment: .top) { Divider().opacity(0.5) }
        .allowsHitTesting(false)
    }

    private var coordString: String {
        let lat = model.cursorLat ?? model.centerLat
        let lon = model.cursorLon ?? model.centerLon
        #if os(iOS)
        if !model.useDMS { return String(format: "%.4f, %.4f", lat, lon) }
        #endif
        return model.useDMS
            ? "\(CoordFormat.dms(lat, isLat: true))  \(CoordFormat.dms(lon, isLat: false))"
            : String(format: "%.5f, %.5f", lat, lon)
    }

    /// Compact 1:N — "1:24k" / "1:2.1M": the HUD is a glance, not a survey.
    private var scaleString: String {
        let n = model.scaleDenominator
        guard n > 0 else { return "1:—" }
        if n >= 1_000_000 { return String(format: "1:%.1fM", n / 1_000_000) }
        if n >= 10_000 { return String(format: "1:%.0fk", n / 1_000) }
        return "1:\(Int(n.rounded()).formatted())"
    }

    private var zoomString: String {
        String(format: "z%.1f", model.zoomLevel)
    }
}

/// A compass rose that rotates with the view and resets to north when tapped.
struct CompassBadge: View {
    let rotationDeg: Double
    let onReset: () -> Void

    var body: some View {
        Button(action: onReset) {
            ZStack {
                Circle().fill(.regularMaterial)
                Circle().stroke(.separator)
                Image(systemName: "location.north.fill")
                    .foregroundStyle(.red)
                    .rotationEffect(.degrees(-rotationDeg))
                Text("N")
                    .font(.system(size: 9, weight: .bold))
                    .offset(y: -13)
                    .rotationEffect(.degrees(-rotationDeg))
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .help("Reset to north-up")
    }
}

/// One line per feature under the last tap: object class + source cell.
struct IdentifyPanel: View {
    let results: [PickFeature]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Identify").font(.caption.bold())
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { f in
                HStack(spacing: 6) {
                    Text(f.cls).font(.system(.caption, design: .monospaced).bold())
                        .accessibilityIdentifier("identify-cls")
                    Text(f.chart).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Lat/lon degrees-minutes formatting for the HUD.
enum CoordFormat {
    static func dms(_ value: Double, isLat: Bool) -> String {
        let hemi = isLat ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W")
        let a = abs(value)
        let deg = Int(a)
        let minutes = (a - Double(deg)) * 60
        return String(format: "%d°%05.2f'%@", deg, minutes, hemi)
    }
}
