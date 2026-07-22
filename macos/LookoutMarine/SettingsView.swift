//  SettingsView.swift — the S-52 mariner settings, as a native macOS
//  preferences window (tabbed) that binds to the live chart.
//
//  Platform-neutral SwiftUI. MarinerSettings.bind() loads the engine's current
//  state and auto-applies edits (debounced); visibility changes show live and
//  emission changes rebuild lazily. On iOS the same tabs drop into a sheet.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var m = MarinerSettings()

    var body: some View {
        TabView {
            DisplayTab(m: m).tabItem { Label("Display", systemImage: "paintpalette") }
            DepthsTab(m: m).tabItem { Label("Depths", systemImage: "water.waves") }
            SymbolsTab(m: m).tabItem { Label("Text & Symbols", systemImage: "textformat") }
            AdvancedTab(m: m).tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 460, height: 430)
        .onAppear { m.bind(to: model.controller) }
    }
}

// MARK: - Tabs

private struct DisplayTab: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Form {
            Section {
                Picker("Color scheme", selection: $m.scheme) {
                    ForEach(MarinerScheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: { Text("Day, dusk and night palettes switch instantly.").captionFooter() }

            Section("Detail") {
                Picker("Display category", selection: $m.displayCategory) {
                    ForEach(MarinerDisplayCategory.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Soundings", selection: $m.soundings) {
                    ForEach(MarinerSoundings.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Four-shade water", isOn: $m.fourShadeWater)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DepthsTab: View {
    @ObservedObject var m: MarinerSettings
    private var unit: String { m.depthUnit == .feet ? "ft" : "m" }
    var body: some View {
        Form {
            Section {
                Picker("Depth unit", selection: $m.depthUnit) {
                    ForEach(MarinerDepthUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                DepthRow("Shallow contour", $m.shallowContour, unit)
                DepthRow("Safety contour", $m.safetyContour, unit)
                DepthRow("Deep contour", $m.deepContour, unit)
                DepthRow("Safety depth", $m.safetyDepth, unit)
            } header: {
                Text("Contours (\(unit))")
            } footer: {
                Text("The safety contour is the bold line separating safe from unsafe water.").captionFooter()
            }
        }
        .formStyle(.grouped)
    }
}

private struct SymbolsTab: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}

private struct AdvancedTab: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}

// MARK: - Rows

private struct DepthRow: View {
    let title: String
    @Binding var value: Double
    let unit: String
    init(_ title: String, _ value: Binding<Double>, _ unit: String) {
        self.title = title; self._value = value; self.unit = unit
    }
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .frame(width: 62)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Stepper("", value: $value, in: 0...200, step: 1).labelsHidden()
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
