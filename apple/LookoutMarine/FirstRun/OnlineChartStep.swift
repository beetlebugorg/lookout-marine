//  OnlineChartStep.swift: a published chart style, drawn as the chart.
//
//  One online chart draws at a time, and while it draws it is the chart. The
//  Mariner settings do not reach inside it, because a linked chart renders the
//  way its publisher styled it.
//
//  The app ships no list of styles. Lookout runs none of these services, so a
//  card naming one states a relationship the app does not have. The cards are
//  the mariner's own links, and the field below adds another.
//
//  A card shows a picture of its chart once the engine has drawn it. Picking
//  one is what draws it. Artboard 7d shows every card already pictured;
//  the engine draws one chart at a time, so they fill in as the mariner looks
//  through them.

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
            if !links.list.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(links.list) { link in
                        ChartLinkCard(link: link,
                                      picture: previews.images[link.url],
                                      picked: links.active == link.url,
                                      onPick: { links.select(link.url) },
                                      onRemove: { links.remove(link.url) })
                    }
                }
                .padding(.top, 20)
            }

            Text("Another link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Chrome.ink)
                .padding(.top, links.list.isEmpty ? 22 : 18)
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
            previews.capture(active: links.active)
        }
        // The chart the mariner just picked, once it has drawn.
        .task(id: links.active) {
            let want = links.active
            await previews.watch(active: want) {
                links.active == want && links.error == nil
            }
        }
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
    /// This chart as the engine drew it, once it has been picked once.
    var picture: Image? = nil
    let picked: Bool
    let onPick: () -> Void
    let onRemove: () -> Void

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
                        Button(action: onRemove) {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Chrome.muted)
                        .accessibilityLabel("Remove \(link.name)")
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
                    .overlay(
                        Image(systemName: "globe.americas")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(Chrome.accent.opacity(0.5))
                    )
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
