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
        // Whatever charts the build put in the bundle, which is one sample cell
        // by default and is however many cells were dropped into
        // visionos/Charts before the build.
        if let resources = Bundle.main.resourceURL {
            let paths = expand(resources.path)
            if !paths.isEmpty {
                lkLog("charts: \(paths.count) from the bundle")
                return paths
            }
        }
        return []
    }

    static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    // MARK: - What the margin says about the charts

    /// The agency and the scale band, the way a printed chart names them in
    /// its title block. The core's own scan answers both: a producer code
    /// every cell agrees on, and each cell's band and native scale.
    static func describe(_ paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        // One file describes itself; a set is described by the folder holding
        // it, which is what carries the producer they share.
        let target = paths.count == 1 ? first : URL(fileURLWithPath: first).deletingLastPathComponent().path
        var len = 0
        guard let s = lookout_scan_charts(target, &len), len > 0,
              let data = String(decoding: UnsafeRawBufferPointer(start: s, count: len), as: UTF8.self)
                .data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "" }

        var parts: [String] = []
        if let producer = root["producer"] as? String, !producer.isEmpty {
            parts.append(agency(producer))
        }
        let cells = (root["cells"] as? [[String: Any]]) ?? []
        if paths.count == 1, let cell = cells.first {
            if let band = cell["bandName"] as? String, !band.isEmpty { parts.append(band) }
            if let scale = cell["scale"] as? Double, scale > 0 {
                parts.append("native 1:\(thousands(Int(scale)))")
            }
        } else if !cells.isEmpty {
            parts.append("\(cells.count) cells")
            let bands = Set(cells.compactMap { $0["bandName"] as? String }).sorted()
            if bands.count == 1, let only = bands.first { parts.append(only) }
        }
        return parts.joined(separator: "   ")
    }

    /// A dataset's producer code as the agency a mariner knows. An unknown
    /// code passes through: it is what the chart itself says.
    private static func agency(_ code: String) -> String {
        switch code.uppercased() {
        case "US": return "NOAA"
        case "GB": return "UKHO"
        case "CA": return "CHS"
        case "AU": return "AHO"
        case "NZ": return "LINZ"
        case "NL": return "NLHO"
        case "DE": return "BSH"
        case "FR": return "Shom"
        case "NO": return "NHS"
        case "SE": return "SMA"
        case "DK": return "DGA"
        case "JP": return "JHA"
        default: return code.uppercased()
        }
    }

    static func thousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - The folder the mariner chose

    /// A folder or a file picked out of the Files app lives outside this app's
    /// container. Reaching it needs a security-scoped bookmark, kept here so
    /// the same charts come back on the next launch, and access held open for
    /// as long as a chart is open: the engine memory-maps every cell and reads
    /// from it as the mariner pans.
    private static let bookmarkKey = "lookout.chartFolderBookmark"
    private static var scoped: URL?

    /// Adopt a folder or a file, from the picker or from whatever the system
    /// handed the app. Answers the .pmtiles paths under it, or an empty list
    /// when it holds none, in which case nothing is remembered.
    ///
    /// A URL from the Files app lives outside this app and needs its scope
    /// started. One the system copied into the app's own Inbox does not, and
    /// says so by refusing the call, so a refusal is not a failure here.
    static func adopt(_ url: URL) -> [String] {
        let outside = url.startAccessingSecurityScopedResource()
        let paths = expand(url.path)
        guard !paths.isEmpty else {
            if outside { url.stopAccessingSecurityScopedResource() }
            lkLog("no .pmtiles in \(url.lastPathComponent)")
            return []
        }
        releaseScope()
        if outside {
            scoped = url
            do {
                let data = try url.bookmarkData()
                UserDefaults.standard.set(data, forKey: bookmarkKey)
            } catch {
                // The charts still open; they just will not come back by
                // themselves next launch.
                lkLog("no bookmark for \(url.lastPathComponent): \(error)")
            }
        } else {
            // Inside the container already, so it is found again by the
            // ordinary search and needs no bookmark.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
        lkLog("charts: \(paths.count) from \(url.lastPathComponent)")
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
        }
        return found.sorted()
    }
}
