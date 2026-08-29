/* lk_text — what the readouts say.
 *
 * The scale, the usage band and the position: the three things on the HUD a
 * mariner reads off, writes in the deck log and passes over the radio. Every
 * shell says them the same way, so they are worth one place and a test.
 *
 * Model code — UTF-8 std::string, no WinRT. The capsule that draws them is
 * hud/Hud.cpp, and the brushes it draws them in are lk_format.h.
 */
#pragma once

#include <string>

namespace lkw
{
    /* "1:12,700"; "1:—" for no scale. */
    std::string FormatScale(double denom);

    /* S-57 usage band by compilation scale ("Harbor", "Coastal", …). */
    char const *BandForDenom(double denom);

    /* Degrees and DECIMAL MINUTES with hemispheres: "38°58.802'N 076°28.920'W".
     *
     * Not degrees-minutes-seconds, whatever a chart's margin says: this is
     * what a GPS shows, what goes in the log and what is passed over the
     * radio. One minute of latitude is one nautical mile, so a decimal minute
     * reads as a distance directly. The longitude carries three degree digits
     * so a pair keeps its column width. */
    std::string FormatCoord(double lat, double lon);
}
