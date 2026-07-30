//  ChartView.swift — the one GPU surface, embedded in SwiftUI.
//
//  A layer-backed native view that hands its handle to lookout via the
//  ChartController, forwards input, and lets the controller's display link drive
//  the on-demand render loop. All app chrome (HUD, menus, settings) is native
//  SwiftUI drawn AROUND/OVER this view — lookout owns only the chart pixels.
//
//  The same ChartController/AppModel drive both platforms; lookout renders via
//  Metal into the chart view's own CAMetalLayer. macOS embeds it in this
//  NSView; on iOS the surface is ChartUIView in the plain-UIKit input window
//  (SwiftUI swallows touches), with the chrome in a PassThroughWindow above.

import SwiftUI
#if canImport(AppKit)
import AppKit
import QuartzCore
#endif
#if canImport(UIKit)
import UIKit
#endif

/// All the floating chrome, over a non-interactive clear fill. Shared by both
/// platforms: macOS hosts it in an AppKit overlay above the chart's Metal layer;
/// iOS composes it in plain SwiftUI (the whole chrome window sits above the
/// chart window, so no layer trickery is needed).
///
/// The layout is the layout of the WinUI 3 shell (windows/ui/MainWindow.xaml):
/// search at the top left, north at the top right, zoom above charts and
/// settings at the bottom right, the scale bar at the bottom left, and the
/// readout capsule at the bottom center.
struct OverlayLayer: View {
    @ObservedObject var model: AppModel

    /// Below this width the capsule and the corner chrome cannot share the
    /// bottom row. The corner chrome then moves above the capsule.
    private static let compactWidth: CGFloat = 700

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < Self.compactWidth
            // The bottom inset of the corner chrome. It clears the capsule in a
            // narrow window.
            let corner = compact ? Chrome.margin + Chrome.capsule + Chrome.gap : Chrome.margin
            Color.clear
                .allowsHitTesting(false)
                // Top left: the search bubble opens the search field.
                .overlay(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: Chrome.gap) {
                        ChromeBubble(system: model.searchOpen ? "xmark" : "magnifyingglass",
                                     help: "Go to coordinate") {
                            withAnimation(.easeInOut(duration: 0.18)) { model.searchOpen.toggle() }
                        }
                        .chromeHitRegion("search-bubble")
                        if model.searchOpen {
                            SearchField(model: model)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                                .chromeHitRegion("search-field")
                        }
                    }
                    .padding(Chrome.margin)
                }
                // Top right: north. It is always visible. It stays at the
                // physical trailing edge, because in landscape the safe-area
                // inset moves it toward the middle.
                .overlay(alignment: .topTrailing) {
                    NorthBubble(rotationDeg: model.rotationDeg) { model.northUp() }
                        .chromeHitRegion("compass")
                        .padding(Chrome.margin)
                        .ignoresSafeArea(.container, edges: .trailing)
                }
                // Bottom right: zoom above settings. The charts live in the
                // Charts tab of the settings.
                .overlay(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing, spacing: Chrome.gap) {
                        ZoomControls(model: model)
                        ChromeBubble(system: "gearshape", help: "Mariner settings") {
                            model.openSettings()
                        }
                        .chromeHitRegion("settings-bubble")
                    }
                    .padding(.trailing, Chrome.margin)
                    .padding(.bottom, corner)
                    .ignoresSafeArea(.container, edges: .trailing)
                }
                // Bottom left: identify results above the scale bar.
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: Chrome.gap) {
                        if !model.pickResults.isEmpty {
                            IdentifyPanel(results: model.pickResults) { model.pickResults = [] }
                                .chromeHitRegion("identify")
                        }
                        if model.hasChart {
                            ScaleBarView(scaleDenominator: model.scaleDenominator)
                        }
                    }
                    .padding(.leading, Chrome.margin)
                    .padding(.bottom, corner)
                }
                // Bottom center: the readout capsule. The scale entry opens
                // above it.
                .overlay(alignment: .bottom) {
                    VStack(spacing: Chrome.gap) {
                        if model.showScaleEntry {
                            ScaleEntryPanel(model: model)
                                .chromeHitRegion("scale-entry")
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if model.hasChart {
                            ReadoutsCapsule(model: model, compact: compact) {
                                if model.showScaleEntry { model.showScaleEntry = false }
                                else { model.beginScaleEntry() }
                            }
                        }
                    }
                    .padding(.bottom, Chrome.margin)
                }
                .overlay(alignment: .top) {
                    if model.isBuilding { BuildingPill().padding(.top, 10) }
                }
                .overlay {
                    if model.showStartupLoader {
                        StartupLoader(phase: model.loadingPhase)
                            .transition(.opacity)
                    } else if !model.hasChart {
                        EmptyChartState(model: model).chromeHitRegion("empty-state")
                    }
                }
                .animation(.default, value: model.pickResults)
                .animation(.default, value: model.isBuilding)
                .animation(.easeInOut(duration: 0.18), value: model.showScaleEntry)
                .animation(.easeInOut(duration: 0.18), value: model.searchOpen)
                .animation(.easeInOut(duration: 0.25), value: model.showStartupLoader)
        }
        // chromeHitRegion writes the control frames in this space.
        // The pass-through hosts hit-test against it.
        .coordinateSpace(name: Chrome.space)
    }
}

