/* What the readouts say.
 *
 * The scale, the band and the position: what a mariner reads off the HUD,
 * writes in the deck log and passes over the radio. A wrong carry here puts
 * sixty minutes in a log, and a wrong band puts a harbour chart in the coastal
 * column.
 */
#include "lk_test.h"

#include "lk_text.h"

using namespace lktest;
using namespace lkw;

namespace
{
    /* Spelled out rather than written into the expectations: a \xb0 escape
     * runs straight into the digit that follows it. */
    std::string const kDeg = "\xc2\xb0";      /* U+00B0 DEGREE SIGN */
    std::string const kDash = "\xe2\x80\x94"; /* U+2014 EM DASH */
}

void TestText()
{
    Suite("lk_text: the scale");

    LK_CASE("thousands separators, as a chart's margin prints them");
    {
        LK_EQ(FormatScale(1), std::string("1:1"));
        LK_EQ(FormatScale(999), std::string("1:999"));
        LK_EQ(FormatScale(1000), std::string("1:1,000"));
        LK_EQ(FormatScale(12700), std::string("1:12,700"));
        LK_EQ(FormatScale(999999), std::string("1:999,999"));
        LK_EQ(FormatScale(1000000), std::string("1:1,000,000"));
        LK_EQ(FormatScale(22000000), std::string("1:22,000,000"));
    }

    LK_CASE("it rounds rather than truncating");
    {
        LK_EQ(FormatScale(12700.4), std::string("1:12,700"));
        LK_EQ(FormatScale(12700.6), std::string("1:12,701"));
    }

    /* With no chart open there is no scale to state, and "1:0" would be a
     * statement. */
    LK_CASE("no scale says so");
    {
        LK_EQ(FormatScale(0), "1:" + kDash);
        LK_EQ(FormatScale(-1), "1:" + kDash);
    }

    Suite("lk_text: the usage band");

    LK_CASE("the S-52 bands, at their boundaries");
    {
        LK_EQ(BandForDenom(4999), std::string("Berthing"));
        LK_EQ(BandForDenom(5000), std::string("Harbor"));
        LK_EQ(BandForDenom(24999), std::string("Harbor"));
        LK_EQ(BandForDenom(25000), std::string("Approach"));
        LK_EQ(BandForDenom(74999), std::string("Approach"));
        LK_EQ(BandForDenom(75000), std::string("Coastal"));
        LK_EQ(BandForDenom(299999), std::string("Coastal"));
        LK_EQ(BandForDenom(300000), std::string("General"));
        LK_EQ(BandForDenom(1499999), std::string("General"));
        LK_EQ(BandForDenom(1500000), std::string("Overview"));
        LK_EQ(BandForDenom(0), kDash);
    }

    Suite("lk_text: the position");

    /* Degrees and DECIMAL MINUTES — what a GPS shows and what goes over the
     * radio. One minute of latitude is one nautical mile. */
    LK_CASE("degrees and decimal minutes, with hemispheres");
    {
        LK_EQ(FormatCoord(38.98, -76.4833), "38" + kDeg + "58.800'N 076" + kDeg + "28.998'W");
        LK_EQ(FormatCoord(0, 0), "00" + kDeg + "00.000'N 000" + kDeg + "00.000'E");
    }

    LK_CASE("the southern and western hemispheres");
    {
        LK_EQ(FormatCoord(-33.86, 151.21), "33" + kDeg + "51.600'S 151" + kDeg + "12.600'E");
        LK_EQ(FormatCoord(-0.5, -0.5), "00" + kDeg + "30.000'S 000" + kDeg + "30.000'W");
    }

    /* The longitude keeps three degree digits so a pair keeps its column
     * width, and the latitude two. */
    LK_CASE("the columns do not move");
    {
        LK_EQ(FormatCoord(9.5, 9.5).size(), FormatCoord(89.5, 179.5).size());
    }

    /* Without the carry a readout says sixty minutes, which is not a place. */
    LK_CASE("the rounding carries into the minute and the degree");
    {
        /* The latitude is 12 bytes ("38", the two of the degree sign, "58.800",
         * "'" and the hemisphere), then a space. */
        LK_EQ(FormatCoord(38.9999999, 0).substr(0, 12), "39" + kDeg + "00.000'N");
        LK_EQ(FormatCoord(0, -179.9999999).substr(13), "180" + kDeg + "00.000'W");
    }

    LK_CASE("the poles and the antimeridian");
    {
        LK_EQ(FormatCoord(90, 180), "90" + kDeg + "00.000'N 180" + kDeg + "00.000'E");
        LK_EQ(FormatCoord(-90, -180), "90" + kDeg + "00.000'S 180" + kDeg + "00.000'W");
    }
}
