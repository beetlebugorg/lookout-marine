//  ChartNSView.swift — the macOS chart surface, and the input on it.
//
//  A layer-backed, flipped view whose backing CAMetalLayer IS what lookout
//  presents into. It hosts the chrome as a subview, so the chrome's layer is a
//  sublayer of that same Metal layer and CoreAnimation composites it above the
//  presented drawable.

import SwiftUI
#if canImport(AppKit)
import AppKit
import QuartzCore
#endif

#if os(macOS)


struct ChartView: NSViewRepresentable {
    var model: AppModel
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
        if let req = model.charts.openRequest, req.id != v.lastOpenId {
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
        if let hit, hit !== self { return hit } // a subview, such as a text field
        // AppKit gives the point in the superview space. The map uses
        // Chrome.space, which is the coordinate space of this view.
        //
        // `hit` can be nil here as well as self: linked against macOS 26,
        // NSHostingView answers nil over SwiftUI drawing that carries no
        // gesture — a report's text and its surface as much as empty space.
        // Trusting that nil sent every click on the report to the chart,
        // which picked again under it (§6.4). The map, not AppKit, decides
        // what is chrome; anything inside a chrome frame stays here.
        let local = superview.map { convert(point, from: $0) } ?? point
        let inChrome = ChromeHitMap.shared.contains(local)
        if ProcessInfo.processInfo.environment["LOOKOUT_HITMAP"] != nil {
            lkLog(String(format: "[hitmap] hitTest (%.0f, %.0f) super=%@ chrome=%d",
                         local.x, local.y, hit === self ? "self" : "nil", inChrome ? 1 : 0))
        }
        return inChrome ? self : nil
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
    // True while a mouse series that began on the chrome runs. The whole
    // series is dropped, not only the down (see mouseDown).
    private var chromeClick = false
    /// Debounce for the overlay hover; see scheduleHover.
    private var hoverTimer: Timer?
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
        model?.overlay.pickCentreHint = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
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
              let paths = model?.charts.initialChartPaths(), !paths.isEmpty else { return }
        didAutoOpen = true
        // No frame restoration for this window: the chart reopens from our own
        // recents, and the fromServer frame restore is exactly the mid-load
        // resize the deferral above is dodging.
        window?.isRestorable = false
        model?.overlay.pickCentreHint = CGPoint(x: bounds.midX, y: bounds.midY)
        model?.charts.openingCells = paths.count
        model?.charts.isOpening = true // loader up before the (synchronous) open runs
        model?.charts.preparingSymbols = (lookout_atlas_cache_ready() == 0) // first run?
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.model?.charts.isOpening = false; self.model?.charts.preparingSymbols = false }
            guard self.controller?.handle == nil else { return }
            self.lastOpenId = self.model?.charts.openRequest?.id ?? 0
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

