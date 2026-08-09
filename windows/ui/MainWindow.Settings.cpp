// The mariner settings pane: tabbed pages built from the live tile57_mariner,
// applied with a 60 ms debounce and saved on every apply.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>
#include <filesystem>
#include <map>

#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::ToggleSettings()
    {
        if (SettingsPane().Visibility() == Visibility::Visible)
        {
            SettingsPane().Visibility(Visibility::Collapsed);
            StopPluginStatusPoll();
            return;
        }
        LoadSettings();
        SettingsPane().Visibility(Visibility::Visible);
        // While the pane is up, the connection lines move on their own.
        StartPluginStatusPoll();
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
        settings_tabs.push_back({ "display", L"Display" });
        settings_tabs.push_back({ "depths", L"Depths" });
        settings_tabs.push_back({ "text", L"Text" });
        settings_tabs.push_back({ "charts", L"Charts" });
        if (PluginTabPopulated("vessels"))
            settings_tabs.push_back({ "vessels", L"Vessels" });
        if (PluginTabPopulated("alarms"))
            settings_tabs.push_back({ "alarms", L"Alarms" });
        if (PluginTabPopulated("connections"))
            settings_tabs.push_back({ "connections", L"Connections" });
        if (!plugins.empty())
            settings_tabs.push_back({ "plugins", L"Plugins" });
        settings_tabs.push_back({ "advanced", L"Advanced" });

        // A section can go away — a plugin that never came up takes its section
        // with it — so a stale selection falls back rather than indexing off the
        // end of the strip.
        settings_tab = 0;
        for (int i = 0; i < (int)settings_tabs.size(); ++i)
        {
            if (settings_tabs[i].id == selected)
                settings_tab = i;
        }

        auto strip = SettingsTabs();
        strip.Children().Clear();
        for (int i = 0; i < (int)settings_tabs.size(); ++i)
        {
            Controls::Button tb;
            tb.Content(winrt::box_value(winrt::hstring{ settings_tabs[i].label }));
            tb.Padding({ 10, 4, 10, 6 });
            tb.CornerRadius({ 14, 14, 14, 14 });
            tb.BorderThickness({ 0, 0, 0, 0 });
            tb.Background(Media::SolidColorBrush{ i == settings_tab
                                                      ? winrt::Windows::UI::Color{ 0x28, 0x00, 0x00, 0x00 }
                                                      : winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
            tb.Click([this, i](auto &&, auto &&) {
                settings_tab = i;
                for (uint32_t j = 0; j < SettingsTabs().Children().Size(); ++j)
                {
                    auto b = SettingsTabs().Children().GetAt(j).as<Controls::Button>();
                    b.Background(Media::SolidColorBrush{ (int)j == i ? winrt::Windows::UI::Color{ 0x28, 0x00, 0x00, 0x00 }
                                                                     : winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
                }
                BuildSettingsPage();
            });
            strip.Children().Append(tb);
        }
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
                    Controls::ColumnDefinition c0, c1, c2;
                    c0.Width({ 0, GridUnitType::Auto });
                    c1.Width({ 1, GridUnitType::Star });
                    c2.Width({ 0, GridUnitType::Auto });
                    row.ColumnDefinitions().ReplaceAll({ c0, c1, c2 });

                    auto gts = mini_switch(group_on, [this, set_file_enabled, files](bool v) {
                        for (auto const &p : files)
                            set_file_enabled(p, v);
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
                    stack.Children().Append(row);

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
                date.TextChanged([this](auto &&s, auto &&) {
                    if (settings_loading)
                        return;
                    std::string t = winrt::to_string(s.template as<Controls::TextBox>().Text());
                    memset(pending.date_view, 0, sizeof pending.date_view);
                    strncpy_s(pending.date_view, t.c_str(), sizeof pending.date_view - 1);
                    ScheduleApply();
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
