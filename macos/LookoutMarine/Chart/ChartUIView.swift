//  ChartUIView.swift — the iOS chart surface, and the gestures on it.
//
//  Plain UIKit, in the input window: SwiftUI's hosting view hit-tests as itself
//  across its whole window and never forwards touches to UIKit subviews or
//  window-attached recognizers, so a gesture surface inside SwiftUI renders
//  fine and never hears a touch. This view's backing layer is the chart's
//  CAMetalLayer.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)

struct ChartView: View {
    let model: AppModel
    let controller: ChartController
    /// The OS appearance, which the form follows in the day scheme. Read
    /// here, outside OverlayLayer, so it is the real OS value and not the
    /// chrome's own override.
    @Environment(\.colorScheme) private var osScheme

    var body: some View {
        // A binding cannot be made through AppModel, which owns its models
        // with a let, so the one this view writes is taken locally.
        @Bindable var chrome = model.chrome
        // Chrome only: the chart renders in SDL's own window and the gesture
        // surface (ChartUIView) lives in the plain-UIKit input window between
        // them — SwiftUI never sees chart touches (see SceneDelegate).
        OverlayLayer(model: model)
        // The form brings its OWN navigation: a stack on a phone, a sidebar
        // and pane on an iPad. It cannot be given one from out here, because
        // only the form knows how wide it came up.
        .sheet(isPresented: $chrome.showSettings) {
            SettingsView(model: model)
                // The form follows the chart's scheme, like the rest of the
                // chrome. The scheme is set here because OverlayLayer sets it
                // inside its own body, and this sheet is attached outside
                // that body.
                //
                // Always pass a value. `nil` means "no preference", and that
                // does not remove a preference already applied to an open
                // sheet. The OS scheme makes a return to Day a change.
                .preferredColorScheme(model.readouts.scheme == 0 ? osScheme : .dark)
        }
        .fileImporter(isPresented: $chrome.showImporter,
                      allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result { model.openImported(url) }
        }
        // On its OWN view. Two .fileImporter modifiers on one view collide —
        // SwiftUI presents only the outer, so Add Charts silently did nothing.
        // A background node keeps the raster importer clear of the vector one.
        .background(
            Color.clear.fileImporter(isPresented: $chrome.showRasterImporter,
                          allowedContentTypes: [.item, .folder],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.importRasterCharts(urls) }
            }
        )
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
            // queue: .main, so this runs on the main actor; assert it so the
            // main-actor-isolated handle is reachable from the Sendable closure.
            MainActor.assumeIsolated {
                if let h = self?.controller?.handle { lookout_memory_warning(h) }
            }
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
        // The hint follows every layout, not just the first: at auto-open time
        // the chrome window is not wired yet and its safe-area inset reads
        // zero, which put the hook-driven pick's mark off its object by that
        // inset once the window settled.
        model?.overlay.pickCentreHint = inChromeSpace(CGPoint(x: bounds.midX, y: bounds.midY))
        // The space the report is laid out in. The chrome is inset by the
        // safe area and this view is not.
        if let inset = chromeWindow?.safeAreaInsets {
            model?.overlay.chromeSize = CGSize(width: bounds.width - inset.left - inset.right,
                                       height: bounds.height - inset.top - inset.bottom)
        } else {
            model?.overlay.chromeSize = bounds.size
        }
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
        let paths = model?.charts.openRequest?.paths ?? model?.charts.initialChartPaths() ?? []
        guard !paths.isEmpty else { return }
        didAutoOpen = true
        lastSizePt = bounds.size
        model?.charts.openingCells = paths.count
        model?.charts.isOpening = true // loader up before the (synchronous) open runs
        model?.charts.preparingSymbols = (lookout_atlas_cache_ready() == 0) // first run?
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.model?.charts.isOpening = false; self.model?.charts.preparingSymbols = false }
            guard self.controller?.handle == nil else { return }
            self.lastOpenId = self.model?.charts.openRequest?.id ?? 0
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
        // A press raises the chart menu at that point, which is the Mac's
        // right-click. Without it a touch device has no way to reach the pick
        // report, drop or rename a mark, or copy a position: the menu is the
        // only route to all five.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(onPress(_:)))
        press.minimumPressDuration = 0.45
        // The wheel and a trackpad's two-finger scroll zoom about the
        // pointer, as they do on the Mac.
        //
        // A recognizer of its own, with no touch types at all. Giving the PAN
        // an `allowedScrollTypesMask` is the obvious way and is wrong: that
        // recognizer then fires on a pointer DRAG as well, and the chart
        // zoomed when the mariner meant to pan. Empty `allowedTouchTypes`
        // leaves this one deaf to everything but a scroll.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)
        // No hover recognizer: it fed the cursor lat/lon readout, and the
        // readout carries own ship now. It comes back with this shell's own
        // press menu, which is what will need a pointer position again.
        //
        // The pan needs a delegate too. UIKit asks both recognizers of a
        // pair whether they may run together, and a recognizer with no
        // delegate answers no.
        [pan, pinch, rotate].forEach { $0.delegate = self } // these compose (see below)
        [pan, pinch, rotate, doubleTap, twoFingerTap, tap, press].forEach(addGestureRecognizer)
        panRecognizer = pan
    }

    /// Held so a starting pinch can cancel the pan.
    private weak var panRecognizer: UIPanGestureRecognizer?

    /// Pinch and rotate run together as one two-finger manipulation. Pinch
    /// also runs with the pan.
    ///
    /// Two fingers do not land on the same frame. The first finger starts the
    /// pan, because `maximumNumberOfTouches` caps the touches a pan tracks but
    /// does not stop it starting. Pinch must therefore be allowed to start
    /// while the pan runs, or it never starts at all. `onPinch` cancels the
    /// pan at once, so the two never drive the chart together.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair: Set = [ObjectIdentifier(type(of: gestureRecognizer)), ObjectIdentifier(type(of: other))]
        let manipulation: Set = [ObjectIdentifier(UIPinchGestureRecognizer.self),
                                 ObjectIdentifier(UIRotationGestureRecognizer.self)]
        if pair.isSubset(of: manipulation) { return true }
        return pair.contains(ObjectIdentifier(UIPanGestureRecognizer.self))
            && pair.contains(ObjectIdentifier(UIPinchGestureRecognizer.self))
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
            // The first finger started a pan. That pan is half of this
            // pinch, not a drag. Toggling `isEnabled` cancels it, so the
            // chart zooms and does not also slide.
            if let pan = panRecognizer, pan.state == .began || pan.state == .changed {
                pan.isEnabled = false
                pan.isEnabled = true
            }
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

    /// A plain tap on the chart. It does NOT pick: a stray tap while panning
    /// used to throw a pick report nobody asked for. What is at a point is
    /// asked for by name, from the menu a press raises.
    ///
    /// A tap also puts an open menu away, as a press does on the Mac, and then
    /// behaves as an ordinary tap.
    @objc private func onTap(_ g: UITapGestureRecognizer) {
        notePointerInput("tap")
        model?.overlay.closeChartMenu()
        model?.overlay.closePin()
    }

    /// A press raises the chart menu at that point. Every item acts on THIS
    /// point, so the coordinates are taken once, here, when the menu opens.
    ///
    /// The finger has been down for the press duration, so the pan has already
    /// started. Cancel it the way a pinch does, or the chart slides out from
    /// under the menu that names a place on it.
    @objc private func onPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        notePointerInput("press")
        if let pan = panRecognizer, pan.state == .began || pan.state == .changed {
            pan.isEnabled = false
            pan.isEnabled = true
        }
        controller?.flingStart(vx: 0, vy: 0)
        model?.overlay.openChartMenu(at: inChromeSpace(g.location(in: self)))
    }

    /// A point in this view, moved into the chrome's coordinate space. The
    /// chrome window's SwiftUI content is inset by the safe area; this view
    /// is not. Without the conversion the mark — and the report's tail, which
    /// aims at it — stands off the object by the width of the inset. This is
    /// defect 11.1 in the behavior spec.
    private func inChromeSpace(_ p: CGPoint) -> CGPoint {
        guard let inset = chromeWindow?.safeAreaInsets else { return p }
        return CGPoint(x: p.x - inset.left, y: p.y - inset.top)
    }

    /// How much of a zoom level one point of scroll is worth. A wheel notch
    /// arrives as about ten points, so a notch is about a third of a level:
    /// enough to feel, small enough to stop where the mariner meant to.
    private static let scrollZoom = 0.03

    /// The running total, so each report zooms by its own delta. The
    /// recognizer reports the translation since the scroll began.
    private var lastScrollY: CGFloat = 0

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            notePointerInput("scroll")
            lastScrollY = 0
            controller?.flingStart(vx: 0, vy: 0)   // a scroll stops any coast
        case .changed:
            let y = g.translation(in: self).y
            let dy = y - lastScrollY
            lastScrollY = y
            guard dy != 0 else { return }
            // Scrolling up zooms in, which is the direction the Mac takes.
            controller?.zoom(Double(dy) * Self.scrollZoom, atPt: g.location(in: self))
        default:
            break
        }
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
}

#endif
