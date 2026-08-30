//  RasterModel.swift — the picture charts under the survey.
//
//  Installed, switched on and off, and which set is DRAWN. The engine owns the
//  election (showing one set turns off the sets covering the same water), so
//  what it says after a change is the only account that can be right.

import Foundation

@MainActor
@Observable
final class RasterModel {
    /// The drawn set's name, or "" for no picture. Shown at all times while a
    /// picture is on: the chart drops its opaque water and land fills to let
    /// the picture through, and the mariner must never mistake that display
    /// for the full chart.
    var name = ""
    /// Every raster chart file the mariner has installed, in the order added.
    /// The engine replays these into each newly opened chart, so a raster
    /// chart survives switching charts and relaunching.
    var paths: [String] = []
    /// True only while a picture is really beneath the view and the chart is
    /// therefore drawing without its opaque fills. The HUD badge keys off this,
    /// not off the selected set — a badge that appeared whenever a raster chart
    /// was merely installed would claim the chart was reduced when it was not.
    var inView = false
    /// The set that covers this view, DRAWN OR NOT. Empty when none does. The
    /// pill appears only when this is set: a control that is useless here is
    /// noise, and one that says nothing about what is available teaches nothing.
    var available = ""
    /// The installed charts the mariner has switched OFF. They stay installed:
    /// these are half-gigabyte downloads, and carrying four providers for one
    /// coast means wanting three of them quiet, not deleted.
    var off: Set<String> = []
    /// The sets the mariner has turned off at the pill, by set name. Read at
    /// launch and applied before the first frame; written whenever the drawn
    /// set changes. Without it the engine's own rule wins every launch —
    /// adding a source draws it — and a chart switched off comes back.
    ///
    /// Not the same thing as `off`. Off means "installed and quiet" and takes
    /// a set out of the pill's list entirely; this is the pill's own choice of
    /// which picture covers this water, and a set that is not drawn is still
    /// offered.
    var hidden: Set<String> = []
    /// True while the vector chart is hidden and only the picture shows.
    var chartHidden = false
    /// Was the ENC hidden over the picture when the app last quit? Applied at
    /// open; `chartHidden` is the live state.
    var chartHiddenSaved = false
    /// Every set, with whether it is in view. The pill's menu is built from it.
    var sets: [RasterSet] = []
    /// The drawn set's index, or -1.
    var active = -1

    weak var engine: (any RasterEngine)?

    /// Persisted, because a chart set is a half-gigabyte download the mariner
    /// picked deliberately — asking again every launch would be its own bug.
    static let pathsKey = "lookout.rastercharts"
    static let offKey = "lookout.rastercharts.off"
    static let hiddenKey = "lookout.rastercharts.hidden"
    static let chartHiddenKey = "lookout.chart.hidden"

