//  ChartGallery.swift: the charts to draw, as tiles.
//
//  One chart draws at a time. Lookout's own chart is built from the installed
//  sets; a link is a publisher's style drawn instead of it. A row of tiles
//  rather than a list, so two styles with similar names are told apart by
//  looking.
//
//  The core draws each tile's picture: the chart on screen as the engine draws
//  it, and one publisher tile for any other raster style. A chart with no
//  picture shows its kind and its url.

import SwiftUI

struct ChartGallery: View {
    var model: AppModel
    /// What the last tile does. The parent owns it, because adding a chart by
    /// link and adding one from a file are the same decision to a mariner and
    /// the parent is where that sheet lives.
    let onAdd: () -> Void

    private var links: ChartLinksModel { model.chartLinks }
    /// One tile of each linked chart, at the water the mariner is on.
    @State private var previews = ChartPreviews()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Metrics.gap) {
                ChartCard(style: .tile,
                          name: "Lookout chart",
                          detail: lookoutDetail,
                          active: links.active == nil,
                          picture: previews.images[""] ?? Image("WelcomeChart")) {
                    links.select(nil)
                }
                ForEach(links.list) { link in
                    ChartCard(style: .tile,
                              name: link.name,
                              detail: link.url,
                              active: links.active == link.url,
                              picture: previews.images[link.url],
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
        .onAppear {
            previews.bind(to: model.controller)
            askPictures()
        }
        // A picture finishing, a pick and a new link all change the revision.
        .onChange(of: links.revision) { _, _ in askPictures() }
        .onDisappear { previews.stop() }
        .scrollIndicators(.automatic)
        // The row starts at its first tile. Without this the form can hand the
        // scroll view an offset and the active tile is cut off at the left.
        .defaultScrollAnchor(.leading)
    }

    /// Every tile's picture, at the water the mariner is on. The zoom is low
    /// enough that one publisher tile holds a recognisable stretch of coast.
    private func askPictures() {
        guard let at = model.controller?.viewCenter() else { return }
        previews.ask([""] + links.list.map(\.url), kind: .tile, lon: at.lon, lat: at.lat,
                     zoom: 9,
                     width: Int((Metrics.tile * displayScale).rounded()),
                     height: Int((Metrics.art * displayScale).rounded()))
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
///
/// `.tile` is the gallery's fixed-width tile, with an ACTIVE badge and a menu.
/// `.shelf` is the first-run card: a grid cell with a tick and a remove
/// button, whose url wraps to two lines. A style link holds the publisher,
/// the style and often a key, and those are the parts a middle ellipsis
/// removes first.
struct ChartCard: View {
    enum Style { case tile, shelf }

    let style: Style
    let name: String
    let detail: String
    let active: Bool
    /// One tile of this chart, once it has been fetched.
    var picture: Image? = nil
    /// True while this chart's picture is drawn.
    var drawing = false
    var onRefresh: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    let select: () -> Void

    private var shelf: Bool { style == .shelf }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                art
                caption
                    .padding(.horizontal, 11)
                    .padding(.top, 9)
                    .padding(.bottom, 11)
            }
            .frame(width: shelf ? nil : ChartGallery.Metrics.tile)
            .modifier(CardSkin(picked: active, radius: shelf ? 12 : 11))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("chart-tile-\(name)")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if shelf {
                    Image(systemName: active ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(active ? Chrome.accent : Chrome.ink.opacity(0.30))
                }
                Text(name)
                    .font(.system(size: shelf ? 14 : 13, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if shelf, let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Chrome.muted)
                    .accessibilityLabel("Remove \(name)")
                }
            }
            Text(detail)
                .font(shelf ? .system(size: 10.5, design: .monospaced) : .system(size: 11))
                .foregroundStyle(Chrome.muted)
                .lineLimit(shelf ? 2 : 1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var art: some View {
        switch style {
        case .tile:
            chartPicture
                .frame(width: ChartGallery.Metrics.tile, height: ChartGallery.Metrics.art)
                .clipped()
                // Over the clipped tile, and not inside it. A picture that fills
                // by covering is wider than the tile, so a badge aligned inside
                // it started left of the tile's own edge and lost its first
                // letter.
                .overlay(alignment: .topLeading) { badge }
                .overlay(alignment: .topTrailing) { menu }
                .overlay(alignment: .bottom) { rule }
        case .shelf:
            chartPicture
                .frame(maxWidth: .infinity)
                // Nearer square than a strip: a chart style is told apart by
                // its water and its marks, and both want height.
                .aspectRatio(4.0 / 3.0, contentMode: .fill)
                .frame(maxHeight: 210)
                .clipped()
                .overlay(alignment: .bottom) { rule }
        }
    }

    private var rule: some View {
        Rectangle().fill(Chrome.edge.opacity(0.5)).frame(height: 1)
    }

    /// The picture at the top of the card, or the room it will take. A style
    /// with vector tiles has no publisher tile to show.
    @ViewBuilder private var chartPicture: some View {
        if let picture {
            picture
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Chrome.panel
                .overlay {
                    if drawing {
                        VStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Drawing this chart…")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Chrome.muted)
                        }
                    } else {
                        Image(systemName: "globe.americas")
                            .font(.system(size: shelf ? 20 : 26, weight: .light))
                            .foregroundStyle(Chrome.accent.opacity(shelf ? 0.5 : 0.55))
                    }
                }
        }
    }

    @ViewBuilder private var badge: some View {
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
