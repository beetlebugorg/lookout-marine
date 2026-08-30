//  ReadoutsCapsule.swift — the readouts at the bottom of the chart.
//
//  Band, scale, zoom and OWN SHIP's position, as one capsule (the WinUI 3
//  shell's HudPill). Where the width will not take one line, a phone, it falls
//  to two rather than dropping a readout: a mariner reads the same values on a
//  phone as on a chart table.
//
//  The raster pill rides in the same row, and on a touch device it is the only
//  way in to the picture charts.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Scale band, 1:N, zoom and OWN SHIP's position. The scale, the position pill
/// and the raster chart pill are the controls.
struct ReadoutsCapsule: View {
    var model: AppModel
    /// A narrow window (a phone) uses a smaller type size. Whether the row
    /// takes one line or two is measured, not assumed — see `body`.
    let compact: Bool
    /// A click on the 1:N readout opens the scale entry.
    let onScaleTap: () -> Void

    /// WHY THIS MEASURES INSTEAD OF ASSUMING.
    ///
    /// The readouts do not fit one line on a phone: the position alone is 44%
    /// of an iPhone's width, and the raster chart pill pushed the row past the
    /// screen, where it lost its shape and clipped. But "phone" is the wrong
    /// question — what matters is whether THIS row fits THIS width, and that
    /// depends on the provider's name, the scale's digits and the window.
    ///
    /// So the row is offered on one line and falls to two only when it must.
    /// Nothing is dropped and nothing hides: a mariner reads the same values on
    /// a phone as on a chart table, and the position stays in front of them.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            readoutRow(withPosition: true)
            VStack(spacing: 2) {
                readoutRow(withPosition: false)
                positionLine
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, compact ? 14 : 18)
        .frame(minHeight: Chrome.capsule)
        .background(Chrome.surface, in: capsuleShape)
        .overlay(capsuleShape.strokeBorder(Chrome.edge.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        // The capsule takes its own taps. Without this a tap on the readouts
        // fell through to the chart and picked whatever was under it.
        .contentShape(capsuleShape)
        .chromeHitRegion("hud-capsule")
    }

    /// A capsule at one line, and a rounded block at two — the corner radius is
    /// half the one-line height, so the settled shape is exactly the capsule it
    /// has always been.
    private var capsuleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Chrome.capsule / 2, style: .continuous)
    }

    /// The position, and the zoom beside it. The second line when there is one.
    private var positionLine: some View {
        HStack(spacing: 10) {
            PositionReadout(model: model, compact: compact)
            separator
            Text(String(format: "z%.1f", model.readouts.zoomLevel))
                .foregroundStyle(Chrome.muted)
        }
        .font(.system(size: compact ? 12 : 14).monospacedDigit())
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func readoutRow(withPosition: Bool) -> some View {
        HStack(spacing: compact ? 10 : 12) {
            Circle()
                .fill(Chrome.amber)
                .frame(width: 10, height: 10)
            // The band says how much the chart has generalised what it shows,
            // in six characters. It stays at every width.
            Text(CoordFormat.band(model.readouts.scaleDenominator))
                .fontWeight(.semibold)
                .foregroundStyle(Chrome.ink)
                .accessibilityIdentifier("band")
            separator
            Button(action: onScaleTap) {
                Text(CoordFormat.scale(model.readouts.scaleDenominator))
                    .fontWeight(.semibold)
                    .foregroundStyle(Chrome.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
            }
            .buttonStyle(ChromeFlatStyle(cornerRadius: 6))
            .help("Zoom to a scale…")
            .accessibilityLabel("Scale \(CoordFormat.scale(model.readouts.scaleDenominator)). Zoom to a scale.")
            .accessibilityIdentifier("scale-readout")
            .chromeHitRegion("scale-readout")
            if withPosition {
                separator
                Text(String(format: "z%.1f", model.readouts.zoomLevel))
                    .foregroundStyle(Chrome.muted)
                separator
                PositionReadout(model: model, compact: compact)
            }
            if model.readouts.overscale > 1.05 {
                Text(String(format: "×%.1f", model.readouts.overscale))
                    .accessibilityIdentifier("overscale")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Chrome.overscale)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Chrome.overscale.opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            // The active raster chart set. Shown whenever a picture is on, because
            // the chart is then drawing WITHOUT its opaque water and land fills
            // — a real reduction in what it is telling the mariner, and one they
            // must never mistake for the full chart. Names the provider, which
            // is what they are choosing between.
            // The raster-chart pill. It appears only where a raster chart is in
            // view. A click steps to the next one — the fast comparison, which
            // must not cost a menu. Click and hold, or right-click, to SEE what
            // is carried here and pick one directly.
            if !pill.inView.isEmpty {
                separator
                #if os(macOS)
                // A plain Button, not a Menu: a macOS Menu renders its own
                // label chrome and drops the pill's fill and tint. The choice
                // list rides on an AppKit menu instead.
                Button { showRasterMenu() } label: { rasterPill }
                    .buttonStyle(.plain)
                    .help(pill.help)
                    .accessibilityLabel(pill.help)
                    .accessibilityIdentifier("raster-pill")
                    .accessibilityValue(pill.stateName)
                    .chromeHitRegion("raster-pill")
                #else
                // A SwiftUI Menu on iOS keeps the label exactly as given, so
                // the pill holds its fill and tint and the touch target is the
                // whole capsule. There is no pointer to pop an AppKit menu at.
                Menu { rasterMenuItems } label: { rasterPill }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel(pill.help)
                    .accessibilityIdentifier("raster-pill")
                    .accessibilityValue(pill.stateName)
                    .chromeHitRegion("raster-pill")
                #endif
            }
        }
        .font(.system(size: compact ? 12 : 14).monospacedDigit())
        .lineLimit(1)
        // Every readout states its full width. A Menu reports an ideal width
        // that does not cover its label, so without this the row is offered
        // less than it needs and truncates whichever readout loses — the scale
        // to "1:26,9…", or the pill's name to "GO…".
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The pill itself. The colour and the text carry the state; both hosts
    /// draw exactly this, so the two platforms cannot drift apart.
    private var rasterPill: some View {
        HStack(spacing: 5) {
            Text(pill.name.uppercased())
            if pill.state != .on {
                Text("|").foregroundStyle(pill.tint.opacity(0.5))
                Text(pill.state == .off ? "OFF" : "ENC OFF")
            }
            // The chevron is a promise: a press opens a list. It is therefore
            // always shown, because a press always does.
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.7)
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(pill.tint)
        // The NAME is the whole point of the pill — it says which picture is
        // under the chart. A Menu label is offered a squeezed width and would
        // truncate it to "GO…", so the pill states its own width.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(pill.tint.opacity(pill.state == .off ? 0.28 : 0.18),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    #if os(iOS)
    /// The same choices the Mac's menu offers, as SwiftUI.
    @ViewBuilder private var rasterMenuItems: some View {
        ForEach(pill.inView) { set in
            Button {
                model.raster.select(set.id)
            } label: {
                if set.id == model.raster.active {
                    Label(set.name, systemImage: "checkmark")
                } else {
                    Text(set.name)
                }
            }
        }
        Button { model.raster.select(-1) } label: {
            if model.raster.active < 0 {
                Label("None", systemImage: "checkmark")
            } else {
                Text("None")
            }
        }
        Divider()
        Button(model.raster.chartHidden ? "Show ENC Over Raster" : "Hide ENC Over Raster") {
            model.raster.toggleChart()
        }
        Button("Add Raster Charts…") { model.chrome.showRasterImporter = true }
    }
    #endif

    #if os(macOS)
    /// Pop the set list at the pointer.
    ///
    /// AppKit rather than a SwiftUI `Menu`: a Menu renders its own label chrome
    /// and drops the pill's fill and tint, and that colour IS the state — amber
    /// for off, blue for drawn, orange for the ENC hidden above it.
    private func showRasterMenu() {
        let menu = NSMenu()
        let target = RasterMenuTarget(model: model)
        menu.autoenablesItems = false
        for set in pill.inView {
            let item = NSMenuItem(title: set.name, action: #selector(RasterMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = set.id
            item.state = (set.id == model.raster.active) ? .on : .off
            menu.addItem(item)
        }
        let none = NSMenuItem(title: "None", action: #selector(RasterMenuTarget.pick(_:)), keyEquivalent: "")
        none.target = target
        none.tag = -1
        none.state = (model.raster.active < 0) ? .on : .off
        menu.addItem(none)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: model.raster.chartHidden ? "Show ENC Over Raster" : "Hide ENC Over Raster",
                              action: #selector(RasterMenuTarget.toggleChart), keyEquivalent: "")
        hide.target = target
        menu.addItem(hide)
        let add = NSMenuItem(title: "Add Raster Charts…", action: #selector(RasterMenuTarget.add), keyEquivalent: "")
        add.target = target
        menu.addItem(add)
        // The target dies with this scope unless the menu holds it.
        objc_setAssociatedObject(menu, Unmanaged.passUnretained(menu).toOpaque(), target, .OBJC_ASSOCIATION_RETAIN)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    #endif

    /// What the pill says, from the sets in view and which one is drawn.
    private var pill: RasterPill {
        RasterPill(inView: model.raster.sets.filter(\.inView),
                   active: model.raster.active, chartHidden: model.raster.chartHidden)
    }

    private var separator: some View {
        Rectangle().fill(Chrome.rule).frame(width: 1, height: 20)
    }
}



#if os(macOS)
/// Carries the pill menu's clicks back to the model. NSMenuItem needs an
/// ObjC target, which a SwiftUI view is not.
@MainActor
private final class RasterMenuTarget: NSObject {
    let model: AppModel
    init(model: AppModel) { self.model = model }
    @objc func pick(_ sender: NSMenuItem) { model.raster.select(sender.tag) }
    @objc func toggleChart() { model.raster.toggleChart() }
    @objc func add() { model.presentRasterPanel() }
}
#endif
