//  ChartSets.swift — the charts aboard, and which of them are drawn.
//
//  A SET is a folder the mariner added, or one .zip — which is how a chart
//  agency publishes them. Either way it carries every chart inside, however
//  deep: a bake mirrors the exchange set's tree, so a library is nested rather
//  than flat.
//
//  The list answers two questions a file picker cannot. What is aboard, and
//  what am I sailing on right now. A folder goes on the list only after the
//  core has looked through it and found charts, so a set on the list always
//  opens. Switching a set off keeps it aboard and takes it out of the chart.
//
//  The core does the looking (lookout_scan_charts). It walks the folder, names
//  every file, and asks tile57 what each archive holds, which is the only way
//  to tell a chart from a picture archive or a foreign bake. An archive is
//  read the same way (lookout_scan_zip) but only its listing: 36 ms for the
//  7,224 charts in NOAA's All_ENCs.zip, against about 3 seconds to walk the
//  same charts unpacked. Nothing inside one can be verified or drawn until it
//  has been taken out, which is what `archived` marks.

import Foundation

/// One chart the scan found.
struct ScannedCell: Identifiable, Hashable {
    let path: String
    /// The 8 character dataset name, such as US5MD1MC.
    let name: String
    /// "baked" draws now. "source" is an S-57 cell that bakes first.
    let kind: String
    /// 1 to 6, or 0 when the name carries no usage band.
    let band: Int
    let bandName: String
    let bytes: Int64
    /// The compilation scale the bake embedded, or 0.
    let scale: Int
    /// True when `path` is a name INSIDE an archive rather than a file. Such a
    /// chart cannot be opened, whatever it is: it has to come out first.
    var archived: Bool = false

    var id: String { path }
    /// The name without its extension, which is what a prepared archive and
    /// the file it was made from have in common.
    var stem: String { (name as NSString).deletingPathExtension }
    /// True when this file must be prepared before it can be drawn: an S-57 or
    /// S-101 cell, or a BSB/KAP sheet.
    var needsBake: Bool { kind == "source" || kind == "raster_source" }
    /// True when something has to happen before the engine can be handed this.
    /// Inside an archive that is everything, including a chart that is already
    /// baked: it still has to be got out.
    var needsPrepare: Bool { archived || needsBake }
    /// True when this is a picture rather than the survey.
    var isRaster: Bool { kind == "raster" || kind == "raster_source" }
}

/// What one folder holds.
///
/// The set IS the folder the mariner picked. Charts Lookout prepared from it
/// live in their own directory and are counted as part of the same set, so a
/// folder holding both raw cells and ready imagery arrives whole. Naming the
/// prepared directory as the set instead loses everything that needed no
/// preparing, because those files never move.
struct ChartSet: Identifiable, Hashable {
    /// The folder. It is also the identity: adding the same folder twice
    /// updates the set rather than making a second one.
    let path: String
    /// The two-character producer code every chart in the set carries, when
    /// they all carry the same one. From the charts, not the file name.
    var producer: String?
    /// Where Lookout put what it prepared from this folder, when it prepared
    /// anything. Removing the set deletes this; the folder above is never
    /// touched.
    var preparedPath: String?
    var cells: [ScannedCell]
    /// Picture charts found in the same folder: imagery, and RNC sheets. They
    /// are part of the set, not a separate thing the mariner has to add again.
    var rasters: [ScannedCell]
    /// S-57 update files. Each one bakes with its base cell.
    var updates: Int
    /// Files in the folder that are not charts.
    var other: Int
    /// Archives with a chart name that the engine refused.
    var refused: Int
    /// False when the mariner switched this set off. It stays aboard.
    var on: Bool

    var id: String { path }
    /// What the folder or archive is called. The identity, and the fallback
    /// name when the charts inside do not agree on who made them.
    var name: String { (path as NSString).lastPathComponent }

