//  Commands.swift — the native macOS menu bar (SwiftUI Commands).
//
//  macOS-only chrome. The ACTIONS all funnel through AppModel, which is shared
//  with iOS — so on iOS the same commands can be surfaced as toolbar buttons
//  without duplicating logic. Settings (⌘,) is provided by the Settings scene.

#if os(macOS)
import SwiftUI
import AppKit

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        // The app owns the settings window (SettingsWindowController), so ⌘,
        // takes the same route as the gear bubble.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }

        // File → Open Chart… / Charts. The menu switches a set on and off
        // rather than reopening it: the charts are already there, and the only
        // question left is whether they are drawn.
        CommandGroup(replacing: .newItem) {
            Button("Open Chart…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Charts") {
                if model.chartSets.isEmpty {
                    Text("No charts").foregroundStyle(.secondary)
                } else {
                    ForEach(model.chartSets) { set in
                        Toggle(set.title, isOn: Binding(
                            get: { set.on },
                            set: { model.setChartSetOn(set.path, $0) }
                        ))
                    }
                }
            }
            .disabled(model.chartSets.isEmpty)
        }

        // Vessels: the shell's menu, holding the tables the plugins declare.
        // The menu is the shell's because the menu bar is: a plugin describes
        // a table and where it belongs, and the shell decides what the bar
        // looks like. Every declaration lands here, whatever its `menu` names,
        // until there is a second place to put one.
        CommandMenu("Vessels") {
            if model.pluginTables.isEmpty {
                Text("No Vessel Tables").foregroundStyle(.secondary)
            } else {
                ForEach(model.pluginTables) { spec in
                    Button("\(spec.title)…") { model.showPluginTable(spec) }
                }
            }
        }

        // Chart menu (a separate top-level menu; SwiftUI already provides "View").
        CommandMenu("Chart") {
            Menu("Color Scheme") {
                Button("Day")   { model.setScheme(0) }
                Button("Dusk")  { model.setScheme(1) }
                Button("Night") { model.setScheme(2) }
                Divider()
                Button("Cycle") { model.cycleScheme() }.keyboardShortcut("l", modifiers: .command)
            }
            // The same list the HUD pill opens: every set that covers the
            // view, marked with the one being drawn.
            Menu("Raster Chart") {
                ForEach(model.rasterSets.filter(\.inView)) { set in
                    Button {
                        model.selectRasterSet(set.id)
                    } label: {
                        if set.id == model.rasterActive {
                            Label(set.name, systemImage: "checkmark")
                        } else {
                            Text(set.name)
                        }
                    }
                }
                if model.rasterSets.contains(where: \.inView) { Divider() }
                Button {
                    model.selectRasterSet(-1)
                } label: {
                    if model.rasterActive < 0 {
                        Label("None", systemImage: "checkmark")
                    } else {
                        Text("None")
                    }
                }
            }
            .disabled(model.rasterPaths.isEmpty)
            Button("Next Raster Chart") { model.cycleRaster() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.rasterPaths.isEmpty)
            Button("Add Raster Charts…") { model.presentRasterPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button(model.chartHidden ? "Show ENC Over Raster" : "Hide ENC Over Raster") { model.toggleChart() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .help("Hide the ENC where a raster chart covers it.")
            if !model.rasterPaths.isEmpty {
                Button("Forget Raster Charts (\(model.rasterPaths.count))") { model.clearRasterCharts() }
                    .help("Takes effect the next time a chart is opened.")
            }
            Divider()
            Button("Zoom In")      { model.zoomIn() }.keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out")     { model.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("Zoom to Fit")  { model.zoomToFit() }.keyboardShortcut("0", modifiers: .command)
            Button("Rotate to North-Up") { model.northUp() }.keyboardShortcut(.upArrow, modifiers: .command)
            Divider()
            Button("Toggle Text")           { model.toggleText() }.keyboardShortcut("t", modifiers: .command)
            Button("Toggle Soundings")      { model.toggleSoundings() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Toggle Other Category") { model.toggleOtherCategory() }.keyboardShortcut("d", modifiers: .command)
        }
    }
}
#endif
