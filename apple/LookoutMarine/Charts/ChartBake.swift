//  ChartBake.swift — turning raw S-57 cells into charts the app can draw.
//
//  A cell as a hydrographic office publishes it is an S-57 dataset: the survey,
//  not a picture of it. The app draws baked archives, so a folder of .000 cells
//  is baked once on the way in. tile57 does the work; this chooses the order,
//  runs it off the main thread, reports where it has got to, and stops when the
//  mariner says stop.
//
//  THE ORDER AND THE PATHS ARE THE CORE'S: lookout_bake_order and
//  lookout_bake_output_path. Four shells had four copies of both, and the
//  output layout is the one with teeth in it (see lookout-library.h).
//
//  THE CHART OPENS ONCE, AT THE END. Handing each batch to the open library as
//  it finished put a chart on screen sooner, and cost about half the machine:
//  every batch rebuilt the ownership partition over a growing library and
//  re-tessellated, against a bake that only gets half the cores to begin with.
//  Measured over 62 cells on four cores, 13 s became 26 s. It bought little as
//  well: zoomed out, a mariner cannot tell which cells have arrived.

import Foundation

/// Which piece of work the panel is reporting.
enum ChartWorkKind: Equatable {
    /// Looking through a folder or an archive for charts.
    case finding
    /// Converting cells and sheets into charts.
    case importing
    /// Throwing away the charts made from a set that has been removed.
    case removing
}

/// Where a bake has got to.
struct BakeProgress: Equatable {
    var kind: ChartWorkKind = .importing
    var done: Int = 0
    var total: Int = 0
    /// The folder being baked.
    var name: String = ""
    /// Seconds since the bake started.
    var elapsed: Double = 0

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// What this work is called, wherever it is shown. One definition: the
    /// chart window's pill and the Charts panel both read it, and when they
    /// each had their own, a removal was still headed "Importing".
    var title: String {
        switch kind {
        case .removing: return "Removing \(name)"
        case .finding: return "Finding charts in \(name)"
        // A count means the charts have been found and are being converted.
        case .importing: return total > 0 ? "Importing \(name)" : "Finding charts in \(name)"
        }
    }

    /// What is left, from the rate so far. Nil until there is enough to say.
    ///
    /// A removal is not timed: it is seconds of disk work, and a countdown on
    /// something already over by the time it is read is noise.
    var remaining: String? {
        if kind == .removing { return nil }
        guard done >= 3, total > done, elapsed > 1 else { return nil }
        let perCell = elapsed / Double(done)
        let left = perCell * Double(total - done)
        if left < 60 { return "under a minute left" }
        if left < 3600 { return "about \(Int((left / 60).rounded())) min left" }
        return String(format: "about %.1f h left", left / 3600)
    }
}

/// One bake, as the shell sees it.
///
/// The core runs the phases on a thread of its own and this polls a snapshot
/// off the display link's readout tick. No callback crosses back out.
final class ChartBakeJob {
    private var handle: OpaquePointer?
    private let started = Date()
    private var name = ""
    private var poll: Timer?

    /// Called on the main queue whenever the count moves.
    var onProgress: ((BakeProgress) -> Void)?

    var cancelled: Bool { handle == nil ? false : cancelledFlag }
    private var cancelledFlag = false

    func cancel() {
        cancelledFlag = true
        if let handle { lookout_bake_cancel(handle) }
    }

    fileprivate func setName(_ n: String) { name = n }

    /// Take the core's job and start reporting. The job is freed when it ends.
    fileprivate func adopt(_ h: OpaquePointer, completion: @escaping (Bool) -> Void) {
        handle = h
        // The core coalesces no reports, so the rate is set here. A 7,000
        // cell import would otherwise lay out the panel 7,000 times.
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let h = self.handle else { timer.invalidate(); return }
                var p = lookout_bake_progress()
                lookout_bake_poll(h, &p)
                self.onProgress?(BakeProgress(
                    kind: .importing,
                    done: Int(p.done),
                    total: Int(p.total),
                    name: self.name,
                    elapsed: Date().timeIntervalSince(self.started)))
                guard p.running == 0 else { return }
                timer.invalidate()
                self.poll = nil
                self.handle = nil
                let ok = p.ok != 0
                // Freeing joins the worker, which has already finished.
                lookout_bake_free(h)
                completion(ok)
            }
        }
    }
}

