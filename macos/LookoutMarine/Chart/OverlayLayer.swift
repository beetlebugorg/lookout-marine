//  OverlayLayer.swift — all the floating chrome, over a clear fill.
//
//  Shared by both platforms: macOS hosts it in an AppKit overlay above the
//  chart's Metal layer, iOS in the chrome window above the input window.
//
//  The layout is the layout of the WinUI 3 shell (windows/ui/MainWindow.xaml):
//  search at the top left, north at the top right, zoom above settings at the
//  bottom right, the scale bar at the bottom left, and the readout capsule at
//  the bottom centre. Where each panel STANDS is CalloutPlacement.swift.

import SwiftUI
#if canImport(AppKit)
import AppKit
import QuartzCore
#endif
#if canImport(UIKit)
import UIKit
#endif

struct OverlayLayer: View {
    var model: AppModel
    /// The OS appearance, which the chrome follows in the day scheme.
    @Environment(\.colorScheme) private var osScheme

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
                                     credit: model.chartLinks.attribution)
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
                    if !model.plugins.alerts.isEmpty {
                        AlertBanner(alerts: model.plugins.alerts) { model.plugins.acknowledge($0) }
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
