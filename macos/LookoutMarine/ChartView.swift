//  ChartView.swift — the one GPU surface, embedded in SwiftUI.
//
//  A layer-backed native view that hands its handle to lookout via the
//  ChartController, forwards input, and lets the controller's display link drive
//  the on-demand render loop. All app chrome (HUD, menus, settings) is native
//  SwiftUI drawn AROUND/OVER this view — lookout owns only the chart pixels.
//
//  The same ChartController/AppModel drive both platforms. macOS embeds lookout
//  into this NSView directly (SDL wraps it with a CAMetalLayer). iOS can't do
//  that — SDL has no create-from-UIView property — so lookout gets its own
//  full-screen UIWindow inside the app's UIWindowScene, and the iOS ChartView is
//  a transparent gesture surface in the app's chrome window layered above it.

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
struct OverlayLayer: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .bottom) {
                ReadoutsBadge(model: model).padding(12)
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    SearchField(model: model)
                    if abs(model.rotationDeg) >= 0.5 {
                        CompassBadge(rotationDeg: model.rotationDeg) { model.northUp() }
                    }
                }
                .padding(12)
            }
            .overlay(alignment: .topLeading) {
                #if os(iOS)
                ChartActionsBar(model: model).padding(12)
                #endif
            }
            .overlay(alignment: .bottomTrailing) {
                ZoomControls(model: model).padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                if !model.pickResults.isEmpty {
                    IdentifyPanel(results: model.pickResults) { model.pickResults = [] }
                        .padding(12)
                }
            }
            .overlay(alignment: .top) {
                if model.isBuilding { BuildingPill().padding(.top, 10) }
            }
            .overlay {
                if !model.hasChart { EmptyChartState(model: model) }
            }
            .animation(.default, value: model.pickResults)
            .animation(.default, value: model.isBuilding)
    }
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
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
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

    /// Host the floating chrome as a SUBVIEW of the chart. SDL replaces this view's
    /// backing layer with a CAMetalLayer; a subview's layer becomes a *sublayer* of
    /// it, which CoreAnimation composites ABOVE the presented drawable (a sibling
    /// view in the same window would be hidden by the async swapchain present).
    /// PassThroughHostingView lets empty-area clicks reach our own mouse handlers.
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

    /// Re-attach the overlay above SDL's freshly-installed CAMetalLayer.
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

    /// Back this view with our OWN CAMetalLayer so SDL adopts it (instead of
    /// attaching a fresh one at 1x). Its contentsScale is set before the chart
    /// opens, so the Vulkan/Metal swapchain is created at true Retina pixels —
    /// poking the scale after creation doesn't retroactively resize a swapchain.
    override func makeBackingLayer() -> CALayer {
        let ml = CAMetalLayer()
        ml.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // First real size → open the initial chart (at a stable size, not the
        // transient zero/pre-layout bounds). Later sizes just resize.
        if !didAutoOpen { maybeAutoOpen() }
        else { controller?.resize(widthPt: Double(newSize.width), heightPt: Double(newSize.height)) }
        syncMetalLayerScale()
    }

    /// SDL wraps this view with a CAMetalLayer but leaves it at 1x and sized to
    /// the window, so the swapchain drawable comes out logical-sized (blurry, 2x
    /// magnified, and offset against the cursor math). Force the layer to the
    /// view's true backing scale and pixel size; the render core adopts whatever
    /// drawable results (see Gpu.renderWindow), keeping camera and picture exact.
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
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller?.handle == nil else { return }
            self.lastOpenId = self.model?.openRequest?.id ?? 0
            _ = self.controller?.open(charts: paths, in: self)
            self.raiseOverlay() // SDL just swapped our layer to CAMetalLayer — put chrome back on top
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
            NavigationStack {
                SettingsView(model: model)
                    .navigationTitle("Mariner Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { model.showSettings = false } }
            }
        }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result { model.openImported(url) }
        }
    }
}

