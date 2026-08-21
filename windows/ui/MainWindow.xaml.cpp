// The window shell: construction, chrome wiring, and the render thread. The
// other concerns are split per file: MainWindow.Open.cpp, .Input.cpp,
// .Hud.cpp, .Settings.cpp.
#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
// InitializeComponent lives in MainWindow.xaml.g.hpp, compiled by
// XamlTypeInfo.g.cpp (see winrt_glue.cpp).

#include <microsoft.ui.xaml.window.h>

#include "lk_backdrop.h"
#include "lk_store.h"
#include "resource.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    // The window's own icon. The ICON resource in LookoutMarine.rc is what
    // Explorer and the taskbar read off the executable, but an HWND wears only
    // what WM_SETICON gave it — without this an unpackaged WinUI 3 window opens
    // with the stock WinUI mark in its titlebar and Alt-Tab. Every window this
    // app opens wears it, not just the chart.
    //
    // LoadImage rather than LoadIcon: asking for an exact size lets Windows
    // pick the matching frame out of the six in the .ico instead of scaling the
    // system-default one. The icons are owned by the resource, not by us, so
    // there is nothing to destroy.
    void MainWindow::ApplyWindowIcon(HWND hwnd)
    {
        if (hwnd == nullptr)
            return;

        HMODULE self = ::GetModuleHandleW(nullptr);
        auto load = [self](int metric) {
            int n = ::GetSystemMetrics(metric);
            return static_cast<HICON>(::LoadImageW(self, MAKEINTRESOURCEW(IDI_APPICON),
                                                   IMAGE_ICON, n, n, LR_DEFAULTCOLOR | LR_SHARED));
        };

        if (HICON big = load(SM_CXICON))
            ::SendMessageW(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big));
        if (HICON small_icon = load(SM_CXSMICON))
            ::SendMessageW(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small_icon));
    }
}

namespace winrt::LookoutMarine::implementation
{
    MainWindow::MainWindow()
    {
        InitializeComponent();
        Title(L"Lookout Marine");
        SystemBackdrop(lkw::MakeTransparentBackdrop());

        auto native = this->try_as<::IWindowNative>();
        winrt::check_hresult(native->get_WindowHandle(&top_hwnd));
        ApplyWindowIcon(top_hwnd);

        controller = lk_controller_new();

        WireChrome();

        readout_timer = DispatcherTimer{};
        readout_timer.Interval(std::chrono::milliseconds(100));
        readout_timer.Tick([this](auto &&, auto &&) { OnRendering(nullptr, nullptr); });
        readout_timer.Start();
        // The ROOT ELEMENT's SizeChanged, not the window's: the element fires
        // after layout, when ActualWidth/Height already hold the new size.
        Root().SizeChanged([this](auto &&, auto &&) { SyncChartBounds(); });
        this->Closed([this](auto &&, auto &&) {
            if (readout_timer != nullptr)
                readout_timer.Stop();
            StopAlertWatch();
            // The other windows hold this controller and this window: they
            // cannot outlive either.
            CloseVesselWindows();
            CloseSettings();
            StopRenderThread();
            lk_controller_free(controller);
            controller = nullptr;
        });
    }

    MainWindow::~MainWindow()
    {
        StopRenderThread();
        lk_controller_free(controller);
        controller = nullptr;
    }

    // Full screen is the chart and nothing else the window can spare: the
    // title bar and its border go, the chrome bubbles stay, because they are
    // what the mariner steers with. F11 or the menu comes back.
    void MainWindow::ToggleFullScreen()
    {
        auto app_window = AppWindow();
        full_screen = app_window.Presenter().Kind() !=
                      winrt::Microsoft::UI::Windowing::AppWindowPresenterKind::FullScreen;
        app_window.SetPresenter(full_screen
            ? winrt::Microsoft::UI::Windowing::AppWindowPresenterKind::FullScreen
            : winrt::Microsoft::UI::Windowing::AppWindowPresenterKind::Default);
    }

    double MainWindow::Density()
    {
        double s = chart_panel != nullptr ? chart_panel.CompositionScaleX() : 0.0;
        return s > 0 ? s : GetDpiForWindow(top_hwnd) / 96.0;
    }

