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
/// The pick report's body for a view size: a callout beside the object on a
/// wide view, a sheet against an edge of a narrow or a short one.
enum PickForm {
    case callout, bottomSheet, sideSheet
}

/// Which edge of the callout is held against the pick mark.
enum CalloutEdge {
    case above   // the card's floor sits over the mark
    case below   // the card's top sits under the mark
}

/// Where a callout stands, and the height it may use.
///
/// `y` is the edge that `edge` names. SwiftUI places the opposite edge, so
/// nothing measures the card to position it. `room` is a hard limit. The card
/// sizes its columns and its scroll area to `room`, so a long report cannot
/// grow over the mark.
struct CalloutPlace {
    let x: CGFloat
    let y: CGFloat
    let edge: CalloutEdge
    let room: CGFloat
}

struct OverlayLayer: View {
    @ObservedObject var model: AppModel
    /// The OS appearance, which the chrome follows in the day scheme.
    @Environment(\.colorScheme) private var osScheme

    /// Below this width the capsule and the corner chrome cannot share the
    /// bottom row, and the pick report becomes a bottom sheet.
    private static let compactWidth: CGFloat = 700
    /// Below this height there is no room for a callout over a chart: a phone
    /// on its side. The report holds the leading edge instead.
    private static let shortHeight: CGFloat = 520
    /// The bottom band the HUD capsule owns: its height and a margin each side.
    private static let hudBand = Chrome.margin * 2 + Chrome.capsule

    static func pickForm(for size: CGSize) -> PickForm {
        if size.width < compactWidth { return .bottomSheet }
        if size.height < shortHeight { return .sideSheet }
        return .callout
    }

    /// Put the callout over the pick. The card is centred on the mark and its
    /// floor stops clear of it.
    ///
    /// The card gets the room between the mark and the margin. A long report
    /// scrolls in that room. The card goes under the mark only when the room
    /// above is too small to read a report in.
    static func calloutLayout(point: CGPoint, width: CGFloat, in view: CGSize) -> CalloutPlace {
        let clear = PickMarker.size / 2 + 6
        let minX = Chrome.margin
        let maxX = max(minX, view.width - Chrome.margin - width)
        // The free area's floor. The card stops here; the HUD owns the rest.
        let floor = max(Chrome.margin, view.height - Self.hudBand)
        let x = min(max(point.x - width / 2, minX), maxX)

        let over = (point.y - clear) - Chrome.margin
        let under = floor - (point.y + clear)
        // Use the space above unless it is too small and the space below is
        // larger.
        if over >= 200 || over >= under {
            return CalloutPlace(x: x, y: point.y - clear, edge: .above, room: max(0, over))
        }
        return CalloutPlace(x: x, y: point.y + clear, edge: .below, room: max(0, under))
    }

    /// Where the hover tooltip stands. The tip sits below and right of the
    /// pointer, and flips to the other side of whichever edge it would cross.
    /// The card is never measured: it holds two edges and SwiftUI sizes it.
    struct HoverPlace {
        let alignment: Alignment
        let leading: CGFloat
        let trailing: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    static func hoverLayout(point: CGPoint, in view: CGSize) -> HoverPlace {
        let gap: CGFloat = 14
        let flipX = point.x + gap + HoverTip.maxWidth > view.width - Chrome.margin
        let flipY = point.y + gap + HoverTip.assumedHeight > view.height - Chrome.margin
        return HoverPlace(
            alignment: Alignment(horizontal: flipX ? .trailing : .leading,
                                 vertical: flipY ? .bottom : .top),
            leading: flipX ? 0 : point.x + gap,
            trailing: flipX ? max(0, view.width - point.x + gap) : 0,
            top: flipY ? 0 : point.y + gap,
            bottom: flipY ? max(0, view.height - point.y + gap) : 0)
    }

