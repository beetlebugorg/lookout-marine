//  ChartController+Raster.swift — the picture charts, and the charts by link.
//
//  A raster chart is attached to a lookout handle, so every open replays them.
//  Which set is DRAWN is the mariner's, and the engine's own election runs
//  against that, which is what restoreRasterShown settles.
//
//  A chart by link is the core's from end to end: it probes the link, inlines
//  TileJSON sources, fetches the sprite packs and keeps the list. These are the
//  calls, and ChartLinkFetch is the door they fetch through.

import Foundation

@MainActor
extension ChartController {
    // MARK: - Convenience live toggles

    func cycleScheme()        { guard let h = handle else { return }; lookout_cycle_scheme(h); kick(); pushReadouts() }
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
    // MARK: - Charts by link

    /// Add a chart by link. The core resolves it through this shell's fetcher
    /// and, on success, keeps it and selects it. Non-blocking: what happened
    /// arrives in the snapshot below.
    func addChartLink(_ link: String) {
        guard let h = handle else { return }
        link.withCString { lookout_chart_link_add(h, $0) }
        kick()
    }

    /// Draw one of the carried charts, or nil for Lookout's own.
    func selectChartLink(_ url: String?) {
        guard let h = handle else { return }
        if let url {
            url.withCString { lookout_chart_link_select(h, $0) }
        } else {
            lookout_chart_link_select(h, nil)
        }
        kick()
    }

    func removeChartLink(_ url: String) {
        guard let h = handle else { return }
        url.withCString { lookout_chart_link_remove(h, $0) }
        kick()
    }

    func refreshChartLink(_ url: String) {
        guard let h = handle else { return }
        url.withCString { lookout_chart_link_refresh(h, $0) }
        kick()
    }

    /// Hand the mariner's old UserDefaults list to the core, once. See
    /// AppModel.migrateChartLinks.
    func importChartLinks(_ json: String) {
        guard let h = handle else { return }
        json.withCString { lookout_chart_links_import(h, $0) }
    }

    /// Everything the chart list shows, or nil when nothing changed since the
    /// last poll. The flag has ONE consumer, so this is called from exactly one
    /// place: pushReadouts.
    func chartLinksSnapshot() -> String? {
        guard let h = handle, lookout_chart_links_changed(h) != 0 else { return nil }
        guard let c = lookout_chart_links_json(h) else { return nil }
        defer { lookout_string_free(c) }
        return String(cString: c)
    }

    /// Is a publisher's style the one being drawn?
    var altChartStyleActive: Bool {
        guard let h = handle else { return false }
        return lookout_alt_chart_style_active(h) != 0
    }
    func chartHidden() -> Bool { guard let h = handle else { return false }; return lookout_chart_hidden(h) != 0 }
    /// Every set, with whether it is in view and whether it is drawn. This is
    /// what the pill's menu is built from — a mariner has to see what they
    /// carry, not guess at it through a cycle.
    ///
    /// `shown` is the set's own state, not "drawn over this view": that is what
    /// gets saved, and a coast off screen still has an answer.
    struct RasterSet: Identifiable, Equatable {
        let id: Int
        let name: String
        let inView: Bool
        let shown: Bool
    }
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
        lkLog("raster: nothing drawn and no survey aboard — showing \(pick.name)")
    }

    /// How many vector charts are open. Zero is a library of pictures alone.
    func chartCount() -> Int {
        guard let h = handle else { return 0 }
        return Int(lookout_charts_count(h))
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
    func toggleText()         { guard let h = handle else { return }; lookout_toggle_text(h); kick() }
    func toggleSoundings()    { guard let h = handle else { return }; lookout_toggle_soundings(h); kick() }
    func toggleOtherCategory(){ guard let h = handle else { return }; lookout_toggle_other_category(h); kick() }
    func nudgeSafetyContour(_ d: Double) { guard let h = handle else { return }; lookout_nudge_safety_contour(h, d); kick() }
    func adjustSize(_ f: Float) { guard let h = handle else { return }; lookout_adjust_size(h, f); kick() }

    var scaleDenominator: Double {
        guard let h = handle else { return 0 }
        return lookout_scale_denominator(h)
    }

    /// A file a picked feature points at, by the cell it came from and the name
    /// the attribute carries. The bytes belong to the engine and stay valid
    /// while the chart is open, so they are copied here.
    func auxFile(cell: String, named name: String) -> (data: Data, mime: String)? {
        guard let h = handle else { return nil }
        var bytes: UnsafePointer<UInt8>?
        var len = 0
        var mime: UnsafePointer<CChar>?
        lookout_aux_file(h, cell, name, &bytes, &len, &mime)
        guard let bytes, len > 0 else { return nil }
        return (Data(bytes: bytes, count: len),
                mime.map { String(cString: $0) } ?? "application/octet-stream")
    }
}
