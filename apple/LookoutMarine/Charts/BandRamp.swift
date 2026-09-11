//  BandRamp.swift: what scales a chart set holds.
//
//  One bar in the S-52 depth ramp, split by usage band, finest first. A set
//  that stops at Coastal does not draw the harbor a passage ends in, and the
//  width of each band says how much of the set is at that scale.

import SwiftUI

struct BandRamp: View {
    /// Coarse to fine, as ChartSet.bandCounts reports it.
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

    /// The S-52 depth ramp, deep to shallow, read as fine to coarse. Band 6 is
    /// berthing detail and band 1 is an overview.
    static func color(_ band: Int) -> Color {
        switch band {
        case 6: return Color(red: 0.184, green: 0.561, blue: 0.878)  // #2F8FE0
        case 5: return Color(red: 0.380, green: 0.718, blue: 1.000)  // #61B7FF
        case 4: return Color(red: 0.510, green: 0.792, blue: 1.000)  // #82CAFF
        case 3: return Color(red: 0.655, green: 0.851, blue: 0.984)  // #A7D9FB
        case 2: return Color(red: 0.788, green: 0.929, blue: 1.000)  // #C9EDFF
        default: return Color(red: 0.894, green: 0.961, blue: 1.000) // #E4F5FF
        }
    }
}


/// A row that wraps. SwiftUI has no flow layout, and a legend of six bands
/// runs off the side of the settings pane without one.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lay(subviews, in: width)
        let height = rows.map(\.height).reduce(0, +)
            + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lay(subviews, in: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lay(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, next > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