    /// Where the chart menu stands: down and right of the press, flipped at
    /// whichever edge it would cross. Like the hover tip, the panel is never
    /// measured: it holds two edges and SwiftUI sizes it.
    static func menuLayout(point: CGPoint, in view: CGSize, hasMarker: Bool) -> HoverPlace {
        let gap: CGFloat = 2
        let flipX = point.x + gap + ChartMenuPanel.width > view.width - Chrome.margin
        let flipY = point.y + gap + ChartMenuPanel.assumedHeight(hasMarker: hasMarker)
            > view.height - Chrome.margin
        return HoverPlace(
            alignment: Alignment(horizontal: flipX ? .trailing : .leading,
                                 vertical: flipY ? .bottom : .top),
            leading: flipX ? 0 : point.x + gap,
            trailing: flipX ? max(0, view.width - point.x + gap) : 0,
            top: flipY ? 0 : point.y + gap,
            bottom: flipY ? max(0, view.height - point.y + gap) : 0)
    }

    static func bottomSheetSize(in view: CGSize) -> CGSize {
        // The chart keeps the larger part of the view.
        CGSize(width: view.width, height: min(340, (view.height * 0.48).rounded(.down)))
    }
    static let sideSheetWidth: CGFloat = 360

    /// The capsule's measured height. It is one row on a wide window and two on
    /// a phone, and the corner chrome has to clear whichever it is.
    @State private var capsuleHeight: CGFloat = Chrome.capsule

