/* lk_backdrop — a fully transparent system backdrop.
 *
 * The XAML island paints an opaque theme backstop; this replaces it so the
 * HWND-fallback chart shows through the region holes. */
#pragma once

#include <winrt/Microsoft.UI.Xaml.Media.h>

namespace lkw
{
    winrt::Microsoft::UI::Xaml::Media::SystemBackdrop MakeTransparentBackdrop();
}
