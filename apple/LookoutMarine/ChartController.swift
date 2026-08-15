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
/// One overlay object the mariner pinned: which object it is, what it says
/// now, and where it draws now. Re-read from the core every render tick.
struct OverlayPin: Equatable {
    let id: String
    var info: OverlayHover
    var lon: Double
    var lat: Double
}

/// What a plugin overlay symbol says about itself. Decoded from the JSON
/// `lookout_overlay_at` returns.
struct OverlayHover: Equatable {
    let title: String
    let rows: [(String, String)]

    static func == (a: OverlayHover, b: OverlayHover) -> Bool {
        a.title == b.title && a.rows.count == b.rows.count
            && zip(a.rows, b.rows).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    init?(json: Data) {
        guard let top = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let title = top["title"] as? String else { return nil }
        self.title = title
        self.rows = (top["rows"] as? [[String]] ?? []).compactMap {
            $0.count >= 2 ? ($0[0], $0[1]) : nil
        }
    }
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
    /// Runs only while the display link is paused and plugins are loaded.
    /// See "Idle poll" below.
    private var idlePoll: Timer?
    /// Rendering runs OFF the main thread so UIKit gesture bursts can never
    /// delay a frame slot (the 120Hz budget is 8.3ms). The display link stays
    /// on main as the pacemaker; each tick hands one render to this queue.
    /// The C ABI serializes itself (api_mu), so gestures landing mid-render
    /// simply wait a millisecond or two.
    private let renderQueue = DispatchQueue(label: "lookout.render", qos: .userInteractive)
    /// One-render-at-a-time gate. A semaphore, NOT a main-thread flag: the
    /// gate must reopen the INSTANT the render returns, on the render thread —
    /// clearing it via a main-queue hop meant the next 120Hz tick often found
    /// it still closed (main busy with gestures) and skipped, capping the loop
    /// at ~half the link rate exactly during interaction.
    private let renderGate = DispatchSemaphore(value: 1)

    /// $LOOKOUT_FRAME_PROF=<path>: one CSV row per display-link tick, so the
    /// INTERACTIVE path can be measured on the app. The offscreen harnesses
    /// (--bench, --sweep) render from a settled camera with tiles resident and
    /// cannot show what a moving camera costs, which is the whole of what
    /// "pan/zoom feels bad" turned out to be.
    ///
    /// Columns: ms since start, tick gap ms, whether the tick dispatched a
    /// render, whether the gate was shut (the frame was DROPPED), the render's
    /// own ms, and whether a build was outstanding.
    private var frameProf: FrameProfiler?

    /// $LOOKOUT_GESTURE_BENCH=pan|zoom|both: drive a scripted gesture through
    /// the same entry points a finger uses, so a run is repeatable and needs
    /// no one at the trackpad. Writes the frame profile above and quits.
    private var gestureBench: GestureBench?

    /// Serves an alt chart style's tiles. Idle — no callback installed on the
    /// core, nothing fetched — until a style is set. See AltChartStyle.swift.
    private let altTiles = AltChartTiles()

    // MARK: - Lifecycle

    /// Open (or re-open) a single baked `.pmtiles` chart into `view`.
    @discardableResult
    func open(chart path: String, in view: PlatformView) -> Bool {
        open(charts: [path], in: view)
    }

    /// Open one or more baked charts into `view` and compose them (a chart
    /// library / a directory of cells). Returns false on failure. Recreates the
    /// handle if one already exists.
    /// An empty list is not a failure: a set of raster charts alone opens with
    /// no vector chart, and the pictures are installed below.
    @discardableResult
    func open(charts paths: [String], in view: PlatformView) -> Bool {
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
        // The tile door, before anything can ask through it. A style set on the
        // old handle does not survive — the model pushes it back below, the
        // same way the raster charts are replayed.
        altTiles.attach(to: h)
        // Empty is legal: a library of pictures alone opens with no cell, and
        // then there is no chart path to report.
        chartPath = paths.isEmpty ? nil
            : (paths.count == 1 ? paths[0] : (paths[0] as NSString).deletingLastPathComponent)

        // Re-install the mariner's raster charts. A raster chart is attached to a
        // lookout handle, and `close()` above destroyed the old one, so every
        // open has to replay them — that is what makes a raster chart survive both
        // switching charts and relaunching the app.
        if let paths = model?.rasterPaths, !paths.isEmpty {
            var ok = 0
            for p in paths where addRaster(p) {
                ok += 1
                if model?.rasterOff.contains(p) == true { setRasterEnabled(p, false) }
            }
            // After every source is in, because switching one chart off can move
            // which set is drawn, and the saved answer is the one that wins.
            restoreRasterShown()
            lkLog("raster: \(ok)/\(paths.count) source(s) re-installed, \(model?.rasterHidden.count ?? 0) set(s) off")
            model?.rasterName = rasterName()
        }
        // The ENC-over-picture state belongs to the mariner too, and it only
        // does anything where a picture covers, so it is safe to put back before
        // knowing whether one does.
        if model?.chartHiddenSaved == true { setChartHidden(true) }
        // A linked chart, if one was picked. Its style is re-fetched, so this
        // lands a moment later than the rest of the replay.
        model?.chartDidOpen()

        // Reopen where we left off. With nothing saved the opening view is the
        // engine's own (lookout_default_view) — the same policy every host gets,
        // rather than each shell inventing its own idea of "the initial view".
        var v = lookout_view()
        if let saved = ViewState.load() {
            v = saved
        } else {
            lookout_default_view(h, &v)
        }
        lookout_set_view(h, &v)

        // Dev hook, mirroring $LOOKOUT_OPEN: $LOOKOUT_VIEW="lon,lat,zoom[,rot]"
        // replaces the fit view at open — deterministic framing for dev runs
        // and screenshots (simctl forwards it as SIMCTL_CHILD_LOOKOUT_VIEW).
        if let spec = ProcessInfo.processInfo.environment["LOOKOUT_VIEW"] {
            let p = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if p.count >= 3 {
                v = lookout_view(lon: p[0], lat: p[1], zoom: p[2],
                                 rotation_deg: p.count > 3 ? p[3] : 0)
                lookout_set_view(h, &v)
            } else {
                lkLog("ignoring malformed LOOKOUT_VIEW '\(spec)' (want lon,lat,zoom[,rot])")
            }
        }

        // Dev hooks for the interactive-path profile. Both off unless
        // asked for; see FrameProfiler / GestureBench at the end of this file.
        if let p = ProcessInfo.processInfo.environment["LOOKOUT_FRAME_PROF"], !p.isEmpty {
            frameProf = FrameProfiler(path: p)
        }
        if let spec = ProcessInfo.processInfo.environment["LOOKOUT_GESTURE_BENCH"], !spec.isEmpty {
            gestureBench = GestureBench(spec: spec)
        }

        // HiDPI physical sizing: the engine reads pixel density from the swapchain,
        // but the mariner's device_scale (symbol/text physical size) is set from the
        // backing scale factor here in the bridge, per the app spec.
        syncDeviceScale()

        // Saved mariner settings (contours, scheme, toggles) overlay the engine
        // defaults — the settings form saves on every applied edit, so the
        // chart reopens exactly as the mariner left it.
        var mm = getMariner()
        MarinerSettings.applySavedOverlay(&mm)
        setMariner(mm)

        // The plugin sets, in the order that decides an id collision: whatever
        // LOOKOUT_PLUGINS brought up inside lookout_open loaded first, so a
        // developer copy keeps its id; then the set that ships inside the app,
        // so a mariner who has installed nothing still gets own ship, AIS,
        // NMEA 0183, Signal K and laylines; then the installed set. Either of
        // the two calls creates the plugin layer when nothing has yet.
        loadBundledPlugins()
        loadInstalledPlugins()

        // The plugins are up, so their saved settings can go in now. A plugin
        // with none stays on its manifest defaults.
        PluginSettings.applySaved(to: self)

        #if os(macOS)
        // And their declared tables can take their place in the menu bar.
        model?.refreshPluginTables()
        #endif
        // Anything they raise from here on reaches the mariner — on both
        // platforms; the banner and siren are cross-platform.
        model?.startAlertWatch()

        startDisplayLink()
        pushReadouts()
        model?.hasChart = true
        model?.chartPath = chartPath
        // A .lkplug opened before the chart was up waited for the plugin
        // layer; it can go to its consent sheet now.
        model?.drainPendingInstall()
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

    /// True once a chart is open, so a caller can tell adding from opening.
    var hasHandle: Bool { handle != nil }

    /// Add charts to the library that is already open, keeping the view and
    /// what is drawn. Answers how many opened.
    ///
    /// This is not a reopen. The composition is rebuilt on a worker and swapped
    /// in when ready, so the charts already on screen keep drawing meanwhile.
    @discardableResult
    func addCharts(_ paths: [String]) -> Int {
        guard let h = handle, !paths.isEmpty else { return 0 }
        var c = paths.map { strdup($0) }
        defer { c.forEach { free($0) } }
        let added = c.withUnsafeMutableBufferPointer { buf in
            buf.withMemoryRebound(to: UnsafePointer<CChar>?.self) { p in
                lookout_charts_add(h, p.baseAddress, paths.count)
            }
        }
        if added > 0 { kick() }
        return Int(added)
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
        // The plugins go with the handle, so nothing is left watching the
        // conditions their alarms describe.
        model?.stopAlertWatch()
        // The render queue is the only other caller into the handle; a sync
        // barrier here means close never destroys a lookout mid-render (the
        // ABI's api_mu cannot protect against its own destruction).
        // Before the barrier: this clears the core's callback and cancels the
        // fetches still out, so nothing can answer into a handle that is about
        // to be destroyed.
        altTiles.detach()
        let h = handle
        handle = nil
        renderQueue.sync {}
        if let h {
            var v = lookout_view()
            lookout_get_view(h, &v) // the pose to reopen on, before the handle dies
            ViewState.save(v)
            lookout_close(h)
        }
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
        stopIdlePoll()
    }

    /// A pick report and the chart menu both belong to the view they were
    /// raised in: both describe one point on the water. Any camera move
    /// retires them, so neither floats over water it does not describe.
    ///
    /// The rename field is not in here. It is anchored to its marker and
    /// re-projected every frame, and a mariner typing a name while the boat
    /// drifts under follow must not lose what they typed.
    private func retireChartChrome() {
        if model?.pickPoint != nil { model?.closePick() }
        if model?.chartMenu != nil { model?.closeChartMenu() }
    }

    /// Resume ticking after any state change (mutating calls funnel through here).
    private func kick() {
        stopIdlePoll()
        idleTicks = 0
        if let link = displayLink {
            if link.isPaused { lastTimestamp = 0; link.isPaused = false }
        } else {
            startDisplayLink()
        }
    }

    // MARK: - Idle poll
    //
    // The display link pauses when nothing is moving, and only input restarts
    // it. A plugin posts geometry with no input behind it, so while plugins
    // are loaded a timer polls needs-redraw and kicks the link when it answers
    // yes. Without it, AIS traffic froze until the mariner touched the
    // trackpad.

    /// Poll rate while paused. The AIS store coalesces to 2 Hz; this is twice
    /// that.
    private static let idlePollInterval: TimeInterval = 0.25

    private func startIdlePoll() {
        guard idlePoll == nil, let h = handle, lookout_plugins_active(h) != 0 else { return }
        idlePoll = Timer.scheduledTimer(withTimeInterval: Self.idlePollInterval,
                                        repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let h = self.handle else { return }
                if lookout_needs_redraw(h) != 0 { self.kick() }
            }
        }
    }

    private func stopIdlePoll() {
        idlePoll?.invalidate()
        idlePoll = nil
    }

    // MARK: - Overlay hover

    /// What the plugin overlay says about the symbol nearest a point, in
    /// logical points. nil when nothing is near it.
    func overlayInfo(atPoint p: CGPoint) -> OverlayHover? {
        guard let h = handle else { return nil }
        var len = 0
        guard let raw = lookout_overlay_at(h, Float(p.x), Float(p.y), &len), len > 0 else {
            return nil
        }
        // Borrowed until the next call, so copy before anything else runs.
        return OverlayHover(json: Data(bytes: raw, count: len))
    }

    /// The overlay object under a point, with its id and anchor. nil when
    /// nothing is near it. A tap uses this; hover uses `overlayInfo(atPoint:)`.
    func overlayHit(atPoint p: CGPoint) -> OverlayPin? {
        guard let h = handle else { return nil }
        var o = lookout_overlay_obj()
        guard lookout_overlay_hit(h, Float(p.x), Float(p.y), &o) != 0 else { return nil }
        return pin(from: o)
    }

    /// What a pinned object says now, or nil once it is gone.
    func overlayInfo(id: String) -> OverlayPin? {
        guard let h = handle else { return nil }
        var o = lookout_overlay_obj()
        guard id.withCString({ lookout_overlay_info(h, $0, &o) }) != 0 else { return nil }
        return pin(from: o)
    }

    /// Everything in the struct is borrowed until the next overlay call, so
    /// copy both strings out before anything else runs.
    private func pin(from o: lookout_overlay_obj) -> OverlayPin? {
        guard let idp = o.id, let infop = o.info, o.info_len > 0 else { return nil }
        let id = String(cString: idp)
        guard let info = OverlayHover(json: Data(bytes: infop, count: o.info_len)) else { return nil }
        return OverlayPin(id: id, info: info, lon: o.lon, lat: o.lat)
    }

    // CADisplayLink fires on the main run loop; assume main-actor isolation.
    @objc private nonisolated func displayLinkFired(_ link: CADisplayLink) {
        MainActor.assumeIsolated { self.step(link) }
    }

    /// Chrome that belongs to a place on the chart — the pick mark and a
    /// pinned bubble — re-projected every frame. Follow moves the chart with
    /// no gesture behind it, so a point measured when the mariner tapped
    /// slides off its object. Assigns only on a real move: @Published fires
    /// on assignment, and this runs at frame rate.
    private func syncGeoChrome() {
        guard let model else { return }
        if let g = model.pickGeo, model.pickPoint != nil {
            let p = screenPoint(forGeoLon: g.lon, lat: g.lat)
            if moved(model.pickPoint, p) { model.pickPoint = p }
        }
        // The rename field rides its marker, for the same reason.
        if let r = model.renaming {
            let p = screenPoint(forGeoLon: r.lon, lat: r.lat)
            if moved(model.renamingPoint, p) { model.renamingPoint = p }
        }
        // A pinned bubble is re-read, not remembered: the target moves, its
        // values change, and it goes away when the plugin drops it.
        if let pinned = model.pinned {
            if let now = overlayInfo(id: pinned.id) {
                if model.pinned != now { model.pinned = now }
                let p = screenPoint(forGeoLon: now.lon, lat: now.lat)
                if moved(model.pinnedPoint, p) { model.pinnedPoint = p }
            } else {
                model.closePin()
            }
        }
    }

    private func moved(_ a: CGPoint?, _ b: CGPoint) -> Bool {
        guard let a else { return true }
        return abs(a.x - b.x) >= 0.5 || abs(a.y - b.y) >= 0.5
    }

    private func step(_ link: CADisplayLink) {
        guard let h = handle else { return }

        // Claim the render slot BEFORE touching the core. Every lookout_* call
        // takes the engine's api lock, and a render holds it for its whole
        // span — including the present, which blocks on the swapchain drawable
        // (measured: 0.2 ms typical, 73 ms at p99). A tick that cannot render
        // anyway must not go and wait on that lock: doing so stalled the main
        // thread, and with it the display link and every queued gesture, for
        // the length of someone else's frame.
        //
        // Skipping is safe for the animation: `dt` is measured from the last
        // tick that RAN, so the next one advances by the whole elapsed time
        // rather than losing it.
        guard renderGate.wait(timeout: .now()) == .success else {
            frameProf?.tick(gap: link.timestamp - lastTimestamp, dispatched: false,
                            dropped: true, building: true, zoom: 0)
            return
        }
        var slotHeld = true
        defer { if slotHeld { renderGate.signal() } }

        let now = link.timestamp
        var dt = lastTimestamp == 0 ? 0 : now - lastTimestamp
        lastTimestamp = now
        if dt > 0.05 { dt = 0.05 } // cap after an idle gap

        let animating = lookout_animating(h) != 0
        if animating { lookout_tick_anim(h, dt) }

        let building = lookout_is_building(h) != 0
        if model?.isBuilding != building { model?.isBuilding = building }

        gestureBench?.step(self)

        var zoomNow: Double = 0
        if frameProf != nil {
            var v = lookout_view()
            lookout_get_view(h, &v)
            zoomNow = v.zoom
        }

        if animating || lookout_needs_redraw(h) != 0 {
            let prof = frameProf
            prof?.tick(gap: dt, dispatched: true, dropped: false, building: building, zoom: zoomNow)
            // The slot passes to the render; it signals the gate when done.
            slotHeld = false
            renderQueue.async { [weak self] in
                let t0 = CACurrentMediaTime()
                _ = lookout_render(h)
                prof?.rendered(ms: (CACurrentMediaTime() - t0) * 1000)
                self?.renderGate.signal()
                DispatchQueue.main.async {
                    self?.syncGeoChrome()
                    self?.pushReadouts()
                }
            }
            idleTicks = 0
            // The first scene is up once a frame has gone out with no build
            // outstanding. Own ship moves between fixes, so with plugins
            // running the loop may never reach the idle branch below.
            if !building, model?.firstBuildDone == false { model?.firstBuildDone = true }
        } else if building {
            // A background tessellation is filling in — keep ticking so it appears.
            idleTicks = 0
        } else {
            // Static: pause after a couple of quiet ticks so idle is ~0% CPU.
            // Reaching idle also means the first scene after an open has
            // rendered — retire the startup loader.
            if model?.firstBuildDone == false { model?.firstBuildDone = true }
            idleTicks += 1
            // A gesture bench drives from this tick, so pausing would strand it
            // in whatever phase it had reached.
            if idleTicks > 2 && gestureBench == nil {
                link.isPaused = true
                startIdlePoll()
            }
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
        retireChartChrome()
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
        retireChartChrome()
        kick()
    }

    /// Pan without retiring the pick report.
    ///
    /// The app makes this move itself, to show the object that its own report
    /// covers. `pan` retires the report, which is correct for a move by the
    /// mariner and wrong here.
    func panRevealingPick(dxPt: CGFloat, dyPt: CGFloat) {
        guard let h = handle else { return }
        lookout_pan_logical(h, Float(dxPt), Float(dyPt))
        kick()
    }

    func zoom(_ dz: Double, atPt pt: CGPoint) {
        guard let h = handle else { return }
        lookout_zoom_at_logical(h, dz, Float(pt.x), Float(pt.y))
        retireChartChrome()
        kick()
    }

    /// True while a scene rebuild is outstanding, or tiles it needs are still
    /// being composed. What "the chart has finished" means.
    var stillBuilding: Bool {
        guard let h = handle else { return false }
        return lookout_is_building(h) != 0
    }

    /// True while the camera is easing a zoom or coasting a fling.
    var isAnimating: Bool {
        guard let h = handle else { return false }
        return lookout_animating(h) != 0
    }

    /// End of a $LOOKOUT_GESTURE_BENCH run: write the profile and quit, so a
    /// run is one command with a file at the end of it.
    func finishGestureBench() {
        gestureBench = nil
        frameProf?.write()
        frameProf = nil
        #if canImport(AppKit)
        NSApplication.shared.terminate(nil)
        #else
        exit(0)
        #endif
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
        retireChartChrome()
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

    // MARK: - Follow mode

    /// 0 off, 1 following own ship, 2 on and waiting for a fix. The core turns
    /// follow off on a pan, so this is read on the render tick, not remembered.
    var followState: Int {
        guard let h = handle else { return 0 }
        return Int(lookout_follow_active(h))
    }

    func setFollow(_ on: Bool) {
        guard let h = handle else { return }
        lookout_follow_set(h, on ? 1 : 0)
        retireChartChrome()
        kick(); pushReadouts()
    }

    /// 0 off, 1 turning with own ship, 2 on and waiting for a heading.
    var courseUpState: Int {
        guard let h = handle else { return 0 }
        return Int(lookout_course_up_active(h))
    }

    func setCourseUp(_ on: Bool) {
        guard let h = handle else { return }
        lookout_course_up_set(h, on ? 1 : 0)
        kick(); pushReadouts()
    }

    /// 1 while the wasm plugin layer is up. Own ship comes from a plugin, so
    /// the follow control has nothing to lock on to without one.
    var pluginsActive: Bool {
        guard let h = handle else { return false }
        return lookout_plugins_active(h) != 0
    }

    // MARK: - Own ship's position

    /// What the position readout may say. The core decides: `live` carries a
    /// fix inside its freshness window, `lost` means a source published once
    /// and has stopped, `none` means nothing ever has.
    enum FixState: Int { case none = 0, lost = 1, live = 2 }

    /// Own ship's reported position, or nil for either of the other two
    /// states. Never the map centre and never the cursor: a coordinate with no
    /// boat behind it is the ambiguity this removes.
    func ownShip() -> (state: FixState, lat: Double, lon: Double)? {
        guard let h = handle else { return nil }
        var lon = 0.0, lat = 0.0
        let s = FixState(rawValue: Int(lookout_own_ship(h, &lon, &lat))) ?? .none
        return (s, lat, lon)
    }

    // MARK: - Markers

    /// One of the mariner's own marks, copied out of the core. The core owns
    /// the list and the file it lives in; this is a snapshot for the UI.
    struct Marker: Identifiable, Equatable {
        let id: UInt64
        let lon: Double
        let lat: Double
        let name: String
        let droppedAt: Date
    }

    private func marker(from m: lookout_marker) -> Marker {
        Marker(id: m.id,
               lon: m.lon,
               lat: m.lat,
               name: m.name.map(String.init(cString:)) ?? "",
               droppedAt: Date(timeIntervalSince1970: Double(m.dropped_ms) / 1000))
    }

    /// Drop a marker at a geographic point. It is named in the same call, so
    /// nothing waits for typing. Nil when the core would not take it.
    @discardableResult
    func dropMarker(lon: Double, lat: Double) -> Marker? {
        guard let h = handle else { return nil }
        let id = lookout_marker_add(h, lon, lat)
        guard id != 0 else { return nil }
        kick()
        var m = lookout_marker()
        guard lookout_marker_by_id(h, id, &m) != 0 else { return nil }
        return marker(from: m)
    }

    /// Every marker, in drop order.
    func markers() -> [Marker] {
        guard let h = handle else { return [] }
        let n = Int(lookout_marker_count(h))
        return (0..<n).compactMap { i in
            var m = lookout_marker()
            guard lookout_marker_get(h, UInt32(i), &m) != 0 else { return nil }
            return marker(from: m)
        }
    }

    /// The marker under a point, in logical points, or nil when none is near.
    func marker(atPoint p: CGPoint) -> Marker? {
        guard let h = handle else { return nil }
        var m = lookout_marker()
        guard lookout_marker_at(h, Float(p.x), Float(p.y), &m) != 0 else { return nil }
        return marker(from: m)
    }

    func marker(id: UInt64) -> Marker? {
        guard let h = handle else { return nil }
        var m = lookout_marker()
        guard lookout_marker_by_id(h, id, &m) != 0 else { return nil }
        return marker(from: m)
    }

    /// Rename a marker. An empty name keeps the old one, which the core
    /// decides so every shell agrees.
    @discardableResult
    func renameMarker(_ id: UInt64, to name: String) -> Bool {
        guard let h = handle else { return false }
        let ok = name.withCString { lookout_marker_rename(h, id, $0) } == 0
        if ok { kick() }
        return ok
    }

    @discardableResult
    func removeMarker(_ id: UInt64) -> Bool {
        guard let h = handle else { return false }
        let ok = lookout_marker_remove(h, id) == 0
        if ok { kick() }
        return ok
    }

    // MARK: - Plugin settings

    /// Every loaded plugin with its settings schema, as JSON. The settings pane
    /// renders straight from this: the app knows nothing about what a plugin is
    /// for, only what controls it asked for.
    func pluginsJSON() -> String? {
        guard let h = handle else { return nil }
        var len = 0
        guard let p = lookout_plugins_json(h, &len), len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }

    /// One plugin's settings object, or nil when the id is not loaded.
    func pluginConfigJSON(_ id: String) -> String? {
        guard let h = handle else { return nil }
        var len = 0
        guard let p = lookout_plugin_config_get(h, id, &len), len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }

    /// Offer a file the mariner opened to the plugins. True when one claims
    /// that file type and now holds the file.
    ///
    /// False for a chart, for a type nobody claims, and for a build with no
    /// plugin layer — so the caller has one fallback, not three.
    func openFileForPlugins(_ path: String) -> Bool {
        guard let h = handle else { return false }
        let took = lookout_open_file(h, path) == 1
        if took { kick() }
        return took
    }

    /// Push settings to a plugin. Applied live — the plugin redraws inside the
    /// call, so the chart is kicked to show it.
    @discardableResult
    func setPluginConfig(_ id: String, _ json: String) -> Bool {
        guard let h = handle else { return false }
        let ok = lookout_plugin_config_set(h, id, json) == 0
        if ok { kick() }
        return ok
    }

    // MARK: - Plugin install and consent

    /// The plugin set that travels inside the app: Contents/Resources/Plugins,
    /// filled by the "Bundle the core plugins" build phase out of
    /// zig-out/plugins-bundled. Loaded through the ordinary directory call, so
    /// the host gives it origin `bundled`: anything that is not the directory
    /// LOOKOUT_PLUGINS names is bundled by definition.
    ///
    /// False when the app carries no such directory, which is a build without
    /// the phase, not a mariner's problem: the log says so and the installed
    /// set still loads.
    @discardableResult
    func loadBundledPlugins() -> Bool {
        guard let h = handle,
              let dir = Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.path)
        else {
            lkLog("no bundled plugins in this build (Resources/Plugins is absent)")
            return false
        }
        return lookout_plugins_load(h, dir.path) == 0
    }

    /// Load the installed plugin set — what Install put under Application
    /// Support — creating the plugin layer when the environment brought none.
    @discardableResult
    func loadInstalledPlugins() -> Bool {
        guard let h = handle else { return false }
        return lookout_plugins_load_installed(h) == 0
    }

    /// Everything the consent sheet shows for a .lkplug, as JSON, without
    /// installing it. Nil only when no plugin layer can come up.
    func inspectPlugin(_ path: String) -> String? {
        guard let h = handle else { return nil }
        var len = 0
        guard let p = lookout_plugin_inspect(h, path, &len), len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }

    /// Install a consented .lkplug. Nil on success — the plugin is already
    /// drawing — else the one sentence to show the mariner.
    func installPlugin(_ path: String) -> String? {
        guard let h = handle else { return "Open a chart before installing a plugin." }
        guard let err = lookout_plugin_install(h, path) else {
            kick()
            return nil
        }
        return String(cString: err)
    }

    /// Remove an installed plugin and everything it owns. False for a bundled
    /// or developer plugin, which install never wrote.
    @discardableResult
    func uninstallPlugin(_ id: String) -> Bool {
        guard let h = handle else { return false }
        let ok = lookout_plugin_uninstall(h, id) == 0
        if ok { kick() }
        return ok
    }

    /// Switch one granted capability on or off, live. The plugin keeps
    /// running; a revoked capability simply answers it -1 from here on.
    @discardableResult
    func setPluginGrant(_ id: String, _ cap: String, _ on: Bool) -> Bool {
        guard let h = handle else { return false }
        let ok = lookout_plugin_grant_set(h, id, cap, on ? 1 : 0) == 0
        if ok { kick() }
        return ok
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
    /// The middle of the chart view, in points.
    var viewCentrePt: CGPoint {
        guard let v = view else { return .zero }
        return CGPoint(x: v.bounds.midX, y: v.bounds.midY)
    }

    func screenPoint(forGeoLon lon: Double, lat: Double) -> CGPoint {
        guard let h = handle else { return .zero }
        var x: Float = 0, y: Float = 0
        lookout_geo_to_screen(h, lon, lat, &x, &y)
        return CGPoint(x: CGFloat(x), y: CGFloat(y))
    }

    // MARK: - Plugin tables

    #if os(macOS)
    /// Every table the loaded plugins declare. The shell builds a menu item
    /// and a window per declaration and knows nothing about the plugins.
    func tableSpecs() -> [PluginTableSpec] {
        guard let h = handle else { return [] }
        var len = 0
        guard let raw = lookout_plugin_tables_json(h, &len), len > 0 else { return [] }
        // Borrowed until the next plugin query, so decode before anything else
        // runs.
        let data = Data(bytes: raw, count: len)
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["tables"] as? [[String: Any]] else { return [] }
        return list.compactMap { PluginTableSpec($0) }
    }

    /// One table's rows, already ordered by the plugin's bands and then by the
    /// column asked for. `seq` moves when the plugin has fed the table since
    /// the last read. `columns` is the declaration's count, so a row that
    /// carried fewer cells than the table has columns still lines up.
    func tableRows(plugin: String, key: String, sortKey: String, ascending: Bool, columns: Int)
        -> (seq: Int, rows: [PluginTableRow])? {
        guard let h = handle else { return nil }
        var len = 0
        let raw = plugin.withCString { p in
            key.withCString { k in
                sortKey.withCString { s in
                    lookout_plugin_table_rows(h, p, k, s, ascending ? 1 : 0, &len)
                }
            }
        }
        guard let raw, len > 0 else { return nil }
        let data = Data(bytes: raw, count: len)
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["rows"] as? [[String: Any]] else { return nil }
        let rows = list.compactMap { PluginTableRow($0, columns: columns) }
        return (top["seq"] as? Int ?? 0, rows)
    }

    #endif

    // The alert bridge is cross-platform: an iPad mariner hears the plugins
    // too. The declared-table queries above are macOS-only (they feed NSWindow
    // dialogs), so the guard closes before these and reopens after.

    /// Every alert the plugins have raised, already ordered: what nobody has
    /// answered first, then the loudest, then the oldest. `seq` moves when the
    /// set has changed since the last read.
    func pluginAlerts() -> (seq: Int, alerts: [PluginAlert])? {
        guard let h = handle else { return nil }
        var len = 0
        guard let raw = lookout_plugin_alerts_json(h, &len), len > 0 else { return nil }
        // Borrowed until the next plugin query, so decode before anything else
        // runs.
        let data = Data(bytes: raw, count: len)
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["alerts"] as? [[String: Any]] else { return nil }
        return (top["seq"] as? Int ?? 0, list.compactMap { PluginAlert($0) })
    }

    /// Silence one alert. It stays listed until the condition clears.
    @discardableResult
    func acknowledgeAlert(_ id: UInt64) -> Bool {
        guard let h = handle else { return false }
        return lookout_plugin_alert_ack(h, id) == 0
    }

    #if os(macOS)
    /// Tell the plugin its table is on screen, or is not.
    func setTableOpen(plugin: String, key: String, _ open: Bool) {
        guard let h = handle else { return }
        _ = plugin.withCString { p in
            key.withCString { k in lookout_plugin_table_open(h, p, k, open ? 1 : 0) }
        }
        kick()
    }

    /// Put a place at the centre of the chart and hand back whatever plugin
    /// object draws there, for the bubble. Follow is switched off first: a
    /// chart that slides back to own ship a moment later has not shown the
    /// mariner the target they asked for.
    @discardableResult
    func reveal(lon: Double, lat: Double) -> OverlayPin? {
        guard let h = handle else { return nil }
        if lookout_follow_active(h) != 0 { lookout_follow_set(h, 0) }
        var v = currentView
        v.lon = lon
        v.lat = lat
        setView(v)
        // The camera has moved, so the row's own position is the middle of the
        // view: the object under that point is the row's symbol.
        return overlayHit(atPoint: screenPoint(forGeoLon: lon, lat: lat))
    }
    #endif

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
    /// Step to the next raster chart set, or to "no picture" after the last one. The
    /// camera does not move and the chart scene is not rebuilt unless the
    /// picture turns on or off, so a mariner comparing two providers over a reef
    /// keeps their fix.
    func cycleRaster()        { guard let h = handle else { return }; lookout_raster_cycle(h); kick(); pushReadouts() }
    /// The active raster chart set's name, or "" for no picture. A shell MUST show
    /// this: with a picture active the chart drops its opaque water and land
    /// fills, which is a real reduction in what it is telling the mariner.
    func rasterName() -> String {
        guard let h = handle else { return "" }
        var len = 0
        guard let p = lookout_raster_active_name(h, &len), len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }
    /// Hide or show the vector chart. The picture beneath it stays.
    func toggleChart()        { guard let h = handle else { return }; lookout_toggle_chart(h); kick(); pushReadouts() }
    func setChartHidden(_ hidden: Bool) { guard let h = handle else { return }; lookout_set_chart_hidden(h, hidden ? 1 : 0) }

    /// Draw a publisher's style instead of Lookout's own chart, or nil to go
    /// back to it. The style's sources are installed FIRST: the core starts
    /// asking for tiles as soon as it has the style, and a source it asks
    /// about before this knows where to fetch it is answered "failed" and
    /// remembered as such.
    func setAltChartStyle(_ style: AltChartStyle?) {
        guard let h = handle else { return }
        altTiles.setSources(style?.sources ?? [:])
        if let style {
            lkLog("alt style: \(style.json.utf8.count) B, source(s): \(style.sources.keys.sorted().joined(separator: ", "))")
            let ok = style.json.withCString { p in
                lookout_alt_chart_style_json(h, p, strlen(p))
            }
            if ok == 0 { lkLog("alt style: the core refused it") }
        } else {
            lkLog("alt style: cleared, back to the Lookout chart")
            lookout_alt_chart_style_json(h, nil, 0)
        }
        kick()
        pushReadouts()
    }

    /// Is a publisher's style the one being drawn?
    var altChartStyleActive: Bool {
        guard let h = handle else { return false }
        return lookout_alt_chart_style_active(h) != 0
    }
    func chartHidden() -> Bool { guard let h = handle else { return false }; return lookout_chart_hidden(h) != 0 }
    /// Every set, with whether it is in view and whether it is drawn. This is
    /// what the pill's menu is built from — a mariner has to see what they
    /// carry, not guess at it through a cycle.
    ///
    /// `shown` is the set's own state, not "drawn over this view": that is what
    /// gets saved, and a coast off screen still has an answer.
    struct RasterSet: Identifiable { let id: Int; let name: String; let inView: Bool; let shown: Bool }
    func rasterSets() -> [RasterSet] {
        guard let h = handle else { return [] }
        let n = Int(lookout_raster_set_count(h))
        return (0..<n).map { i in
            var len = 0
            let p = lookout_raster_set_name(h, UInt32(i), &len)
            let name = (p != nil && len > 0)
                ? String(decoding: UnsafeRawBufferPointer(start: p!, count: len), as: UTF8.self) : ""
            return RasterSet(id: i, name: name,
                             inView: lookout_raster_set_in_view(h, UInt32(i)) != 0,
                             shown: lookout_raster_shown(h, UInt32(i)) != 0)
        }
    }
    func rasterActiveIndex() -> Int { guard let h = handle else { return -1 }; return Int(lookout_raster_active_index(h)) }
    func rasterSelect(_ i: Int) { guard let h = handle else { return }; lookout_raster_select(h, Int32(i)); kick(); pushReadouts() }

    /// Draw a set, or stop drawing it, by index and without reference to the
    /// camera. `rasterSelect` cannot do this: it answers for the view on screen,
    /// and the view a launch opens into is often nowhere near the set being
    /// restored. Showing still turns off the sets covering the same water.
    func rasterSetShown(_ i: Int, _ on: Bool) {
        guard let h = handle else { return }
        lookout_raster_set_shown(h, UInt32(i), on ? 1 : 0)
    }

    /// Put back which raster sets the mariner had drawn. Adding a source draws
    /// its set, which is right for a chart just picked and wrong for one being
    /// re-installed at launch, so every open has to correct it — and before the
    /// first frame, or a set the mariner switched off flashes on screen.
    ///
    /// Two passes. Hiding first and showing second is what keeps the election:
    /// where two providers cover one coast, the sources were added in an order
    /// that drew the first of them, so showing the mariner's pick before hiding
    /// its rival would leave the rival to turn the pick straight back off.
    private func restoreRasterShown() {
        guard let hidden = model?.rasterHidden else { return }
        let sets = rasterSets()
        guard !sets.isEmpty else { return }
        for s in sets where hidden.contains(s.name) { rasterSetShown(s.id, false) }
        for s in sets where !hidden.contains(s.name) { rasterSetShown(s.id, true) }

        // With no survey open, the imagery IS the chart, and switching a set
        // off no longer means what it meant when it was said. The mariner hid
        // it to see the ENC underneath; with the ENC gone, obeying that leaves
        // them a blank sea and no way to read what they are looking at — so
        // the set covering this water comes back on. It is named in the pill
        // and one click from off again, which a blank screen is not.
        //
        // What they saved is NOT rewritten. This overrides the choice while
        // there is no survey to see under; add ENC charts back and the set
        // they hid is hidden again, which is what they asked for.
        guard chartCount() == 0 else { return }
        let here = rasterSets().filter(\.inView)
        guard !here.isEmpty, !here.contains(where: \.shown), let pick = here.first else { return }
        rasterSetShown(pick.id, true)
        lkLog("raster: nothing drawn and no survey aboard — showing \(pick.name)")
    }

    /// How many vector charts are open. Zero is a library of pictures alone.
    func chartCount() -> Int {
        guard let h = handle else { return 0 }
        return Int(lookout_charts_count(h))
    }

    /// Turn one raster chart on or off without removing it.
    @discardableResult
    func setRasterEnabled(_ path: String, _ on: Bool) -> Bool {
        guard let h = handle else { return false }
        return path.withCString { lookout_raster_set_enabled(h, $0, on ? 1 : 0) != 0 }
    }
    /// The set covering this view, drawn or not — so the pill can say a picture
    /// is here while it is off.
    func rasterAvailableName() -> String {
        guard let h = handle else { return "" }
        var len = 0
        guard let p = lookout_raster_available_name(h, &len), len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self)
    }
    /// Is a picture beneath THIS view?
    func rasterOverChart() -> Bool { guard let h = handle else { return false }; return lookout_raster_over_chart(h) != 0 }
    /// How many raster chart sets the mariner has installed.
    func rasterSetCount() -> Int { guard let h = handle else { return 0 }; return Int(lookout_raster_set_count(h)) }
    /// Open a raster chart (satellite imagery or another picture chart) the
    /// mariner supplied. The app offers no catalogue and no download.
    @discardableResult
    func addRaster(_ path: String) -> Bool {
        guard let h = handle else { return false }
        return path.withCString { lookout_raster_add(h, $0) != 0 }
    }
    func toggleText()         { guard let h = handle else { return }; lookout_toggle_text(h); kick() }
    func toggleSoundings()    { guard let h = handle else { return }; lookout_toggle_soundings(h); kick() }
    func toggleOtherCategory(){ guard let h = handle else { return }; lookout_toggle_other_category(h); kick() }
    func nudgeSafetyContour(_ d: Double) { guard let h = handle else { return }; lookout_nudge_safety_contour(h, d); kick() }
    func adjustSize(_ f: Float) { guard let h = handle else { return }; lookout_adjust_size(h, f); kick() }

    var scaleDenominator: Double {
        guard let h = handle else { return 0 }
        return lookout_scale_denominator(h)
    }

    /// A file a picked feature points at, by the cell it came from and the name
    /// the attribute carries. The bytes belong to the engine and stay valid
    /// while the chart is open, so they are copied here.
    func auxFile(cell: String, named name: String) -> (data: Data, mime: String)? {
        guard let h = handle else { return nil }
        var bytes: UnsafePointer<UInt8>?
        var len = 0
        var mime: UnsafePointer<CChar>?
        lookout_aux_file(h, cell, name, &bytes, &len, &mime)
        guard let bytes, len > 0 else { return nil }
        return (Data(bytes: bytes, count: len),
                mime.map { String(cString: $0) } ?? "application/octet-stream")
    }

    // MARK: - Cursor pick

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
            // The core decides what a pick reports and in what order (pick.zig),
            // so every shell shows the same thing.
            lookout_pick_ranked(h, lon, lat, &cb)
        }
        return results
    }

