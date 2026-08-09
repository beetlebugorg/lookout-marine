#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"
// App's InitializeComponent + wWinMain live in App.xaml.g.hpp, which
// XamlTypeInfo.g.cpp compiles — see winrt_glue.cpp. App is not in the IDL, so
// there is no App.g.cpp factory.

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
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
        HWND other = ::FindWindowW(nullptr, L"Lookout Marine");
        if (other != nullptr)
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
    }
}
