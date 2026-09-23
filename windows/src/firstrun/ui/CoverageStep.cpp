// Setup's coverage step: the map of NOAA's water and the regions to pick.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <winrt/Microsoft.UI.Xaml.Documents.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cwchar>
#include <filesystem>
#include <limits>
#include <set>
#include <system_error>

#include "lk_bake.h"
#include "lk_firstrun.h"
#include "lk_chrome.h"
#include "lk_format.h"
#include "lk_paths.h"
#include "FirstRunParts.h"
#include "WrapPanel.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace lkw::setup;

namespace winrt::LookoutMarine::implementation
{
    // The coverage map, above the region list.
    //
    // The coastline is the core's GSHHG rings (lookout_coastline_rings). Land
    // fills first, then lakes over it: a lake is its own ring rather than a
    // hole, so fill order is what makes it water.
    //
    // Each region draws as the boxes the catalog states for it, which is what a
    // download would fetch. One rectangle per region claims water it does not
    // cover: district 8 runs Texas to the Keys around the Florida peninsula,
    // and its bounding box paints across Miami.
    // One panel of the picker: the ground it covers, and the regions drawn on
    // it as the water they cover.
    //
    // A region is ONE path rather than a box per cell. Outlining every cell
    // draws a mesh over the coast; filled and unstroked, a region reads as one
    // piece of water, and overlapping cells do not stack their fill. The tap
    // goes on that path, so it lands on the region's own water rather than on
    // a rectangle around it.
    Border MainWindow::FirstRunCoveragePanel(CoverageWindow const &win, int panel, double width,
                                             double radius, bool enabled)
    {
        double const height = width / lookout_map_aspect(win.w, win.e, win.s, win.n);

        Controls::Canvas canvas;
        canvas.Width(width);
        canvas.Height(height);
        // A box that runs past the panel is cut at its edge.
        Media::RectangleGeometry clip;
        clip.Rect({ 0, 0, (float)width, (float)height });
        canvas.Clip(clip);

        // The palette's medium-depth water and its land, at 0.55 alpha, in the
        // scheme the chart draws in.
        uint32_t const scheme = lkw::SchemeOf(controller);
        auto water = SolidColorBrush{ lkw::S52("DEPMD", scheme, 0x8C) };
        auto land = SolidColorBrush{ lkw::S52("LANDA", scheme, 0x8C) };

        Shapes::Rectangle back;
        back.Width(width);
        back.Height(height);
        back.Fill(water);
        canvas.Children().Append(back);

        auto add_rings = [&](int level, Media::Brush const &fill) {
            size_t const count = lookout_coastline_rings(level, win.w, win.e, win.s, win.n, width,
                                                         height, nullptr, 0, nullptr, 0);
            std::vector<float> xy(count * 2);
            std::vector<uint32_t> ends(count / 4 + 1);
            lookout_coastline_rings(level, win.w, win.e, win.s, win.n, width, height, xy.data(),
                                    count, ends.data(), ends.size());
            size_t start = 0;
            for (size_t r = 0; start < count && r < ends.size(); ++r)
            {
                Shapes::Polygon poly;
                Media::PointCollection pts;
                for (size_t i = start; i < ends[r]; ++i)
                    pts.Append(Windows::Foundation::Point{ xy[i * 2], xy[i * 2 + 1] });
                start = ends[r];
                poly.Points(pts);
                poly.Fill(fill);
                // A ring simplified to 0.02 degrees can cross itself, and
                // even-odd would drive a hole through the land there.
                poly.FillRule(Media::FillRule::Nonzero);
                canvas.Children().Append(poly);
            }
        };
        add_rings(LOOKOUT_COAST_LAND, land);
        add_rings(LOOKOUT_COAST_LAKE, water); // a lake is water drawn back over the land

        lookout_noaa_region const *regions = nullptr;
        size_t const n = lookout_noaa_regions(&regions);
        for (size_t i = 0; i < n && regions != nullptr; ++i)
        {
            auto const &r = regions[i];
            if (r.panel != panel)
                continue;
            std::string const rid = r.id;
            bool const picked = lkw::RegionPicked(noaa_region_id, rid);

            // The catalog's boxes, or the region's rough extent until the
            // catalog is in. What downloads is the catalog's either way.
            std::vector<lookout_noaa_box> boxes;
            size_t const have = lookout_noaa_region_coverage(noaa.handle(), r.id, nullptr, 0);
            if (have > 0)
            {
                boxes.resize(have);
                lookout_noaa_region_coverage(noaa.handle(), r.id, boxes.data(), have);
            }
            else
            {
                boxes.push_back({ r.west, r.south, r.east, r.north });
            }

            // Non-zero, not the even-odd a geometry defaults to. A region's
            // cells overlap along their borders, and even-odd cancels the
            // overlap: it drew holes through the Mid-Atlantic where the
            // Chesapeake cells cross their neighbours. Every box below is
            // wound the same way, so non-zero fills their union.
            Media::PathGeometry geo;
            geo.FillRule(Media::FillRule::Nonzero);
            for (auto const &b : boxes)
            {
                double const corners[4] = { b.west, b.north, b.east, b.south };
                float xy[4]{};
                lookout_map_project(win.w, win.e, win.s, win.n, width, height, corners, xy, 2);
                if (xy[2] <= xy[0] || xy[3] <= xy[1])
                    continue;
                Media::PathFigure fig;
                fig.StartPoint({ xy[0], xy[1] });
                fig.IsClosed(true);
                fig.IsFilled(true);
                auto corner = [&](float x, float y) {
                    Media::LineSegment seg;
                    seg.Point({ x, y });
                    fig.Segments().Append(seg);
                };
                corner(xy[2], xy[1]);
                corner(xy[2], xy[3]);
                corner(xy[0], xy[3]);
                geo.Figures().Append(fig);
            }
            if (geo.Figures().Size() == 0)
                continue;

            auto c = AccentColor(DarkChrome());
            Shapes::Path shape;
            shape.Data(geo);
            shape.Fill(SolidColorBrush{
                Windows::UI::Color{ (uint8_t)(picked ? 0x80 : 0x29), c.R, c.G, c.B } });
            if (enabled)
                shape.Tapped([this, rid](auto &&, auto &&e) {
                    noaa_region_id = lkw::RegionToggle(noaa_region_id, rid);
                    e.Handled(true);
                    FirstRunRender(); // re-prices the pick and restates the map
                });
            Automation::AutomationProperties::SetName(
                shape, winrt::hstring{ std::wstring{ winrt::to_hstring(r.name) } + L". " +
                                       std::wstring{ winrt::to_hstring(r.blurb) } });
            canvas.Children().Append(shape);
        }

        Border frame;
        frame.CornerRadius({ radius, radius, radius, radius });
        frame.BorderThickness({ 1, 1, 1, 1 });
        frame.BorderBrush(HairlineBrush(DarkChrome()));
        frame.Child(canvas);
        return frame;
    }

