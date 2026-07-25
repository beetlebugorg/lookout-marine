//  SearchField.swift — search box with a results dropdown.
//
//  Phase 1: coordinate go-to works now (decimal or DMS lat/lon → recenter).
//  Feature / place-name search is scaffolded and clearly marked "coming soon" —
//  it needs a name/feature index in tile57 and a matching `lookout_*` query
//  (out of Phase-1 scope). We never fake results. Platform-neutral.

import SwiftUI

struct SearchField: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    private var parsedCoord: (lat: Double, lon: Double)? {
        CoordinateParser.parse(model.searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to coordinate  (e.g. 38.978, -76.492)", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { _ = model.submitSearch() }
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)

            if focused && !model.searchText.isEmpty {
                Divider()
                results
            }
        }
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.hairline))
    }

    @ViewBuilder private var results: some View {
        if let c = parsedCoord {
            Button {
                _ = model.submitSearch(); focused = false
            } label: {
                Label {
                    Text("Go to \(CoordFormat.dms(c.lat, isLat: true)) \(CoordFormat.dms(c.lon, isLat: false))")
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            // Feature / place-name search — deferred (needs a tile57 name index).
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.questionmark").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Feature & place search").font(.callout)
                    Text("Coming soon — needs a chart name index").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
    }
}
