// Setup's depth step: the boat, the four depths, and the seabed they shade.
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

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace lkw::setup;

namespace winrt::LookoutMarine::implementation
{
    // The depth step: two questions about the boat, the four numbers they come
    // to, and a picture of the water they shade.
    void MainWindow::FirstRunDepths(Controls::StackPanel const &body)
    {
        depth_pills.clear();
        depth_units.clear();
        depth_rows.clear();
        depth_key.clear();
        depth_draft = nullptr;
        depth_badge = nullptr;
        depth_seabed = nullptr;

        body.Children().Append(
            Heading(L"How deep does your boat sit?",
                    L"Lookout shades water your boat cannot cross. It needs one number to do "
                    L"that, and everything else follows from it."));

        // The boat on the left, the water it makes on the right.
        Grid columns;
        ColumnDefinition left, right;
        left.Width({ 334, GridUnitType::Pixel });
        right.Width({ 1, GridUnitType::Star });
        columns.ColumnDefinitions().Append(left);
        columns.ColumnDefinitions().Append(right);
        columns.ColumnSpacing(26);
        columns.Margin({ 0, 10, 0, 0 });

        StackPanel boat;
        Grid::SetColumn(boat, 0);
        columns.Children().Append(boat);

        // ---- the draft ----------------------------------------------------
        {
            Grid row;
            ColumnDefinition c0, c1;
            c0.Width({ 62, GridUnitType::Pixel });
            c1.Width({ 1, GridUnitType::Star });
            row.ColumnDefinitions().Append(c0);
            row.ColumnDefinitions().Append(c1);
            row.Margin({ 0, 0, 0, 9 });

            auto label = Line(L"Draft", 14, true);
            label.VerticalAlignment(VerticalAlignment::Center);
            row.Children().Append(label);

            // The number, the unit, and a pair of steppers. The field commits
            // on Enter and on losing focus: a commit per keystroke would
            // renumber the water under the mariner's hands.
            Grid field;
            ColumnDefinition f0, f1, f2;
            f0.Width({ 1, GridUnitType::Star });
            f1.Width({ 0, GridUnitType::Auto });
            f2.Width({ 0, GridUnitType::Auto });
            field.ColumnDefinitions().Append(f0);
            field.ColumnDefinitions().Append(f1);
            field.ColumnDefinitions().Append(f2);
            field.Height(44);

            depth_draft = TextBox{};
            depth_draft.Text(winrt::hstring{ depth_choice.DraftText() });
            depth_draft.FontSize(22);
            depth_draft.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            depth_draft.TextAlignment(TextAlignment::Right);
            depth_draft.BorderThickness({ 0, 0, 0, 0 });
            depth_draft.Background(SolidColorBrush{ Windows::UI::Colors::Transparent() });
            depth_draft.VerticalAlignment(VerticalAlignment::Center);
            auto commit = [this] {
                // Text that is not a depth leaves the draft alone. The field
                // is written back either way, so it reads what the step uses.
                (void)depth_choice.ReadDraft(std::wstring{ depth_draft.Text() });
                depth_draft.Text(winrt::hstring{ depth_choice.DraftText() });
                FirstRunDepthsApply();
                FirstRunDepthsRestate();
            };
            depth_draft.KeyDown([commit](auto &&, auto &&e) {
                if (e.Key() == Windows::System::VirtualKey::Enter)
                    commit();
            });
            depth_draft.LostFocus([commit](auto &&, auto &&) { commit(); });
            field.Children().Append(depth_draft);

            auto unit_label = Muted(depth_choice.unit(), 15);
            unit_label.VerticalAlignment(VerticalAlignment::Center);
            unit_label.Margin({ 8, 0, 8, 0 });
            Grid::SetColumn(unit_label, 1);
            field.Children().Append(unit_label);

            StackPanel steppers;
            steppers.Margin({ 0, 0, 8, 0 });
            steppers.VerticalAlignment(VerticalAlignment::Center);
            auto stepper = [this](wchar_t const *glyph, int by) {
                FontIcon mark;
                mark.Glyph(glyph);
                mark.FontSize(9);
                Button b;
                b.Content(mark);
                b.Padding({ 6, 1, 6, 1 });
                b.MinWidth(0);
                b.Click([this, by](auto &&, auto &&) {
                    depth_choice.Step(by);
                    depth_draft.Text(winrt::hstring{ depth_choice.DraftText() });
                    FirstRunDepthsApply();
                    FirstRunDepthsRestate();
                });
                return b;
            };
            steppers.Children().Append(stepper(L"", 1));   // ChevronUp
            steppers.Children().Append(stepper(L"", -1));  // ChevronDown
            Grid::SetColumn(steppers, 2);
            field.Children().Append(steppers);

            Border frame;
            frame.CornerRadius({ 9, 9, 9, 9 });
            frame.BorderThickness({ 1.5, 1.5, 1.5, 1.5 });
            frame.BorderBrush(AccentBrush(DarkChrome()));
            frame.Child(field);
            Grid::SetColumn(frame, 1);
            row.Children().Append(frame);
            boat.Children().Append(row);
        }

        // ---- the unit -----------------------------------------------------
        {
            Grid row;
            ColumnDefinition c0, c1;
            c0.Width({ 62, GridUnitType::Pixel });
            c1.Width({ 1, GridUnitType::Star });
            row.ColumnDefinitions().Append(c0);
            row.ColumnDefinitions().Append(c1);
            row.Margin({ 0, 0, 0, 8 });

            auto label = Muted(L"Units", 13);
            label.VerticalAlignment(VerticalAlignment::Center);
            row.Children().Append(label);

            StackPanel pair;
            pair.Orientation(Orientation::Horizontal);
            pair.Spacing(6);
            pair.HorizontalAlignment(HorizontalAlignment::Left);
            auto unit_button = [this](wchar_t const *name, bool feet) {
                Button b;
                b.Content(box_value(winrt::hstring{ name }));
                b.MinWidth(56);
                b.Padding({ 12, 4, 12, 4 });
                b.CornerRadius({ 7, 7, 7, 7 });
                b.Click([this, feet](auto &&, auto &&) {
                    if (depth_choice.feet() == feet)
                        return;
                    depth_choice.SetUnit(feet);
                    // The unit is the mariner's, and the chart reads it too.
                    tile57_mariner m{};
                    lk_controller_get_mariner(controller, &m);
                    m.depth_unit = feet ? (tile57_depth_unit)1 : (tile57_depth_unit)0;
                    lk_controller_set_mariner(controller, &m);
                    // Every label on the step carries the unit, so this one
                    // change is a rebuild.
                    FirstRunDepthsApply();
                    FirstRunRender();
                });
                depth_units.push_back(b);
                return b;
            };
            pair.Children().Append(unit_button(L"Meters", false));
            pair.Children().Append(unit_button(L"Feet", true));
            Grid::SetColumn(pair, 1);
            row.Children().Append(pair);
            boat.Children().Append(row);
        }

        auto caption = [](std::wstring const &text) {
            auto t = Muted(text, 11.5);
            return t;
        };
        {
            auto c = caption(L"Deepest point of the hull below the waterline, keel included.");
            c.Margin({ 0, 0, 0, 18 });
            boat.Children().Append(c);
        }

        // ---- the clearance ------------------------------------------------
        {
            auto head = Line(L"Clearance under the keel", 13, true);
            head.Margin({ 0, 0, 0, 9 });
            boat.Children().Append(head);

            StackPanel pills;
            pills.Orientation(Orientation::Horizontal);
            pills.Spacing(8);
            for (double c : depth_choice.Clearances())
            {
                Button b;
                b.Content(box_value(winrt::hstring{ depth_choice.Measure(c) }));
                b.Height(34);
                b.MinWidth(0);
                b.Padding({ 15, 0, 15, 0 });
                b.CornerRadius({ 17, 17, 17, 17 });
                b.Click([this, c](auto &&, auto &&) {
                    depth_choice.set_clearance(c);
                    FirstRunDepthsApply();
                    FirstRunDepthsRestate();
                });
                depth_pills.push_back(b);
                pills.Children().Append(b);
            }
            boat.Children().Append(pills);

            auto c = caption(L"How much water you want left under the keel at the shallowest "
                             L"point of a passage.");
            c.Margin({ 0, 9, 0, 0 });
            boat.Children().Append(c);
        }

        // ---- what the answers come to -------------------------------------
        {
            StackPanel derived;
            derived.Margin({ 0, 16, 0, 0 });
            wchar_t const *names[] = { L"Safety depth", L"Safety contour", L"Deep contour" };
            for (auto const *name : names)
            {
                Border rule;
                rule.Height(1);
                rule.Background(HairlineBrush(DarkChrome()));
                derived.Children().Append(rule);

                Grid row;
                ColumnDefinition c0, c1;
                c0.Width({ 1, GridUnitType::Star });
                c1.Width({ 0, GridUnitType::Auto });
                row.ColumnDefinitions().Append(c0);
                row.ColumnDefinitions().Append(c1);
                row.Margin({ 0, 11, 0, 0 });
                auto label = Muted(name, 13);
                row.Children().Append(label);
                auto value = Line(std::wstring{}, 14, true);
                Grid::SetColumn(value, 1);
                row.Children().Append(value);

                StackPanel cell;
                cell.Spacing(5);
                cell.Margin({ 0, 0, 0, 11 });
                cell.Children().Append(row);
                auto blurb = caption(std::wstring{});
                cell.Children().Append(blurb);
                derived.Children().Append(cell);
                depth_rows.push_back({ value, blurb });
            }
            boat.Children().Append(derived);
        }

        // ---- the water ----------------------------------------------------
        {
            StackPanel water;
            Grid::SetColumn(water, 1);
            water.VerticalAlignment(VerticalAlignment::Top);

            Grid panel;
            depth_seabed = Controls::Canvas{};
            depth_seabed.Width(kSeabedW);
            depth_seabed.Height(kSeabedH);
            panel.Children().Append(depth_seabed);

            depth_badge = Line(std::wstring{}, 11.5, true);
            Border badge;
            badge.Child(depth_badge);
            badge.CornerRadius({ 6, 6, 6, 6 });
            badge.Padding({ 10, 3, 10, 3 });
            badge.Margin({ 12, 12, 12, 12 });
            badge.HorizontalAlignment(HorizontalAlignment::Left);
            badge.VerticalAlignment(VerticalAlignment::Top);
            badge.Background(SolidColorBrush{ lkw::Rgb(lkw::chrome::Badge(DarkChrome())) });
            panel.Children().Append(badge);
            water.Children().Append(panel);

            Border rule;
            rule.Height(1);
            rule.Background(HairlineBrush(DarkChrome()));
            water.Children().Append(rule);

            // The four shades, with the water each one covers.
            Grid keys;
            wchar_t const *names[] = { L"Unsafe", L"Shallow", L"Medium", L"Deep" };
            char const *tokens[] = { "DEPVS", "DEPMS", "DEPMD", "DEPDW" };
            for (int i = 0; i < 4; ++i)
            {
                ColumnDefinition c;
                c.Width({ 1, GridUnitType::Star });
                keys.ColumnDefinitions().Append(c);

                StackPanel cell;
                cell.Spacing(6);
                cell.Padding({ 8, 11, 8, 11 });

                StackPanel top;
                top.Orientation(Orientation::Horizontal);
                top.Spacing(7);
                Border swatch;
                swatch.Width(11);
                swatch.Height(11);
                swatch.CornerRadius({ 3, 3, 3, 3 });
                swatch.Background(SolidColorBrush{ lkw::S52(tokens[i], lkw::SchemeOf(controller)) });
                swatch.BorderThickness({ 1, 1, 1, 1 });
                swatch.BorderBrush(HairlineBrush(DarkChrome()));
                swatch.VerticalAlignment(VerticalAlignment::Center);
                top.Children().Append(swatch);
                top.Children().Append(Line(names[i], 12, true));
                cell.Children().Append(top);

                auto range = Muted(std::wstring{}, 11.5);
                range.TextWrapping(TextWrapping::NoWrap);
                cell.Children().Append(range);
                depth_key.push_back(range);

                Grid::SetColumn(cell, i);
                keys.Children().Append(cell);
            }
            water.Children().Append(keys);

            Border round;
            round.CornerRadius({ 12, 12, 12, 12 });
            round.BorderThickness({ 1, 1, 1, 1 });
            round.BorderBrush(HairlineBrush(DarkChrome()));
            round.Child(water);
            // As tall as the water it holds. Stretched, it ran the length of
            // the questions beside it and left an empty panel under the key.
            round.VerticalAlignment(VerticalAlignment::Top);
            Grid::SetColumn(round, 1);
            columns.Children().Append(round);
        }

        body.Children().Append(columns);

        // ---- the warning --------------------------------------------------
        {
            StackPanel row;
            row.Orientation(Orientation::Horizontal);
            row.Spacing(10);
            FontIcon mark;
            mark.Glyph(L""); // Warning
            mark.FontSize(13);
            mark.Foreground(SolidColorBrush{ Windows::UI::Color{ 0xFF, 0xF5, 0x9E, 0x0B } });
            mark.VerticalAlignment(VerticalAlignment::Top);
            row.Children().Append(mark);

            TextBlock says;
            says.FontSize(12);
            says.TextWrapping(TextWrapping::Wrap);
            Run bold;
            bold.Text(L"Shading is not a depth sounder. ");
            bold.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            says.Inlines().Append(bold);
            Run rest;
            rest.Text(L"Soundings are not corrected for tide, surge or squat, and a survey can "
                      L"be decades old. Keep your own margin.");
            says.Inlines().Append(rest);
            says.Opacity(0.85);
            row.Children().Append(says);

            Border panel;
            panel.CornerRadius({ 9, 9, 9, 9 });
            panel.Padding({ 14, 12, 14, 12 });
            panel.Margin({ 0, 18, 0, 0 });
            panel.Background(SolidColorBrush{ Windows::UI::Color{ 0x1A, 0xF5, 0x9E, 0x0B } });
            panel.Child(row);
            body.Children().Append(panel);
        }

        FirstRunDepthsApply();
        FirstRunDepthsRestate();
    }

