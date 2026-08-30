//  HoverTip.swift — what a plugin overlay symbol says.
//
//  Shown while the pointer rests on it, and again with a close control when the
//  mariner pins it. Values are monospaced-digit so a live SOG does not reflow
//  its column.

import SwiftUI

/// The panel surface and the type sizes are the app's, the same as a pick
/// report.
struct HoverTip: View {
    let info: OverlayHover
    /// Set when the card is PINNED: it then carries a close control. A hover
    /// tooltip has none — it goes when the pointer does.
    var onClose: (() -> Void)?

    /// `maxWidth` caps the card. `assumedHeight` only tells hoverLayout which
    /// way to flip, so it is an over-estimate and never a frame.
    static let maxWidth: CGFloat = 240
    static let assumedHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(info.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Chrome.ink)
                    .lineLimit(1)
                if let onClose {
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Chrome.muted)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(ChromeFlatStyle(cornerRadius: 4))
                    .help("Close")
                    .accessibilityLabel("Close")
                }
            }
            if !info.rows.isEmpty {
                Divider().overlay(Chrome.rule)
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(info.rows, id: \.0) { key, value in
                        GridRow {
                            Text(key)
                                .font(.system(size: 11))
                                .foregroundStyle(Chrome.muted)
                            Text(value)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Chrome.ink)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .panelSurface(cornerRadius: 8, opaque: true)
    }
}
