//  ChartSets.swift — the installed charts, and which of them are drawn.
//
//  A SET is a folder the mariner added, or one .zip — which is how a chart
//  agency publishes them. Either way it carries every chart inside, however
//  deep: a bake mirrors the exchange set's tree, so a library is nested rather
//  than flat.
//
//  The list answers two questions a file picker cannot. What is installed, and
//  what am I sailing on right now. A folder goes on the list only after the
//  core has looked through it and found charts, so a set on the list always
//  opens. Switching a set off keeps it installed and takes it out of the chart.
//
//  The core does the looking (lookout_scan_read). It walks the folder, names
//  every file, and asks tile57 what each archive holds, which is the only way
//  to tell a chart from a picture archive or a foreign bake. An archive is
//  read the same way (lookout_scan_zip_read) but only its listing: 36 ms for the
//  7,224 charts in NOAA's All_ENCs.zip, against about 3 seconds to walk the
//  same charts unpacked. Nothing inside one can be verified or drawn until it
//  has been taken out, which is what `archived` marks.

import Foundation

/// One chart the scan found.
struct ScannedCell: Identifiable, Hashable {
    /// What a scanned file is, as the core names it.
    enum Kind {
        case baked, source, update, raster, rasterSource, other

        init(_ k: lookout_file_kind) {
            switch k {
            case LOOKOUT_FILE_SOURCE:        self = .source
            case LOOKOUT_FILE_UPDATE:        self = .update
            case LOOKOUT_FILE_RASTER:        self = .raster
            case LOOKOUT_FILE_RASTER_SOURCE: self = .rasterSource
            case LOOKOUT_FILE_OTHER:         self = .other
            default:                         self = .baked
            }
        }
    }

    let path: String
    /// The 8 character dataset name, such as US5MD1MC.
    let name: String
    let kind: Kind
    /// 1 to 6, or 0 when the name carries no usage band. The name of the band
    /// comes from ChartSet.bandName, so a set and a cell cannot disagree.
    let band: Int
    let bytes: Int64
    /// True when `path` is a name INSIDE an archive rather than a file. Such a
    /// chart cannot be opened, whatever it is: it has to come out first.
    var archived: Bool = false

    init(path: String, name: String, kind: Kind, band: Int, bytes: Int64,
         archived: Bool = false) {
        self.path = path
        self.name = name
        self.kind = kind
        self.band = band
        self.bytes = bytes
        self.archived = archived
    }

    init(_ f: lookout_chart_file, archived: Bool) {
        self.init(path: String(cString: f.path),
                  name: String(cString: f.name),
                  kind: Kind(f.kind),
                  band: Int(f.band),
                  bytes: Int64(f.bytes),
                  archived: archived)
    }

    var id: String { path }
    /// The name without its extension, which is what a prepared archive and
    /// the file it was made from have in common.
    var stem: String { (name as NSString).deletingPathExtension }
    /// True when this file must be prepared before it can be drawn: an S-57 or
    /// S-101 cell, or a BSB/KAP sheet.
    var needsBake: Bool { kind == .source || kind == .rasterSource }
    /// True when something has to happen before the engine can be handed this.
    /// Inside an archive that is everything, including a chart that is already
    /// baked: it still has to be got out.
    var needsPrepare: Bool { archived || needsBake }
    /// True when this is a picture rather than the survey.
    var isRaster: Bool { kind == .raster || kind == .rasterSource }
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
    /// False when the mariner switched this set off. It stays installed.
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
    /// A read is this caller's own copy, so two at once are safe. They are
    /// serialized because two scans of a big library compete for the same
    /// disk.
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
                                         cells: [], rasters: [], on: true)
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
        guard let read = archive ? lookout_scan_zip_read(path) : lookout_scan_read(path),
              let found = lookout_scan_found(read)
        else { return nil }
        defer { lookout_scan_free(read) }

        var n = 0
        let cells = Self.scanned(lookout_scan_cells(read, &n), n, archived: archive)
        let raster = Self.scanned(lookout_scan_raster(read, &n), n, archived: archive)
        // The core states no producer when the charts disagree, and says so
        // with an empty string.
        let producer = String(cString: found.pointee.producer)
        return ChartSet(
            path: String(cString: found.pointee.root),
            producer: producer.isEmpty ? nil : producer,
            preparedPath: nil,
            cells: cells,
            rasters: raster,
            on: true
        )
    }

    /// One of the scan's two lists, copied out of the read.
    private static func scanned(_ p: UnsafePointer<UnsafePointer<lookout_chart_file>?>?,
                                _ n: Int, archived: Bool) -> [ScannedCell] {
        guard let p else { return [] }
        return (0..<n).compactMap { i in
            p[i].map { ScannedCell($0.pointee, archived: archived) }
        }
    }
}

