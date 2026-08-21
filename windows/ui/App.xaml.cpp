#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"

#include <microsoft.ui.xaml.window.h> // IWindowNative, to publish the HWND
// App's InitializeComponent + wWinMain live in App.xaml.g.hpp, which
// XamlTypeInfo.g.cpp compiles — see winrt_glue.cpp. App is not in the IDL, so
// there is no App.g.cpp factory.

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    // The first copy publishes its top-level HWND in a named mapping, held
    // open for the process life. Matching by window TITLE broke the moment
    // the title changed; the mapping names the window whatever it says.
    HANDLE hwnd_mapping = nullptr;

    void PublishTopWindow(HWND hwnd)
    {
        hwnd_mapping = ::CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
                                            0, sizeof(uint64_t), L"Local\\LookoutMarine.hwnd");
        if (hwnd_mapping == nullptr)
            return;
        if (auto *p = (uint64_t *)::MapViewOfFile(hwnd_mapping, FILE_MAP_WRITE, 0, 0, sizeof(uint64_t)))
        {
            *p = (uint64_t)(uintptr_t)hwnd;
            ::UnmapViewOfFile(p);
        }
    }

    HWND RunningCopyWindow()
    {
        HANDLE m = ::OpenFileMappingW(FILE_MAP_READ, FALSE, L"Local\\LookoutMarine.hwnd");
        if (m == nullptr)
            return nullptr;
        HWND hwnd = nullptr;
        if (auto *p = (const uint64_t *)::MapViewOfFile(m, FILE_MAP_READ, 0, 0, sizeof(uint64_t)))
        {
            hwnd = (HWND)(uintptr_t)*p;
            ::UnmapViewOfFile(p);
        }
        ::CloseHandle(m);
        return hwnd;
    }

    // One running copy per machine. Two copies share one settings.ini and one
    // plugin storage directory, so the second to quit overwrites the first's
    // connections, alarm limits and raster choices - and they compete for an
    // instrument feed that serves one client. LOOKOUT_MULTI=1 is the escape
    // hatch the screenshot protocol needs. Mirrors the macOS shell.
    bool HandOverToRunningCopy()
    {
        if (::GetEnvironmentVariableW(L"LOOKOUT_MULTI", nullptr, 0) > 0)
            return false;

        ::CreateMutexW(nullptr, TRUE, L"Local\\LookoutMarine.single-instance");
        if (::GetLastError() != ERROR_ALREADY_EXISTS)
            return false; // we are the first copy; hold the mutex for our lifetime

        // Hand over: bring the running copy's window forward, then leave.
        HWND other = RunningCopyWindow();
        if (other != nullptr && ::IsWindow(other))
        {
            ::ShowWindow(other, SW_RESTORE);
            ::SetForegroundWindow(other);
        }
        fprintf(stderr, "app: another copy is running; handing over to it\n");
        return true;
    }
}

namespace winrt::LookoutMarine::implementation
{
    App::App()
    {
        InitializeComponent();
    }

    void App::OnLaunched(LaunchActivatedEventArgs const &)
    {
        if (HandOverToRunningCopy())
        {
            // Nothing is built yet to unwind - leave the way the macOS shell
            // does, before a window or a controller exists.
            ::ExitProcess(0);
        }
        window = make<MainWindow>();
        window.Activate();
        HWND hwnd = nullptr;
        if (auto native = window.try_as<::IWindowNative>())
            if (SUCCEEDED(native->get_WindowHandle(&hwnd)) && hwnd != nullptr)
                PublishTopWindow(hwnd);
    }
}
