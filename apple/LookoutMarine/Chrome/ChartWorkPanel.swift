//  ChartWorkPanel.swift — the chart work, in the two places a mariner looks.
//
//  ONE view, not two. Before there is a chart it stands in the middle of the
//  window, open, because the wait is the only thing on screen. Once charts are
//  drawing it moves to the top and closes to a line. Moving one panel is what
//  makes those two states read as the same work.

import SwiftUI


/// The chart work, in the two places a mariner looks for it.
///
/// ONE view, not two. Before there is a chart it stands in the middle of the
/// window, open, because the wait is the only thing on screen. Once charts are
/// drawing it moves to the top and closes to a line, because the chart is now
/// the thing worth looking at. Moving one panel is what makes those two states
/// read as the same work; swapping a big panel for a small one somewhere else
/// reads as two unrelated things.
struct ChartWorkPanel: View {
    let progress: BakeProgress
    /// True once a chart is drawing: the small form at the top.
    let compact: Bool
    let onCancel: () -> Void
    @State private var open = false
    @State private var cancelling = false

    private var title: String { progress.title }
    /// The detail shows always in the big form, and on request in the small one.
    private var showDetail: Bool { !compact || open }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            if compact {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { open.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text(cancelling ? "Finishing this chart…" : title)
                            .font(.system(size: 13))
                            .foregroundStyle(Chrome.ink)
                        if progress.total > 0 {
                            Text("\(progress.done) of \(progress.total)")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Chrome.muted)
                        } else {
                            // Nothing to count yet. A moving count is what says
                            // the app is working; with none, the pill is a line
                            // of text that sits there for seconds and reads as
                            // a hang, so it spins instead.
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        }
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Chrome.muted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(progress.done) of \(progress.total) charts")
                .accessibilityHint(open ? "Closes the details" : "Opens the details")
            } else {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
            }

            if showDetail {
                BakeDetail(progress: progress, onCancel: onCancel, cancelling: $cancelling)
            }

        }
        .padding(.horizontal, compact ? 14 : 0)
        .padding(.vertical, compact ? 10 : 0)
        // A card floats over something. On first run there is nothing under
        // it, so the big form is the page itself and only the pill, which
        // really does sit over a chart, keeps the surface.
        .panelSurface(cornerRadius: 14, enabled: compact)
    }
}



/// One step of the work, and where it has got to.
///
/// A step that is done says what it produced. The step running says how far in
/// it is. A step not started yet is dim and says nothing, because a number
/// against work that has not begun is noise.
struct BakeStep: View {
    enum State { case done, running, waiting }
    let state: State
    let label: String
    /// The short fact beside the label: a count, or what the step produced.
    var detail: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                case .running:
                    Image(systemName: "circle.dotted.circle").foregroundStyle(.tint)
                case .waiting:
                    Image(systemName: "circle.dotted").foregroundStyle(Chrome.muted)
                }
            }
            .font(.system(size: 12))
            .frame(width: 14)

            Text(label)
                .font(.system(size: 12, weight: state == .running ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? Chrome.muted : Chrome.ink)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Chrome.muted)
            }
            Spacer(minLength: 0)
        }
        .opacity(state == .waiting ? 0.5 : 1)
    }
}



/// What a bake is doing, in full: the bar, the steps, and the way out.
///
/// One panel in two places. It is the body of the pill at the top of the chart
/// once opened, and it is the whole first-run panel while there is no chart to
/// put a pill over. The mariner reads the same thing either way.
struct BakeDetail: View {
    let progress: BakeProgress
    let onCancel: () -> Void
    @Binding var cancelling: Bool

    /// One width in both places, so the panel that moves to the top of the
    /// chart is recognisably the panel that was in the middle of it.
    static let width: CGFloat = 320
    private var width: CGFloat { Self.width }
    private var counted: Bool { progress.total > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 6) {
                // Counted or not, the bar has to look like work. A determinate
                // bar with nothing in it reads as stuck, which is exactly what
                // the seconds of looking through a big folder looked like.
                Group {
                    if counted {
                        ProgressView(value: progress.fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                HStack {
                    Text(counted ? "\(Int(progress.fraction * 100))%" : "")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Chrome.muted)
                    Spacer()
                    Text(progress.remaining ?? "")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Chrome.muted)
                }
            }
            .frame(width: width)

            VStack(alignment: .leading, spacing: 7) {
                if progress.kind == .removing {
                    BakeStep(
                        state: counted && progress.done >= progress.total ? .done : .running,
                        label: "Removing charts",
                        detail: counted ? "\(progress.done) of \(progress.total)" : "")
                } else {
                    BakeStep(
                        state: counted ? .done : .running,
                        label: "Finding charts",
                        detail: counted ? "\(progress.total) found" : "")
                    BakeStep(
                        state: !counted ? .waiting : (progress.done < progress.total ? .running : .done),
                        label: "Importing charts",
                        detail: counted ? "\(progress.done) of \(progress.total)" : "")
                }
            }
            .frame(width: width, alignment: .leading)

            // No way out of a removal: the set is already off the list and the
            // charts are already moved aside, so a Cancel here could only stop
            // the disk being freed — which is not a choice worth offering, and
            // a button that cannot undo what it appears to undo is a lie.
            if progress.kind != .removing {
                Divider().frame(width: width)

                HStack {
                    Spacer(minLength: 0)
                    Button(cancelling ? "Stopping…" : "Cancel") {
                        cancelling = true
                        onCancel()
                    }
                    .disabled(cancelling)
                    .controlSize(.small)
                }
                .frame(width: width)
            }
        }
    }
}
