/* lk_format — HUD readout formatting. */
#pragma once

#include <winrt/base.h>

namespace lkw
{
    /* "1:12,700"; "1:—" for no scale. */
    winrt::hstring FormatScale(double denom);
    /* S-57 usage band by compilation scale ("Harbor", "Coastal", …). */
    wchar_t const *BandForDenom(double denom);
    /* Degrees, minutes and seconds: 38°58'34.8"N 076°28'55.2"W. */
    winrt::hstring FormatCoord(double lat, double lon);
}
