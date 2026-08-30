//  ChartMenuPanel.swift — the menu raised at a point on the water, and the
//  rename field that stands on a marker.
//
//  App chrome, not a system menu: the chrome follows the CHART's hours, so dusk
//  and night wear the dark palette whatever the desktop is set to. It is also
//  anchored to a place on the chart and retires when the camera moves, the way
//  the pick report does.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif


/// The chart menu, raised at a point on the water.
///
/// Every item acts on the point under the press, not on the map centre and not
/// on where the cursor drifts to afterwards, so the coordinates are taken once
/// when the menu opens and the menu carries them.
///
/// It is app chrome, not a system menu. The chrome follows the CHART's hours:
/// dusk and night wear the dark palette whatever the desktop is set to, while
/// a system menu takes its appearance from the desktop, which would put a
/// bright panel on a night passage. It is also anchored to a place on the
/// chart, and it closes when the camera moves, the way the pick report does.
struct ChartMenuPanel: View {
    var model: AppModel
    let menu: AppModel.ChartMenu

    static let width: CGFloat = 236
    /// Only used to decide which way the menu flips at an edge, never as a
    /// frame. The panel sizes itself.
    static func assumedHeight(hasMarker: Bool) -> CGFloat {
        (hasMarker ? 84 : 60) + 34 * (hasMarker ? 4 : 3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Chrome.rule)
            VStack(alignment: .leading, spacing: 1) {
                item("Pick report", system: "info.circle", action: model.chartMenuPick)
                if menu.marker == nil {
                    item("Drop marker", system: "mappin", action: model.chartMenuDropMarker)
                } else {
                    item("Rename marker", system: "pencil", action: model.chartMenuRenameMarker)
                    item("Remove marker", system: "trash", action: model.chartMenuRemoveMarker)
                }
                item("Copy position", system: "doc.on.doc", action: model.chartMenuCopyPosition)
            }
            .padding(.vertical, 4)
        }
        .frame(width: Self.width, alignment: .leading)
        .panelSurface(cornerRadius: 10, opaque: true)
    }

    /// The point's own coordinates, in the mariner's format. Reading them is
    /// the common case, so they are there without a click. Over a marker the
    /// mark's name rides above them, because that is what Rename and Remove
    /// act on.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let mark = menu.marker {
                HStack(spacing: 5) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.magenta)
                    Text(mark.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Chrome.ink)
                        .lineLimit(1)
                }
            }
            Text(CoordFormat.position(lat: menu.lat, lon: menu.lon))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(menu.marker == nil ? Chrome.ink : Chrome.muted)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }

    private func item(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: system)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(Chrome.muted)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Chrome.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(ChromeFlatStyle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .accessibilityLabel(title)
    }
}



/// The rename field, anchored to its marker.
///
/// A separate, unhurried action: the drop already placed and named the mark,
/// so nothing on the water is waiting for this. Return commits, Escape
/// abandons, an empty field keeps the old name, and the field takes 32
/// characters, which is a name and not a note.
struct MarkerRenameField: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    static let width: CGFloat = 200

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Chrome.magenta)
            TextField("Name", text: $model.renamingText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Chrome.ink)
                .focused($focused)
                .onSubmit { model.commitRename() }
                .onChange(of: model.renamingText) { clip() }
                .accessibilityIdentifier("marker-name-field")
        }
        .padding(.horizontal, 10)
        .frame(width: Self.width, height: 32)
        .panelSurface(cornerRadius: 8, opaque: true)
        .onAppear { focused = true }
        #if os(macOS)
        .onExitCommand { model.cancelRename() }
        #endif
    }

    /// Cut here as well as in the core, so the field never shows more than
    /// will be kept.
    private func clip() {
        if model.renamingText.count > 32 {
            model.renamingText = String(model.renamingText.prefix(32))
        }
    }
}
