#pragma once
#include "WrapPanel.g.h"

namespace winrt::LookoutMarine::implementation
{
    struct WrapPanel : WrapPanelT<WrapPanel>
    {
        WrapPanel() = default;
        double Spacing() const { return spacing_; }
        void Spacing(double value)
        {
            spacing_ = value;
            InvalidateMeasure();
        }
        Windows::Foundation::Size MeasureOverride(Windows::Foundation::Size available);
        Windows::Foundation::Size ArrangeOverride(Windows::Foundation::Size final_size);

    private:
        // Measure and Arrange walk the rows the same way. With `arrange`
        // set, each child is placed. Returns the size the rows take.
        Windows::Foundation::Size Lay(float width, bool arrange);

        double spacing_{ 0 };
    };
}

namespace winrt::LookoutMarine::factory_implementation
{
    struct WrapPanel : WrapPanelT<WrapPanel, implementation::WrapPanel>
    {
    };
}
