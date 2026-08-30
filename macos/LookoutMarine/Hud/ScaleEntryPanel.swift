//  ScaleEntryPanel.swift — go to a scale.
//
//  Type one, or pick the usual scale for a navigational purpose band. The 1:N
//  readout in the capsule and in the pick sheet's footer opens it.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif


/// The scale entry. Type a scale or select a band, and the view zooms to it.
struct ScaleEntryPanel: View {
    let model: AppModel
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
    private var typed: Double? { ScaleParser.parse(model.chrome.scaleEntryText) }

    var body: some View {
        // A binding cannot be made through AppModel, which owns its models
        // with a let, so the one this view writes is taken locally.
        @Bindable var chrome = model.chrome
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Zoom to scale")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                Spacer(minLength: 8)
                Text("now \(CoordFormat.scale(model.readouts.scaleDenominator))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Chrome.muted)
                Button { model.chrome.showScaleEntry = false } label: {
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
                    TextField("25,000", text: $chrome.scaleEntryText)
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
        .onExitCommand { model.chrome.showScaleEntry = false }
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
                    model.chrome.showScaleEntry = false
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
    private var current: String { CoordFormat.band(model.readouts.scaleDenominator) }
}
