//  BandRamp.swift: what scales a chart set holds.
//
//  One bar in the S-52 depth ramp, split by usage band, finest first. A set
//  that stops at Coastal does not draw the harbor a passage ends in, and the
//  width of each band says how much of the set is at that scale.

import SwiftUI

struct BandRamp: View {
    /// Coarse to fine, as ChartSet.bandCounts reports it from the core.
    let counts: [(band: Int, name: String, count: Int)]

    /// Finest first, matching the ramp from deep color to pale.
    private var ordered: [(band: Int, name: String, count: Int)] {
        counts.sorted { $0.band > $1.band }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar
            legend
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            // A hairline between the segments. Four of the six bands are the
            // pale end of the S-52 ramp, and next to each other in a 9pt bar
            // they read as one stripe.
            HStack(spacing: Self.hair) {
                ForEach(ordered, id: \.band) { b in
                    BandRamp.color(b.band)
                        .frame(width: width(b.count, in: geo.size.width))
                }
            }
        }
        .frame(height: 9)
        .background(Chrome.edge.opacity(0.55))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Chrome.edge.opacity(0.5), lineWidth: 1))
        .accessibilityLabel(voiceOver)
    }

    private static let hair: CGFloat = 1
    /// The narrowest a band draws. A library of 7,000 cells holds two dozen
    /// overviews, and a band the legend counts has to be on the bar.
    private static let least: CGFloat = 4

    private var legend: some View {
        // Wraps rather than scrolls: six bands fit two lines at any width the
        // settings pane reaches.
        FlowRow(spacing: 12, lineSpacing: 6) {
            ForEach(ordered, id: \.band) { b in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(BandRamp.color(b.band))
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Chrome.edge.opacity(0.5), lineWidth: 1))
                        .frame(width: 8, height: 8)
                    Text(b.name)
                        .foregroundStyle(Chrome.muted)
                    Text("\(b.count)")
                        .foregroundStyle(Chrome.ink)
                        .monospacedDigit()
                }
                .font(.system(size: 11))
            }
        }
    }

    /// One band's share of the bar, with a floor under it. The floor comes out
    /// of the bands wide enough to give it, so the bar still fills.
    private func width(_ count: Int, in total: CGFloat) -> CGFloat {
        let sum = ordered.reduce(0) { $0 + $1.count }
        guard sum > 0, count > 0 else { return 0 }
        let room = total - Self.hair * CGFloat(max(ordered.count - 1, 0))
        guard room > 0 else { return 0 }
        let raw = ordered.map { room * CGFloat($0.count) / CGFloat(sum) }
        let owed = raw.filter { $0 < Self.least }.reduce(0) { $0 + Self.least - $1 }
        let spare = raw.filter { $0 > Self.least }.reduce(0) { $0 + $1 - Self.least }
        let mine = room * CGFloat(count) / CGFloat(sum)
        if mine < Self.least { return Self.least }
        guard spare > 0 else { return mine }
        return mine - (mine - Self.least) * min(owed / spare, 1)
    }

    private var voiceOver: String {
        ordered.map { "\($0.name) \($0.count)" }.joined(separator: ", ")
    }

    /// The core's usage band ramp, BAND1 to BAND6. In the day palette it is
    /// the S-52 depth ramp, deep to shallow, read as fine to coarse. Band 6 is
    /// berthing detail and band 1 is an overview.
    static func color(_ band: Int) -> Color {
        ramp[min(max(band, 1), 6) - 1]
    }

    private static let ramp: [Color] = (1...6).map { Chrome.s52("BAND\($0)") }
}
