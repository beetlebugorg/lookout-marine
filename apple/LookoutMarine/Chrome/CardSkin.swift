//  CardSkin.swift: the border and fill of a card that can be chosen.

import SwiftUI

/// The chosen card's 2pt accent border and tinted fill, or the plain one.
struct CardSkin: ViewModifier {
    let picked: Bool
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(picked ? Chrome.accent.opacity(0.05) : Chrome.surface, in: shape)
            // Clipped to the card. A card whose content draws to its own edge,
            // a picture filling the top of a chart tile among them, ran past
            // the corners and over the card beside it.
            .clipShape(shape)
            .overlay(shape.strokeBorder(picked ? Chrome.accent : Chrome.edge.opacity(0.7),
                                        lineWidth: picked ? 2 : 1))
            .contentShape(shape)
    }
}