    // MARK: - Push live readouts to the UI

    private var lastReadoutsAt: TimeInterval = 0
    private var lastViewSavedAt: TimeInterval = 0
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
        let over = rasterOverChart()
        if model.rasterInView != over { model.rasterInView = over }
        let hidden = chartHidden()
        if model.chartHidden != hidden { model.chartHidden = hidden }
        let avail = rasterAvailableName()
        if model.rasterAvailable != avail { model.rasterAvailable = avail }
        let sets = rasterSets()
        if model.rasterSets.map(\.id) != sets.map(\.id)
            || model.rasterSets.map(\.inView) != sets.map(\.inView)
            || model.rasterSets.map(\.shown) != sets.map(\.shown) { model.rasterSets = sets }
        let ai = rasterActiveIndex()
        if model.rasterActive != ai { model.rasterActive = ai }
        let active = rasterName()
        if model.rasterName != active { model.rasterName = active }
        // The core turns follow off itself on a pan; polling here is what makes
        // the lock button follow the core instead of its own last tap.
        let follow = followState
        if model.followState != follow { model.followState = follow }
        let cup = courseUpState
        if model.courseUpState != cup { model.courseUpState = cup }
        let plugged = pluginsActive
        if model.pluginsActive != plugged { model.pluginsActive = plugged }
        // Own ship, for the position readout. The state and the numbers move
        // together: a readout that kept the last position through a lost fix
        // would be presenting a stale one as live.
        if let ship = ownShip() {
            if model.fixState != ship.state { model.fixState = ship.state }
            let lat: Double? = ship.state == .live ? ship.lat : nil
            let lon: Double? = ship.state == .live ? ship.lon : nil
            if model.shipLat != lat { model.shipLat = lat }
            if model.shipLon != lon { model.shipLon = lon }
        }
        if model.rotationDeg != v.rotation_deg { model.rotationDeg = v.rotation_deg }
        if model.zoomLevel != v.zoom { model.zoomLevel = v.zoom }
        if model.centerLat != v.lat { model.centerLat = v.lat }
        if model.centerLon != v.lon { model.centerLon = v.lon }
        // Persist periodically too: a crash or a force-quit never reaches close().
        if now - lastViewSavedAt >= 3 {
            lastViewSavedAt = now
            ViewState.save(v)
        }
        let ov = lookout_overscale(h)
        if model.overscale != ov { model.overscale = ov }
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
            if c.model?.firstBuildDone != true || c.stillBuilding { frames = 0; return }
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

/// The settings form reads and writes the chart through these. Both protocols
/// are the whole of what it asks for, so the same form serves every app.
extension ChartController: MarinerSettingsHost, PluginSettingsHost {}