    void MainWindow::FirstRunCoverageMap(Controls::StackPanel const &body)
    {
        lookout_noaa_state const &st = noaa.state();
        bool const enabled = st.have_catalog != 0;

        // The lower 48, with Alaska and Hawaii inset. One view cannot hold all
        // three: they span 128 degrees of longitude, and at that scale their
        // latitude span is taller than the card. An atlas prints them as
        // insets for the same reason.
        // west, east, south, north, the order the struct declares rather than
        // the labelled order the reference writes them in.
        CoverageWindow const lower48{ -132.0, -64.0, 20.0, 52.0 };
        CoverageWindow const alaska{ -172.0, -128.0, 50.5, 72.0 };
        CoverageWindow const hawaii{ -161.0, -154.0, 18.3, 22.6 };
        constexpr double kMapW = 620.0;
        constexpr double kInsetW = 134.0;

        auto inset = [&](CoverageWindow const &win, int panel, double width,
                         wchar_t const *label) {
            // Its own frame, so each reads as itself rather than as something
            // floating off the coast of Oregon.
            StackPanel column;
            column.Spacing(2);
            auto title = Line(label, 9, false);
            title.Opacity(0.7);
            column.Children().Append(title);
            column.Children().Append(FirstRunCoveragePanel(win, panel, width, 5, enabled));
            return column;
        };

        StackPanel corners;
        corners.Orientation(Orientation::Horizontal);
        corners.Spacing(8);
        corners.Margin({ 8, 8, 8, 8 });
        corners.HorizontalAlignment(HorizontalAlignment::Left);
        corners.VerticalAlignment(VerticalAlignment::Bottom);
        corners.Children().Append(inset(alaska, LOOKOUT_NOAA_PANEL_ALASKA, kInsetW, L"Alaska"));
        corners.Children().Append(
            inset(hawaii, LOOKOUT_NOAA_PANEL_HAWAII, kInsetW * 0.54, L"Hawaii"));

        Controls::Grid map;
        map.HorizontalAlignment(HorizontalAlignment::Center);
        map.Children().Append(FirstRunCoveragePanel(
            lower48, LOOKOUT_NOAA_PANEL_LOWER48, kMapW, 10, enabled));
        // In the Pacific, where they reach no coast.
        map.Children().Append(corners);
        Automation::AutomationProperties::SetName(map, L"Coverage map");
        body.Children().Append(map);
    }

