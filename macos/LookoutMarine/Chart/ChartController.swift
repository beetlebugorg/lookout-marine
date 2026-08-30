//  ChartController.swift
//
//  The single owner of the `lookout*` handle and the single funnel for every
//  `lookout_*` call. The handle is main-actor owned, so the whole class is
//  @MainActor and every caller reaches it from one place.
//
//  THE RENDER IS THE EXCEPTION. `lookout_render` runs on `renderQueue`, off the
//  main thread, so a gesture burst can never delay a frame slot. The C ABI
//  serializes itself (api_mu), so a gesture landing mid-render waits a
//  millisecond or two. See `step` and `renderGate` for the rest of that rule.
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

    /// This shell's whole part in charts by link: fetch bytes for a url the
    /// core hands it. See ChartLinkFetch.swift.
    private let linkFetch = ChartLinkFetch()

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
        // The fetch door, before anything can ask through it. Installing it
        // also resolves whatever chart link the mariner left selected: the core
        // read the list at open and has been waiting for a way to fetch.
        linkFetch.attach(to: h) { [weak self] in self?.kick() }
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

        // Dev hook: write the documents this shell parses, and quit. See
        // dumpCoreJSON below.
        if let dir = ProcessInfo.processInfo.environment["LOOKOUT_DUMP_JSON"], !dir.isEmpty {
            // After the plugin layer is up, which is further down this method.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.dumpCoreJSON(into: dir)
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

        // And their declared tables can take their place: the menu bar on the
        // Mac, a row in the settings form on a phone.
        model?.refreshPluginTables()
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
        // Before the barrier: this answers the fetches still out, clears the
        // core's callback and cancels the transfers, so nothing can answer into
        // a handle that is about to be destroyed.
        linkFetch.detach()
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
    func kick() {
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

    // MARK: - Push live readouts to the UI

    private var lastReadoutsAt: TimeInterval = 0
    private var lastViewSavedAt: TimeInterval = 0
    /// The pose last written down, so an unmoved camera is not written again.
    private var lastSavedView: lookout_view?
    /// Internal, not private: the raster and chart-link calls in
    /// ChartController+Raster.swift push a readout after a change the
    /// frame loop would not otherwise see.
    func pushReadouts() {
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
        // The chart-link list, the credit and the error, from the core. A
        // landing answer raises needs-redraw, so a resolve keeps this ticking
        // until it is done.
        model.chartLinks.poll()
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
        // Persist periodically too: a crash or a force-quit never reaches
        // close(). Only when it has moved: frames keep coming while a plugin
        // moves own ship, so a boat at anchor wrote the same pose every three
        // seconds for as long as it lay there.
        if now - lastViewSavedAt >= 3,
           lastSavedView.map({ ViewState.differs(v, from: $0) }) ?? true {
            lastViewSavedAt = now
            lastSavedView = v
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

    // MARK: - Fixture capture

    /// $LOOKOUT_DUMP_JSON=<dir>: write every document this shell parses out of
    /// the core, then quit. The parser tests read the result, so a fixture is
    /// the core's own output and can be captured again when the core changes:
    ///
    ///     LOOKOUT_MULTI=1 LOOKOUT_CLEAN=1 \
    ///     LOOKOUT_OPEN=<chart.pmtiles> LOOKOUT_DUMP_JSON=<dir> \
    ///       open -n macos/build-mac/Build/Products/Debug/LookoutMarine.app
    ///
    /// LOOKOUT_CLEAN matters for the reason it matters to a screenshot: a saved
    /// connection list points at the developer's own instruments, and a captured
    /// registry would put their addresses in the repository.
    private func dumpCoreJSON(into dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String?) {
            guard let text, !text.isEmpty else {
                lkLog("dump: \(name) — the core had nothing to say")
                return
            }
            let path = (dir as NSString).appendingPathComponent(name)
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            lkLog("dump: \(name) \(text.utf8.count) B")
        }
        write("plugins.json", pluginsJSON())
        write("tables.json", jsonString(lookout_plugin_tables_json))
        write("alerts.json", jsonString(lookout_plugin_alerts_json))
        var len = 0
        if let p = lookout_licenses_json(&len), len > 0 {
            write("licenses.json",
                  String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self))
        }
        #if canImport(AppKit)
        NSApplication.shared.terminate(nil)
        #else
        exit(0)
        #endif
    }

    /// One of the core's counted-buffer queries, as a string. The buffer is
    /// borrowed until the next plugin query, so copy it before anything else
    /// runs.
    private func jsonString(_ query: (OpaquePointer?, UnsafeMutablePointer<Int>?) -> UnsafePointer<CChar>?) -> String? {
        guard let h = handle else { return nil }
        var len = 0
        guard let p = query(h, &len), len > 0 else { return nil }
        return p.withMemoryRebound(to: UInt8.self, capacity: len) {
            String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
        }
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
