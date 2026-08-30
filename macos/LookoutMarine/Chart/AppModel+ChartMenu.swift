//  AppModel+ChartMenu.swift — the commands, and the menu raised on the water.
//
//  Every item acts on THIS point: not the map centre, and not where the cursor
//  drifts to afterwards, so the coordinates are taken once when the menu opens
//  and the menu carries them.

import Foundation

@MainActor
extension AppModel {
    // MARK: - Commands (menu / buttons)

    func zoomIn()   { controller?.zoomCentered(+1.0) }
    func zoomOut()  { controller?.zoomCentered(-1.0) }
    func zoomToFit(){ controller?.fitChart() }
    func northUp()  { controller?.resetRotation() }

    /// What the compass bubble shows. The core owns both parts: it drops
    /// follow on a pan and course up on a hand rotation, so this is read, not
    /// remembered.
    var orientation: Orientation {
        if followState == 0 { return .unlocked }
        if followState == 2 { return .armed }   // on, no fix to follow yet
        return courseUpState == 0 ? .northUp : .courseUp
    }

    /// The compass bubble's tap. It always locks the chart to own ship, and
    /// once locked it cycles north up and course up.
    func cycleOrientation() {
        guard let c = controller else { return }
        if followState == 0 {
            c.setFollow(true)          // lock, leaving the chart as it lies
        } else if courseUpState == 0 {
            c.setCourseUp(true)        // turn with own ship
        } else {
            c.resetRotation()          // back to north up, still locked
        }
    }

    // MARK: - The chart menu, and markers

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

    /// Which marker is being renamed, and where it is. The name being typed is
    /// `renamingText`.
    struct MarkerRename: Equatable {
        let id: UInt64
        let lon: Double
        let lat: Double
    }

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

    /// The Configure GPS button. This is the one place in the app where a
    /// mariner is told they have no position, so it carries the fix: Settings,
    /// Connections, where a gateway or a Signal K server is added. (A phone
    /// has a receiver of its own and will ask for permission here instead;
    /// that is a later pass.)
    func configurePosition() {
        openSettings()
        settingsTab = "connections"
    }

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

    // MARK: - The display commands

    /// Scheme changes from the MENU must persist like ones from the settings
    /// form (the form saves in its own apply path).
    func cycleScheme() {
        guard let c = controller else { return }
        c.cycleScheme()
        MarinerSettings.save(c.getMariner())
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
