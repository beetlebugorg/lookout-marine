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
        }
        .font(.system(size: compact ? 12 : 14).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .frame(height: Chrome.capsule)
        .padding(.horizontal, compact ? 14 : 18)
        .background(Chrome.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Chrome.edge.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        // The capsule does not disable hit testing. Only the scale button is a
        // control. A drag that starts on the other parts must reach the chart.
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
        // The panel is white in every appearance; see SearchField.
        .environment(\.colorScheme, .light)
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

/// One line per feature under the last tap: object class + source cell.
struct IdentifyPanel: View {
    let results: [PickFeature]
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Features")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                Spacer(minLength: 12)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(4)
                }
                .buttonStyle(ChromeFlatStyle(cornerRadius: 6))
                .foregroundStyle(Chrome.muted)
                .accessibilityLabel("Dismiss features")
            }
            ForEach(results) { f in
                HStack(spacing: 6) {
                    Text(f.cls)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Chrome.ink)
                        .accessibilityIdentifier("identify-cls")
                    Text(f.chart)
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .panelSurface()
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
