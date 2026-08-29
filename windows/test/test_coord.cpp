/* The coordinate go-to parser and the chart-scale parser: what a mariner may
 * type into the search field and into the zoom-to-scale panel.
 *
 * Both are gates in front of the engine. The coordinate parser must refuse
 * anything that is not a place — the envelope check exists because "999 N
 * 999 E" reaching lookout_set_view is a camera nobody can get back from — and
 * the scale parser must take every form the header promises, because a
 * mariner reads "1:25,000" off a chart and types what they read. */
#include "lk_test.h"

extern "C" {
#include "lk_coord.h"
}

using namespace lktest;

namespace
{
    /* The parser's out params are written only on success, so they start at a
     * value no real coordinate has. */
    struct Parsed
    {
        double lat{ 999 };
        double lon{ 999 };
        int ok{ -1 };
    };

    Parsed Coord(char const *text)
    {
        Parsed p;
        p.ok = lk_coord_parse(text, &p.lat, &p.lon);
        return p;
    }

    double Scale(char const *text, int *ok)
    {
        double denom = -1;
        *ok = lk_scale_parse(text, &denom);
        return denom;
    }
}

void TestCoord()
{
    Suite("lk_coord");

    LK_CASE("a decimal pair, latitude first");
    {
        auto p = Coord("38.978, -76.492");
        LK_EQ(p.ok, 1);
        LK_NEAR(p.lat, 38.978, 1e-9);
        LK_NEAR(p.lon, -76.492, 1e-9);
    }

    LK_CASE("whitespace separates a decimal pair as well as a comma");
    {
        auto p = Coord("38.978 -76.492");
        LK_EQ(p.ok, 1);
        LK_NEAR(p.lat, 38.978, 1e-9);
        LK_NEAR(p.lon, -76.492, 1e-9);
    }

    LK_CASE("leading space is trimmed");
    {
        auto p = Coord("   38.978, -76.492");
        LK_EQ(p.ok, 1);
        LK_NEAR(p.lat, 38.978, 1e-9);
    }

    LK_CASE("a token that is not purely a number is not a coordinate");
    {
        LK_EQ(Coord("38.978x, -76.492").ok, 0);
        LK_EQ(Coord("Annapolis").ok, 0);
        LK_EQ(Coord("").ok, 0);
        LK_EQ(Coord("   ").ok, 0);
        LK_EQ(Coord("38.978").ok, 0); /* one number is not a pair */
    }

    LK_CASE("a null argument is not a coordinate");
    {
        double lat = 0, lon = 0;
        LK_EQ(lk_coord_parse(nullptr, &lat, &lon), 0);
        LK_EQ(lk_coord_parse("38, -76", nullptr, &lon), 0);
        LK_EQ(lk_coord_parse("38, -76", &lat, nullptr), 0);
    }

    /* The envelope is what the engine must never be handed. */
    LK_CASE("a decimal pair outside the envelope is refused");
    {
        LK_EQ(Coord("91, 0").ok, 0);
        LK_EQ(Coord("-91, 0").ok, 0);
        LK_EQ(Coord("0, 181").ok, 0);
        LK_EQ(Coord("0, -181").ok, 0);
    }

    LK_CASE("the poles and the antimeridian are inside it");
    {
        LK_EQ(Coord("90, 180").ok, 1);
        LK_EQ(Coord("-90, -180").ok, 1);
    }

    LK_CASE("degrees and decimal minutes with hemispheres");
    {
        auto p = Coord("38 58.5N 76 28.9W");
        LK_EQ(p.ok, 1);
        LK_NEAR(p.lat, 38.0 + 58.5 / 60.0, 1e-9);
        LK_NEAR(p.lon, -(76.0 + 28.9 / 60.0), 1e-9);
    }

    LK_CASE("degree, minute and second marks are separators");
    {
        auto p = Coord("38\xc2\xb0" "58.8'N 076\xc2\xb0" "29.0'W");
        LK_EQ(p.ok, 1);
        LK_NEAR(p.lat, 38.0 + 58.8 / 60.0, 1e-9);
        LK_NEAR(p.lon, -(76.0 + 29.0 / 60.0), 1e-9);
    }

    LK_CASE("degrees, minutes AND seconds");
    {
        auto p = Coord("38 58 30N 76 28 54W");
        LK_EQ(p.ok, 1);
        LK_NEAR(p.lat, 38.0 + 58.0 / 60.0 + 30.0 / 3600.0, 1e-9);
        LK_NEAR(p.lon, -(76.0 + 28.0 / 60.0 + 54.0 / 3600.0), 1e-9);
    }

    LK_CASE("degrees alone with a hemisphere");
    {
        auto p = Coord("38N 76W");
        LK_EQ(p.ok, 1);
        LK_NEAR(p.lat, 38.0, 1e-9);
        LK_NEAR(p.lon, -76.0, 1e-9);
    }

    LK_CASE("lowercase hemispheres");
    {
        auto p = Coord("38 58.5n 76 28.9w");
        LK_EQ(p.ok, 1);
        LK_NEAR(p.lat, 38.0 + 58.5 / 60.0, 1e-9);
    }

    LK_CASE("a hemisphere form needs both a latitude and a longitude");
    {
        LK_EQ(Coord("38 58.5N").ok, 0);
        LK_EQ(Coord("76 28.9W").ok, 0);
    }

    LK_CASE("the same envelope holds for the hemisphere form");
    {
        LK_EQ(Coord("999 N 999 E").ok, 0);
        LK_EQ(Coord("91 N 0 E").ok, 0);
    }

    Suite("lk_scale_parse");

    LK_CASE("a bare denominator");
    {
        int ok = 0;
        LK_NEAR(Scale("25000", &ok), 25000, 0);
        LK_EQ(ok, 1);
    }

    LK_CASE("thousands separators are ignored, as read off a chart");
    {
        int ok = 0;
        LK_NEAR(Scale("25,000", &ok), 25000, 0);
        LK_EQ(ok, 1);
    }

    LK_CASE("only what follows the last colon counts");
    {
        int ok = 0;
        LK_NEAR(Scale("1:25000", &ok), 25000, 0);
        LK_EQ(ok, 1);
        LK_NEAR(Scale("1:25,000", &ok), 25000, 0);
        LK_EQ(ok, 1);
    }

    LK_CASE("a k or M suffix multiplies, in either case");
    {
        int ok = 0;
        LK_NEAR(Scale("25k", &ok), 25000, 0);
        LK_EQ(ok, 1);
        LK_NEAR(Scale("25K", &ok), 25000, 0);
        LK_EQ(ok, 1);
        LK_NEAR(Scale("1:2.5M", &ok), 2500000, 0);
        LK_EQ(ok, 1);
        LK_NEAR(Scale("2.5m", &ok), 2500000, 0);
        LK_EQ(ok, 1);
    }

    LK_CASE("whitespace inside the number is ignored");
    {
        int ok = 0;
        LK_NEAR(Scale("  25000  ", &ok), 25000, 0);
        LK_EQ(ok, 1);
    }

    /* A value outside this is not a chart scale, whatever it is. */
    LK_CASE("the range gate");
    {
        int ok = 0;
        Scale("99", &ok);
        LK_EQ(ok, 0);
        Scale("100", &ok);
        LK_EQ(ok, 1);
        Scale("100000000", &ok);
        LK_EQ(ok, 1);
        Scale("100000001", &ok);
        LK_EQ(ok, 0);
        Scale("1e9", &ok);
        LK_EQ(ok, 0);
    }

    LK_CASE("what is not a scale at all");
    {
        int ok = 0;
        Scale("", &ok);
        LK_EQ(ok, 0);
        Scale("1:", &ok);
        LK_EQ(ok, 0);
        Scale("k", &ok);
        LK_EQ(ok, 0);
        Scale("harbour", &ok);
        LK_EQ(ok, 0);
        Scale("25000x", &ok);
        LK_EQ(ok, 0);
        LK_EQ(lk_scale_parse(nullptr, nullptr), 0);
    }
}
