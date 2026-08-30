//  OverlayModel.swift — everything that floats over the chart, anchored to a
//  place on it.
//
//  The pick report, the menu raised on the water, the marker rename field, the
//  pinned bubble and the hover tooltip. One at a time: raising any of them puts
//  the others away. Each is anchored to a chart position rather than to the
//  screen, so the render tick re-projects them all together — follow moves the
//  chart with no gesture behind it.
//
//  The order and the filtering of a pick belong to the core
//  (lookout_pick_ranked), so the shells cannot drift apart on what a pick
//  reports. This decides where the report stands and how far the chart lifts to
//  clear it.

import Foundation

@MainActor
@Observable
final class OverlayModel {
    /// The cursor pick: the features under the last tap, where it happened (in
    /// the chrome's coordinate space), and which one the report is showing.
    var pickResults: [PickFeature] = []
    var pickPoint: CGPoint?
    var pickIndex = 0
    /// Where on the CHART the pick was taken. The mark belongs to the object,
    /// not to the screen: follow moves the chart with no gesture behind it, so
    /// the mark is re-projected from this every frame.
    var pickGeo: (lon: Double, lat: Double)?
    /// Where the REPORT is docked: the mark's position when the pick was
    /// taken, and fixed for as long as the report is open. The panel's frame
    /// must not depend on anything the camera touches, or a chart sliding
    /// under follow re-lays it out every frame.
    var pickAnchor: CGPoint?
    /// Where a hook-driven pick should anchor its report. The chart view sets
    /// it to the centre of its bounds.
    var pickCentreHint: CGPoint?
    /// The chrome's size: the view inset by the safe area. This is the space
    /// the report is laid out in. The chart view sets it with the hint.
    /// `showPick` reads it to find the report's body and the sheet's edge.
    var chromeSize: CGSize = .zero
    /// How far `showPick` lifted the chart to clear the sheet. `closePick`
    /// puts the chart back by the same amount. Points, in the chrome's space.
    var pickLift: CGFloat = 0

    /// A picture from the pick report, shown over the chart at full size.
    struct Picture: Equatable {
        let name: String
        let data: Data
    }
    var picture: Picture?

    /// The menu raised at a point on the water. Every item acts on THIS point:
    /// not the map centre, and not where the cursor drifts to afterwards, so
    /// the coordinates are taken once, when the menu opens, and carried here.
    struct ChartMenu: Equatable {
        /// Where the menu stands, in the chrome's coordinate space.
        let at: CGPoint
        let lon: Double
        let lat: Double
        /// The mark under the press, when there is one. Over a marker the menu
        /// offers Rename and Remove in place of Drop.
        let marker: ChartController.Marker?
    }
    var chartMenu: ChartMenu?

    /// Which marker is being renamed, and where it is. The name being typed is
    /// `renamingText`.
    struct MarkerRename: Equatable {
        let id: UInt64
        let lon: Double
        let lat: Double
    }
    var renaming: MarkerRename?
    var renamingText = ""
    /// Where the rename field stands, re-projected every frame: it is anchored
    /// to its marker, not to the screen.
    var renamingPoint: CGPoint?

    /// The overlay object the mariner pinned, and where it draws in the
    /// chrome's coordinate space. One at a time.
    var pinned: OverlayPin?
    var pinnedPoint: CGPoint?
    /// What the plugin overlay says about the symbol under the pointer, and
    /// where the pointer is in the chrome's coordinate space. Both nil when the
    /// pointer is over nothing. Set by the chart view after a hover settles.
    var hover: OverlayHover?
    var hoverPoint: CGPoint?

    weak var controller: ChartController?

    // MARK: The pick report

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

    // MARK: The chart menu, and markers

    /// Raise the menu at a point on the chart, in the chrome's coordinate
    /// space. A pinned bubble goes: one thing at a time over the chart.
    func openChartMenu(at p: CGPoint) {
        guard let c = controller, let g = c.geo(atPoint: p) else { return }
        closePin()
        cancelRename()
        chartMenu = ChartMenu(at: p, lon: g.lon, lat: g.lat, marker: c.marker(atPoint: p))
    }

    func closeChartMenu() {
        if chartMenu != nil { chartMenu = nil }
    }

    /// "Pick report": the report for the point the menu was raised at.
    /// The report itself is unchanged; only how it is raised has.
    func chartMenuPick() {
        guard let m = chartMenu, let c = controller else { return }
        chartMenu = nil
        showPick(c.pick(lon: m.lon, lat: m.lat), at: m.at)
    }