/// Write this view's frame to ChromeHitMap. The pass-through host keeps the
/// clicks in these frames and lets all other clicks reach the chart. Both
/// platforms need this, because a SwiftUI control has no view of its own and
/// hit-tests as the hosting view, like empty space.
private struct ChromeHitRegion: ViewModifier {
    let id: String
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { g in
                Color.clear
                    .onAppear { ChromeHitMap.shared.set(id, g.frame(in: .named(Chrome.space))) }
                    // One-parameter onChange: the iOS 17 (of:initial:_:) form
                    // is unavailable on the iOS 15 floor.
                    .onChange(of: g.frame(in: .named(Chrome.space))) { f in
                        ChromeHitMap.shared.set(id, f)
                    }
                    .onDisappear { ChromeHitMap.shared.remove(id) }
            }
        }
    }
}
extension View {
    func chromeHitRegion(_ id: String) -> some View { modifier(ChromeHitRegion(id: id)) }
}

#if os(macOS)

struct ChartView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    let controller: ChartController

    func makeNSView(context: Context) -> ChartNSView {
        let v = ChartNSView()
        v.controller = controller
        v.model = model
        controller.model = model
        model.controller = controller
        v.installOverlay(OverlayLayer(model: model))
        return v
    }

    func updateNSView(_ v: ChartNSView, context: Context) {
        v.model = model
        v.controller = controller
        // A pending open request the model couldn't service (no view attached
        // yet when it was made) — normally requestOpen drives the controller
        // directly; see AppModel.requestOpen.
        if let req = model.openRequest, req.id != v.lastOpenId {
            v.lastOpenId = req.id
            _ = controller.open(charts: req.paths, in: v)
            v.raiseOverlay()
            v.syncMetalLayerScale()
        }
    }

    static func dismantleNSView(_ v: ChartNSView, coordinator: ()) {
        v.controller?.close()
    }
}

/// A hosting view that lets clicks fall through its empty (non-interactive)
/// regions to the chart below (its superview), so panning/zooming still work
/// everywhere the floating controls aren't.
///
/// AppKit cannot make that decision alone. SwiftUI draws its controls without
/// backing views, so a bubble and empty space both hit-test as this view. The
/// rule "hit === self, return nil" therefore sent every chrome click to the
/// chart. ChromeHitMap holds the frames of the controls and makes the decision,
/// as on iOS.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self else { return hit } // a subview, such as a text field
        // AppKit gives the point in the superview space. The map uses
        // Chrome.space, which is the coordinate space of this view.
        let local = superview.map { convert(point, from: $0) } ?? point
        return ChromeHitMap.shared.contains(local) ? self : nil
    }
}

