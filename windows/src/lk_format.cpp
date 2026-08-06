#include "pch.h"
#include "lk_format.h"

#include <cmath>

namespace lkw
{
    winrt::Microsoft::UI::Xaml::Media::SolidColorBrush Brush(uint32_t argb)
    {
        winrt::Windows::UI::Color c{ (uint8_t)(argb >> 24), (uint8_t)(argb >> 16),
                                     (uint8_t)(argb >> 8), (uint8_t)argb };
        return winrt::Microsoft::UI::Xaml::Media::SolidColorBrush{ c };
    }

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

    // Degrees, minutes and seconds with a hemisphere. The longitude has three
    // degree digits, so a pair keeps its column width.
    static void SplitDMS(double value, int *deg, int *min, double *sec)
    {
        double a = std::abs(value);
        *deg = (int)a;
        *min = (int)((a - *deg) * 60.0);
        *sec = ((a - *deg) * 60.0 - *min) * 60.0;
        // Carry the rounding. 59.96" prints as 60.0", which is the next minute.
        if (std::llround(*sec * 10.0) >= 600) { *sec = 0.0; (*min)++; }
        if (*min >= 60) { *min = 0; (*deg)++; }
    }

    winrt::hstring FormatCoord(double lat, double lon)
    {
        int lat_d, lat_m, lon_d, lon_m;
        double lat_s, lon_s;
        SplitDMS(lat, &lat_d, &lat_m, &lat_s);
        SplitDMS(lon, &lon_d, &lon_m, &lon_s);
        wchar_t buf[64];
        // Degrees and DECIMAL MINUTES: what a GPS shows, what goes in the log,
        // and what is passed over the radio. One minute of latitude is one
        // nautical mile, so a decimal minute reads as distance directly.
        swprintf_s(buf, L"%02d\x00B0%06.3f'%c %03d\x00B0%06.3f'%c",
                   lat_d, lat_m + lat_s / 60.0, lat < 0 ? L'S' : L'N',
                   lon_d, lon_m + lon_s / 60.0, lon < 0 ? L'W' : L'E');
        return buf;
    }
}
