//  ChartController.swift
//
//  The single owner of the `lookout*` handle and the single funnel for every
//  `lookout_*` call. Per the engine's hard threading contract, ALL of these must
//  run on ONE thread — the main thread — so the whole class is @MainActor.
//
//  It also drives the on-demand render loop: a CADisplayLink that renders only
//  while something is animating or the scene is dirty, and pauses itself when the
//  chart is static (so idle costs ~0% CPU). Every mutating call resumes it.
//
//  Coordinate units (see include/lookout.h):
//    • open / resize / pan / zoom       — LOGICAL POINTS (lookout scales by
//                                         pixel density internally)
//    • screen_to_geo / geo_to_screen    — LOGICAL POINTS too (the camera is
//                                         logical-native; multiplying by
//                                         density here sent every tap ~density
//                                         times too far from the view centre).
//  All unit conversion is centralized in this file; callers speak in points.

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import QuartzCore

/// One S-57 feature returned by a cursor pick.
struct PickFeature: Identifiable, Hashable {
    let id = UUID()
    let cls: String     // S-57 object-class acronym (e.g. "LIGHTS", "DEPARE")
    let chart: String   // source cell name
    let s57: String     // full S-57 attribute JSON (unused in the HUD line)
}

@MainActor
final class ChartController: NSObject {
    /// The opaque `lookout*`. nil until a chart is opened.
    private(set) var handle: OpaquePointer?
    /// Path (or directory) of the chart currently open, for the title/Recent.
    private(set) var chartPath: String?

    /// The backing view we render into; used for center-anchored zoom and to
    /// build the display link.
    private weak var view: PlatformView?

    /// Pushed live readouts to the UI (cursor coord, scale, scheme, rotation…).
    weak var model: AppModel?

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var idleTicks = 0
    /// Rendering runs OFF the main thread so UIKit gesture bursts can never
    /// delay a frame slot (the 120Hz budget is 8.3ms). The display link stays
    /// on main as the pacemaker; each tick hands one render to this queue.
    /// The C ABI serializes itself (api_mu), so gestures landing mid-render
    /// simply wait a millisecond or two.
    private let renderQueue = DispatchQueue(label: "lookout.render", qos: .userInteractive)
    /// Main-thread-only: a render is queued or running; further ticks skip
    /// instead of piling up (the link fires again next vsync anyway).
    private var renderInFlight = false

    // MARK: - Lifecycle

    /// Open (or re-open) a single baked `.pmtiles` chart into `view`.
    @discardableResult
    func open(chart path: String, in view: PlatformView) -> Bool {
        open(charts: [path], in: view)
    }

    /// Open one or more baked charts into `view` and compose them (a chart
    /// library / a directory of cells). Returns false on failure. Recreates the
    /// handle if one already exists.
    @discardableResult
    func open(charts paths: [String], in view: PlatformView) -> Bool {
        guard !paths.isEmpty else { return false }
        close()
        self.view = view
        model?.firstBuildDone = false

        let (wPt, hPt) = Self.pointSize(of: view)
        // Both platforms: lookout renders via Metal straight into the view's
        // own CAMetalLayer. The layer stays host-owned; lookout only attaches
        // its device and presents drawables.
        guard let layer = Platform.metalLayer(of: view) else {
            lkLog("open FAILED — the chart view has no CAMetalLayer backing")
            model?.openError = "The chart view has no Metal layer."
            return false
        }
        let kind = LOOKOUT_NATIVE_METAL_LAYER
        let nativePtr: UnsafeMutableRawPointer? = Unmanaged.passUnretained(layer).toOpaque()
        lkLog("opening \(paths.count) chart(s) into a \(Int(wPt))×\(Int(hPt))pt view: \(paths.first ?? "")")
        let opened: OpaquePointer? = withCStrings(paths) { cpaths in
            if cpaths.count == 1 {
                return lookout_open_in_window(kind, nativePtr, cpaths[0],
                                              UInt32(wPt), UInt32(hPt), 1)
            }
            return cpaths.withUnsafeBufferPointer { buf in
                lookout_open_charts_in_window(kind, nativePtr, buf.baseAddress,
                                              buf.count, UInt32(wPt), UInt32(hPt), 1)
            }
        }
        guard let h = opened else {
            lkLog("open FAILED (lookout_open_in_window returned null — GPU device or chart file?)")
            model?.openError = "Couldn't open the chart.\nThe file may be unreadable, or the Metal device couldn't be created."
            return false
        }
        lkLog("open OK")
        model?.openError = nil
        handle = h
        chartPath = paths.count == 1
            ? paths[0]
            : ((paths[0] as NSString).deletingLastPathComponent)

        // Fit the whole cell/library as the initial view.
        var v = lookout_view()
        lookout_fit_chart(h, &v)
        lookout_set_view(h, &v)

        // HiDPI physical sizing: the engine reads pixel density from the swapchain,
        // but the mariner's device_scale (symbol/text physical size) is set from the
        // backing scale factor here in the bridge, per the app spec.
        syncDeviceScale()

        startDisplayLink()
        pushReadouts()
        model?.hasChart = true
        model?.chartPath = chartPath
        return true
    }

