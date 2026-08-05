//  HUDOverlay.swift — the readouts above the chart.
//
//  The engine draws the chart only. OverlayLayer puts these badges above it.
//  Each badge captures clicks on its own area. The chart keeps all other clicks.
//  The file is platform-neutral.
//
//  The readout is a capsule at the bottom center, as in the WinUI 3 shell
//  (`HudPill` in windows/ui/MainWindow.xaml): band, scale, zoom and position,
//  with a hairline between them. The overscale badge shows when the view is
//  magnified past the survey.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Scale band, 1:N, zoom and lat/lon. The position is the cursor position, or
/// the view centre when there is no cursor. The scale is the only control.
struct ReadoutsCapsule: View {
    @ObservedObject var model: AppModel
    /// A narrow window (iPhone) uses a smaller type size and hides the band.
    /// The position, the scale and the zoom stay.
    let compact: Bool
    /// A click on the 1:N readout opens the scale entry.
    let onScaleTap: () -> Void

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            Circle()
                .fill(Chrome.amber)
                .frame(width: 10, height: 10)
            if !compact {
                Text(CoordFormat.band(model.scaleDenominator))
                    .fontWeight(.semibold)
                    .foregroundStyle(Chrome.ink)
                separator
            }
            Button(action: onScaleTap) {
                Text(CoordFormat.scale(model.scaleDenominator))
                    .fontWeight(.semibold)
                    .foregroundStyle(Chrome.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
            }
            .buttonStyle(ChromeFlatStyle(cornerRadius: 6))
            .help("Zoom to a scale…")
            .accessibilityLabel("Scale \(CoordFormat.scale(model.scaleDenominator)). Zoom to a scale.")
            .chromeHitRegion("scale-readout")
            separator
            Text(String(format: "z%.1f", model.zoomLevel))
                .foregroundStyle(Chrome.muted)
            separator
            Text(coordString)
                .foregroundStyle(Chrome.ink)
            if model.overscale > 1.05 {
                Text(String(format: "×%.1f", model.overscale))
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
            if !visibleRasterSets.isEmpty {
                separator
                // A plain Button, not a Menu: a macOS Menu renders its own
                // label chrome and drops the pill's fill and tint. The choice
                // list rides on the context menu instead.
                Button { showRasterMenu() } label: {
                    HStack(spacing: 5) {
                        Text(pillName.uppercased())
                        if rasterState != .on {
                            Text("|").foregroundStyle(rasterTint.opacity(0.5))
                            Text(rasterState == .off ? "OFF" : "ENC OFF")
                        }
                        // The chevron is a promise: a click opens a list. It is
                        // therefore always shown, because a click always does.
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .opacity(0.7)
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(rasterTint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(rasterTint.opacity(rasterState == .off ? 0.28 : 0.18),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(rasterHelp)
                .accessibilityLabel(rasterHelp)
                .chromeHitRegion("raster-pill")
            }
        }
        .font(.system(size: compact ? 12 : 14).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .frame(height: Chrome.capsule)
        .padding(.horizontal, compact ? 14 : 18)
        .background(Chrome.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Chrome.edge.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        // The capsule takes its own taps. Without this a tap on the readouts
        // fell through to the chart and picked whatever was under it.
        .chromeHitRegion("hud-capsule")
    }

    /// Pop the set list at the pointer.
    ///
    /// AppKit rather than a SwiftUI `Menu`: a Menu renders its own label chrome
    /// and drops the pill's fill and tint, and that colour IS the state — amber
    /// for off, blue for drawn, orange for the ENC hidden above it.
    private func showRasterMenu() {
        let menu = NSMenu()
        let target = RasterMenuTarget(model: model)
        menu.autoenablesItems = false
        for set in visibleRasterSets {
            let item = NSMenuItem(title: set.name, action: #selector(RasterMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = set.id
            item.state = (set.id == model.rasterActive) ? .on : .off
            menu.addItem(item)
        }
        let none = NSMenuItem(title: "None", action: #selector(RasterMenuTarget.pick(_:)), keyEquivalent: "")
        none.target = target
        none.tag = -1
        none.state = (model.rasterActive < 0) ? .on : .off
        menu.addItem(none)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: model.chartHidden ? "Show ENC Over Raster" : "Hide ENC Over Raster",
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

    private enum RasterState { case on, off, chartOff }

    /// The sets with enabled charts in view. The pill exists for these.
    private var visibleRasterSets: [ChartController.RasterSet] {
        model.rasterSets.filter(\.inView)
    }

    /// The set the pill NAMES: the drawn one when it is in view, otherwise the
    /// first one that is. Naming one set and reporting the state of another is
    /// how the pill came to read "NAVIONICS | OFF" while Navionics was drawn.
    private var pillSet: ChartController.RasterSet? {
        if let a = visibleRasterSets.first(where: { $0.id == model.rasterActive }) { return a }
        return visibleRasterSets.first
    }

    private var pillName: String { pillSet?.name ?? "" }

    /// Read from the set the pill names, so the two can never disagree.
    private var rasterState: RasterState {
        guard let s = pillSet, s.id == model.rasterActive else { return .off }
        return model.chartHidden ? .chartOff : .on
    }

    /// The colour reports THE RASTER CHART, not the ENC: blue while the chart is
    /// drawn, amber while one is here and off. Hiding the ENC above it does not
    /// change the colour, because the raster chart is still drawn — the "ENC
    /// OFF" text carries that, and a warning colour there would say the picture
    /// was off when it is the only thing on screen.
    private var rasterTint: Color {
        rasterState == .off ? Chrome.amber : Chrome.accent
    }

    private var rasterHelp: String {
        let n = pillName
        let more = visibleRasterSets.count > 1
            ? " \(visibleRasterSets.count) raster charts cover this view; right-click to choose." : ""
        switch rasterState {
        case .off: return "\(n) is here but off. Click to choose it." + more
        case .chartOff: return "\(n), with the ENC hidden above it. Click to choose another." + more
        case .on: return "\(n) below the ENC. Click to choose another." + more
        }
    }

    private var separator: some View {
        Rectangle().fill(Chrome.rule).frame(width: 1, height: 20)
    }

    private var coordString: String {
        let lat = model.cursorLat ?? model.centerLat
        let lon = model.cursorLon ?? model.centerLon
        return CoordFormat.position(lat: lat, lon: lon)
    }
}

/// Carries the pill menu's clicks back to the model. NSMenuItem needs an
/// ObjC target, which a SwiftUI view is not.
@MainActor
private final class RasterMenuTarget: NSObject {
    let model: AppModel
    init(model: AppModel) { self.model = model }
    @objc func pick(_ sender: NSMenuItem) { model.selectRasterSet(sender.tag) }
    @objc func toggleChart() { model.toggleChart() }
    @objc func add() { model.presentRasterPanel() }
}

/// The scale entry. Type a scale or select a band, and the view zooms to it.
struct ScaleEntryPanel: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    /// One usual scale for each S-52 navigational purpose band.
    private struct Preset: Identifiable {
        let band: String
        let denominator: Double
        let short: String
        var id: String { band }
    }
    private static let presets = [
        Preset(band: "Berthing", denominator: 2_000, short: "1:2k"),
        Preset(band: "Harbor", denominator: 12_000, short: "1:12k"),
        Preset(band: "Approach", denominator: 50_000, short: "1:50k"),
        Preset(band: "Coastal", denominator: 150_000, short: "1:150k"),
        Preset(band: "General", denominator: 700_000, short: "1:700k"),
    ]

    /// The typed scale, or nil while the text is not a scale.
    private var typed: Double? { ScaleParser.parse(model.scaleEntryText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Zoom to scale")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                Spacer(minLength: 8)
                Text("now \(CoordFormat.scale(model.scaleDenominator))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Chrome.muted)
                Button { model.showScaleEntry = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(5)
                }
                .buttonStyle(ChromeFlatStyle(cornerRadius: 6))
                .foregroundStyle(Chrome.muted)
                .accessibilityLabel("Close scale entry")
            }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Text("1:")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Chrome.muted)
                    TextField("25,000", text: $model.scaleEntryText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Chrome.ink)
                        .focused($focused)
                        .onSubmit { _ = model.submitScaleEntry() }
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        .submitLabel(.go)
                        #endif
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Chrome.ink.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(typed == nil ? Chrome.overscale.opacity(0.55)
                                               : Chrome.accent.opacity(0.55), lineWidth: 1))

                Button("Go") { _ = model.submitScaleEntry() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(typed == nil)
            }

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Chrome.muted)

            Divider().overlay(Chrome.rule)

            VStack(spacing: 6) {
                presetRow(Self.presets.prefix(3))
                presetRow(Self.presets.suffix(2))
            }
        }
        .padding(14)
        .frame(width: 340)
        .panelSurface(cornerRadius: 12)
        .onAppear { focused = true }
        #if os(macOS)
        .onExitCommand { model.showScaleEntry = false }
        #endif
    }

    /// The band the typed scale belongs to, or how to write a scale.
    private var hint: String {
        guard let typed else { return "Type a scale, for example 25,000 or 1:25k." }
        return "\(CoordFormat.band(typed)) band. The chart holds the nearest scale it has."
    }

    private func presetRow(_ presets: ArraySlice<Preset>) -> some View {
        HStack(spacing: 6) {
            ForEach(presets) { p in
                Button {
                    model.zoomToScale(p.denominator)
                    model.showScaleEntry = false
                } label: {
                    VStack(spacing: 2) {
                        Text(p.band).font(.system(size: 12, weight: .semibold))
                        Text(p.short).font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Chrome.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(ChromeFlatStyle(
                    resting: current == p.band ? Chrome.accent.opacity(0.14) : Chrome.ink.opacity(0.06),
                    cornerRadius: 10))
                .foregroundStyle(Chrome.ink)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(current == p.band ? Chrome.accent.opacity(0.5) : .clear, lineWidth: 1))
                .help("Zoom to \(p.short)")
            }
        }
    }

    /// The band of the current view. Its preset is marked.
    private var current: String { CoordFormat.band(model.scaleDenominator) }
}

/// A file a feature points at, read through the engine and shown here: the text
/// of a caution note, or the picture itself. The bake stores those files beside
/// the chart; a chart baked before that carries the name alone.
struct AuxFileView: View {
    @ObservedObject var model: AppModel
    let cell: String
    let name: String
    let isPicture: Bool

    @State private var loaded: (data: Data, mime: String)?
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isPicture ? "photo" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.accent)
                Text(name)
                    .font(.system(size: 14))
                    .foregroundStyle(Chrome.ink)
                    .textSelection(.enabled)
            }
            content
        }
        .onAppear(perform: load)
        .onChange(of: name) { tried = false; loaded = nil; load() }
    }

    @ViewBuilder private var content: some View {
        if let loaded {
            if let image = Self.image(from: loaded) {
                Button {
                    model.picture = .init(name: name, data: loaded.data)
                } label: {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        // A chart picture is a diagram or a note: 200pt made it
                        // unreadable. Click it for the full size.
                        .frame(maxWidth: .infinity, maxHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Chrome.edge.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Show \(name) at full size")
                .accessibilityLabel("Show \(name) at full size")
            } else if let text = String(data: loaded.data, encoding: .utf8)
                        ?? String(data: loaded.data, encoding: .isoLatin1) {
                // No scroll view here: the report itself scrolls. A note inside
                // its own little scroller fights the one around it, and a
                // caution is worth reading in full.
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Chrome.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Chrome.ink.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        } else if tried {
            Text("The chart does not carry this file.")
                .font(.system(size: 10))
                .foregroundStyle(Chrome.muted)
        }
    }

    private func load() {
        guard !tried else { return }
        tried = true
        loaded = model.controller?.auxFile(cell: cell, named: name)
    }

    /// A picture, whatever the format the cell shipped: the platform decodes
    /// TIFF, which is what an ENC usually carries.
    static func image(from file: (data: Data, mime: String)) -> Image? {
        guard file.mime.hasPrefix("image/") else { return nil }
        #if os(macOS)
        guard let ns = NSImage(data: file.data) else { return nil }
        return Image(nsImage: ns)
        #else
        guard let ui = UIImage(data: file.data) else { return nil }
        return Image(uiImage: ui)
        #endif
    }
}

/// A picture from a pick report, over the chart at full size. A click anywhere,
/// or Escape, puts it away.
struct PictureViewer: View {
    @ObservedObject var model: AppModel
    let picture: AppModel.Picture

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 10) {
                if let image = AuxFileView.image(from: (picture.data, "image/")) {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                }
                Text(picture.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(40)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.picture = nil }
        #if os(macOS)
        .onExitCommand { model.picture = nil }
        #endif
    }
}

/// Attribute payload helpers.
///
/// An S-57 cell gives a flat object of acronym and value. S-101 does not: a
/// complex attribute carries sub-attributes, so a value can be an object or an
/// array. The rows therefore carry a depth, and a complex attribute becomes a
/// heading with its parts indented under it.
enum S57 {
    struct Row: Identifiable {
        let name: String
        let value: String
        let depth: Int
        var id: String { "\(depth)/\(name)/\(value)" }

        /// A cell can point at a text file or a picture beside it, such as
        /// US348MDE.TXT. S-57 names it in TXTDSC, NTXTDS or PICREP; S-101 puts
        /// it in a fileReference. The bake does not carry those files, so the
        /// report states the reference and marks it as a file.
        var fileReference: Bool {
            ["TXTDSC", "NTXTDS", "PICREP", "fileReference"].contains(name)
                && !value.isEmpty
        }

        var isPicture: Bool {
            let lower = value.lowercased()
            return [".tif", ".tiff", ".jpg", ".jpeg", ".png"].contains { lower.hasSuffix($0) }
        }
    }

    static func attributes(of json: String) -> [Row] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        var rows: [Row] = []
        append(root, name: nil, depth: 0, into: &rows)
        return rows
    }

    /// Rows from an already-parsed payload — the envelope's raw half.
    static func rows(of any: Any?) -> [Row] {
        guard let any else { return [] }
        var rows: [Row] = []
        append(any, name: nil, depth: 0, into: &rows)
        return rows
    }

    private static func append(_ node: Any, name: String?, depth: Int, into rows: inout [Row]) {
        switch node {
        case let object as [String: Any]:
            if let name { rows.append(Row(name: name, value: "", depth: depth)) }
            for key in object.keys.sorted() {
                append(object[key] ?? "", name: key, depth: name == nil ? depth : depth + 1, into: &rows)
            }
        case let list as [Any]:
            if let name { rows.append(Row(name: name, value: "", depth: depth)) }
            for item in list {
                append(item, name: nil, depth: depth + 1, into: &rows)
            }
        default:
            rows.append(Row(name: name ?? "", value: text(of: node), depth: depth))
        }
    }

    private static func text(of node: Any) -> String {
        if let s = node as? String { return s }
        if let n = node as? NSNumber { return n.stringValue }
        return String(describing: node)
    }

    /// The attribute names that carry something to read.
    static let informational: Set<String> = [
        "INFORM", "NINFOM", "TXTDSC", "NTXTDS", "PICREP", "fileReference", "text",
    ]

    /// True when the payload holds a note or a reference. It is what keeps a
    /// meta object in the report: M_NPUB carries the chart's cautions, M_QUAL
    /// carries nothing a mariner reads.
    static func carriesInformation(_ json: String) -> Bool {
        attributes(of: json).contains { informational.contains($0.name) && !$0.value.isEmpty }
    }

    /// The report, as plain text for the clipboard: the raw payload, out of
    /// the envelope when there is one — a chart problem is reported with the
    /// cell's own words.
    static func plainText(_ feature: PickFeature) -> String {
        let root = (try? JSONSerialization.jsonObject(with: Data(feature.s57.utf8)))
            as? [String: Any]
        let raw = (root?["report"] != nil ? root?["s57"] : root) as Any?
        var text = "\(feature.cls)  \(feature.chart)\n"
        for row in rows(of: raw) {
            let indent = String(repeating: "  ", count: row.depth)
            text += row.value.isEmpty ? "\(indent)\(row.name):\n"
                                      : "\(indent)\(row.name): \(row.value)\n"
        }
        return text
    }
}

/// Readout formatting for both platforms. It agrees with `lkw::FormatCoord` and
/// `lkw::BandForDenom` (windows/src/lk_format.cpp), `lk_coord_format_dms`
/// (linux/src/lk-hud.c) and Hud.kt (Android). Each host prints the same string.
enum CoordFormat {
    /// Degrees, minutes and seconds with a hemisphere: `38°58'34.8"N`. The
    /// longitude has three degree digits, so a pair keeps its column width.
    static func dms(_ value: Double, isLat: Bool) -> String {
        let hemi = isLat ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W")
        let a = abs(value)
        var deg = Int(a)
        var mins = Int((a - Double(deg)) * 60)
        var secs = ((a - Double(deg)) * 60 - Double(mins)) * 60
        // Carry the rounding. 59.96" prints as 60.0", which is the next minute.
        if (secs * 10).rounded() >= 600 { secs = 0; mins += 1 }
        if mins >= 60 { mins = 0; deg += 1 }
        return String(format: isLat ? "%02d°%02d'%04.1f\"%@" : "%03d°%02d'%04.1f\"%@",
                      deg, mins, secs, hemi)
    }

    /// A full position: `38°58'34.8"N 076°28'55.2"W`.
    static func position(lat: Double, lon: Double) -> String {
        "\(dms(lat, isLat: true)) \(dms(lon, isLat: false))"
    }

    /// The full scale with group separators, as in the WinUI 3 shell: `1:13,267`.
    static func scale(_ denominator: Double) -> String {
        guard denominator > 0 else { return "1:—" }
        return "1:\(Int(denominator.rounded()).formatted(.number))"
    }

    /// The S-52 navigational purpose band for a display scale.
    static func band(_ denominator: Double) -> String {
        switch denominator {
        case ..<0.001:      return "—"
        case ..<5_000:      return "Berthing"
        case ..<25_000:     return "Harbor"
        case ..<75_000:     return "Approach"
        case ..<300_000:    return "Coastal"
        case ..<1_500_000:  return "General"
        default:            return "Overview"
        }
    }
}