    /// "Drop marker": placed at once, named by the core, and the menu closes.
    /// The drop never waits for typing: a mariner drops a mark one-handed on a
    /// moving boat, often to record something they have just seen.
    func chartMenuDropMarker() {
        guard let m = chartMenu, let c = controller else { return }
        chartMenu = nil
        c.dropMarker(lon: m.lon, lat: m.lat)
    }

    /// "Copy position": the point's coordinates in the mariner's own format,
    /// the one the readout, the deck log and the radio all use.
    func chartMenuCopyPosition() {
        guard let m = chartMenu else { return }
        chartMenu = nil
        Pasteboard.copy(CoordFormat.position(lat: m.lat, lon: m.lon))
    }

    func chartMenuRenameMarker() {
        guard let mark = chartMenu?.marker else { return }
        chartMenu = nil
        beginRename(mark)
    }

    func chartMenuRemoveMarker() {
        guard let mark = chartMenu?.marker, let c = controller else { return }
        chartMenu = nil
        _ = c.removeMarker(mark.id)
    }

    /// Open the rename field on a marker, with its current name in it.
    func beginRename(_ mark: ChartController.Marker) {
        renaming = MarkerRename(id: mark.id, lon: mark.lon, lat: mark.lat)
        renamingText = mark.name
        renamingPoint = controller?.screenPoint(forGeoLon: mark.lon, lat: mark.lat)
    }

    /// Return commits. An empty field keeps the old name, which the core
    /// decides, so every shell agrees on what an emptied field means.
    func commitRename() {
        guard let r = renaming else { return }
        controller?.renameMarker(r.id, to: renamingText)
        cancelRename()
    }

    /// Escape abandons.
    func cancelRename() {
        if renaming != nil { renaming = nil }
        if !renamingText.isEmpty { renamingText = "" }
        if renamingPoint != nil { renamingPoint = nil }
    }

    // MARK: The pinned bubble

    /// Pin an overlay object's bubble. It replaces any bubble already up, and
    /// a hover tooltip never shares the screen with one.
    func pin(_ p: OverlayPin) {
        hover = nil
        hoverPoint = nil
        pinned = p
        pinnedPoint = controller?.screenPoint(forGeoLon: p.lon, lat: p.lat)
    }

    func closePin() {
        if pinned != nil { pinned = nil }
        if pinnedPoint != nil { pinnedPoint = nil }
    }

    /// Show a place a plugin table row named: centre the chart on it and pin
    /// the bubble of whatever the plugin draws there. A row with no position
    /// never gets here.
    func revealOnChart(lon: Double, lat: Double) {
        guard let c = controller else { return }
        if let hit = c.reveal(lon: lon, lat: lat) { pin(hit) } else { closePin() }
    }

    // MARK: The screenshot protocol's hooks
    //
    // These have no pointer to press with, so they name a fraction of the view
    // instead: LOOKOUT_SHOW=pick:0.5x0.85.

    /// A point at a fraction of the view.
    private func viewPoint(fx: Double, fy: Double) -> CGPoint? {
        guard let centre = pickCentreHint else { return nil }
        return CGPoint(x: centre.x * 2 * fx, y: centre.y * 2 * fy)
    }

    /// A pick at a fraction of the view.
    func pickAt(fx: Double, fy: Double) {
        guard let controller, let p = viewPoint(fx: fx, fy: fy),
              let g = controller.geo(atPoint: p) else { return }
        showPick(controller.pick(lon: g.lon, lat: g.lat), at: p)
    }

    /// A pick at the view centre. A tap on the chart runs the same pick; the
    /// hook has no cursor to tap with.
    func pickAtCentre(lon: Double, lat: Double) {
        guard let controller, let point = pickCentreHint else { return }
        showPick(controller.pick(lon: lon, lat: lat), at: point)
    }

    /// The chart menu at a fraction of the view, as a right-click there would.
    func showChartMenu(fx: Double, fy: Double) {
        guard let p = viewPoint(fx: fx, fy: fy) else { return }
        openChartMenu(at: p)
    }

    /// Drop a marker at a fraction of the view.
    func showDropMarker(fx: Double, fy: Double) {
        guard let c = controller, let p = viewPoint(fx: fx, fy: fy),
              let g = c.geo(atPoint: p) else { return }
        c.dropMarker(lon: g.lon, lat: g.lat)
    }

    /// Open the rename field on the newest mark.
    func showRenameNewestMarker() {
        guard let mark = controller?.markers().last else { return }
        beginRename(mark)
    }
}
