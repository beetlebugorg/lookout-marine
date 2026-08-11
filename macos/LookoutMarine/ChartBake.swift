//  ChartBake.swift — turning raw S-57 cells into charts the app can draw.
//
//  A cell as a hydrographic office publishes it is an S-57 dataset: the survey,
//  not a picture of it. The app draws baked archives, so a folder of .000 cells
//  is baked once on the way in. tile57 does the work; this chooses the order,
//  runs it off the main thread, reports where it has got to, and stops when the
//  mariner says stop.
//
//  ORDER IS THE POINT. The list goes coarse band first: Overview, General,
//  Coastal, then the harbor detail. A mariner who cancels half way then has
//  charts that cover the whole passage at a usable scale. The other order
//  gives them every berth in one river and nothing between rivers.
//
//  THE CHART OPENS ONCE, AT THE END. Handing each batch to the open library as
//  it finished put a chart on screen sooner, and cost about half the machine:
//  every batch rebuilt the ownership partition over a growing library and
//  re-tessellated, against a bake that only gets half the cores to begin with.
//  Measured over 62 cells on four cores, 13 s became 26 s. It bought little as
//  well: zoomed out, a mariner cannot tell which cells have arrived.

import Foundation

/// Where a bake has got to.
struct BakeProgress: Equatable {
    var done: Int = 0
    var total: Int = 0
    /// The folder being baked.
    var name: String = ""
    /// The cell that finished last, for the action line.
    var cell: String = ""
    /// Seconds since the bake started.
    var elapsed: Double = 0

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// What is left, from the rate so far. Nil until there is enough to say.
    var remaining: String? {
        guard done >= 3, total > done, elapsed > 1 else { return nil }
        let perCell = elapsed / Double(done)
        let left = perCell * Double(total - done)
        if left < 60 { return "under a minute left" }
        if left < 3600 { return "about \(Int((left / 60).rounded())) min left" }
        return String(format: "about %.1f h left", left / 3600)
    }
}

/// One bake, running on a background queue.
///
/// The callbacks run on tile57's worker threads, out of order, so everything
/// they touch is behind the lock. `cancelled` is read by the progress callback,
/// which returns false to stop; tile57 stops at the next chart boundary, so a
/// cancel lands within roughly one cell's bake time, not instantly.
final class ChartBakeJob {
    private let lock = NSLock()
    private var _cancelled = false
    private var _progress = BakeProgress()
    private var _finished: [String] = []
    private let started = Date()
    /// When the last progress went to the main queue. A 7,000 cell import
    /// would otherwise post 7,000 times and lay out the panel 7,000 times,
    /// against a machine with nothing spare.
    private var _lastPost = Date.distantPast

    /// The archive paths, by the index tile57 labels. Read-only once set.
    fileprivate var outPaths: [String] = []
    /// Where the phase now running starts in `outPaths`, and how many charts
    /// the whole job has. The engine is called once per kind and counts from
    /// zero each time; the mariner is watching one job.
    private var _offset = 0
    private var _jobTotal = 0

    fileprivate func beginPhase(offset: Int, jobTotal: Int) {
        lock.lock(); _offset = offset; _jobTotal = jobTotal; lock.unlock()
    }

    /// Called on the main queue whenever the count moves.
    var onProgress: ((BakeProgress) -> Void)?
    /// Called on the main queue when the work stops, with every archive that
    /// finished. Also called for a cancelled run: what landed is a library.
    var onFinished: (([String]) -> Void)?

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    /// A chart finished. Held until the run ends, when the whole list opens at
    /// once.
    fileprivate func finished(index: Int) {
        lock.lock()
        let i = index + _offset
        if i < outPaths.count {
            _finished.append(outPaths[i])
            _progress.cell = (outPaths[i] as NSString).deletingPathExtension
            _progress.cell = (_progress.cell as NSString).lastPathComponent
        }
        lock.unlock()
    }

