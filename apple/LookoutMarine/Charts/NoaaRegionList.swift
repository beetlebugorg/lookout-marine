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

    /// The app's own basemap: the lower 48, with Alaska and Hawaii inset.
    @State private var basemaps = CoverageBasemaps()

    /// Photograph the three views the picker draws, then put the chart back
    /// where the mariner had it.
    ///
    /// Each picture holds the corners it was taken under, so the boxes stay
    /// true whatever the chart does afterward.
    private func photograph() async {
        guard let saved = model.controller?.currentView else { return }
        basemaps.main = await shoot(AppModel.countryView)
        basemaps.alaska = await shoot(AppModel.alaskaView)
        basemaps.hawaii = await shoot(AppModel.hawaiiView)
        // Setup asks which waters a mariner sails, so the chart under the
        // sheet goes back to the lower 48 rather than to a harbor they have no
        // chart for.
        model.controller?.setView(basemaps.main == nil ? saved : AppModel.countryView)
    }

    /// Ask for a view until the chart holds it, then take the picture.
    /// Opening a chart applies its own default view, which can land after the
    /// first ask.
    private func shoot(_ view: lookout_view) async -> ChartSnapshot? {
        for _ in 0..<40 {
            guard let c = model.controller else {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            c.setView(view)
            try? await Task.sleep(for: .milliseconds(300))
            guard c.isShowing(view) else { continue }
            // The framing has landed. The tiles for it have not: a picture
            // taken now is the empty frame before the basemap draws.
            try? await Task.sleep(for: .milliseconds(900))
            guard let shot = c.currentSnapshot() else { continue }
            return shot
        }
        lkLog("coverage map: the chart never held a framing")
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Full width. The height follows from the picture's own shape, so
            // the map is never stretched.
            CoverageMap(regions: noaa.regions,
                        picked: noaa.picked,
                        enabled: noaa.state.haveCatalog,
                        basemaps: basemaps) { noaa.toggle($0) }
                .frame(maxWidth: .infinity)
                .task { await photograph() }

            NoaaRegionPills(regions: noaa.regions,
                            picked: noaa.picked,
                            enabled: noaa.state.haveCatalog) { noaa.toggle($0) }
        }
    }
}


/// Picking regions from Mariner settings, after setup has run.
struct NoaaPickerSheet: View {
    var model: AppModel
    @Bindable var noaa: NoaaModel
    @Environment(\.dismiss) private var dismiss

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
                Button("Cancel") { dismiss() }
                Button("Download") {
                    model.startNoaaDownload()
                    dismiss()
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