    /// How far the capsule sits off the bottom. A phone gives it less, because
    /// a two-row capsule grows upward into the zoom controls and the screen has
    /// none to spare.
    private var capsuleBottom: CGFloat { Chrome.gap }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < Self.compactWidth
            let form: PickForm? = model.pickAnchor == nil ? nil : Self.pickForm(for: geo.size)
            // A side sheet owns the leading edge; the chrome there slides
            // inboard of it.
            let sideInset: CGFloat = form == .sideSheet ? Self.sideSheetWidth + Chrome.gap : 0
            // The bottom inset of the corner chrome. It clears the capsule in
            // a narrow window, and the sheet when one is up.
            let corner: CGFloat = form == .bottomSheet
                ? Self.bottomSheetSize(in: geo.size).height + Chrome.gap
                : (compact ? capsuleBottom + capsuleHeight + Chrome.gap : Chrome.margin)
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
                    .padding(.leading, sideInset)
                }
                // Top right: north. It is always visible. It stays at the
                // physical trailing edge, because in landscape the safe-area
                // inset moves it toward the middle.
                .overlay(alignment: .topTrailing) {
                    NorthBubble(rotationDeg: model.rotationDeg,
                                orientation: model.orientation) { model.cycleOrientation() }
                        .chromeHitRegion("compass")
                        .padding(Chrome.margin)
                        .ignoresSafeArea(.container, edges: .trailing)
                }
                // Bottom right: follow above zoom above settings. The charts
                // live in the Charts tab of the settings.
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
                // Bottom left: the scale bar.
                .overlay(alignment: .bottomLeading) {
                    if model.hasChart {
                        ScaleBarView(scaleDenominator: model.scaleDenominator,
                                     credit: model.chartLinkAttribution)
                            .padding(.leading, Chrome.margin + sideInset)
                            .padding(.bottom, corner)
                    }
                }
                // The mark on what was picked, then the report beside it.
                .overlay(alignment: .topLeading) {
                    if let point = model.pickPoint {
                        PickMarker()
                            .offset(x: point.x - PickMarker.size / 2,
                                    y: point.y - PickMarker.size / 2)
                    }
                }
                // The report, in the body the view size asks for. The tail is
                // drawn first, so its inner half hides under the panel.
                // Everything is placed with padding, not an offset: an offset
                // moves the drawing and not the layout, so the frame the
                // chrome publishes would stay at the top left and every click
                // on the report would reach the chart underneath.
                // The report docks where the pick was taken and stays there.
                // Only the mark above tracks the chart.
                .overlay(alignment: .topLeading) {
                    if let point = model.pickAnchor, let form {
                        switch form {
                        case .callout:
                            let width = PickCallout.width(for: model.pickResults.count,
                                                          in: geo.size.width)
                            let place = Self.calloutLayout(point: point, width: width,
                                                           in: geo.size)
                            let card = PickCallout(model: model, width: width,
                                                   roomBelow: place.room, anchor: point)
                                .chromeHitRegion("pick-report")
                                .padding(.leading, place.x)
                            // The card holds one edge against the mark.
                            // SwiftUI aligns the opposite edge, so the card's
                            // height is never measured here. Use padding, not
                            // an offset. An offset moves the drawing only and
                            // leaves the frame, and the chrome hit region,
                            // behind.
                            switch place.edge {
                            case .above:
                                card.frame(maxWidth: .infinity, maxHeight: .infinity,
                                           alignment: .bottomLeading)
                                    .padding(.bottom, max(0, geo.size.height - place.y))
                            case .below:
                                card.frame(maxWidth: .infinity, maxHeight: .infinity,
                                           alignment: .topLeading)
                                    .padding(.top, place.y)
                            }
                        case .bottomSheet:
                            let size = Self.bottomSheetSize(in: geo.size)
                            ZStack(alignment: .topLeading) {
                                if point.y < geo.size.height - size.height - PickMarker.size / 2 {
                                    PickTail()
                                        .padding(.leading, min(max(point.x, 30),
                                                               geo.size.width - 30)
                                                           - PickTail.size / 2)
                                        .padding(.top, geo.size.height - size.height
                                                       - PickTail.size / 2)
                                }
                                PickSheet(model: model, side: .bottom, sheetSize: size,
                                          anchor: point, onScaleTap: toggleScaleEntry)
                                    .chromeHitRegion("pick-report")
                                    .padding(.top, geo.size.height - size.height)
                            }
                        case .sideSheet:
                            let size = CGSize(width: Self.sideSheetWidth,
                                              height: geo.size.height)
                            ZStack(alignment: .topLeading) {
                                if point.x > size.width + PickMarker.size / 2 {
                                    PickTail()
                                        .padding(.leading, size.width - PickTail.size / 2)
                                        .padding(.top, min(max(point.y, 30),
                                                           geo.size.height - 30)
                                                       - PickTail.size / 2)
                                }
                                PickSheet(model: model, side: .leading, sheetSize: size,
                                          anchor: point, onScaleTap: toggleScaleEntry)
                                    .chromeHitRegion("pick-report")
                            }
                        }
                    }
                }
                // Bottom center: the readout capsule. The scale entry opens
                // above it. A sheet folds the readouts into its own footer,
                // so the capsule stands down and the entry clears the sheet.
                .overlay(alignment: .bottom) {
                    VStack(spacing: Chrome.gap) {
                        if model.showScaleEntry {
                            ScaleEntryPanel(model: model)
                                .chromeHitRegion("scale-entry")
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if model.hasChart, form == nil || form == .callout {
                            ReadoutsCapsule(model: model, compact: compact,
                                            onScaleTap: toggleScaleEntry)
                                .measureSize { capsuleHeight = $0.height }
                        }
                    }
                    .padding(.bottom, form == .bottomSheet
                             ? Self.bottomSheetSize(in: geo.size).height + Chrome.gap
                             : capsuleBottom)
                }
                .overlay(alignment: .top) {
                    if model.isBuilding { BuildingPill().padding(.top, 10) }
                }
                // Top centre: what the plugins are alarming about. It is drawn
                // after the building pill, so an alarm is never under it, and
                // it takes the pointer because the mariner has to be able to
                // press Acknowledge.
                .overlay(alignment: .top) {
                    if !model.alerts.isEmpty {
                        AlertBanner(alerts: model.alerts) { model.acknowledgeAlert($0) }
                            .chromeHitRegion("plugin-alerts")
                            .padding(.top, Chrome.margin)
                    }
                }
                .overlay {
                    if let picture = model.picture {
                        PictureViewer(model: model, picture: picture)
                            .chromeHitRegion("picture-viewer")
                    }
                }
                .overlay {
                    if model.showStartupLoader {
                        StartupLoader(phase: model.loadingPhase, cells: model.openingCells)
                            .transition(.opacity)
                    } else if !model.hasChart {
                        // The Metal layer keeps the last frame it presented, so
                        // a closed chart stays on screen with nothing drawing
                        // it. Cover it here rather than hiding the layer: the
                        // chrome is a subview of that same layer, and hiding it
                        // takes this panel with it.
                        Chrome.panel.ignoresSafeArea()
                    }
                }
                .overlay {
                    // The picker asked a question the mariner has answered.
                    // While the answer is being acted on, the work stands in
                    // its place.
                    if !model.showStartupLoader, !model.hasChart, model.chartWork == nil {
                        EmptyChartState(model: model).chromeHitRegion("empty-state")
                            .transition(.opacity)
                    }
                }
                // Importing runs for minutes over a big folder, so it never
                // blocks the chart. ONE panel in both places: centred and open
                // while there is nothing to look at, then it travels to the top
                // and closes once charts are drawing. Same view, so the move is
                // something the eye can follow.
                .overlay(alignment: model.hasChart ? .top : .center) {
                    if let b = model.chartWork {
                        ChartWorkPanel(progress: b, compact: model.hasChart,
                                       onCancel: { model.cancelBake() })
                            .padding(.top, model.hasChart ? 10 : 0)
                            .chromeHitRegion("chart-work")
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.5), value: model.hasChart)
                .animation(.easeInOut(duration: 0.25), value: model.chartWork == nil)
                // The overlay hover tooltip, clear of the pointer. Padding,
                // not an offset, for the reason above. No chrome hit region:
                // a click over the tip must still pick the chart under it.
                .overlay(alignment: .topLeading) {
                    if let info = model.hover, let p = model.hoverPoint, model.pinned == nil {
                        let place = Self.hoverLayout(point: p, in: geo.size)
                        HoverTip(info: info)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: place.alignment)
                            .padding(.leading, place.leading)
                            .padding(.trailing, place.trailing)
                            .padding(.top, place.top)
                            .padding(.bottom, place.bottom)
                            .allowsHitTesting(false)
                    }
                }
                // The rename field, over its marker. Padding, not an offset:
                // an offset moves the drawing and leaves the frame, and the
                // chrome hit region with it, behind. It sits above and right
                // of the mark, clear of the mark's own name.
                .overlay(alignment: .topLeading) {
                    if model.renaming != nil, let p = model.renamingPoint {
                        MarkerRenameField(model: model)
                            .chromeHitRegion("marker-rename")
                            .padding(.leading, min(max(0, p.x + 10),
                                                   max(0, geo.size.width - MarkerRenameField.width)))
                            .padding(.top, max(0, p.y - 40))
                    }
                }
                // The chart menu, at the point it was raised at.
                .overlay(alignment: .topLeading) {
                    if let menu = model.chartMenu {
                        let place = Self.menuLayout(point: menu.at, in: geo.size,
                                                    hasMarker: menu.marker != nil)
                        ChartMenuPanel(model: model, menu: menu)
                            .chromeHitRegion("chart-menu")
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: place.alignment)
                            .padding(.leading, place.leading)
                            .padding(.trailing, place.trailing)
                            .padding(.top, place.top)
                            .padding(.bottom, place.bottom)
                    }
                }
                // The pinned bubble. Same card as the tooltip, with a close
                // control, and it takes the pointer: the mariner has to be
                // able to press that control.
                .overlay(alignment: .topLeading) {
                    if let pin = model.pinned, let p = model.pinnedPoint {
                        let place = Self.hoverLayout(point: p, in: geo.size)
                        HoverTip(info: pin.info) { model.closePin() }
                            .chromeHitRegion("pinned-bubble")
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: place.alignment)
                            .padding(.leading, place.leading)
                            .padding(.trailing, place.trailing)
                            .padding(.top, place.top)
                            .padding(.bottom, place.bottom)
                    }
                }
                // No .animation keyed on pickResults: it animates every layout
                // change in the subtree, which slid each new report across the
                // chart from the previous one's position. The report shows
                // immediately, at its place.
                .animation(.default, value: model.isBuilding)
                .animation(.easeInOut(duration: 0.18), value: model.showScaleEntry)
                .animation(.easeInOut(duration: 0.18), value: model.searchOpen)
                .animation(.easeInOut(duration: 0.25), value: model.showStartupLoader)
        }
        // chromeHitRegion writes the control frames in this space.
        // The pass-through hosts hit-test against it.
        .coordinateSpace(name: Chrome.space)
        // The chrome keeps the chart's hours: dusk and night wear the dark
        // palette whatever the OS says, and the day scheme follows the OS.
        .environment(\.colorScheme, model.scheme == 0 ? osScheme : .dark)
    }

    private func toggleScaleEntry() {
        if model.showScaleEntry { model.showScaleEntry = false }
        else { model.beginScaleEntry() }
    }
}

