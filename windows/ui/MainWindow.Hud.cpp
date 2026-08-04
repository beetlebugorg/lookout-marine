// The readout capsule and the scale bar.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

#include "lk_format.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::UpdateReadouts(bool /*force*/)
    {
        if (controller == nullptr)
            return;
        lk_readout r{};
        lk_controller_readout(controller, &r);

        // A pick report describes the objects under one point of one view:
        // any camera move — pan, fling, zoom, rotate — retires it.
        if (pick_pose_valid &&
            (r.lon != pick_pose.lon || r.lat != pick_pose.lat ||
             r.zoom != pick_pose.zoom || r.rotation_deg != pick_pose.rotation_deg))
            DismissPick();

        HudCoord().Text(lkw::FormatCoord(r.lat, r.lon));
        HudScale().Text(lkw::FormatScale(r.scale_denom));
        HudBand().Text(lkw::BandForDenom(r.scale_denom));
        wchar_t z[16];
        swprintf_s(z, L"z%.1f", r.zoom);
        HudZoom().Text(z);

        bool over = r.overscale > 1.05;
        HudOverscale().Visibility(over ? Visibility::Visible : Visibility::Collapsed);
        if (over)
        {
            wchar_t ov[16];
            swprintf_s(ov, L"\x00D7%.1f", r.overscale);
            HudOverscaleText().Text(ov);
        }

        LoaderTick(r.building);
        if (ScalePanel().Visibility() == Visibility::Visible)
            UpdateScalePanel(r);
        // The pill is the loader's small successor: only background rebuilds
        // after the first scene get it.
        BuildingPill().Visibility(r.building && !loader_waiting ? Visibility::Visible
                                                                : Visibility::Collapsed);
        NorthRotate().Angle(-r.rotation_deg);
        UpdateScaleBar(r.scale_denom);
    }

    // Nice-number distance bar, sized from the 1:N scale at this display density.
    void MainWindow::UpdateScaleBar(double denom)
    {
        if (denom <= 0)
        {
            ScaleBar().Visibility(Visibility::Collapsed);
            return;
        }
        ScaleBar().Visibility(Visibility::Visible);

        // Ground metres per logical point. The engine gives the OGC/WMTS
        // denominator: metres per camera pixel divided by 0.00028, the standard
        // 0.28 mm pixel. One camera pixel is one logical point. A 96 dpi value
        // here made the bar 5% too long for its label.
        double m_per_pt = denom * 0.00028;
        static constexpr double nice[] = { 10, 20, 50, 100, 200, 500, 1000, 2000, 5000,
                                           10000, 20000, 50000, 100000, 200000, 500000 };
        double target = 140.0 * m_per_pt;
        double best = nice[0];
        for (double n : nice)
            if (n <= target)
                best = n;
        double width_pt = best / m_per_pt;
        if (std::abs(width_pt - scalebar_pt) < 1 && best == scalebar_m)
            return;
        scalebar_pt = width_pt;
        scalebar_m = best;

        wchar_t label[24];
        if (best >= 1000)
            swprintf_s(label, L"%g km", best / 1000.0);
        else
            swprintf_s(label, L"%g m", best);
        ScaleBarLabel().Text(label);

        auto segs = ScaleBarSegs();
        segs.Children().Clear();
        for (int i = 0; i < 4; ++i)
        {
            Controls::Border seg;
            seg.Width(width_pt / 4.0);
            seg.Height(6);
            seg.Background(Media::SolidColorBrush{ i % 2 == 0 ? winrt::Windows::UI::Color{ 0xFF, 0x1A, 0x1A, 0x1A }
                                                              : winrt::Windows::UI::Color{ 0xFF, 0xFF, 0xFF, 0xFF } });
            seg.BorderBrush(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0xFF, 0x1A, 0x1A, 0x1A } });
            seg.BorderThickness({ 1, 1, i == 3 ? 1.0 : 0.0, 1 });
            segs.Children().Append(seg);
        }
    }
}