    // The four numbers the engine draws with. The shallow contour follows the
    // safety depth, which makes the first shade the water the boat cannot
    // cross.
    void MainWindow::FirstRunDepthsApply()
    {
        if (controller == nullptr)
            return;
        tile57_mariner m{};
        lk_controller_get_mariner(controller, &m);
        m.safety_depth = depth_choice.plan().safety_depth_m;
        m.shallow_contour = depth_choice.plan().shallow_contour_m;
        m.safety_contour = depth_choice.plan().safety_contour_m;
        m.deep_contour = depth_choice.plan().deep_contour_m;
        m.four_shade_water = true;
        // The unit the step is answered in is the unit the readouts use.
        m.depth_unit = depth_choice.feet() ? (tile57_depth_unit)1 : (tile57_depth_unit)0;
        lk_controller_set_mariner(controller, &m);
    }

    void MainWindow::FirstRunDepthsRestate()
    {
        auto const &d = depth_choice;
        std::wstring const depth = d.Measure(d.plan().safety_depth);
        std::wstring const safety = d.Measure(d.plan().safety_contour);
        std::wstring const deep = d.Measure(d.plan().deep_contour);

        if (depth_rows.size() == 3)
        {
            depth_rows[0].value.Text(winrt::hstring{ depth });
            depth_rows[0].blurb.Text(L"Soundings at or shallower than this print bold. It does "
                                     L"not shade water.");
            depth_rows[1].value.Text(winrt::hstring{ safety });
            depth_rows[1].blurb.Text(
                winrt::hstring{ L"Water shallower than this shades as unsafe. Rounded up to a "
                                L"contour the survey draws, so " +
                                depth + L" reads as " + safety + L"." });
            depth_rows[2].value.Text(winrt::hstring{ deep });
            depth_rows[2].blurb.Text(L"Water deeper than this draws in the lightest shade. Twice "
                                     L"the safety contour, up the same ladder the safety contour "
                                     L"came off.");
        }
        if (depth_badge != nullptr)
            depth_badge.Text(winrt::hstring{ L"Your water at " + depth });
        if (depth_key.size() == 4)
        {
            depth_key[0].Text(winrt::hstring{ L"0 – " + depth });
            depth_key[1].Text(winrt::hstring{ depth + L" – " + safety });
            depth_key[2].Text(winrt::hstring{ safety + L" – " + deep });
            depth_key[3].Text(winrt::hstring{ deep + L" +" });
        }

        // The pills and the unit pair wear the pick.
        auto const clearances = d.Clearances();
        for (size_t i = 0; i < depth_pills.size() && i < clearances.size(); ++i)
            PaintPicked(depth_pills[i], clearances[i] == d.clearance(), DarkChrome());
        for (size_t i = 0; i < depth_units.size(); ++i)
            PaintPicked(depth_units[i], (i == 1) == d.feet(), DarkChrome());

        FirstRunDrawSeabed();
    }

