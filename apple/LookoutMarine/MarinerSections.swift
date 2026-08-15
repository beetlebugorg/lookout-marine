//
//  The mariner's own display settings, as sections a settings form composes.
//
//  Every section here binds to MarinerSettings and to the row vocabulary in
//  SettingsRows.swift, and reaches nothing else. That is what lets the Mac,
//  iOS and visionOS apps show the same S-52 controls: each one supplies its
//  own settings shell and fills it with these.
//

import SwiftUI

// MARK: - Display

struct DisplaySections: View {
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

struct DepthsSections: View {
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
            SegmentedRow("Depth unit", selection: $m.depthUnit) {
                ForEach(MarinerDepthUnit.allCases) { Text($0.label).tag($0) }
            }
            SegmentedRow("Water shading", selection: $m.fourShadeWater) {
                Text("Two shades").tag(false)
                Text("Four shades").tag(true)
            }
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

struct SymbolsSections: View {
    @ObservedObject var m: MarinerSettings
    var body: some View {
        Section("Text") {
            Toggle("Feature names", isOn: $m.textNames)
            Toggle("Light descriptions", isOn: $m.showLightDescriptions)
            Toggle("Other text", isOn: $m.textOther)
        }
        Section("Symbols") {
            Toggle("Simplified point symbols", isOn: $m.simplifiedPoints)
            SegmentedRow("Boundaries", selection: $m.boundaryStyle) {
                ForEach(MarinerBoundaryStyle.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Full light-sector lines", isOn: $m.showFullSectorLines)
        }
    }
}

// MARK: - Advanced

struct AdvancedSections: View {
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
                    // Borderless, a contour depth reads as a printed value
                    // rather than something to change. The row editors wear
                    // the border already; these match them.
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(whole ? .numberPad : .decimalPad)
                    .keyboardDone()
                    #endif
                Stepper("", value: $value, in: 0...660, step: 1).labelsHidden()
                Text(unit).foregroundStyle(.secondary)
                    .fixedSize()
                    .frame(minWidth: 20, alignment: .leading)
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

extension Text {
    func captionFooter() -> some View { self.font(.caption).foregroundStyle(.secondary) }
}
