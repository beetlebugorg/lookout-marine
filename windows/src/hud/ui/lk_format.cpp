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
}
