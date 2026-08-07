//  SettingsRows.swift — the row grammar the settings window is built from, and
//  the drawn colour-scheme swatches.
//
//  Every row says what the setting DOES for the person at the helm, under the
//  control, and names the keystroke that reaches the same thing from the chart.
//  The structure is ours; the colours, fonts and control shapes are the
//  platform's, so the window is a Mac window at night as well as by day.
//
//  Plugin-contributed rows use the same grammar as the app's own. A mariner
//  never learns which settings came from a plugin.

import SwiftUI

// MARK: - Headings and rows

/// A section heading, with the keystroke that does the same job on the chart.
struct SectionHead: View {
    let title: String
    var hint: String?

    init(_ title: String, hint: String? = nil) {
        self.title = title
        self.hint = hint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            if let hint {
                Spacer()
                Text(hint).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// One choice out of several, with the sentence that explains it. A stack of
/// these instead of a segmented control: the explanation needs the width, and
/// a mariner choosing how much chart to draw should read what each choice adds.
struct ChoiceRow: View {
    let title: String
    let desc: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(selected ? .semibold : .regular)
                    if !desc.isEmpty {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A control with its label and explanation on the left. The explanation is
/// part of the row, not a section footer: it belongs to this one setting.
struct DescribedRow<Content: View>: View {
    let title: String
    let desc: String
    @ViewBuilder let content: Content

    var body: some View {
        LabeledContent {
            content
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !desc.isEmpty {
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Plugin contributions

/// The groups a plugin put in this section of the window. Each group is one
/// Section with its own heading and its own reset — the mariner sees settings
/// about the chart, never a list of plugins. A section nothing contributes to
/// renders nothing at all.
struct PluginSections: View {
    @ObservedObject var p: PluginSettings
    let tab: String

    var body: some View {
        ForEach(p.groups(tab: tab)) { g in
            Section {
                ForEach(g.fields) { f in
                    switch f.kind {
                    case .toggle:
                        // Two Texts is the platform's title-and-subtitle
                        // toggle. One Text when the schema gave no sentence.
                        if f.desc.isEmpty {
                            Toggle(f.label, isOn: p.toggle(g.pluginID, f.key))
                        } else {
                            Toggle(isOn: p.toggle(g.pluginID, f.key)) {
                                Text(f.label)
                                Text(f.desc)
                            }
                        }
                    case .number:
                        PluginNumberRow(field: f, value: p.number(g.pluginID, f.key))
                    }
                }
                if p.isChanged(g) {
                    Button("Reset to defaults") { p.resetToDefaults(g) }
                }
            } header: {
                SectionHead(g.title)
            }
        }
    }
}

/// A number a plugin asked for: typed or stepped, inside the range the schema
/// declares, with its unit beside it and the range under it. Same shape as the
/// depth rows, because a mariner should not have to learn a second kind of
/// number field.
struct PluginNumberRow: View {
    let field: PluginField
    @Binding var value: Double

    var body: some View {
        DescribedRow(title: field.label, desc: field.desc) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .frame(width: 68)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Stepper("", value: $value, in: field.min...field.max, step: field.step)
                        .labelsHidden()
                    Text(field.unit).foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .leading)
                }
                Text(field.rangeText).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Colour scheme

/// The three schemes DRAWN, not named: each swatch is a piece of chart in that
/// scheme's own colours, so the choice is made by eye. Day is unreadable at
/// night and night is unreadable by day — the swatches say so without words.
struct SchemeSwatches: View {
    @Binding var scheme: MarinerScheme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(MarinerScheme.allCases) { s in
                Button {
                    scheme = s
                } label: {
                    VStack(spacing: 6) {
                        SchemeSwatch(palette: .of(s))
                            .frame(height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(s == scheme ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                                  lineWidth: s == scheme ? 3 : 1)
                            }
                        Text(s.label)
                            .font(.subheadline)
                            .fontWeight(s == scheme ? .semibold : .regular)
                            .foregroundStyle(s == scheme ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(s == scheme ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A shore in one scheme: the four depth shades out to deep water, then land
/// behind a curved coastline. A piece of chart, not a colour chip.
private struct SchemeSwatch: View {
    let palette: SchemePalette

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                VStack(spacing: 0) {
                    palette.deep.frame(height: h * 0.36)
                    palette.medium.frame(height: h * 0.18)
                    palette.shallow.frame(height: h * 0.16)
                    palette.veryShallow
                }
                shore(w, h).fill(palette.land)
                shore(w, h).stroke(palette.coastline, lineWidth: 1.5)
            }
        }
    }

    /// The shoreline: a bay open to the top-left, land filling the corner.
    private func shore(_ w: CGFloat, _ h: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: h * 0.80))
        p.addCurve(to: CGPoint(x: w, y: h * 0.52),
                   control1: CGPoint(x: w * 0.35, y: h * 0.74),
                   control2: CGPoint(x: w * 0.60, y: h * 0.44))
        p.addLine(to: CGPoint(x: w, y: h))
        p.closeSubpath()
        return p
    }
}

/// The chart colours of one scheme. These are the presentation library's own
/// sRGB values (S-101 colour profile, tokens DEPDW/DEPMD/DEPMS/DEPVS/LANDA/
/// CSTLN), copied so a swatch can be drawn without opening a chart. They are a
/// legend of the palette, not the palette itself: the engine draws from the
/// tables in the chart.
struct SchemePalette {
    let deep: Color, medium: Color, shallow: Color, veryShallow: Color
    let land: Color, coastline: Color

    static func of(_ s: MarinerScheme) -> SchemePalette {
        switch s {
        case .day:
            return .init(deep: hex(0xc9edff), medium: hex(0xa7d9fb), shallow: hex(0x82caff),
                         veryShallow: hex(0x61b7ff), land: hex(0xbfbe8f), coastline: hex(0x4c5b63))
        case .dusk:
            return .init(deep: hex(0x000000), medium: hex(0x0f1b21), shallow: hex(0x1d3246),
                         veryShallow: hex(0x1e4165), land: hex(0x40402e), coastline: hex(0x6b7f89))
        case .night:
            return .init(deep: hex(0x000000), medium: hex(0x03070a), shallow: hex(0x050e16),
                         veryShallow: hex(0x071727), land: hex(0x17160e), coastline: hex(0x252d31))
        }
    }

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xff) / 255,
              green: Double((v >> 8) & 0xff) / 255,
              blue: Double(v & 0xff) / 255)
    }
}
