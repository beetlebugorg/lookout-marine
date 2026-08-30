//  TextSection.swift — feature names, light descriptions, and the symbols.

import SwiftUI


// MARK: - Text & Symbols

struct SymbolsSections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section("Text") {
            Toggle("Feature names", isOn: $m.textNames)
            Toggle("Light descriptions", isOn: $m.showLightDescriptions)
            Toggle("Other text", isOn: $m.textOther)
        }
        Section("Symbols") {
            Toggle("Simplified point symbols", isOn: $m.simplifiedPoints)
            SegmentedRow("Boundaries", selection: $m.boundaryStyle) {
                ForEach(MarinerBoundaryStyle.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Full light-sector lines", isOn: $m.showFullSectorLines)
        }
    }
}
