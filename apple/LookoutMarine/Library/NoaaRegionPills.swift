//  NoaaRegionPills.swift: the NOAA regions as pills under the map.

import SwiftUI

/// The regions as pills under the map: the name, and the mark for a chosen one.
struct NoaaRegionPills: View {
    let regions: [NoaaRegion]
    let picked: Set<String>
    let enabled: Bool
    /// How much of each region is on the device. A pill for water already held
    /// says so, because the tick then means "keep this" rather than "fetch it".
    var state: [String: NoaaRegionState] = [:]
    let toggle: (String) -> Void

    var body: some View {
        FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(regions) { r in
                pill(r)
            }
        }
    }

    private func pill(_ r: NoaaRegion) -> some View {
        let on = picked.contains(r.id)
        return Button { toggle(r.id) } label: {
            HStack(spacing: 6) {
                if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(r.name)
                    .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                if let note = badge(r) {
                    Text(note)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .opacity(0.75)
                }
            }
            .foregroundStyle(on ? Color.white : Chrome.ink)
            .padding(.horizontal, 13)
            .frame(height: pillHeight)
            .background(on ? Chrome.accent : Chrome.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? .clear : Chrome.edge.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(r.blurb)
        .accessibilityLabel(label(r))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("region-\(r.id)")
    }

    /// What of this region is here, in the pill. Nothing before the catalog is
    /// read, and nothing for water with none of it on the device.
    /// Only the whole of a region is stated. NOAA files cells across district
    /// lines, so downloading one region installs some of its neighbour's, and
    /// a count of those read as a transfer that had stopped part way.
    private func badge(_ r: NoaaRegion) -> String? {
        guard let st = state[r.id], st.allHeld else { return nil }
        return "installed"
    }

    private func label(_ r: NoaaRegion) -> String {
        guard let st = state[r.id] else { return "\(r.name). \(r.blurb)" }
        if st.allHeld { return "\(r.name). \(r.blurb). All \(st.held) charts installed." }
        return "\(r.name). \(r.blurb). \(st.cells) charts to download."
    }

    #if os(macOS)
    private var pillHeight: CGFloat { 30 }
    #else
    // A thumb needs the full target.
    private var pillHeight: CGFloat { 44 }
    #endif
}
