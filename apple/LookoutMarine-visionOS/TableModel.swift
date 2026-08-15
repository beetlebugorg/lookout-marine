//
//  What the chart table is doing, and every rule about how a hand changes it.
//
//  THE ONE RULE THE WHOLE APP RESTS ON: the margin is the object and the face
//  is the map. A hand on the white margin moves, turns and resizes the SHEET,
//  the way a hand on the edge of a paper chart does. A hand on the printed
//  chart moves the CHART under the paper: it pans, it zooms and it turns, and
//  the sheet does not move at all.
//

import Foundation
import RealityKit
import SwiftUI
import simd

@Observable
@MainActor
final class TableModel {
    let engine = ChartEngine()
    let sheet = ChartSheet()
    let traffic = AISTraffic()
    let ownShip = OwnShip()
    let pickCard = PickCard()

    /// The alarms the plugins raise. A collision alarm has to reach the
    /// mariner whatever they are looking at, so the watch runs for as long as
    /// the chart is open.
    let alerts = AlertWatch()

    /// The water under the paper. Off until the mariner asks for it: sampling
    /// it costs a second of picks, and a chart table is a chart first.
    let seabed = Seabed()

    /// What a chart table's instruments say: where the boat is, what it is
    /// doing, and what the chart under it is showing. Read a few times a
    /// second, which is faster than any of it changes.
    var readouts: Readouts = .init()
    private var lastReadoutAt: TimeInterval = 0

    /// What the mariner is told when there is no chart, and while one opens.
    var status = "Opening the chart"
    var ready = false

    /// The chart name and scale printed on the margin.
    private var lastTitleAt: TimeInterval = 0

    // MARK: - Opening

    func open() {
        let charts = ChartLibrary.find()
        guard !charts.isEmpty else {
            status = "No chart. Choose a folder of charts, or put one in this app's Documents folder."
            lkLog("no charts found")
            return
        }
        open(charts: charts)
    }

    /// Open the folder or file a picker returned, and remember it for the next
    /// launch. A folder is walked for .pmtiles.
    func openPicked(_ url: URL) {
        let charts = ChartLibrary.adopt(url)
        guard !charts.isEmpty else {
            status = "No .pmtiles charts in \(url.lastPathComponent)."
            return
        }
        open(charts: charts)
    }

    private func open(charts: [String]) {
        // Opening a second library replaces the first. The plugin layer, the
        // traffic and the card all belong to the handle that is going away.
        if engine.handle != nil {
            alerts.stop()
            traffic.close(engine: engine)
            traffic.clear()
            pickCard.hide()
            ready = false
            engine.close()
        }
        let w = sheet.width
        let ok = engine.open(
            paths: charts,
            pixels: SheetMetrics.pixels(sheet: sheet.size),
            points: SheetMetrics.points(sheet: sheet.size),
            density: SheetMetrics.density)
        guard ok, let texture = engine.texture else {
            status = "The chart could not be opened."
            return
        }
        sheet.setChartTexture(texture)
        sheet.root.addChild(seabed.root)
        sheet.overlays.addChild(traffic.root)
        sheet.overlays.addChild(ownShip.root)
        sheet.overlays.addChild(pickCard.root)
        engine.fitChart()
        alerts.start(host: engine)
        ready = true
        status = ""
    }

    // MARK: - The frame

    func tick(_ dt: TimeInterval, now: TimeInterval) {
        // The sheet follows the volume whether or not a chart is open.
        commitPendingSize(now: now)
        guard ready else { return }
        engine.tick(dt)
        engine.renderFrame()
        traffic.update(engine: engine, sheet: sheet, now: now)
        ownShip.update(engine: engine, sheet: sheet)
        pickCard.update(engine: engine, sheet: sheet)
        resampleSeabedIfStale(now: now)
        if now - lastReadoutAt > 0.4 {
            lastReadoutAt = now
            readouts = makeReadouts()
        }
        if now - lastTitleAt > 0.5 {
            lastTitleAt = now
            sheet.setTitle(titleLine())
            sheet.setNote(engine.chartNote)
            sheet.setLegend(soundingsLegend())
            sheet.setScale(groundPerSheetMeter: groundPerSheetMeter())
            sheet.setNorth(rotationDegrees: engine.rotationDegrees)
        }
    }