/// The installed sets, and their on and off state, across launches.
///
/// The CORE holds the list: `lookout_chart_sets` loads it off the store, scans
/// each folder on a worker of its own, and answers what to open. Only the
/// folder and the switch are stored. The cells are scanned again at launch,
/// because a folder changes underneath the app: a bake finishes, a drive is
/// unplugged, the mariner deletes a region.
enum ChartSetStore {
    /// The model, opened once on the shell's store. Nil when the core cannot
    /// open one, leaving every read empty and every write a no-op.
    nonisolated(unsafe) private static var handle: OpaquePointer? = open()

    private static func open() -> OpaquePointer? {
        guard let store = Store.shared.handle else { return nil }
        // Where the bake writes. The core scans it beside each set, so a
        // folder imported once does not ask to be imported again.
        return (ChartBake.chartsRoot ?? "").withCString {
            lookout_chart_sets_open(store, $0)
        }
    }

    /// A background scan has landed since the last ask. The frame loop polls
    /// it, the way it polls the chart links.
    static func changed() -> Bool {
        guard let h = handle else { return false }
        return lookout_chart_sets_changed(h) != 0
    }

    /// Every set, in the order added.
    static func all() -> [CoreChartSet] {
        guard let h = handle else { return [] }
        var n = 0
        guard let rows = lookout_chart_sets_all(h, &n) else { return [] }
        return (0..<n).compactMap { rows[$0].map { CoreChartSet($0.pointee) } }
    }

    /// Every file one set holds, as the scan found it. The bake reads this
    /// rather than walking the folder again.
    static func files(of path: String) -> [ScannedCell] {
        guard let h = handle else { return [] }
        return path.withCString { p in
            var n = 0
            guard let rows = lookout_chart_set_files(h, p, &n) else { return [] }
            // A .zip's entries cannot be handed to the engine as they lie.
            let archive = ChartScan.isArchive(path)
            return (0..<n).compactMap { i in
                rows[i].map { ScannedCell($0.pointee, archived: archive) }
            }
        }
    }

    static func savedPaths() -> [String] { all().map(\.path) }
    static func savedOff() -> Set<String> { Set(all().filter { !$0.on }.map(\.path)) }

    /// Every chart the switched-on sets hold, sorted and deduplicated. The
    /// core's rule, so two shells reading one library open it the same way.
    static func compose() -> [String] {
        guard let h = handle else { return [] }
        var n = 0
        guard let paths = lookout_chart_sets_compose(h, &n) else { return [] }
        return (0..<n).compactMap { paths[$0].map { String(cString: $0) } }
    }

    /// Put a folder on the list and scan it. False when it was already there.
    @discardableResult
    static func add(_ path: String) -> Bool {
        guard let h = handle else { return false }
        return path.withCString { lookout_chart_sets_add(h, $0) != 0 }
    }

    /// Take a folder off the list. This deletes nothing: what a bake produced
    /// is the shell's to remove.
    @discardableResult
    static func remove(_ path: String) -> Bool {
        guard let h = handle else { return false }
        return path.withCString { lookout_chart_sets_remove(h, $0) != 0 }
    }

    static func setOff(_ path: String, _ off: Bool) {
        guard let h = handle else { return }
        _ = path.withCString { lookout_chart_sets_set_on(h, $0, off ? 0 : 1) }
    }

    /// For a test: point the model at the store in force. `Store.shared` is
    /// swapped per test, and a handle held over that swap reads the previous
    /// test's file.
    static func reopen() {
        close()
        handle = open()
    }

    /// For a test: close the model and open none. Opening one starts a scan of
    /// every saved path, which a test putting the mariner's own store back has
    /// no business starting.
    static func close() {
        if let h = handle { lookout_chart_sets_close(h) }
        handle = nil
    }
}

/// One row of the core's list.
struct CoreChartSet: Identifiable, Hashable {
    let path: String
    /// The agency when the charts agree on one, else the folder name.
    let title: String
    /// The two-character producer code. Empty when the charts disagree.
    let producer: String
    let on: Bool
    /// False until the background scan has read this folder. Every count below
    /// is 0 until then.
    let scanned: Bool
    let charts: Int
    let pictures: Int
    let unprepared: Int
    let bytes: Int64
    /// The coarsest and finest usage bands present, 1 to 6. 0 when the set
    /// holds no cell with a band in its name.
    let bandLo: Int
    let bandHi: Int

    var id: String { path }

    init(_ s: lookout_chart_set) {
        path = String(cString: s.path)
        title = String(cString: s.title)
        producer = String(cString: s.producer)
        on = s.on != 0
        scanned = s.scanned != 0
        charts = s.charts
        pictures = s.pictures
        unprepared = s.unprepared
        bytes = Int64(s.bytes)
        bandLo = Int(s.band_lo)
        bandHi = Int(s.band_hi)
    }
}
