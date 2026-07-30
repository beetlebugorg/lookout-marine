#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
// MainWindow's InitializeComponent lives in MainWindow.xaml.g.hpp, compiled by
// XamlTypeInfo.g.cpp (see winrt_glue.cpp).

#include <microsoft.ui.xaml.window.h>
#if __has_include(<microsoft.ui.xaml.media.dxinterop.h>)
#include <microsoft.ui.xaml.media.dxinterop.h>
#else
#error "microsoft.ui.xaml.media.dxinterop.h missing (ISwapChainPanelNative)"
#endif
#include <DispatcherQueue.h>
#include <shobjidl.h>
#include <windowsx.h>

#include <algorithm>
#include <filesystem>

#include "lk_coord.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    constexpr COLORREF kNoDataDay = RGB(147, 174, 187); // S-52 NODATA, day
    constexpr wchar_t kChartHostClass[] = L"LookoutMarineChartHost";
    constexpr double kTapSlopPt = 4.0;

    winrt::Windows::UI::Composition::Compositor SystemCompositor()
    {
        static winrt::Windows::System::DispatcherQueueController controller{ nullptr };
        static winrt::Windows::UI::Composition::Compositor compositor{ nullptr };
        if (compositor == nullptr)
        {
            if (winrt::Windows::System::DispatcherQueue::GetForCurrentThread() == nullptr)
            {
                DispatcherQueueOptions options{ sizeof(DispatcherQueueOptions),
                                                DQTYPE_THREAD_CURRENT, DQTAT_COM_STA };
                ABI::Windows::System::IDispatcherQueueController *raw{ nullptr };
                winrt::check_hresult(CreateDispatcherQueueController(options, &raw));
                controller = { raw, winrt::take_ownership_from_abi };
            }
            compositor = winrt::Windows::UI::Composition::Compositor();
        }
        return compositor;
    }

    // The island backstop is opaque; a transparent system backdrop lets the
    // HWND-fallback chart show through the region-clipped bridge.
    struct TransparentBackdrop
        : winrt::Microsoft::UI::Xaml::Media::SystemBackdropT<TransparentBackdrop>
    {
        void OnTargetConnected(winrt::Microsoft::UI::Composition::ICompositionSupportsSystemBackdrop const &target,
                               winrt::Microsoft::UI::Xaml::XamlRoot const &)
        {
            try
            {
                target.SystemBackdrop(SystemCompositor().CreateColorBrush({ 0, 0, 0, 0 }));
            }
            catch (winrt::hresult_error const &)
            {
            }
        }
        void OnTargetDisconnected(winrt::Microsoft::UI::Composition::ICompositionSupportsSystemBackdrop const &target)
        {
            target.SystemBackdrop(nullptr);
        }
    };

    LRESULT CALLBACK ChartHostProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);

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

    std::vector<std::string> CollectCells(std::string const &dir)
    {
        std::vector<std::string> out;
        std::error_code ec;
        for (auto const &e : std::filesystem::recursive_directory_iterator(dir, ec))
        {
            if (e.is_regular_file(ec) && e.path().extension() == ".pmtiles")
                out.push_back(e.path().string());
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    std::vector<std::string> CellsFor(std::string const &path)
    {
        std::error_code ec;
        if (std::filesystem::is_directory(path, ec))
            return CollectCells(path);
        if (std::filesystem::exists(path, ec))
            return { path };
        return {};
    }

    std::vector<std::string> InitialPaths()
    {
        char env[1024];
        DWORD n = GetEnvironmentVariableA("LOOKOUT_OPEN", env, sizeof env);
        if (n > 0 && n < sizeof env)
        {
            auto cells = CellsFor(env);
            if (!cells.empty())
                return cells;
        }
        char **recents = lk_store_load_recents();
        if (recents != nullptr)
        {
            std::string first = recents[0] != nullptr ? recents[0] : "";
            lk_store_free_recents(recents);
            if (!first.empty())
            {
                auto cells = CellsFor(first);
                if (!cells.empty())
                    return cells;
            }
        }
        char exe[MAX_PATH];
        GetModuleFileNameA(nullptr, exe, MAX_PATH);
        std::string dir(exe);
        dir.resize(dir.find_last_of('\\'));
        char full[MAX_PATH];
        std::string demo = dir + "\\..\\..\\..\\android\\app\\src\\main\\assets\\charts\\US5MD1MC.pmtiles";
        if (GetFullPathNameA(demo.c_str(), MAX_PATH, full, nullptr) != 0 &&
            GetFileAttributesA(full) != INVALID_FILE_ATTRIBUTES)
            return { full };
        return {};
    }

    winrt::hstring FormatScale(double denom)
    {
        if (denom <= 0)
            return L"1:—";
        wchar_t raw[24], out[32];
        swprintf_s(raw, L"%d", (int)std::llround(denom));
        int len = (int)wcslen(raw), o = 0;
        for (int i = 0; i < len; ++i)
        {
            if (i > 0 && (len - i) % 3 == 0)
                out[o++] = L',';
            out[o++] = raw[i];
        }
        out[o] = 0;
        return winrt::hstring{ L"1:" } + out;
    }

    // S-57 usage band by compilation scale, as the HUD names it.
    wchar_t const *BandForDenom(double denom)
    {
        if (denom <= 0) return L"—";
        if (denom < 5000) return L"Berthing";
        if (denom < 25000) return L"Harbor";
        if (denom < 75000) return L"Approach";
        if (denom < 300000) return L"Coastal";
        if (denom < 1500000) return L"General";
        return L"Overview";
    }

    winrt::hstring FormatCoord(double lat, double lon, bool dms)
    {
        wchar_t buf[64];
        if (dms)
        {
            double alat = std::abs(lat), alon = std::abs(lon);
            swprintf_s(buf, L"%d\x00B0%04.1f'%c %03d\x00B0%04.1f'%c",
                       (int)alat, (alat - (int)alat) * 60.0, lat < 0 ? L'S' : L'N',
                       (int)alon, (alon - (int)alon) * 60.0, lon < 0 ? L'W' : L'E');
            return buf;
        }
        swprintf_s(buf, L"%.5f, %.5f", lat, lon);
        return buf;
    }
}

namespace winrt::LookoutMarine::implementation
{
    MainWindow::MainWindow()
    {
        InitializeComponent();
        Title(L"Lookout Marine");
        SystemBackdrop(winrt::make<TransparentBackdrop>());

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

    // ---- chrome ----------------------------------------------------------------

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

    void MainWindow::RebuildOpenFlyout()
    {
        Controls::MenuFlyout fly;
        Controls::MenuFlyoutItem file;
        file.Text(L"Open Chart…");
        file.Click([this](auto &&, auto &&) { PickChartFile(); });
        fly.Items().Append(file);
        Controls::MenuFlyoutItem folder;
        folder.Text(L"Open Folder…");
        folder.Click([this](auto &&, auto &&) { PickChartFolder(); });
        fly.Items().Append(folder);

        char **recents = lk_store_load_recents();
        if (recents != nullptr && recents[0] != nullptr)
        {
            fly.Items().Append(Controls::MenuFlyoutSeparator{});
            for (int i = 0; recents[i] != nullptr; ++i)
            {
                std::string path = recents[i];
                std::string name = std::filesystem::path(path).filename().string();
                if (name.empty())
                    name = path;
                Controls::MenuFlyoutItem item;
                item.Text(winrt::to_hstring(name));
                item.Click([this, path](auto &&, auto &&) { OpenPaths(CellsFor(path), path); });
                fly.Items().Append(item);
            }
        }
        lk_store_free_recents(recents);

        fly.Items().Append(Controls::MenuFlyoutSeparator{});
        Controls::ToggleMenuFlyoutItem dms;
        dms.Text(L"Coordinates as DMS");
        dms.IsChecked(use_dms);
        dms.Click([this](auto &&, auto &&) {
            use_dms = !use_dms;
            lk_store_save_use_dms(use_dms ? 1 : 0);
            UpdateReadouts(true);
        });
        fly.Items().Append(dms);

        fly.ShowAt(LayersBtn());
    }

    // ---- open ------------------------------------------------------------------

    void MainWindow::TryOpen()
    {
        if (open_attempted || controller == nullptr)
            return;
        if (Root().ActualWidth() < 2 || Root().ActualHeight() < 2)
            return; // pre-layout; retried from the Rendering tick
        open_attempted = true;

        auto paths = InitialPaths();
        if (paths.empty())
        {
            EmptyState().Visibility(Visibility::Visible);
            return;
        }
        OpenPaths(paths, {});
    }

    void MainWindow::OpenPaths(std::vector<std::string> const &paths, std::string const &recent)
    {
        if (paths.empty() || controller == nullptr)
            return;
        if (!recent.empty())
            lk_store_note_recent(recent.c_str());

        StopRenderThread();
        lk_controller_close(controller);
        d3d.destroy();
        if (chart_panel != nullptr)
        {
            uint32_t idx;
            if (Root().Children().IndexOf(chart_panel, idx))
                Root().Children().RemoveAt(idx);
            chart_panel = nullptr;
        }
        mode = Mode::None;

        bool force_hwnd = GetEnvironmentVariableA("LOOKOUT_FORCE_HWND", nullptr, 0) > 0;
        if ((!force_hwnd && OpenDxgi(paths)) || OpenHwnd(paths))
        {
            EmptyState().Visibility(Visibility::Collapsed);
            warmup_frames.store(180);
            StartRenderThread();
            UpdateReadouts(true);
            if (GetEnvironmentVariableA("LOOKOUT_OPEN_SETTINGS", nullptr, 0) > 0)
                ToggleSettings(); // screenshot/dev hook
        }
        else
        {
            EmptyState().Visibility(Visibility::Visible);
        }
    }

    bool MainWindow::OpenDxgi(std::vector<std::string> const &paths)
    {
        double density = Density();
        UINT wpx = (UINT)std::max(1.0, Root().ActualWidth() * density);
        UINT hpx = (UINT)std::max(1.0, Root().ActualHeight() * density);
        if (!d3d.init(wpx, hpx))
        {
            d3d.destroy();
            return false;
        }
        d3d.fill_target(&target);

        std::vector<const char *> cps;
        for (auto const &p : paths)
            cps.push_back(p.c_str());
        if (!lk_controller_open_dxgi(controller, &target, cps.data(), (int)cps.size(),
                                     (unsigned)(wpx / density), (unsigned)(hpx / density),
                                     (float)density))
        {
            d3d.destroy();
            fprintf(stderr, "shell: no DXGI interop, falling back to HWND\n");
            return false;
        }

        chart_panel = Controls::SwapChainPanel{};
        Root().Children().InsertAt(0, chart_panel);
        auto panel_native = chart_panel.as<ISwapChainPanelNative>();
        winrt::check_hresult(panel_native->SetSwapChain(d3d.swapchain));
        if (chart_hwnd != nullptr)
            ShowWindow(chart_hwnd, SW_HIDE);
        mode = Mode::Dxgi;
        fprintf(stderr, "shell: DXGI composition path up (%ux%u)\n", wpx, hpx);
        return true;
    }

    bool MainWindow::OpenHwnd(std::vector<std::string> const &paths)
    {
        EnsureChartHost();
        if (chart_hwnd == nullptr)
            return false;
        ShowWindow(chart_hwnd, SW_SHOW);

        RECT rc{};
        GetClientRect(top_hwnd, &rc);
        double density = Density();
        std::vector<const char *> cps;
        for (auto const &p : paths)
            cps.push_back(p.c_str());
        if (!lk_controller_open(controller, GetModuleHandleW(nullptr), chart_hwnd,
                                cps.data(), (int)cps.size(),
                                (unsigned)(rc.right / density), (unsigned)(rc.bottom / density),
                                (float)density))
            return false;
        // Above the XAML bridge; the inverse region cuts the chrome holes.
        SetWindowPos(chart_hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        mode = Mode::Hwnd;
        last_pieces.clear();
        return true;
    }

    fire_and_forget MainWindow::PickChartFile()
    {
        auto lifetime = get_strong();
        Windows::Storage::Pickers::FileOpenPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(top_hwnd);
        picker.FileTypeFilter().Append(L".pmtiles");
        auto file = co_await picker.PickSingleFileAsync();
        if (file != nullptr)
        {
            std::string path = winrt::to_string(file.Path());
            OpenPaths({ path }, path);
        }
    }

    fire_and_forget MainWindow::PickChartFolder()
    {
        auto lifetime = get_strong();
        Windows::Storage::Pickers::FolderPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(top_hwnd);
        picker.FileTypeFilter().Append(L"*");
        auto folder = co_await picker.PickSingleFolderAsync();
        if (folder != nullptr)
        {
            std::string path = winrt::to_string(folder.Path());
            OpenPaths(CollectCells(path), path);
        }
    }

    // ---- fallback chart host ---------------------------------------------------

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

    // Fallback layering: the chart child sits ON TOP of the XAML bridge with an
    // INVERSE region — the client minus the chrome rects. The chrome shows
    // through the holes and gets the input there; the region churns on OUR
    // window only (re-clipping the bridge kills its composition content).
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

    // ---- frame loop ------------------------------------------------------------

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

    void MainWindow::UpdateReadouts(bool /*force*/)
    {
        if (controller == nullptr)
            return;
        lk_readout r{};
        lk_controller_readout(controller, &r);

        HudCoord().Text(FormatCoord(r.lat, r.lon, use_dms));
        HudScale().Text(FormatScale(r.scale_denom));
        HudBand().Text(BandForDenom(r.scale_denom));
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

        BuildingPill().Visibility(r.building ? Visibility::Visible : Visibility::Collapsed);
        NorthRotate().Angle(-r.rotation_deg);
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

        double m_per_pt = denom * 0.0254 / 96.0; // real metres per logical point
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

        auto segs = ScaleBarSegs();
        segs.Children().Clear();
        for (int i = 0; i < 4; ++i)
        {
            Controls::Border seg;
            seg.Width(width_pt / 4.0);
            seg.Height(6);
            seg.Background(Media::SolidColorBrush{ i % 2 == 0 ? winrt::Windows::UI::Color{ 0xFF, 0x1A, 0x1A, 0x1A }
                                                              : winrt::Windows::UI::Color{ 0xFF, 0xFF, 0xFF, 0xFF } });
            seg.BorderBrush(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0xFF, 0x1A, 0x1A, 0x1A } });
            seg.BorderThickness({ 1, 1, i == 3 ? 1.0 : 0.0, 1 });
            segs.Children().Append(seg);
        }
    }

    // ---- gestures --------------------------------------------------------------

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

    void MainWindow::GestureHover(double x, double y, bool inside)
    {
        if (!inside || !lk_controller_is_open(controller))
        {
            UpdateReadouts(true);
            return;
        }
        double lon, lat;
        if (lk_controller_geo_at(controller, x, y, &lon, &lat))
            HudCoord().Text(FormatCoord(lat, lon, use_dms));
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

    void MainWindow::ShowPick(double x, double y)
    {
        lk_pick_feature feats[16];
        int n = lk_controller_pick_at(controller, x, y, feats, 16);
        if (n <= 0)
        {
            IdentifyPanel().Visibility(Visibility::Collapsed);
            return;
        }
        IdentifyList().Items().Clear();
        for (int i = 0; i < n; ++i)
        {
            std::string line = feats[i].cls[0] != '\0' ? feats[i].cls : feats[i].s57;
            if (feats[i].chart[0] != '\0')
                line += std::string("  (") + feats[i].chart + ")";
            Controls::TextBlock tb;
            tb.Text(winrt::to_hstring(line));
            tb.FontSize(12);
            IdentifyList().Items().Append(tb);
        }
        IdentifyPanel().Visibility(Visibility::Visible);
    }

    // ---- commands --------------------------------------------------------------

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

    // ---- mariner settings ------------------------------------------------------

    void MainWindow::ToggleSettings()
    {
        if (SettingsPane().Visibility() == Visibility::Visible)
        {
            SettingsPane().Visibility(Visibility::Collapsed);
            return;
        }
        LoadSettings();
        SettingsPane().Visibility(Visibility::Visible);
    }

    void MainWindow::ScheduleApply()
    {
        if (settings_loading)
            return;
        if (apply_timer == nullptr)
        {
            apply_timer = DispatcherTimer{};
            apply_timer.Interval(std::chrono::milliseconds(60));
            apply_timer.Tick([this](auto &&, auto &&) {
                apply_timer.Stop();
                lk_controller_set_mariner(controller, &pending);
                lk_store_save_mariner(&pending);
                UpdateReadouts(true);
            });
        }
        apply_timer.Stop();
        apply_timer.Start();
    }

    void MainWindow::LoadSettings()
    {
        lk_controller_get_mariner(controller, &pending);
        BuildSettingsPage();
    }

    void MainWindow::BuildSettingsPage()
    {
        settings_loading = true;

        auto stack = SettingsContent();
        stack.Children().Clear();

        const double ft = 3.28084;
        bool feet = pending.depth_unit == 1;

        auto header = [&](wchar_t const *text) {
            Controls::TextBlock tb;
            tb.Text(text);
            tb.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
            tb.Margin({ 0, 10, 0, 0 });
            stack.Children().Append(tb);
        };
        auto combo = [&](wchar_t const *label, std::vector<wchar_t const *> options,
                         int index, auto &&set) {
            Controls::TextBlock tb;
            tb.Text(label);
            tb.FontSize(12);
            stack.Children().Append(tb);
            Controls::ComboBox cb;
            for (auto o : options)
                cb.Items().Append(winrt::box_value(winrt::hstring{ o }));
            cb.SelectedIndex(index);
            cb.HorizontalAlignment(HorizontalAlignment::Stretch);
            cb.SelectionChanged([this, set](auto &&s, auto &&) {
                if (settings_loading)
                    return;
                set((int)s.template as<Controls::ComboBox>().SelectedIndex());
                ScheduleApply();
            });
            stack.Children().Append(cb);
        };
        auto toggle = [&](wchar_t const *label, bool value, auto &&set) {
            Controls::ToggleSwitch ts;
            ts.Header(winrt::box_value(winrt::hstring{ label }));
            ts.IsOn(value);
            ts.Toggled([this, set](auto &&s, auto &&) {
                if (settings_loading)
                    return;
                set(s.template as<Controls::ToggleSwitch>().IsOn());
                ScheduleApply();
            });
            stack.Children().Append(ts);
        };
        auto number = [&](wchar_t const *label, double metres, auto &&set_metres) {
            Controls::TextBlock tb;
            tb.Text(label);
            tb.FontSize(12);
            stack.Children().Append(tb);
            Controls::NumberBox nb;
            nb.Value(feet ? std::round(metres * ft) : metres);
            nb.SpinButtonPlacementMode(Controls::NumberBoxSpinButtonPlacementMode::Compact);
            nb.SmallChange(1);
            nb.Minimum(0);
            nb.Maximum(feet ? 2165 : 660);
            nb.ValueChanged([this, set_metres, feet_local = feet, ft](auto &&, auto &&e) {
                if (settings_loading)
                    return;
                double v = e.NewValue();
                if (std::isnan(v))
                    return;
                set_metres(feet_local ? v / ft : v);
                ScheduleApply();
            });
            stack.Children().Append(nb);
        };
        auto slider = [&](wchar_t const *label, double value, auto &&set) {
            Controls::TextBlock tb;
            tb.Text(label);
            tb.FontSize(12);
            stack.Children().Append(tb);
            Controls::Slider sl;
            sl.Minimum(0.5);
            sl.Maximum(2.0);
            sl.StepFrequency(0.05);
            sl.Value(value > 0 ? value : 1.0);
            sl.ValueChanged([this, set](auto &&, auto &&e) {
                if (settings_loading)
                    return;
                set(e.NewValue());
                ScheduleApply();
            });
            stack.Children().Append(sl);
        };

        switch (settings_tab)
        {
        case 0: // Display
        {
            combo(L"Color scheme", { L"Day", L"Dusk", L"Night" }, (int)pending.scheme,
                  [this](int i) { pending.scheme = (tile57_scheme)i; });
            int cat = pending.display_other ? 2 : (pending.display_standard ? 1 : 0);
            combo(L"Display category", { L"Base", L"Standard", L"Other" }, cat, [this](int i) {
                pending.display_base = true;
                pending.display_standard = i != 0;
                pending.display_other = i == 2;
            });
            combo(L"Soundings", { L"Follow category", L"Always on", L"Always off" }, (int)pending.soundings,
                  [this](int i) { pending.soundings = (uint8_t)i; });
            break;
        }
        case 1: // Depths
            combo(L"Depth unit", { L"Meters", L"Feet" }, (int)pending.depth_unit, [this](int i) {
                pending.depth_unit = (tile57_depth_unit)i;
                BuildSettingsPage(); // re-show the depth fields in the new unit
            });
            combo(L"Water shading", { L"Two shades", L"Four shades" }, pending.four_shade_water ? 1 : 0,
                  [this](int i) {
                      pending.four_shade_water = i == 1;
                      BuildSettingsPage();
                  });
            if (pending.four_shade_water)
                number(feet ? L"Shallow contour (ft)" : L"Shallow contour (m)", pending.shallow_contour,
                       [this](double v) { pending.shallow_contour = v; });
            number(feet ? L"Safety contour (ft)" : L"Safety contour (m)", pending.safety_contour,
                   [this](double v) { pending.safety_contour = v; });
            if (pending.four_shade_water)
                number(feet ? L"Deep contour (ft)" : L"Deep contour (m)", pending.deep_contour,
                       [this](double v) { pending.deep_contour = v; });
            number(feet ? L"Safety depth (ft)" : L"Safety depth (m)", pending.safety_depth,
                   [this](double v) { pending.safety_depth = v; });
            break;
        case 2: // Text & symbols
            header(L"Text");
            toggle(L"Feature names", pending.text_names, [this](bool v) { pending.text_names = v; });
            toggle(L"Light descriptions", pending.show_light_descriptions,
                   [this](bool v) { pending.show_light_descriptions = v; });
            toggle(L"Other text", pending.text_other, [this](bool v) { pending.text_other = v; });
            header(L"Symbols");
            toggle(L"Simplified point symbols", pending.simplified_points,
                   [this](bool v) { pending.simplified_points = v; });
            combo(L"Boundaries", { L"Symbolized", L"Plain" }, (int)pending.boundary_style,
                  [this](int i) { pending.boundary_style = (tile57_boundary_style)i; });
            toggle(L"Full light-sector lines", pending.show_full_sector_lines,
                   [this](bool v) { pending.show_full_sector_lines = v; });
            break;
        case 3: // Charts
        {
            header(L"Open");
            Controls::TextBlock open_tb;
            std::vector<std::string> none;
            open_tb.Text(lk_controller_is_open(controller)
                ? winrt::to_hstring(std::filesystem::path(InitialPaths().front()).filename().string())
                : L"No chart open");
            open_tb.FontSize(12);
            stack.Children().Append(open_tb);

            header(L"Recent");
            char **recents = lk_store_load_recents();
            for (int i = 0; recents != nullptr && recents[i] != nullptr; ++i)
            {
                std::string path = recents[i];
                std::string name = std::filesystem::path(path).filename().string();
                Controls::Button b;
                b.Content(winrt::box_value(winrt::to_hstring(name.empty() ? path : name)));
                b.HorizontalAlignment(HorizontalAlignment::Stretch);
                b.Click([this, path](auto &&, auto &&) { OpenPaths(CellsFor(path), path); });
                stack.Children().Append(b);
            }
            lk_store_free_recents(recents);

            Controls::Button add;
            add.Content(winrt::box_value(L"Add Charts…"));
            add.HorizontalAlignment(HorizontalAlignment::Stretch);
            add.Margin({ 0, 8, 0, 0 });
            add.Click([this](auto &&, auto &&) { PickChartFolder(); });
            stack.Children().Append(add);

            Controls::TextBlock foot;
            foot.Text(L"A folder of baked cells opens as one seamless library.");
            foot.FontSize(11);
            foot.Opacity(0.7);
            foot.TextWrapping(TextWrapping::Wrap);
            stack.Children().Append(foot);
            break;
        }
        case 4: // Advanced
            header(L"Safety & Quality");
            toggle(L"Data quality overlay", pending.data_quality, [this](bool v) { pending.data_quality = v; });
            toggle(L"Isolated dangers in shallow water", pending.show_isolated_dangers_shallow,
                   [this](bool v) { pending.show_isolated_dangers_shallow = v; });
            toggle(L"Information callouts", pending.show_inform_callouts,
                   [this](bool v) { pending.show_inform_callouts = v; });
            toggle(L"Meta boundaries", pending.show_meta_bounds,
                   [this](bool v) { pending.show_meta_bounds = v; });
            toggle(L"Overscale indication", pending.show_overscale,
                   [this](bool v) { pending.show_overscale = v; });
            header(L"Sizing");
            slider(L"Overall size", pending.size_scale, [this](double v) { pending.size_scale = v; });
            slider(L"Text size", pending.text_size_scale, [this](double v) { pending.text_size_scale = v; });
            slider(L"Sounding size", pending.sounding_size_scale,
                   [this](double v) { pending.sounding_size_scale = v; });
            header(L"Dates");
            toggle(L"Date-dependent features", pending.date_dependent,
                   [this](bool v) { pending.date_dependent = v; });
            toggle(L"Highlight date-dependent", pending.highlight_date_dependent,
                   [this](bool v) { pending.highlight_date_dependent = v; });
            {
                Controls::TextBlock tb;
                tb.Text(L"View date (YYYYMMDD, empty = today)");
                tb.FontSize(12);
                stack.Children().Append(tb);
                Controls::TextBox date;
                date.Text(winrt::to_hstring(pending.date_view));
                date.MaxLength(8);
                date.TextChanged([this](auto &&s, auto &&) {
                    if (settings_loading)
                        return;
                    std::string t = winrt::to_string(s.template as<Controls::TextBox>().Text());
                    memset(pending.date_view, 0, sizeof pending.date_view);
                    strncpy_s(pending.date_view, t.c_str(), sizeof pending.date_view - 1);
                    ScheduleApply();
                });
                stack.Children().Append(date);
            }
            break;
        }

        settings_loading = false;
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

namespace
{
    // Fallback chart input: the child HWND owns the mouse where the bridge is
    // clipped away. Coordinates are pixels; the gesture core takes points.
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
            if (win)
            {
                if (wp & MK_LBUTTON)
                    win->GestureMove(px(lp), py(lp));
                else
                    win->GestureHover(px(lp), py(lp), true);
            }
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
                case 'S': win->Command(shift ? 'S' : 0); return 0;
                case 'D': win->Command('d'); return 0;
                case 'F': win->Command('f'); return 0;
                case VK_OEM_COMMA: win->Command(','); return 0;
                }
            }
            return 0;
        }
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}
