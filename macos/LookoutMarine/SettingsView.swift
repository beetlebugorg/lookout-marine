//  SettingsView.swift — the mariner settings window: a SIDEBAR of sections on
//  macOS (Display / Depths / Text / Charts / … / Advanced), the same sections
//  as tabs in the iOS sheet. One MarinerSettings model behind both: bind()
//  loads the engine state, edits auto-apply (debounced) and SAVE.
//
//  The sidebar is a slot list, not a fixed menu. The four core sections and
//  Advanced always exist; Vessels, Alarms and Connections appear only while
//  something puts settings in them, and today that something is a plugin. The
//  mariner is never told which: AIS settings are chart settings.
//
//  The Depths section explains the S-52 shading model instead of assuming it:
//  the single most-reported "bug" was a safety-contour change not turning
//  water white — which is FOUR-shade semantics (white starts at the DEEP
//  contour) plus chart-ladder snapping, not a bug. The band preview makes the
//  model visible where the knobs are.

import SwiftUI

/// One entry in the sidebar. `core` sections are the app's own and are always
/// listed; the rest are listed only while they hold something. The ids are the
/// core's section names (src/plugin/host.zig, `Tab`), so a plugin and the shell
/// mean the same thing by "alarms".
struct SettingsSection: Identifiable {
    let id: String
    let label: String
    let icon: String
    let core: Bool

    /// Every section, in the order the sidebar shows them. Advanced is last:
    /// it is where anything unclaimed lands.
    static let all: [SettingsSection] = [
        .init(id: "display", label: "Display", icon: "paintpalette", core: true),
        .init(id: "depths", label: "Depths", icon: "water.waves", core: true),
        .init(id: "text", label: "Text", icon: "textformat", core: true),
        .init(id: "charts", label: "Charts", icon: "map", core: true),
        .init(id: "vessels", label: "Vessels", icon: "ferry", core: false),
        .init(id: "alarms", label: "Alarms", icon: "bell", core: false),
        .init(id: "connections", label: "Connections", icon: "antenna.radiowaves.left.and.right", core: false),
        .init(id: "advanced", label: "Advanced", icon: "slider.horizontal.3", core: true),
    ]
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var m = MarinerSettings()
    @StateObject private var p = PluginSettings()

    var body: some View {
        content
            .onAppear {
                m.bind(to: model.controller)
                p.bind(to: model.controller)
                // A connection's line moves on its own while the window is up.
                p.startPolling()
            }
            .onDisappear { p.stopPolling() }
    }

    private var sections: [SettingsSection] {
        let filled = p.populatedTabs
        return SettingsSection.all.filter { $0.core || filled.contains($0.id) }
    }

    /// The section on screen. A section can go away — a plugin that never came
    /// up takes its section with it — so a stale selection falls back.
    private var selected: String {
        sections.contains { $0.id == model.settingsTab } ? model.settingsTab : "display"
    }

