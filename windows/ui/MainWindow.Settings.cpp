// The mariner settings pane: tabbed pages built from the live tile57_mariner,
// applied with a 60 ms debounce and saved on every apply.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <microsoft.ui.xaml.window.h> // IWindowNative, for the window's icon

#include <cmath>
#include <filesystem>
#include <map>

#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    // The settings have their own window. Over the chart they had to dodge
    // the readouts and the corner bubbles, which left no room for a list
    // beside a form and put the pane under the chrome it covered.
    //
    // The markup is built with the main window (it names the two panels the
    // code fills), so it is taken out of the chart's tree here and handed to
    // the settings window. It goes back the same way when that window closes.
    bool MainWindow::SettingsOpen()
    {
        return settings_window != nullptr;
    }

    // A dialog belongs to the window that raised it: an uninstall asked for
    // in the settings must not open behind them, over the chart.
    Microsoft::UI::Xaml::XamlRoot MainWindow::DialogRoot()
    {
        if (settings_window != nullptr)
            if (auto content = settings_window.Content())
                return content.XamlRoot();
        return Root().XamlRoot();
    }

    void MainWindow::DetachSettingsPane()
    {
        uint32_t idx = 0;
        if (Root().Children().IndexOf(SettingsPane(), idx))
            Root().Children().RemoveAt(idx);
        SettingsPane().Visibility(Visibility::Visible);
    }

    void MainWindow::ShowSettings()
    {
        if (settings_window != nullptr)
        {
            settings_window.Activate(); // a second ask brings it forward
            return;
        }

        LoadSettings();

        Window w;
        w.Title(L"Mariner Settings");
        w.Content(SettingsPane());
        settings_window = w;

        // Big enough for a list beside a form, and it opens where it was left:
        // a mariner who widened it to read a connection's address should not
        // widen it again next time.
        //
        // ResizeClient counts PHYSICAL pixels, so the size a layout is written
        // in has to be scaled: asking for 720 on a 150% display gave a window
        // 480 points wide, which is narrower than the form inside it.
        auto app_window = w.AppWindow();
        int width = 0, height = 0;
        if (!lk_store_load_settings_size(&width, &height) || width < 480 || height < 380)
        {
            double density = Density();
            width = (int)(720 * density);
            height = (int)(560 * density);
        }
        app_window.ResizeClient({ width, height });

        app_window.Changed([this](auto &&sender, auto &&args) {
            if (args.DidSizeChange())
            {
                auto size = sender.ClientSize();
                lk_store_save_settings_size(size.Width, size.Height);
            }
        });

        w.Closed([this](auto &&, auto &&) {
            StopPluginStatusPoll();
            if (settings_window != nullptr)
                settings_window.Content(nullptr); // the markup outlives the window
            settings_window = nullptr;
        });

        // The app's mark, so the settings wear it in Alt-Tab and the taskbar
        // rather than the stock WinUI one.
        HWND hwnd = nullptr;
        if (auto native = w.try_as<::IWindowNative>())
            if (SUCCEEDED(native->get_WindowHandle(&hwnd)))
                ApplyWindowIcon(hwnd);

        w.Activate();
        // While the window is up, the connection lines move on their own.
        StartPluginStatusPoll();
    }

    void MainWindow::CloseSettings()
    {
        if (settings_window != nullptr)
            settings_window.Close();
    }

    void MainWindow::ToggleSettings()
    {
        if (SettingsOpen())
            CloseSettings();
        else
            ShowSettings();
    }

    // The sections, in the order the strip shows them. The four the app owns are
    // always listed; Vessels, Alarms and Connections only while something puts
    // settings in them, and today that something is a plugin — the mariner is
    // never told which. Plugins is the one section that talks ABOUT plugins.
    // Advanced is last: it is where anything unclaimed lands.
    void MainWindow::BuildSettingsTabs()
    {
        std::string selected = settings_tab >= 0 && settings_tab < (int)settings_tabs.size()
                                   ? settings_tabs[settings_tab].id
                                   : "display";

        settings_tabs.clear();
        settings_tabs.push_back({ "display", L"Display", L"\uE790" });
        settings_tabs.push_back({ "depths", L"Depths", L"\uEC48" });
        settings_tabs.push_back({ "text", L"Text", L"\uE8D2" });
        settings_tabs.push_back({ "charts", L"Charts", L"\uE774" });
        if (PluginTabPopulated("vessels"))
            settings_tabs.push_back({ "vessels", L"Vessels", L"\uE7C0" });
        if (PluginTabPopulated("alarms"))
            settings_tabs.push_back({ "alarms", L"Alarms", L"\uEA8F" });
        if (PluginTabPopulated("connections"))
            settings_tabs.push_back({ "connections", L"Connections", L"\uE701" });
        // Plugins is the one section that talks ABOUT plugins: install,
        // grants, uninstall. It is the app's own, not a slot a schema fills.
        settings_tabs.push_back({ "plugins", L"Plugins", L"\uE71D" });
        settings_tabs.push_back({ "advanced", L"Advanced", L"\uE713" });

        // A section can go away — a plugin that never came up takes its section
        // with it — so a stale selection falls back rather than indexing off the
        // end of the strip.
        settings_tab = 0;
        for (int i = 0; i < (int)settings_tabs.size(); ++i)
        {
            if (settings_tabs[i].id == selected)
                settings_tab = i;
        }

        // One row per section, down the left: its mark, its name, and the
        // selection behind whichever one is on screen. The list IS the
        // navigation, so there is no way to collapse it away.
        auto list = SettingsTabs();
        list.Children().Clear();
        for (int i = 0; i < (int)settings_tabs.size(); ++i)
        {
            Controls::Button row;
            row.HorizontalAlignment(HorizontalAlignment::Stretch);
            row.HorizontalContentAlignment(HorizontalAlignment::Left);
            row.Padding({ 10, 7, 10, 7 });
            row.CornerRadius({ 6, 6, 6, 6 });
            row.BorderThickness({ 0, 0, 0, 0 });
            row.Background(Media::SolidColorBrush{ i == settings_tab
                                                      ? winrt::Windows::UI::Color{ 0x28, 0x00, 0x00, 0x00 }
                                                      : winrt::Windows::UI::Color{ 0, 0, 0, 0 } });

            Controls::StackPanel content;
            content.Orientation(Controls::Orientation::Horizontal);
            content.Spacing(10);
            Controls::FontIcon icon;
            icon.Glyph(winrt::hstring{ settings_tabs[i].glyph });
            icon.FontSize(14);
            icon.Opacity(0.85);
            content.Children().Append(icon);
            Controls::TextBlock label;
            label.Text(winrt::hstring{ settings_tabs[i].label });
            label.FontSize(13);
            label.VerticalAlignment(VerticalAlignment::Center);
            content.Children().Append(label);
            row.Content(content);

            row.Click([this, i](auto &&, auto &&) {
                settings_tab = i;
                for (uint32_t j = 0; j < SettingsTabs().Children().Size(); ++j)
                {
                    auto b = SettingsTabs().Children().GetAt(j).as<Controls::Button>();
                    b.Background(Media::SolidColorBrush{ (int)j == i ? winrt::Windows::UI::Color{ 0x28, 0x00, 0x00, 0x00 }
                                                                     : winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
                }
                BuildSettingsPage();
            });
            list.Children().Append(row);
        }
    }

    // Open the settings on one section by its id ("connections" from the GPS
    // pill). A section a plugin never populated falls back to the first one.
    void MainWindow::OpenSettingsTab(std::string const &id)
    {
        ShowSettings();
        for (int i = 0; i < (int)settings_tabs.size(); ++i)
            if (settings_tabs[i].id == id)
                settings_tab = i;
        BuildSettingsTabs();
        BuildSettingsPage();
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
        // The pane wears the chart's scheme: dusk and night take the dark
        // palette whatever the OS says — a bright panel has no place on a
        // night passage. Day follows the app default.
        bool dark = pending.scheme != 0;
        SettingsPane().RequestedTheme(dark ? ElementTheme::Dark : ElementTheme::Default);
        SettingsPane().Background(Media::SolidColorBrush{
            dark ? winrt::Windows::UI::Color{ 0xFF, 0x20, 0x24, 0x28 }
                 : winrt::Windows::UI::Color{ 0xFF, 0xF8, 0xF8, 0xF8 } });
        // The plugin schemas are read here, not at construction: there is no
        // plugin layer until a chart opens. What a plugin DECLARES does not
        // change while the pane is up, so this is the only whole read.
        ReloadPlugins();
        BuildSettingsTabs();
        BuildSettingsPage();
    }

    void MainWindow::BuildSettingsPage()
    {
        settings_loading = true;

        auto stack = SettingsContent();
        stack.Children().Clear();
        // The controls the status poll updates in place died with that Clear.
        plugin_status_ui.clear();

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

        std::string tab = settings_tab >= 0 && settings_tab < (int)settings_tabs.size()
                              ? settings_tabs[settings_tab].id
                              : "display";

        if (tab == "display")
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
        }
        else if (tab == "depths")
        {
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
        }
        else if (tab == "text")
        {
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
        }
        else if (tab == "charts")
        {
            header(L"Open");
            Controls::TextBlock open_tb;
            open_tb.Text(lk_controller_is_open(controller) && !open_chart_label.empty()
                ? winrt::to_hstring(std::filesystem::path(open_chart_label).filename().string())
                : L"No chart open");
            open_tb.FontSize(12);
            stack.Children().Append(open_tb);

            header(L"Recent");
            char **recents = lk_store_load_recents();
            for (int i = 0; recents != nullptr && recents[i] != nullptr; ++i)
            {
                std::string path = recents[i];
                std::string name = std::filesystem::path(path).filename().string();
                // Same naming as the Open Recent menu: the library's entry is
                // the office whose charts are open, never "Charts".
                if (path == lkw::ChartLibraryDir())
                    name = (!open_chart_label.empty() &&
                            open_chart_label.find_first_of("\\/") == std::string::npos)
                               ? open_chart_label
                               : "Chart Library";
                Controls::Button b;
                b.Content(winrt::box_value(winrt::to_hstring(name.empty() ? path : name)));
                b.HorizontalAlignment(HorizontalAlignment::Stretch);
                b.Click([this, path](auto &&, auto &&) { OpenPaths(lkw::CellsFor(path), path); });
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

            // ---- raster charts: what is installed, grouped the way the
            // engine groups sets, each file with its own on/off (half-gigabyte
            // downloads are switched off, not deleted) and a remove.
            header(L"Raster charts");
            if (raster_paths.empty())
            {
                Controls::TextBlock none;
                none.Text(L"No raster charts");
                none.FontSize(12);
                none.Opacity(0.7);
                stack.Children().Append(none);
            }
            else
            {
                // The store carries the enabled flags (the live handle cannot
                // answer for a file that failed to install this session).
                std::map<std::string, bool> on;
                {
                    int *enabled = nullptr;
                    char **stored = lk_store_load_rasters(&enabled);
                    for (int i = 0; stored != nullptr && stored[i] != nullptr; ++i)
                        on[stored[i]] = enabled[i] != 0;
                    lk_store_free_rasters(stored, enabled);
                }

                // Group by the engine's set name, first-seen order, so what
                // Settings shows and what the pill cycles are the same thing.
                std::vector<std::pair<std::string, std::vector<std::string>>> groups;
                for (auto const &p : raster_paths)
                {
                    std::string g = lkw::RasterSetNameFor(p);
                    auto it = std::find_if(groups.begin(), groups.end(),
                                           [&](auto const &e) { return e.first == g; });
                    if (it == groups.end())
                        groups.push_back({ g, { p } });
                    else
                        it->second.push_back(p);
                }

                auto set_file_enabled = [this](std::string const &path, bool v) {
                    lk_store_set_raster_enabled(path.c_str(), v ? 1 : 0);
                    lk_controller_raster_set_enabled(controller, path.c_str(), v ? 1 : 0);
                };
                auto set_group_enabled = [this](std::vector<std::string> const &files, bool v) {
                    std::vector<const char *> cps;
                    for (auto const &p : files)
                        cps.push_back(p.c_str());
                    lk_store_set_rasters_enabled(cps.data(), (int)cps.size(), v ? 1 : 0);
                    for (auto const &p : files)
                        lk_controller_raster_set_enabled(controller, p.c_str(), v ? 1 : 0);
                };
                auto remove_group = [this](std::vector<std::string> const &files) {
                    std::vector<const char *> cps;
                    for (auto const &p : files)
                        cps.push_back(p.c_str());
                    lk_store_forget_rasters(cps.data(), (int)cps.size());
                    for (auto const &p : files)
                    {
                        lk_controller_raster_set_enabled(controller, p.c_str(), 0);
                        raster_paths.erase(
                            std::remove(raster_paths.begin(), raster_paths.end(), p),
                            raster_paths.end());
                    }
                };
                auto mini_switch = [this](bool is_on, auto &&set) {
                    Controls::ToggleSwitch ts;
                    ts.OnContent(nullptr);
                    ts.OffContent(nullptr);
                    ts.MinWidth(0);
                    ts.IsOn(is_on);
                    ts.Toggled([this, set](auto &&s, auto &&) {
                        if (settings_loading)
                            return;
                        set(s.template as<Controls::ToggleSwitch>().IsOn());
                        UpdateReadouts(true);
                        BuildSettingsPage();
                    });
                    return ts;
                };

                for (auto const &[gname, files] : groups)
                {
                    bool group_on = false;
                    for (auto const &p : files)
                        group_on = group_on || on.count(p) == 0 || on[p];

                    Controls::Grid row;
                    Controls::ColumnDefinition c0, c1, c2, c3;
                    c0.Width({ 0, GridUnitType::Auto });
                    c1.Width({ 1, GridUnitType::Star });
                    c2.Width({ 0, GridUnitType::Auto });
                    c3.Width({ 0, GridUnitType::Auto });
                    row.ColumnDefinitions().ReplaceAll({ c0, c1, c2, c3 });

                    auto gts = mini_switch(group_on, [this, set_group_enabled, files](bool v) {
                        set_group_enabled(files, v);
                    });
                    row.Children().Append(gts);

                    Controls::TextBlock name;
                    name.Text(winrt::to_hstring(gname));
                    name.FontWeight(winrt::Windows::UI::Text::FontWeights::Medium());
                    name.Opacity(group_on ? 1.0 : 0.6);
                    name.VerticalAlignment(VerticalAlignment::Center);
                    name.TextTrimming(TextTrimming::CharacterEllipsis);
                    Controls::Grid::SetColumn(name, 1);
                    row.Children().Append(name);

                    Controls::TextBlock count;
                    count.Text(winrt::to_hstring(files.size() == 1
                        ? std::string("1 file")
                        : std::to_string(files.size()) + " files"));
                    count.FontSize(11);
                    count.Opacity(0.7);
                    count.VerticalAlignment(VerticalAlignment::Center);
                    Controls::Grid::SetColumn(count, 2);
                    row.Children().Append(count);

                    Controls::Button grm;
                    Controls::FontIcon gminus;
                    gminus.Glyph(L"\uE738"); // Remove
                    gminus.FontSize(12);
                    grm.Content(gminus);
                    grm.Padding({ 4, 2, 4, 2 });
                    grm.Background(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
                    grm.BorderThickness({ 0, 0, 0, 0 });
                    Automation::AutomationProperties::SetName(grm,
                        L"Remove the whole set. Takes full effect the next time a chart opens.");
                    grm.Click([this, remove_group, files](auto &&, auto &&) {
                        remove_group(files);
                        UpdateReadouts(true);
                        BuildSettingsPage();
                    });
                    Controls::Grid::SetColumn(grm, 3);
                    row.Children().Append(grm);
                    stack.Children().Append(row);

                    // A baked bundle is hundreds of sheets: no mariner switches
                    // those one by one, and hundreds of rows stall the pane.
                    // The group row carries the whole set; files list only when
                    // the set is small enough to reason about per file.
                    if (files.size() > 16)
                        continue;

                    for (auto const &p : files)
                    {
                        bool file_on = on.count(p) == 0 || on[p];

                        Controls::Grid frow;
                        Controls::ColumnDefinition f0, f1, f2;
                        f0.Width({ 0, GridUnitType::Auto });
                        f1.Width({ 1, GridUnitType::Star });
                        f2.Width({ 0, GridUnitType::Auto });
                        frow.ColumnDefinitions().ReplaceAll({ f0, f1, f2 });
                        frow.Margin({ 22, 0, 0, 0 });

                        auto fts = mini_switch(file_on, [this, set_file_enabled, p](bool v) {
                            set_file_enabled(p, v);
                        });
                        frow.Children().Append(fts);

                        Controls::TextBlock fname;
                        fname.Text(winrt::to_hstring(std::filesystem::path(p).filename().string()));
                        fname.FontSize(11);
                        fname.Opacity(file_on ? 1.0 : 0.6);
                        fname.VerticalAlignment(VerticalAlignment::Center);
                        fname.TextTrimming(TextTrimming::CharacterEllipsis);
                        Controls::Grid::SetColumn(fname, 1);
                        frow.Children().Append(fname);

                        Controls::Button rm;
                        Controls::FontIcon minus;
                        minus.Glyph(L"\uE738"); // Remove
                        minus.FontSize(12);
                        rm.Content(minus);
                        rm.Padding({ 4, 2, 4, 2 });
                        rm.Background(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
                        rm.BorderThickness({ 0, 0, 0, 0 });
                        Automation::AutomationProperties::SetName(rm,
                            L"Remove. Takes full effect the next time a chart opens.");
                        rm.Click([this, p](auto &&, auto &&) {
                            lk_store_forget_raster(p.c_str());
                            raster_paths.erase(
                                std::remove(raster_paths.begin(), raster_paths.end(), p),
                                raster_paths.end());
                            // The engine has no remove: quiet it on the live
                            // handle, and the next open drops it for good.
                            lk_controller_raster_set_enabled(controller, p.c_str(), 0);
                            UpdateReadouts(true);
                            BuildSettingsPage();
                        });
                        Controls::Grid::SetColumn(rm, 2);
                        frow.Children().Append(rm);
                        stack.Children().Append(frow);
                    }
                }
            }

            Controls::Button add_raster;
            add_raster.Content(winrt::box_value(L"Add Raster Charts…"));
            add_raster.HorizontalAlignment(HorizontalAlignment::Stretch);
            add_raster.Margin({ 0, 8, 0, 0 });
            add_raster.Click([this](auto &&, auto &&) { AddRasterFiles(); });
            stack.Children().Append(add_raster);

            Controls::Button add_raster_dir;
            add_raster_dir.Content(winrt::box_value(L"Add a Folder of Raster Charts…"));
            add_raster_dir.HorizontalAlignment(HorizontalAlignment::Stretch);
            add_raster_dir.Click([this](auto &&, auto &&) { AddRasterFolder(); });
            stack.Children().Append(add_raster_dir);

            Controls::TextBlock raster_foot;
            raster_foot.Text(L"Charts made of pictures: MBTiles of satellite imagery or "
                             L"another vendor's charts, and BSB/KAP raster nautical charts "
                             L"baked with tile57. The ENC draws over them and drops its "
                             L"depth and land shading only where they cover. Switch one "
                             L"off to keep it installed without drawing it.");
            raster_foot.FontSize(11);
            raster_foot.Opacity(0.7);
            raster_foot.TextWrapping(TextWrapping::Wrap);
            stack.Children().Append(raster_foot);

            // ---- charts by link: an online map AS the chart. Picking one
            // renders that publisher's MapLibre style instead of the built-in
            // portrayal — Lookout's own chart is just the default entry in
            // the same list (the reference shell's Chart list, row for row).
            header(L"Chart");
            auto link_row = [this](std::string const &url, std::string const &title,
                                   std::string const &sub, bool removable) {
                Controls::Grid row;
                Controls::ColumnDefinition c0, c1, c2, c3;
                c0.Width({ 0, GridUnitType::Auto });
                c1.Width({ 1, GridUnitType::Star });
                c2.Width({ 0, GridUnitType::Auto });
                c3.Width({ 0, GridUnitType::Auto });
                row.ColumnDefinitions().ReplaceAll({ c0, c1, c2, c3 });

                Controls::RadioButton pick;
                pick.GroupName(L"chartlink");
                pick.IsChecked(active_chart_link == url);
                pick.MinWidth(0);
                pick.Checked([this, url](auto &&, auto &&) {
                    if (!settings_loading && active_chart_link != url)
                        SelectChartLink(url);
                });
                row.Children().Append(pick);

                Controls::StackPanel text;
                Controls::TextBlock name;
                name.Text(winrt::to_hstring(title));
                name.TextTrimming(TextTrimming::CharacterEllipsis);
                text.Children().Append(name);
                if (!sub.empty())
                {
                    Controls::TextBlock s;
                    s.Text(winrt::to_hstring(sub));
                    s.FontSize(11);
                    s.Opacity(0.7);
                    s.TextTrimming(TextTrimming::CharacterEllipsis);
                    text.Children().Append(s);
                }
                text.VerticalAlignment(VerticalAlignment::Center);
                Controls::Grid::SetColumn(text, 1);
                row.Children().Append(text);

                if (removable)
                {
                    Controls::Button refresh;
                    refresh.Content(winrt::box_value(L"Refresh"));
                    refresh.FontSize(11);
                    refresh.Padding({ 6, 2, 6, 2 });
                    refresh.Click([this, url](auto &&, auto &&) { RefreshChartLink(url); });
                    Controls::Grid::SetColumn(refresh, 2);
                    row.Children().Append(refresh);

                    Controls::Button rm;
                    Controls::FontIcon minus;
                    minus.Glyph(L"");
                    minus.FontSize(12);
                    rm.Content(minus);
                    rm.Padding({ 4, 2, 4, 2 });
                    rm.Background(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
                    rm.BorderThickness({ 0, 0, 0, 0 });
                    rm.Click([this, url](auto &&, auto &&) { RemoveChartLink(url); });
                    Controls::Grid::SetColumn(rm, 3);
                    row.Children().Append(rm);
                }
                stack.Children().Append(row);
            };
            link_row("", "Lookout chart", "The built-in portrayal of your opened cells.", false);
            for (auto const &l : chart_links)
                link_row(l.url, l.name.empty() ? l.url : l.name, l.url, true);

            // Add by link, committed on Enter like every other field.
            Controls::TextBox link_box;
            link_box.PlaceholderText(L"https://…/style.json");
            link_box.Margin({ 0, 6, 0, 0 });
            link_box.KeyDown([this](auto &&s, auto &&e) {
                if (e.Key() != Windows::System::VirtualKey::Enter)
                    return;
                auto box = s.template as<Controls::TextBox>();
                auto text = winrt::to_string(box.Text());
                if (!text.empty())
                {
                    AddChartLink(text);
                    box.Text(L"");
                }
            });
            stack.Children().Append(link_box);

            if (!chart_link_error.empty())
            {
                Controls::TextBlock err;
                err.Text(winrt::to_hstring(chart_link_error));
                err.FontSize(11);
                err.Foreground(lkw::Brush(lkw::chrome::kAmber));
                err.TextWrapping(TextWrapping::Wrap);
                stack.Children().Append(err);
            }

            Controls::TextBlock link_foot;
            link_foot.Text(L"A chart added by link draws INSTEAD of Lookout's own: the "
                           L"publisher styles it and their tiles are fetched as you sail. "
                           L"A style link or a TileJSON tile source; also a style.json "
                           L"on this machine by path.");
            link_foot.FontSize(11);
            link_foot.Opacity(0.7);
            link_foot.TextWrapping(TextWrapping::Wrap);
            stack.Children().Append(link_foot);
        }
        else if (tab == "advanced")
        {
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
                /* Commits on Enter or focus loss, never per keystroke — half
                 * a date is not a date the chart should redraw against. */
                auto commit_date = [this](Controls::TextBox const &b) {
                    if (settings_loading)
                        return;
                    std::string t = winrt::to_string(b.Text());
                    memset(pending.date_view, 0, sizeof pending.date_view);
                    strncpy_s(pending.date_view, t.c_str(), sizeof pending.date_view - 1);
                    ScheduleApply();
                };
                date.LostFocus([commit_date](auto &&s, auto &&) {
                    commit_date(s.template as<Controls::TextBox>());
                });
                date.KeyDown([commit_date](auto &&s, auto &&e) {
                    if (e.Key() == Windows::System::VirtualKey::Enter)
                        commit_date(s.template as<Controls::TextBox>());
                });
                stack.Children().Append(date);
            }
        }
        else if (tab == "plugins")
        {
            BuildPluginsPage();
        }

        // Whatever a plugin filed under this section, after the app's own
        // settings for it. A section nothing contributed to draws nothing.
        if (tab != "plugins")
            BuildPluginSections(tab);

        settings_loading = false;
    }
}