    /// The instruments, read off the chart and off own ship's own overlay.
    private func makeReadouts() -> Readouts {
        var r = Readouts()
        let d = engine.scaleDenominator
        if d > 0 { r.scale = "1:\(ChartLibrary.thousands(Int(d.rounded())))" }
        r.overscaled = engine.overscale > 1.05
        guard let ship = engine.ownShipReadout() else { return r }
        r.position = Readouts.latLon(lon: ship.lon, lat: ship.lat)
        for (key, value) in ship.rows {
            switch key {
            case "SOG": r.sog = value
            case "COG": r.cog = value
            case "HDG": r.heading = value
            default: continue
            }
        }
        return r
    }

    /// How many meters of sea one meter of paper covers, measured across the
    /// middle of the chart itself. Taken from two positions rather than from
    /// the scale denominator, so it is right at any latitude and under any
    /// projection the renderer is using.
    private func groundPerSheetMeter() -> Double {
        guard let a = engine.geoFor(fraction: [0.25, 0.5]),
              let b = engine.geoFor(fraction: [0.75, 0.5])
        else { return 0 }
        let ground = TableModel.distanceMeters(a, b)
        let paper = Double(SheetMetrics.faceSize(sheet: sheet.size).x) * 0.5
        guard paper > 0 else { return 0 }
        return ground / paper
    }

