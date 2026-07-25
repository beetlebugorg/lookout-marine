//  ZoomControls.swift — floating circular +/− (and north-up) bubbles,
//  chartplotter-style: each control is its own circle, stacked bottom-right,
//  kept clear of the bottom HUD by OverlayLayer's padding.

import SwiftUI

struct ZoomControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            bubble("plus", "Zoom in") { model.zoomIn() }
            bubble("minus", "Zoom out") { model.zoomOut() }
            if abs(model.rotationDeg) >= 0.5 {
                bubble("location.north.line", "North-up") { model.northUp() }
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        .disabled(!model.hasChart)
        .opacity(model.hasChart ? 1 : 0.4)
    }

    private func bubble(_ system: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(.hairline.opacity(0.5)))
        .help(help)
    }
}
