//  CalloutPlacement.swift — where the pick report and the floating panels stand.
//
//  Arithmetic on a point and a view size, and nothing else: which body the
//  report takes, where a callout sits and how much room it has, and which way a
//  hover tip or the chart menu flips at an edge. No chart, no view, no state.
//  See PlacementTests.

import SwiftUI

/// The pick report's body for a view size: a callout beside the object on a
/// wide view, a sheet against an edge of a narrow or a short one.
enum PickForm {
    case callout, bottomSheet, sideSheet
}

/// Which edge of the callout is held against the pick mark.
enum CalloutEdge {
    case above   // the card's floor sits over the mark
    case below   // the card's top sits under the mark
}

/// Where a callout stands, and the height it may use.
///
/// `y` is the edge that `edge` names. SwiftUI places the opposite edge, so
/// nothing measures the card to position it. `room` is a hard limit. The card
/// sizes its columns and its scroll area to `room`, so a long report cannot
/// grow over the mark.
struct CalloutPlace {
    let x: CGFloat
    let y: CGFloat
    let edge: CalloutEdge
    let room: CGFloat
}

// Not isolated: none of this touches the view or the model, which is what lets
// a test call it directly.
extension OverlayLayer {
    /// Below this width the capsule and the corner chrome cannot share the
    /// bottom row, and the pick report becomes a bottom sheet. OverlayLayer
    /// reads it to lay the chrome out compact.
    static let compactWidth: CGFloat = 700
    /// Below this height there is no room for a callout over a chart: a phone
    /// on its side. The report holds the leading edge instead.
    static let shortHeight: CGFloat = 520
    /// The bottom band the HUD capsule owns: its height and a margin each side.
    static let hudBand = Chrome.margin * 2 + Chrome.capsule

    static func pickForm(for size: CGSize) -> PickForm {
        if size.width < compactWidth { return .bottomSheet }
        if size.height < shortHeight { return .sideSheet }
        return .callout
    }

    /// Put the callout over the pick. The card is centred on the mark and its
    /// floor stops clear of it.
    ///
    /// The card gets the room between the mark and the margin. A long report
    /// scrolls in that room. The card goes under the mark only when the room
    /// above is too small to read a report in.
    static func calloutLayout(point: CGPoint, width: CGFloat, in view: CGSize) -> CalloutPlace {
        let clear = PickMarker.size / 2 + 6
        let minX = Chrome.margin
        let maxX = max(minX, view.width - Chrome.margin - width)
        // The free area's floor. The card stops here; the HUD owns the rest.
        let floor = max(Chrome.margin, view.height - Self.hudBand)
        let x = min(max(point.x - width / 2, minX), maxX)

        let over = (point.y - clear) - Chrome.margin
        let under = floor - (point.y + clear)
        // Use the space above unless it is too small and the space below is
        // larger.
        if over >= 200 || over >= under {
            return CalloutPlace(x: x, y: point.y - clear, edge: .above, room: max(0, over))
        }
        return CalloutPlace(x: x, y: point.y + clear, edge: .below, room: max(0, under))
    }

    /// Where the hover tooltip stands. The tip sits below and right of the
    /// pointer, and flips to the other side of whichever edge it would cross.
    /// The card is never measured: it holds two edges and SwiftUI sizes it.
    struct HoverPlace {
        let alignment: Alignment
        let leading: CGFloat
        let trailing: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    static func hoverLayout(point: CGPoint, in view: CGSize) -> HoverPlace {
        let gap: CGFloat = 14
        let flipX = point.x + gap + HoverTip.maxWidth > view.width - Chrome.margin
        let flipY = point.y + gap + HoverTip.assumedHeight > view.height - Chrome.margin
        return HoverPlace(
            alignment: Alignment(horizontal: flipX ? .trailing : .leading,
                                 vertical: flipY ? .bottom : .top),
            leading: flipX ? 0 : point.x + gap,
            trailing: flipX ? max(0, view.width - point.x + gap) : 0,
            top: flipY ? 0 : point.y + gap,
            bottom: flipY ? max(0, view.height - point.y + gap) : 0)
    }

    /// Where the chart menu stands: down and right of the press, flipped at
    /// whichever edge it would cross. Like the hover tip, the panel is never
    /// measured: it holds two edges and SwiftUI sizes it.
    static func menuLayout(point: CGPoint, in view: CGSize, hasMarker: Bool) -> HoverPlace {
        let gap: CGFloat = 2
        let flipX = point.x + gap + ChartMenuPanel.width > view.width - Chrome.margin
        let flipY = point.y + gap + ChartMenuPanel.assumedHeight(hasMarker: hasMarker)
            > view.height - Chrome.margin
        return HoverPlace(
            alignment: Alignment(horizontal: flipX ? .trailing : .leading,
                                 vertical: flipY ? .bottom : .top),
            leading: flipX ? 0 : point.x + gap,
            trailing: flipX ? max(0, view.width - point.x + gap) : 0,
            top: flipY ? 0 : point.y + gap,
            bottom: flipY ? max(0, view.height - point.y + gap) : 0)
    }

    static func bottomSheetSize(in view: CGSize) -> CGSize {
        // The chart keeps the larger part of the view.
        CGSize(width: view.width, height: min(340, (view.height * 0.48).rounded(.down)))
    }
    static let sideSheetWidth: CGFloat = 360
}
