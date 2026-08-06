// Chart gestures and commands, shared by the XAML pointer path and the
// fallback wndproc. A tap (drag under the slop) lands in ShowPick — the pick
// report itself lives in MainWindow.Pick.cpp.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>

#include "lk_coord.h"
#include "lk_format.h"

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
            ShowPick(x, y);
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
        case 'H': lk_controller_toggle_chart(controller); break;
        case 'f':
        {
            bool open = SearchBox().Visibility() == Visibility::Visible;
            SearchBox().Visibility(open ? Visibility::Collapsed : Visibility::Visible);
            SearchIcon().Glyph(open ? L"\uE721" : L"\uE711");
            if (!open)
                SearchBox().Focus(FocusState::Programmatic);
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
            Command('f'); // collapse
        }
    }
}
