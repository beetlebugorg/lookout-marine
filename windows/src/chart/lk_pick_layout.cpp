/* lk_pick_layout — see lk_pick_layout.h. */
#include "lk_pick_layout.h"

#include <algorithm>

namespace lkw
{
    namespace
    {
        constexpr double kPickMargin = 12.0;
        /* The card's edge stops this clear of the mark, either side of it. */
        constexpr double kMarkClear = kMarkerSize / 2 + 6;
        /* The readouts capsule owns the bottom of the view; the card's floor
         * is the top of that band, not the bottom of the window. */
        constexpr double kHudBand = 44 + 16 * 2;
        constexpr double kMinWidth = 280.0;
        /* Enough room above wins outright, even when there is more below: a
         * callout that flips sides as the card grows is worse than a shorter
         * one that stays put. */
        constexpr double kPreferAbove = 200.0;
        /* Under this there is no report worth showing, so the card is capped
         * at it rather than at nothing. */
        constexpr double kMinRoom = 48.0;
    }

    PickPlacement PlacePick(double view_w, double view_h, double mark_x, double mark_y,
                            int count, double height_floor)
    {
        PickPlacement out;

        double want = kDetailWidth + (count > 1 ? kListWidth : 0.0);
        out.width = std::min(want, std::max(kMinWidth, view_w - 2 * kPickMargin));

        /* Centred on the mark, then held inside the view. The max() guards a
         * view narrower than the card: the clamp's own bounds must not cross. */
        out.x = std::clamp(mark_x - out.width / 2, kPickMargin,
                           std::max(kPickMargin, view_w - kPickMargin - out.width));

        double floor_y = std::max(kPickMargin, view_h - kHudBand);
        double over = (mark_y - kMarkClear) - kPickMargin;
        double under = floor_y - (mark_y + kMarkClear);
        out.above = over >= kPreferAbove || over >= under;
        out.room = std::max(kMinRoom, out.above ? over : under);

        /* The floor never carries past the room: a resize that leaves less
         * room must not keep a taller card than the room can hold. */
        out.min_height = std::min(height_floor, out.room);

        out.edge_gap = out.above ? view_h - (mark_y - kMarkClear) : mark_y + kMarkClear;
        return out;
    }
}
