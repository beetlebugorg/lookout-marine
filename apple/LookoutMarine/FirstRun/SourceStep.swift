//  SourceStep.swift: where the first charts come from.
//
//  One decision, as big as the screen allows. The cards stand side by side in a
//  sheet and stack on a phone, and that is the only difference between the two
//  platforms here.
//
//  FirstRunModel.Source is the list, so a source that gains a screen gains a
//  card without this file changing.

import SwiftUI

struct SourceStep: View {
    @Bindable var flow: FirstRunModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(
                title: "How would you like to add charts?",
                blurb: "You can add the other sources any time, from Charts in Mariner settings.",
                centered: centered)
                .padding(.top, topInset)
            cards.padding(.top, 26)
        }
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 26)
    }

    @ViewBuilder private var cards: some View {
        #if os(macOS)
        // Equal columns, so blurbs of different lengths still make one row of
        // cards rather than a staircase.
        HStack(alignment: .top, spacing: 14) {
            ForEach(FirstRunModel.Source.allCases) { source in
                card(source)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        #else
        VStack(spacing: 11) {
            ForEach(FirstRunModel.Source.allCases) { source in
                card(source)
            }
        }
        #endif
    }

    private func card(_ source: FirstRunModel.Source) -> some View {
        SourceCard(
            icon: source.icon,
            title: source.title,
            recommended: source == .online,
            blurb: source.blurb,
            picked: flow.source == source,
            stacked: stacked
        ) {
            flow.source = source
        }
    }

    #if os(macOS)
    private var centered: Bool { true }
    private var stacked: Bool { false }
    private var topInset: CGFloat { 38 }
    private var horizontalInset: CGFloat { 40 }
    #else
    private var centered: Bool { false }
    private var stacked: Bool { true }
    private var topInset: CGFloat { 20 }
    private var horizontalInset: CGFloat { 18 }
    #endif
}
