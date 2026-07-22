//  ChartView.swift — the one GPU surface, embedded in SwiftUI.
//
//  A layer-backed native view that hands its handle to lookout via the
//  ChartController, forwards input, and lets the controller's display link drive
//  the on-demand render loop. All app chrome (HUD, menus, settings) is native
//  SwiftUI drawn AROUND/OVER this view — lookout owns only the chart pixels.
//
//  macOS is implemented concretely below. The iOS branch is a scaffold: the same
//  ChartController/AppModel drive it; it needs a CAMetalLayer-backed UIView, a
//  LOOKOUT_NATIVE_UIKIT_VIEW ABI kind, and UIGestureRecognizer input (see README).

import SwiftUI
#if canImport(AppKit)
import AppKit
import QuartzCore
#endif
#if canImport(UIKit)
import UIKit
#endif

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

/// All the floating chrome, over a non-interactive clear fill. Lives inside the
/// AppKit overlay host so it draws above the chart's Metal layer.
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
    func maybeAutoOpen() {
        guard !didAutoOpen, window != nil, controller?.handle == nil,
              bounds.width > 1, bounds.height > 1,
              let paths = model?.initialChartPaths(), !paths.isEmpty else { return }
        didAutoOpen = true
        lastOpenId = model?.openRequest?.id ?? 0
        _ = controller?.open(charts: paths, in: self)
        raiseOverlay() // SDL just swapped our layer to CAMetalLayer — put chrome back on top
        syncMetalLayerScale()
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

#else  // ---- iOS scaffold (reuses ChartController/AppModel) --------------------

struct ChartView: UIViewRepresentable {
    @ObservedObject var model: AppModel
    let controller: ChartController

    func makeUIView(context: Context) -> UIView {
        // TODO(iOS): a CAMetalLayer-backed UIView + LOOKOUT_NATIVE_UIKIT_VIEW ABI
        // kind + UIPanGestureRecognizer/UIPinchGestureRecognizer input, forwarding
        // to the SAME ChartController used on macOS. See macos/README.md.
        let v = UIView()
        v.backgroundColor = .darkGray
        controller.model = model
        model.controller = controller
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

#endif
