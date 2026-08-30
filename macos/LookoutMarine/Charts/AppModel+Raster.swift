//  AppModel+Raster.swift — the picture charts under the survey.
//
//  Installed, switched on and off, and which set is DRAWN. The engine owns the
//  election (showing one set turns off the sets covering the same water), so
//  what it says after a change is the only account that can be right.

import Foundation

@MainActor
extension AppModel {
    /// Scheme changes from the MENU must persist like ones from the settings
    /// form (the form saves in its own apply path).
    func cycleScheme() {
        guard let c = controller else { return }
        c.cycleScheme()
        MarinerSettings.save(c.getMariner())
    }
    /// Hide or show the vector chart, leaving the picture beneath it.
    func toggleChart() {
        guard let c = controller else { return }
        c.toggleChart()
        chartHidden = c.chartHidden()
        chartHiddenSaved = chartHidden
        Store.shared.set(chartHidden, chartHiddenKey)
    }

    /// Install the raster charts the mariner chose. Files that will not open are reported
    /// together rather than one alert at a time — picking a folder of twenty and
    /// being asked twenty times would be unusable.
    func addRasterCharts(_ paths: [String]) {
        guard let c = controller else { return }
        var failed: [String] = []
        for p in paths where !rasterPaths.contains(p) {
            if c.addRaster(p) {
                rasterPaths.append(p)
            } else {
                failed.append((p as NSString).lastPathComponent)
            }
        }
        Store.shared.set(rasterPaths, rasterKey)

        // Read the whole state back, not just the name. The pill is built from
        // rasterSets and rasterAvailable, and those reach it through the frame
        // readouts — which never come while the chart sits idle behind the open
        // panel. Without this, adding a chart over the water you are looking at
        // appeared to do nothing at all.
        refreshRasterState()

        // Draw what was just added, if it covers this view. The mariner picked
        // these files deliberately while looking at this water; showing them is
        // the obvious answer, and the pill takes them back in one click.
        if let added = paths.last(where: { rasterPaths.contains($0) }) {
            let name = AppModel.providerLabel(added)
            if let set = rasterSets.first(where: { $0.name == name && $0.inView }) {
                selectRasterSet(set.id)
            }
        }

        if !failed.isEmpty {
            openError = failed.count == 1
                ? "Couldn't open \(failed[0]).\nIt may not be a raster chart tile57 reads."
                : "Couldn't open \(failed.count) of \(paths.count) files:\n" + failed.joined(separator: "\n")
        }
    }

    /// Pull every published raster field off the controller at once. Anything
    /// that changes the set list or the selection outside a frame must call
    /// this: the readouts only run while the chart renders.
    func refreshRasterState() {
        guard let c = controller else { return }
        rasterName = c.rasterName()
        rasterActive = c.rasterActiveIndex()
        rasterSets = c.rasterSets()
        rasterAvailable = c.rasterAvailableName()
        chartHidden = c.chartHidden()
        saveRasterShown()
    }

    /// Write down which sets are drawn. Everything that can move the selection
    /// comes through refreshRasterState, so this is the one place it is saved:
    /// the pill's menu, the Chart menu, the cycle key, and switching a chart off
    /// in Settings, which can move the selection on its own.
    ///
    /// Read back from the engine rather than tracked here. The engine owns the
    /// election — showing one set turns off the sets covering the same water —
    /// so what it says after the change is the only account that can be right.
    ///
    /// Sets that are not installed this launch keep their entry: a mariner who
    /// unplugs the drive holding one has not changed their mind about it.
    private func saveRasterShown() {
        guard let sets = controller?.rasterSets(), !sets.isEmpty else { return }
        var hidden = rasterHidden
        for s in sets {
            if s.shown { hidden.remove(s.name) } else { hidden.insert(s.name) }
        }
        guard hidden != rasterHidden else { return }
        rasterHidden = hidden
        Store.shared.set(Array(hidden), rasterHiddenKey)
    }

    /// Draw one set, or none for -1.
    func selectRasterSet(_ i: Int) {
        guard let c = controller else { return }
        c.rasterSelect(i)
        refreshRasterState()
    }

    /// Is any file of this set on?
    func rasterGroupOn(_ paths: [String]) -> Bool {
        paths.contains { !rasterOff.contains($0) }
    }

    /// Turn a whole set on or off. Off keeps every file installed.
    func setRasterGroupEnabled(_ paths: [String], _ on: Bool) {
        for p in paths { setRasterEnabled(p, on) }
    }

    /// Turn one raster chart on or off. It stays installed either way.
    func setRasterEnabled(_ path: String, _ on: Bool) {
        if on { rasterOff.remove(path) } else { rasterOff.insert(path) }
        Store.shared.set(Array(rasterOff), rasterOffKey)
        controller?.setRasterEnabled(path, on)
        // Read the selection back: switching off the last file of the drawn set
        // moves the selection, and the pill must not keep naming a chart that
        // is off. Settings can be open while the chart is idle, so this cannot
        // wait for the next frame's readouts.
        refreshRasterState()
    }

    /// Remove one source. The engine cannot drop a source from a live handle,
    /// so this takes effect the next time a chart opens.
    func removeRasterChart(_ path: String) {
        rasterPaths.removeAll { $0 == path }
        rasterOff.remove(path)
        Store.shared.set(rasterPaths, rasterKey)
        Store.shared.set(Array(rasterOff), rasterOffKey)
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

    /// Forget every installed source. The engine has no remove yet, so this
    /// takes effect on the next chart open — say so where it is offered.
    ///
    /// The switched-off and not-drawn lists go with it. They are keyed by path
    /// and set name, so leaving them behind means the same file added again
    /// months later comes back switched off with nothing on screen to say why.
    func clearRasterCharts() {
        rasterPaths.removeAll()
        rasterOff.removeAll()
        rasterHidden.removeAll()
        Store.shared.set(rasterPaths, rasterKey)
        Store.shared.set(Array(rasterOff), rasterOffKey)
        Store.shared.set(Array(rasterHidden), rasterHiddenKey)
    }

    /// Step to the next raster chart set, with "no picture" as one position — so the
    /// same control also reaches the full chart.
    func cycleRaster() {
        guard let c = controller else { return }
        // Nothing installed: the cycle has nowhere to go, so offer the picker
        // rather than letting the key press do nothing at all.
        if rasterPaths.isEmpty {
            #if os(macOS)
            presentRasterPanel()
            #endif
            return
        }
        c.cycleRaster()
        // The whole state, not just the name: the cycle moves which set is drawn,
        // and that has to reach the pill's mark and the saved selection at once
        // rather than waiting on the next frame's readouts.
        refreshRasterState()
    }
    /// Set the color scheme directly (0 day / 1 dusk / 2 night).
    func setScheme(_ s: Int) {
        guard let c = controller else { return }
        var m = c.getMariner()
        m.scheme = tile57_scheme(UInt32(s))
        c.setMariner(m)
        MarinerSettings.save(m)
    }
    func toggleText() { controller?.toggleText() }
    func toggleSoundings() { controller?.toggleSoundings() }
    func toggleOtherCategory() { controller?.toggleOtherCategory() }
}
