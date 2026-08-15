//
//  Where the charts are.
//
//  A headset has no home directory a mariner can reach, so charts arrive in
//  the app's own Documents folder, which the Files app shows. A build for the
//  simulator can also be pointed at the machine's chart library with
//  LOOKOUT_CHARTS, and the bundle carries one cell so a fresh install has
//  something to draw.
//

import Foundation

enum ChartLibrary {
    /// Baked charts, best source first. Every path is a .pmtiles file.
    static func find() -> [String] {
        if let chosen = resolveChosen() {
            let paths = expand(chosen.path)
            if !paths.isEmpty {
                lkLog("charts: \(paths.count) from the chosen folder \(chosen.lastPathComponent)")
                return paths
            }
            lkLog("the chosen folder \(chosen.lastPathComponent) holds no .pmtiles")
        }
        if let env = ProcessInfo.processInfo.environment["LOOKOUT_CHARTS"], !env.isEmpty {
            let paths = expand(env)
            if !paths.isEmpty {
                lkLog("charts: \(paths.count) from LOOKOUT_CHARTS")
                return paths
            }
            lkLog("LOOKOUT_CHARTS=\(env) holds no .pmtiles")
        }
        if let docs = documents {
            let paths = expand(docs.path)
            if !paths.isEmpty {
                lkLog("charts: \(paths.count) from Documents")
                return paths
            }
        }
        if let bundled = Bundle.main.url(forResource: "US5MD1MC", withExtension: "pmtiles") {
            lkLog("charts: the bundled sample cell")
            return [bundled.path]
        }
        return []
    }

    static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    // MARK: - The folder the mariner chose

    /// A folder or a file picked out of the Files app lives outside this app's
    /// container. Reaching it needs a security-scoped bookmark, kept here so
    /// the same charts come back on the next launch, and access held open for
    /// as long as a chart is open: the engine memory-maps every cell and reads
    /// from it as the mariner pans.
    private static let bookmarkKey = "lookout.chartFolderBookmark"
    private static var scoped: URL?

    /// Adopt what a picker returned. Answers the .pmtiles paths under it, or an
    /// empty list when it holds none, in which case nothing is remembered.
    static func adopt(_ url: URL) -> [String] {
        guard url.startAccessingSecurityScopedResource() else {
            lkLog("no access to \(url.lastPathComponent)")
            return []
        }
        let paths = expand(url.path)
        guard !paths.isEmpty else {
            url.stopAccessingSecurityScopedResource()
            return []
        }
        releaseScope()
        scoped = url
        do {
            let data = try url.bookmarkData()
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            // The charts still open; they just will not come back by
            // themselves next launch.
            lkLog("no bookmark for \(url.lastPathComponent): \(error)")
        }
        lkLog("charts: \(paths.count) chosen from \(url.lastPathComponent)")
        return paths
    }

    /// The remembered folder, with access started, or nil when there is none,
    /// it has moved, or it can no longer be reached.
    private static func resolveChosen() -> URL? {
        if let already = scoped { return already }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else {
            lkLog("the remembered chart folder is out of reach")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        scoped = url
        return url
    }

    /// Give the remembered folder back and open the app's own again.
    static func forget() {
        releaseScope()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private static func releaseScope() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
    }

    /// Every .pmtiles under a path: the file itself when it is one, else the
    /// directory walked one level down, which is the layout a baked ENC_ROOT
    /// has (one directory per cell).
    private static func expand(_ path: String) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return path.hasSuffix(".pmtiles") ? [path] : []
        }
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: path),
                                         includingPropertiesForKeys: nil,
                                         options: [.skipsHiddenFiles])
        else { return [] }
        var found: [String] = []
        for case let url as URL in walker where url.pathExtension == "pmtiles" {
            found.append(url.path)
            // A whole ENC_ROOT is thousands of cells and opening every one of
            // them is a minute of work a table does not need. The library
            // composes what it is given, so give it a working set.
            if found.count >= maxCells { break }
        }
        return found.sorted()
    }

    /// How many cells one table opens. A harbor and its approaches is a
    /// handful of cells; the cap is what keeps a dropped ENC_ROOT from
    /// stalling the open.
    static let maxCells = 400
}
