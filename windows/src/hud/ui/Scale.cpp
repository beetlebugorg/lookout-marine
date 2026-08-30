// The zoom-to-scale panel: click the HUD's 1:N readout, type a scale or pick
// a band preset. The target is applied as a zoom DELTA about the view centre
// (log2(current/target)), so the engine keeps its zoom limits and easing.
// Mirrors ScaleEntryPanel (HUDOverlay.swift) and ScaleEntryDialog (GoTo.kt).
#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>
#include <cstring>

#include "lk_coord.h"
#include "lk_format.h"
#include "lk_text.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using lkw::Brush;
using namespace lkw::chrome;

namespace
{
    // A mariner picks a purpose, not a number: one preset per S-52 band.
    struct Preset
    {
        wchar_t const *name;
        double denom;
    };
    constexpr Preset kPresets[] = {
        { L"Berthing", 2000 },  { L"Harbor", 12000 },   { L"Approach", 50000 },
        { L"Coastal", 150000 }, { L"General", 700000 },
    };
    constexpr uint32_t kOverscaleRed55 = 0x8CD83B01; // an unparseable entry

    // The accent at the strengths this panel wants it, whichever scheme is on.
    // The presets are BUILT ONCE, at construction, so their sublabel is
    // re-inked by UpdateScalePanel rather than by the build — the panel would
    // otherwise wear the theme the app launched in for the rest of the run.
    constexpr uint32_t Alpha(uint32_t argb, uint32_t a)
    {
        return (a << 24) | (argb & 0x00FFFFFFu);
    }
}

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::WireScale()
    {
        HudScaleBtn().Click([this](auto &&, auto &&) { ToggleScalePanel(); });
        ScaleClose().Click([this](auto &&, auto &&) {
            ScalePanel().Visibility(Visibility::Collapsed);
        });
        ScaleGo().Click([this](auto &&, auto &&) { SubmitScale(); });
        ScaleBox().TextChanged([this](auto &&, auto &&) { UpdateScaleValidity(); });
        ScaleBox().KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() == Windows::System::VirtualKey::Enter)
                SubmitScale();
        });

        // Two rows of band presets, three then two.
        Controls::StackPanel row;
        for (size_t i = 0; i < std::size(kPresets); ++i)
        {
            if (i % 3 == 0)
            {
                row = Controls::StackPanel{};
                row.Orientation(Controls::Orientation::Horizontal);
                row.Spacing(6);
                ScalePresetRows().Children().Append(row);
            }
            Controls::StackPanel text;
            Controls::TextBlock name;
            name.Text(kPresets[i].name);
            name.FontSize(12);
            name.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            name.HorizontalAlignment(HorizontalAlignment::Center);
            text.Children().Append(name);
            Controls::TextBlock value;
            value.Text(to_hstring(lkw::FormatScale(kPresets[i].denom)));
            value.FontSize(11);
            value.Foreground(Brush(Muted(DarkChrome())));
            value.HorizontalAlignment(HorizontalAlignment::Center);
            text.Children().Append(value);
            Controls::Button b;
            b.Content(text);
            b.Padding({ 10, 5, 10, 6 });
            b.CornerRadius({ 10, 10, 10, 10 });
            b.BorderThickness({ 1, 1, 1, 1 });
            b.BorderBrush(Brush(kClear));
            b.Background(Brush(kClear));
            double denom = kPresets[i].denom;
            b.Click([this, denom](auto &&, auto &&) {
                ApplyScale(denom);
                ScalePanel().Visibility(Visibility::Collapsed);
            });
            row.Children().Append(b);
        }
    }

    void MainWindow::ToggleScalePanel()
    {
        if (ScalePanel().Visibility() == Visibility::Visible)
        {
            ScalePanel().Visibility(Visibility::Collapsed);
            return;
        }
        ScaleBox().Text(L"");
        UpdateScaleValidity();
        lk_readout r{};
        lk_controller_readout(controller, &r);
        UpdateScalePanel(r);
        ScalePanel().Visibility(Visibility::Visible);
        ScaleBox().Focus(FocusState::Programmatic);
    }

    // The live half of the panel: "now 1:N" and the highlighted band preset.
    // Refreshed from the readout tick while the panel is up.
    void MainWindow::UpdateScalePanel(lk_readout const &r)
    {
        ScaleNow().Text(hstring{ L"now " } + to_hstring(lkw::FormatScale(r.scale_denom)));
        char const *band = lkw::BandForDenom(r.scale_denom);
        bool dark = DarkChrome();
        uint32_t accent = Accent(dark);
        for (uint32_t i = 0, n = 0; i < ScalePresetRows().Children().Size(); ++i)
        {
            auto row = ScalePresetRows().Children().GetAt(i).as<Controls::StackPanel>();
            for (uint32_t j = 0; j < row.Children().Size() && n < std::size(kPresets); ++j, ++n)
            {
                auto b = row.Children().GetAt(j).as<Controls::Button>();
                bool sel = std::strcmp(band, lkw::BandForDenom(kPresets[n].denom)) == 0;
                b.Background(Brush(sel ? Alpha(accent, 0x24) : kClear)); // 14 % accent
                b.BorderBrush(Brush(sel ? Alpha(accent, 0x80) : kClear)); // 50 % accent
                // The sublabel was inked when the panel was built; re-ink it
                // here so it follows the scheme like everything else.
                if (auto text = b.Content().try_as<Controls::StackPanel>())
                    if (text.Children().Size() > 1)
                        if (auto value = text.Children().GetAt(1).try_as<Controls::TextBlock>())
                            value.Foreground(Brush(Muted(dark)));
            }
        }
    }

    void MainWindow::UpdateScaleValidity()
    {
        std::string text = to_string(ScaleBox().Text());
        double denom;
        bool ok = lk_scale_parse(text.c_str(), &denom);
        ScaleGo().IsEnabled(ok);
        bool empty = text.empty();
        // Nothing typed yet is a quiet rule, not a black one: at night a
        // black edge on a dark field is no edge at all.
        uint32_t edge = empty ? Alpha(Rule(DarkChrome()), 0x66)
                        : ok  ? Alpha(Accent(DarkChrome()), 0x8C)
                              : kOverscaleRed55;
        ScaleBox().BorderBrush(Brush(edge));
        if (ok)
        {
            ScaleHint().Text(to_hstring(lkw::BandForDenom(denom)) +
                             L" band. The chart holds the nearest scale it has.");
        }
        else
        {
            ScaleHint().Text(L"Type a scale, for example 25,000 or 1:25k.");
        }
    }

    void MainWindow::SubmitScale()
    {
        std::string text = to_string(ScaleBox().Text());
        double denom;
        if (!lk_scale_parse(text.c_str(), &denom))
            return;
        ApplyScale(denom);
        ScalePanel().Visibility(Visibility::Collapsed);
    }

    // The denominator at a latitude is C·cos(lat)/2^zoom, so a target scale
    // is purely a zoom delta from the current one.
    void MainWindow::ApplyScale(double denom)
    {
        if (!(denom > 0) || !lk_controller_is_open(controller))
            return;
        lk_readout r{};
        lk_controller_readout(controller, &r);
        if (!(r.scale_denom > 0))
            return;
        double dz = std::log2(r.scale_denom / denom);
        lk_controller_zoom_centered(controller, dz,
                                    (unsigned)std::max(1.0, Root().ActualWidth()),
                                    (unsigned)std::max(1.0, Root().ActualHeight()));
        UpdateReadouts();
    }
}
