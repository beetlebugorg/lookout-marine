//  ZoomControls.swift — the + and − bubbles.
//
//  OverlayLayer puts them above the charts and settings row, at the bottom
//  right. North-up is now the north bubble at the top right.

import SwiftUI

struct ZoomControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: Chrome.gap) {
            ChromeBubble(system: "plus", help: "Zoom in", enabled: model.hasChart) {
                model.zoomIn()
            }
            .chromeHitRegion("zoom-in")
            ChromeBubble(system: "minus", help: "Zoom out", enabled: model.hasChart) {
                model.zoomOut()
            }
            .chromeHitRegion("zoom-out")
        }
    }
}