/// Layer-backed, flipped (top-left origin, matching lookout's pixel coords) view
/// that lookout renders into and that captures pan/rotate/zoom/tap/hover input.
final class ChartNSView: NSView {
    weak var controller: ChartController?
    weak var model: AppModel?
    var lastOpenId = 0
    private var didAutoOpen = false
    private var overlayHost: NSView?
    private var fsObservers: [NSObjectProtocol] = []

    /// Host the floating chrome as a SUBVIEW of the chart: a subview's layer is a
    /// *sublayer* of the backing CAMetalLayer, which CoreAnimation composites
    /// ABOVE the presented drawable. PassThroughHostingView lets empty-area
    /// clicks reach our own mouse handlers.
    func installOverlay<V: View>(_ view: V) {
        let host = PassThroughHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        overlayHost = host
    }

    /// Keep the overlay the frontmost subview after (re)opens.
    func raiseOverlay() {
        guard let host = overlayHost else { return }
        addSubview(host) // re-adding brings it to front / re-parents onto the new layer
    }

    // gesture state
    private var dragging = false
    private var rotating = false
    private var downPoint = CGPoint.zero
    private var lastDrag = CGPoint.zero
    private var vx = 0.0, vy = 0.0
    private var lastSampleTime: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never // lookout presents; AppKit must not clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// The view's backing layer IS the render target lookout presents into.
    /// contentsScale is set before the chart opens so the first drawable is
    /// true Retina pixels.
    override func makeBackingLayer() -> CALayer {
        let ml = CAMetalLayer()
        ml.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        // S-52 NODATA (day): what the first presented frame will clear to —
        // showing it immediately kills the white flash before that frame.
        ml.backgroundColor = CGColor(red: 0.576, green: 0.682, blue: 0.733, alpha: 1)
        return ml
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Grab the first click even when the window isn't key (feels native for a map).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        applyWindowSizeHook()
        // The full-screen transition swaps the drawable at its very END — often
        // after our last setFrameSize, when the render loop may already be idle.
        // Without a fresh frame the window keeps a blank drawable, so kick a
        // resize+render when the transition (either direction) completes.
        let nc = NotificationCenter.default
        fsObservers.forEach(nc.removeObserver)
        fsObservers = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification].map { name in
            nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.syncMetalLayerScale()
                self.controller?.resize(widthPt: Double(self.bounds.width), heightPt: Double(self.bounds.height))
            }
        }
        maybeAutoOpen()
    }

    /// Dev hook, as LOOKOUT_OPEN and LOOKOUT_VIEW: LOOKOUT_WINDOW="1400x900"
    /// sets the content size, so a screenshot frame is the same on any Mac.
    /// It runs after the scene has sized the window, which is why it defers.
    private func applyWindowSizeHook() {
        guard let spec = ProcessInfo.processInfo.environment["LOOKOUT_WINDOW"] else { return }
        let size = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard size.count == 2, size[0] > 100, size[1] > 100 else {
            lkLog("ignoring malformed LOOKOUT_WINDOW '\(spec)' (want WIDTHxHEIGHT)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let window = self?.window else { return }
            window.setContentSize(NSSize(width: size[0], height: size[1]))
            window.center()
            lkLog("LOOKOUT_WINDOW: content size \(Int(size[0]))x\(Int(size[1]))pt")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // First real size → open the initial chart (at a stable size, not the
        // transient zero/pre-layout bounds). Later sizes just resize.
        if !didAutoOpen { maybeAutoOpen() }
        else { controller?.resize(widthPt: Double(newSize.width), heightPt: Double(newSize.height)) }
        syncMetalLayerScale()
    }

    /// Keep the layer's contentsScale at the window's backing scale — the
    /// render core sizes drawables from bounds × contentsScale each frame.
    func syncMetalLayerScale() {
        guard let ml = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if ml.contentsScale != scale {
            lkLog("metal layer contentsScale \(ml.contentsScale) -> \(scale)")
            ml.contentsScale = scale
        }
    }

    /// Open the last recent / default chart once, as soon as the view has a valid
    /// size and a window. Opening at a transient (0×0 / pre-layout) size and then
    /// resizing mid-open can wedge the swapchain, so we wait for a real size.
    ///
    /// The open is DEFERRED off the current AppKit call stack: our first layout
    /// can run inside the window controller's windowDidLoad, and opening there
    /// registers SDL's windowDidResize listener while AppKit is still placing /
    /// restoring the window frame. The restoration resize then walks into SDL's
    /// listener, whose ScheduleContextUpdates touches NSOpenGLContext — which
    /// dies on a poisoned GL stub at that point of app startup (crash observed
    /// on macOS 26.5: SwiftUI sizeAndPlaceWindow → SDL windowDidResize →
    /// +[NSOpenGLContext currentContext] → 0xbad4007).
    func maybeAutoOpen() {
        guard !didAutoOpen, window != nil, controller?.handle == nil,
              bounds.width > 1, bounds.height > 1,
              let paths = model?.initialChartPaths(), !paths.isEmpty else { return }
        didAutoOpen = true
        // No frame restoration for this window: the chart reopens from our own
        // recents, and the fromServer frame restore is exactly the mid-load
        // resize the deferral above is dodging.
        window?.isRestorable = false
        model?.openingCells = paths.count
        model?.isOpening = true // loader up before the (synchronous) open runs
        model?.preparingSymbols = (lookout_atlas_cache_ready() == 0) // first run?
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.model?.isOpening = false; self.model?.preparingSymbols = false }
            guard self.controller?.handle == nil else { return }
            self.lastOpenId = self.model?.openRequest?.id ?? 0
            _ = self.controller?.open(charts: paths, in: self)
            self.raiseOverlay()
            self.syncMetalLayerScale()
            self.controller?.resize(widthPt: Double(self.bounds.width), heightPt: Double(self.bounds.height))
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.syncDeviceScale()
        controller?.resize(widthPt: Double(bounds.width), heightPt: Double(bounds.height))
        syncMetalLayerScale()
    }

    // MARK: Hover (HUD cursor readout)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The window forwards mouseMoved to the first responder (us) even when
        // the pointer is outside — only track it while it is over the chart.
        guard bounds.contains(p) else {
            model?.cursorLon = nil
            model?.cursorLat = nil
            return
        }
        if let g = controller?.geo(atPoint: p) {
            model?.cursorLon = g.lon
            model?.cursorLat = g.lat
        }
    }
    override func mouseExited(with event: NSEvent) {
        model?.cursorLon = nil; model?.cursorLat = nil
    }

    // MARK: Drag = pan (with fling) / shift-drag = rotate

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p; lastDrag = p
        vx = 0; vy = 0; lastSampleTime = 0
        controller?.flingStart(vx: 0, vy: 0) // grabbing stops any coast
        if event.modifierFlags.contains(.shift) {
            rotating = true; dragging = false
        } else {
            dragging = true; rotating = false
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if rotating {
            controller?.rotateDrag(from: lastDrag, to: p)
        } else if dragging {
            let dx = p.x - lastDrag.x
            let dy = p.y - lastDrag.y
            controller?.pan(dxPt: dx, dyPt: dy)
            sampleVelocity(dx: dx, dy: dy, at: event.timestamp)
        }
        lastDrag = p
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { dragging = false; rotating = false }
        if rotating { return }
        let moved = hypot(p.x - downPoint.x, p.y - downPoint.y)
        if moved <= 4 {
            tapPick(at: p)          // a tap: identify
        } else {
            controller?.flingStart(vx: vx, vy: vy) // a throw: momentum
        }
    }

    private func sampleVelocity(dx: CGFloat, dy: CGFloat, at ts: TimeInterval) {
        if lastSampleTime != 0, ts > lastSampleTime {
            let dt = ts - lastSampleTime
            if dt > 0.0005 {
                vx = vx * 0.5 + (Double(dx) / dt) * 0.5
                vy = vy * 0.5 + (Double(dy) / dt) * 0.5
            }
        }
        lastSampleTime = ts
    }

    private func tapPick(at p: CGPoint) {
        guard let g = controller?.geo(atPoint: p) else { return }
        model?.pickResults = controller?.pick(lon: g.lon, lat: g.lat) ?? []
    }

    // MARK: Wheel / pinch zoom (cursor-anchored)

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Trackpad precise deltas are large; a classic wheel notch is ~±1 (match
        // the demo's 0.25 factor for wheels).
        let factor = event.hasPreciseScrollingDeltas ? 0.01 : 0.25
        let dz = Double(event.scrollingDeltaY) * factor
        if dz != 0 { controller?.zoom(dz, atPt: p) }
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        controller?.zoom(Double(event.magnification) * 3.0, atPt: p)
    }
}