/// Write this view's frame to ChromeHitMap. The pass-through host keeps the
/// clicks in these frames and lets all other clicks reach the chart. Both
/// platforms need this, because a SwiftUI control has no view of its own and
/// hit-tests as the hosting view, like empty space.
private struct ChromeHitRegion: ViewModifier {
    let id: String
    /// Names this instance in the map, so a dying view with the same id
    /// cannot overwrite or remove the live view's entry.
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Chrome.space)) }) {
                ChromeHitMap.shared.set(id, token: token, $0)
            }
            .onDisappear { ChromeHitMap.shared.remove(id, token: token) }
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
            NSLog("[hitmap] hitTest (%.0f, %.0f) super=%@ chrome=%d",
                  local.x, local.y, hit === self ? "self" : "nil", inChrome ? 1 : 0)
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
        model?.pickCentreHint = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
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
        model?.pickCentreHint = CGPoint(x: bounds.midX, y: bounds.midY)
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

    /// Escape closes the pick report, and the arrows walk its list. The
    /// chart view is the first responder; the SwiftUI overlay is not, so its
    /// own exit and move commands never fire.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // 53 = Escape
            if model?.chartMenu != nil {
                model?.closeChartMenu()
                return
            }
            if model?.renaming != nil {
                model?.cancelRename()
                return
            }
            if model?.picture != nil {
                model?.picture = nil
                return
            }
            if model?.pickPoint != nil {
                model?.closePick()
                return
            }
        }
        // 126 up, 125 down: the selection in the pick's list.
        if let model, model.pickResults.count > 1 {
            if event.keyCode == 126 {
                model.pickIndex = max(0, model.pickIndex - 1)
                return
            }
            if event.keyCode == 125 {
                model.pickIndex = min(model.pickResults.count - 1, model.pickIndex + 1)
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
        if model?.pinned != nil { return } // one bubble at a time
        if model?.hover != nil, controller?.overlayInfo(atPoint: p) == nil { clearHover() }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverDelay,
                                          repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.model else { return }
                let info = self.controller?.overlayInfo(atPoint: p)
                if m.hover != info { m.hover = info }
                m.hoverPoint = info == nil ? nil : p
            }
        }
    }

    private func clearHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard let m = model else { return }
        if m.hover != nil { m.hover = nil }
        if m.hoverPoint != nil { m.hoverPoint = nil }
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
        model?.closeChartMenu()
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
                NSLog("[hitmap] tapChart refused (%.0f, %.0f): inside chrome", p.x, p.y)
            }
            return
        }
        // An overlay symbol answers first and takes the click: a tap on a
        // target pins its bubble, because a mariner tapping a vessel is asking
        // about the vessel rather than the water under it.
        if let hit = controller?.overlayHit(atPoint: p) {
            model?.pin(hit)
            return
        }
        model?.closePin() // a click elsewhere on the chart closes the bubble
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
        model?.openChartMenu(at: p)
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

