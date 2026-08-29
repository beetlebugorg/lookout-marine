// Installing a plugin: the consent sheet, the install itself, and the file
// routing that gets a .lkplug here from a picker or a drop.
//
// NOTHING IS INSTALLED BEFORE ITS PERMISSIONS ARE SHOWN. The consent
// sentences come from the core (lookout_plugin_inspect), so every shell shows
// the same words; a reinstall calls out exactly what changed. The file router
// sends a folder or an archive to the chart import, asks the plugins about
// anything else (lookout_open_file), and falls back to opening a chart — the
// shell matches extensions only to find the consent sheet for a .lkplug and
// to tell an archive from a file, the same routing the Mac shell does.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <shobjidl.h>

#include <algorithm>
#include <cctype>
#include <filesystem>

#include "lk_bake.h"
#include "lk_format.h"
#include "lk_paths.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace winrt::Windows::Data::Json;

namespace
{
    bool IsPluginPackage(std::string const &path)
    {
        auto dot = path.find_last_of('.');
        if (dot == std::string::npos)
            return false;
        std::string ext = path.substr(dot);
        std::transform(ext.begin(), ext.end(), ext.begin(),
                       [](unsigned char c) { return (char)std::tolower(c); });
        return ext == ".lkplug";
    }

    winrt::Microsoft::UI::Xaml::Controls::TextBlock ConsentLine(winrt::hstring const &text,
                                                                double size, bool bold,
                                                                winrt::Windows::UI::Color color)
    {
        winrt::Microsoft::UI::Xaml::Controls::TextBlock tb;
        tb.Text(text);
        tb.FontSize(size);
        if (bold)
            tb.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
        tb.Foreground(winrt::Microsoft::UI::Xaml::Media::SolidColorBrush{ color });
        tb.TextWrapping(TextWrapping::Wrap);
        return tb;
    }

    constexpr winrt::Windows::UI::Color kAdd{ 0xFF, 0xE0, 0x9B, 0x2A };
}

namespace winrt::LookoutMarine::implementation
{
    fire_and_forget MainWindow::ShowPluginError(winrt::hstring msg)
    {
        auto lifetime = get_strong();
        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(winrt::box_value(L"Couldn't install plugin"));
        dialog.Content(winrt::box_value(msg));
        dialog.CloseButtonText(L"OK");
        co_await dialog.ShowAsync();
    }

