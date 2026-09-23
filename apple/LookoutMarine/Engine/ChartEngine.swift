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
    /// One chart's picture at a point, drawn by the core. `url` "" is
    /// Lookout's own chart.
    func chartLinkPicture(_ url: String, kind: ChartPictureKind, lon: Double, lat: Double,
                          zoom: Double, width: Int, height: Int) -> ChartPicture
    /// Drop the pictures still being drawn.
    func cancelChartLinkPictures()
    /// Where the chart is now, for a preview every tile shares.
    func viewCenter() -> (lon: Double, lat: Double)?
}

/// Which picture of a chart the core draws. See lookout_chart_link_picture.
enum ChartPictureKind {
    /// The chart on screen as the engine draws it, or one publisher tile.
    case tile
    /// The chart drawn on a second engine with no window.
    case render
}

enum ChartPicture {
    case ready(Image)
    /// The core is drawing it. The list model's revision changes when it is
    /// done.
    case pending
    /// No picture. The view draws its own art.
    case none
}

/// NOAA's chart catalog and the downloads run from it. The core reads the
/// catalog, chooses the cells a region needs and fetches them; these are the
/// calls that start it and read where it got to.
@MainActor
protocol NoaaEngine: AnyObject {
    @discardableResult func noaaRefresh() -> Bool
    /// True when the state has changed since the last call. It also adopts
    /// what the fetcher brought, so the frame loop calls it.
    func noaaChanged() -> Bool
    func noaaState() -> NoaaState
    func noaaCost(regionIDs: String) -> NoaaCost?
    func noaaDownload(regionIDs: String, destination: String, again: Bool)
    /// Make the download hold the picked water: record the pick, delete what
    /// it gave back, fetch what it lacks. Returns the directories taken out.
    func noaaApply(regionIDs: String, destination: String, again: Bool) -> UInt32
    /// One region as the core counts it. Nil before a catalog is read.
    func noaaRegionState(_ regionID: String) -> NoaaRegionState?
    /// How many of the downloaded cells NOAA has reissued. 0 until a catalog
    /// has been read from the network.
    func noaaOutdated() -> UInt32
    func noaaUpdate(destination: String)
    /// True when an update check is due and has started, or still runs.
    func noaaUpdateDue() -> Bool
    /// How often the update check runs, as LOOKOUT_NOAA_CHECK_*.
    func noaaUpdateCheck() -> Int32
    func noaaSetUpdateCheck(_ cadence: Int32)
    func noaaCancel()
    func noaaRegionCoverage(_ regionID: String) -> [GeoBox]
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

/// The calls ChartOpen makes on the chart: open a library, and put it away.
@MainActor
protocol ChartOpenEngine: AnyObject {
    @discardableResult func reopen(charts: [String], requestID: Int) -> Bool
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

extension ChartController: RasterEngine, ChartLinkEngine, PluginEngine,
                          ChartOpenEngine, ReadoutEngine, OverlayEngine {}
