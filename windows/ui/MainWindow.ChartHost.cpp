// The fallback chart host: a child HWND over the XAML bridge, clipped by an
// inverse region so the chrome shows through, with Win32 input for the chart.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <windowsx.h>

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    constexpr COLORREF kNoDataDay = RGB(147, 174, 187); // S-52 NODATA, day
    constexpr wchar_t kChartHostClass[] = L"LookoutMarineChartHost";

    LRESULT CALLBACK ChartHostProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
    {
        auto *win = (winrt::LookoutMarine::implementation::MainWindow *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        double density = GetDpiForWindow(hwnd) / 96.0;
        auto px = [&](LPARAM l) { return GET_X_LPARAM(l) / density; };
        auto py = [&](LPARAM l) { return GET_Y_LPARAM(l) / density; };

        switch (msg)
        {
        case WM_ERASEBKGND:
            return 1;
        case WM_LBUTTONDOWN:
            if (win)
            {
                SetFocus(hwnd);
                SetCapture(hwnd);
                win->GesturePress(px(lp), py(lp), (wp & MK_SHIFT) != 0);
            }
            return 0;
        case WM_MOUSEMOVE:
            if (win && (wp & MK_LBUTTON))
                win->GestureMove(px(lp), py(lp));
            return 0;
        case WM_LBUTTONUP:
            if (win)
            {
                ReleaseCapture();
                win->GestureRelease(px(lp), py(lp));
            }
            return 0;
        case WM_LBUTTONDBLCLK:
            if (win)
                win->GestureDoubleTap(px(lp), py(lp));
            return 0;
        case WM_MOUSEWHEEL:
            if (win)
            {
                POINT p{ GET_X_LPARAM(lp), GET_Y_LPARAM(lp) };
                ScreenToClient(hwnd, &p);
                win->GestureWheel(GET_WHEEL_DELTA_WPARAM(wp) / 120.0, p.x / density, p.y / density);
            }
            return 0;
        case WM_KEYDOWN:
            if (win && (GetKeyState(VK_CONTROL) & 0x8000))
            {
                bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
                switch (wp)
                {
                case 'O': win->Command('o'); return 0;
                case VK_OEM_PLUS: win->Command('+'); return 0;
                case VK_OEM_MINUS: win->Command('-'); return 0;
                case '0': win->Command('0'); return 0;
                case VK_UP: win->Command('u'); return 0;
                case 'L': win->Command('l'); return 0;
                case 'T': win->Command('t'); return 0;
                case 'S': if (shift) win->Command('S'); return 0;
                case 'D': win->Command('d'); return 0;
                case 'F': win->Command('f'); return 0;
                case VK_OEM_COMMA: win->Command(','); return 0;
                }
            }
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wp, lp);
    }

    void RegisterChartHostClass()
    {
        static bool done = false;
        if (done)
            return;
        WNDCLASSW wc{};
        wc.style = CS_DBLCLKS;
        wc.lpfnWndProc = ChartHostProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        wc.hbrBackground = CreateSolidBrush(kNoDataDay);
        wc.lpszClassName = kChartHostClass;
        RegisterClassW(&wc);
        done = true;
    }
}

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::EnsureChartHost()
    {
        if (chart_hwnd != nullptr || top_hwnd == nullptr)
            return;
        RECT rc{};
        GetClientRect(top_hwnd, &rc);
        RegisterChartHostClass();
        chart_hwnd = CreateWindowExW(0, kChartHostClass, L"",
                                     WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
                                     0, 0, std::max<LONG>(1, rc.right), std::max<LONG>(1, rc.bottom),
                                     top_hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
        if (chart_hwnd != nullptr)
        {
            SetWindowLongPtrW(chart_hwnd, GWLP_USERDATA, (LONG_PTR)this);
            SetWindowPos(chart_hwnd, HWND_BOTTOM, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    void MainWindow::SyncChartBounds()
    {
        if (controller == nullptr || !lk_controller_is_open(controller))
            return;
        StopRenderThread(); // resize swaps the frame targets under the renderer
        double density = Density();
        if (mode == Mode::Dxgi)
        {
            UINT wpx = (UINT)std::max(1.0, Root().ActualWidth() * density);
            UINT hpx = (UINT)std::max(1.0, Root().ActualHeight() * density);
            if ((wpx != d3d.width || hpx != d3d.height) && d3d.resize(wpx, hpx))
            {
                d3d.fill_target(&target);
                lk_controller_retarget_dxgi(controller, &target);
                lk_controller_set_density(controller, (float)density);
                lk_controller_resize(controller, (unsigned)(wpx / density), (unsigned)(hpx / density));
            }
        }
        else if (mode == Mode::Hwnd && chart_hwnd != nullptr)
        {
            RECT rc{};
            GetClientRect(top_hwnd, &rc);
            MoveWindow(chart_hwnd, 0, 0, std::max<LONG>(1, rc.right), std::max<LONG>(1, rc.bottom), TRUE);
            lk_controller_set_density(controller, (float)density);
            lk_controller_resize(controller, (unsigned)(rc.right / density), (unsigned)(rc.bottom / density));
        }
        warmup_frames.store(30);
        StartRenderThread();
    }

    // The chart child sits ON TOP of the XAML bridge with an INVERSE region:
    // the client minus the chrome rects. The chrome shows and gets input
    // through the holes. The region churns on OUR window only — re-clipping
    // the bridge kills its composition content.
    void MainWindow::UpdateChromeRegion()
    {
        if (mode != Mode::Hwnd || chart_hwnd == nullptr)
            return;

        RECT rc{};
        GetClientRect(chart_hwnd, &rc);
        double scale = Root().XamlRoot().RasterizationScale();
        FrameworkElement clusters[] = { SearchCluster(), NorthBtn(), ZoomStack(), RightBubbles(),
                                        HudPill(), ScaleBar(), BuildingPill(), IdentifyPanel(),
                                        EmptyState(), SettingsPane() };
        HRGN rgn = CreateRectRgn(0, 0, rc.right, rc.bottom);
        std::vector<RECT> pieces{ rc };
        for (auto const &el : clusters)
        {
            if (el.Visibility() == Visibility::Collapsed || el.ActualWidth() < 1)
                continue;
            auto t = el.TransformToVisual(nullptr);
            auto r = t.TransformBounds({ 0, 0, (float)el.ActualWidth(), (float)el.ActualHeight() });
            RECT px{ (LONG)(r.X * scale), (LONG)(r.Y * scale),
                     (LONG)((r.X + r.Width) * scale) + 1, (LONG)((r.Y + r.Height) * scale) + 1 };
            LONG corner = std::min<LONG>((LONG)(24 * scale), (px.bottom - px.top) / 2);
            HRGN piece = CreateRoundRectRgn(px.left, px.top, px.right, px.bottom, corner * 2, corner * 2);
            CombineRgn(rgn, rgn, piece, RGN_DIFF);
            DeleteObject(piece);
            pieces.push_back(px);
        }
        if (pieces.size() == last_pieces.size() &&
            memcmp(pieces.data(), last_pieces.data(), pieces.size() * sizeof(RECT)) == 0)
        {
            DeleteObject(rgn);
            return;
        }
        last_pieces = std::move(pieces);
        SetWindowRgn(chart_hwnd, rgn, TRUE); // the window owns rgn
        // A present while an area was clipped out never reached it; repaint so
        // newly revealed chart isn't stale background.
        if (warmup_frames.load() < 8)
            warmup_frames.store(8);
    }
}
