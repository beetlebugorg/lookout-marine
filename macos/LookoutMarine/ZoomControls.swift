//  ZoomControls.swift — floating +/−/fit/north buttons (bottom-right, maps-app
//  style). Self-sized so `.overlay(alignment: .bottomTrailing)` only captures
//  hits on the buttons. Zoom is eased by the engine, so a click glides.

import SwiftUI

struct ZoomControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                button("plus", "Zoom in") { model.zoomIn() }
                Divider().frame(width: 30)
                button("minus", "Zoom out") { model.zoomOut() }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator))

            // (Zoom-to-fit lives in the toolbar and View menu (⌘0) — no floating
            // button; it read as a second full-screen control.)
            if abs(model.rotationDeg) >= 0.5 {
                button("location.north.line", "North-up") { model.northUp() }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator))
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        .disabled(!model.hasChart)
        .opacity(model.hasChart ? 1 : 0.4)
    }

    private func button(_ system: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
