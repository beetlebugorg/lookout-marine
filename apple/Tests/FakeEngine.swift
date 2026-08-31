//  FakeEngine.swift — a chart that answers, for the models to be tested against.
//
//  The area models reach the chart through the seams in ChartEngine.swift, so a
//  test can put this in place of the controller. Exercising them against the
//  real one would need a cell on disk, a bake and a render thread.
//
//  It records what it was asked and answers what the test set. Nothing here
//  models the engine's behaviour: where a model reads its own state back after
//  a change (the raster election, say), the test sets what comes back.

import Foundation
@testable import LookoutMarine

@MainActor
final class FakeEngine: RasterEngine, ChartLinkEngine, PluginEngine,
                        ChartOpenEngine, ReadoutEngine, OverlayEngine {

    // MARK: What it was asked
    var calls: [String] = []
    private func note(_ s: String) { calls.append(s) }

    // MARK: Raster
    /// Paths this refuses to add, so the "would not open" path can be run.
    var rasterRefuses: Set<String> = []
    var rasterSetList: [RasterSet] = []
    var rasterActive = -1
    var rasterNameValue = ""
    var rasterAvailable = ""
    var chartIsHidden = false

    func addRaster(_ path: String) -> Bool {
        note("addRaster(\(path))")
        return !rasterRefuses.contains(path)
    }
    func setRasterEnabled(_ path: String, _ on: Bool) -> Bool {
        note("setRasterEnabled(\(path), \(on))")
        return true
    }
    func rasterSets() -> [RasterSet] { rasterSetList }
    func rasterName() -> String { rasterNameValue }
    func rasterActiveIndex() -> Int { rasterActive }
    func rasterAvailableName() -> String { rasterAvailable }
    func rasterSelect(_ i: Int) { note("rasterSelect(\(i))"); rasterActive = i }
    func cycleRaster() { note("cycleRaster") }
    func toggleChart() { note("toggleChart"); chartIsHidden.toggle() }
    func chartHidden() -> Bool { chartIsHidden }
    var rasterIsOverChart = false
    func rasterOverChart() -> Bool { rasterIsOverChart }

    // MARK: The readouts
    var view = lookout_view(lon: -76, lat: 39, zoom: 12, rotation_deg: 0)
    var follow = 0
    var courseUp = 0
    var pluginsAreActive = false
    var scale: Double = 25_000
    var overscaleValue: Double = 1
    var scheme = 0
    var building = false
    /// What ownShip answers. Nil is "the core did not say".
    var ship: (state: FixState, lat: Double, lon: Double)?

    var currentView: lookout_view { view }
    var followState: Int { follow }
    var courseUpState: Int { courseUp }
    var pluginsActive: Bool { pluginsAreActive }
    var scaleDenominator: Double { scale }
    var overscale: Double { overscaleValue }
    var schemeIndex: Int { scheme }
    var stillBuilding: Bool { building }
    func ownShip() -> (state: FixState, lat: Double, lon: Double)? { ship }

    // MARK: Chart links
    /// What chartLinksSnapshot returns. Nil is no change since the last poll.
    var links: ChartLinkSnapshot?
    func addChartLink(_ link: String) { note("addChartLink(\(link))") }
    func refreshChartLink(_ url: String) { note("refreshChartLink(\(url))") }
    func removeChartLink(_ url: String) { note("removeChartLink(\(url))") }
    func selectChartLink(_ url: String?) { note("selectChartLink(\(url ?? "nil"))") }
    func importChartLinks(_ json: String) { note("importChartLinks") }
    func chartLinksSnapshot() -> ChartLinkSnapshot? { links }

    // MARK: Plugins
    var specs: [PluginTableSpec] = []
    var alerts: (seq: Int, alerts: [PluginAlert])?
    var acknowledged: [UInt64] = []
    /// What inspectPlugin answers: nil is "the layer could not start".
    var inspectJSON: String?
    /// What installPlugin answers: a sentence is a refusal.
    var installRefusal: String?

    func tableSpecs() -> [PluginTableSpec] { specs }
    func pluginAlerts() -> (seq: Int, alerts: [PluginAlert])? { alerts }
    func acknowledgeAlert(_ id: UInt64) -> Bool { acknowledged.append(id); return true }
    func inspectPlugin(_ path: String) -> String? { note("inspect(\(path))"); return inspectJSON }
    func installPlugin(_ path: String) -> String? { note("install(\(path))"); return installRefusal }

    // MARK: Opening
    var reopenSucceeds = true
    func reopen(charts: [String]) -> Bool {
        note("reopen(\(charts.count))")
        return reopenSucceeds
    }
    func close() { note("close") }

    // MARK: The overlay
    /// The geographic point every screen point maps to, and back. A flat
    /// mapping is enough: no test here is about the projection.
    var geoAt: (lon: Double, lat: Double)? = (lon: -76.0, lat: 39.0)
    var screenAt = CGPoint(x: 100, y: 100)
    var features: [PickDecoded] = []
    var revealPin: OverlayPin?
    var markerList: [ChartMarker] = []
    var markerAt: ChartMarker?
    var panned: [CGFloat] = []
    var renamed: [(UInt64, String)] = []
    var removed: [UInt64] = []

    func geo(atPoint pt: CGPoint) -> (lon: Double, lat: Double)? { geoAt }
    func screenPoint(forGeoLon lon: Double, lat: Double) -> CGPoint { screenAt }
    func pick(lon: Double, lat: Double) -> [PickDecoded] { features }
    func reveal(lon: Double, lat: Double) -> OverlayPin? { revealPin }
    func panRevealingPick(dxPt: CGFloat, dyPt: CGFloat) { panned.append(dyPt) }
    func markers() -> [ChartMarker] { markerList }
    func marker(atPoint p: CGPoint) -> ChartMarker? { markerAt }
    func dropMarker(lon: Double, lat: Double) -> ChartMarker? {
        note("dropMarker")
        return nil
    }
    func renameMarker(_ id: UInt64, to name: String) -> Bool {
        renamed.append((id, name))
        return true
    }
    func removeMarker(_ id: UInt64) -> Bool { removed.append(id); return true }
}
