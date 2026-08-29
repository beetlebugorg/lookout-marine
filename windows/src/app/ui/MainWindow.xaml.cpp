// The window shell: construction, chrome wiring, and the render thread.
//
// Everything else this window does lives in the directory for the area it
// belongs to — chart/, hud/, library/, plugins/, settings/, about/ — each
// beside the model that drives it. See README.md for the map.
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

namespace
{
    // A frame must never take the whole app down. The per-frame UI work and the
    // render thread call into WinRT and D3D, and either can fail under memory
    // pressure — building a XAML element, an allocation for a world-view scene
    // on the software rasterizer — as a thrown hresult_error. An exception that
    // escapes a dispatcher callback, or a std::thread body, terminates the
    // process; for a chartplotter a dropped frame must cost only that frame.
    // Logged once so a persistent failure shows in the core log without a line
    // every tick.
    void SwallowFrameError(const char *where)
    {
        static bool logged = false;
        try
        {
            throw;
        }
        catch (winrt::hresult_error const &e)
        {
            if (!logged)
            {
                logged = true;
                fprintf(stderr, "shell: %s dropped a frame: hresult 0x%08X\n",
                        where, static_cast<unsigned>(e.code()));
            }
        }
        catch (std::exception const &e)
        {
            if (!logged)
            {
                logged = true;
                fprintf(stderr, "shell: %s dropped a frame: %s\n", where, e.what());
            }
        }
        catch (...)
        {
            if (!logged)
            {
                logged = true;
                fprintf(stderr, "shell: %s dropped a frame: unknown exception\n", where);
            }
        }
    }
}

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

        // The interactive-path profile, as the reference's hooks:
        // $LOOKOUT_FRAME_PROF=<path> writes one CSV row per render-loop tick
        // (the offscreen harnesses render from a settled camera and cannot
        // show what a moving one costs); $LOOKOUT_GESTURE_BENCH=pan|zoom|both
        // drives a scripted gesture through the same entry points the mouse
        // uses, writes that profile, and quits.
        {
            char buf[512];
            DWORD prof_n = GetEnvironmentVariableA("LOOKOUT_FRAME_PROF", buf, sizeof buf);
            if (prof_n > 0 && prof_n < sizeof buf && buf[0] != '\0')
                frame_prof_path = buf;
            DWORD bench_n = GetEnvironmentVariableA("LOOKOUT_GESTURE_BENCH", buf, sizeof buf);
            if (bench_n > 0 && bench_n < sizeof buf)
            {
                std::string spec = buf;
                bench_mode = spec == "pan" ? 1 : spec == "zoom" ? 2 : spec == "both" ? 3 : 0;
            }
            hitmap_log = GetEnvironmentVariableA("LOOKOUT_HITMAP", nullptr, 0) > 0;
        }

        WireChrome();

        // The readout poll. NOT STARTED HERE: a boat runs off a battery, and
        // ten wakeups a second with no chart open is a clock ticking for
        // nothing. It starts when a chart opens (chart/ui/Open.cpp) and stops
        // when the window closes; before that the only thing it did was retry
        // the open, which the first layout below does instead — an event,
        // not a poll.
        readout_timer = DispatcherTimer{};
        readout_timer.Interval(std::chrono::milliseconds(100));
        readout_timer.Tick([this](auto &&, auto &&) { OnRendering(nullptr, nullptr); });

        // The ROOT ELEMENT's SizeChanged, not the window's: the element fires
        // after layout, when ActualWidth/Height already hold the new size —
        // which is also the moment the first open becomes possible, because
        // an open needs a size to give the engine.
        Root().SizeChanged([this](auto &&, auto &&) {
            if (controller != nullptr && !lk_controller_is_open(controller))
                TryOpen();
            else
                SyncChartBounds();
        });
        this->Closed([this](auto &&, auto &&) {
            if (readout_timer != nullptr)
                readout_timer.Stop();
            ChartLinksDetach(); // before the handle: fetches must not answer into it
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
        SearchBox().TextChanged([this](auto &&, auto &&) { UpdateSearchResults(); });

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
        try
        {
            if (controller == nullptr)
                return;
            if (!lk_controller_is_open(controller))
            {
                // Between a close and the open that follows it there is
                // nothing to read out. The open itself is driven by layout,
                // not by this clock, so the poll stands down until one lands.
                readout_timer.Stop();
                return;
            }
            UpdateReadouts(false);
            // The chart-link list, the credit and the error, from the core. A
            // landing answer raises needs-redraw, so a resolve keeps the render
            // loop ticking until it is done.
            PollChartLinks();
        }
        catch (...)
        {
            // This runs on the readout timer, ~10 Hz. Every call in it touches
            // WinRT — the readouts rebuild scale-bar segments and the chart
            // link rows rebuild XAML — and any of those can throw under memory
            // pressure. The next tick rebuilds the same chrome, so a lost one
            // costs nothing; letting it escape the timer callback would end the
            // process.
            SwallowFrameError("OnRendering");
        }
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
        LARGE_INTEGER freq;
        QueryPerformanceFrequency(&freq);
        const bool prof = !frame_prof_path.empty();
        while (render_run.load())
        {
          try
          {
            LARGE_INTEGER now;
            QueryPerformanceCounter(&now);
            if (prof_t0_qpc == 0)
                prof_t0_qpc = now.QuadPart;
            double dt = last_qpc == 0 ? 0.0 : (double)(now.QuadPart - last_qpc) / freq.QuadPart;
            last_qpc = now.QuadPart;

            bool drew = false;
            double render_ms = -1;
            lk_readout r{};
            if (controller != nullptr && lk_controller_is_open(controller))
            {
                int w = warmup_frames.load();
                if (w > 0)
                {
                    warmup_frames.store(w - 1);
                    lk_controller_invalidate(controller);
                }
                if (bench_mode != 0 && bench_phase < 5)
                    BenchStep();
                if (prof)
                    lk_controller_readout(controller, &r);
                LARGE_INTEGER rt0, rt1;
                QueryPerformanceCounter(&rt0);
                drew = lk_controller_tick(controller, dt) != 0;
                if (prof && drew)
                {
                    QueryPerformanceCounter(&rt1);
                    render_ms = (double)(rt1.QuadPart - rt0.QuadPart) / freq.QuadPart * 1000.0;
                }
            }
            if (prof)
                frame_prof.push_back({
                    (double)(now.QuadPart - prof_t0_qpc) / freq.QuadPart * 1000.0,
                    dt * 1000.0,
                    drew ? 1 : 0,
                    r.building,
                    r.zoom,
                    render_ms,
                });
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
          catch (...)
          {
            // A frame that throws must not tear down the thread — an exception
            // out of a std::thread body calls std::terminate. Drop the frame
            // and pause so a persistent failure does not spin a hot loop.
            SwallowFrameError("RenderLoop");
            lk_controller_wait(50);
          }
        }
        // Rewritten whole at every loop exit (a resize restarts the loop),
        // so the file on disk always holds the run so far.
        WriteFrameProfile();
        if (bench_mode != 0 && bench_phase >= 5)
        {
            // The bench is over: leave, the way the reference's run does.
            DispatcherQueue().TryEnqueue([this] { Close(); });
        }
    }

    /* The scripted gesture, one step per render tick: settle until the chart
     * is open and quiet, pan a steady drag (4 pt a frame is an ordinary
     * finger, and it keeps crossing into new tiles), rest, zoom IN across
     * levels (each one needs tiles the view never held), then measure how
     * long the chart takes to FINISH after the gesture stops — the phases of
     * the reference's GestureBench, minus its tour. */
    void MainWindow::BenchStep()
    {
        lk_readout r{};
        lk_controller_readout(controller, &r);
        bench_frames++;
        switch (bench_phase)
        {
        case 0: // settle: open and quiet, then 120 clean frames
            if (r.building)
            {
                bench_frames = 0;
                return;
            }
            if (bench_frames >= 120)
            {
                bench_phase = (bench_mode & 1) ? 1 : 3;
                bench_frames = 0;
            }
            break;
        case 1: // pan
            lk_controller_pan(controller, -4, -1.5);
            if (bench_frames >= 240)
            {
                bench_phase = 2;
                bench_frames = 0;
            }
            break;
        case 2: // rest between gestures
            if (bench_frames >= 60)
            {
                bench_phase = (bench_mode & 2) ? 3 : 5;
                bench_frames = 0;
            }
            break;
        case 3: // zoom in, 0.05 a frame — six levels over 480 frames
        {
            RECT rc{};
            GetClientRect(top_hwnd, &rc);
            double density = GetDpiForWindow(top_hwnd) / 96.0;
            lk_controller_zoom_centered(controller, 0.05,
                                        (unsigned)(rc.right / density),
                                        (unsigned)(rc.bottom / density));
            if (bench_frames >= 480)
            {
                bench_phase = 4;
                bench_frames = 0;
                LARGE_INTEGER n, f;
                QueryPerformanceCounter(&n);
                QueryPerformanceFrequency(&f);
                bench_fill_t0 = (double)n.QuadPart / f.QuadPart;
            }
            break;
        }
        case 4: // fill: how long until the chart FINISHES after the gesture
            if (!r.building || bench_frames > 900)
            {
                LARGE_INTEGER n, f;
                QueryPerformanceCounter(&n);
                QueryPerformanceFrequency(&f);
                fprintf(stderr, "shell: fill after zoom: %.0f ms (%d frames)\n",
                        ((double)n.QuadPart / f.QuadPart - bench_fill_t0) * 1000.0, bench_frames);
                bench_phase = 5;
                render_run.store(false); // the loop tail writes the profile and quits
            }
            break;
        default:
            break;
        }
    }

    void MainWindow::WriteFrameProfile()
    {
        if (frame_prof_path.empty() || frame_prof.empty())
            return;
        FILE *f = nullptr;
        if (fopen_s(&f, frame_prof_path.c_str(), "w") != 0 || f == nullptr)
            return;
        // The reference's columns, so one script reads both hosts' runs.
        // This loop has no render gate, so `dropped` is always 0 here.
        fprintf(f, "t_ms,gap_ms,dispatched,dropped,building,zoom,render_ms\n");
        for (auto const &row : frame_prof)
            fprintf(f, "%.2f,%.2f,%d,0,%d,%.4f,%.3f\n",
                    row.t, row.gap, row.drew, row.building, row.zoom, row.render_ms);
        fclose(f);
        fprintf(stderr, "shell: frame profile: %zu ticks -> %s\n",
                frame_prof.size(), frame_prof_path.c_str());
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
