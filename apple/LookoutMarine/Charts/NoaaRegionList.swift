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
struct NoaaCatalogLine: View {
    @Bindable var noaa: NoaaModel

    var body: some View { line }

    @ViewBuilder private var line: some View {
        switch noaa.state.catalogLine {
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading NOAA's chart catalog…")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Chrome.muted)
        case .summary(let text):
            summaryText(text)
        case .summaryThenError(let text, let err):
            VStack(alignment: .leading, spacing: 3) {
                summaryText(text)
                errorLine(err, size: 11.5)
            }
        case .error(let err):
            errorLine(err, size: 12.5)
        case .blank:
            EmptyView()
        }
    }

    private func summaryText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Chrome.muted)
            .monospacedDigit()
    }

    private func errorLine(_ err: String, size: CGFloat) -> some View {
        HStack(spacing: 8) {
            Label(err, systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { noaa.refresh() }
        }
        .font(.system(size: size))
        .foregroundStyle(Chrome.overscale)
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

    /// The regions being given back: held when this opened, unticked since.
    private var removing: [NoaaRegion] {
        noaa.regions.filter { held.contains($0.id) && !noaa.picked.contains($0.id) }
    }
    private var adding: Bool { noaa.cells > 0 }

    /// What Apply is about to do, in the mariner's words.
    private var planLine: String {
        var parts: [String] = []
        if adding { parts.append("Add \(TextFormat.count(noaa.cells)) charts, \(TextFormat.bytes(noaa.bytes))") }
        let gone = removing
        if !gone.isEmpty {
            parts.append("remove \(gone.map(\.name).joined(separator: ", "))")
        }
        return parts.isEmpty ? noaa.costLine : parts.joined(separator: " · ")
    }

    /// Do both halves in one core call. The removal runs first, so a mariner
    /// swapping one region for another does not hold both on the disk at once.
    private func apply() {
        model.applyNoaaPick(givesBack: !removing.isEmpty)
        shut()
    }

    /// Tick what is already here, and remember it, so unticking reads as a
    /// removal.
    private func startFromInstalled() {
        noaa.pickRecorded()
        held = noaa.picked
        seeded = true
    }

    private var removalTitle: String {
        let gone = removing
        if noaa.picked.isEmpty { return "Remove all NOAA charts?" }
        if gone.count == 1 { return "Remove \(gone[0].name) charts?" }
        return "Remove charts for \(gone.count) regions?"
    }

    /// What the whole-download removal deletes: every chart in the
    /// downloader's own set, as the core's scan counted it. The catalog counts
    /// what a district names, and the point of this removal is the cells it
    /// does not.
    private var wholeRemovalMessage: String {
        let n = model.charts.sets.first(where: \.managed)?.cells.count ?? 0
        return "Lookout deletes all \(n) charts it downloaded, and the folder they are in. Charts you added yourself stay where they are, and you can download this water again."
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
            if noaa.picked.isEmpty {
                Text(wholeRemovalMessage)
            } else {
                Text("Lookout deletes the charts it downloaded for this water. Charts you added yourself stay where they are, and you can download this water again.")
            }
        }
        .onAppear {
            noaa.poll()
            noaa.reprice()
            if !noaa.state.haveCatalog { noaa.refresh() } else { startFromInstalled() }
        }
        // The catalog is what prices a region, so what is held cannot be known
        // until it lands. On a first open it arrives after this view.
        .onChange(of: noaa.regionState) { _, _ in
            if !seeded { startFromInstalled() }
        }
    }
}
