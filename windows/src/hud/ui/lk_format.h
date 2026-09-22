/* lk_format: the chrome palette, and brushes for chrome built in code.
 *
 * What the readouts SAY is the core's format kit (lookout-shell.h). This is
 * what they are drawn in.
 */
#pragma once

#include <winrt/base.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.h>

namespace lkw
{
    /* A solid brush from 0xAARRGGBB, for chrome built in code. */
    winrt::Microsoft::UI::Xaml::Media::SolidColorBrush Brush(uint32_t argb);

    /* The colour itself, for the few places that tint one before drawing it
     * (a pill's fill is its ink at 18 %). */
    winrt::Windows::UI::Color Rgb(uint32_t argb);

    /* `c` at `alpha` of its opacity: how every pill in this shell gets its
     * fill from its own ink. */
    winrt::Windows::UI::Color WithAlpha(winrt::Windows::UI::Color c, double alpha);

    /* The light-theme chrome literals the markup uses, for code-built chrome
     * (the shared palette every shell carries: see Chrome.swift). */
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
        /* The hairline a card draws its own edges with: the chrome ink at 20
         * per cent. LkHairlineBrush in the markup holds the same pair. */
        constexpr uint32_t Hairline(bool dark) { return dark ? 0x33FFFFFFu : 0x33000000u; }
        /* A control drawn on a card: its resting fill, the fill under the
         * pointer and the fill while it is pressed. Chrome.surface in the
         * reference. */
        constexpr uint32_t Surface(bool dark) { return dark ? 0xFF16181Cu : 0xFFFFFFFFu; }
        constexpr uint32_t SurfaceOver(bool dark) { return dark ? 0xFF1E2126u : 0xFFF2F2F2u; }
        constexpr uint32_t SurfaceDown(bool dark) { return dark ? 0xFF23272Du : 0xFFE9E9E9u; }
        /* The card a step or a panel stands on, at 95 per cent. LkCardBrush
         * and the setup fade hold the same pair. */
        constexpr uint32_t Panel(bool dark) { return dark ? 0xF2121C24u : 0xF2F8F8F8u; }
        /* A badge over a drawing, at 92 per cent, so the chart shows through
         * it faintly. */
        constexpr uint32_t Badge(bool dark) { return dark ? 0xEB202428u : 0xEBF8F8F8u; }
    }

}
