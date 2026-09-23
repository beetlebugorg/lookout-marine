//  NoaaRegionRows.swift: the NOAA regions as rows, for a narrow screen.

import SwiftUI

/// The regions as rows, for a narrow screen.
///
/// Nine pills wrap to three ragged lines on a phone and leave the rest of the
/// page empty under them. A row is the width of the screen, says which water
/// the region covers rather than making the map answer that, and is a target a
/// thumb cannot miss.
struct NoaaRegionRows: View {
    let regions: [NoaaRegion]
    let picked: Set<String>
    let enabled: Bool
    let toggle: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(regions.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider().padding(.leading, 14) }
                row(r)
            }
        }
        .background(Chrome.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Chrome.edge.opacity(0.8), lineWidth: 1))
        .opacity(enabled ? 1 : 0.5)
    }

    private func row(_ r: NoaaRegion) -> some View {
        let on = picked.contains(r.id)
        return Button { toggle(r.id) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name)
                        .font(.system(size: 15, weight: on ? .semibold : .regular))
                        .foregroundStyle(Chrome.ink)
                    Text(r.blurb)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Chrome.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(on ? Chrome.accent : Chrome.ink.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(r.name). \(r.blurb)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("region-\(r.id)")
    }
}