    /// What to call this set. The agency that made the charts when they all
    /// came from one, because "All_ENCs.zip" and "ENC_ROOT" are what a
    /// download happened to be called and say nothing about what is in it.
    /// The folder name stays in the line underneath, so two sets from the same
    /// office are still told apart.
    var title: String { ChartSet.agency(producer) ?? name }

    /// The hydrographic office a producer code belongs to.
    ///
    /// The code is the country's, and for these that is the office a mariner
    /// would name. An office not listed keeps the folder name rather than
    /// being given a title invented here: a wrong agency on a chart set is
    /// worse than a dull one.
    static func agency(_ code: String?) -> String? {
        switch code?.uppercased() {
        case "US": return "NOAA"
        case "GB": return "UKHO"
        case "CA": return "CHS"
        case "AU": return "AHO"
        case "NZ": return "LINZ"
        case "NL": return "Netherlands Hydrographic Office"
        case "DE": return "BSH"
        case "FR": return "Shom"
        case "NO": return "Norwegian Hydrographic Service"
        case "DK": return "Danish Geodata Agency"
        case "SE": return "Swedish Maritime Administration"
        case "FI": return "Finnish Transport Agency"
        case "IE": return "INFOMAR"
        case "JP": return "Japan Hydrographic Association"
        case "BR": return "DHN"
        case "ZA": return "SANHO"
        default: return nil
        }
    }
    /// True when Lookout prepared part of this set. Those files can be made
    /// again, so removing the set deletes them. The mariner's own folder is
    /// never deleted.
    var isDerived: Bool { preparedPath != nil }
    var bytes: Int64 { (cells + rasters).reduce(0) { $0 + $1.bytes } }
    /// Everything in this set that must be prepared before it draws.
    var toPrepare: [ScannedCell] { (cells + rasters).filter(\.needsPrepare) }
    var needsBake: Int { toPrepare.count }
    /// What is left over after a prepare has already run for this set: files
    /// the engine would not read. Offering to prepare them again says the work
    /// is unfinished when it is as finished as it will get.
    var refusedCount: Int { preparedPath == nil ? 0 : toPrepare.count }
    /// The pictures that are ready to draw now.
    var rasterPaths: [String] { rasters.filter { !$0.needsPrepare }.map(\.path) }

    /// The pictures, grouped the way the chart draws them: by whoever made
    /// them. A folder can hold hundreds of tiles from one survey, and a
    /// hundred switches is not a list a mariner reads on a moving boat. The
    /// provider is the unit that means something, because only one picture
    /// covers a piece of water at a time.
    func rasterGroups(label: (String) -> String) -> [(name: String, paths: [String])] {
        var order: [String] = []
        var byName: [String: [String]] = [:]
        for r in rasters where !r.needsPrepare {
            let n = label(r.path)
            if byName[n] == nil { order.append(n) }
            byName[n, default: []].append(r.path)
        }
        return order.map { ($0, byName[$0] ?? []) }
    }
    /// The archives that can be handed to the engine now. Never a chart still
    /// inside an archive: that path is an entry name, and there is no file at
    /// it until it is taken out.
    var openablePaths: [String] { cells.filter { !$0.needsPrepare }.map(\.path) }

