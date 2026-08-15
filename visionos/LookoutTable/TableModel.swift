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
            traffic.close(engine: engine)
            traffic.clear()
            pickCard.hide()
            ready = false
            engine.close()
        }
        let w = sheet.width
        let ok = engine.open(
            paths: charts,
            pixels: SheetMetrics.pixels(sheetWidth: w),
            points: SheetMetrics.points(sheetWidth: w),
            density: SheetMetrics.density)
        guard ok, let texture = engine.texture else {
            status = "The chart could not be opened."
            return
        }
        sheet.setChartTexture(texture)
        sheet.overlays.addChild(traffic.root)
        sheet.overlays.addChild(ownShip.root)
        sheet.overlays.addChild(pickCard.root)
        engine.fitChart()
        ready = true
        status = ""
    }

    // MARK: - The frame

    func tick(_ dt: TimeInterval, now: TimeInterval) {
        guard ready else { return }
        engine.tick(dt)
        engine.renderFrame()
        traffic.update(engine: engine, sheet: sheet, now: now)
        ownShip.update(engine: engine, sheet: sheet)
        pickCard.update(engine: engine, sheet: sheet)
        if now - lastTitleAt > 0.5 {
            lastTitleAt = now
            sheet.setTitle(titleLine())
            sheet.setScale(groundPerSheetMeter: groundPerSheetMeter())
            sheet.setNorth(rotationDegrees: engine.rotationDegrees)
        }
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
        let paper = Double(SheetMetrics.faceSize(sheetWidth: sheet.width).x) * 0.5
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

    private func titleLine() -> String {
        let d = engine.scaleDenominator
        guard d > 0 else { return engine.chartName }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let n = f.string(from: NSNumber(value: Int(d.rounded()))) ?? "\(Int(d))"
        return "\(engine.chartName)     1:\(n)"
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
        guard step.isFinite, step != 0 else { return }
        engine.zoom(step, atFraction: chartZoomAnchor)
    }

    /// Zoom levels per doubling of the hands' distance apart.
    ///
    /// A pinch on glass can run the length of the screen, and doubling it
    /// doubles the content, which is one level. Two hands in the air start
    /// about 300 mm apart and comfortably reach about a metre, so one honest
    /// pinch is only some 1.7 doublings. A chart runs from an approach to a
    /// berth over five or six levels, and at a gain of one that is four
    /// pinches. This spends a comfortable pinch on about four levels.
    private static let zoomGain: Double = 2.5

    func chartZoomEnded() {
        chartZoomLast = 1
    }

    func chartRotateChanged(_ radians: Double) {
        if chartRotateStart == 0 { chartRotateStart = engine.rotationDegrees }
        engine.setRotation(degrees: chartRotateStart + radians * 180 / .pi)
    }

    func chartRotateEnded() {
        chartRotateStart = 0
    }

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
        let m = Float(magnification)
        let target = min(max(sheet.width * m, SheetMetrics.minWidth), maxSheetWidth)
        sheet.root.scale = .init(repeating: target / sheet.width)
    }

    func sheetResizeEnded() {
        let committed = sheet.width * sheet.root.scale.x
        sheet.root.scale = .one
        setSheetWidth(committed)
    }

    /// The volume the sheet lies in, in meters. A sheet wider than its volume
    /// is clipped by the system, so the volume's own width is the ceiling on
    /// resizing, whatever SheetMetrics would otherwise allow.
    private(set) var volumeWidth: Float = SheetMetrics.maxWidth

    func setVolumeWidth(_ w: Float) {
        guard w > 0.1, abs(w - volumeWidth) > 0.001 else { return }
        volumeWidth = w
        if sheet.width > maxSheetWidth { setSheetWidth(maxSheetWidth) }
    }

    /// The widest sheet this volume holds, with the margin the system leaves
    /// around a volume's contents.
    var maxSheetWidth: Float {
        min(SheetMetrics.maxWidth, volumeWidth * 0.98)
    }

    func setSheetWidth(_ w: Float) {
        sheet.setWidth(min(w, maxSheetWidth))
        guard ready else { return }
        engine.resize(
            points: SheetMetrics.points(sheetWidth: sheet.width),
            pixels: SheetMetrics.pixels(sheetWidth: sheet.width),
            density: SheetMetrics.density)
        if let t = engine.texture { sheet.setChartTexture(t) }
        engine.renderFrame(force: true)
    }

    func sheetRotateChanged(_ radians: Double) {
        let start = sheetRotateStart ?? sheet.root.orientation
        sheetRotateStart = start
        sheet.root.orientation = start * simd_quatf(angle: Float(radians), axis: [0, 1, 0])
    }

    func sheetRotateEnded() {
        sheetRotateStart = nil
    }

    // MARK: - A tap on the chart

    /// Report what the chart holds where the mariner tapped, on a card that
    /// floats over the spot.
    func tapChart(at p: SIMD3<Float>) {
        let f = sheet.fraction(at: p)
        guard sheet.onSheet(f), let geo = engine.geoFor(fraction: f) else { return }
        let features = engine.pick(lon: geo.lon, lat: geo.lat)
        pickCard.show(features: features, lon: geo.lon, lat: geo.lat)
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
        sheet.root.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    }
}
