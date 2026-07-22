//  HUDOverlay.swift — native, translucent readouts drawn OVER the chart.
//
//  Deliberately NOT drawn by lookout (that stays the chart surface). These are
//  small, self-sized badges placed with `.overlay(alignment:)` in ContentView so
//  they only capture hits on their own footprint — the rest of the chart stays
//  fully interactive. Platform-neutral.

import SwiftUI

/// Cursor lat/lon, 1:N scale, zoom, and color scheme — one row, centered at the
/// bottom of the chart. Non-interactive.
struct ReadoutsBadge: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text(coordString)
                .font(.system(.callout, design: .monospaced))
            HStack(spacing: 10) {
                Label(scaleString, systemImage: "ruler")
                Label(zoomString, systemImage: "plus.magnifyingglass")
                Label(model.schemeName, systemImage: "circle.lefthalf.filled")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }

    private var coordString: String {
        guard let lat = model.cursorLat, let lon = model.cursorLon else { return "—, —" }
        return model.useDMS
            ? "\(CoordFormat.dms(lat, isLat: true))  \(CoordFormat.dms(lon, isLat: false))"
            : String(format: "%.5f, %.5f", lat, lon)
    }

    private var scaleString: String {
        let n = model.scaleDenominator
        guard n > 0 else { return "1:—" }
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
