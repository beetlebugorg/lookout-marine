#include "pch.h"
#include "lk_backdrop.h"

#include <DispatcherQueue.h>

namespace
{
    // ICompositionSupportsSystemBackdrop takes a SYSTEM (Windows.UI.Composition)
    // brush; that Compositor needs a system DispatcherQueue on this thread.
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
}

namespace lkw
{
    winrt::Microsoft::UI::Xaml::Media::SystemBackdrop MakeTransparentBackdrop()
    {
        return winrt::make<TransparentBackdrop>();
    }
}