    init() {
        // Drop anything that has since been deleted or unplugged, so a stale
        // entry never becomes an error the mariner has to dismiss at every
        // launch.
        paths = (Store.shared.strings(Self.pathsKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
        off = Set(Store.shared.strings(Self.offKey) ?? [])
        hidden = Set(Store.shared.strings(Self.hiddenKey) ?? [])
        chartHiddenSaved = Store.shared.bool(Self.chartHiddenKey)
    }

    /// Hide or show the vector chart, leaving the picture beneath it.
    func toggleChart() {
        guard let c = engine else { return }
        c.toggleChart()
        chartHidden = c.chartHidden()
        chartHiddenSaved = chartHidden
        Store.shared.set(chartHidden, Self.chartHiddenKey)
    }

    /// Install the raster charts the mariner chose, and return the sentence for
    /// the ones that would not open, if any.
    ///
    /// Reported together rather than one alert at a time — picking a folder of
    /// twenty and being asked twenty times would be unusable.
    @discardableResult
    func add(_ picked: [String]) -> String? {
        guard let c = engine else { return nil }
        var failed: [String] = []
        for p in picked where !paths.contains(p) {
            if c.addRaster(p) {
                paths.append(p)
            } else {
                failed.append((p as NSString).lastPathComponent)
            }
        }
        Store.shared.set(paths, Self.pathsKey)

        // Read the whole state back, not just the name. The pill is built from
        // the set list and what is available, and those reach it through the
        // frame readouts — which never come while the chart sits idle behind
        // the open panel. Without this, adding a chart over the water you are
        // looking at appeared to do nothing at all.
        refresh()

        // Draw what was just added, if it covers this view. The mariner picked
        // these files deliberately while looking at this water; showing them is
        // the obvious answer, and the pill takes them back in one click.
        if let added = picked.last(where: { paths.contains($0) }) {
            let label = Self.providerLabel(added)
            if let set = sets.first(where: { $0.name == label && $0.inView }) {
                select(set.id)
            }
        }

        guard !failed.isEmpty else { return nil }
        return failed.count == 1
            ? "Couldn't open \(failed[0]).\nIt may not be a raster chart tile57 reads."
            : "Couldn't open \(failed.count) of \(picked.count) files:\n" + failed.joined(separator: "\n")
    }

    /// Read the frame's values off the chart. Only what changed is assigned:
    /// see ReadoutsModel.pull.
    func pull() {
        guard let e = engine else { return }
        let over = e.rasterOverChart()
        if inView != over { inView = over }
        let hidden = e.chartHidden()
        if chartHidden != hidden { chartHidden = hidden }
        let avail = e.rasterAvailableName()
        if available != avail { available = avail }
        let live = e.rasterSets()
        if sets != live { sets = live }
        let i = e.rasterActiveIndex()
        if active != i { active = i }
        let drawn = e.rasterName()
        if name != drawn { name = drawn }
    }

    /// Read every field back and write down which sets are drawn. Anything
    /// that changes the set list or the selection outside a frame must call
    /// this: the frame readouts only run while the chart renders.
    func refresh() {
        pull()
        saveShown()
    }

    /// Write down which sets are drawn. Everything that can move the selection
    /// comes through `refresh`, so this is the one place it is saved: the
    /// pill's menu, the Chart menu, the cycle key, and switching a chart off in
    /// Settings, which can move the selection on its own.
    ///
    /// Read back from the engine rather than tracked here. The engine owns the
    /// election — showing one set turns off the sets covering the same water —
    /// so what it says after the change is the only account that can be right.
    ///
    /// Sets that are not installed this launch keep their entry: a mariner who
    /// unplugs the drive holding one has not changed their mind about it.
    private func saveShown() {
        guard let live = engine?.rasterSets(), !live.isEmpty else { return }
        var next = hidden
        for s in live {
            if s.shown { next.remove(s.name) } else { next.insert(s.name) }
        }
        guard next != hidden else { return }
        hidden = next
        Store.shared.set(Array(next), Self.hiddenKey)
    }

    /// Draw one set, or none for -1.
    func select(_ i: Int) {
        guard let c = engine else { return }
        c.rasterSelect(i)
        refresh()
    }

    /// Is any file of this set on?
    func groupOn(_ paths: [String]) -> Bool {
        paths.contains { !off.contains($0) }
    }

    /// Turn a whole set on or off. Off keeps every file installed.
    func setGroupEnabled(_ paths: [String], _ on: Bool) {
        for p in paths { setEnabled(p, on) }
    }

    /// Turn one raster chart on or off. It stays installed either way.
    func setEnabled(_ path: String, _ on: Bool) {
        if on { off.remove(path) } else { off.insert(path) }
        Store.shared.set(Array(off), Self.offKey)
        engine?.setRasterEnabled(path, on)
        // Read the selection back: switching off the last file of the drawn set
        // moves the selection, and the pill must not keep naming a chart that
        // is off. Settings can be open while the chart is idle, so this cannot
        // wait for the next frame's readouts.
        refresh()
    }

    /// Remove one source. The engine cannot drop a source from a live handle,
    /// so this takes effect the next time a chart opens.
    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        off.remove(path)
        Store.shared.set(paths, Self.pathsKey)
        Store.shared.set(Array(off), Self.offKey)
    }

    /// Forget every installed source. The engine has no remove yet, so this
    /// takes effect on the next chart open — say so where it is offered.
    ///
    /// The switched-off and not-drawn lists go with it. They are keyed by path
    /// and set name, so leaving them behind means the same file added again
    /// months later comes back switched off with nothing on screen to say why.
    func clear() {
        paths.removeAll()
        off.removeAll()
        hidden.removeAll()
        Store.shared.set(paths, Self.pathsKey)
        Store.shared.set(Array(off), Self.offKey)
        Store.shared.set(Array(hidden), Self.hiddenKey)
    }

    /// Step to the next set, with "no picture" as one position — so the same
    /// control also reaches the full chart. False when nothing is installed and
    /// the caller should offer the picker instead.
    @discardableResult
    func cycle() -> Bool {
        guard let c = engine, !paths.isEmpty else { return false }
        c.cycleRaster()
        // The whole state, not just the name: the cycle moves which set is
        // drawn, and that has to reach the pill's mark and the saved selection
        // at once rather than waiting on the next frame's readouts.
        refresh()
        return true
    }

    /// What to call the set a file belongs to — mirrors the engine's rule.
    ///
    /// A community MBTiles names its provider, and that is what a mariner
    /// chooses between. A baked sheet does not: `tile57 bake` writes one
    /// directory per sheet under a bake root, and a bundle holds hundreds, so
    /// they belong to the bake they came from.
    nonisolated static func providerLabel(_ path: String) -> String {
        let ns = path as NSString
        let base = ns.lastPathComponent
        for k in ["ArcGIS", "Bing", "Google", "Navionics", "ESRI", "Esri",
                  "CMap", "C-Map", "Sentinel", "NAIP", "OSM", "Imagery"] {
            if base.range(of: k, options: .caseInsensitive) != nil { return k }
        }
        let stem = (base as NSString).deletingPathExtension
        if base.lowercased().hasSuffix(".pmtiles") {
            let dir = ns.deletingLastPathComponent
            if (dir as NSString).lastPathComponent == stem {
                let root = ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if !root.isEmpty { return root }
            }
        }
        return stem.isEmpty ? base : stem
    }
}