    // The consent sheet, from the core's inspection of the package. Install
    // runs only from its Install button.
    fire_and_forget MainWindow::InstallPluginFromPath(std::string path)
    {
        auto lifetime = get_strong();

        // Parked, not refused: a .lkplug dropped at the empty state has no
        // chart handle for the plugin layer to ride, so it installs the
        // moment one opens instead of erroring now.
        if (!lk_controller_is_open(controller))
        {
            pending_plugin_install = path;
            co_return;
        }

        char *json = lk_controller_plugin_inspect(controller, path.c_str());
        if (json == nullptr)
        {
            ShowPluginError(L"The plugin layer could not start.");
            co_return;
        }

        winrt::hstring name, version, error;
        std::vector<winrt::hstring> sentences, adds, drops;
        winrt::hstring replaces;
        try
        {
            auto root = JsonObject::Parse(winrt::to_hstring(json));
            if (root.HasKey(L"error"))
                error = root.GetNamedString(L"error", L"");
            name = root.GetNamedString(L"name", L"");
            version = root.GetNamedString(L"version", L"");
            for (auto const &s : root.GetNamedArray(L"sentences", JsonArray{}))
                sentences.push_back(s.GetString());
            if (auto inst = root.TryLookup(L"installed"); inst && inst.ValueType() == JsonValueType::Object)
            {
                auto io = inst.GetObject();
                bool downgrade = io.GetNamedBoolean(L"downgrade", false);
                auto old_version = io.GetNamedString(L"version", L"");
                std::wstring line;
                if (downgrade)
                    line = std::wstring(L"Replaces ") + name.c_str() + L". This is a downgrade.";
                else
                    line = std::wstring(L"Replaces the installed version ") + old_version.c_str() + L".";
                if (io.GetNamedString(L"origin", L"") == L"developer")
                    line += L" The developer copy keeps running until its override is dropped.";
                replaces = winrt::hstring{ line };
                for (auto const &s : io.GetNamedArray(L"adds", JsonArray{}))
                    adds.push_back(s.GetString());
                for (auto const &s : io.GetNamedArray(L"drops", JsonArray{}))
                    drops.push_back(s.GetString());
            }
        }
        catch (winrt::hresult_error const &)
        {
            error = L"The plugin package could not be read.";
        }
        free(json);

        if (!error.empty())
        {
            ShowPluginError(error);
            co_return;
        }

        // The dialog wears the chart's scheme (its XamlRoot is Root's), so
        // the consent ink resolves against it: dark cards need light text.
        auto ink = lkw::Rgb(lkw::chrome::Ink(DarkChrome()));
        auto muted = lkw::Rgb(lkw::chrome::Muted(DarkChrome()));

        Controls::StackPanel body;
        body.Spacing(8);
        body.MaxWidth(420);
        if (!version.empty())
            body.Children().Append(ConsentLine(L"Version " + version, 12, false, muted));
        if (!replaces.empty())
            body.Children().Append(ConsentLine(replaces, 12, false, muted));
        body.Children().Append(ConsentLine(
            replaces.empty() ? L"This plugin can:" : L"After this install it can:", 13, true, ink));
        if (sentences.empty())
            body.Children().Append(ConsentLine(L"This plugin only draws its own settings pages.",
                                               13, false, ink));
        for (auto const &s : sentences)
            body.Children().Append(ConsentLine(s, 13, false, ink));
        if (!adds.empty())
        {
            body.Children().Append(ConsentLine(L"New since the installed version:", 12, true, kAdd));
            for (auto const &s : adds)
                body.Children().Append(ConsentLine(s, 12, false, kAdd));
        }
        if (!drops.empty())
        {
            body.Children().Append(ConsentLine(L"No longer asks to:", 12, true, muted));
            for (auto const &s : drops)
                body.Children().Append(ConsentLine(s, 12, false, muted));
        }

        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(winrt::box_value(name.empty() ? L"Install Plugin" : name));
        dialog.Content(body);
        dialog.PrimaryButtonText(L"Install");
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(Controls::ContentDialogButton::Primary);

        auto result = co_await dialog.ShowAsync();
        if (result != Controls::ContentDialogResult::Primary)
            co_return;

        char *err = lk_controller_plugin_install(controller, path.c_str());
        if (err != nullptr)
        {
            ShowPluginError(winrt::to_hstring(err));
            free(err);
            co_return;
        }

        // The plugin is live: its tables and settings sections exist now.
        RefreshPluginTables();
        if (SettingsOpen())
            LoadSettings();
    }

    fire_and_forget MainWindow::PickPluginFile()
    {
        auto lifetime = get_strong();
        Windows::Storage::Pickers::FileOpenPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(top_hwnd);
        picker.FileTypeFilter().Append(L".lkplug");
        auto file = co_await picker.PickSingleFileAsync();
        if (file != nullptr)
            InstallPluginFromPath(winrt::to_string(file.Path()));
    }

    fire_and_forget MainWindow::HandleDrop(Microsoft::UI::Xaml::DragEventArgs e)
    {
        auto lifetime = get_strong();
        if (!e.DataView().Contains(winrt::Windows::ApplicationModel::DataTransfer::StandardDataFormats::StorageItems()))
            co_return;
        auto items = co_await e.DataView().GetStorageItemsAsync();
        for (auto const &item : items)
            OpenDroppedPath(winrt::to_string(item.Path()));
    }

    // Every file that arrives from outside — a drop today, an association
    // tomorrow — takes one path: consent for a plugin package, the plugins'
    // own file types next, a chart last. The shell never guesses beyond the
    // consent sheet.
    void MainWindow::OpenDroppedPath(std::string const &path)
    {
        if (IsPluginPackage(path))
        {
            InstallPluginFromPath(path);
            return;
        }
        // A folder or an archive is a library arriving, not a file for a
        // plugin: a chart agency's whole catalogue is one zip. Import scans
        // it, bakes what is raw and opens what it holds.
        std::error_code ec;
        if (std::filesystem::is_directory(path, ec) || lkw::IsArchive(path))
        {
            ImportCharts(path);
            return;
        }
        int taken = lk_controller_open_file(controller, path.c_str());
        if (taken == 1)
        {
            UpdateReadouts();
            return;
        }
        if (taken == -1)
        {
            ShowPluginError(L"A plugin claims this file type but could not take the file.");
            return;
        }
        auto cells = lkw::CellsFor(path);
        if (!cells.empty())
            OpenPaths(cells, path);
    }
}
