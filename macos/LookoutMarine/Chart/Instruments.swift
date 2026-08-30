//  Instruments.swift — measuring the interactive path, in the app.
//
//  Both of these are dev hooks: $LOOKOUT_FRAME_PROF writes one CSV row per
//  display-link tick, and $LOOKOUT_GESTURE_BENCH drives a scripted gesture
//  through the controller's own entry points and quits. Neither runs unless it
//  is asked for.
//
//  They ship in the release binary on purpose. A bench that only exists in a
//  debug build cannot measure the binary a mariner has.

import Foundation
import QuartzCore
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Interactive-path profiling
//
// The offscreen harnesses measure a settled camera with its tiles resident:
// 5.68 ms a frame, rebuilds at a 6 ms median. Neither reproduces what a
// MOVING camera costs, which is the whole of the complaint. These two run in
// the app, on the real display link, through the real gesture entry points.

/// One row per display-link tick, written as CSV at the end of the run.
final class FrameProfiler: @unchecked Sendable {
    struct Row {
        var t: Double // ms since the first tick
        var gap: Double // ms since the previous tick — the FELT frame rate
        var dispatched: Bool
        var dropped: Bool // the render gate was shut: this slot was skipped
        var building: Bool
        var zoom: Double // so cost can be read against the LEVEL, not the clock
        var renderMs: Double = -1 // filled in when the render returns
    }

    private let path: String
    private let lock = NSLock()
    private var rows: [Row] = []
    private var t0: Double = 0
    /// Index of the row whose render is in flight. One at a time, by the gate.
    private var pending: Int?

    init(path: String) {
        self.path = path
        rows.reserveCapacity(8192)
    }

    func tick(gap: Double, dispatched: Bool, dropped: Bool, building: Bool, zoom: Double) {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        if t0 == 0 { t0 = now }
        rows.append(.init(t: (now - t0) * 1000, gap: gap * 1000,
                          dispatched: dispatched, dropped: dropped, building: building,
                          zoom: zoom))
        if dispatched { pending = rows.count - 1 }
    }

    /// Called on the render queue when lookout_render returns.
    func rendered(ms: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let i = pending, i < rows.count { rows[i].renderMs = ms }
        pending = nil
    }

    func write() {
        lock.lock()
        let snapshot = rows
        lock.unlock()
        var out = "t_ms,gap_ms,dispatched,dropped,building,zoom,render_ms\n"
        for r in snapshot {
            out += String(format: "%.2f,%.2f,%d,%d,%d,%.4f,%.3f\n",
                          r.t, r.gap, r.dispatched ? 1 : 0, r.dropped ? 1 : 0,
                          r.building ? 1 : 0, r.zoom, r.renderMs)
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
        lkLog("frame profile: \(snapshot.count) ticks -> \(path)")
    }
}

/// A scripted pan/zoom through the controller's own entry points, so the
/// interactive path can be measured without anyone at the trackpad — and the
/// same run twice.
@MainActor
final class GestureBench {
    private enum Phase { case settle, pan, rest, zoom, fill, rest2, flickPan, rest3, flickZoom, cursor, tour, done }

    /// The tour: at each stop, zoom all the way in, then all the way out, then
    /// pan (at the wide zoom) to the next coast. It crosses the whole library,
    /// every zoom level, and the band handoffs between them, which is the run
    /// that finds what a single sweep at one place never does.
    private struct Stop { let lon: Double; let lat: Double; let name: String }
    private let tourStops = [
        Stop(lon: -76.44, lat: 38.956, name: "Chesapeake"),
        Stop(lon: -122.44, lat: 37.80, name: "San Francisco"),
        Stop(lon: -70.90, lat: 42.35, name: "Boston"),
        Stop(lon: -81.78, lat: 24.55, name: "Key West"),
        Stop(lon: -87.56, lat: 41.89, name: "Chicago"),
    ]
    private var tourStop = 0
    /// Flick-and-settle bookkeeping (see .flickPan).
    private var flicksDone = 0
    private var quiet = 0
    private enum Leg { case zoomIn, zoomOut, panTo }
    private var leg: Leg = .zoomIn
    private var legStart: CFTimeInterval = 0
    private var lastZoom: Double = -1
    private var legStall = 0
    private var phase: Phase = .settle
    private var frames = 0
    private let doPan: Bool
    private let doZoom: Bool
    /// Long enough for the first build and its tiles to land.
    private let settleFrames = 120
    private let panFrames = 240
    /// 240 out + 240 back at 0.05 a frame = six levels each way.
    private let zoomFrames = 480

