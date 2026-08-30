//  ChartEngine.swift — the narrow ways each area model reaches the chart.
//
//  Every model here needs the core for something, and before these existed each
//  one held the whole ChartController and could call anything on it. One
//  protocol per area names what that area actually uses and nothing else, so
//  the raster model cannot pick a feature and the plugin model cannot move the
//  camera.
//
//  The second reason is testing. A model that holds a ChartController needs a
//  chart handle to exercise, which means a cell on disk, a bake, and a render
//  thread. A model that holds one of these needs a struct that answers.
//
//  ChartController conforms to all of them; the conformances are at the bottom
//  and are empty, because the methods are already there.

import Foundation

/// What RasterModel asks the chart for.
@MainActor
protocol RasterEngine: AnyObject {
    @discardableResult func addRaster(_ path: String) -> Bool
    @discardableResult func setRasterEnabled(_ path: String, _ on: Bool) -> Bool
    func rasterSets() -> [RasterSet]
    func rasterName() -> String
    func rasterActiveIndex() -> Int
    func rasterAvailableName() -> String
    func rasterSelect(_ i: Int)
    func cycleRaster()
    func toggleChart()
    func chartHidden() -> Bool
}

/// What ChartLinksModel asks the chart for. The core owns the list, resolves
/// the styles and persists them, so all of this is "ask" and "read back".
@MainActor
protocol ChartLinkEngine: AnyObject {
    func addChartLink(_ link: String)
    func refreshChartLink(_ url: String)
    func removeChartLink(_ url: String)
    func selectChartLink(_ url: String?)
    func importChartLinks(_ json: String)
    func chartLinksSnapshot() -> String?
}

/// What PluginsModel asks the chart for.
@MainActor
protocol PluginEngine: AnyObject {
    func tableSpecs() -> [PluginTableSpec]
    func pluginAlerts() -> (seq: Int, alerts: [PluginAlert])?
    func acknowledgeAlert(_ id: UInt64) -> Bool
    func inspectPlugin(_ path: String) -> String?
    func installPlugin(_ path: String) -> String?
}

/// What OverlayModel asks the chart for: where a screen point is on the earth
/// and back, what is under it, and the mariner's own marks.
@MainActor
protocol OverlayEngine: AnyObject {
    func geo(atPoint pt: CGPoint) -> (lon: Double, lat: Double)?
    func screenPoint(forGeoLon lon: Double, lat: Double) -> CGPoint
    func pick(lon: Double, lat: Double) -> [PickFeature]
    func reveal(lon: Double, lat: Double) -> OverlayPin?
    func panRevealingPick(dxPt: CGFloat, dyPt: CGFloat)
    func markers() -> [ChartMarker]
    func marker(atPoint p: CGPoint) -> ChartMarker?
    @discardableResult func dropMarker(lon: Double, lat: Double) -> ChartMarker?
    @discardableResult func renameMarker(_ id: UInt64, to name: String) -> Bool
    @discardableResult func removeMarker(_ id: UInt64) -> Bool
}

extension ChartController: RasterEngine, ChartLinkEngine, PluginEngine, OverlayEngine {}
