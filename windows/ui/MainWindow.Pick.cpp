// The pick report card: ranked cursor pick → marker, callout placement, the
// object list, the decoded rows and the raw S-57 fold. The aux-file views and
// the picture viewer live in MainWindow.PickAux.cpp. Mirrors PickReport.swift
// (macOS/iOS) and PickReport.kt (Android).
#include "pch.h"
#include "MainWindow.xaml.h"

#include <algorithm>
#include <cmath>

#include "lk_format.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using lkw::Brush;
using namespace lkw::chrome;

namespace
{
    // The decoder is model code and speaks UTF-8 (lk_pick.h); the card is the
    // only place that needs an hstring, and every string it is handed is
    // already known-good UTF-8, so this never throws.
    winrt::hstring H(std::string const &s) { return winrt::to_hstring(s); }

    // Callout geometry — the same numbers as OverlayLayer.calloutLayout
    // (macOS) and calloutPlacement (Android).
    constexpr double kPickMargin = 12.0;
    constexpr double kMarkerSize = 34.0;
    constexpr double kMarkClear = kMarkerSize / 2 + 6; // card edge stops clear of the mark
    constexpr double kHudBand = 44 + 16 * 2;           // the readouts capsule owns the rest
    constexpr double kDetailWidth = 430.0;
    constexpr double kListWidth = 200.0;
    constexpr double kMinWidth = 280.0;
    constexpr double kPreferAbove = 200.0;             // enough room above wins outright
}

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::WirePick()
    {
        PickCloseBtn().Click([this](auto &&, auto &&) { DismissPick(); });
        PickCopyBtn().Click([this](auto &&, auto &&) { CopyPickReport(); });
        PickFoldBtn().Click([this](auto &&, auto &&) {
            pick_fold_open = !pick_fold_open;
            PickFoldIcon().Glyph(pick_fold_open ? L"\uE70D" : L"\uE76C"); // chevron down / right
            BuildPickBody();
        });
        PictureViewer().Tapped([this](auto &&, auto &&) {
            PictureViewer().Visibility(Visibility::Collapsed);
        });

        // The height floor: the card keeps the tallest height it has stood at
        // for this pick, so a card that shrinks under the pointer cannot move
        // the controls or the chart below it. Capped by the placement room
        // (PlacePickCard's MaxHeight) so a resize can't carry a taller value
        // forward. Reset only when a NEW pick opens.
        PickCard().SizeChanged([this](auto &&, auto &&) {
            if (PickCard().Visibility() != Visibility::Visible)
                return;
            double h = PickCard().ActualHeight();
            if (h > pick_height_floor)
                pick_height_floor = h;
            double cap = PickCard().MaxHeight();
            PickCard().MinHeight(std::min(pick_height_floor, cap));
        });

        // Escape retires the picture viewer, then the scale panel, then the
        // report; ↑/↓ move the object selection. No modifiers, so each fires
        // only when it acts.
        Input::KeyboardAccelerator esc;
        esc.Key(Windows::System::VirtualKey::Escape);
        esc.Modifiers(Windows::System::VirtualKeyModifiers::None);
        esc.Invoked([this](auto &&, Input::KeyboardAcceleratorInvokedEventArgs const &e) {
            if (PictureViewer().Visibility() == Visibility::Visible)
            {
                PictureViewer().Visibility(Visibility::Collapsed);
                e.Handled(true);
            }
            else if (ScalePanel().Visibility() == Visibility::Visible)
            {
                ScalePanel().Visibility(Visibility::Collapsed);
                e.Handled(true);
            }
            else if (PickCard().Visibility() == Visibility::Visible)
            {
                DismissPick();
                e.Handled(true);
            }
        });
        Root().KeyboardAccelerators().Append(esc);

        for (int dir : { -1, 1 })
        {
            Input::KeyboardAccelerator arrow;
            arrow.Key(dir < 0 ? Windows::System::VirtualKey::Up : Windows::System::VirtualKey::Down);
            arrow.Modifiers(Windows::System::VirtualKeyModifiers::None);
            arrow.Invoked([this, dir](auto &&, Input::KeyboardAcceleratorInvokedEventArgs const &e) {
                if (PickCard().Visibility() != Visibility::Visible || pick_count <= 1)
                    return;
                int next = std::clamp(pick_index + dir, 0, pick_count - 1);
                if (next != pick_index)
                    SelectPickObject(next);
                e.Handled(true);
            });
            Root().KeyboardAccelerators().Append(arrow);
        }
    }

    void MainWindow::ShowPick(double x, double y)
    {
        lk_pick_feature *feats = nullptr;
        int n = lk_controller_pick_at(controller, x, y, &feats);
        // $LOOKOUT_HITMAP: the classes a pick resolved, for chasing a report
        // that names something the eye disagrees with.
        if (hitmap_log)
        {
            fprintf(stderr, "[pick] at (%.0f, %.0f) -> [", x, y);
            for (int i = 0; i < n; ++i)
                fprintf(stderr, "%s%s", i > 0 ? "," : "", feats[i].cls ? feats[i].cls : "?");
            fprintf(stderr, "]\n");
        }
        DismissPick(); // a tap on bare water is how a mariner dismisses it
        if (n <= 0)
            return;

        pick_feats = feats;
        pick_count = n;
        pick_decoded.clear();
        pick_decoded.reserve((size_t)n);
        for (int i = 0; i < n; ++i)
            pick_decoded.push_back(lkw::DecodePick(feats[i].cls, feats[i].json, feats[i].chart));
        pick_x = x;
        pick_y = y;
        pick_height_floor = 0;
        PickCard().MinHeight(0);

        PickMarker().Margin({ x - kMarkerSize / 2, y - kMarkerSize / 2, 0, 0 });
        PickMarker().Visibility(Visibility::Visible);

        // The object list column, only when the pick found several objects:
        // the whole pick set stays in sight, there is no pager to walk blind.
        // Meta objects (M_*) — the chart's notes — are pulled out of the
        // scrolling list onto a shelf pinned at the column's floor, so they
        // keep one place and never scroll away with a long list.
        PickList().Children().Clear();
        PickNotesShelf().Children().Clear();
        bool have_meta = false;
        if (n > 1)
        {
            wchar_t head[32];
            swprintf_s(head, L"%d OBJECTS", n);
            PickListHeader().Text(head);

            auto make_row = [this](int i, bool meta) {
                auto const &d = pick_decoded[(size_t)i];
                Controls::Button row;
                if (meta)
                {
                    Controls::StackPanel line;
                    line.Orientation(Controls::Orientation::Horizontal);
                    line.Spacing(8);
                    Controls::FontIcon book;
                    book.Glyph(L"\uE736"); // an open book: the chart's notes
                    book.FontSize(13);
                    book.Foreground(Brush(Muted(DarkChrome())));
                    line.Children().Append(book);
                    Controls::TextBlock chip;
                    chip.Text(H(!d.chip.empty() ? d.chip : d.title));
                    chip.FontSize(12);
                    chip.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
                    chip.TextTrimming(TextTrimming::CharacterEllipsis);
                    chip.MaxLines(1);
                    line.Children().Append(chip);
                    row.Content(line);
                }
                else
                {
                    Controls::StackPanel text;
                    Controls::TextBlock title;
                    title.Text(H(d.title));
                    title.FontSize(13);
                    title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
                    title.TextTrimming(TextTrimming::CharacterEllipsis);
                    title.MaxLines(1);
                    text.Children().Append(title);
                    std::string sub = !d.subtitle.empty() ? d.subtitle : d.chip;
                    if (!sub.empty() && sub != d.title)
                    {
                        Controls::TextBlock subtitle;
                        subtitle.Text(H(sub));
                        subtitle.FontSize(11);
                        subtitle.Foreground(Brush(Muted(DarkChrome())));
                        subtitle.TextTrimming(TextTrimming::CharacterEllipsis);
                        subtitle.MaxLines(1);
                        text.Children().Append(subtitle);
                    }
                    row.Content(text);
                }
                row.Tag(box_value(i));
                row.HorizontalAlignment(HorizontalAlignment::Stretch);
                row.HorizontalContentAlignment(HorizontalAlignment::Left);
                row.Padding({ 8, 6, 8, 6 });
                row.CornerRadius({ 8, 8, 8, 8 });
                row.BorderThickness({ 0, 0, 0, 0 });
                row.Background(Brush(kClear));
                row.Foreground(Brush(Ink(DarkChrome())));
                row.Click([this, i](auto &&, auto &&) { SelectPickObject(i); });
                return row;
            };

            for (int i = 0; i < n; ++i)
            {
                bool meta = strncmp(feats[i].cls, "M_", 2) == 0;
                if (meta)
                {
                    have_meta = true;
                    PickNotesShelf().Children().Append(make_row(i, true));
                }
                else
                {
                    PickList().Children().Append(make_row(i, false));
                }
            }
        }
        PickListPane().Visibility(n > 1 ? Visibility::Visible : Visibility::Collapsed);
        PickListRule().Visibility(n > 1 ? Visibility::Visible : Visibility::Collapsed);
        PickNotesShelfRule().Visibility(have_meta ? Visibility::Visible : Visibility::Collapsed);

        SelectPickObject(0);
        PlacePickCard();
        PickCard().Visibility(Visibility::Visible);

        // The pose this report describes; any camera move retires it.
        lk_controller_readout(controller, &pick_pose);
        pick_pose_valid = true;
    }

    void MainWindow::DismissPick()
    {
        PickCard().Visibility(Visibility::Collapsed);
        PickMarker().Visibility(Visibility::Collapsed);
        PickBody().Children().Clear();
        PickList().Children().Clear();
        PickNotesShelf().Children().Clear();
        lk_controller_pick_free(pick_feats, pick_count);
        pick_feats = nullptr;
        pick_count = 0;
        pick_decoded.clear();
        pick_index = -1;
        pick_fold_open = false;
        pick_pose_valid = false;
        pick_height_floor = 0;
        PickCard().MinHeight(0);
    }

    void MainWindow::SelectPickObject(int index)
    {
        if (index < 0 || index >= (int)pick_decoded.size())
            return;
        pick_index = index;
        // An opened fold doesn't survive onto an object nobody asked to unfold.
        pick_fold_open = false;
        PickFoldIcon().Glyph(L"\uE76C");

        // Highlight over both the scrolling list and the notes shelf; a row's
        // feature index rides its Tag (Button.Foreground reaches the title,
        // which sets none of its own).
        auto highlight = [this, index](Controls::StackPanel const &panel, bool scrolls) {
            for (uint32_t j = 0; j < panel.Children().Size(); ++j)
            {
                auto row = panel.Children().GetAt(j).as<Controls::Button>();
                bool sel = unbox_value<int>(row.Tag()) == index;
                row.Background(Brush(sel ? AccentFill(DarkChrome()) : kClear));
                row.Foreground(Brush(sel ? Accent(DarkChrome()) : Ink(DarkChrome())));
                if (sel && scrolls)
                {
                    // Keep the selection in sight, and move ONLY when it has
                    // left the viewport — StartBringIntoView re-aligns on
                    // every step, which reads as pinning to the top.
                    auto to_view = row.TransformToVisual(PickListScroll());
                    auto pos = to_view.TransformPoint({ 0, 0 });
                    double top = pos.Y;
                    double bottom = top + row.ActualHeight();
                    double viewport = PickListScroll().ViewportHeight();
                    double offset = PickListScroll().VerticalOffset();
                    using DoubleRef = Windows::Foundation::IReference<double>;
                    if (top < 0)
                        PickListScroll().ChangeView(nullptr, DoubleRef{ offset + top },
                                                    nullptr, false);
                    else if (bottom > viewport)
                        PickListScroll().ChangeView(nullptr,
                                                    DoubleRef{ offset + bottom - viewport },
                                                    nullptr, false);
                }
            }
        };
        highlight(PickList(), true);
        highlight(PickNotesShelf(), false);

        auto const &d = pick_decoded[(size_t)index];
        PickTitle().Text(H(d.title));
        // The subtitle line is reserved even when empty so the header keeps
        // one height for every object and the rows never shift.
        PickSubtitle().Text(d.subtitle.empty() ? hstring{ L" " } : H(d.subtitle));
        PickFootnote().Text(H(d.footnote));
        wchar_t fold[64];
        swprintf_s(fold, L"S-57 source attributes (%zu)", d.raw.size());
        PickFoldLabel().Text(fold);
        PickFoldBtn().Visibility(d.raw.empty() ? Visibility::Collapsed : Visibility::Visible);
        BuildPickBody();
    }

    void MainWindow::BuildPickBody()
    {
        if (pick_index < 0 || pick_index >= (int)pick_decoded.size())
            return;
        auto const &d = pick_decoded[(size_t)pick_index];
        auto body = PickBody();
        body.Children().Clear();

        // Promoted INFORM cautions first, as amber callouts.
        for (auto const &note : d.notes)
        {
            Controls::Border callout;
            callout.Background(Brush(kAmberFill));
            callout.BorderBrush(Brush(kAmberEdge));
            callout.BorderThickness({ 1, 1, 1, 1 });
            callout.CornerRadius({ 8, 8, 8, 8 });
            callout.Padding({ 10, 8, 10, 8 });
            callout.Margin({ 16, 4, 16, 4 });
            Controls::StackPanel line;
            line.Orientation(Controls::Orientation::Horizontal);
            line.Spacing(8);
            Controls::FontIcon warn;
            warn.Glyph(L"\uE7BA"); // warning triangle
            warn.FontSize(15);
            warn.Foreground(Brush(kAmber));
            warn.VerticalAlignment(VerticalAlignment::Top);
            line.Children().Append(warn);
            Controls::TextBlock text;
            text.Text(H(note));
            text.FontSize(13);
            text.Foreground(Brush(Ink(DarkChrome())));
            text.TextWrapping(TextWrapping::Wrap);
            text.IsTextSelectionEnabled(true);
            text.MaxWidth(kDetailWidth - 80);
            line.Children().Append(text);
            callout.Child(line);
            body.Children().Append(callout);
        }

        // A blank body reads as a defect: say why there is nothing to read.
        if (d.empty != lkw::PickEmpty::No)
        {
            Controls::TextBlock verdict;
            verdict.Text(d.empty == lkw::PickEmpty::NoAttributes
                             ? L"The cell carries no attributes for this object."
                             : L"The cell carries only source data for this object.");
            verdict.FontSize(13);
            verdict.Foreground(Brush(Muted(DarkChrome())));
            verdict.TextWrapping(TextWrapping::Wrap);
            verdict.Margin({ 16, 4, 16, 4 });
            body.Children().Append(verdict);
        }

        // The decoded rows: label column, value owns the width.
        for (auto const &row : d.rows)
        {
            Controls::Grid grid;
            Controls::ColumnDefinition c0, c1;
            c0.Width({ std::max(40.0, 132.0 - row.depth * 12.0), GridUnitType::Pixel });
            c1.Width({ 1, GridUnitType::Star });
            grid.ColumnDefinitions().Append(c0);
            grid.ColumnDefinitions().Append(c1);
            grid.Margin({ 16.0 + row.depth * 12.0, 3, 16, 3 });
            grid.ColumnSpacing(12);
            Controls::TextBlock label;
            label.Text(H(row.label));
            label.FontSize(13);
            label.Foreground(Brush(Muted(DarkChrome())));
            label.TextWrapping(TextWrapping::Wrap);
            grid.Children().Append(label);
            Controls::TextBlock value;
            value.Text(H(row.value));
            value.FontSize(13);
            value.Foreground(Brush(Ink(DarkChrome())));
            value.TextWrapping(TextWrapping::Wrap);
            value.IsTextSelectionEnabled(true);
            Controls::Grid::SetColumn(value, 1);
            grid.Children().Append(value);
            body.Children().Append(grid);

            // A row that names an aux file gets the file itself below it.
            if (row.file && !row.value.empty() && pick_feats != nullptr)
                AddAuxFileView(body, pick_feats[pick_index].chart, row.value);
        }

        // The raw payload, when the fold is open.
        if (pick_fold_open)
        {
            for (auto const &raw : d.raw)
            {
                Controls::Grid grid;
                Controls::ColumnDefinition c0, c1;
                c0.Width({ std::max(24.0, 88.0 - raw.depth * 12.0), GridUnitType::Pixel });
                c1.Width({ 1, GridUnitType::Star });
                grid.ColumnDefinitions().Append(c0);
                grid.ColumnDefinitions().Append(c1);
                grid.Margin({ 16.0 + raw.depth * 12.0, 1, 16, 1 });
                grid.ColumnSpacing(8);
                Controls::TextBlock name;
                name.Text(raw.name.empty()
                              ? hstring{}
                              : H(raw.value.empty() ? raw.name : raw.name + ":"));
                name.FontSize(11);
                name.FontFamily(Media::FontFamily{ L"Consolas" });
                name.Foreground(Brush(Muted(DarkChrome())));
                grid.Children().Append(name);
                Controls::TextBlock value;
                value.Text(H(raw.value));
                value.FontSize(11);
                value.FontFamily(Media::FontFamily{ L"Consolas" });
                value.Foreground(Brush(Ink(DarkChrome())));
                value.TextWrapping(TextWrapping::Wrap);
                value.IsTextSelectionEnabled(true);
                Controls::Grid::SetColumn(value, 1);
                grid.Children().Append(value);
                body.Children().Append(grid);
            }
        }
    }

    // Callout placement: above the mark when there is room, below otherwise;
    // the floor is the HUD band, and `room` is a hard cap the card scrolls in.
    void MainWindow::PlacePickCard()
    {
        double view_w = Root().ActualWidth(), view_h = Root().ActualHeight();
        double want = kDetailWidth + (pick_count > 1 ? kListWidth : 0.0);
        double width = std::min(want, std::max(kMinWidth, view_w - 2 * kPickMargin));
        double x = pick_x - width / 2;
        x = std::clamp(x, kPickMargin, std::max(kPickMargin, view_w - kPickMargin - width));

        double floor_y = std::max(kPickMargin, view_h - kHudBand);
        double over = (pick_y - kMarkClear) - kPickMargin;
        double under = floor_y - (pick_y + kMarkClear);
        bool above = over >= kPreferAbove || over >= under;
        double room = std::max(48.0, above ? over : under);

        PickCard().Width(width);
        PickCard().MaxHeight(room);
        // Re-cap the height floor: a resize must not carry a taller floor
        // than the new room forward.
        PickCard().MinHeight(std::min(pick_height_floor, room));
        if (above)
        {
            PickCard().VerticalAlignment(VerticalAlignment::Bottom);
            PickCard().Margin({ x, 0, 0, view_h - (pick_y - kMarkClear) });
        }
        else
        {
            PickCard().VerticalAlignment(VerticalAlignment::Top);
            PickCard().Margin({ x, pick_y + kMarkClear, 0, 0 });
        }
    }

    // The clipboard gets the RAW payload: a chart problem gets reported in
    // the cell's own words.
    void MainWindow::CopyPickReport()
    {
        if (pick_feats == nullptr || pick_index < 0 || pick_index >= pick_count)
            return;
        auto const &f = pick_feats[pick_index];
        Windows::ApplicationModel::DataTransfer::DataPackage dp;
        dp.SetText(H(lkw::PickPlainText(f.cls, f.json, f.chart)));
        Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(dp);
    }
}
