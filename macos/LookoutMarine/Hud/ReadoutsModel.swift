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
