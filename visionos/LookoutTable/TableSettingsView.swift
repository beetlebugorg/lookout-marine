//
//  The settings window.
//
//  The sections are the Mac and iOS app's own: DisplaySections, DepthsSections,
//  SymbolsSections and AdvancedSections bind to MarinerSettings, and
//  PluginSections and PluginListSections draw whatever schema a plugin
//  declares. This file is only the shell that arranges them, so a control
//  added for the chartplotter appears here as well.
//
//  What is missing against the Mac is what this platform has not got: the
//  Charts section is the chart-set and raster-underlay UI, and the Plugins
//  section installs and uninstalls, which needs a plugin file to install from.
//  Charts are chosen on the table itself, with the Charts button.
//

import SwiftUI

struct TableSettingsView: View {
    let model: TableModel

    @StateObject private var mariner = MarinerSettings()
    @StateObject private var plugins = PluginSettings()
    @State private var tab = "display"

    var body: some View {
        // A tab per section, which visionOS shows as the bar beside the
        // window. It is the Mac's sidebar in this platform's own shape.
        TabView(selection: $tab) {
            ForEach(sections) { section in
                Form { body(of: section.id) }
                    .formStyle(.grouped)
                    .navigationTitle(section.label)
                    .tabItem { Label(section.label, systemImage: section.icon) }
                    .tag(section.id)
            }
        }
        .onAppear {
            mariner.bind(to: model.engine)
            plugins.bind(to: model.engine)
            // A connection's line moves on its own while the window is up.
            plugins.startPolling()
        }
        .onDisappear { plugins.stopPolling() }
    }

    /// What one section holds. The chart's own sections bind to the mariner
    /// state; every other is a tab some plugin declared, drawn from its
    /// schema by the same rows the other apps draw it with.
    @ViewBuilder
    private func body(of id: String) -> some View {
        switch id {
        case "display": DisplaySections(m: mariner)
        case "depths": DepthsSections(m: mariner)
        case "text": SymbolsSections(m: mariner)
        case "advanced": AdvancedSections(m: mariner)
        default:
            PluginListSections(p: plugins, tab: id)
            PluginSections(p: plugins, tab: id)
        }
    }

    /// The chartplotter's own list, less the two sections this platform has
    /// nothing behind, plus whichever tabs the loaded plugins filled.
    private var sections: [SettingsSection] {
        let filled = plugins.populatedTabs
        return SettingsSection.all.filter { s in
            if s.id == "charts" || s.id == "plugins" { return false }
            return s.core || filled.contains(s.id)
        }
    }
}
