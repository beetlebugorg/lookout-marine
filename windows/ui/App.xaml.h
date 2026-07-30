#pragma once
// The markup-compiler stub (defines AppT directly — App is not in the IDL,
// matching the official WinUI 3 C++ template).
#include "App.xaml.g.h"

namespace winrt::LookoutMarine::implementation
{
    struct App : AppT<App>
    {
        App();
        void OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const &);

    private:
        Microsoft::UI::Xaml::Window window{ nullptr };
    };
}