/// What has to happen to one file, as `lookout_prepare` names it: a cell is
/// parsed and portrayed, a sheet is decoded and warped, and a lift only comes
/// out of the archive.
private func bakeItem(_ c: ScannedCell) -> lookout_prepare {
    switch c.kind {
    case .source:       return LOOKOUT_PREPARE_CELL
    case .rasterSource: return LOOKOUT_PREPARE_SHEET
    default:            return LOOKOUT_PREPARE_LIFT
    }
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
    static func deleteDerived(_ path: String, progress: ((BakeProgress) -> Void)? = nil) -> Bool {
        guard isDerived(path), path != chartsRoot, let root = chartsRoot else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }

        // Rename first, delete behind. Removing a set runs on the main thread,
        // and a 7,224-chart library is 36,000 files: measured at 3.7 seconds of
        // disk work, which the mariner sees as the app hanging. The rename is
        // one atomic step, so the charts are gone from where anything looks for
        // them before this returns, and a set added straight back writes into a
        // fresh directory instead of racing the delete.
        let trash = (root as NSString).appendingPathComponent(trashPrefix + UUID().uuidString)
        do {
            try fm.moveItem(atPath: path, toPath: trash)
        } catch {
            // Nowhere to rename it to. Still not on this thread.
            DispatchQueue.global(qos: .utility).async { try? fm.removeItem(atPath: path) }
            return true
        }
        DispatchQueue.global(qos: .utility).async { emptyAndRemove(trash, progress: progress) }
        return true
    }

    /// Delete `dir`, a chart at a time, saying where it has got to.
    ///
    /// The count is the mariner's own unit: the bake writes a directory per
    /// chart, so removing one is a chart gone, and the panel counts the same
    /// things coming out that it counted going in. Finding them costs one
    /// listing, not a walk of all 36,000 files.
    private static func emptyAndRemove(_ dir: String, progress: ((BakeProgress) -> Void)?) {
        let fm = FileManager.default
        // Descend past any skeleton the source's own shape left behind — an
        // archive's charts arrive under ENC_ROOT — so the count is charts and
        // not the one directory holding them.
        var level = dir
        while true {
            let kids = (try? fm.contentsOfDirectory(atPath: level)) ?? []
            guard kids.count == 1 else { break }
            let only = (level as NSString).appendingPathComponent(kids[0])
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: only, isDirectory: &isDir), isDir.boolValue else { break }
            level = only
        }

        let charts = (try? fm.contentsOfDirectory(atPath: level)) ?? []
        let started = Date()
        var last = Date.distantPast
        var done = 0
        func post(_ force: Bool) {
            let now = Date()
            guard force || now.timeIntervalSince(last) >= 0.2 else { return }
            last = now
            let p = BakeProgress(kind: .removing, done: done, total: charts.count,
                                 name: (dir as NSString).lastPathComponent,
                                 elapsed: now.timeIntervalSince(started))
            DispatchQueue.main.async { progress?(p) }
        }
        post(true)
        for c in charts {
            try? fm.removeItem(atPath: (level as NSString).appendingPathComponent(c))
            done += 1
            post(false)
        }
        // Whatever is left: the skeleton above, and anything the listing missed.
        try? fm.removeItem(atPath: dir)
        done = charts.count
        post(true)
        DispatchQueue.main.async { progress?(BakeProgress(kind: .removing, done: charts.count,
                                                          total: charts.count, name: "")) }
    }

    /// The name a chart directory takes while it is being thrown away. Dotted
    /// so it cannot be read as a set's own directory, and unique so two
    /// removals cannot collide.
    private static let trashPrefix = ".removing-"

    /// Throw away what a previous run renamed but did not finish deleting.
    /// Without this, quitting mid-delete leaves gigabytes on the disk that
    /// nothing will ever mention again.
    static func sweepTrash() {
        guard let root = chartsRoot else { return }
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for n in (try? fm.contentsOfDirectory(atPath: root)) ?? []
            where n.hasPrefix(trashPrefix) {
                try? fm.removeItem(atPath: (root as NSString).appendingPathComponent(n))
            }
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
        let todo = cells.filter(\.needsPrepare)
        guard !todo.isEmpty else {
            completion(outDir)
            return false
        }

        // Every string the core reads has to outlive the call, so they are
        // copied once here and freed at the end of it.
        var cs: [UnsafeMutablePointer<CChar>] = []
        defer { cs.forEach { free($0) } }
        func dup(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            cs.append(p)
            return UnsafePointer(p)
        }

        // The CORE decides the order: coarse band first, sheets after the
        // survey, a lift last.
        var items = todo.map {
            lookout_bake_item(path: dup($0.path), name: dup($0.name),
                              band: Int32($0.band), work: bakeItem($0))
        }
        items.withUnsafeMutableBufferPointer { lookout_bake_order($0.baseAddress, $0.count) }

        // And where each one lands. The layout has teeth in it, so it is the
        // core's rule rather than four copies of it.
        var ins: [UnsafePointer<CChar>?] = []
        var outs: [UnsafePointer<CChar>?] = []
        for item in items {
            var buf = [CChar](repeating: 0, count: 4096)
            var one = item
            let n = buf.withUnsafeMutableBufferPointer { b in
                lookout_bake_output_path(outDir, sourceDir, &one, b.baseAddress, b.count)
            }
            guard n > 0 else { continue }
            let path = String(cString: buf)
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent),
                withIntermediateDirectories: true)
            ins.append(item.path)
            outs.append(dup(path))
        }
        guard ins.count == items.count else {
            completion(nil)
            return false
        }

        // Kind-contiguous after the order, the shape the phases take.
        let cellCount = items.prefix { $0.work == LOOKOUT_PREPARE_CELL }.count
        let sheetCount = items[cellCount...].prefix { $0.work == LOOKOUT_PREPARE_SHEET }.count
        let liftCount = items.count - cellCount - sheetCount

        job.setName((sourceDir as NSString).lastPathComponent)
        let started = ins.withUnsafeBufferPointer { i in
            outs.withUnsafeBufferPointer { o in
                lookout_bake_start(sourceDir, i.baseAddress, o.baseAddress,
                                   cellCount, sheetCount, liftCount,
                                   ChartScan.isArchive(sourceDir) ? 1 : 0)
            }
        }
        guard let started else {
            completion(nil)
            return false
        }
        // A cancelled bake is not a failure. Whatever landed is a usable
        // library, so the caller still gets the directory.
        job.adopt(started) { ok in completion(ok ? outDir : nil) }
        return true
    }
}
