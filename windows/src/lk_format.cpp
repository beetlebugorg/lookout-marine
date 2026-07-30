#include "pch.h"
#include "lk_format.h"

#include <cmath>

namespace lkw
{
    winrt::hstring FormatScale(double denom)
    {
        if (denom <= 0)
            return L"1:—";
        wchar_t raw[24], out[32];
        swprintf_s(raw, L"%d", (int)std::llround(denom));
        int len = (int)wcslen(raw), o = 0;
        for (int i = 0; i < len; ++i)
        {
            if (i > 0 && (len - i) % 3 == 0)
                out[o++] = L',';
            out[o++] = raw[i];
        }
        out[o] = 0;
        return winrt::hstring{ L"1:" } + out;
    }

    wchar_t const *BandForDenom(double denom)
    {
        if (denom <= 0) return L"—";
        if (denom < 5000) return L"Berthing";
        if (denom < 25000) return L"Harbor";
        if (denom < 75000) return L"Approach";
        if (denom < 300000) return L"Coastal";
        if (denom < 1500000) return L"General";
        return L"Overview";
    }

    winrt::hstring FormatCoord(double lat, double lon, bool dms)
    {
        wchar_t buf[64];
        if (dms)
        {
            double alat = std::abs(lat), alon = std::abs(lon);
            swprintf_s(buf, L"%d\x00B0%04.1f'%c %03d\x00B0%04.1f'%c",
                       (int)alat, (alat - (int)alat) * 60.0, lat < 0 ? L'S' : L'N',
                       (int)alon, (alon - (int)alon) * 60.0, lon < 0 ? L'W' : L'E');
            return buf;
        }
        swprintf_s(buf, L"%.5f, %.5f", lat, lon);
        return buf;
    }
}
