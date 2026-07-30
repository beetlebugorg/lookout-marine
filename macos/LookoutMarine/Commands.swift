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

        // File → Open Chart… / Open Recent
        CommandGroup(replacing: .newItem) {
            Button("Open Chart…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                if model.recents.isEmpty {
                    Text("No Recent Charts").foregroundStyle(.secondary)
                } else {
                    ForEach(model.recents, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) { model.openChart(path) }
                    }
                }
            }
            .disabled(model.recents.isEmpty)
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
