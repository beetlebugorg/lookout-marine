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

/// Run the cells through the chart bake and the BSB/KAP sheets through the
/// raster bake, and report as one job.
///
/// The two engine calls are separate because the work is: a cell is parsed and
/// portrayed from the survey, a sheet is decoded and warped from a picture.
/// The mariner picked one folder, so they see one count.
private func bakeSplit(
    _ ins: UnsafePointer<UnsafePointer<CChar>?>?,
    _ outs: UnsafePointer<UnsafePointer<CChar>?>?,
    _ ordered: [ScannedCell],
    _ workers: UInt32,
    _ progress: tile57_bake_progress?,
    _ label: tile57_bake_label?,
    _ ctx: UnsafeMutableRawPointer?,
    _ baked: UnsafeMutablePointer<UInt32>?,
    _ err: UnsafeMutablePointer<tile57_error>?
) -> tile57_status {
    // Sorted so cells come first, so one prefix and one suffix.
    let cellCount = ordered.prefix { !$0.isRaster }.count
    let rasterCount = ordered.count - cellCount
    var total: UInt32 = 0

    let job = ctx.map { Unmanaged<ChartBakeJob>.fromOpaque($0).takeUnretainedValue() }

    if cellCount > 0 {
        job?.beginPhase(offset: 0, jobTotal: ordered.count)
        var n: UInt32 = 0
        let st = tile57_bake_files(ins, outs, cellCount, workers, progress, label, ctx, &n, err)
        total += n
        if st != TILE57_OK { baked?.pointee = total; return st }
    }
    if rasterCount > 0 {
        // The engine names and counts from zero for this call; the job puts
        // both back on the mariner's scale.
        job?.beginPhase(offset: cellCount, jobTotal: ordered.count)
        var n: UInt32 = 0
        let st = tile57_bake_rasters(ins?.advanced(by: cellCount), outs?.advanced(by: cellCount),
                                     rasterCount, workers, progress, label, ctx, &n, err)
        total += n
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
        return (root as NSString).appendingPathComponent((sourceDir as NSString).lastPathComponent)
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
        // Coarse first, then by name so a run is repeatable. Raster sheets
        // last: the survey is what a mariner needs to sail, and a picture is
        // what they compare it against.
        let ordered = cells.filter(\.needsBake).sorted {
            if $0.isRaster != $1.isRaster { return !$0.isRaster }
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
        let outPaths = ordered.map { c -> String in
            let stem = (c.name as NSString).deletingPathExtension
            let dir = (outDir as NSString).appendingPathComponent(stem)
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
            return (dir as NSString).appendingPathComponent("\(stem).pmtiles")
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
            // Two engine calls, one per kind: a cell is parsed and portrayed,
            // a BSB sheet is decoded and warped. The list is sorted so each
            // kind is one contiguous run.
            let status = cIn.withUnsafeMutableBufferPointer { inBuf in
                cOut.withUnsafeMutableBufferPointer { outBuf in
                    inBuf.withMemoryRebound(to: UnsafePointer<CChar>?.self) { ins in
                        outBuf.withMemoryRebound(to: UnsafePointer<CChar>?.self) { outs in
                            bakeSplit(
                                ins.baseAddress, outs.baseAddress, ordered, workers,
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