    private let doCursor: Bool
    private let doTour: Bool
    /// The point a cursor-anchored zoom must hold still, deliberately well off
    /// centre so a zoom that quietly falls back to centre-anchored shows up.
    private var anchorPt = CGPoint(x: 320, y: 200)
    private var anchorGeo: (lon: Double, lat: Double)?
    private var fillStart: CFTimeInterval = 0
    private(set) var anchorDriftM: Double = 0

    init(spec: String) {
        let s = spec.lowercased()
        doPan = (s == "1" || s == "pan" || s == "both")
        doZoom = (s == "1" || s == "zoom" || s == "both")
        doCursor = (s == "1" || s == "both" || s == "cursor")
        doTour = (s == "tour")
    }

    /// One tick of the tour. Each leg runs until the camera stops responding
    /// (the zoom clamped, or the pan arrived), then reports how long it took
    /// and how long the chart went on working after it.
    private func stepTour(_ c: ChartController) {
        let v = c.currentView
        switch leg {
        case .zoomIn, .zoomOut:
            let dz = leg == .zoomIn ? 0.35 : -0.35
            c.zoomCentered(dz)
            // Clamped when the zoom stops moving for a few frames running.
            if abs(v.zoom - lastZoom) < 0.001 { legStall += 1 } else { legStall = 0 }
            lastZoom = v.zoom
            // z18 is as deep as the survey goes; past it the chart is only
            // magnified, so a test that runs on to z21 is measuring overscale
            // rather than the chart.
            let atLimit = leg == .zoomIn && v.zoom >= 18.0
            if legStall >= 8 || atLimit || frames > 1200 {
                report(c, "\(leg == .zoomIn ? "zoom in " : "zoom out")@\(tourStops[tourStop].name) -> z\(String(format: "%.1f", v.zoom))")
                if leg == .zoomIn { beginLeg(.zoomOut) } else {
                    if tourStop + 1 < tourStops.count { tourStop += 1; beginLeg(.panTo) }
                    else { phase = .done; frames = 0 }
                }
            }
        case .panTo:
            // Steer by where the destination actually IS on screen, both axes
            // at once. Testing longitude alone stopped the pan the moment the
            // meridian matched and left the latitude wherever it had got to,
            // which put "Key West" and "Chicago" in the middle of the country.
            let want = tourStops[tourStop]
            let p = c.screenPoint(forGeoLon: want.lon, lat: want.lat)
            let centre = c.viewCentrePt
            var dx = centre.x - p.x
            var dy = centre.y - p.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < 24 || frames > 2400 {
                report(c, "pan -> \(want.name)")
                beginLeg(.zoomIn)
                return
            }
            // Brisk but not a jump, so the pan is a real gesture over real
            // ground rather than a teleport the tile path never sees.
            let step = min(dist, 160)
            dx = dx / dist * step
            dy = dy / dist * step
            c.pan(dxPt: dx, dyPt: dy)
        }
    }

    private func beginLeg(_ l: Leg) {
        leg = l; frames = 0; legStall = 0; lastZoom = -1
        legStart = CACurrentMediaTime()
    }

    private func report(_ c: ChartController, _ what: String) {
        let ms = (CACurrentMediaTime() - legStart) * 1000
        lkLog(String(format: "tour: %@ in %.0f ms (%d frames)", what, ms, frames))
    }

