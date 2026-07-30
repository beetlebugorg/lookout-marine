// The mariner settings pane: tabbed pages built from the live tile57_mariner,
// applied with a 60 ms debounce and saved on every apply.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <cmath>
#include <filesystem>

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
            return;
        }
        LoadSettings();
        SettingsPane().Visibility(Visibility::Visible);
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

        switch (settings_tab)
        {
        case 0: // Display
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
            break;
        }
        case 1: // Depths
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
            break;
        case 2: // Text & symbols
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
            break;
        case 3: // Charts
        {
            header(L"Open");
            Controls::TextBlock open_tb;
            open_tb.Text(lk_controller_is_open(controller)
                ? winrt::to_hstring(std::filesystem::path(lkw::InitialPaths().front()).filename().string())
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
            break;
        }
        case 4: // Advanced
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
            break;
        }

        settings_loading = false;
    }
}
