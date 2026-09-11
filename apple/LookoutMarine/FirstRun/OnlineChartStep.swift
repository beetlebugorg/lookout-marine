//  OnlineChartStep.swift: a published chart style, drawn as the chart.
//
//  One online chart draws at a time, and while it draws it is the chart. The
//  Mariner settings do not reach inside it, because a linked chart renders the
//  way its publisher styled it.
//
//  The app ships no list of styles. Lookout runs none of these services, so a
//  card naming one states a relationship the app does not have. The step offers
//  a link field. Mariner settings owns the depth unit and the light sectors.

import SwiftUI

struct OnlineChartStep: View {
    var model: AppModel
    @Bindable var flow: FirstRunModel

    @State private var entry = ""

    private var links: ChartLinksModel { model.chartLinks }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "Choose an online chart",
                blurb: "Paste a MapLibre style link or a TileJSON tile link. It renders straight away, worldwide, and stores nothing.",
                centered: centered)
                .padding(.top, topInset)

            linkEntry.padding(.top, 22)

            if !links.list.isEmpty {
                VStack(spacing: 11) {
                    ForEach(links.list) { link in
                        ChartLinkCard(link: link,
                                      picked: links.active == link.url,
                                      onPick: { links.select(link.url) },
                                      onRemove: { links.remove(link.url) })
                    }
                }
                .padding(.top, 16)
            }

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
    #else
    private var centered: Bool { false }
    private var topInset: CGFloat { 16 }
    private var horizontalInset: CGFloat { 18 }
    #endif
}


/// One added chart: the mark, the name, and the url it came from.
///
/// The url wraps rather than clipping. A style link holds the publisher, the
/// style and often a key, and those are the parts a middle ellipsis removes
/// first.
private struct ChartLinkCard: View {
    let link: ChartLinksModel.ChartLink
    let picked: Bool
    let onPick: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPick) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(picked ? Chrome.accent : Chrome.ink.opacity(0.30))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(link.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Chrome.ink)
                        Text(link.url)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Chrome.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Chrome.muted)
            .accessibilityLabel("Remove \(link.name)")
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 14)
        .modifier(CardSkin(picked: picked, radius: 12))
    }
}