/// The iOS floating command strip (macOS surfaces these in menus/toolbar).
struct ChartActionsBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            bar(icon: "folder") { model.showImporter = true }
            Divider().frame(width: 30)
            bar(icon: "circle.lefthalf.filled") { model.cycleScheme() }
                .disabled(!model.hasChart)
            Divider().frame(width: 30)
            bar(icon: "gearshape") { model.showSettings = true }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }

    private func bar(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Transparent full-screen gesture surface — the root view of the plain-UIKit
/// INPUT window (SceneDelegate). The chart renders in lookout's OWN UIWindow
/// below it (SDL can't wrap an existing UIView) and the SwiftUI chrome floats
/// in a PassThroughWindow above; this view owns input, sizing, and the
/// auto-open.
final class ChartUIView: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate {
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
    private var lastPinchCentroid = CGPoint.zero
    private var rotationStartDeg = 0.0
    /// Last pointer position from hover (nil on touch-only devices) — anchors
    /// scroll-sink zoom at the pointer when known.
    private var lastHoverPoint: CGPoint?

    /// Trackpad/wheel sink: simulator front-ends deliver indirect scrolls to
    /// UIScrollViews but NOT to plain gesture recognizers (measured — lists
    /// scroll, `allowedScrollTypesMask` pans never fire). This hidden, always
    /// re-centered scroll view rides on top of the gesture surface: pointer
    /// scrolls move its contentOffset (converted to zoom in
    /// scrollViewDidScroll); its pan ignores touches entirely, so finger
    /// gestures pass to this view's recognizers as before.
    private let scrollSink = UIScrollView()
    private var sinkRecentering = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        installGestures()
        installScrollSink()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func installScrollSink() {
        scrollSink.backgroundColor = .clear
        scrollSink.showsVerticalScrollIndicator = false
        scrollSink.showsHorizontalScrollIndicator = false
        scrollSink.contentInsetAdjustmentBehavior = .never
        scrollSink.delegate = self
        scrollSink.panGestureRecognizer.allowedTouchTypes = [] // pointer scrolls only — never fingers
        scrollSink.panGestureRecognizer.allowedScrollTypesMask = .all
        addSubview(scrollSink)
    }

    private func recenterScrollSink() {
        sinkRecentering = true
        scrollSink.frame = bounds
        scrollSink.contentSize = CGSize(width: bounds.width * 3, height: bounds.height * 3)
        scrollSink.contentOffset = CGPoint(x: bounds.width, y: bounds.height)
        sinkRecentering = false
    }

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard sv === scrollSink, !sinkRecentering else { return }
        let dy = sv.contentOffset.y - bounds.height
        let dx = sv.contentOffset.x - bounds.width
        guard dx != 0 || dy != 0 else { return }
        sinkRecentering = true
        sv.contentOffset = CGPoint(x: bounds.width, y: bounds.height)
        sinkRecentering = false
        notePointerInput("scroll")
        // Direction matches the macOS trackpad (ChartNSView.scrollWheel):
        // two-finger swipe toward you zooms in. Flip the sign here if it
        // feels inverted on a given input stack.
        let dz = Double(-dy) * 0.01
        if dz != 0 {
            let anchor = lastHoverPoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
            controller?.zoom(dz, atPt: anchor)
        }
    }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncLayerScale()
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
        recenterScrollSink()
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
        lastOpenId = model?.openRequest?.id ?? 0
        _ = controller?.open(charts: paths, in: self)
        hostWindowAboveChart()
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
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1 // two-finger pans ride the pinch centroid
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(onRotate(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(onTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.require(toFail: doubleTap)
        // Pointer devices (iPad trackpad/mouse, the simulator's host pointer):
        // scroll to zoom at the pointer, hover to feed the cursor readout —
        // the affordances the macOS app gets from NSEvent.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        // Pinch + rotate + scroll compose (delegate below); scroll coexists
        // with the finger pan because its handler only acts on 0-touch pans.
        [pinch, rotate, scroll].forEach { $0.delegate = self }
        [pan, pinch, rotate, doubleTap, twoFingerTap, tap, scroll, hover].forEach(addGestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true // only pinch/rotate/scroll carry the delegate — they compose freely
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

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            notePointerInput("pinch")
            lastPinchScale = g.scale
            lastPinchCentroid = p
            controller?.flingStart(vx: 0, vy: 0)
        case .changed:
            // Zoom by the scale delta, anchored at the fingers' centroid…
            let dz = log2(Double(g.scale / lastPinchScale))
            lastPinchScale = g.scale
            if dz != 0 { controller?.zoom(dz, atPt: p) }
            // …and let the two-finger drag pan at the same time.
            controller?.pan(dxPt: p.x - lastPinchCentroid.x, dyPt: p.y - lastPinchCentroid.y)
            lastPinchCentroid = p
        default:
            break
        }
    }

    @objc private func onRotate(_ g: UIRotationGestureRecognizer) {
        guard let controller else { return }
        switch g.state {
        case .began:
            rotationStartDeg = controller.currentView.rotation_deg
        case .changed:
            var v = controller.currentView
            // UIKit rotation is positive clockwise; course-up rotation_deg turns
            // the chart with the fingers. (If it fights the fingers on-device,
            // this sign is the knob.)
            v.rotation_deg = rotationStartDeg - Double(g.rotation) * 180 / .pi
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

    /// Trackpad/mouse scroll → zoom anchored at the pointer. The 0.01/pt factor
    /// and sign match the macOS trackpad path (ChartNSView.scrollWheel). Only
    /// 0-touch pans are scrolls — finger drags ride the main pan recognizer.
    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed, g.numberOfTouches == 0 else { return }
        notePointerInput("scroll")
        let d = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let dz = Double(d.y) * 0.01
        if dz != 0 { controller?.zoom(dz, atPt: g.location(in: self)) }
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
