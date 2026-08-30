//  AppModel+Pick.swift — the pick report, the search, and the scale entry.
//
//  The order and the filtering of a pick belong to the core
//  (lookout_pick_ranked), so the shells cannot drift apart on what a pick
//  reports. This decides where the report stands and how far the chart lifts to
//  clear it.

import Foundation

@MainActor
extension AppModel {
    // MARK: - Search: coordinate go-to (feature/place search deferred)

    /// Parse the search text as a coordinate and recenter. Returns true if it was
    /// a recognizable coordinate (so the UI can clear/collapse results).
    @discardableResult
    func submitSearch() -> Bool {
        guard let controller, let coord = CoordinateParser.parse(searchText) else { return false }
        let cur = controller.currentView
        // Keep the current zoom & rotation; a fresh chart-less view uses a sensible
        // harbor-ish zoom.
        let zoom = cur.zoom > 0 ? cur.zoom : 12
        controller.setView(lookout_view(lon: coord.lon, lat: coord.lat,
                                        zoom: zoom, rotation_deg: cur.rotation_deg))
        return true
    }

    /// Show a pick report for `results` at `point`. An empty result closes it:
    /// a tap on bare water is how a mariner dismisses the report.
    ///
    /// The order and the filtering belong to the core (lookout_pick_ranked), so
    /// the shells cannot drift apart on what a pick reports.
    func showPick(_ results: [PickFeature], at point: CGPoint) {
        pickResults = results
        pickPoint = results.isEmpty ? nil : point
        pickIndex = 0
        pickGeo = results.isEmpty ? nil : controller?.geo(atPoint: point)
        pickAnchor = pickPoint
        // A sheet covers part of the chart, so the object can fall under it.
        // Lift the chart until the mark clears the sheet, and move the mark
        // with it. Only a sheet needs this. A callout stands over its object
        // and does not hide it.
        pickLift = 0
        if let p = pickPoint, let lift = sheetLift(for: p), lift > 0 {
            controller?.panRevealingPick(dxPt: 0, dyPt: -lift)
            pickPoint = CGPoint(x: p.x, y: p.y - lift)
            pickGeo = controller?.geo(atPoint: pickPoint!)
            pickAnchor = pickPoint
            pickLift = lift
        }
        // The screenshot protocol's view of a pick: where, and what came
        // back. What a pick MISSES is diagnosed from here.
        if ProcessInfo.processInfo.environment["LOOKOUT_HITMAP"] != nil {
            let classes = results.map(\.cls).joined(separator: ",")
            lkLog(String(format: "[pick] at (%.0f, %.0f) -> [%@]", point.x, point.y, classes))
        }
    }

    func closePick() {
        // Put the chart back where the mariner left it (§2.5). This undoes
        // only the lift the app made.
        if pickLift != 0 {
            controller?.panRevealingPick(dxPt: 0, dyPt: pickLift)
            pickLift = 0
        }
        pickResults = []
        pickPoint = nil
        pickGeo = nil
        pickAnchor = nil
        pickIndex = 0
    }

    /// How far the chart must rise for a mark at `point` to clear the bottom
    /// sheet. Returns nil when the view does not use a sheet.
    ///
    /// The test is the report's body, not the device, because the body
    /// decides what covers the object. The sheet is the narrow-screen body,
    /// so this is the phone in practice. Only the iOS chart view sets
    /// `chromeSize`, so a narrow Mac window does not move.
    private func sheetLift(for point: CGPoint) -> CGFloat? {
        guard chromeSize.width > 0, chromeSize.height > 0 else { return nil }
        guard OverlayLayer.pickForm(for: chromeSize) == .bottomSheet else { return nil }
        let sheetTop = chromeSize.height - OverlayLayer.bottomSheetSize(in: chromeSize).height
        // The whole mark must clear the sheet's edge, not just its centre.
        let clear = PickMarker.size / 2 + Chrome.gap
        return max(0, (point.y + clear) - sheetTop)
    }

    /// A point at a fraction of the view. The hooks below have no pointer to
    /// press with, so they name a fraction instead.
    private func viewPoint(fx: Double, fy: Double) -> CGPoint? {
        guard let centre = pickCentreHint else { return nil }
        return CGPoint(x: centre.x * 2 * fx, y: centre.y * 2 * fy)
    }

    /// A hook-driven pick at a fraction of the view: the screenshot protocol's
    /// way of picking away from the centre, LOOKOUT_SHOW=pick:0.5x0.85.
    func pickAt(fx: Double, fy: Double) {
        guard let controller, let p = viewPoint(fx: fx, fy: fy),
              let g = controller.geo(atPoint: p) else { return }
        showPick(controller.pick(lon: g.lon, lat: g.lat), at: p)
    }

    /// Raise the chart menu at a fraction of the view, as a right-click there
    /// would: LOOKOUT_SHOW=menu:0.5x0.5.
    func showChartMenu(fx: Double, fy: Double) {
        guard let p = viewPoint(fx: fx, fy: fy) else { return }
        openChartMenu(at: p)
    }

    /// Drop a marker at a fraction of the view: LOOKOUT_SHOW=marker:0.45x0.5.
    func showDropMarker(fx: Double, fy: Double) {
        guard let c = controller, let p = viewPoint(fx: fx, fy: fy),
              let g = c.geo(atPoint: p) else { return }
        c.dropMarker(lon: g.lon, lat: g.lat)
    }

    /// Open the rename field on the newest mark: LOOKOUT_SHOW=rename.
    func showRenameNewestMarker() {
        guard let mark = controller?.markers().last else { return }
        beginRename(mark)
    }

    /// Run a cursor pick at the view centre. A tap on the chart runs the same
    /// pick; the screenshot hook has no cursor to tap with.
    func pickAtCentre() {
        guard let controller else { return }
        guard let point = pickCentreHint else { return }
        showPick(controller.pick(lon: centerLon, lat: centerLat), at: point)
    }

    var schemeName: String {
        switch scheme { case 1: return "Dusk"; case 2: return "Night"; default: return "Day" }
    }

    // MARK: - Go to a scale (tap the 1:N readout)
}
