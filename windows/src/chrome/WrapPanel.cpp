#include "pch.h"
#include "WrapPanel.h"
#if __has_include("WrapPanel.g.cpp")
#include "WrapPanel.g.cpp"
#endif

#include <algorithm>
#include <limits>

namespace winrt::LookoutMarine::implementation
{
    Windows::Foundation::Size WrapPanel::MeasureOverride(Windows::Foundation::Size available)
    {
        for (auto const &child : Children())
            child.Measure({ available.Width, std::numeric_limits<float>::infinity() });
        return Lay(available.Width, false);
    }

    Windows::Foundation::Size WrapPanel::ArrangeOverride(Windows::Foundation::Size final_size)
    {
        Lay(final_size.Width, true);
        return final_size;
    }

    Windows::Foundation::Size WrapPanel::Lay(float width, bool arrange)
    {
        float const gap = static_cast<float>(spacing_);
        float x = 0, y = 0, row = 0, widest = 0;
        for (auto const &child : Children())
        {
            auto const want = child.DesiredSize();
            if (x > 0 && x + want.Width > width)
            {
                y += row + gap;
                x = 0;
                row = 0;
            }
            if (arrange)
                child.Arrange({ x, y, want.Width, want.Height });
            widest = std::max(widest, x + want.Width);
            x += want.Width + gap;
            row = std::max(row, want.Height);
        }
        return { widest, y + row };
    }
}
