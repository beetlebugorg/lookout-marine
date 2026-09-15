//  CoverageStep.swift: which waters to download.
//
//  A region is a Coast Guard district, the unit NOAA files a cell under. The
//  core turns a pick into the cells that cover that water, including the ones
//  NOAA files next door, so a region downloads without a gap along its border.
//  See src/noaa.zig.

import SwiftUI

struct CoverageStep: View {
    var model: AppModel
    @Bindable var noaa: NoaaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "Which waters do you sail?",
                blurb: "Pick the water you use. Lookout downloads those charts and prepares them. You can add the rest later.",
                centered: centered)
                .padding(.top, topInset)

            NoaaCatalogLine(noaa: noaa).padding(.top, 12)
            NoaaRegionList(model: model, noaa: noaa).padding(.top, 10)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 22)
        .onAppear {
            noaa.poll()
            noaa.noteInstalled(model.charts.installedCellNames)
            if !noaa.state.haveCatalog { noaa.refresh() }
        }
    }

    #if os(macOS)
    private var centered: Bool { true }
    private var topInset: CGFloat { 26 }
    private var horizontalInset: CGFloat { 20 }
    #else
    private var centered: Bool { false }
    private var topInset: CGFloat { 16 }
    private var horizontalInset: CGFloat { 16 }
    #endif
}
