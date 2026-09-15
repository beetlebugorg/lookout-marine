#include "pch.h"
#include "lk_format.h"

namespace lkw
{
    winrt::Windows::UI::Color Rgb(uint32_t argb)
    {
        return { (uint8_t)(argb >> 24), (uint8_t)(argb >> 16), (uint8_t)(argb >> 8),
                 (uint8_t)argb };
    }

    winrt::Microsoft::UI::Xaml::Media::SolidColorBrush Brush(uint32_t argb)
    {
        return winrt::Microsoft::UI::Xaml::Media::SolidColorBrush{ Rgb(argb) };
    }

    winrt::Windows::UI::Color WithAlpha(winrt::Windows::UI::Color c, double alpha)
    {
        c.A = (uint8_t)(alpha * 255.0 + 0.5);
        return c;
    }

    void ButtonFills(winrt::Microsoft::UI::Xaml::Controls::Control const &c, uint32_t flat,
                     uint32_t over, uint32_t down, uint32_t edge)
    {
        c.Background(Brush(flat));
        auto put = [&](wchar_t const *key, uint32_t argb) {
            c.Resources().Insert(winrt::box_value(winrt::hstring{ key }), Brush(argb));
        };
        put(L"ButtonBackground", flat);
        put(L"ButtonBackgroundPointerOver", over);
        put(L"ButtonBackgroundPressed", down);
        put(L"ButtonBackgroundDisabled", flat);
        put(L"ButtonBorderBrush", edge);
        put(L"ButtonBorderBrushPointerOver", edge);
        put(L"ButtonBorderBrushPressed", edge);
        put(L"ButtonBorderBrushDisabled", edge);
    }

    void FlatFills(winrt::Microsoft::UI::Xaml::Controls::Control const &c, bool dark,
                   uint32_t edge)
    {
        ButtonFills(c, dark ? 0x00FFFFFFu : 0x00000000u, dark ? 0x14FFFFFFu : 0x0F000000u,
                    dark ? 0x1FFFFFFFu : 0x17000000u, edge);
    }
}