    func step(_ c: ChartController) {
        frames += 1
        switch phase {
        case .settle:
            // Wait for the chart to be OPEN and settled, not just for a frame
            // count: a chart library takes tens of seconds to compose, and a
            // bench that starts on frame 120 measures the loading screen.
            if c.model?.charts.firstBuildDone != true || c.stillBuilding { frames = 0; return }
            if frames >= settleFrames {
                if doTour { beginLeg(.zoomIn); phase = .tour; return }
                phase = doPan ? .pan : (doZoom ? .zoom : (doCursor ? .cursor : .done))
                frames = 0
            }
        case .pan:
            // A steady drag: 4 pt a frame is an ordinary finger, and it keeps
            // crossing into new tiles, which is the case the settled
            // benchmarks cannot produce. (8 pt was a race, not a pan — the
            // gentler drag is the cadence the complaint describes.)
            c.pan(dxPt: -4, dyPt: -1.5)
            if frames >= panFrames { phase = .rest; frames = 0 }
        case .rest:
            if frames >= 60 { phase = doZoom ? .zoom : .done; frames = 0 }
        case .zoom:
            // Out six whole zoom levels and back in. Crossing LEVELS is where
            // the work is: each one changes which tiles cover the view, so the
            // compositor is asked for a fresh set and every resident tile is
            // re-laid-out. A shallow pinch inside one level measures almost
            // nothing by comparison.
            // Zoom IN only: every level needs tiles the view has never
            // held, which is the case that waits on the compositor.
            c.zoomCentered(0.05)
            if frames >= zoomFrames { phase = .fill; frames = 0; fillStart = CACurrentMediaTime() }
        case .fill:
            // How long the chart takes to FINISH after the gesture stops: the
            // tiles a zoom asked for still have to be composed and tessellated,
            // and that wait is what reads as "it fills in ages later".
            if !c.stillBuilding || frames > 900 {
                let ms = (CACurrentMediaTime() - fillStart) * 1000
                lkLog(String(format: "fill after zoom: %.0f ms (%d frames)", ms, frames))
                phase = .rest2; frames = 0
            }
        case .rest2:
            if frames >= 60 { phase = .flickPan; frames = 0 }
        case .flickPan:
            // A FLICK, then wait for the chart to SETTLE — coast ended, build
            // landed, three quarters of a second of quiet — then flick again.
            // That is the cadence of a real hand, and the settle boundary is
            // the path a fixed spacing never ran: each throw used to land in
            // the previous coast, so the first-frame-after-idle work was
            // measured zero times. Three throws, coasts and settles both.
            //
            // Thrown into water that NEEDS tiles. The pan and zoom phases
            // warmed everything around the start view, and a coast over
            // resident tiles measures nothing about supply — so this jumps to
            // a coast the run has not touched, lets it build, and every throw
            // after that keeps entering cold water.
            if frames == 1 {
                var v = c.currentView
                v.lon = -76.61
                v.lat = 39.27 // Baltimore approaches, untouched by the run
                c.setView(v)
                return
            }
            let settled = !c.isAnimating && !c.stillBuilding
            quiet = settled ? quiet + 1 : 0
            if flicksDone < 3 {
                if quiet >= 45 { // the first throw waits for the jump to build
                    c.flingStart(vx: -2600, vy: -900)
                    flicksDone += 1
                    quiet = 0
                }
            } else if quiet >= 45 || frames >= 1800 {
                flicksDone = 0
                quiet = 0
                phase = .rest3
                frames = 0
            }
        case .rest3:
            if frames >= 60 { phase = .flickZoom; frames = 0 }
        case .flickZoom:
            // A snap zoom: one big step, eased by the camera. Same coast path.
            if frames % 60 == 1 {
                c.zoomCentered(frames < 180 ? -1.0 : 1.0)
            }
            if frames >= 360 { phase = doCursor ? .cursor : .done; frames = 0 }
        case .cursor:
            // Zoom-to-cursor is a CONTRACT, not a feel: the world point under
            // the pointer must not move while the zoom eases. Record the geo
            // under the anchor, wheel in and back out at that point, and
            // measure how far it drifted. Anything past a few metres at harbor
            // scale means the anchor is being lost — which reads to a mariner
            // as "it zooms to the middle, not to where I'm pointing".
            if frames == 1 { anchorGeo = c.geo(atPoint: anchorPt) }
            if frames % 3 == 1 { c.zoom(frames <= 180 ? 0.15 : -0.15, atPt: anchorPt) }
            if frames >= 360 {
                if let want = anchorGeo, let got = c.geo(atPoint: anchorPt) {
                    // Metres on the ground, at this latitude.
                    let dLat = (got.lat - want.lat) * 111_320
                    let dLon = (got.lon - want.lon) * 111_320 * cos(want.lat * .pi / 180)
                    anchorDriftM = (dLat * dLat + dLon * dLon).squareRoot()
                    lkLog(String(format: "cursor anchor drift: %.1f m (want %.6f,%.6f got %.6f,%.6f)",
                                 anchorDriftM, want.lon, want.lat, got.lon, got.lat))
                }
                phase = .done; frames = 0
            }
        case .tour:
            stepTour(c)
        case .done:
            if frames == 30 {
                c.finishGestureBench()
            }
        }
    }
}
