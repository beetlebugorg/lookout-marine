//  PositionReadout.swift — own ship's position, and whether to believe it.
//
//  It shows own ship and nothing else. It does not follow the map centre and it
//  does not change meaning when the mariner pans away, because panning away is
//  exactly when a mistaken value is dangerous. With no fix it shows NO NUMBERS:
//  a coordinate with no boat behind it is the ambiguity this removes.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif


/// OWN SHIP's position, and a pill saying whether to believe it.
///
/// The readout carries own ship and nothing else. It does not follow the map
/// centre and it does not switch meaning when the mariner pans away, because
/// panning away is exactly when a mistaken value is dangerous. Where there
/// is no fix it shows NO NUMBERS: a coordinate with no boat behind it is the
/// ambiguity this removes. The coordinates of a PLACE come from the chart
/// menu, on demand, at the point the mariner asked about.
///
/// The pill differs by more than its text, so it reads at a glance in bad
/// light: the colour changes, the glyph changes, the fill goes from solid to
/// outlined, and the third state is a BUTTON rather than a label. That state
/// is the one place the app tells a mariner they have no position, so it
/// carries the fix.
struct PositionReadout: View {
    var model: AppModel
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            switch model.readouts.fixState {
            case .live:
                pill("GPS", system: "location.fill", tint: Chrome.accent, solid: true)
                Text(coordString)
                    .font(.system(size: compact ? 12 : 14).monospacedDigit())
                    .foregroundStyle(Chrome.ink)
            case .lost:
                pill("NO GPS", system: "location.slash", tint: Chrome.overscale, solid: false)
            case .none:
                Button(action: model.configurePosition) {
                    pill("Configure GPS", system: "gearshape.fill",
                         tint: Chrome.accent, solid: false)
                }
                .buttonStyle(ChromeFlatStyle(cornerRadius: 8))
                .help("No source of position. Add a gateway or a Signal K server.")
                .accessibilityLabel("Configure GPS. No source of position; add a gateway or a Signal K server.")
                .accessibilityIdentifier("configure-gps")
                .chromeHitRegion("position-pill")
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityValue(stateName)
    }

    /// A solid pill reads as a state that is good and settled; an outlined one
    /// as a state waiting on the mariner. Both carry their own glyph.
    private func pill(_ text: String, system: String, tint: Color, solid: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(spacing: 5) {
            Image(systemName: system).font(.system(size: 9, weight: .bold))
            Text(text)
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(solid ? Color.white : tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(solid ? tint : tint.opacity(0.16), in: shape)
        .overlay(shape.strokeBorder(solid ? .clear : tint.opacity(0.55), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var coordString: String {
        CoordFormat.ownShip(lat: model.readouts.shipLat, lon: model.readouts.shipLon)
    }

    /// The state as one stable word, for assistive technology and the UI
    /// tests. The help text reads well and changes freely; this does not.
    private var stateName: String {
        switch model.readouts.fixState {
        case .live: return "own ship"
        case .lost: return "no fix"
        case .none: return "no source"
        }
    }
}
