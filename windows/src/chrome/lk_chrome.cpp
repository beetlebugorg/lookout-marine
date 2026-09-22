#include "pch.h"
#include "lk_chrome.h"

#include <filesystem>
#include <system_error>

#include <windows.h>

#include "lk_format.h"

namespace lkw
{
    using winrt::Microsoft::UI::Xaml::Controls::Border;
    using winrt::Microsoft::UI::Xaml::Controls::Control;
    using winrt::Microsoft::UI::Xaml::Controls::TextBlock;
    using winrt::Microsoft::UI::Xaml::Media::Imaging::BitmapImage;

    TextBlock Line(std::wstring const &text, double size, bool strong)
    {
        TextBlock t;
        t.Text(text);
        t.FontSize(size);
        t.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);
        if (strong)
            t.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
        return t;
    }

    TextBlock Muted(std::wstring const &text, double size)
    {
        auto t = Line(text, size, false);
        t.Opacity(0.7);
        return t;
    }

    Border Card(bool dark)
    {
        Border b;
        b.CornerRadius({ 10, 10, 10, 10 });
        b.BorderThickness({ 1, 1, 1, 1 });
        b.BorderBrush(Brush(chrome::Hairline(dark)));
        b.Background(Brush(dark ? 0x14FFFFFFu : 0x0A000000u));
        b.Padding({ 12, 10, 12, 12 });
        b.Margin({ 0, 4, 0, 0 });
        return b;
    }

    winrt::Windows::UI::Color Hex(uint32_t v)
    {
        return { 0xFF, (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    }

    std::string ShippedDataDir()
    {
        wchar_t exe[MAX_PATH]{};
        DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
        if (n == 0 || n >= MAX_PATH)
            return {};
        return (std::filesystem::path(exe).parent_path() / L"data" / L"firstrun").string();
    }

    BitmapImage ShippedPicture(wchar_t const *name)
    {
        if (name == nullptr)
            return nullptr;
        std::string const dir = ShippedDataDir();
        if (dir.empty())
            return nullptr;
        auto path = std::filesystem::path(dir) / name;
        std::error_code ec;
        if (!std::filesystem::exists(path, ec))
            return nullptr;
        std::wstring uri = L"file:///" + path.wstring();
        for (auto &c : uri)
            if (c == L'\\')
                c = L'/';
        try
        {
            return BitmapImage{ winrt::Windows::Foundation::Uri{ uri } };
        }
        catch (winrt::hresult_error const &)
        {
            return nullptr;
        }
    }

    void ButtonFills(Control const &c, uint32_t flat, uint32_t over, uint32_t down, uint32_t edge)
    {
        c.Background(Brush(flat));
        auto put = [&](wchar_t const *key, uint32_t argb) {
            c.Resources().Insert(winrt::box_value(winrt::hstring{ key }), Brush(argb));
        };
        put(L"ButtonBackground", flat);
        put(L"ButtonBackgroundPointerOver", over);
        put(L"ButtonBackgroundPressed", down);
        put(L"ButtonBackgroundDisabled", flat);
        put(L"ButtonBorderBrush", edge);
        put(L"ButtonBorderBrushPointerOver", edge);
        put(L"ButtonBorderBrushPressed", edge);
        put(L"ButtonBorderBrushDisabled", edge);
    }

    void FlatFills(Control const &c, bool dark, uint32_t edge)
    {
        ButtonFills(c, dark ? 0x00FFFFFFu : 0x00000000u, dark ? 0x14FFFFFFu : 0x0F000000u,
                    dark ? 0x1FFFFFFFu : 0x17000000u, edge);
    }
}
