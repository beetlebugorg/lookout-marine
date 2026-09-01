/* lk_format — the chrome palette, and brushes for chrome built in code.
 *
 * What the readouts SAY is the core's format kit (lookout-shell.h). This is
 * what they are drawn in.
 */
#pragma once

#include <winrt/base.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>

namespace lkw
{
    /* A solid brush from 0xAARRGGBB, for chrome built in code. */
    winrt::Microsoft::UI::Xaml::Media::SolidColorBrush Brush(uint32_t argb);

    /* The colour itself, for the few places that tint one before drawing it
     * (a pill's fill is its ink at 18 %). */
    winrt::Windows::UI::Color Rgb(uint32_t argb);

    /* `c` at `alpha` of its opacity — how every pill in this shell gets its
     * fill from its own ink. */
    winrt::Windows::UI::Color WithAlpha(winrt::Windows::UI::Color c, double alpha);

    /* The light-theme chrome literals the markup uses, for code-built chrome
     * (the shared palette every shell carries — see Chrome.swift). */
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

        /* Theme-aware picks: the chrome wears the chart's scheme (the XAML
         * ThemeDictionaries), and code-built cards resolve at build time from
         * the element they fill (ActualTheme == Dark). Amber stays amber at
         * night to mean anything; the accent lightens to read on dark. */
        constexpr uint32_t Ink(bool dark) { return dark ? 0xFFDDE4EAu : kInk; }
        constexpr uint32_t Muted(bool dark) { return dark ? 0xFF9FB0BDu : kMuted; }
        constexpr uint32_t Accent(bool dark) { return dark ? 0xFF7EA1F5u : kAccent; }
        constexpr uint32_t AccentFill(bool dark) { return dark ? 0x1F7EA1F5u : kAccentFill; }
        constexpr uint32_t Rule(bool dark) { return dark ? 0xFF33414Du : kRule; }
    }
}