    /// "512 charts · 3 pictures · Coastal to Harbor · 1.2 GB".
    var summary: String {
        var parts: [String] = []
        if !cells.isEmpty { parts.append(cells.count == 1 ? "1 chart" : "\(cells.count) charts") }
        if !rasters.isEmpty {
            parts.append(rasters.count == 1 ? "1 picture" : "\(rasters.count) pictures")
        }
        if let lo = cells.map(\.band).filter({ $0 > 0 }).min(),
           let hi = cells.map(\.band).filter({ $0 > 0 }).max() {
            let loName = ChartSet.bandName(lo), hiName = ChartSet.bandName(hi)
            parts.append(lo == hi ? loName : "\(loName) to \(hiName)")
        }
        parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    /// How many cells sit in each band, coarse to fine. The row draws this as
    /// a ladder, so a mariner sees at a glance whether a set carries the
    /// harbor detail or stops at the coast.
    var bandCounts: [(band: Int, name: String, count: Int)] {
        (1...6).compactMap { b in
            let n = cells.filter { $0.band == b }.count
            return n == 0 ? nil : (b, ChartSet.bandName(b), n)
        }
    }

    static func bandName(_ band: Int) -> String {
        switch band {
        case 1: return "Overview"
        case 2: return "General"
        case 3: return "Coastal"
        case 4: return "Approach"
        case 5: return "Harbor"
        case 6: return "Berthing"
        default: return "Unknown"
        }
    }
}

/// The result of looking through one folder.
enum ChartScan {
    /// Every scan runs here, one at a time.
    ///
    /// lookout_scan_charts hands back a pointer the core owns until the NEXT
    /// call, so two scans at once free each other's answer and a folder comes
    /// back empty. Serializing is right on its own terms as well: two scans of
    /// a big library at once would fight for the same disk.
    private static let queue = DispatchQueue(label: "org.beetlebug.lookout.chartscan")

    /// Walk `path` and report what is there. Runs the core's scan, which opens
    /// every archive it finds, so it is slow enough to keep off the main
    /// thread: the full NOAA library is 7,217 archives and about 3 seconds.
    /// One folder as a set: what is in it, plus whatever Lookout prepared
    /// from it. A cell that has been prepared is dropped in favour of its
    /// archive, so a folder scanned after an import does not ask to be
    /// imported again.
    static func scan(_ path: String) -> ChartSet? {
        queue.sync {
            let source = scanLocked(path)
            guard let prepared = ChartBake.preparedDirectory(for: path),
                  FileManager.default.fileExists(atPath: prepared),
                  let derived = scanLocked(prepared)
            else { return source }

            // The archive wins over the file it was made from.
            let readyStems = Set((derived.cells + derived.rasters).map(\.stem))
            var set = source ?? ChartSet(path: path, producer: nil, preparedPath: nil,
                                         cells: [], rasters: [],
                                         updates: 0, other: 0, refused: 0, on: true)
            set.preparedPath = prepared
            // Whichever half holds the charts knows who made them: a set that
            // has been imported has them under the prepared directory, and one
            // that needed no importing has them where the mariner keeps them.
            set.producer = set.producer ?? derived.producer
            set.cells = derived.cells + set.cells.filter { !readyStems.contains($0.stem) }
            set.rasters = derived.rasters + set.rasters.filter { !readyStems.contains($0.stem) }
            return set
        }
    }

    /// True for a chart set that arrives as one archive.
    static func isArchive(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "zip"
    }

    private static func scanLocked(_ path: String) -> ChartSet? {
        let archive = isArchive(path)
        var len = 0
        guard let raw = archive ? lookout_scan_zip(path, &len) : lookout_scan_charts(path, &len),
              len > 0
        else { return nil }
        // Build from the reported length, not as a C string. The core hands
        // back a counted buffer, and reading it to a NUL would run past the
        // end of the answer.
        let json = raw.withMemoryRebound(to: UInt8.self, capacity: len) {
            String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
        }
        guard let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return nil }

        let cells = (o["cells"] as? [[String: Any]] ?? []).map { c in
            ScannedCell(
                path: c["path"] as? String ?? "",
                name: c["name"] as? String ?? "",
                kind: c["kind"] as? String ?? "baked",
                band: c["band"] as? Int ?? 0,
                bandName: c["bandName"] as? String ?? "",
                bytes: c["bytes"] as? Int64 ?? Int64(c["bytes"] as? Int ?? 0),
                scale: c["scale"] as? Int ?? 0,
                archived: archive
            )
        }
        let raster = (o["raster"] as? [[String: Any]] ?? []).map { c in
            ScannedCell(
                path: c["path"] as? String ?? "",
                name: c["name"] as? String ?? "",
                kind: c["kind"] as? String ?? "raster",
                band: 0, bandName: "",
                bytes: c["bytes"] as? Int64 ?? Int64(c["bytes"] as? Int ?? 0),
                scale: 0,
                archived: archive)
        }
        return ChartSet(
            path: o["root"] as? String ?? path,
            producer: o["producer"] as? String,
            preparedPath: nil,
            cells: cells,
            rasters: raster,
            updates: o["updates"] as? Int ?? 0,
            other: o["other"] as? Int ?? 0,
            refused: o["refused"] as? Int ?? 0,
            on: true
        )
    }
}