    @ViewBuilder private var content: some View {
        #if os(macOS)
        NavigationSplitView {
            List(sections, selection: $model.settingsTab) { s in
                Label(s.label, systemImage: s.icon)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 178, max: 220)
            // No collapse control: the list IS the navigation, and a window
            // with it hidden has no way back to another section.
            .toolbar(removing: .sidebarToggle)
            // The one thing the whole window promises. It stands under the
            // list rather than repeating in every section.
            .safeAreaInset(edge: .bottom) {
                Text("Applies at once · kept for next launch")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            pane(selected)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 560)
        #else
        // The presenting sheet supplies the Done button.
        TabView(selection: $model.settingsTab) {
            ForEach(sections) { s in
                pane(s.id)
                    .tabItem { Label(s.label, systemImage: s.icon) }
                    .tag(s.id)
            }
        }
        #endif
    }

    /// One section's form: the app's own settings for it, then whatever a
    /// plugin contributed to the same section.
    @ViewBuilder private func pane(_ id: String) -> some View {
        Form {
            switch id {
            case "display": DisplaySections(m: m)
            case "depths": DepthsSections(m: m)
            case "text": SymbolsSections(m: m)
            case "charts": ChartsSections(model: model)
            case "advanced": AdvancedSections(m: m)
            default: EmptyView()
            }
            PluginSections(p: p, tab: id)
            PluginListSections(p: p, tab: id)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Charts

/// Chart selection: the open library, recents, and the picker. iOS imports via
/// the file importer (sheet-swapped by addChartsFromSettings); macOS uses the
/// shared NSOpenPanel.
private struct ChartsSections: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            if let p = model.chartPath {
                Label {
                    Text(displayName(p)).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: "map.fill").foregroundStyle(.tint)
                }
            } else {
                Text("No chart open").foregroundStyle(.secondary)
            }
        } header: { Text("Open") }

        if !model.recents.isEmpty {
            Section {
                ForEach(model.recents, id: \.self) { p in
                    Button {
                        model.openChart(p)
                    } label: {
                        HStack {
                            Image(systemName: p == model.chartPath ? "checkmark.circle.fill" : "clock")
                                .foregroundStyle(p == model.chartPath ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            Text(displayName(p)).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            } header: { Text("Recent") }
        }

        Section {
            Button {
                model.addChartsFromSettings()
            } label: {
                Label("Add Charts…", systemImage: "plus")
            }
        } footer: {
            Text("A folder of baked cells opens as one seamless library.").captionFooter()
        }

        // A raster chart is a different KIND of chart, so it gets its own section
        // rather than a mixed list: one is the survey, the other is a picture of
        // the water, and a mariner must never lose track of which is which.
        Section {
            if model.rasterPaths.isEmpty {
                Text("No raster charts").foregroundStyle(.secondary)
            } else {
                // Grouped by provider, because a set is what the pill cycles and
                // what covers a piece of water. A mariner turns off Navionics,
                // not four files that happen to be Navionics.
                ForEach(model.rasterGroups, id: \.name) { group in
                    let on = model.rasterGroupOn(group.paths)
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { on },
                            set: { model.setRasterGroupEnabled(group.paths, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        Text(group.name)
                            .fontWeight(.medium)
                            .foregroundStyle(on ? .primary : .secondary)
                        Spacer()
                        Text(group.paths.count == 1 ? "1 file" : "\(group.paths.count) files")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(group.paths, id: \.self) { p in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { !model.rasterOff.contains(p) },
                                set: { model.setRasterEnabled(p, $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            Text(displayName(p))
                                .font(.caption)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(model.rasterOff.contains(p) ? .secondary : .primary)
                            Spacer()
                            Button {
                                model.removeRasterChart(p)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove. Takes effect the next time a chart opens.")
                        }
                        .padding(.leading, 22)
                    }
                }
            }
            Button {
                #if os(macOS)
                model.presentRasterPanel()
                #else
                model.showRasterImporter = true
                #endif
            } label: {
                Label("Add Raster Charts…", systemImage: "plus")
            }
        } header: {
            Text("Raster charts")
        } footer: {
            Text("Charts made of pictures: MBTiles of satellite imagery or another "
                 + "vendor's charts, and BSB/KAP raster nautical charts. The ENC "
                 + "draws over them and drops its depth and land shading only where "
                 + "they cover. Switch one off to keep it installed without drawing it.")
                .captionFooter()
        }
    }

    private func displayName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

// MARK: - Display

private struct DisplaySections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section {
            SchemeSwatches(scheme: $m.scheme)
        } header: {
            SectionHead("Colour scheme", hint: "⌘L steps")
        } footer: {
            Text("The palettes switch instantly. Night keeps your eyes dark-adapted.").captionFooter()
        }

        Section {
            ForEach(MarinerDisplayCategory.allCases) { c in
                ChoiceRow(title: c.label, desc: c.desc, selected: m.displayCategory == c) {
                    m.displayCategory = c
                }
            }
        } header: {
            SectionHead("Display category", hint: "⌘D adds Other")
        } footer: {
            Text("Each category contains the one before it.").captionFooter()
        }

        Section {
            ForEach(MarinerSoundings.allCases) { s in
                ChoiceRow(title: s.label, desc: s.desc, selected: m.soundings == s) {
                    m.soundings = s
                }
            }
        } header: {
            SectionHead("Soundings", hint: "⌘⇧S steps")
        }
    }
}

// MARK: - Depths

private struct DepthsSections: View {
    @ObservedObject var m: MarinerSettings
    private var feet: Bool { m.depthUnit == .feet }
    private var unit: String { feet ? "ft" : "m" }

    /// The ENGINE always takes metres (S-57 depths are metres; the unit only
    /// changes sounding and contour labels). Feet mode edits through this
    /// converted binding, in WHOLE feet — a depth read to fractions of a foot
    /// is noise, and the previous form sent "ft" values as metres.
    private func depth(_ b: Binding<Double>) -> Binding<Double> {
        guard feet else { return b }
        return Binding(
            get: { (b.wrappedValue * 3.28084).rounded() },
            set: { b.wrappedValue = $0.rounded() / 3.28084 }
        )
    }

    var body: some View {
        Section {
            Picker("Depth unit", selection: $m.depthUnit) {
                ForEach(MarinerDepthUnit.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Water shading", selection: $m.fourShadeWater) {
                Text("Two shades").tag(false)
                Text("Four shades").tag(true)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(m.fourShadeWater
                 ? "Four shades: white (safe) water starts at the DEEP contour; the safety contour separates the two middle blues."
                 : "Two shades: water deeper than the safety contour is white (safe), everything shallower is blue.")
                .captionFooter()
        }

        Section {
            BandPreview(m: m)
                .listRowInsets(EdgeInsets())
        } footer: {
            Text("Shading follows the depth areas in the chart: the effective safety contour is the next DEEPER contour available in the data, drawn bold.").captionFooter()
        }

        Section {
            if m.fourShadeWater {
                DepthRow("Shallow contour", depth($m.shallowContour), unit, whole: feet)
            }
            DepthRow("Safety contour", depth($m.safetyContour), unit, whole: feet)
            if m.fourShadeWater {
                DepthRow("Deep contour", depth($m.deepContour), unit, whole: feet)
            }
            DepthRow("Safety depth", depth($m.safetyDepth), unit, whole: feet)
        } header: {
            Text("Contours (\(unit))")
        } footer: {
            Text("Safety depth bolds soundings at or shallower than it; it does not shade water.").captionFooter()
        }
    }
}

/// Schematic of the S-52 depth bands for the CURRENT settings: which shades
/// exist, and which contour separates each pair. Colours approximate the day
/// palette — this is a legend, not the palette itself.
private struct BandPreview: View {
    @ObservedObject var m: MarinerSettings
    private var feet: Bool { m.depthUnit == .feet }

    private func label(_ metres: Double) -> String {
        feet ? "\(Int((metres * 3.28084).rounded())) ft" : String(format: "%g m", metres)
    }

    var body: some View {
        let bands: [(Color, String)] = m.fourShadeWater
            ? [
                (Color(red: 0.55, green: 0.80, blue: 0.60), "drying"),
                (Color(red: 0.45, green: 0.75, blue: 0.93), "0–\(label(min(m.shallowContour, m.safetyContour)))"),
                (Color(red: 0.55, green: 0.82, blue: 0.97), "–\(label(m.safetyContour))"),
                (Color(red: 0.75, green: 0.90, blue: 0.99), "–\(label(max(m.deepContour, m.safetyContour)))"),
                (Color.white, "deeper"),
            ]
            : [
                (Color(red: 0.55, green: 0.80, blue: 0.60), "drying"),
                (Color(red: 0.45, green: 0.75, blue: 0.93), "0–\(label(m.safetyContour))"),
                (Color.white, "deeper"),
            ]
        HStack(spacing: 0) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                band.0
                    .overlay(alignment: .bottom) {
                        Text(band.1)
                            .font(.system(size: 9))
                            .foregroundStyle(.black.opacity(0.75))
                            .padding(.bottom, 2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
            }
        }
        .frame(height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .padding(10)
    }
}

// MARK: - Text & Symbols

private struct SymbolsSections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section("Text") {
            Toggle("Feature names", isOn: $m.textNames)
            Toggle("Light descriptions", isOn: $m.showLightDescriptions)
            Toggle("Other text", isOn: $m.textOther)
        }
        Section("Symbols") {
            Toggle("Simplified point symbols", isOn: $m.simplifiedPoints)
            Picker("Boundaries", selection: $m.boundaryStyle) {
                ForEach(MarinerBoundaryStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Full light-sector lines", isOn: $m.showFullSectorLines)
        }
    }
}

// MARK: - Advanced

private struct AdvancedSections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section("Safety & Quality") {
            Toggle("Data quality overlay", isOn: $m.dataQuality)
            Toggle("Isolated dangers in shallow water", isOn: $m.showIsolatedDangersShallow)
            Toggle("Information callouts", isOn: $m.showInformCallouts)
            Toggle("Meta boundaries", isOn: $m.showMetaBounds)
            Toggle("Overscale indication", isOn: $m.showOverscale)
        }
        Section("Sizing") {
            SizeRow("Overall size", $m.sizeScale)
            SizeRow("Text size", $m.textSizeScale)
            SizeRow("Sounding size", $m.soundingSizeScale)
        }
        Section {
            Toggle("Date-dependent features", isOn: $m.dateDependent)
            Toggle("Highlight date-dependent", isOn: $m.highlightDateDependent)
            LabeledContent("View date") {
                TextField("YYYYMMDD", text: $m.dateView)
                    .frame(width: 110)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Dates")
        } footer: { Text("Leave the date empty to use today.").captionFooter() }
    }
}

// MARK: - Rows

private struct DepthRow: View {
    let title: String
    @Binding var value: Double
    let unit: String
    let whole: Bool
    init(_ title: String, _ value: Binding<Double>, _ unit: String, whole: Bool) {
        self.title = title; self._value = value; self.unit = unit; self.whole = whole
    }
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value,
                          format: .number.precision(.fractionLength(whole ? 0...0 : 0...1)))
                    .labelsHidden()
                    .frame(width: 62)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(whole ? .numberPad : .decimalPad)
                    #endif
                Stepper("", value: $value, in: 0...660, step: 1).labelsHidden()
                Text(unit).foregroundStyle(.secondary).frame(width: 20, alignment: .leading)
            }
        }
    }
}

private struct SizeRow: View {
    let title: String
    @Binding var value: Double
    init(_ title: String, _ value: Binding<Double>) { self.title = title; self._value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f×", value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: 0.5...2.0)
        }
    }
}

private extension Text {
    func captionFooter() -> some View { self.font(.caption).foregroundStyle(.secondary) }
}