    /// Great-circle distance, in meters.
    private static func distanceMeters(_ a: (lon: Double, lat: Double), _ b: (lon: Double, lat: Double)) -> Double {
        let r = 6_371_000.0
        let p = Double.pi / 180
        let dLat = (b.lat - a.lat) * p
        let dLon = (b.lon - a.lon) * p
        let s = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.lat * p) * cos(b.lat * p) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(s.squareRoot(), (1 - s).squareRoot())
    }

    /// What a printed chart says first, because reading a sounding in the
    /// wrong unit is how a boat goes aground. It follows the mariner's own
    /// depth setting.
    private func soundingsLegend() -> String {
        engine.getMariner().depth_unit == TILE57_DEPTH_FEET
            ? "SOUNDINGS IN FEET"
            : "SOUNDINGS IN METERS"
    }

    private func titleLine() -> String {
        let d = engine.scaleDenominator
        guard d > 0 else { return engine.chartName }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let n = f.string(from: NSNumber(value: Int(d.rounded()))) ?? "\(Int(d))"
        return "\(engine.chartName)     1:\(n)"
    }

    // MARK: - The water under the paper

    private var samplingSeabed = false
    private var seabedSettledAt: TimeInterval = 0

    /// How the seabed is sampled. 40 by 30 is 1200 picks, which is about a
    /// second of work, and it resolves a harbor's channel and its banks. A
    /// finer grid costs its area and shows the same shape.
    private static let seabedColumns = 40
    private static let seabedRows = 30

    /// The view has to hold still before the sample starts: panning through a
    /// harbor would otherwise start a second of work on every frame.
    private static let seabedSettle: TimeInterval = 0.4

    func toggleSeabed() {
        seabed.setShowing(!seabed.isShowing)
        if seabed.isShowing { seabedSettledAt = 0 }
    }

    /// Sample again when the view has moved away from what the slab was built
    /// for. The sampling runs off the main actor, because every node is a pick
    /// and a thousand of them would drop a second of frames.
    private func resampleSeabedIfStale(now: TimeInterval) {
        guard seabed.isShowing, !samplingSeabed else { return }
        let v = engine.view
        let span = engine.spanDegrees
        if let field = seabed.field, field.matches(lon: v.lon, lat: v.lat, zoom: v.zoom, spanDegrees: span) {
            seabedSettledAt = 0
            return
        }
        if seabedSettledAt == 0 {
            seabedSettledAt = now
            return
        }
        guard now - seabedSettledAt > TableModel.seabedSettle else { return }
        seabedSettledAt = 0
        samplingSeabed = true
        let columns = TableModel.seabedColumns
        let rows = TableModel.seabedRows
        Task.detached(priority: .utility) { [engine, seabed, sheet] in
            let field = await MainActor.run { engine.sampleDepths(columns: columns, rows: rows) }
            await MainActor.run {
                if let field {
                    seabed.rebuild(field: field,
                                   face: SheetMetrics.faceSize(sheet: sheet.size),
                                   thickness: SheetMetrics.thickness)
                }
                self.samplingSeabed = false
            }
        }
    }

    // MARK: - A hand on the chart

    private var chartDragLast: SIMD3<Float>?
    private var chartDragLastAt: TimeInterval = 0
    private var chartDragVelocity: SIMD2<Double> = .zero
    private var chartZoomLast: Double = 1
    private var chartZoomAnchor: SIMD2<Float> = [0.5, 0.5]
    private var chartRotateStart: Double = 0

    func chartDragChanged(to p: SIMD3<Float>, at time: TimeInterval) {
        defer { chartDragLast = p; chartDragLastAt = time }
        guard let last = chartDragLast else {
            // A hand on the chart stops any coast, the way a hand on a paper
            // chart stops it sliding.
            engine.fling(vx: 0, vy: 0)
            chartDragVelocity = .zero
            return
        }
        let d = p - last
        // Sheet meters to chart points. The chart follows the hand: +X on the
        // sheet is east on the chart and +Z is south, which is the same pair
        // of directions a pointer platform sends.
        let dx = Double(d.x * SheetMetrics.pointsPerMeter)
        let dy = Double(d.z * SheetMetrics.pointsPerMeter)
        engine.pan(dxPoints: Float(dx), dyPoints: Float(dy))

        // Velocity for the throw, smoothed: one sample is whatever the last
        // frame happened to be, and a hand stopping dead still reports the
        // frame before it.
        let dt = time - chartDragLastAt
        guard dt > 0.001, dt < 0.2 else { return }
        let sample = SIMD2<Double>(dx / dt, dy / dt)
        chartDragVelocity = chartDragVelocity * 0.6 + sample * 0.4
    }

    /// A chart let go while it is moving keeps moving and slows down, which is
    /// how a paper chart pushed across a table behaves.
    func chartDragEnded() {
        chartDragLast = nil
        let v = chartDragVelocity
        let speed = (v.x * v.x + v.y * v.y).squareRoot()
        if speed > TableModel.flingFloor {
            engine.fling(vx: v.x, vy: v.y)
        }
        chartDragVelocity = .zero
    }

    /// Below this the hand was placing the chart, not throwing it. Points per
    /// second, so it is the same number a pointer platform would use.
    private static let flingFloor: Double = 120

    func chartZoomChanged(_ magnification: Double, anchor: SIMD3<Float>) {
        if chartZoomLast == 1 {
            chartZoomAnchor = sheet.fraction(at: anchor)
        }
        let step = log2(magnification / chartZoomLast) * TableModel.zoomGain
        chartZoomLast = magnification
        guard claim(&chartHands, as: .zoom, past: abs(log2(magnification)) > TableModel.zoomDeadZone) else { return }
        guard step.isFinite, step != 0 else { return }
        engine.zoom(step, atFraction: chartZoomAnchor)
    }

    /// Zoom levels per doubling of the hands' distance apart.
    ///
    /// A pinch on glass can run the length of the screen, and doubling it
    /// doubles the content, which is one level. Two hands in the air start
    /// about 300 mm apart and comfortably reach about a metre, so one honest
    /// pinch is only some 1.7 doublings. A chart runs from an approach to a
    /// berth over five or six levels, so a gain of one spends four pinches
    /// crossing it. This spends one pinch on nearly seven levels, which is the
    /// whole useful range of a chart library.
    private static let zoomGain: Double = 4.0

    func chartZoomEnded() {
        chartZoomLast = 1
        chartHands = .undecided
    }

    /// The chart turns with the hands. A pair of hands turning clockwise seen
    /// from above turns about -Y in the scene, and the same turn is a POSITIVE
    /// course-up rotation, so the sign flips on the way to the engine. The
    /// sheet needs no such flip: it takes the hands' own rotation unchanged.
    func chartRotateChanged(_ radians: Double) {
        let claimed = chartHands == .rotate
        guard claim(&chartHands, as: .rotate, past: abs(radians) > TableModel.rotateDeadZone) else { return }
        if !claimed {
            // Start from where the hands crossed into a turn, so the chart
            // does not jump by the dead zone the moment it takes over.
            chartRotateOrigin = radians
            chartRotateStart = engine.rotationDegrees
        }
        engine.setRotation(degrees: chartRotateStart - (radians - chartRotateOrigin) * 180 / .pi)
    }

    func chartRotateEnded() {
        chartRotateStart = 0
        chartRotateOrigin = 0
        chartHands = .undecided
    }

    // MARK: - Which gesture a pair of hands is making

    /// Two hands moving apart are never perfectly parallel, and two hands
    /// turning are never perfectly still, so the system reports a magnify and
    /// a rotate at once. The first to pass its own threshold takes the hands,
    /// and the other stays out until they let go. Without this every zoom
    /// leaves the chart askew.
    enum Hands { case undecided, zoom, rotate }

    private var chartHands: Hands = .undecided
    private var sheetHands: Hands = .undecided
    private var chartRotateOrigin: Double = 0
    private var sheetRotateOrigin: Double = 0

    /// True while `what` may act: it already holds the hands, or nothing does
    /// and it has just passed its threshold.
    private func claim(_ hands: inout Hands, as what: Hands, past: Bool) -> Bool {
        if hands == what { return true }
        guard hands == .undecided, past else { return false }
        hands = what
        return true
    }

    /// How far the hands must turn before a turn is meant. Twelve degrees is
    /// past what a pinch strays into and well short of a deliberate turn.
    private static let rotateDeadZone = 12.0 * .pi / 180

    /// How far apart they must move before a zoom is meant, as log2 of the
    /// magnification: a tenth of a level, which is a few centimeters.
    private static let zoomDeadZone = 0.10

    // MARK: - A hand on the margin

    private var sheetDragLast: SIMD3<Float>?
    private var sheetRotateStart: simd_quatf?

    func sheetDragChanged(to p: SIMD3<Float>) {
        defer { sheetDragLast = p }
        guard let last = sheetDragLast else { return }
        sheet.root.position += p - last
    }

    func sheetDragEnded() {
        sheetDragLast = nil
    }

    /// Resizing runs live as a scale on the whole sheet and commits on release.
    /// The chart's texture and viewport are rebuilt once, at the end, because
    /// rebuilding a texture every frame of a pinch would stutter.
    func sheetResizeChanged(_ magnification: Double) {
        guard claim(&sheetHands, as: .zoom, past: abs(log2(magnification)) > TableModel.zoomDeadZone) else { return }
        let m = Float(magnification)
        let target = min(max(sheet.width * m, SheetMetrics.minWidth), SheetMetrics.maxWidth)
        sheet.root.scale = .init(repeating: target / sheet.width)
    }

    func sheetResizeEnded() {
        sheetHands = .undecided
        let committed = sheet.width * sheet.root.scale.x
        sheet.root.scale = .one
        setSheetWidth(committed)
    }

    /// The volume the sheet lies in, in meters. The volume is the table, so
    /// the sheet fills it and follows it when the mariner resizes it.
    private(set) var volumeWidth: Float = SheetMetrics.maxWidth
    private(set) var volumeDepth: Float = SheetMetrics.maxWidth * SheetMetrics.aspect

    /// A resize in progress. Growing the sheet live would rebuild its meshes
    /// and its whole texture on every frame of the drag, so the drag only
    /// scales the transform and the real size is taken once it settles.
    private var pendingSize: SIMD2<Float>?
    private var pendingSizeAt: TimeInterval = 0

    func setVolumeSize(width: Float, depth: Float) {
        guard width > 0.1, depth > 0.1 else { return }
        guard abs(width - volumeWidth) > 0.005 || abs(depth - volumeDepth) > 0.005 else { return }
        volumeWidth = width
        volumeDepth = depth
        let target = sheetFillingFloor
        guard length(target - sheet.size) > 0.005 else { return }
        pendingSize = target
        pendingSizeAt = Date.timeIntervalSinceReferenceDate
        sheet.root.scale = .init(repeating: target.x / sheet.width)
    }

    /// The sheet that covers the volume's floor. The volume IS the table, so
    /// the paper takes its shape rather than a printed chart's, and only the
    /// width is held to what a sheet may be. The system leaves a little room
    /// around a volume's contents, hence the 2%.
    var sheetFillingFloor: SIMD2<Float> {
        let w = min(max(volumeWidth * 0.98, SheetMetrics.minWidth), SheetMetrics.maxWidth)
        return SIMD2<Float>(w, volumeDepth * 0.98)
    }

    /// Take the size a settled volume resize asked for.
    private func commitPendingSize(now: TimeInterval) {
        guard let target = pendingSize, now - pendingSizeAt > 0.25 else { return }
        pendingSize = nil
        sheet.root.scale = .one
        setSheetSize(target)
    }

    func setSheetWidth(_ w: Float) {
        let scale = w / sheet.width
        setSheetSize(SIMD2<Float>(w, sheet.depth * scale))
    }

    func setSheetSize(_ s: SIMD2<Float>) {
        sheet.setSize(s)
        guard ready else { return }
        engine.resize(
            points: SheetMetrics.points(sheet: sheet.size),
            pixels: SheetMetrics.pixels(sheet: sheet.size),
            density: SheetMetrics.density)
        if let t = engine.texture { sheet.setChartTexture(t) }
        engine.renderFrame(force: true)
    }

    func sheetRotateChanged(_ radians: Double) {
        let claimed = sheetHands == .rotate
        guard claim(&sheetHands, as: .rotate, past: abs(radians) > TableModel.rotateDeadZone) else { return }
        if !claimed {
            sheetRotateStart = yaw
            sheetRotateOrigin = radians
        }
        let start = sheetRotateStart ?? yaw
        yaw = start * simd_quatf(angle: Float(radians - sheetRotateOrigin), axis: [0, 1, 0])
        applyPose()
    }

    func sheetRotateEnded() {
        sheetRotateStart = nil
        sheetRotateOrigin = 0
        sheetHands = .undecided
    }

    // MARK: - The sheet's pose

    /// The sheet lies flat by default, as a chart on a table does. Tilting the
    /// far edge up stands it towards the mariner, the way a drafting table or
    /// a chart table's own sloped top does, which is easier to read across
    /// without leaning over it.
    ///
    /// Yaw and tilt are held apart and composed here. Kept as one quaternion
    /// they would fight: turning a tilted sheet about the world's up axis
    /// swings it through the table rather than turning it on its own surface.
    private var yaw = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private(set) var tiltDegrees: Float = 0

    /// The angles the tilt control steps through. Flat, a reading slope, a
    /// drafting slope, and near upright for a chart read from across the room.
    static let tiltSteps: [Float] = [0, 15, 30, 50]

    func stepTilt() {
        let next = TableModel.tiltSteps.first { $0 > tiltDegrees + 0.5 }
        setTilt(next ?? 0)
    }

    func setTilt(_ degrees: Float) {
        tiltDegrees = min(max(degrees, 0), 80)
        applyPose()
    }

    /// Yaw about the room's up axis, then tilt about the sheet's own near edge,
    /// so the far edge is what rises.
    private func applyPose() {
        let tilt = simd_quatf(angle: tiltDegrees * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
        sheet.root.orientation = yaw * tilt
    }

    // MARK: - A tap on the chart

    /// What the chart holds where the mariner tapped, on a panel that floats
    /// over the spot. A tap on open water closes the panel: the mariner is
    /// done reading, and a card nobody asked for is in the way.
    var picks: [PickDecoded] = []
    var pickIndex = 0

    func tapChart(at p: SIMD3<Float>) {
        let f = sheet.fraction(at: p)
        guard sheet.onSheet(f), let geo = engine.geoFor(fraction: f) else { return }
        let found = engine.pick(lon: geo.lon, lat: geo.lat)
        picks = found
        pickIndex = 0
        if found.isEmpty {
            pickCard.hide()
        } else {
            pickCard.show(lon: geo.lon, lat: geo.lat)
        }
    }

    func closePick() {
        picks = []
        pickIndex = 0
        pickCard.hide()
    }

    // MARK: - Controls

    func cycleScheme() {
        engine.cycleScheme()
        engine.renderFrame(force: true)
    }

    func fitChart() {
        engine.fitChart()
    }

    func followOwnShip() {
        guard let s = engine.ownShip else { return }
        engine.setView(lon: s.lon, lat: s.lat, zoom: engine.view.zoom)
    }

    func levelSheet() {
        yaw = simd_quatf(angle: 0, axis: [0, 1, 0])
        tiltDegrees = 0
        applyPose()
    }
}