    // The seabed: a slope from a shore to deep water, shaded at the derived
    // contours, with spot depths on it. The core draws it
    // (lookout_depth_preview) in a unit square, scaled here to the panel.
    //
    // The soundings are the seabed and hold still; the shading is the
    // mariner's and moves over them. A chart behaves the same way when a boat
    // changes.
    void MainWindow::FirstRunDrawSeabed()
    {
        if (depth_seabed == nullptr)
            return;
        depth_seabed.Children().Clear();
        auto const v = depth_choice.Preview();
        uint32_t const scheme = lkw::SchemeOf(controller);
        auto shade = [scheme](char const *token, uint8_t alpha = 0xFF) {
            return SolidColorBrush{ lkw::S52(token, scheme, alpha) };
        };

        Shapes::Rectangle back;
        back.Width(kSeabedW);
        back.Height(kSeabedH);
        back.Fill(shade("DEPDW"));
        depth_seabed.Children().Append(back);

        // One depth line across the panel, closed along the bottom so it
        // fills.
        auto shoal = [&v](int line) {
            Media::PathFigure fig;
            fig.StartPoint({ 0, (float)kSeabedH });
            fig.IsClosed(true);
            fig.IsFilled(true);
            auto step = [&fig](float x, float y) {
                Media::LineSegment seg;
                seg.Point({ x, y });
                fig.Segments().Append(seg);
            };
            for (int i = 0; i < LOOKOUT_DEPTH_PREVIEW_POINTS; ++i)
                step((float)(kSeabedW * i / (LOOKOUT_DEPTH_PREVIEW_POINTS - 1)),
                     (float)(kSeabedH * v.y[line][i]));
            step((float)kSeabedW, (float)kSeabedH);
            Media::PathGeometry geo;
            geo.FillRule(Media::FillRule::Nonzero);
            geo.Figures().Append(fig);
            Shapes::Path p;
            p.Data(geo);
            return p;
        };
        auto fill = [&](int line, char const *token) {
            auto p = shoal(line);
            p.Fill(shade(token));
            depth_seabed.Children().Append(p);
        };
        auto stroke = [&](int line, char const *token, uint8_t alpha, double thick) {
            auto p = shoal(line);
            p.Stroke(shade(token, alpha));
            p.StrokeThickness(thick);
            depth_seabed.Children().Append(p);
        };

        fill(LOOKOUT_DEPTH_LINE_DEEP_CONTOUR, "DEPMD");
        fill(LOOKOUT_DEPTH_LINE_SAFETY_CONTOUR, "DEPMS");
        fill(LOOKOUT_DEPTH_LINE_SAFETY_DEPTH, "DEPVS");
        // The safety contour drawn bold, the way S-52 draws the contour a boat
        // is measured against.
        stroke(LOOKOUT_DEPTH_LINE_SAFETY_CONTOUR, "DEPCN", 0xFF, 1.8);
        stroke(LOOKOUT_DEPTH_LINE_DEEP_CONTOUR, "DEPCN", 0x99, 0.8);
        fill(LOOKOUT_DEPTH_LINE_SHORE, "LANDA");
        stroke(LOOKOUT_DEPTH_LINE_SHORE, "CSTLN", 0xFF, 1.0);

        // Spot depths, bold at or shallower than the safety depth. That is
        // what the safety depth does to a chart.
        for (int i = 0; i < LOOKOUT_DEPTH_PREVIEW_SPOTS; ++i)
        {
            bool const bold = v.spot_bold[i] != 0;
            auto label = Line(std::to_wstring(v.spot_sounding[i]), 10.5, bold);
            label.Foreground(shade(bold ? "SNDG2" : "SNDG1"));
            label.TextWrapping(TextWrapping::NoWrap);
            Controls::Canvas::SetLeft(label, kSeabedW * v.spot_x[i] - 6);
            Controls::Canvas::SetTop(label, kSeabedH * v.spot_y[i] - 7);
            depth_seabed.Children().Append(label);
        }
    }
}
