//  ChartGallery.swift: the charts to draw, as tiles.
//
//  One chart draws at a time. Lookout's own chart is built from the installed
//  sets; a link is a publisher's style drawn instead of it. A row of tiles
//  rather than a list, so two styles with similar names are told apart by
//  looking.
//
//  A tile shows the chart it names only for Lookout's own chart. Rendering a
//  publisher's style needs the style resolved and its tiles fetched, and the
//  engine renders one chart at a time, so a linked tile shows its kind and its
//  url instead of a picture.

import SwiftUI

struct ChartGallery: View {
    var model: AppModel
    /// What the last tile does. The parent owns it, because adding a chart by
    /// link and adding one from a file are the same decision to a mariner and
    /// the parent is where that sheet lives.
    let onAdd: () -> Void

    private var links: ChartLinksModel { model.chartLinks }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Metrics.gap) {
                ChartTile(kind: .lookout,
                          name: "Lookout chart",
                          detail: lookoutDetail,
                          active: links.active == nil) {
                    links.select(nil)
                }
                ForEach(links.list) { link in
                    ChartTile(kind: .link,
                              name: link.name,
                              detail: link.url,
                              active: links.active == link.url,
                              onRefresh: { links.refresh(link.url) },
                              onRemove: { links.remove(link.url) }) {
                        links.select(link.url)
                    }
                }
                AddChartTile(add: onAdd)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.automatic)
        // The row starts at its first tile. Without this the form can hand the
        // scroll view an offset and the active tile is cut off at the left.
        .defaultScrollAnchor(.leading)
    }

    /// What Lookout's own chart is built from.
    private var lookoutDetail: String {
        let cells = model.charts.sets.filter(\.on).reduce(0) { $0 + $1.cells.count }
        if cells == 0 { return "From your chart sets" }
        return "From your chart sets · \(cells) cells"
    }

    enum Metrics {
        #if os(macOS)
        static let tile: CGFloat = 250
        static let art: CGFloat = 132
        static let add: CGFloat = 176
        static let gap: CGFloat = 10
        #else
        static let tile: CGFloat = 196
        static let art: CGFloat = 112
        static let add: CGFloat = 150
        static let gap: CGFloat = 10
        #endif
    }
}


/// One chart: a picture of it where there is one, its name, and where it comes
/// from.
private struct ChartTile: View {
    enum Kind { case lookout, link }

    let kind: Kind
    let name: String
    let detail: String
    let active: Bool
    var onRefresh: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                art
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Chrome.ink)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.top, 9)
                .padding(.bottom, 11)
            }
            .frame(width: ChartGallery.Metrics.tile)
            .modifier(CardSkin(picked: active, radius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("chart-tile-\(name)")
    }

    private var art: some View {
        ZStack(alignment: .topLeading) {
            switch kind {
            case .lookout:
                Image("WelcomeChart")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .link:
                // No picture: see the note at the top of this file.
                Chrome.panel
                    .overlay(
                        Image(systemName: "globe.americas")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Chrome.accent.opacity(0.55))
                    )
            }
            if active {
                Text("ACTIVE")
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Chrome.accent, in: RoundedRectangle(cornerRadius: 5))
                    .padding(7)
            }
        }
        .frame(height: ChartGallery.Metrics.art)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) { menu }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Chrome.edge.opacity(0.5)).frame(height: 1)
        }
    }

    /// Re-read the chart, or take it off the list. Lookout's own chart has
    /// neither: it is built from the sets below and cannot be removed.
    @ViewBuilder private var menu: some View {
        if onRefresh != nil || onRemove != nil {
            Menu {
                if let onRefresh {
                    Button("Read This Chart Again", systemImage: "arrow.clockwise", action: onRefresh)
                }
                if let onRemove {
                    Button("Remove", systemImage: "minus.circle", role: .destructive, action: onRemove)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                    .frame(width: 22, height: 22)
                    .background(Chrome.surface.opacity(0.92), in: Circle())
                    .overlay(Circle().strokeBorder(Chrome.edge.opacity(0.6), lineWidth: 0.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(7)
            .accessibilityLabel("More for \(name)")
        }
    }
}


/// The last tile: add a chart by link or from a file.
private struct AddChartTile: View {
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Chrome.accent)
                Text("Add a chart")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Chrome.ink)
                Text("Style link, TileJSON, or a file")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Chrome.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .frame(width: ChartGallery.Metrics.add)
            .frame(maxHeight: .infinity)
            .background(Chrome.ink.opacity(0.02),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Chrome.edge.opacity(0.7),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("add-chart-tile")
    }
}