#else  // ---- iOS (reuses ChartController/AppModel) ---------------------------

struct ChartView: View {
    @ObservedObject var model: AppModel
    let controller: ChartController
    /// The OS appearance, which the form follows in the day scheme. Read
    /// here, outside OverlayLayer, so it is the real OS value and not the
    /// chrome's own override.
    @Environment(\.colorScheme) private var osScheme

    var body: some View {
        // Chrome only: the chart renders in SDL's own window and the gesture
        // surface (ChartUIView) lives in the plain-UIKit input window between
        // them — SwiftUI never sees chart touches (see SceneDelegate).
        OverlayLayer(model: model)
        // The form brings its OWN navigation: a stack on a phone, a sidebar
        // and pane on an iPad. It cannot be given one from out here, because
        // only the form knows how wide it came up.
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
                // The form follows the chart's scheme, like the rest of the
                // chrome. The scheme is set here because OverlayLayer sets it
                // inside its own body, and this sheet is attached outside
                // that body.
                //
                // Always pass a value. `nil` means "no preference", and that
                // does not remove a preference already applied to an open
                // sheet. The OS scheme makes a return to Day a change.
                .preferredColorScheme(model.scheme == 0 ? osScheme : .dark)
        }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [.item, .folder]) { result in
            if case .success(let url) = result { model.openImported(url) }
        }
        // On its OWN view. Two .fileImporter modifiers on one view collide —
        // SwiftUI presents only the outer, so Add Charts silently did nothing.
        // A background node keeps the raster importer clear of the vector one.
        .background(
            Color.clear.fileImporter(isPresented: $model.showRasterImporter,
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
        model?.pickCentreHint = inChromeSpace(CGPoint(x: bounds.midX, y: bounds.midY))
        // The space the report is laid out in. The chrome is inset by the
        // safe area and this view is not.
        if let inset = chromeWindow?.safeAreaInsets {
            model?.chromeSize = CGSize(width: bounds.width - inset.left - inset.right,
                                       height: bounds.height - inset.top - inset.bottom)
        } else {
            model?.chromeSize = bounds.size
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
        // No hover recognizer: it fed the cursor lat/lon readout, and the
        // readout carries own ship now. It comes back with this shell's own
        // press menu, which is what will need a pointer position again.
        // (No scroll-to-zoom recognizer either: `allowedScrollTypesMask` also
        // fires on a pointer *drag*, which then zoomed instead of panned.
        // Pinch is the zoom gesture; +/- and double-tap cover pointer users.)
        //
        // The pan needs a delegate too. UIKit asks both recognizers of a
        // pair whether they may run together, and a recognizer with no
        // delegate answers no.
        [pan, pinch, rotate].forEach { $0.delegate = self } // these compose (see below)
        [pan, pinch, rotate, doubleTap, twoFingerTap, tap].forEach(addGestureRecognizer)
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
    /// asked for by name, from the menu a press raises there, which this shell
    /// does not carry yet.
    @objc private func onTap(_ g: UITapGestureRecognizer) {
        notePointerInput("tap")
        model?.closePin()
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

/// What a plugin overlay symbol says, shown while the pointer rests on it.
/// Panel surface and type sizes are the app's, the same as a pick report.
/// Values are monospaced-digit so a live SOG does not reflow its column.
struct HoverTip: View {
    let info: OverlayHover
    /// Set when the card is PINNED: it then carries a close control. A hover
    /// tooltip has none — it goes when the pointer does.
    var onClose: (() -> Void)?

    /// `maxWidth` caps the card. `assumedHeight` only tells hoverLayout which
    /// way to flip, so it is an over-estimate and never a frame.
    static let maxWidth: CGFloat = 240
    static let assumedHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(info.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                    .lineLimit(1)
                if let onClose {
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Chrome.muted)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(ChromeFlatStyle(cornerRadius: 4))
                    .help("Close")
                    .accessibilityLabel("Close")
                }
            }
            if !info.rows.isEmpty {
                Divider().overlay(Chrome.rule)
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(info.rows, id: \.0) { key, value in
                        GridRow {
                            Text(key)
                                .font(.system(size: 11))
                                .foregroundStyle(Chrome.muted)
                            Text(value)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Chrome.ink)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .panelSurface(cornerRadius: 8, opaque: true)
    }
}
