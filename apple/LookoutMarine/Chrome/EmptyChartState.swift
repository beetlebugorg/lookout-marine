//  EmptyChartState.swift — the first thing a mariner sees, before any chart.
//
//  It answers three questions in the order they are asked. What is this program
//  for. Why is it empty. What do I do now. It does not offer to download
//  anything, because nothing here can yet: a door that does not open is worse
//  than no door.

import SwiftUI


/// One fact under the first-run panel's buttons: an icon and a line.
private struct EmptyStateNote<Content: View>: View {
    let icon: String
    @ViewBuilder let content: Content

    init(icon: String, text: String) where Content == Text {
        self.icon = icon
        self.content = Text(text)
    }
    init(icon: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Chrome.muted)
                .frame(width: 15)
            content
                .font(.system(size: 11.5))
                .foregroundStyle(Chrome.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 7)
    }
}



/// The first thing a mariner sees, before any chart is installed.
///
/// It answers three questions in the order they are asked. What is this
/// program for. Why is it empty. What do I do now. The old panel answered only
/// the third, and answered it in file extensions.
///
/// It does not offer to download anything, because nothing here can yet. A
/// door that does not open is worse than no door, so where charts come from is
/// stated as a fact instead.
struct EmptyChartState: View {
    var model: AppModel

    /// NOAA's ENC download page: the whole country, a state, or one cell.
    static let noaaDownloads = URL(string: "https://www.charts.noaa.gov/ENCs/ENCs.shtml")!

    var body: some View {
        // Centred while it fits, and scrollable when it does not. An overlay
        // child that does not fill is allocated its natural height, so on a
        // phone in landscape, or at an accessibility text size, the page was
        // taller than the screen and clipped at both ends with no way to
        // reach either.
        GeometryReader { geo in
            ScrollView {
                page
                    .frame(maxWidth: 430, alignment: .leading)
                    // A page with no inset runs its text into both edges of a
                    // phone, which is where it was losing the end of a line.
                    .padding(.horizontal, Chrome.margin)
                    .padding(.vertical, Chrome.margin)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "map")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tint)
                .padding(.bottom, 12)

            Text("No charts yet")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Chrome.ink)
                .padding(.bottom, 6)

            Text("Lookout draws official S-57 and S-101 ENC charts. It does not come with any, so point it at yours.")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            if let msg = model.charts.emptyPick {
                // A folder that held nothing has to say so HERE. This page is
                // where the mariner pressed the button, and a message that
                // only appears in the settings window is a message they never
                // see.
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle")
                    Text(msg)
                }
                .font(.system(size: 12))
                .foregroundStyle(Chrome.overscale)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            }

            HStack(spacing: 10) {
                Button { model.requestOpenPicker() } label: {
                    // The Files picker runs in another process, and starting
                    // it takes about three seconds the first time. The button
                    // says it is working for that whole wait: three seconds of
                    // an unchanged screen reads as a button that did nothing.
                    if model.chrome.showImporter {
                        Label {
                            Text("Choose Charts…")
                        } icon: {
                            ProgressView().controlSize(.small)
                        }
                    } else {
                        Label("Choose Charts…", systemImage: "folder")
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(model.chrome.showImporter)
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityIdentifier("choose-charts")

                #if os(macOS)
                // The Mac takes a drop on the window. A touch device does not:
                // there is no window to drop on, and the picker below reaches
                // everywhere the Files app does, a folder of cells included.
                Text("or drop them anywhere in this window")
                    .font(.system(size: 12))
                    .foregroundStyle(Chrome.muted)
                #endif
            }
            .padding(.bottom, 14)

            // What actually works, in the words of what the mariner has in
            // hand rather than the words of the file format.
            // Where the charts come from goes first: a mariner with none needs
            // that before they need a list of file extensions.
            // One Text, not a row of them: pieces in an HStack each wrap on
            // their own and the sentence comes apart. The URL is written out
            // rather than interpolated, because markdown is only parsed in a
            // literal and an interpolated link does not open.
            EmptyStateNote(icon: "globe.americas") {
                Text("NOAA publishes every United States chart at no cost, at [charts.noaa.gov](https://www.charts.noaa.gov/ENCs/ENCs.shtml). Most other offices sell theirs.")
            }
            EmptyStateNote(
                icon: "square.stack.3d.up",
                text: "A folder of cells (.000), prepared charts (.pmtiles), imagery (.mbtiles) or BSB/KAP sheets. Cells and sheets are converted once on the way in, a few seconds each.")

            // Last, and set apart. It is the one thing on this page that is
            // not about getting started, and the one a mariner must not skim.
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Chrome.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOT FOR NAVIGATION")
                        .font(.system(size: 12, weight: .bold))
                        .kerning(0.5)
                        .foregroundStyle(Chrome.ink)
                    Text("By importing charts you accept that Lookout is a prototype and not a certified navigation system, and that the charts it prepares are processed for display and are not the official ENC. They do not meet chart carriage regulations. You remain responsible for the safe navigation of your vessel and for keeping clear of every danger. Verify everything shown here against official, up-to-date charts and publications, and keep a paper backup.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Chrome.ink.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    // NOAA's own terms, in their words. They apply to their
                    // charts whoever prepared them.
                    Text("NOAA ENC® charts come from the NOAA Office of Coast Survey and are updated weekly on a best-efforts basis; you are responsible for holding the current edition and the latest updates. NOAA makes no warranty and assumes no liability for their use. See the [NOAA ENC User Agreement](https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml).")
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.ink.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .background(Chrome.amber.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Chrome.amber.opacity(0.55), lineWidth: 1))
            .padding(.top, 10)

            if !model.charts.sets.isEmpty {
                Divider().padding(.vertical, 12)
                Text("Switched off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Chrome.muted)
                ForEach(model.charts.sets) { set in
                    Toggle(set.name, isOn: Binding(
                        get: { set.on },
                        set: { model.charts.setChartSetOn(set.path, $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12))
                }
            }
        }
    }
}
