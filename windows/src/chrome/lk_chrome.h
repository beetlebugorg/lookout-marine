/* lk_chrome: the chrome every pane of this shell is built from.
 *
 * The palette and the brushes are lk_format's. What is here is the chrome
 * itself: a line of text, a card, the fills a button wears in each of its
 * states, and the pictures shipped beside the executable. Each of these had a
 * copy in the file that first needed it.
 */
#pragma once

#include <cstdint>
#include <string>

#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Media.Imaging.h>
#include <winrt/Microsoft.UI.Xaml.h>

struct lk_controller;

namespace lkw
{
    /* One line of text at a size, wrapped. `strong` is a heading or a figure a
     * mariner reads first. */
    winrt::Microsoft::UI::Xaml::Controls::TextBlock Line(std::wstring const &text, double size,
                                                         bool strong = false);
    /* The same line, at the opacity a caption reads at. */
    winrt::Microsoft::UI::Xaml::Controls::TextBlock Muted(std::wstring const &text,
                                                          double size = 12.5);

    /* The card a section stands on: a rounded border, a hairline edge and the
     * ink of the scheme at a low alpha. */
    winrt::Microsoft::UI::Xaml::Controls::Border Card(bool dark);

    /* An opaque colour from 0xRRGGBB, for the palette tables the chart's
     * schemes are drawn from. */
    winrt::Windows::UI::Color Hex(uint32_t v);

    /* A colour from the core's palette (lookout_s52_color) in `scheme`, by S-52
     * token or by the core's BAND1 to BAND6, at `alpha`. Grey for a token the
     * palette lacks. */
    winrt::Windows::UI::Color S52(char const *token, uint32_t scheme, uint8_t alpha = 0xFF);
    /* The scheme the chart draws in, 0 day, 1 dusk, 2 night. */
    uint32_t SchemeOf(::lk_controller *c);

    /* A picture the core drew, as premultiplied RGBA with the top row first,
     * in the premultiplied BGRA a WriteableBitmap holds. */
    winrt::Microsoft::UI::Xaml::Media::Imaging::WriteableBitmap RgbaBitmap(uint8_t const *rgba,
                                                                          int width, int height);

    /* Where the data shipped beside the executable lives: the setup pictures
     * and the coastline. Empty when the path cannot be read. */
    std::string ShippedDataDir();

    /* One picture from that directory, or nullptr when the file is absent. A
     * page reads properly without it, and that is what a launch looks like
     * when a file fails to load. */
    winrt::Microsoft::UI::Xaml::Media::Imaging::BitmapImage ShippedPicture(
        wchar_t const *name);

    /* Pin a button's four background states, and its border in all of them.
     *
     * WinUI animates a button's background between its states over 83 ms
     * (DefaultButtonStyle puts a BrushTransition on the ContentPresenter), and
     * it interpolates the colour. A button left transparent starts that
     * animation at transparent BLACK and ends at the theme's near-white hover
     * fill, #80F9F9F9, so on the way in it passes through a quarter-opaque
     * grey: the highlight goes dark for a moment, then light. Naming the
     * states keeps the fade inside one hue.
     *
     * The fills go in the button's own resources. Its template looks the
     * state brushes up from there, and the resting fill is set on the
     * button as well, so the fade out of hover ends on it. */
    void ButtonFills(winrt::Microsoft::UI::Xaml::Controls::Control const &c, uint32_t flat,
                     uint32_t over, uint32_t down, uint32_t edge);

    /* A button drawn flat against a card: the card's own ink at night, its
     * shadow by day, at a resting, a hovered and a pressed alpha. `edge` is
     * the border it keeps in every state, which a button with no border of its
     * own leaves at zero. */
    void FlatFills(winrt::Microsoft::UI::Xaml::Controls::Control const &c, bool dark,
                   uint32_t edge = 0x00000000u);
}
