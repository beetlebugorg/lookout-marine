//  WelcomeStep.swift: what this is, and the ways to get a chart.
//
//  The hero is a real ENC, the app's own day screenshot, so the promise is
//  visible before anything downloads. The rows below answer what to do next.
//  The legal notice is a footnote, near the action it qualifies.

import SwiftUI

struct WelcomeStep: View {
    @Bindable var flow: FirstRunModel

    /// NOAA's ENC agreement, which applies to their charts however they were
    /// prepared. Setup asks the mariner to accept it before it downloads any,
    /// in EncTermsSheet; this is the same document, for reading beforehand.
    static let noaaAgreement = URL(string: "https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            VStack(spacing: 0) {
                StepHeading(title: "Welcome to Lookout Marine", blurb: FirstRun.promise)
                    .padding(.top, 26)
                VStack(alignment: .leading, spacing: 20) {
                    StepFact(
                        icon: "map",
                        title: "Official ENC charts, drawn live",
                        blurb: "Lookout renders S-57 and S-101 cells itself. NOAA publishes every United States chart at no cost; most other offices sell theirs.")
                    StepFact(
                        icon: "globe.americas",
                        title: "Or start with an online chart",
                        blurb: "A published chart style renders straight away, worldwide, with nothing to download and nothing stored.")
                    StepFact(
                        icon: "folder",
                        title: "Bring charts you already have",
                        blurb: FirstRun.filesBlurb)
                }
                .padding(.top, 26)
                notice.padding(.top, 26)
            }
            .padding(.horizontal, horizontalInset)
            .padding(.bottom, 4)
        }
    }

    /// The chart, bleeding to the top edge. It sits behind the status bar on a
    /// phone, so the page has no title above it.
    ///
    /// The picture draws in an overlay over a box of the size this wants, so
    /// its own width stays out of the layout. Filling a fixed height gives a
    /// picture this wide its natural width to ask for, and on a phone, where
    /// no sheet caps it, that width set the width of the whole step: the rows
    /// below were laid out wider than the screen and clipped at both edges.
    private var hero: some View {
        Color.clear
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            .overlay {
                Image("WelcomeChart")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
            .accessibilityLabel("A Lookout chart of Annapolis")
    }

    /// The prototype notice, as a sentence and a link. The page that installs
    /// charts holds the full agreement. Repeating it here teaches a mariner to
    /// scroll past it in both places.
    private var notice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Chrome.muted)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Lookout is a prototype and is not a certified navigation system. It does not meet chart carriage regulations. Always carry official charts aboard.")
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(Chrome.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Link("NOAA ENC User Agreement", destination: WelcomeStep.noaaAgreement)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Chrome.accent)
            }
        }
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    #if os(macOS)
    private var heroHeight: CGFloat { 296 }
    private var horizontalInset: CGFloat { 64 }
    #else
    private var heroHeight: CGFloat { 260 }
    private var horizontalInset: CGFloat { 24 }
    #endif
}
