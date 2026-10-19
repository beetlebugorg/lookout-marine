// Setup's shared parts: the brushes, the prose blocks, the pickable cards and
// the palette lookups the steps are built from. FirstRunParts.cpp defines
// them. Every setup file reads them through `using namespace lkw::setup`.
#pragma once

#include <winrt/Microsoft.UI.Xaml.Documents.h>

#include <string>

#include "lk_chrome.h"
#include "lk_controller.h"
#include "lk_firstrun.h"
#include "lk_format.h"

namespace lkw::setup
{
    using namespace winrt;
    using namespace winrt::Microsoft::UI::Xaml;
    using namespace winrt::Microsoft::UI::Xaml::Controls;
    using namespace winrt::Microsoft::UI::Xaml::Documents;
    using namespace winrt::Microsoft::UI::Xaml::Media;

    // NOAA's agreement itself. The paragraph beside it summarizes it.
    inline constexpr wchar_t kEncAgreement[] =
        L"https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml";

    // Text inherits its colour, and muted text is that colour at 70%. The Lk*
    // brushes live in Root's resources rather than the application's, and they
    // are theme dictionaries, so a code-side Lookup of one throws. Settings has
    // the same need and uses Opacity for it.
    using lkw::Line;
    using lkw::Muted;

    using lkw::SizeText;
    using lkw::Thousands;

    // The accent, from the palette both this file and the settings pane
    // read (lkw::chrome::Accent), which is the LkAccentBrush pair from
    // MainWindow.xaml kept in step with it by hand.
    inline Windows::UI::Color AccentColor(bool dark) { return lkw::Rgb(lkw::chrome::Accent(dark)); }
    inline SolidColorBrush AccentBrush(bool dark) { return SolidColorBrush{ AccentColor(dark) }; }
    SolidColorBrush HairlineBrush(bool dark);

    StackPanel Heading(std::wstring const &title, std::wstring const &blurb);
    StackPanel Fact(wchar_t const *glyph, std::wstring const &title, std::wstring const &blurb,
                    bool dark);
    Border WarningPanel(std::wstring const &heading, std::wstring const &body);
    TextBlock LinkLine(std::wstring const &text, std::wstring const &url);

    inline constexpr double kSeabedW = 286;
    inline constexpr double kSeabedH = 210;

    void PaintPicked(Button const &b, bool on, bool dark);

    Button RegionPill(std::wstring const &name, std::wstring const &blurb,
                      lkw::RegionHold const &hold, bool on, bool enabled, bool dark);
    Button ChoiceCard(wchar_t const *glyph, std::wstring const &title, std::wstring const &blurb,
                      bool picked, bool recommended, bool dark);
}
