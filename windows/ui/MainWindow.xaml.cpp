// The window shell: construction, chrome wiring, and the render thread. The
// other concerns are split per file: MainWindow.Open.cpp, .ChartHost.cpp,
// .Input.cpp, .Hud.cpp, .Settings.cpp.
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

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    MainWindow::MainWindow()
    {
        InitializeComponent();
        Title(L"Lookout Marine");
        SystemBackdrop(lkw::MakeTransparentBackdrop());

        auto native = this->try_as<::IWindowNative>();
        winrt::check_hresult(native->get_WindowHandle(&top_hwnd));

        controller = lk_controller_new();
        use_dms = lk_store_load_use_dms() != 0;

        WireChrome();

        rendering_token = Media::CompositionTarget::Rendering({ this, &MainWindow::OnRendering });
        this->SizeChanged([this](auto &&, auto &&) { SyncChartBounds(); });
        Root().LayoutUpdated([this](auto &&, auto &&) {
            if (mode == Mode::Hwnd)
                UpdateChromeRegion();
        });
        this->Closed([this](auto &&, auto &&) {
            if (rendering_token)
            {
                Media::CompositionTarget::Rendering(rendering_token);
                rendering_token = {};
            }
            StopRenderThread();
            lk_controller_free(controller);
            controller = nullptr;
            d3d.destroy();
        });
    }

    MainWindow::~MainWindow()
    {
        StopRenderThread();
        lk_controller_free(controller);
        controller = nullptr;
        d3d.destroy();
    }

    double MainWindow::Density()
    {
        double s = chart_panel != nullptr ? chart_panel.CompositionScaleX() : 0.0;
        return s > 0 ? s : GetDpiForWindow(top_hwnd) / 96.0;
    }

    void MainWindow::WireChrome()
    {
        LayersBtn().Click([this](auto &&, auto &&) { RebuildOpenFlyout(); });
        EmptyOpenBtn().Click([this](auto &&, auto &&) { PickChartFolder(); });
        ZoomInBtn().Click([this](auto &&, auto &&) { Command('+'); });
        ZoomOutBtn().Click([this](auto &&, auto &&) { Command('-'); });
        NorthBtn().Click([this](auto &&, auto &&) { Command('u'); });
        SettingsBtn().Click([this](auto &&, auto &&) { Command(','); });
        SearchBtn().Click([this](auto &&, auto &&) { Command('f'); });
        IdentifyClose().Click([this](auto &&, auto &&) {
            IdentifyPanel().Visibility(Visibility::Collapsed);
        });
        SettingsClose().Click([this](auto &&, auto &&) {
            SettingsPane().Visibility(Visibility::Collapsed);
        });

        static constexpr wchar_t const *tab_names[] = { L"Display", L"Depths", L"Text", L"Charts", L"Advanced" };
        for (int i = 0; i < 5; ++i)
        {
            Controls::Button tb;
            tb.Content(winrt::box_value(winrt::hstring{ tab_names[i] }));
            tb.Padding({ 10, 4, 10, 6 });
            tb.CornerRadius({ 14, 14, 14, 14 });
            tb.BorderThickness({ 0, 0, 0, 0 });
            tb.Background(Media::SolidColorBrush{ i == 0 ? winrt::Windows::UI::Color{ 0x28, 0x00, 0x00, 0x00 }
                                                         : winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
            tb.Click([this, i](auto &&, auto &&) {
                settings_tab = i;
                for (uint32_t j = 0; j < SettingsTabs().Children().Size(); ++j)
                {
                    auto b = SettingsTabs().Children().GetAt(j).as<Controls::Button>();
                    b.Background(Media::SolidColorBrush{ (int)j == i ? winrt::Windows::UI::Color{ 0x28, 0x00, 0x00, 0x00 }
                                                                     : winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
                }
                BuildSettingsPage();
            });
            SettingsTabs().Children().Append(tb);
        }

        SearchBox().KeyDown([this](auto &&, Input::KeyRoutedEventArgs const &e) {
            if (e.Key() == Windows::System::VirtualKey::Enter)
                SubmitSearch();
            else if (e.Key() == Windows::System::VirtualKey::Escape)
                Command('f');
        });

        // Chart gestures via XAML (DXGI mode; the fallback path uses the child
        // HWND wndproc). Root has a hit-testable transparent background.
        Root().PointerPressed([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto p = e.GetCurrentPoint(Root()).Position();
            bool rot = (e.KeyModifiers() & Windows::System::VirtualKeyModifiers::Shift) ==
                       Windows::System::VirtualKeyModifiers::Shift;
            GesturePress(p.X, p.Y, rot);
            Root().CapturePointer(e.Pointer());
        });
        Root().PointerMoved([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto p = e.GetCurrentPoint(Root()).Position();
            if (dragging || rotating)
                GestureMove(p.X, p.Y);
            else
                GestureHover(p.X, p.Y, true);
        });
        Root().PointerReleased([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto p = e.GetCurrentPoint(Root()).Position();
            GestureRelease(p.X, p.Y);
            Root().ReleasePointerCaptures();
        });
        Root().PointerExited([this](auto &&, auto &&) { GestureHover(0, 0, false); });
        Root().PointerWheelChanged([this](auto &&, Input::PointerRoutedEventArgs const &e) {
            auto pt = e.GetCurrentPoint(Root());
            GestureWheel(pt.Properties().MouseWheelDelta() / 120.0, pt.Position().X, pt.Position().Y);
        });
        Root().DoubleTapped([this](auto &&, Input::DoubleTappedRoutedEventArgs const &e) {
            auto p = e.GetPosition(Root());
            GestureDoubleTap(p.X, p.Y);
        });

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
        LARGE_INTEGER now, freq;
        QueryPerformanceCounter(&now);
        QueryPerformanceFrequency(&freq);
        double sec = (double)(now.QuadPart - last_readout_qpc) / freq.QuadPart;
        if (last_readout_qpc == 0 || sec > 0.1)
        {
            last_readout_qpc = now.QuadPart;
            UpdateReadouts(false);
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
        if (render_thread.joinable())
            render_thread.join();
    }

    void MainWindow::RenderLoop()
    {
        long long last_qpc = 0;
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
                if (mode == Mode::Dxgi)
                {
                    lk_controller_tick_anim(controller, dt);
                    if (lk_controller_needs_frame(controller))
                    {
                        UINT idx = frame_index++ % 2;
                        UINT64 wait = d3d.copy_done[idx];
                        UINT64 signal = ++d3d.next_value;
                        if (lk_controller_render_dxgi(controller, idx, wait, signal))
                        {
                            d3d.present(idx, signal);
                            drew = true;
                        }
                    }
                }
                else if (mode == Mode::Hwnd)
                {
                    drew = lk_controller_tick(controller, dt) != 0;
                }
            }
            Sleep(drew ? 1 : 8);
        }
    }
}
