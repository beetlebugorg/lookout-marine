// The menu, in a bubble.
//
// The Mac takes its menus from the system bar, which stands outside the
// window. Windows has no such bar, and a bar inside the window would take a
// strip of water on every screen of an app whose whole point is the chart —
// so the commands hang off a bubble in the same chrome the zoom and the
// compass live in. It is also the one shape every shell can wear: the Mac,
// the iPad and the phone have no menu bar to put this in either.
//
// The items are the Mac's, in the Mac's order, saying the Mac's words
// (macos/LookoutMarine/Commands.swift): Chart and Vessels keep their own
// submenus so the two read the same, and what a mariner reaches for at the
// helm — open a chart, go full screen, settings — sits at the top level.
//
// Every item already had a keystroke; a keystroke nobody can find is not a
// command, so each one says what it is.
//
// The list is built fresh on every press because most of it names things that
// come and go: the charts opened lately, the raster sets covering THIS view,
// the tables the plugins declare.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <filesystem>

#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    using winrt::Microsoft::UI::Xaml::Controls::MenuFlyoutItem;
    using winrt::Microsoft::UI::Xaml::Controls::MenuFlyoutSeparator;
    using winrt::Microsoft::UI::Xaml::Controls::MenuFlyoutSubItem;
    using winrt::Microsoft::UI::Xaml::Controls::ToggleMenuFlyoutItem;
}

namespace winrt::LookoutMarine::implementation
{
    // One item: a label, the keystroke beside it, and what it does.
    Controls::MenuFlyoutItem MainWindow::MenuItem(winrt::hstring const &label,
                                                  winrt::hstring const &chord,
                                                  std::function<void()> action)
    {
        MenuFlyoutItem item;
        item.Text(label);
        if (!chord.empty())
            item.KeyboardAcceleratorTextOverride(chord);
        item.Click([action](auto &&, auto &&) { action(); });
        return item;
    }

    // Everything the Chart menu holds on the Mac.
    Controls::MenuFlyoutSubItem MainWindow::ChartMenu()
    {
        bool open = lk_controller_is_open(controller) != 0;
        MenuFlyoutSubItem chart;
        chart.Text(L"Chart");

        MenuFlyoutSubItem scheme;
        scheme.Text(L"Color Scheme");
        {
            int now = 0;
            if (open)
            {
                lk_readout r{};
                lk_controller_readout(controller, &r);
                now = r.scheme;
            }
            wchar_t const *names[] = { L"Day", L"Dusk", L"Night" };
            for (int i = 0; i < 3; ++i)
            {
                ToggleMenuFlyoutItem it;
                it.Text(names[i]);
                it.IsChecked(i == now);
                it.IsEnabled(open);
                it.Click([this, i](auto &&, auto &&) {
                    lk_controller_set_scheme(controller, i);
                    UpdateReadouts(true);
                });
                scheme.Items().Append(it);
            }
            scheme.Items().Append(MenuFlyoutSeparator{});
            scheme.Items().Append(MenuItem(L"Cycle", L"Ctrl+L", [this] { Command('l'); }));
        }
        chart.Items().Append(scheme);

        // The raster sets covering THIS view, the drawn one marked, then the
        // way back to no picture at all — the same list the pill opens.
        MenuFlyoutSubItem raster;
        raster.Text(L"Raster Chart");
        {
            int count = open ? lk_controller_raster_set_count(controller) : 0;
            int active = open ? lk_controller_raster_active_index(controller) : -1;
            bool any_in_view = false;
            for (int i = 0; i < count; ++i)
            {
                if (!lk_controller_raster_set_in_view(controller, (unsigned)i))
                    continue;
                any_in_view = true;
                char name[96];
                lk_controller_raster_set_name(controller, (unsigned)i, name, sizeof name);
                ToggleMenuFlyoutItem it;
                it.Text(winrt::to_hstring(name));
                it.IsChecked(i == active);
                it.Click([this, i](auto &&, auto &&) {
                    lk_controller_raster_select(controller, i);
                    UpdateReadouts(true);
                });
                raster.Items().Append(it);
            }
            if (any_in_view)
                raster.Items().Append(MenuFlyoutSeparator{});
            ToggleMenuFlyoutItem none;
            none.Text(L"None");
            none.IsChecked(active < 0);
            none.Click([this](auto &&, auto &&) {
                lk_controller_raster_select(controller, -1);
                UpdateReadouts(true);
            });
            raster.Items().Append(none);
            raster.IsEnabled(open && !raster_paths.empty());
        }
        chart.Items().Append(raster);

        {
            auto next = MenuItem(L"Next Raster Chart", L"Ctrl+I", [this] { Command('i'); });
            next.IsEnabled(open && !raster_paths.empty());
            chart.Items().Append(next);
        }
        chart.Items().Append(MenuItem(L"Add Raster Charts…", L"Ctrl+Shift+I",
                                      [this] { AddRasterFiles(); }));
        chart.Items().Append(MenuItem(L"Add a Folder of Raster Charts…", L"",
                                      [this] { AddRasterFolder(); }));
        {
            bool hidden = open && lk_controller_chart_hidden(controller);
            auto enc = MenuItem(hidden ? L"Show ENC Over Raster" : L"Hide ENC Over Raster",
                                L"Ctrl+Shift+H", [this] { Command('H'); });
            enc.IsEnabled(open);
            chart.Items().Append(enc);
        }

        chart.Items().Append(MenuFlyoutSeparator{});
        chart.Items().Append(MenuItem(L"Zoom In", L"Ctrl+Plus", [this] { Command('+'); }));
        chart.Items().Append(MenuItem(L"Zoom Out", L"Ctrl+Minus", [this] { Command('-'); }));
        chart.Items().Append(MenuItem(L"Zoom to Fit", L"Ctrl+0", [this] { Command('0'); }));
        chart.Items().Append(MenuItem(L"Zoom to Scale…", L"", [this] { ToggleScalePanel(); }));
        chart.Items().Append(MenuItem(L"Rotate to North-Up", L"Ctrl+Up", [this] { Command('u'); }));

        chart.Items().Append(MenuFlyoutSeparator{});
        chart.Items().Append(MenuItem(L"Toggle Text", L"Ctrl+T", [this] { Command('t'); }));
        chart.Items().Append(MenuItem(L"Toggle Soundings", L"Ctrl+Shift+S", [this] { Command('S'); }));
        chart.Items().Append(MenuItem(L"Toggle Other Category", L"Ctrl+D", [this] { Command('d'); }));
        return chart;
    }

