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
    ///
    /// A plugin may read files too — a weather file, say — and the panel says so
    /// in its message rather than in allowedContentTypes, for the reason above:
    /// naming types at all greys out the mariner's charts. What the mariner
    /// chose goes to openFileOrChart, which lets the core decide.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true      // a folder composes a chart library
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.title = "Open Chart"
        let types = pluginFileTypes()
        panel.message = types.isEmpty
            ? "Choose a baked .pmtiles chart, or a folder of cells."
            : "Choose a baked .pmtiles chart, a folder of cells, or a data file: \(types.joined(separator: ", "))."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { openChartDirectory(url.path) } else { openFileOrChart(url.path) }
    }

    /// Present the Add Raster Charts panel. Multiple selection and folders both, because
    /// the way this material actually ships is several files at once: the same
    /// water from ArcGIS, Bing and Google side by side, or a folder of adjacent
    /// regions from one provider.
    ///
    /// No content-type restriction, for the same reason as the chart panel — a
    /// `.mbtiles` UTI is not registered on anyone's Mac, and greying out the
    /// mariner's own downloads would be worse than letting the engine say no.
    func presentRasterPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.title = "Add Raster Charts"
        panel.message = "Choose raster charts (.mbtiles) - satellite imagery or another vendor's chart - or a folder of them."
        guard panel.runModal() == .OK else { return }

        var picked: [String] = []
        for url in panel.urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                picked.append(contentsOf: rasterPathsIn(url.path))
            } else {
                picked.append(url.path)
            }
        }
        addRasterCharts(picked)
    }

}
#endif

import Foundation

extension AppModel {
    /// One file the mariner chose. A plugin that claims the file type gets it
    /// and reads it; anything else is a chart, which is what this panel opens
    /// nearly every time.
    ///
    /// The core answers which — the app never matches extensions itself, so
    /// every shell routes the same file the same way.
    func openFileOrChart(_ path: String) {
        #if os(macOS)
        // A plugin package goes to consent, never to the chart engine. The
        // extension is the package's own, so this is routing, not sniffing.
        if path.lowercased().hasSuffix(".lkplug") {
            beginPluginInstall(path)
            return
        }
        #endif
        if controller?.openFileForPlugins(path) == true { return }
        openChart(path)
    }

    /// Every file extension the loaded plugins read, for the open panel's
    /// message. Empty when no plugin claims one, which is the state a build
    /// with no plugin layer is always in.
    func pluginFileTypes() -> [String] {
        PluginSettings.parse(controller?.pluginsJSON())
            .filter(\.live)
            .flatMap(\.fileTypes)
    }

    /// Every raster chart under a directory. `.mbtiles` today; the extension is
    /// a hint only — the engine decides by what the file IS.
    func rasterPathsIn(_ dir: String) -> [String] {
        guard let en = FileManager.default.enumerator(atPath: dir) else { return [] }
        var paths: [String] = []
        for case let rel as String in en where rel.lowercased().hasSuffix(".mbtiles") {
            paths.append((dir as NSString).appendingPathComponent(rel))
        }
        return paths.sorted()
    }
}

#if os(iOS)
import Foundation

extension AppModel {
    /// Open the mariner form. On iOS it is a sheet, and it opens on the LIST
    /// of sections: the list is the form's first page here, the way the
    /// sidebar is the Mac window's left edge. A caller that wants a particular
    /// section (the screenshot hook) sets `settingsTab` after this.
    func openSettings() {
        settingsTab = ""
        showSettings = true
    }

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
        if isDir.boolValue { openChartDirectory(dest.path) } else { openFileOrChart(dest.path) }
    }

    /// Install the raster charts picked on iOS.
    ///
    /// A chart ALREADY IN THE APP'S OWN DOCUMENTS is used where it lies. The
    /// app publishes that directory to Files (UIFileSharingEnabled), so the way
    /// to carry these aboard is to drop them in from a Mac or a drive and pick
    /// them here. They are half-gigabyte downloads and copying one would spend
    /// the space twice.
    ///
    /// Anything else is copied in, because the picker's security scope ends
    /// with the URL and the engine holds the file open — mmapped — for as long
    /// as the chart is installed.
    func importRasterCharts(_ urls: [URL]) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("Raster", isDirectory: true)
        var picked: [String] = []
        var failed: [String] = []

        for url in urls {
            var isDir: ObjCBool = false
            if url.path.hasPrefix(docs.path), fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                picked.append(contentsOf: isDir.boolValue ? rasterPathsIn(url.path) : [url.path])
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            let sources = isDir.boolValue ? rasterPathsIn(url.path) : [url.path]
            for src in sources {
                let dest = dir.appendingPathComponent((src as NSString).lastPathComponent)
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(atPath: src, toPath: dest.path)
                    picked.append(dest.path)
                } catch {
                    failed.append((src as NSString).lastPathComponent)
                }
            }
        }

        if !failed.isEmpty {
            openError = failed.count == 1
                ? "Couldn't copy \(failed[0]) into the app."
                : "Couldn't copy \(failed.count) raster charts into the app."
        }
        addRasterCharts(picked)
    }
}
#endif
