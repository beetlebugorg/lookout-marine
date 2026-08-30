//  Commands.swift — the native macOS menu bar (SwiftUI Commands).
//
//  macOS-only chrome. The ACTIONS all funnel through AppModel, which is shared
//  with iOS — so on iOS the same commands can be surfaced as toolbar buttons
//  without duplicating logic. Settings (⌘,) is provided by the Settings scene.

#if os(macOS)
import SwiftUI
import AppKit

struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        // The app's own About panel, which the AppKit standard one replaces.
        // It carries the button to the licenses; the standard panel takes no
        // button, and a legal obligation has to be reachable from here.
        CommandGroup(replacing: .appInfo) {
            Button("About Lookout Marine") { AboutWindowController.shared.show() }
            Button("Licenses…") { LicensesWindowController.shared.show() }
        }

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
                if model.charts.sets.isEmpty {
                    Text("No charts").foregroundStyle(.secondary)
                } else {
                    ForEach(model.charts.sets) { set in
                        Toggle(set.title, isOn: Binding(
                            get: { set.on },
                            set: { model.charts.setChartSetOn(set.path, $0) }
                        ))
                    }
                }
            }
            .disabled(model.charts.sets.isEmpty)
        }

        // Vessels: the shell's menu, holding the tables the plugins declare.
        // The menu is the shell's because the menu bar is: a plugin describes
        // a table and where it belongs, and the shell decides what the bar
        // looks like. Every declaration lands here, whatever its `menu` names,
        // until there is a second place to put one.
        CommandMenu("Vessels") {
            if model.plugins.tables.isEmpty {
                Text("No Vessel Tables").foregroundStyle(.secondary)
            } else {
                ForEach(model.plugins.tables) { spec in
                    Button("\(spec.title)…") { PluginTableWindowController.show(spec, model: model) }
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
                ForEach(model.raster.sets.filter(\.inView)) { set in
                    Button {
                        model.raster.select(set.id)
                    } label: {
                        if set.id == model.raster.active {
                            Label(set.name, systemImage: "checkmark")
                        } else {
                            Text(set.name)
                        }
                    }
                }
                if model.raster.sets.contains(where: \.inView) { Divider() }
                Button {
                    model.raster.select(-1)
                } label: {
                    if model.raster.active < 0 {
                        Label("None", systemImage: "checkmark")
                    } else {
                        Text("None")
                    }
                }
            }
            .disabled(model.raster.paths.isEmpty)
            Button("Next Raster Chart") { model.cycleRaster() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.raster.paths.isEmpty)
            Button("Add Raster Charts…") { model.presentRasterPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button(model.raster.chartHidden ? "Show ENC Over Raster" : "Hide ENC Over Raster") { model.raster.toggleChart() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .help("Hide the ENC where a raster chart covers it.")
            if !model.raster.paths.isEmpty {
                Button("Forget Raster Charts (\(model.raster.paths.count))") { model.raster.clear() }
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
