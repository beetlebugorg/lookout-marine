//  NoaaRegionList.swift: picking the waters to download.
//
//  Setup asks this on its coverage step, and Mariner settings asks it again
//  from Charts. One list, so the two places name the same regions and price
//  them the same way.
//
//  Region sizes are per selection rather than per region. The core includes
//  every cell covering a region's water, including the ones NOAA files under
//  the district next door, so per-region totals overlap and do not add up to
//  the total. One accurate total beats six numbers that do not sum.

import CoreGraphics
import SwiftUI

/// Where NOAA's catalog stands, and a way to read it again after a failure.
///
/// This polls while the read runs. The core reports progress and accepts no
/// callback across the C ABI, so a view showing that state has to ask for it.
/// The poll ends with the read, leaving an idle app with no timer.
struct NoaaCatalogLine: View {
    @Bindable var noaa: NoaaModel

    var body: some View {
        line.task(id: noaa.state.phase) {
            while noaa.state.phase == .readingCatalog {
                try? await Task.sleep(for: .milliseconds(300))
                noaa.poll()
            }
        }
    }

    @ViewBuilder private var line: some View {
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
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.muted)
                    .monospacedDigit()
            }
        }
    }

    private var summary: String {
        var s = "\(noaa.state.catalogCells) charts published"
        if !noaa.state.date.isEmpty { s += ", catalog dated \(noaa.state.date)" }
        return s + "."
    }
}


/// The map, and the regions as pills under it. The two drive one selection.
struct NoaaRegionList: View {
    var model: AppModel
    @Bindable var noaa: NoaaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Full width. The height follows from the picture's own shape, so
            // the map is never stretched.
            CoverageMap(regions: noaa.regions,
                        picked: noaa.picked,
                        enabled: noaa.state.haveCatalog,
                        coverage: noaa.coverage) { noaa.toggle($0) }
                .frame(maxWidth: .infinity)

            NoaaRegionPills(regions: noaa.regions,
                            picked: noaa.picked,
                            enabled: noaa.state.haveCatalog) { noaa.toggle($0) }
        }
    }
}


/// Picking regions from Mariner settings, after setup has run.
///
/// A sheet on a phone and a window on the Mac, where the map wants more room
/// than a form gives it. `close` is the window's, and nil in a sheet, which
/// dismisses itself.
struct NoaaPickerSheet: View {
    var model: AppModel
    @Bindable var noaa: NoaaModel
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private func shut() {
        if let close { close() } else { dismiss() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("NOAA publishes an ENC for every United States waterway at no cost. Pick the water you sail.")
                        .font(.system(size: 13))
                        .foregroundStyle(Chrome.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    NoaaCatalogLine(noaa: noaa)
                    NoaaRegionList(model: model, noaa: noaa)
                }
                .padding(18)
            }
            Divider()
            HStack(spacing: 12) {
                if noaa.state.haveCatalog, noaa.cells > 0 {
                    Text("\(noaa.cells) charts, \(NoaaModel.sizeText(noaa.bytes))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Chrome.muted)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                Button("Cancel") { shut() }
                Button("Download") {
                    model.startNoaaDownload()
                    shut()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!noaa.state.haveCatalog || noaa.picked.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear {
            noaa.poll()
            if !noaa.state.haveCatalog { noaa.refresh() }
        }
    }
}