#else  // ---- iOS (reuses ChartController/AppModel) ---------------------------

struct ChartView: View {
    @ObservedObject var model: AppModel
    let controller: ChartController

    var body: some View {
        // Chrome only: the chart renders in SDL's own window and the gesture
        // surface (ChartUIView) lives in the plain-UIKit input window between
        // them — SwiftUI never sees chart touches (see SceneDelegate).
        OverlayLayer(model: model)
        .sheet(isPresented: $model.showSettings) {
            // NavigationStack is iOS 16+; NavigationView carries the same
            // title + Done toolbar on the iOS 15 floor.
            if #available(iOS 16.0, *) {
                NavigationStack { settingsSheetContent }
            } else {
                NavigationView { settingsSheetContent }
                    .navigationViewStyle(.stack)
            }
        }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result { model.openImported(url) }
        }
    }

    private var settingsSheetContent: some View {
        SettingsView(model: model)
            .navigationTitle("Mariner Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { model.showSettings = false } }
    }
}


/// Transparent full-screen gesture surface — the root view of the plain-UIKit
/// INPUT window (SceneDelegate). The chart renders in lookout's OWN UIWindow
/// below it (SDL can't wrap an existing UIView) and the SwiftUI chrome floats
/// in a PassThroughWindow above; this view owns input, sizing, and the
/// auto-open.
final class ChartUIView: UIView, UIGestureRecognizerDelegate {
    /// lookout renders via Metal straight into this view's backing layer —
    /// the input window IS the chart surface now (no separate render window).
    override class var layerClass: AnyClass { CAMetalLayer.self }

