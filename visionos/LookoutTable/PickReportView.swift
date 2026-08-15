//
//  What the chart holds where the mariner tapped, floating over the spot.
//
//  The reading is the chartplotter's: PickDecoded turns the cell's S-57
//  payload into a title, a subtitle, a chip, notes, rows and a footnote, and
//  this shows all of it. A pick usually answers with several objects stacked
//  at one place, best first, so the panel pages through them.
//

import SwiftUI

struct PickReportView: View {
    let picks: [PickDecoded]
    @Binding var index: Int
    let onClose: () -> Void

    private var pick: PickDecoded? {
        picks.indices.contains(index) ? picks[index] : picks.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pick {
                header(pick)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(pick.notes, id: \.self) { note in
                            note.pickNote()
                        }
                        if let empty = pick.empty {
                            Text(empty == .noAttributes
                                 ? "The cell carries no attributes for this object."
                                 : "The cell carries only source data for this object.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        }
                        ForEach(pick.reportRows) { row in
                            PickRowView(row: row)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 360)
                footer(pick)
            }
        }
        .padding(20)
        .frame(width: 460)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private func header(_ pick: PickDecoded) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pick.title)
                    .font(.title3.bold())
                if let subtitle = pick.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(pick.chip)
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.bottom, 12)
    }

    /// The cell the reading came from, and the pager when a tap found more
    /// than one object. A mariner taps a buoy on a depth area inside a
    /// restricted area, and all three are the answer.
    @ViewBuilder
    private func footer(_ pick: PickDecoded) -> some View {
        Divider()
        HStack {
            Text(pick.footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if picks.count > 1 {
                Button {
                    index = (index - 1 + picks.count) % picks.count
                } label: {
                    Image(systemName: "chevron.left")
                }
                Text("\(index + 1) of \(picks.count)")
                    .font(.caption.monospacedDigit())
                Button {
                    index = (index + 1) % picks.count
                } label: {
                    Image(systemName: "chevron.right")
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.top, 10)
    }
}

/// One decoded attribute. The label is narrow and indents with its depth, so
/// a nested group reads as a group; the value owns the width, because a note
/// or a name is the reading matter.
private struct PickRowView: View {
    let row: PickDecoded.ReportRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 132 - CGFloat(row.depth) * 12, alignment: .leading)
            Text(row.value)
                .font(.callout.monospacedDigit())
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .padding(.vertical, 5)
    }
}

private extension String {
    /// A note the mariner reads before the attributes: INFORM, promoted.
    @ViewBuilder
    func pickNote() -> some View {
        Text(self)
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 8)
    }
}
