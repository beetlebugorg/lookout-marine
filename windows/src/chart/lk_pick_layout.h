/* lk_pick_layout — where the pick report card stands.
 *
 * The card is a CALLOUT: it belongs to the point the mariner tapped, so it
 * has to sit clear of the mark, inside the view, above the readouts, and it
 * must not jump around as the selection changes. That is arithmetic, and
 * arithmetic that is wrong by a few points puts a report over the water the
 * report is about — so it lives here with a test rather than inside the
 * layout code.
 *
 * The same numbers as OverlayLayer.calloutLayout (macOS) and
 * calloutPlacement (Android). The card itself is chart/ui/Pick.cpp.
 */
#pragma once

namespace lkw
{
    /* The marker drawn at the picked point; the card stops clear of it. */
    inline constexpr double kMarkerSize = 34.0;
    /* The detail column, and the object list beside it past one object. */
    inline constexpr double kDetailWidth = 430.0;
    inline constexpr double kListWidth = 200.0;

    struct PickPlacement
    {
        double width{ 0 };      /* the card's width */
        double x{ 0 };          /* its left edge in the view */
        bool above{ true };     /* above the mark, or below it */
        double room{ 0 };       /* the height it may not exceed, and scrolls inside */
        double min_height{ 0 }; /* the height floor, re-capped by `room` */
        /* The margin on the edge the card is aligned to: the bottom margin
         * when it stands above the mark, the top margin when below. Both stop
         * clear of the marker. */
        double edge_gap{ 0 };
    };

    /* `view_w`/`view_h` are the chart view in logical points, `mark_x`/`mark_y`
     * the picked point in the same space, `count` how many objects the pick
     * found, and `height_floor` the tallest this card has stood for THIS pick
     * — it never shrinks below that, so the controls and the chart under the
     * pointer do not move as the selection changes. */
    PickPlacement PlacePick(double view_w, double view_h, double mark_x, double mark_y,
                            int count, double height_floor);
}
