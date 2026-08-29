// Chart gestures and commands, shared by the XAML pointer path and the
// fallback wndproc. A tap (drag under the slop) lands in ShowPick — the pick
// report itself lives in chart/ui/Pick.cpp.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

#include "lk_coord.h"
#include "lk_format.h"
#include "lk_text.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    constexpr double kTapSlopPt = 4.0;
}

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::GesturePress(double x, double y, bool rotate)
    {
        if (!lk_controller_is_open(controller))
            return;
        down_x = last_x = x;
        down_y = last_y = y;
        vx = vy = 0;
        last_sample_qpc = 0;
        lk_controller_fling_start(controller, 0, 0);
        rotating = rotate;
        dragging = !rotate;
    }

    void MainWindow::GestureMove(double x, double y)
    {
        if (!lk_controller_is_open(controller))
            return;
        if (rotating)
        {
            lk_controller_rotate_drag(controller, last_x, last_y, x, y);
        }
        else if (dragging)
        {
            double dx = x - last_x, dy = y - last_y;
            lk_controller_pan(controller, dx, dy);
            LARGE_INTEGER now, freq;
            QueryPerformanceCounter(&now);
            QueryPerformanceFrequency(&freq);
            if (last_sample_qpc != 0)
            {
                double dt = (double)(now.QuadPart - last_sample_qpc) / freq.QuadPart;
                if (dt > 0.0005)
                {
                    vx = vx * 0.5 + (dx / dt) * 0.5;
                    vy = vy * 0.5 + (dy / dt) * 0.5;
                }
            }
            last_sample_qpc = now.QuadPart;
        }
        last_x = x;
        last_y = y;
    }

    void MainWindow::GestureRelease(double x, double y)
    {
        bool was_rotating = rotating;
        bool was_dragging = dragging;
        dragging = rotating = false;
        if (!lk_controller_is_open(controller) || was_rotating)
            return;
        if (!was_dragging)
            return;
        double moved = std::hypot(x - down_x, y - down_y);
        if (moved <= kTapSlopPt)
        {
            // Held back one double-tap interval: the first release of a
            // double-tap must not flash the pick report open (or pin a
            // bubble) before the second tap zooms. A lone tap lands when the
            // timer fires; a double-tap cancels it.
            tap_x = x;
            tap_y = y;
            if (tap_timer == nullptr)
            {
                tap_timer = DispatcherTimer{};
                tap_timer.Tick([this](auto &&, auto &&) {
                    tap_timer.Stop();
                    // A tap on an overlay symbol pins its bubble and never
                    // also opens the chart pick report; a tap on open water
                    // retires the bubble.
                    bool pinned = TryPinOverlayAt(tap_x, tap_y);
                    // $LOOKOUT_HITMAP: what a tap resolved to, for chasing a
                    // pick that lands somewhere the eye disagrees with.
                    if (hitmap_log)
                        fprintf(stderr, "[hitmap] tap (%.0f, %.0f) overlay=%d\n",
                                tap_x, tap_y, pinned ? 1 : 0);
                    if (!pinned)
                    {
                        CloseOverlayBubble();
                        ShowPick(tap_x, tap_y);
                    }
                });
            }
            tap_timer.Interval(std::chrono::milliseconds{ ::GetDoubleClickTime() });
            tap_timer.Stop();
            tap_timer.Start();
        }
        else
            lk_controller_fling_start(controller, vx, vy);
    }

    void MainWindow::GestureWheel(double notches, double x, double y)
    {
        if (lk_controller_is_open(controller))
            lk_controller_zoom_at(controller, notches * 0.25, x, y);
    }

    void MainWindow::GestureDoubleTap(double x, double y)
    {
        // The parked first tap belongs to this gesture, not to the chart.
        if (tap_timer != nullptr)
            tap_timer.Stop();
        if (lk_controller_is_open(controller))
            lk_controller_zoom_at(controller, 1.0, x, y);
    }

    void MainWindow::Command(char cmd)
    {
        RECT rc{};
        GetClientRect(top_hwnd, &rc);
        double density = Density();
        unsigned w_pt = (unsigned)(rc.right / density);
        unsigned h_pt = (unsigned)(rc.bottom / density);

        switch (cmd)
        {
        case 'o': PickChartFolder(); break;
        case 'O': PickChartFile(); break;
        case '+': lk_controller_zoom_centered(controller, 1.0, w_pt, h_pt); break;
        case '-': lk_controller_zoom_centered(controller, -1.0, w_pt, h_pt); break;
        case '0': lk_controller_fit_chart(controller); break;
        case 'u': lk_controller_reset_rotation(controller); break;
        case 'l': lk_controller_cycle_scheme(controller); break;
        case 't': lk_controller_toggle_text(controller); break;
        case 'S': lk_controller_toggle_soundings(controller); break;
        case 'd': lk_controller_toggle_other_category(controller); break;
        case 'i': CycleRaster(); break;
        case 'I': AddRasterFiles(); break;
        case 'H':
            lk_controller_toggle_chart(controller);
            lk_store_set_chart_hidden(lk_controller_chart_hidden(controller));
            break;
        case 'f':
        {
            bool open = SearchBox().Visibility() == Visibility::Visible;
            SearchBox().Visibility(open ? Visibility::Collapsed : Visibility::Visible);
            SearchIcon().Glyph(open ? L"\uE721" : L"\uE711");
            if (open)
                SearchResults().Visibility(Visibility::Collapsed);
            else
            {
                SearchBox().Focus(FocusState::Programmatic);
                UpdateSearchResults();
            }
            break;
        }
        case ',':
            ToggleSettings();
            break;
        default:
            break;
        }
        UpdateReadouts(true);
    }

    void MainWindow::SubmitSearch()
    {
        double lat, lon;
        std::string text = winrt::to_string(SearchBox().Text());
        if (lk_coord_parse(text.c_str(), &lat, &lon))
        {
            lk_controller_set_center(controller, lon, lat);
            SearchBox().Text(L"");
            Command('f'); // collapse (also hides the results row)
        }
    }

    // The results row under the field, live as the mariner types: a parsed
    // coordinate previews as a go-to they can click; anything else says
    // honestly that feature/place search is not here yet. Never faked
    // results (the reference's SearchField dropdown, row for row).
    void MainWindow::UpdateSearchResults()
    {
        std::string text = winrt::to_string(SearchBox().Text());
        if (SearchBox().Visibility() != Visibility::Visible || text.empty())
        {
            SearchResults().Visibility(Visibility::Collapsed);
            return;
        }

        SearchResultRows().Children().Clear();
        double lat = 0, lon = 0;
        if (lk_coord_parse(text.c_str(), &lat, &lon))
        {
            Controls::Button go;
            go.HorizontalAlignment(HorizontalAlignment::Stretch);
            go.HorizontalContentAlignment(HorizontalAlignment::Left);
            go.Background(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
            go.BorderThickness({ 0, 0, 0, 0 });
            go.Padding({ 12, 10, 12, 10 });
            Controls::StackPanel row;
            row.Orientation(Controls::Orientation::Horizontal);
            row.Spacing(8);
            Controls::FontIcon pin;
            pin.Glyph(L""); // map pin
            pin.FontSize(14);
            row.Children().Append(pin);
            Controls::TextBlock label;
            label.Text(hstring{ L"Go to " } + to_hstring(lkw::FormatCoord(lat, lon)));
            label.FontSize(13);
            row.Children().Append(label);
            go.Content(row);
            go.Click([this](auto &&, auto &&) { SubmitSearch(); });
            SearchResultRows().Children().Append(go);
        }
        else
        {
            Controls::StackPanel row;
            row.Orientation(Controls::Orientation::Horizontal);
            row.Spacing(8);
            row.Padding({ 12, 10, 12, 10 });
            Controls::FontIcon q;
            q.Glyph(L""); // question ring
            q.FontSize(14);
            q.Foreground(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0xFF, 0x6B, 0x6B, 0x6B } });
            row.Children().Append(q);
            Controls::StackPanel lines;
            Controls::TextBlock title;
            title.Text(L"Feature & place search");
            title.FontSize(13);
            lines.Children().Append(title);
            Controls::TextBlock note;
            note.Text(L"Coming soon. Needs a chart name index.");
            note.FontSize(11);
            note.Foreground(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0xFF, 0x6B, 0x6B, 0x6B } });
            lines.Children().Append(note);
            row.Children().Append(lines);
            SearchResultRows().Children().Append(row);
        }
        SearchResults().Visibility(Visibility::Visible);
    }
}
