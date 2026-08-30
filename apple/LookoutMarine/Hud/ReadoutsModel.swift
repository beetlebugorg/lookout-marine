//  ReadoutsModel.swift — what the chart reports every frame.
//
//  All of it is READ from the core on the render tick, never remembered from a
//  gesture. The core turns follow off itself when the mariner pans and drops
//  course up on a hand rotation, so a shell that remembered what it last asked
//  for would disagree with the chart on screen.

import Foundation

@MainActor
@Observable
final class ReadoutsModel {
    var scaleDenominator: Double = 0
    var zoomLevel: Double = 0      // fractional web-mercator zoom
    var scheme: Int = 0            // 0 day, 1 dusk, 2 night
    var rotationDeg: Double = 0
    var overscale: Double = 1.0    // >1 = zoomed past the deepest data
    var centerLat: Double = 0
    var centerLon: Double = 0
    /// Follow mode as the core reports it: 0 off, 1 following own ship, 2 on
    /// and waiting for a fix.
    var followState: Int = 0
    /// Course up as the core reports it: 0 off, 1 turning with own ship, 2 on
    /// and waiting for a heading.
    var courseUpState: Int = 0
    /// What the position readout may say, as the core reports it. Polled on
    /// the render tick beside the position itself, so the two can never
    /// disagree: a readout holding the last numbers through a lost fix would
    /// be presenting a stale one as live.
    var fixState: FixState = .none
    /// Own ship's reported position. Both nil unless `fixState` is `.live`;
    /// the readout NEVER falls back to the map centre or the cursor.
    var shipLat: Double?
    var shipLon: Double?
    var isBuilding = false         // a background tessellation is filling in
    /// True while the plugin layer is up. Own ship comes from a plugin, so the
    /// follow control is only shown when one can supply a position.
    var pluginsActive = false

    weak var engine: (any ReadoutEngine)?

    /// Read the frame's values off the chart.
    ///
    /// Only what changed is assigned. Observation tracks a view against the
    /// properties it read, and an assignment counts as a change whether the
    /// value moved or not, so an unconditional push per frame re-evaluated the
    /// whole HUD at frame rate — it showed up as per-frame AttributeGraph work
    /// in a gesture profile. The caller throttles the rest of the way.
    func pull() {
        guard let e = engine else { return }
        let v = e.currentView
        if rotationDeg != v.rotation_deg { rotationDeg = v.rotation_deg }
        if zoomLevel != v.zoom { zoomLevel = v.zoom }
        if centerLat != v.lat { centerLat = v.lat }
        if centerLon != v.lon { centerLon = v.lon }
        if overscale != e.overscale { overscale = e.overscale }
        if scaleDenominator != e.scaleDenominator { scaleDenominator = e.scaleDenominator }
        if scheme != e.schemeIndex { scheme = e.schemeIndex }
        // The core turns follow off itself on a pan, so polling here is what
        // makes the lock button follow the core instead of its own last tap.
        if followState != e.followState { followState = e.followState }
        if courseUpState != e.courseUpState { courseUpState = e.courseUpState }
        if pluginsActive != e.pluginsActive { pluginsActive = e.pluginsActive }
        pullOwnShip(e)
    }

    /// Own ship, for the position readout. The state and the numbers move
    /// together: a readout that kept the last position through a lost fix
    /// would be presenting a stale one as live.
    private func pullOwnShip(_ e: any ReadoutEngine) {
        guard let ship = e.ownShip() else { return }
        if fixState != ship.state { fixState = ship.state }
        let lat: Double? = ship.state == .live ? ship.lat : nil
        let lon: Double? = ship.state == .live ? ship.lon : nil
        if shipLat != lat { shipLat = lat }
        if shipLon != lon { shipLon = lon }
    }

    var schemeName: String {
        switch scheme { case 1: return "Dusk"; case 2: return "Night"; default: return "Day" }
    }

    /// What the compass bubble shows. The core owns both parts, so this is
    /// read, not remembered.
    var orientation: Orientation {
        if followState == 0 { return .unlocked }
        if followState == 2 { return .armed }   // on, no fix to follow yet
        return courseUpState == 0 ? .northUp : .courseUp
    }
}
