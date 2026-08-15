//  SearchField.swift — the go-to-coordinate field, with a results dropdown.
//
//  Phase 1: coordinate go-to works now (decimal or DMS lat/lon → recenter).
//  Feature / place-name search is scaffolded and clearly marked "coming soon" —
//  it needs a name/feature index in tile57 and a matching `lookout_*` query
//  (out of Phase-1 scope). We never fake results. Platform-neutral.
//
//  The field is a 320×48 white capsule, as in the WinUI 3 shell. The search
//  bubble opens it. The results show below it.

import SwiftUI

struct SearchField: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    private var parsedCoord: (lat: Double, lon: Double)? {
        CoordinateParser.parse(model.searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Go to coordinate  (e.g. 38.978, -76.492)", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Chrome.ink)
                    .focused($focused)
                    .onSubmit { _ = model.submitSearch() }
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Chrome.muted)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 18)
            .frame(width: 320, height: Chrome.bubble)
            .background(Chrome.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Chrome.edge.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)

            if focused && !model.searchText.isEmpty {
                results
                    .frame(width: 320, alignment: .leading)
                    .panelSurface()
            }
        }
        // The chrome is white in every appearance. Without this, the system
        // draws the placeholder, the caret and the selection for a dark
        // background, and the placeholder is invisible on the white field.
        .onAppear { focused = true }
    }

    @ViewBuilder private var results: some View {
        if let c = parsedCoord {
            Button {
                _ = model.submitSearch(); focused = false
            } label: {
                Label {
                    Text("Go to \(CoordFormat.position(lat: c.lat, lon: c.lon))")
                        .font(.system(size: 13))
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                }
                .foregroundStyle(Chrome.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            // Feature / place-name search — deferred (needs a tile57 name index).
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle").foregroundStyle(Chrome.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Feature & place search")
                        .font(.system(size: 13))
                        .foregroundStyle(Chrome.ink)
                    Text("Coming soon. Needs a chart name index.")
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }
}
