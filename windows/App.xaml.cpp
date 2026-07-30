#include "pch.h"
#include "App.xaml.h"
#include "MainWindow.xaml.h"
// App's InitializeComponent + wWinMain live in App.xaml.g.hpp, which
// XamlTypeInfo.g.cpp compiles — see winrt_glue.cpp. App is not in the IDL, so
// there is no App.g.cpp factory.

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    App::App()
    {
        InitializeComponent();
    }

    void App::OnLaunched(LaunchActivatedEventArgs const &)
    {
        window = make<MainWindow>();
        window.Activate();
    }
}
