//  OnlineChartStep.swift: a published chart style, drawn as the chart.
//
//  One online chart draws at a time, and while it draws it is the chart. The
//  Mariner settings do not reach inside it, because a linked chart renders the
//  way its publisher styled it.
//
//  The shelf holds the charts in ChartCatalog, then whatever the mariner has
//  linked themselves, and the field below adds another. Lookout runs none of
//  these services, so a card names its publisher and the url its tiles come
//  from.
//
//  Every card draws a picture. A shipped entry has one in the app, so the
//  shelf is pictured before a tile is fetched, and a render of the mariner's
//  own water replaces it when it lands.

import SwiftUI

struct OnlineChartStep: View {
    var model: AppModel
    @Bindable var flow: FirstRunModel

    @State private var entry = ""
    /// A picture of each chart, once the engine has drawn it.
    @State private var previews = ChartPreviews()

    private var links: ChartLinksModel { model.chartLinks }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "Choose an online chart",
                blurb: "An online chart renders straight away, worldwide, and stores nothing. One shows at a time, and while it is on it is the chart.",
                centered: centered)
                .padding(.top, topInset)

            // The charts first, the way to add one after them. Side by side,
            // so two styles are compared by looking rather than by scrolling
            // between them.
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(shelf) { link in
                    ChartLinkCard(link: link,
                                  picture: previews.images[link.url]
                                      ?? ChartCatalog.art(for: link.url),
                                  drawing: previews.drawing.contains(link.url),
                                  picked: links.active == link.url,
                                  onPick: { pick(link.url) },
                                  onRemove: added(link.url)
                                      ? { links.remove(link.url) } : nil)
                }
            }
            .padding(.top, 20)

            Text("Another link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Chrome.ink)
                .padding(.top, shelf.isEmpty ? 22 : 18)
            linkEntry.padding(.top, 8)
            Text("MapLibre style or TileJSON link")
                .font(.system(size: 11.5))
                .foregroundStyle(Chrome.muted)
                .padding(.top, 6)

            if let error = links.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.overscale)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            StepWarning(
                lead: "Not for navigation.",
                body_: "A published style is drawn exactly as its publisher styled it. Its depths and marks come from whoever made it, may be missing, outdated or wrong, and are not reduced to a chart datum by Lookout.")
                .padding(.top, 20)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 26)
        .onAppear {
            previews.bind(to: model.controller)
            drawPreviews()
        }
        // The list arrives from the core a moment after the step appears.
        .onChange(of: links.list) { _, _ in drawPreviews() }
        .onDisappear { previews.stopRendering() }
    }

    /// Paste a link, or open one already on this device. The app treats both
    /// as the same kind of chart, so they share one row.
    private var linkEntry: some View {
        HStack(spacing: 8) {
            TextField("https://…/style.json", text: $entry)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .onSubmit(submit)
                .accessibilityIdentifier("first-run-chart-link")
            if links.busy {
                ProgressView().controlSize(.small)
            } else {
                Button("Add", action: submit)
                    .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { model.addChartStyleFile() } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Chrome.muted)
                .help("Add a style file from this device")
                .accessibilityLabel("Add a chart style file")
            }
        }
    }

    /// What the shelf lists: the shipped charts in their order, then the links
    /// the mariner added. Picking a shipped chart adds it to the mariner's
    /// list, and holding the order steady keeps the cards where they were.
    private var shelf: [ChartLinksModel.ChartLink] {
        let shipped = ChartCatalog.entries.map {
            ChartLinksModel.ChartLink(url: $0.url, name: $0.name)
        }
        let urls = Set(shipped.map(\.url))
        // A shipped chart the core has read goes under the publisher's own
        // name for it.
        let named = shipped.map { entry in
            links.list.first(where: { $0.url == entry.url }) ?? entry
        }
        return named + links.list.filter { !urls.contains($0.url) }
    }

    /// True once this chart is on the mariner's own list.
    private func added(_ url: String) -> Bool {
        links.list.contains(where: { $0.url == url })
    }

    /// Draw this chart. A shipped entry the mariner has not taken yet is added
    /// first, which the core reads and then picks.
    private func pick(_ url: String) {
        if added(url) { links.select(url) } else { links.add(url) }
    }

    /// Every chart on the shelf, drawn off to one side at the water the mariner
    /// is on, so a card has its picture without being picked.
    private func drawPreviews() {
        let charts = shelf.map(\.url)
        guard !charts.isEmpty else { return }
        let at = model.controller?.viewCenter() ?? (lon: -76.48, lat: 38.97)
        previews.renderAll(charts, lon: at.lon, lat: at.lat, zoom: 12)
    }

    private func submit() {
        let raw = entry
        entry = ""
        links.add(raw)
    }

    #if os(macOS)
    private var centered: Bool { true }
    private var topInset: CGFloat { 34 }
    private var horizontalInset: CGFloat { 40 }
    /// Two across. A third column makes a preview too small to tell a style by.
    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }
    #else
    private var centered: Bool { false }
    private var topInset: CGFloat { 16 }
    private var horizontalInset: CGFloat { 18 }
    private var columns: [GridItem] { [GridItem(.flexible())] }
    #endif
}


/// One added chart: the mark, the name, and the url it came from.
///
/// The url wraps rather than clipping. A style link holds the publisher, the
/// style and often a key, and those are the parts a middle ellipsis removes
/// first.
private struct ChartLinkCard: View {
    let link: ChartLinksModel.ChartLink
    /// This chart as the engine drew it, off to one side.
    var picture: Image? = nil
    /// True while that render is running.
    var drawing = false
    let picked: Bool
    let onPick: () -> Void
    /// Nil for a chart the app ships that the mariner has not taken yet:
    /// there is no link of theirs to drop.
    let onRemove: (() -> Void)?

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 0) {
                art
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14))
                            .foregroundStyle(picked ? Chrome.accent : Chrome.ink.opacity(0.30))
                        Text(link.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Chrome.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let onRemove {
                            Button(action: onRemove) {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Chrome.muted)
                            .accessibilityLabel("Remove \(link.name)")
                        }
                    }
                    Text(link.url)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Chrome.muted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 11)
                .padding(.top, 9)
                .padding(.bottom, 11)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
        .modifier(CardSkin(picked: picked, radius: 12))
    }

    /// The chart, or the room it will take. A style renders through the engine
    /// and the engine draws one at a time, so a chart never picked has none.
    private var art: some View {
        Group {
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
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(Chrome.accent.opacity(0.5))
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        // Nearer square than a strip: a chart style is told apart by its water
        // and its marks, and both want height.
        .aspectRatio(4.0 / 3.0, contentMode: .fill)
        .frame(maxHeight: 210)
        .clipped()
        .overlay(alignment: .bottom) {
            Rectangle().fill(Chrome.edge.opacity(0.5)).frame(height: 1)
        }
    }
}
