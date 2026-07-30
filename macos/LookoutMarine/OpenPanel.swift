//  OpenPanel.swift — the "Open Chart…" file pickers.
//
//  macOS: an NSOpenPanel shared by the File menu and the empty-state button so
//  there's one code path. We deliberately DON'T restrict allowedContentTypes to
//  a dynamic .pmtiles UTI — that greys out the user's charts if the type isn't
//  registered. Instead we accept any file or folder and let the engine validate.
//
//  iOS: the SwiftUI fileImporter (presented by ChartView) hands its picked URL
//  to openImported below.

#if os(macOS)
import AppKit

extension AppModel {
    /// Open the mariner form. The gear bubble and ⌘, both come here.
    func openSettings() { SettingsWindowController.shared.show(model: self) }

    /// Present the Open panel; open the chosen `.pmtiles` file or a folder of cells.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true      // a folder composes a chart library
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.title = "Open Chart"
        panel.message = "Choose a baked .pmtiles chart, or a folder of cells."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { openChartDirectory(url.path) } else { openChart(url.path) }
    }
}
#endif

#if os(iOS)
import Foundation

extension AppModel {
    /// Open the mariner form. On iOS it is a sheet, so the flag is enough.
    func openSettings() { showSettings = true }

    /// Import a picked chart (or folder of cells) into the app container, then
    /// open the copy. Copying sidesteps security-scope lifetime: the engine
    /// mmaps the cells for as long as the chart stays open, but the picker's
    /// scoped access ends the moment the URL is released.
    func openImported(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let chartsDir = docs.appendingPathComponent("Charts", isDirectory: true)
        let dest = chartsDir.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.createDirectory(at: chartsDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
        } catch {
            openError = "Couldn't import the chart:\n\(error.localizedDescription)"
            return
        }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: dest.path, isDirectory: &isDir)
        if isDir.boolValue { openChartDirectory(dest.path) } else { openChart(dest.path) }
    }
}
#endif
