#include "pch.h"
#include "lk_format.h"

namespace lkw
{
    winrt::Microsoft::UI::Xaml::Media::SolidColorBrush Brush(uint32_t argb)
    {
        winrt::Windows::UI::Color c{ (uint8_t)(argb >> 24), (uint8_t)(argb >> 16),
                                     (uint8_t)(argb >> 8), (uint8_t)argb };
        return winrt::Microsoft::UI::Xaml::Media::SolidColorBrush{ c };
    }
}
