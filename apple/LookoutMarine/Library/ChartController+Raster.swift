//  ChartController+Raster.swift — the picture charts under the survey.
//
//  A raster chart is attached to a lookout handle, so every open replays them.
//  Which set is DRAWN is the mariner's, and the engine's own election runs
//  against that, which is what restoreRasterShown settles.

import Foundation

@MainActor
extension ChartController {
    /// Step to the next raster chart set, or to "no picture" after the last one. The
    /// camera does not move and the chart scene is not rebuilt unless the
    /// picture turns on or off, so a mariner comparing two providers over a reef
    /// keeps their fix.
    func cycleRaster()        { guard let h = handle else { return }; lookout_raster_cycle(h); kick(); pushReadouts() }
    /// The active raster chart set's name, or "" for no picture. A shell MUST show
    /// this: with a picture active the chart drops its opaque water and land
    /// fills, which is a real reduction in what it is telling the mariner.
    func rasterName() -> String {
        guard let h = handle else { return "" }
        var len = 0
        guard let p = lookout_raster_active_name(h, &len), len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }
    /// Hide or show the vector chart. The picture beneath it stays.
    func toggleChart()        { guard let h = handle else { return }; lookout_toggle_chart(h); kick(); pushReadouts() }
    func setChartHidden(_ hidden: Bool) { guard let h = handle else { return }; lookout_set_chart_hidden(h, hidden ? 1 : 0) }
    func chartHidden() -> Bool { guard let h = handle else { return false }; return lookout_chart_hidden(h) != 0 }
    /// Every set, with whether it is in view and whether it is drawn. This is
    /// what the pill's menu is built from — a mariner has to see what they
    /// carry, not guess at it through a cycle.
    ///
    func rasterSets() -> [RasterSet] {
        guard let h = handle else { return [] }
        let n = Int(lookout_raster_set_count(h))
        return (0..<n).map { i in
            var len = 0
            let p = lookout_raster_set_name(h, UInt32(i), &len)
            let name = (p != nil && len > 0)
                ? String(decoding: UnsafeRawBufferPointer(start: p!, count: len), as: UTF8.self) : ""
            return RasterSet(id: i, name: name,
                             inView: lookout_raster_set_in_view(h, UInt32(i)) != 0,
                             shown: lookout_raster_shown(h, UInt32(i)) != 0)
        }
    }
    func rasterActiveIndex() -> Int { guard let h = handle else { return -1 }; return Int(lookout_raster_active_index(h)) }
    func rasterSelect(_ i: Int) { guard let h = handle else { return }; lookout_raster_select(h, Int32(i)); kick(); pushReadouts() }

    /// Draw a set, or stop drawing it, by index and without reference to the
    /// camera. `rasterSelect` cannot do this: it answers for the view on screen,
    /// and the view a launch opens into is often nowhere near the set being
    /// restored. Showing still turns off the sets covering the same water.
    func rasterSetShown(_ i: Int, _ on: Bool) {
        guard let h = handle else { return }
        lookout_raster_set_shown(h, UInt32(i), on ? 1 : 0)
    }

    /// Put back which raster sets the mariner had drawn. Adding a source draws
    /// its set, which is right for a chart just picked and wrong for one being
    /// re-installed at launch, so every open has to correct it — and before the
    /// first frame, or a set the mariner switched off flashes on screen.
    ///
    /// Two passes. Hiding first and showing second is what keeps the election:
    /// where two providers cover one coast, the sources were added in an order
    /// that drew the first of them, so showing the mariner's pick before hiding
    /// its rival would leave the rival to turn the pick straight back off.
    func restoreRasterShown() {
        guard let hidden = model?.raster.hidden else { return }
        let sets = rasterSets()
        guard !sets.isEmpty else { return }
        for s in sets where hidden.contains(s.name) { rasterSetShown(s.id, false) }
        for s in sets where !hidden.contains(s.name) { rasterSetShown(s.id, true) }

        // With no survey open, the imagery IS the chart, and switching a set
        // off no longer means what it meant when it was said. The mariner hid
        // it to see the ENC underneath; with the ENC gone, obeying that leaves
        // them a blank sea and no way to read what they are looking at — so
        // the set covering this water comes back on. It is named in the pill
        // and one click from off again, which a blank screen is not.
        //
        // What they saved is NOT rewritten. This overrides the choice while
        // there is no survey to see under; add ENC charts back and the set
        // they hid is hidden again, which is what they asked for.
        guard chartCount() == 0 else { return }
        let here = rasterSets().filter(\.inView)
        guard !here.isEmpty, !here.contains(where: \.shown), let pick = here.first else { return }
        rasterSetShown(pick.id, true)
        lkLog("raster: nothing drawn and no survey installed — showing \(pick.name)")
    }

    /// Turn one raster chart on or off without removing it.
    @discardableResult
    func setRasterEnabled(_ path: String, _ on: Bool) -> Bool {
        guard let h = handle else { return false }
        return path.withCString { lookout_raster_set_enabled(h, $0, on ? 1 : 0) != 0 }
    }
    /// The set covering this view, drawn or not — so the pill can say a picture
    /// is here while it is off.
    func rasterAvailableName() -> String {
        guard let h = handle else { return "" }
        var len = 0
        guard let p = lookout_raster_available_name(h, &len), len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }
    /// Is a picture beneath THIS view?
    func rasterOverChart() -> Bool { guard let h = handle else { return false }; return lookout_raster_over_chart(h) != 0 }
    /// Open a raster chart (satellite imagery or another picture chart) the
    /// mariner supplied. The app offers no catalogue and no download.
    @discardableResult
    func addRaster(_ path: String) -> Bool {
        guard let h = handle else { return false }
        return path.withCString { lookout_raster_add(h, $0) != 0 }
    }
}