    fileprivate func report(done: Int, total: Int) {
        lock.lock()
        let now = Date()
        _progress.done = done + _offset
        _progress.total = _jobTotal > 0 ? _jobTotal : total
        _progress.elapsed = now.timeIntervalSince(started)
        let p = _progress
        // The last one always lands, whatever the rate.
        let post = done == total || now.timeIntervalSince(_lastPost) >= 0.2
        if post { _lastPost = now }
        lock.unlock()
        guard post else { return }
        DispatchQueue.main.async { [weak self] in self?.onProgress?(p) }
    }

    /// Every archive that finished. Called once, when the work stops.
    fileprivate func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let all = _finished
        _finished = []
        return all
    }

    fileprivate func setName(_ n: String) {
        lock.lock(); _progress.name = n; lock.unlock()
    }
}

/// What has to happen to one chart before the app can draw it.
private enum Prepare {
    /// An S-57 or S-101 cell: parse the survey and portray it.
    case cell
    /// A BSB/KAP sheet: decode the picture and warp it.
    case sheet
    /// Already a chart, and only has to come out of the archive.
    case lift

    init(_ c: ScannedCell) {
        if c.kind == "source" { self = .cell } else if c.kind == "raster_source" {
            self = .sheet
        } else {
            self = .lift
        }
    }
}

/// Run each kind of work through the engine call that does it, and report the
/// lot as one job.
///
/// The calls are separate because the work is: a cell is parsed and portrayed
/// from the survey, a sheet is decoded and warped from a picture, and imagery
/// that is already a chart is only lifted out of the archive. The mariner
/// picked one thing, so they see one count.
///
/// `source` is the folder or the archive. From an archive each `in` is an
/// ENTRY NAME and the engine reads it where it lies — nothing is unzipped, so
/// importing NOAA's 788 MB All_ENCs.zip never costs the 2.0 GiB of source it
/// holds.
private func bakeSplit(
    _ ins: UnsafePointer<UnsafePointer<CChar>?>?,
    _ outs: UnsafePointer<UnsafePointer<CChar>?>?,
    _ ordered: [ScannedCell],
    _ source: String,
    _ workers: UInt32,
    _ progress: tile57_bake_progress?,
    _ label: tile57_bake_label?,
    _ ctx: UnsafeMutableRawPointer?,
    _ baked: UnsafeMutablePointer<UInt32>?,
    _ err: UnsafeMutablePointer<tile57_error>?
) -> tile57_status {
    // Sorted by kind, so each is one contiguous run.
    let cellCount = ordered.prefix { Prepare($0) == .cell }.count
    let sheetCount = ordered[cellCount...].prefix { Prepare($0) == .sheet }.count
    let liftCount = ordered.count - cellCount - sheetCount
    var total: UInt32 = 0

    let job = ctx.map { Unmanaged<ChartBakeJob>.fromOpaque($0).takeUnretainedValue() }
    let zip: [CChar]? = ChartScan.isArchive(source) ? source.cString(using: .utf8) : nil

    func run(_ offset: Int, _ count: Int, _ call: (UnsafePointer<UnsafePointer<CChar>?>?,
                                                   UnsafePointer<UnsafePointer<CChar>?>?,
                                                   UnsafeMutablePointer<UInt32>?) -> tile57_status)
        -> tile57_status
    {
        guard count > 0 else { return TILE57_OK }
        // The engine names and counts from zero for each call; the job puts
        // them back on the mariner's scale.
        job?.beginPhase(offset: offset, jobTotal: ordered.count)
        var n: UInt32 = 0
        let st = call(ins?.advanced(by: offset), outs?.advanced(by: offset), &n)
        total += n
        return st
    }

    var st = run(0, cellCount) { i, o, n in
        if let zip {
            return zip.withUnsafeBufferPointer {
                tile57_bake_zip_charts($0.baseAddress, i, o, cellCount, workers,
                                       progress, label, ctx, n, err)
            }
        }
        return tile57_bake_files(i, o, cellCount, workers, progress, label, ctx, n, err)
    }
    if st != TILE57_OK { baked?.pointee = total; return st }

    st = run(cellCount, sheetCount) { i, o, n in
        if let zip {
            return zip.withUnsafeBufferPointer {
                tile57_bake_zip_rasters($0.baseAddress, i, o, sheetCount, workers,
                                        progress, label, ctx, n, err)
            }
        }
        return tile57_bake_rasters(i, o, sheetCount, workers, progress, label, ctx, n, err)
    }
    if st != TILE57_OK { baked?.pointee = total; return st }

    // Only an archive has anything to lift: in a folder these files are
    // already where the engine can read them.
    if let zip {
        st = run(cellCount + sheetCount, liftCount) { i, o, n in
            zip.withUnsafeBufferPointer {
                tile57_zip_extract($0.baseAddress, i, o, liftCount, progress, ctx, n, err)
            }
        }
        if st != TILE57_OK { baked?.pointee = total; return st }
    }

    baked?.pointee = total
    return TILE57_OK
}

