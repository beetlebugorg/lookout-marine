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
