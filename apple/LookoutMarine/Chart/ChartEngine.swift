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
import SwiftUI

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
    /// Is a picture beneath THIS view?
    func rasterOverChart() -> Bool
}

/// What ChartLinksModel asks the chart for. The core owns the list, resolves
/// the styles and persists them, so all of this is "ask" and "read back".
@MainActor
protocol ChartLinkEngine: AnyObject {
    // Each of these goes through a lookout handle. They return false when no
    // chart is open, and the model holds the request until one is.
    @discardableResult func addChartLink(_ link: String) -> Bool
    @discardableResult func refreshChartLink(_ url: String) -> Bool
    @discardableResult func removeChartLink(_ url: String) -> Bool
    @discardableResult func selectChartLink(_ url: String?) -> Bool
    func importChartLinks(_ json: String)
    func chartLinksSnapshot() -> ChartLinkSnapshot?
    /// Read every link's style for the tile its picture comes from.
    func previewChartLinks()
    /// The tile url that pictures one chart at a point, or nil when the style
    /// names no raster tiles.
    func chartLinkPreviewURL(_ url: String, lon: Double, lat: Double, zoom: Int) -> String?
    /// Where the chart is now, for a preview every tile shares.
    func viewCenter() -> (lon: Double, lat: Double)?
    /// The chart as it is drawing. The one true picture of the active chart.
    func snapshot() -> Image?
}

/// What PluginsModel asks the chart for.
@MainActor
/// NOAA's chart catalog and the downloads run from it. The core reads the
/// catalog, chooses the cells a region needs and fetches them; these are the
/// calls that start it and read where it got to.
protocol NoaaEngine: AnyObject {
    @discardableResult func noaaRefresh() -> Bool
    func noaaState() -> NoaaState
    func noaaCost(regionIDs: String) -> (cells: UInt32, bytes: UInt64, held: UInt32)?
    /// Name the NOAA cells already installed, so a pick prices the rest.
    func noaaHave(_ names: [String])
    func noaaDownload(regionIDs: String, destination: String, again: Bool)
    func noaaOutdated(_ have: [NoaaInstalledCell]) -> UInt32
    func noaaUpdate(_ have: [NoaaInstalledCell], destination: String)
    func noaaCancel()
    func noaaRegionCoverage(_ regionID: String) -> [GeoBox]
}

protocol PluginEngine: AnyObject {
    func tableSpecs() -> [PluginTableSpec]
    func pluginAlerts() -> (seq: Int, alerts: [PluginAlert])?
    func acknowledgeAlert(_ id: UInt64) -> Bool
    func inspectPlugin(_ path: String) -> String?
    func installPlugin(_ path: String) -> String?
}

/// What ReadoutsModel reads every frame. All getters: the render tick reads,
/// it never asks for anything.
@MainActor
protocol ReadoutEngine: AnyObject {
    var currentView: lookout_view { get }
    var followState: Int { get }
    var courseUpState: Int { get }
    var pluginsActive: Bool { get }
    var scaleDenominator: Double { get }
    var overscale: Double { get }
    var schemeIndex: Int { get }
    var stillBuilding: Bool { get }
    func ownShip() -> (state: FixState, lat: Double, lon: Double)?
}

/// What ChartsModel asks the chart for: open a library, and put it away.
@MainActor
protocol ChartOpenEngine: AnyObject {
    @discardableResult func reopen(charts: [String]) -> Bool
    func close()
}

/// What OverlayModel asks the chart for: where a screen point is on the earth
/// and back, what is under it, and the mariner's own marks.
@MainActor
protocol OverlayEngine: AnyObject {
    func geo(atPoint pt: CGPoint) -> (lon: Double, lat: Double)?
    func screenPoint(forGeoLon lon: Double, lat: Double) -> CGPoint
    func pick(lon: Double, lat: Double) -> [PickDecoded]
    func reveal(lon: Double, lat: Double) -> OverlayPin?
    func panRevealingPick(dxPt: CGFloat, dyPt: CGFloat)
    func markers() -> [ChartMarker]
    func marker(atPoint p: CGPoint) -> ChartMarker?
    @discardableResult func dropMarker(lon: Double, lat: Double) -> ChartMarker?
    @discardableResult func renameMarker(_ id: UInt64, to name: String) -> Bool
    @discardableResult func removeMarker(_ id: UInt64) -> Bool
}

extension ChartController: RasterEngine, ChartLinkEngine, NoaaEngine, PluginEngine,
                          ChartOpenEngine, ReadoutEngine, OverlayEngine {}
