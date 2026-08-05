/* lk_format — HUD readout formatting and the code-built chrome palette. */
#pragma once

#include <winrt/base.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>

namespace lkw
{
    /* "1:12,700"; "1:—" for no scale. */
    winrt::hstring FormatScale(double denom);
    /* S-57 usage band by compilation scale ("Harbor", "Coastal", …). */
    wchar_t const *BandForDenom(double denom);
    /* Degrees, minutes and seconds: 38°58'34.8"N 076°28'55.2"W. */
    winrt::hstring FormatCoord(double lat, double lon);

    /* A solid brush from 0xAARRGGBB, for chrome built in code. */
    winrt::Microsoft::UI::Xaml::Media::SolidColorBrush Brush(uint32_t argb);

    /* The light-theme chrome literals MainWindow.xaml uses, for code-built
     * chrome (the shared palette every shell carries — see Chrome.swift). */
    namespace chrome
    {
        constexpr uint32_t kInk = 0xFF1A1A1A;
        constexpr uint32_t kMuted = 0xFF6B6B6B;
        constexpr uint32_t kAccent = 0xFF1B49C4;
        constexpr uint32_t kAccentFill = 0x1F1B49C4; /* 12 % accent (selection) */
        constexpr uint32_t kAmber = 0xFFF59E0B;
        constexpr uint32_t kAmberFill = 0x1FF59E0B;  /* 12 % amber (note callout) */
        constexpr uint32_t kAmberEdge = 0x66F59E0B;  /* 40 % amber */
        constexpr uint32_t kRule = 0xFFDDDDDD;
        constexpr uint32_t kClear = 0x00000000;
    }
}