    // One item per table a plugin declared. Every declaration lands here
    // whatever its own menu field says, until there is a second place to put
    // one.
    Controls::MenuFlyoutSubItem MainWindow::VesselsMenu()
    {
        MenuFlyoutSubItem vessels;
        vessels.Text(L"Vessels");
        if (tables.empty())
        {
            auto none = MenuItem(L"No Vessel Tables", L"", [] {});
            none.IsEnabled(false);
            vessels.Items().Append(none);
            vessels.IsEnabled(false);
        }
        for (auto const &spec : tables)
        {
            auto copy = spec;
            vessels.Items().Append(MenuItem(winrt::to_hstring(spec.title + "\xE2\x80\xA6"), L"",
                                            [this, copy] { OpenPluginTable(copy); }));
        }
        return vessels;
    }

    void MainWindow::ShowMainMenu()
    {
        Controls::MenuFlyout menu;
        // Beside the bubble, not over the chrome above it: the default drops
        // the list off the window's left edge and onto the desktop.
        menu.Placement(Controls::Primitives::FlyoutPlacementMode::RightEdgeAlignedTop);
        menu.Items().Append(ChartMenu());
        menu.Items().Append(VesselsMenu());

        menu.Items().Append(MenuFlyoutSeparator{});
        menu.Items().Append(MenuItem(L"Open Charts…", L"Ctrl+O", [this] { PickChartFolder(); }));
        menu.Items().Append(MenuItem(L"Open Chart File…", L"Ctrl+Shift+O", [this] { PickChartFile(); }));

        MenuFlyoutSubItem recents;
        recents.Text(L"Open Recent");
        {
            char **list = lk_store_load_recents();
            for (int i = 0; list != nullptr && list[i] != nullptr; ++i)
            {
                std::string path = list[i];
                std::string name = std::filesystem::path(path).filename().string();
                // The library's own entry gets the office's name when that is
                // what is open ("NOAA") — its directory name ("Charts") says
                // nothing. A label never carries a path separator; a path
                // fallback in open_chart_label does.
                if (path == lkw::ChartLibraryDir())
                    name = (!open_chart_label.empty() &&
                            open_chart_label.find_first_of("\\/") == std::string::npos)
                               ? open_chart_label
                               : "Chart Library";
                recents.Items().Append(MenuItem(winrt::to_hstring(name.empty() ? path : name), L"",
                                                [this, path] { OpenPaths(lkw::CellsFor(path), path); }));
            }
            lk_store_free_recents(list);
        }
        recents.IsEnabled(recents.Items().Size() > 0);
        menu.Items().Append(recents);
        menu.Items().Append(MenuItem(L"Install Plugin…", L"", [this] { PickPluginFile(); }));

        menu.Items().Append(MenuFlyoutSeparator{});
        menu.Items().Append(MenuItem(full_screen ? L"Leave Full Screen" : L"Full Screen", L"F11",
                                     [this] { ToggleFullScreen(); }));
        menu.Items().Append(MenuItem(L"Settings…", L"Ctrl+,", [this] { ShowSettings(); }));

        menu.ShowAt(MenuBtn());
    }
}