/// The sets aboard, and their on and off state, across launches.
///
/// Only the folder and the switch are stored. The cells are scanned again at
/// launch, because a folder changes underneath the app: a bake finishes, a
/// drive is unplugged, the mariner deletes a region. Storing the cell list
/// would mean offering charts that are no longer there.
struct ChartSetStore {
    private static let pathsKey = "lookout.chartsets"
    private static let offKey = "lookout.chartsets.off"
    /// What the sets replaced. Read once, so a mariner who had charts open
    /// before this list existed still has them after.
    private static let legacyKey = "lookout.recents"

    /// Raster charts added before sets existed, as the folders they live in.
    /// One list means one list: a picture the mariner added by hand is a set
    /// like any other, not a second kind of thing in a second section.
    private static func legacyRasterFolders() -> [String] {
        let files = Store.shared.strings("lookout.rastercharts") ?? []
        var seen = Set<String>()
        var out: [String] = []
        for f in files where FileManager.default.fileExists(atPath: f) {
            // Never anything Lookout prepared. Those already belong to the set
            // they were made from, and each one sits in a directory of its own
            // name: a folder of 900 sheets would otherwise arrive as 900 sets.
            if ChartBake.isDerived(f) { continue }
            let dir = (f as NSString).deletingLastPathComponent
            if dir.isEmpty || seen.contains(dir) { continue }
            seen.insert(dir)
            out.append(dir)
        }
        return out
    }

    static func savedPaths() -> [String] {
        if let saved = Store.shared.strings(pathsKey) {
            // A mariner who had raster charts before this list existed gets
            // them as sets, once.
            let missing = legacyRasterFolders().filter { !saved.contains($0) }
            guard !missing.isEmpty, !Store.shared.bool("lookout.chartsets.rastermigrated")
            else { return saved }
            Store.shared.set(true, "lookout.chartsets.rastermigrated")
            let merged = saved + missing
            Store.shared.set(merged, pathsKey)
            return merged
        }
        // No list yet means this build has never run here. Carry the last
        // opened paths across: without this the mariner's charts are simply
        // gone at the next launch, with the folder still on disk and the app
        // showing the first-run panel.
        //
        // The paths are not filtered here. A scan decides what is a chart, so
        // an entry that was never a chart library, or has since been deleted,
        // drops out on its own the first time the list is built.
        let legacy = (Store.shared.strings(legacyKey) ?? [])
            + legacyRasterFolders()
        Store.shared.set(true, "lookout.chartsets.rastermigrated")
        if !legacy.isEmpty { Store.shared.set(legacy, pathsKey) }
        return legacy
    }

    static func savedOff() -> Set<String> {
        Set(Store.shared.strings(offKey) ?? [])
    }

    /// Put a folder on the list. Adding one already there changes nothing.
    static func add(_ path: String) {
        var paths = savedPaths()
        if !paths.contains(path) { paths.append(path) }
        Store.shared.set(paths, pathsKey)
    }

    /// Take a folder off the list. This is the ONLY thing that shortens it.
    static func remove(_ path: String) {
        Store.shared.set(savedPaths().filter { $0 != path }, pathsKey)
        Store.shared.set(Array(savedOff().subtracting([path])), offKey)
    }

    static func setOff(_ path: String, _ off: Bool) {
        var list = savedOff()
        if off { list.insert(path) } else { list.remove(path) }
        Store.shared.set(Array(list), offKey)
    }
}