enum ChartBake {
    /// Everything this app prepared for itself, and nothing else.
    ///
    /// The boundary matters beyond tidiness: what is under here was made from
    /// the mariner's cells and can be made again, so removing a set may delete
    /// it. What is outside is the mariner's own and is never touched.
    static var chartsRoot: String? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base
            .appendingPathComponent("Lookout", isDirectory: true)
            .appendingPathComponent("Charts", isDirectory: true).path
    }

    /// True when this app prepared the charts at `path`.
    static func isDerived(_ path: String) -> Bool {
        guard let root = chartsRoot else { return false }
        return path == root || path.hasPrefix(root + "/")
    }

    /// Where charts prepared from `sourceDir` live, whether or not any have
    /// been. One directory per source folder, named after it, under the app's
    /// own support directory. The source folder is never written to: it may be
    /// a read-only disc or a drive that goes away.
    static func preparedDirectory(for sourceDir: String) -> String? {
        guard let root = chartsRoot else { return nil }
        var name = (sourceDir as NSString).lastPathComponent
        // An archive names its directory without the .zip: what comes out of
        // All_ENCs.zip is charts, and "All_ENCs.zip/" as a folder full of them
        // reads like a mistake.
        if ChartScan.isArchive(sourceDir) { name = (name as NSString).deletingPathExtension }
        return (root as NSString).appendingPathComponent(name)
    }

    /// The same directory, made on disk.
    static func outputDirectory(for sourceDir: String) -> String? {
        guard let dir = preparedDirectory(for: sourceDir) else { return nil }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        return dir
    }

    /// Delete charts this app prepared. Refuses any path it did not make, so a
    /// mariner's own folder can never be deleted by removing a set.
    @discardableResult
    static func deleteDerived(_ path: String) -> Bool {
        guard isDerived(path), path != chartsRoot else { return false }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    /// Bake `cells` into the app's chart directory. `cells` comes from the
    /// scan, so the band is known and the order can be chosen here.
    ///
    /// `workers` is a memory bound, not a speed dial: each one holds a whole
    /// cell's working set, so the cap is what stops a big cell set from
    /// filling memory.
    ///
    /// Every core otherwise. Holding one back does not buy a smooth window:
    /// the bake threads are not scheduled below the render loop, so a saturated
    /// machine is choppy either way, and the mariner is waiting on this and
    /// nothing else. Finishing sooner is the better trade.
    @discardableResult
    static func run(
        sourceDir: String,
        cells: [ScannedCell],
        job: ChartBakeJob,
        completion: @escaping (String?) -> Void
    ) -> Bool {
        guard let outDir = outputDirectory(for: sourceDir) else {
            completion(nil)
            return false
        }
        // Coarse first, then by name so a run is repeatable. Sheets after the
        // survey — that is what a mariner needs to sail, and a picture is what
        // they compare it against — and anything only being lifted out of an
        // archive last, because it is the cheapest and the least urgent.
        let rank = { (c: ScannedCell) -> Int in
            switch Prepare(c) {
            case .cell: return 0
            case .sheet: return 1
            case .lift: return 2
            }
        }
        let ordered = cells.filter(\.needsPrepare).sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            return $0.band == $1.band ? $0.name < $1.name : $0.band < $1.band
        }
        guard !ordered.isEmpty else {
            completion(outDir)
            return false
        }

        let inPaths = ordered.map(\.path)
        // Every prepared chart goes in a directory of its own name, which is
        // the layout tile57's own bake writes and the layout an exchange set
        // uses. Two things depend on it. The raster layer reads a provider
        // from the directory ABOVE, so a folder of 900 sheets written flat
        // becomes 900 providers and 900 switches instead of one. And a cell
        // carries the text and pictures it references beside it, which the
        // engine only writes when the chart has a directory to hold them:
        // those files are named per exchange set, not per chart, so charts
        // written flat would share one manifest and overwrite each other's.
        //
        // From an archive the output MIRRORS the entry's own path, so what
        // comes out is laid out like what went in and a cell's referenced
        // text lands beside the right chart. Imagery keeps its own name: an
        // .mbtiles is a chart already, and renaming it to .pmtiles would be a
        // lie about what is in the file.
        let outPaths = ordered.map { c -> String in
            let stem = (c.name as NSString).deletingPathExtension
            let base = ChartScan.isArchive(sourceDir)
                ? (outDir as NSString).appendingPathComponent((c.path as NSString).deletingLastPathComponent)
                : outDir
            // The chart's own directory — unless the mirrored path IS one
            // already, which it is for every exchange set, since they put each
            // cell in a directory of its name. Appending it again would give
            // US1EEZ3M/US1EEZ3M/US1EEZ3M.pmtiles.
            let dir = Prepare(c) == .lift || (base as NSString).lastPathComponent == stem
                ? base
                : (base as NSString).appendingPathComponent(stem)
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
            let name = Prepare(c) == .lift
                ? (c.path as NSString).lastPathComponent
                : "\(stem).pmtiles"
            return (dir as NSString).appendingPathComponent(name)
        }
        job.outPaths = outPaths
        job.setName((sourceDir as NSString).lastPathComponent)
        let workers = UInt32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))

        DispatchQueue.global(qos: .userInitiated).async {
            let ctx = Unmanaged.passRetained(job).toOpaque()
            defer { Unmanaged<ChartBakeJob>.fromOpaque(ctx).release() }

            var cIn = inPaths.map { strdup($0) }
            var cOut = outPaths.map { strdup($0) }
            defer {
                cIn.forEach { free($0) }
                cOut.forEach { free($0) }
            }

            var baked: UInt32 = 0
            var err = tile57_error()
            // One engine call per kind of work: a cell is parsed and portrayed,
            // a BSB sheet is decoded and warped. The list is sorted so each
            // kind is one contiguous run.
            let status = cIn.withUnsafeMutableBufferPointer { inBuf in
                cOut.withUnsafeMutableBufferPointer { outBuf in
                    inBuf.withMemoryRebound(to: UnsafePointer<CChar>?.self) { ins in
                        outBuf.withMemoryRebound(to: UnsafePointer<CChar>?.self) { outs in
                            bakeSplit(
                                ins.baseAddress, outs.baseAddress, ordered, sourceDir, workers,
                                { ctx, done, total in
                                    guard let ctx else { return true }
                                    let j = Unmanaged<ChartBakeJob>.fromOpaque(ctx).takeUnretainedValue()
                                    j.report(done: Int(done), total: Int(total))
                                    return !j.cancelled   // false CANCELS the bake
                                },
                                { ctx, index in
                                    guard let ctx else { return }
                                    let j = Unmanaged<ChartBakeJob>.fromOpaque(ctx).takeUnretainedValue()
                                    j.finished(index: Int(index))
                                },
                                ctx, &baked, &err)
                        }
                    }
                }
            }

            let done = job.drain()
            DispatchQueue.main.async {
                job.onFinished?(done)
                // A cancelled bake is not a failure. Whatever landed is a
                // usable library, so the caller still gets the directory.
                completion(status == TILE57_OK ? outDir : nil)
            }
        }
        return true
    }
}
