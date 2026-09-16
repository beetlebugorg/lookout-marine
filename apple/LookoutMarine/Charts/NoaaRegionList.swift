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


/// The map, and the regions under it. The two drive one selection.
struct NoaaRegionList: View {
    var model: AppModel
    @Bindable var noaa: NoaaModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var width
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Full width. The height follows from the picture's own shape, so
            // the map is never stretched.
            CoverageMap(regions: noaa.regions,
                        picked: noaa.picked,
                        enabled: noaa.state.haveCatalog,
                        coverage: noaa.coverage) { noaa.toggle($0) }
                .frame(maxWidth: .infinity)

            picker
        }
    }

    /// Pills where there is room to lay them out in a line or two, rows where
    /// there is not. A phone is the narrow case.
    @ViewBuilder private var picker: some View {
        #if os(iOS)
        if width == .compact {
            NoaaRegionRows(regions: noaa.regions,
                           picked: noaa.picked,
                           enabled: noaa.state.haveCatalog) { noaa.toggle($0) }
        } else {
            pills
        }
        #else
        pills
        #endif
    }

    private var pills: some View {
        NoaaRegionPills(regions: noaa.regions,
                        picked: noaa.picked,
                        enabled: noaa.state.haveCatalog,
                        state: noaa.regionState) { noaa.toggle($0) }
    }
}


/// Picking regions from Mariner settings, after setup has run.
///
/// A sheet on a phone and a window on the Mac, where the map wants more room
/// than a form gives it. `close` is the window's, and nil in a sheet, which
/// dismisses itself.
///
/// The ticks state WHAT WATER THE MARINER HOLDS. Water already downloaded
/// opens ticked, unticking it removes those charts, and Apply does both halves
/// at once. Opening with everything unticked said they held nothing, and there
/// was no way to give water back except by removing the whole set.
struct NoaaPickerSheet: View {
    var model: AppModel
    @Bindable var noaa: NoaaModel
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    /// The regions that were fully installed when this opened. Unticking one
    /// of these is a removal; unticking a region that was never here is a
    /// mariner changing their mind before pressing Apply.
    @State private var held: Set<String> = []
    @State private var confirmRemoval = false
    /// True once the ticks have been set from what is installed. A mariner who
    /// holds nothing seeds an empty set, which is not the same as not having
    /// seeded yet: without this their picks are cleared again on the next
    /// change.
    @State private var seeded = false

    private func shut() {
        // The confirmation is a sheet on this window, and a window holding one
        // ignores performClose. The hop puts the close after the sheet has
        // gone, so Apply closes the window instead of leaving it up with the
        // button still live.
        if let close { DispatchQueue.main.async { close() } } else { dismiss() }
    }

    /// The regions being given back.
    private var removing: [NoaaRegion] { noaa.removedRegions(from: held) }
    private var adding: Bool { noaa.cells > 0 }

    /// What Apply is about to do, in the mariner's words.
    private var planLine: String {
        var parts: [String] = []
        if adding { parts.append("Add \(noaa.cells) charts, \(NoaaModel.sizeText(noaa.bytes))") }
        let gone = removing
        if !gone.isEmpty {
            parts.append("remove \(gone.map(\.name).joined(separator: ", "))")
        }
        return parts.isEmpty ? noaa.costLine : parts.joined(separator: " · ")
    }

    /// Do both halves. The removal runs first, so a mariner swapping one region
    /// for another does not hold both on the disk at once.
    private func apply() {
        let gone = removing
        if !gone.isEmpty {
            model.charts.removeNoaaWater(named: noaa.cellsToRemove(unpicking: gone))
            noaa.dropRecorded(gone.map(\.id))
        }
        if adding { model.startNoaaDownload() }
        shut()
    }

    /// Tick what is already here, and remember it, so unticking reads as a
    /// removal.
    private func startFromInstalled() {
        noaa.pickInstalled()
        held = noaa.picked
        seeded = true
    }

    private var removalTitle: String {
        let gone = removing
        if gone.count == 1 { return "Remove \(gone[0].name) charts?" }
        return "Remove charts for \(gone.count) regions?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("NOAA publishes an ENC for every United States waterway at no cost. Tick the water you sail. Unticking water you hold removes those charts.")
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
                if noaa.state.haveCatalog, noaa.cells > 0 || noaa.held > 0 || !removing.isEmpty {
                    Text(planLine)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Chrome.muted)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                Button("Cancel") { shut() }
                // Water that is all here has nothing to add and nothing to
                // remove, and a mariner repairing a damaged download or
                // forcing the current editions still needs a way to fetch it.
                if noaa.allInstalled, removing.isEmpty {
                    Button("Download Again") {
                        model.startNoaaDownload(again: true)
                        shut()
                    }
                    .accessibilityIdentifier("noaa-download-again")
                }
                Button("Apply") {
                    // Removing charts needs one question. Adding them does
                    // not: it costs time and disk, and the line above says how
                    // much of both.
                    if removing.isEmpty { apply() } else { confirmRemoval = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!noaa.state.haveCatalog || (!adding && removing.isEmpty))
                .accessibilityIdentifier("noaa-apply")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        #if os(macOS)
        // The window this opens in has no size of its own to start from.
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .confirmationDialog(removalTitle, isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Lookout deletes the charts it downloaded for this water. Charts you added yourself stay where they are, and you can download this water again.")
        }
        .onAppear {
            noaa.poll()
            noaa.noteInstalled(model.charts.installedCellNames)
            noaa.noteManaged(model.charts.managedCellNames)
            if !noaa.state.haveCatalog { noaa.refresh() } else { startFromInstalled() }
        }
        // The catalog is what prices a region, so what is held cannot be known
        // until it lands. On a first open it arrives after this view.
        .onChange(of: noaa.regionState) { _, _ in
            if !seeded { startFromInstalled() }
        }
    }
}
