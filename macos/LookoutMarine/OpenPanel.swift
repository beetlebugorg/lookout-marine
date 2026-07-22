//  OpenPanel.swift — the macOS "Open Chart…" file picker.
//
//  Shared by the File menu and the empty-state button so there's one code path.
//  We deliberately DON'T restrict allowedContentTypes to a dynamic .pmtiles UTI —
//  that greys out the user's charts if the type isn't registered. Instead we
//  accept any file or folder and let the engine validate.

#if os(macOS)
import AppKit

extension AppModel {
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
