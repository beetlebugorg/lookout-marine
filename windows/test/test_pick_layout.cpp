/* Where the pick report card stands.
 *
 * The card belongs to the point the mariner tapped. It has to stay clear of
 * the mark, inside the view, and above the readouts — and it must not move
 * as the selection changes underneath it, because a mariner reading one row
 * of a report should not have the next row arrive where their eye already is.
 */
#include "lk_test.h"

#include "lk_pick_layout.h"

using namespace lktest;
using namespace lkw;

namespace
{
    /* A comfortable window, and a mark in the middle of it. */
    constexpr double kW = 1400;
    constexpr double kH = 900;
}

void TestPickLayout()
{
    Suite("lk_pick_layout: the width");

    LK_CASE("one object is the detail column; several add the list beside it");
    {
        LK_NEAR(PlacePick(kW, kH, 700, 450, 1, 0).width, kDetailWidth, 0);
        LK_NEAR(PlacePick(kW, kH, 700, 450, 4, 0).width, kDetailWidth + kListWidth, 0);
    }

    LK_CASE("a narrow view takes what it can spare, down to a floor");
    {
        /* Narrower than the card wants: it gives up its margins first... */
        double narrow = PlacePick(500, kH, 250, 450, 4, 0).width;
        LK_CHECK(narrow < kDetailWidth + kListWidth);
        LK_NEAR(narrow, 500 - 24, 0);
        /* ...and then stops, rather than shrinking to nothing. */
        LK_NEAR(PlacePick(120, kH, 60, 450, 1, 0).width, 280, 0);
    }

    Suite("lk_pick_layout: staying in the view");

    LK_CASE("centred on the mark when there is room either side");
    {
        auto at = PlacePick(kW, kH, 700, 450, 1, 0);
        LK_NEAR(at.x + at.width / 2, 700, 1e-9);
    }

    LK_CASE("held inside the view at both edges");
    {
        auto left = PlacePick(kW, kH, 10, 450, 1, 0);
        LK_NEAR(left.x, 12, 0); /* the margin, not off the edge */

        auto right = PlacePick(kW, kH, kW - 10, 450, 1, 0);
        LK_NEAR(right.x + right.width, kW - 12, 1e-9);
    }

    /* A view narrower than the card: the clamp's own bounds would otherwise
     * cross, and std::clamp on crossed bounds is undefined. */
    LK_CASE("a view narrower than the card still places it");
    {
        auto at = PlacePick(100, kH, 50, 450, 4, 0);
        LK_NEAR(at.x, 12, 0);
        LK_CHECK(at.width > 0);
    }

    Suite("lk_pick_layout: above or below");

    /* Enough room above wins outright, even when there is more below: a
     * callout that flips sides as the card grows is worse than a shorter one
     * that stays put. */
    LK_CASE("above when there is room above");
    {
        LK_EQ(PlacePick(kW, kH, 700, 450, 1, 0).above, true);
        LK_EQ(PlacePick(kW, kH, 700, 260, 1, 0).above, true); /* 200 pt is enough */
    }

    LK_CASE("below when there is not");
    {
        auto at = PlacePick(kW, kH, 700, 40, 1, 0);
        LK_EQ(at.above, false);
        LK_CHECK(at.room > 0);
    }

    LK_CASE("a mark at the very top goes below, at the very bottom goes above");
    {
        LK_EQ(PlacePick(kW, kH, 700, 0, 1, 0).above, false);
        LK_EQ(PlacePick(kW, kH, 700, kH, 1, 0).above, true);
    }

    /* The readouts capsule owns the bottom of the view: the card's floor is
     * the top of that band, not the bottom of the window. */
    LK_CASE("the room below stops at the readouts, not at the window");
    {
        auto at = PlacePick(kW, kH, 700, 100, 1, 0);
        LK_EQ(at.above, false);
        /* floor is kH - 76; the card starts 23 below the mark. */
        LK_NEAR(at.room, (kH - 76) - (100 + 23), 1e-9);
    }

    LK_CASE("the card always has some room, however cramped");
    {
        LK_CHECK(PlacePick(kW, 120, 700, 60, 1, 0).room >= 48);
        LK_CHECK(PlacePick(kW, 40, 700, 20, 1, 0).room >= 48);
    }

    Suite("lk_pick_layout: the gap to the mark");

    LK_CASE("the card stops clear of the marker on whichever side it is");
    {
        auto above = PlacePick(kW, kH, 700, 450, 1, 0);
        /* Aligned to the bottom: the margin is measured from the view's foot,
         * and the card's own bottom edge lands 23 above the mark. */
        LK_NEAR(kH - above.edge_gap, 450 - 23, 1e-9);

        auto below = PlacePick(kW, kH, 700, 40, 1, 0);
        LK_NEAR(below.edge_gap, 40 + 23, 1e-9);
    }

    Suite("lk_pick_layout: the height floor");

    /* The card keeps the tallest height it has stood at for this pick, so the
     * controls and the chart under the pointer do not move as the selection
     * changes. */
    LK_CASE("the floor is carried");
    {
        LK_NEAR(PlacePick(kW, kH, 700, 450, 1, 300).min_height, 300, 0);
    }

    /* But a resize that leaves less room must not keep a taller card than the
     * room can hold. */
    LK_CASE("the floor is re-capped by the room");
    {
        auto at = PlacePick(kW, 300, 700, 150, 1, 800);
        LK_NEAR(at.min_height, at.room, 1e-9);
        LK_CHECK(at.min_height < 800);
    }

    LK_CASE("a new pick starts with no floor");
    {
        LK_NEAR(PlacePick(kW, kH, 700, 450, 1, 0).min_height, 0, 0);
    }
}