    /// Escape closes the pick report, and the arrows walk its list. The
    /// chart view is the first responder; the SwiftUI overlay is not, so its
    /// own exit and move commands never fire.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // 53 = Escape
            if model?.overlay.chartMenu != nil {
                model?.overlay.closeChartMenu()
                return
            }
            if model?.overlay.renaming != nil {
                model?.overlay.cancelRename()
                return
            }
            if model?.overlay.picture != nil {
                model?.overlay.picture = nil
                return
            }
            if model?.overlay.pickPoint != nil {
                model?.overlay.closePick()
                return
            }
        }
        // 126 up, 125 down: the selection in the pick's list.
        if let model, model.overlay.pickResults.count > 1 {
            if event.keyCode == 126 {
                model.overlay.pickIndex = max(0, model.overlay.pickIndex - 1)
                return
            }
            if event.keyCode == 125 {
                model.overlay.pickIndex = min(model.overlay.pickResults.count - 1, model.overlay.pickIndex + 1)
                return
            }
        }
        super.keyDown(with: event)
    }

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
        // the pointer is outside: only track it while it is over the chart.
        guard bounds.contains(p) else {
            clearHover()
            return
        }
        scheduleHover(at: p)
    }
    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    // MARK: Hover over an overlay symbol

    /// How long the pointer must settle before the overlay is asked what is
    /// under it.
    private static let hoverDelay: TimeInterval = 0.15

    /// Ask once the pointer has been still for `hoverDelay`. An open tooltip
    /// is dropped as soon as the pointer leaves its symbol, without waiting.
    private func scheduleHover(at p: CGPoint) {
        hoverTimer?.invalidate()
        if model?.overlay.pinned != nil { return } // one bubble at a time
        if model?.overlay.hover != nil, controller?.overlayInfo(atPoint: p) == nil { clearHover() }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverDelay,
                                          repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.model else { return }
                let info = self.controller?.overlayInfo(atPoint: p)
                if m.overlay.hover != info { m.overlay.hover = info }
                m.overlay.hoverPoint = info == nil ? nil : p
            }
        }
    }

    private func clearHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard let m = model else { return }
        if m.overlay.hover != nil { m.overlay.hover = nil }
        if m.overlay.hoverPoint != nil { m.overlay.hoverPoint = nil }
    }

    // MARK: Drag = pan (with fling) / shift-drag = rotate

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // A click on the chrome bubbles here when SwiftUI has no control
        // under the point. The click must not become chart input: one
        // pixel of drag pans the chart, and a pan retires the pick
        // report. The mouse-up then picks again under where the report
        // was. Latch at mouse-down and drop the whole down-drag-up
        // series; scrollWheel and magnify refuse the same way.
        chromeClick = overChrome(p)
        if chromeClick { return }
        // A press on the chart puts an open menu away, and then behaves as an
        // ordinary press: a click that only dismissed would cost the mariner
        // a second one to start the pan they were already making.
        model?.overlay.closeChartMenu()
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
        if chromeClick { return }
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
        // The latch, not a fresh test: the report can close or move
        // between down and up, and the up must still stay dead.
        if chromeClick { chromeClick = false; return }
        let p = convert(event.locationInWindow, from: nil)
        defer { dragging = false; rotating = false }
        if rotating { return }
        let moved = hypot(p.x - downPoint.x, p.y - downPoint.y)
        if moved <= 4 {
            tapChart(at: p)
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

    /// A plain click on the chart. It pins an overlay symbol's card and does
    /// nothing else.
    ///
    /// IT DOES NOT PICK. A stray click while panning used to throw a pick
    /// report the mariner never asked for, and the plain click belongs to the
    /// chart. What is at a point is asked for by name now, from the menu a
    /// right-click raises there.
    private func tapChart(at p: CGPoint) {
        // The last line of defense for §6.2. The pass-through host should
        // have swallowed a click on the chrome, but every routing path that
        // assumption depends on has failed at least once. A click that slips
        // through does nothing instead of acting on what is under the panel.
        if ChromeHitMap.shared.contains(p) {
            if ProcessInfo.processInfo.environment["LOOKOUT_HITMAP"] != nil {
                lkLog(String(format: "[hitmap] tapChart refused (%.0f, %.0f): inside chrome",
                             p.x, p.y))
            }
            return
        }
        // An overlay symbol answers first and takes the click: a tap on a
        // target pins its bubble, because a mariner tapping a vessel is asking
        // about the vessel rather than the water under it.
        if let hit = controller?.overlayHit(atPoint: p) {
            model?.overlay.pin(hit)
            return
        }
        model?.overlay.closePin() // a click elsewhere on the chart closes the bubble
    }

    // MARK: The chart menu

    /// A right-click raises the menu at that point. AppKit routes control-click
    /// and a two-finger tap here too, so every way a Mac asks for a context
    /// menu lands in one place.
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if overChrome(p) {
            super.rightMouseDown(with: event)
            return
        }
        model?.overlay.openChartMenu(at: p)
    }

    // MARK: Wheel / pinch zoom (cursor-anchored)

    /// A wheel or pinch over the chrome belongs to the chrome. A scroll the pick
    /// report does not use — its text already at the end, or short enough to need
    /// no scrolling — walks the responder chain to this view, and zooming on it
    /// closed the report the reader was scrolling.
    private func overChrome(_ p: NSPoint) -> Bool {
        ChromeHitMap.shared.contains(p)
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if overChrome(p) { return }
        // Trackpad precise deltas are large; a classic wheel notch is ~±1 (match
        // the demo's 0.25 factor for wheels).
        let factor = event.hasPreciseScrollingDeltas ? 0.01 : 0.25
        let dz = Double(event.scrollingDeltaY) * factor
        if dz != 0 { controller?.zoom(dz, atPt: p) }
    }

    override func magnify(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if overChrome(p) { return }
        controller?.zoom(Double(event.magnification) * 3.0, atPt: p)
    }
}

#endif
