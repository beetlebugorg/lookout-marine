//
//  Lookout Table: the chart as a sheet of paper on a real table.
//
//  The app is one volume. A volume is placed in the room by the person wearing
//  the headset, it holds its size and position between launches, and it snaps
//  to a horizontal surface, which is where a chart table belongs.
//

import RealityKit
import SwiftUI

@main
struct LookoutTableApp: App {
    init() {
        // The components the sheet and its traffic tag entities with. A
        // component must be registered before any entity carries it.
        ChartFaceTag.registerComponent()
        SheetBorderTag.registerComponent()
        TargetPositionComponent.registerComponent()
    }

    /// One chart, shared by the table and the settings window that edits it.
    @State private var model = TableModel()

    var body: some SwiftUI.Scene {
        WindowGroup(id: "chart-table") {
            ChartTableView(model: model)
        }
        .windowStyle(.volumetric)
        // A sheet a meter across with room above it for the traffic and the
        // flags. Depth follows the sheet's own proportions.
        .defaultSize(width: 1.0, height: 0.45, depth: 0.72, in: .meters)
        // Gravity aligned: the sheet lies flat however the volume is turned,
        // and the flags above it stand up.
        .volumeWorldAlignment(.gravityAligned)

        // A plain window beside the table, because a form is a flat thing and
        // reaching into the volume to read one would put a hand over the
        // chart.
        WindowGroup(id: LookoutTableApp.settingsWindow) {
            TableSettingsView(model: model)
        }
        .windowStyle(.plain)
        .defaultSize(width: 900, height: 700)
    }

    static let settingsWindow = "settings"
}