    /// Attach the surface we render into, WITHOUT opening a chart yet. iOS calls
    /// this as soon as ChartUIView has a window, so a mid-session open (importing
    /// a chart when the app launched with none) has a view to reopen into — on
    /// iOS the chart lives in ChartUIView, and there is no SwiftUI representable
    /// to service a pending openRequest as a fallback.
    func attachView(_ v: PlatformView) {
        if view == nil { view = v }
    }

    /// Re-open into the view we already render into (menu/search/panel opens
    /// after the first open — the AppModel calls this directly because SwiftUI
    /// stops updating the wrapped content view). False when no view yet.
    @discardableResult
    func reopen(charts paths: [String]) -> Bool {
        guard let view else { return false }
        return open(charts: paths, in: view)
    }

    func close() {
        stopDisplayLink()
        // The render queue is the only other caller into the handle; a sync
        // barrier here means close never destroys a lookout mid-render (the
        // ABI's api_mu cannot protect against its own destruction).
        let h = handle
        handle = nil
        renderQueue.sync {}
        if let h { lookout_close(h) }
    }

    // MARK: - Render loop (on-demand)

    private func startDisplayLink() {
        stopDisplayLink()
        guard let view else { return }
        let link = Platform.makeDisplayLink(for: view, target: self,
                                            selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        lastTimestamp = 0
        idleTicks = 0
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Resume ticking after any state change (mutating calls funnel through here).
    private func kick() {
        idleTicks = 0
        if let link = displayLink {
            if link.isPaused { lastTimestamp = 0; link.isPaused = false }
        } else {
            startDisplayLink()
        }
    }

    // CADisplayLink fires on the main run loop; assume main-actor isolation.
    @objc private nonisolated func displayLinkFired(_ link: CADisplayLink) {
        MainActor.assumeIsolated { self.step(link) }
    }

    private func step(_ link: CADisplayLink) {
        guard let h = handle else { return }
        let now = link.timestamp
        var dt = lastTimestamp == 0 ? 0 : now - lastTimestamp
        lastTimestamp = now
        if dt > 0.05 { dt = 0.05 } // cap after an idle gap

        let animating = lookout_animating(h) != 0
        if animating { lookout_tick_anim(h, dt) }

        let building = lookout_is_building(h) != 0
        if model?.isBuilding != building { model?.isBuilding = building }

        if animating || lookout_needs_redraw(h) != 0 {
            if !renderInFlight {
                renderInFlight = true
                renderQueue.async { [weak self] in
                    _ = lookout_render(h)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.renderInFlight = false
                        self.pushReadouts()
                    }
                }
            }
            idleTicks = 0
        } else if building {
            // A background tessellation is filling in — keep ticking so it appears.
            idleTicks = 0
        } else {
            // Static: pause after a couple of quiet ticks so idle is ~0% CPU.
            // Reaching idle also means the first scene after an open has
            // rendered — retire the startup loader.
            if model?.firstBuildDone == false { model?.firstBuildDone = true }
            idleTicks += 1
            if idleTicks > 2 { link.isPaused = true }
        }
    }

    // MARK: - View

    var currentView: lookout_view {
        guard let h = handle else { return lookout_view() }
        var v = lookout_view()
        lookout_get_view(h, &v)
        return v
    }

    func setView(_ v: lookout_view) {
        guard let h = handle else { return }
        var vv = v
        lookout_set_view(h, &vv)
        kick(); pushReadouts()
    }

    func fitChart() {
        guard let h = handle else { return }
        var v = lookout_view()
        lookout_fit_chart(h, &v)
        lookout_set_view(h, &v)
        kick(); pushReadouts()
    }

    /// Resize the surface. `wPt`/`hPt` are logical points.
    func resize(widthPt wPt: Double, heightPt hPt: Double) {
        guard let h = handle, wPt > 0, hPt > 0 else { return }
        _ = lookout_resize(h, UInt32(wPt.rounded()), UInt32(hPt.rounded()))
        kick()
    }

    var pixelDensity: CGFloat {
        guard let h = handle else { return 1 }
        return CGFloat(lookout_pixel_density(h))
    }

    // MARK: - Interaction (points in; pixels handled internally)

    func pan(dxPt: CGFloat, dyPt: CGFloat) {
        guard let h = handle else { return }
        lookout_pan_logical(h, Float(dxPt), Float(dyPt))
        kick()
    }

    func zoom(_ dz: Double, atPt pt: CGPoint) {
        guard let h = handle else { return }
        lookout_zoom_at_logical(h, dz, Float(pt.x), Float(pt.y))
        kick()
    }

    /// Center-anchored zoom (menu / buttons).
    func zoomCentered(_ dz: Double) {
        guard let view else { return }
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        zoom(dz, atPt: c)
    }

    func rotateDrag(from a: CGPoint, to b: CGPoint) {
        guard let h = handle else { return }
        lookout_rotate_drag_logical(h, Float(a.x), Float(a.y), Float(b.x), Float(b.y))
        kick(); pushReadouts()
    }

    func resetRotation() {
        guard let h = handle else { return }
        lookout_reset_rotation(h)
        kick(); pushReadouts()
    }

    func flingStart(vx: Double, vy: Double) {
        guard let h = handle else { return }
        lookout_fling_start(h, vx, vy)
        kick()
    }

    // MARK: - Geo <-> screen (points API; pixels under the hood)

    /// Chart lon/lat under a view point (top-left origin — the view is flipped).
    func geo(atPoint pt: CGPoint) -> (lon: Double, lat: Double)? {
        guard let h = handle else { return nil }
        var lon = 0.0, lat = 0.0
        lookout_screen_to_geo(h, Float(pt.x), Float(pt.y), &lon, &lat)
        return (lon, lat)
    }

    /// View point (top-left origin) for a chart lon/lat.
    func screenPoint(forGeoLon lon: Double, lat: Double) -> CGPoint {
        guard let h = handle else { return .zero }
        var x: Float = 0, y: Float = 0
        lookout_geo_to_screen(h, lon, lat, &x, &y)
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    // MARK: - Mariner state

    func getMariner() -> tile57_mariner {
        var m = tile57_mariner()
        if let h = handle { lookout_get_mariner(h, &m) } else { lookout_mariner_defaults(&m) }
        return m
    }

    func setMariner(_ m: tile57_mariner) {
        guard let h = handle else { return }
        var mm = m
        lookout_set_mariner(h, &mm)
        kick(); pushReadouts()
    }

    /// Set mariner.device_scale from the view's backing scale factor (physical
    /// symbol sizing), preserving every other field.
    func syncDeviceScale() {
        guard handle != nil, let view else { return }
        var m = getMariner()
        m.device_scale = Double(Platform.backingScale(of: view))
        setMariner(m)
    }

    // MARK: - Convenience live toggles

    func cycleScheme()        { guard let h = handle else { return }; lookout_cycle_scheme(h); kick(); pushReadouts() }
    func toggleText()         { guard let h = handle else { return }; lookout_toggle_text(h); kick() }
    func toggleSoundings()    { guard let h = handle else { return }; lookout_toggle_soundings(h); kick() }
    func toggleOtherCategory(){ guard let h = handle else { return }; lookout_toggle_other_category(h); kick() }
    func nudgeSafetyContour(_ d: Double) { guard let h = handle else { return }; lookout_nudge_safety_contour(h, d); kick() }
    func adjustSize(_ f: Float) { guard let h = handle else { return }; lookout_adjust_size(h, f); kick() }

    var scaleDenominator: Double {
        guard let h = handle else { return 0 }
        return lookout_scale_denominator(h)
    }

    // MARK: - Pick (tap-to-identify)

    func pick(lon: Double, lat: Double) -> [PickFeature] {
        guard let h = handle else { return [] }
        var results: [PickFeature] = []
        withUnsafeMutablePointer(to: &results) { ctx in
            var cb = tile57_query_cb(
                ctx: UnsafeMutableRawPointer(ctx),
                feature: { c, cls, clsLen, s57, s57Len, chart, chartLen in
                    guard let c else { return }
                    let arr = c.assumingMemoryBound(to: [PickFeature].self)
                    func str(_ p: UnsafePointer<CChar>?, _ n: Int) -> String {
                        guard let p, n > 0 else { return "" }
                        return String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
                    }
                    arr.pointee.append(PickFeature(cls: str(cls, clsLen),
                                                   chart: str(chart, chartLen),
                                                   s57: str(s57, s57Len)))
                })
            lookout_pick(h, lon, lat, &cb)
        }
        return results
    }

    // MARK: - Push live readouts to the UI

    private var lastReadoutsAt: TimeInterval = 0
    private func pushReadouts() {
        guard let model, let h = handle else { return }
        // @Published fires objectWillChange on ASSIGNMENT, changed or not — an
        // unconditional push per rendered frame re-evaluated the SwiftUI HUD at
        // frame rate and showed up as per-frame AttributeGraph work in a
        // gesture profile. Throttle to 10Hz (readouts are human-readable text)
        // and only assign what actually changed.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReadoutsAt < 0.1 { return }
        lastReadoutsAt = now
        var v = lookout_view()
        lookout_get_view(h, &v)
        if model.rotationDeg != v.rotation_deg { model.rotationDeg = v.rotation_deg }
        if model.zoomLevel != v.zoom { model.zoomLevel = v.zoom }
        let sd = lookout_scale_denominator(h)
        if model.scaleDenominator != sd { model.scaleDenominator = sd }
        var m = tile57_mariner()
        lookout_get_mariner(h, &m)
        let sch = Int(m.scheme.rawValue)
        if model.scheme != sch { model.scheme = sch }
    }

    // MARK: - Helpers

    /// Logical point size of a view (falls back to a sane default before layout).
    private static func pointSize(of view: PlatformView) -> (Double, Double) {
        let b = view.bounds.size
        let w = b.width > 1 ? Double(b.width) : 1280
        let h = b.height > 1 ? Double(b.height) : 800
        return (w.rounded(), h.rounded())
    }
}

/// Run `body` with an array of C strings valid only for its duration. Elements
/// are optional to match C's `const char *const *` (nullable inner pointers).
/// Iterative on purpose: nesting one withCString closure per element blew the
/// 1 MB iOS main-thread stack at chart-library scale (7k+ cells).
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafePointer<CChar>?]) -> R) -> R {
    let dups: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { dups.forEach { free($0) } }
    return body(dups.map { UnsafePointer($0) })
}
