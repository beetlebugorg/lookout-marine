//  ChromeHitRegion.swift — publishing where the controls are.
//
//  SwiftUI draws a control without a backing view, so a bubble and empty space
//  hit-test identically. Both pass-through hosts consult these frames instead.

import SwiftUI

/// platforms need this, because a SwiftUI control has no view of its own and
/// hit-tests as the hosting view, like empty space.
private struct ChromeHitRegion: ViewModifier {
    let id: String
    /// Names this instance in the map, so a dying view with the same id
    /// cannot overwrite or remove the live view's entry.
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Chrome.space)) }) {
                ChromeHitMap.shared.set(id, token: token, $0)
            }
            .onDisappear { ChromeHitMap.shared.remove(id, token: token) }
    }
}
extension View {
    func chromeHitRegion(_ id: String) -> some View { modifier(ChromeHitRegion(id: id)) }
}