    weak var controller: ChartController?
    weak var model: AppModel?
    /// The SwiftUI chrome window (set by SceneDelegate) — re-asserted key and
    /// topmost after lookout's chart window appears.
    weak var chromeWindow: UIWindow?
    var lastOpenId = 0
    private var didAutoOpen = false
    private var lastSizePt = CGSize.zero

    // pinch/rotate gesture state
    private var lastPinchScale: CGFloat = 1
    private var rotationEngaged = false // rotate stays inert until past a dead-zone
    private var rotationBaseDeg = 0.0   // chart rotation when the dead-zone was crossed
    private var rotationOffset = 0.0    // gesture rotation (rad) at that moment
    /// Last pointer position from hover (nil on touch-only devices) — anchors
    /// trackpad scroll-zoom at the pointer when known.
    private var lastHoverPoint: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // S-52 NODATA (day): what the first presented frame clears to — kills
        // the white flash before that frame.
        layer.backgroundColor = CGColor(red: 0.576, green: 0.682, blue: 0.733, alpha: 1)
        isMultipleTouchEnabled = true
        installGestures()
        // OS memory pressure: hand the warning to the engine, which trims its
        // reclaimable caches at the next safe point instead of ignoring it.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            if let h = self?.controller?.handle { lookout_memory_warning(h) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncLayerScale()
        // Attach as the render surface immediately, so an imported-chart open
        // works even when the app launched with no default chart (nothing has
        // called controller.open yet, so controller.view would be nil).
        if window != nil { controller?.attachView(self) }
        maybeAutoOpen()
    }

    /// Keep the Metal layer's contentsScale at the screen's density — the
    /// render core derives its pixel size from bounds × contentsScale.
    private func syncLayerScale() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        if scale > 0, layer.contentsScale != scale { layer.contentsScale = scale }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncLayerScale()
        // First real size → open the initial chart (at a stable size, not the
        // transient zero/pre-layout bounds). Later sizes (rotation, split view)
        // just resize.
        if !didAutoOpen { maybeAutoOpen(); return }
        let s = bounds.size
        if s != lastSizePt {
            lastSizePt = s
            controller?.resize(widthPt: Double(s.width), heightPt: Double(s.height))
        }
    }

    private func maybeAutoOpen() {
        guard !didAutoOpen, window != nil, controller?.handle == nil,
              bounds.width > 1, bounds.height > 1 else { return }
        // A pending open request beats the startup default (it can only exist
        // this early if something opened a chart before first layout).
        let paths = model?.openRequest?.paths ?? model?.initialChartPaths() ?? []
        guard !paths.isEmpty else { return }
        didAutoOpen = true
        lastSizePt = bounds.size
        model?.openingCells = paths.count
        model?.isOpening = true // loader up before the (synchronous) open runs
        model?.preparingSymbols = (lookout_atlas_cache_ready() == 0) // first run?
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.model?.isOpening = false; self.model?.preparingSymbols = false }
            guard self.controller?.handle == nil else { return }
            self.lastOpenId = self.model?.openRequest?.id ?? 0
            _ = self.controller?.open(charts: paths, in: self)
            self.hostWindowAboveChart()
        }
    }

    /// The chart renders in THIS window's layer; keep the chrome window above
    /// and transparent. SwiftUI re-applies systemBackground (black in dark
    /// mode) to its hosting view when content attaches — clear it again after
    /// the open, or the chrome window paints over the chart.
    func hostWindowAboveChart() {
        chromeWindow?.windowLevel = .normal + 2
        chromeWindow?.makeKey()
        if let w = chromeWindow {
            w.isOpaque = false
            w.backgroundColor = .clear
            w.rootViewController?.view.isOpaque = false
            w.rootViewController?.view.backgroundColor = .clear
        }
    }

    // MARK: Gestures

    private func installGestures() {
        // One finger drags = pan; drag INCLUDES an indirect pointer (trackpad /
        // mouse / the simulator's host pointer), so a pointer drag pans too.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(onRotate(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.require(toFail: doubleTap)
        // Hover feeds the cursor read-out on pointer devices; touches don't hover.
        // (No scroll-to-zoom recognizer: `allowedScrollTypesMask` also fires on a
        // pointer *drag*, which then zoomed instead of panned. Pinch is the zoom
        // gesture; +/- and double-tap cover pointer users.)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        [pinch, rotate].forEach { $0.delegate = self } // only these compose (see below)
        [pan, pinch, rotate, doubleTap, twoFingerTap, tap, hover].forEach(addGestureRecognizer)
    }

    /// Only pinch↔rotate may run together (one two-finger manipulation). Pan is
    /// deliberately EXCLUSIVE with them so a drag can't also zoom/rotate.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair: Set = [ObjectIdentifier(type(of: gestureRecognizer)), ObjectIdentifier(type(of: other))]
        return pair.isSubset(of: [ObjectIdentifier(UIPinchGestureRecognizer.self), ObjectIdentifier(UIRotationGestureRecognizer.self)])
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            notePointerInput("pan")
            controller?.flingStart(vx: 0, vy: 0) // grabbing stops any coast
        case .changed:
            let t = g.translation(in: self)
            controller?.pan(dxPt: t.x, dyPt: t.y)
            g.setTranslation(.zero, in: self)
        case .ended:
            let v = g.velocity(in: self) // points/sec — same units as the mac fling
            controller?.flingStart(vx: Double(v.x), vy: Double(v.y))
        default:
            break
        }
    }

    // Pinch = zoom to the fingers' centroid. Pure zoom (no simultaneous pan):
    // the centroid IS the anchor, so the chart point under the fingers stays
    // put; adding a centroid-delta pan on top fought that anchor and made the
    // zoom feel like it drifted off the pinch.
    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            notePointerInput("pinch")
            lastPinchScale = g.scale
            controller?.flingStart(vx: 0, vy: 0)
        case .changed:
            let dz = log2(Double(g.scale / lastPinchScale))
            lastPinchScale = g.scale
            if dz != 0 { controller?.zoom(dz, atPt: g.location(in: self)) }
        default:
            break
        }
    }

    // Rotate = course-up, but with a DEAD-ZONE so an incidental twist during a
    // pinch-zoom doesn't spin the chart. Stays inert until the fingers have
    // turned past ~18°, then tracks from there (no jump).
    private static let rotateDeadzone = 18.0 * .pi / 180.0 // radians
    @objc private func onRotate(_ g: UIRotationGestureRecognizer) {
        guard let controller else { return }
        switch g.state {
        case .began:
            rotationEngaged = false
        case .changed:
            if !rotationEngaged {
                guard abs(g.rotation) >= Self.rotateDeadzone else { return }
                rotationEngaged = true
                rotationBaseDeg = controller.currentView.rotation_deg
                rotationOffset = g.rotation // subtract so there's no jump on engage
            }
            var v = controller.currentView
            // UIKit rotation is positive clockwise (y-down), and so is the
            // core's rotation: the macOS grab-and-spin adds the swept atan2
            // angle straight onto cam.rotation. ADD here too, so the chart
            // turns WITH the fingers; subtracting fought them.
            v.rotation_deg = rotationBaseDeg + Double(g.rotation - rotationOffset) * 180 / .pi
            controller.setView(v)
        default:
            break
        }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        notePointerInput("tap")
        let p = g.location(in: self)
        guard let geo = controller?.geo(atPoint: p) else { return }
        model?.pickResults = controller?.pick(lon: geo.lon, lat: geo.lat) ?? []
    }

    @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
        controller?.zoom(1.0, atPt: g.location(in: self))
    }

    @objc private func onTwoFingerTap(_ g: UITapGestureRecognizer) {
        controller?.zoom(-1.0, atPt: g.location(in: self))
    }

    private static var loggedInputKinds = Set<String>()
    /// One-time-per-kind breadcrumb that input is arriving at all — simulator
    /// front-ends don't always forward host input, and these lines are how to
    /// tell "no events delivered" apart from "handler math is wrong".
    private func notePointerInput(_ kind: String) {
        if Self.loggedInputKinds.insert(kind).inserted {
            lkLog("input active: \(kind)")
        }
    }

    /// Pointer hover → live cursor lat/lon in the HUD (parity with macOS
    /// mouseMoved; touches don't hover, so this only fires for pointers).
    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            notePointerInput("hover")
            let p = g.location(in: self)
            lastHoverPoint = p
            if let geo = controller?.geo(atPoint: p) {
                model?.cursorLon = geo.lon
                model?.cursorLat = geo.lat
            }
        default:
            lastHoverPoint = nil
            model?.cursorLon = nil
            model?.cursorLat = nil
        }
    }
}

#endif