    void MainWindow::WireChrome()
    {
        EmptyOpenBtn().Click([this](auto &&, auto &&) { PickChartFolder(); });
        ZoomInBtn().Click([this](auto &&, auto &&) { Command('+'); });
        ZoomOutBtn().Click([this](auto &&, auto &&) { Command('-'); });
        // The north bubble is the follow lock; Ctrl+U stays the plain
        // north-up reset.
        NorthBtn().Click([this](auto &&, auto &&) { CycleFollowLock(); });
        GpsPill().Click([this](auto &&, auto &&) { OpenSettingsTab("connections"); });
        SettingsBtn().Click([this](auto &&, auto &&) { Command(','); });
        SearchBtn().Click([this](auto &&, auto &&) { Command('f'); });
        RasterPill().Click([this](auto &&, auto &&) { ShowRasterMenu(); });
        // The settings markup is built with this window because it names the
        // panels the code fills; its home is the settings window, so it comes
        // out of the chart's tree before anything lays out.
        DetachSettingsPane();
        MenuBtn().Click([this](auto &&, auto &&) { ShowMainMenu(); });
        WirePick();
        WireScale();

        BuildSettingsTabs();

        SearchBox().KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() == Windows::System::VirtualKey::Enter)
                SubmitSearch();
            else if (e.Key() == Windows::System::VirtualKey::Escape)
                Command('f');
        });

        // Chart gestures via XAML (DXGI mode; the fallback path uses the child
        // HWND wndproc). Only presses that start on the chart surface are chart
        // gestures — capturing on a chrome press steals the button's Click.
        auto on_chart = [this](winrt::Windows::Foundation::IInspectable const &src) {
            auto el = src.try_as<UIElement>();
            return el == Root() || (chart_panel != nullptr && el == chart_panel);
        };
        Root().PointerPressed([this, on_chart](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!on_chart(e.OriginalSource()))
                return;
            auto pt = e.GetCurrentPoint(Root());
            // A right press is the chart menu's (RightTapped below), not the
            // start of a pan.
            if (pt.Properties().IsRightButtonPressed())
                return;
            auto p = pt.Position();
            bool rot = (e.KeyModifiers() & Windows::System::VirtualKeyModifiers::Shift) ==
                       Windows::System::VirtualKeyModifiers::Shift;
            GesturePress(p.X, p.Y, rot);
            Root().CapturePointer(e.Pointer());
        });
        // Right-click (or a touch long-press) raises the chart menu at that
        // point on the water.
        Root().RightTapped([this, on_chart](auto &&, Input::RightTappedRoutedEventArgs const &e) {
            if (!on_chart(e.OriginalSource()))
                return;
            auto p = e.GetPosition(Root());
            ShowChartMenu(p.X, p.Y);
        });
        Root().PointerMoved([this, on_chart](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto p = e.GetCurrentPoint(Root()).Position();
            if (!dragging && !rotating)
            {
                // Hover over the chart asks the overlay what is under the
                // pointer (an AIS target's payload).
                if (on_chart(e.OriginalSource()))
                    HoverProbe(p.X, p.Y);
                return;
            }
            GestureMove(p.X, p.Y);
        });
        Root().PointerReleased([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!dragging && !rotating)
                return;
            auto p = e.GetCurrentPoint(Root()).Position();
            GestureRelease(p.X, p.Y);
            Root().ReleasePointerCaptures();
        });
        Root().PointerWheelChanged([this, on_chart](auto &&, Input::PointerRoutedEventArgs const &e) {
            if (!on_chart(e.OriginalSource()))
                return;
            auto pt = e.GetCurrentPoint(Root());
            GestureWheel(pt.Properties().MouseWheelDelta() / 120.0, pt.Position().X, pt.Position().Y);
        });
        Root().DoubleTapped([this, on_chart](auto &&, Input::DoubleTappedRoutedEventArgs const &e) {
            if (!on_chart(e.OriginalSource()))
                return;
            auto p = e.GetPosition(Root());
            GestureDoubleTap(p.X, p.Y);
        });

        // Files dropped on the chart take the same path as the pickers:
        // consent for a .lkplug, the plugins' file types, then a chart.
        Root().AllowDrop(true);
        Root().DragOver([](auto &&, DragEventArgs const &e) {
            e.AcceptedOperation(winrt::Windows::ApplicationModel::DataTransfer::DataPackageOperation::Copy);
        });
        Root().Drop([this](auto &&, DragEventArgs const &e) { HandleDrop(e); });

        // The accelerators are chart commands, not menu items: without this
        // XAML surfaces its key-tip tooltip for them (a floating "ESC").
        Root().KeyboardAcceleratorPlacementMode(Input::KeyboardAcceleratorPlacementMode::Hidden);

        struct Accel { Windows::System::VirtualKey key; bool shift; char cmd; };
        static constexpr Accel accels[] = {
            { Windows::System::VirtualKey::O, false, 'o' },
            { (Windows::System::VirtualKey)0xBB, false, '+' }, // VK_OEM_PLUS
            { (Windows::System::VirtualKey)0xBD, false, '-' }, // VK_OEM_MINUS
            { Windows::System::VirtualKey::Number0, false, '0' },
            { Windows::System::VirtualKey::Up, false, 'u' },
            { Windows::System::VirtualKey::L, false, 'l' },
            { Windows::System::VirtualKey::T, false, 't' },
            { Windows::System::VirtualKey::S, true, 'S' },
            { Windows::System::VirtualKey::D, false, 'd' },
            { Windows::System::VirtualKey::F, false, 'f' },
            { Windows::System::VirtualKey::I, false, 'i' }, // next raster chart
            { Windows::System::VirtualKey::I, true, 'I' },  // add raster charts
            { Windows::System::VirtualKey::H, true, 'H' },  // hide ENC over raster
            { (Windows::System::VirtualKey)0xBC, false, ',' }, // VK_OEM_COMMA
        };
        for (auto const &a : accels)
        {
            Input::KeyboardAccelerator ka;
            ka.Key(a.key);
            ka.Modifiers(a.shift
                ? (Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift)
                : Windows::System::VirtualKeyModifiers::Control);
            char cmd = a.cmd;
            ka.Invoked([this, cmd](auto &&, Input::KeyboardAcceleratorInvokedEventArgs const &e) {
                Command(cmd);
                e.Handled(true);
            });
            Root().KeyboardAccelerators().Append(ka);
        }

        // Full screen carries no modifier, so it stands outside that table.
        {
            Input::KeyboardAccelerator f11;
            f11.Key(Windows::System::VirtualKey::F11);
            f11.Invoked([this](auto &&, Input::KeyboardAcceleratorInvokedEventArgs const &e) {
                ToggleFullScreen();
                e.Handled(true);
            });
            Root().KeyboardAccelerators().Append(f11);
        }
    }

    void MainWindow::OnRendering(Windows::Foundation::IInspectable const &,
                                 Windows::Foundation::IInspectable const &)
    {
        if (controller == nullptr)
            return;
        if (!lk_controller_is_open(controller))
        {
            TryOpen();
            return;
        }
        UpdateReadouts(false);
    }

    void MainWindow::StartRenderThread()
    {
        if (render_run.load())
            return;
        render_run.store(true);
        render_thread = std::thread([this] { RenderLoop(); });
    }

    void MainWindow::StopRenderThread()
    {
        render_run.store(false);
        lk_controller_kick(); // it may be parked; a stop must not wait out the timeout
        if (render_thread.joinable())
            render_thread.join();
    }

    void MainWindow::RenderLoop()
    {
        long long last_qpc = 0;
        DWORD idle_wait_ms = 1;
        while (render_run.load())
        {
            LARGE_INTEGER now, freq;
            QueryPerformanceCounter(&now);
            QueryPerformanceFrequency(&freq);
            double dt = last_qpc == 0 ? 0.0 : (double)(now.QuadPart - last_qpc) / freq.QuadPart;
            last_qpc = now.QuadPart;

            bool drew = false;
            if (controller != nullptr && lk_controller_is_open(controller))
            {
                int w = warmup_frames.load();
                if (w > 0)
                {
                    warmup_frames.store(w - 1);
                    lk_controller_invalidate(controller);
                }
                drew = lk_controller_tick(controller, dt) != 0;
            }
            /* Parked, not slept: input kicks the event and the next frame
             * starts at once. The escalating timeout is only for what the
             * engine does on its own — a plugin drawing, a build finishing —
             * and caps at the same 250 ms the Mac shell idles at. A quiet
             * chart costs four wakeups a second instead of 125. */
            if (drew)
                idle_wait_ms = 1;
            else if (idle_wait_ms < 250)
                idle_wait_ms = idle_wait_ms * 2 > 250 ? 250 : idle_wait_ms * 2;
            lk_controller_wait(drew ? 1 : idle_wait_ms);
        }
    }

    // The core owns the swapchain: a resize is set_density + resize (the core
    // resizes its buffers), plus the panel's inverse composition scale so one
    // swapchain pixel lands on one device pixel.
    void MainWindow::SyncChartBounds()
    {
        if (controller == nullptr || !lk_controller_is_open(controller))
            return;
        StopRenderThread(); // resize swaps the frame targets under the renderer
        double density = Density();
        double w = Root().ActualWidth(), h = Root().ActualHeight();
        lk_controller_set_density(controller, (float)density);
        lk_controller_resize(controller, (unsigned)(w < 1 ? 1 : w), (unsigned)(h < 1 ? 1 : h));
        ApplyPanelScale();
        warmup_frames.store(30);
        StartRenderThread();
        // A resize keeps the pick report (only a camera move retires it) but
        // the callout must re-fit the new window.
        if (PickCard().Visibility() == Visibility::Visible)
            PlacePickCard();
    }
}
