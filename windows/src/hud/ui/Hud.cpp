// The readout capsule and the scale bar.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

#include "lk_format.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    // The scheme the whole app is wearing. Every window built after a change
    // asks for this, so one opened at night opens dark rather than waiting
    // for the next change to catch it.
    ElementTheme MainWindow::ChromeTheme()
    {
        return Root().RequestedTheme();
    }

    // The chart's scheme belongs to EVERY window this app opens, not only the
    // chart. The settings pane is the reason: it is declared inside Root but
    // detached from it at construction and handed to a window of its own
    // (settings/ui/Settings.cpp), so it never sees Root's RequestedTheme and
    // resolved its ThemeDictionary brushes against the SYSTEM theme instead —
    // while the rows built inside it in code asked DarkChrome(), which is the
    // chart's. A night chart under a light system theme gave a light pane
    // with night ink on it: white on white.
    void MainWindow::ApplyChromeTheme(ElementTheme want)
    {
        Root().RequestedTheme(want);
        ThemeSettingsPane(want); // settings/ui/Settings.cpp
        for (auto const &w : { settings_window, licenses_window, about_window })
            if (w != nullptr)
                if (auto content = w.Content().try_as<FrameworkElement>())
                    content.RequestedTheme(want);
        ApplyTableTheme(want); // the plugin tables, in plugins/ui/Tables.cpp

        // The change-detected chrome re-resolves its colours on its next
        // build; force one, or the pills and the bar keep the old theme's ink.
        fix_state_shown = -2;
        follow_state_shown = -2;
        raster_pill_shown.clear();
        scalebar_pt = 0;
        scalebar_m = 0;
    }

    void MainWindow::UpdateReadouts()
    {
        if (controller == nullptr)
            return;
        lk_readout r{};
        lk_controller_readout(controller, &r);

        // The chrome wears the CHART's scheme: dusk and night take the dark
        // dictionaries (see the XAML ThemeDictionaries), and menus and
        // dialogs follow the element theme on their own.
        ElementTheme want = r.scheme != 0 ? ElementTheme::Dark : ElementTheme::Light;
        if (Root().RequestedTheme() != want)
            ApplyChromeTheme(want);

        // A pick report describes the objects under one point of one view:
        // any camera move the MARINER makes — pan, fling, zoom, rotate —
        // retires it. Follow moving the chart under way does not: the core
        // drops follow the moment they pan, so while follow is active every
        // pose change is the boat's, and a report they just opened must stay
        // readable (the report rides the water, like the pick mark).
        if (pick_pose_valid && lk_controller_follow_active(controller))
        {
            // Ride along: when follow later drops, the comparison below must
            // start from where the boat left the camera, not from where the
            // report was opened, or the first still tick retires it.
            pick_pose.lon = r.lon;
            pick_pose.lat = r.lat;
            pick_pose.zoom = r.zoom;
            pick_pose.rotation_deg = r.rotation_deg;
        }
        else if (pick_pose_valid &&
                 (r.lon != pick_pose.lon || r.lat != pick_pose.lat ||
                  r.zoom != pick_pose.zoom || r.rotation_deg != pick_pose.rotation_deg))
            DismissPick();

        // The position slot is own ship's REPORTED fix or nothing (the
        // ship-or-nothing rule): the map centre here is a wrong position a
        // mariner may write in a log. With no live fix the GPS pill alone
        // carries the state.
        {
            double slon = 0, slat = 0;
            bool live = lk_controller_own_ship(controller, &slon, &slat) == 2;
            char pos[LOOKOUT_POSITION_MAX] = "";
            if (live)
                lookout_fmt_position(slat, slon, pos, sizeof pos);
            HudCoord().Text(winrt::to_hstring(pos));
            HudCoord().Visibility(live ? Visibility::Visible : Visibility::Collapsed);
        }
        char scale[LOOKOUT_SCALE_MAX];
        lookout_fmt_scale(r.scale_denom, scale, sizeof scale);
        HudScale().Text(winrt::to_hstring(scale));
        HudBand().Text(winrt::to_hstring(lookout_band_name(r.scale_denom)));
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
        UpdateRasterPill(r);
        UpdateGpsPill();
        UpdateFollowLock();
        UpdateOverlayBubble();
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

        // The bar is a chequer of ink and ground, so it takes both from the
        // palette rather than from black and white: at night the ink lightens
        // and the light half goes to the panel behind it, or the bar reads as
        // a white block on a dark chart. ApplyChromeTheme clears the
        // change-detect above so this runs again when the scheme moves.
        bool dark = DarkChrome();
        auto ink = lkw::Brush(lkw::chrome::Ink(dark));
        auto ground = lkw::Brush(dark ? 0xFF1B2126u : 0xFFFFFFFFu);

        auto segs = ScaleBarSegs();
        segs.Children().Clear();
        for (int i = 0; i < 4; ++i)
        {
            Controls::Border seg;
            seg.Width(width_pt / 4.0);
            seg.Height(6);
            seg.Background(i % 2 == 0 ? ink : ground);
            seg.BorderBrush(ink);
            seg.BorderThickness({ 1, 1, i == 3 ? 1.0 : 0.0, 1 });
            segs.Children().Append(seg);
        }
    }
}