    void MainWindow::FirstRunCoverage(Controls::StackPanel const &body)
    {
        // Setup asks a mariner what to download. A picker opened from the
        // Charts pane asks what they want to hold, which includes giving water
        // back, so it says so in the reference's own words.
        body.Children().Append(Heading(
            L"Which waters do you sail?",
            first_run.picker_only()
                ? L"NOAA publishes an ENC for every United States waterway at no cost. Tick "
                  L"the water you sail. Unticking water you hold removes those charts."
                : L"Pick the water you use. Lookout downloads those charts and prepares "
                  L"them. You can add the rest later."));

        lookout_noaa_region const *regions = nullptr;
        size_t const n = lookout_noaa_regions(&regions);
        if (n == 0 || regions == nullptr)
        {
            body.Children().Append(Muted(L"The region list is not available."));
            return;
        }

        lookout_noaa_state const &st = noaa.state();

        // Ask for the catalog here rather than trusting whoever opened the
        // chart to have asked. This step is reached from a launch with no
        // charts, from removing the last set and from the Charts pane, and a
        // read that failed leaves nothing to price. The core runs one read at
        // a time; the flag is what keeps a failed read from being asked for
        // again on every render.
        if (!st.have_catalog && st.phase != 1 && !noaa_catalog_asked)
        {
            noaa_catalog_asked = true;
            lookout_noaa_refresh(noaa.handle());
        }
        if (st.have_catalog)
            noaa_catalog_asked = false; // a later failure may ask again
        // What this build drew from, so the poll renders again only when the
        // catalog moves.
        noaa_catalog_drawn = NoaaCatalogSignature();

        // What of each region is already here, before anything draws from
        // it. The pills state it, and a picker opened from the Charts pane
        // opens ticked on the water the mariner holds: opening it with
        // nothing ticked said they held none.
        std::string const recorded = FirstRunRepriceRegions();
        if (st.have_catalog && first_run.picker_only() && !noaa_picked_seeded)
        {
            noaa_picked_seeded = true;
            // Ticked, and remembered: unticking one of these gives that water
            // back, and unticking water that was never here is a mariner
            // changing their mind before they press Apply.
            noaa_held_at_open = recorded;
            if (!noaa_held_at_open.empty())
                noaa_region_id = noaa_held_at_open;
        }

        FirstRunCoverageMap(body);

        // Where the catalog stands. The price comes from it, so a region can
        // be picked before it lands but not priced.
        if (st.phase == 1)
        {
            StackPanel reading;
            reading.Orientation(Orientation::Horizontal);
            reading.Spacing(8);
            ProgressRing ring;
            ring.IsActive(true);
            ring.Width(14);
            ring.Height(14);
            reading.Children().Append(ring);
            auto says = Muted(L"Reading NOAA's chart catalog…");
            says.VerticalAlignment(VerticalAlignment::Center);
            reading.Children().Append(says);
            body.Children().Append(reading);
        }
        else
        {
            // What the catalog says comes first when there IS one. A read that
            // failed over a catalog already loaded leaves the prices standing,
            // and putting its error where the summary goes said the step had
            // nothing to price.
            if (st.have_catalog)
            {
                std::wstring says = Thousands(st.catalog_cells) + L" charts published";
                if (st.date[0] != '\0')
                    says += L", catalog dated " + std::wstring{ winrt::to_hstring(st.date) };
                body.Children().Append(Muted(says + L".", 12));
            }
            if (st.error[0] != '\0')
            {
                StackPanel failed;
                failed.Orientation(Orientation::Horizontal);
                failed.Spacing(10);
                // Under the summary, and smaller than it: the catalog on this
                // device is the fact, and the failed read is the caption.
                auto why = Muted(winrt::to_hstring(st.error).c_str(),
                                 st.have_catalog ? 11 : 12);
                why.VerticalAlignment(VerticalAlignment::Center);
                failed.Children().Append(why);
                Button again;
                again.Content(box_value(L"Try Again"));
                again.Click([this](auto &&, auto &&) {
                    noaa_catalog_asked = true;
                    lookout_noaa_refresh(noaa.handle());
                    FirstRunRender();
                });
                failed.Children().Append(again);
                body.Children().Append(failed);
            }
        }

        // The districts as pills, wrapped into rows. The mariner picks as many
        // as they sail.
        {
            auto rows = winrt::make<winrt::LookoutMarine::implementation::WrapPanel>();
            rows.Spacing(8);
            // What of each region is here, by the core's id.
            auto hold_of = [this](std::string const &id) {
                for (auto const &one : noaa_region_hold)
                    if (one.first == id)
                        return one.second;
                return lkw::RegionHold{};
            };
            for (size_t i = 0; i < n; ++i)
            {
                auto const &r = regions[i];
                bool const picked = lkw::RegionPicked(noaa_region_id, r.id);
                std::wstring name{ winrt::to_hstring(r.name) };
                lkw::RegionHold const hold = hold_of(r.id);
                auto pill = RegionPill(name, winrt::to_hstring(r.blurb).c_str(), hold,
                                       picked, st.have_catalog, DarkChrome());
                std::string const rid = r.id;
                pill.Click([this, rid](auto &&, auto &&) {
                    noaa_region_id = lkw::RegionToggle(noaa_region_id, rid);
                    FirstRunRender(); // re-prices the pick
                });
                rows.Children().Append(pill);
            }
            body.Children().Append(rows);
        }
    }
}
