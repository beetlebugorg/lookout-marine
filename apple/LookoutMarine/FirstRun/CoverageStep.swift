//  CoverageStep.swift: which waters to download.
//
//  A region is a Coast Guard district, the unit NOAA files a cell under. The
//  core turns a pick into the cells that cover that water, including the ones
//  NOAA files next door, so a region downloads without a gap along its border.
//  See src/noaa.zig.
//
//  Depth units are asked here rather than later in Mariner settings, because
//  every sounding and readout in the chart about to download is labeled in
//  them.

import SwiftUI

struct CoverageStep: View {
    var model: AppModel
    @Bindable var noaa: NoaaModel
    @ObservedObject var m: MarinerSettings

    private var feet: Bool { m.depthUnit == .feet }
    private var unit: String { feet ? "ft" : "m" }

    /// The engine holds depths in meters. Feet mode edits through a converted
    /// binding in whole feet, matching DepthsSection.
    private func depth(_ b: Binding<Double>) -> Binding<Double> {
        guard feet else { return b }
        return Binding(
            get: { (b.wrappedValue * 3.28084).rounded() },
            set: { b.wrappedValue = $0.rounded() / 3.28084 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "Which waters do you sail?",
                blurb: "Pick the water you use. Lookout downloads those charts and prepares them. You can add the rest later.",
                centered: centered)
                .padding(.top, topInset)

            catalogLine.padding(.top, 16)
            regions.padding(.top, 14)
            depths.padding(.top, 20)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 26)
        .onAppear {
            noaa.poll()
            if !noaa.state.haveCatalog { noaa.refresh() }
        }
    }

    /// Where the catalog stands. NOAA's list decides what a pick costs, so the
    /// page says whether it has one before it shows a total.
    @ViewBuilder private var catalogLine: some View {
        switch noaa.state.phase {
        case .readingCatalog:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading NOAA's chart catalog…")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Chrome.muted)
        default:
            if !noaa.state.error.isEmpty {
                HStack(spacing: 8) {
                    Label(noaa.state.error, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { noaa.refresh() }
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Chrome.overscale)
            } else if noaa.state.haveCatalog {
                Text("\(noaa.state.catalogCells) charts published, \(noaa.state.date.isEmpty ? "catalog read" : "catalog dated " + noaa.state.date).")
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.muted)
                    .monospacedDigit()
            }
        }
    }

    private var regions: some View {
        VStack(spacing: 8) {
            ForEach(noaa.regions) { r in
                RegionRow(region: r,
                          picked: noaa.picked.contains(r.id),
                          enabled: noaa.state.haveCatalog) {
                    noaa.toggle(r.id)
                }
            }
        }
    }

    /// The two depth settings a mariner sets before the first chart draws.
    private var depths: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepControlRow(label: "Depths in",
                           note: "Applies to every sounding, contour and readout.") {
                Picker("", selection: $m.depthUnit) {
                    ForEach(MarinerDepthUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            StepControlRow(label: "Safety depth (\(unit))",
                           note: "Bolds soundings at or shallower than it.") {
                DepthField(value: depth($m.safetyDepth), whole: feet)
            }
            StepControlRow(label: "Safety contour (\(unit))",
                           note: "The chart shades water shallower than this as unsafe.") {
                DepthField(value: depth($m.safetyContour), whole: feet)
            }
            Text("Mariner settings holds all three, and a change there applies at once.")
                .font(.system(size: 11.5))
                .foregroundStyle(Chrome.muted)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(Chrome.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Chrome.edge.opacity(0.5), lineWidth: 1))
    }

    #if os(macOS)
    private var centered: Bool { true }
    private var topInset: CGFloat { 34 }
    private var horizontalInset: CGFloat { 40 }
    #else
    private var centered: Bool { false }
    private var topInset: CGFloat { 16 }
    private var horizontalInset: CGFloat { 18 }
    #endif
}


/// One region: the mark, the name, and the waters it covers.
private struct RegionRow: View {
    let region: NoaaRegion
    let picked: Bool
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(picked ? Chrome.accent : Chrome.ink.opacity(0.30))
                VStack(alignment: .leading, spacing: 3) {
                    Text(region.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Chrome.ink)
                    Text(region.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 13)
            .modifier(CardSkin(picked: picked, radius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("region-\(region.id)")
    }
}


/// A depth in whole units. The engine holds meters; feet mode edits whole feet.
private struct DepthField: View {
    @Binding var value: Double
    let whole: Bool

    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(whole ? 0 : 1)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 78)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            .multilineTextAlignment(.trailing)
    }
}
