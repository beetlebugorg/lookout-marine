// The mariner settings pane: tabbed pages built from the live tile57_mariner,
// applied with a 60 ms debounce and saved on every apply.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <microsoft.ui.xaml.window.h> // IWindowNative, for the window's icon

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <map>

#include "lk_format.h"
#include "lk_licenses.h"
#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    /* The chart colours of one scheme: the presentation library's own sRGB
     * values (S-101 colour profile, tokens DEPDW/DEPMD/DEPMS/DEPVS/LANDA/
     * CSTLN), copied so a swatch can be drawn without opening a chart. A
     * legend of the palette, not the palette itself — the engine draws from
     * the tables in the chart (the reference's SchemePalette, hex for hex). */
    struct SchemePalette
    {
        winrt::Windows::UI::Color deep, medium, shallow, very_shallow, land, coastline;
    };

    winrt::Windows::UI::Color Hex(uint32_t v)
    {
        return { 0xFF, (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    }

    SchemePalette PaletteOf(int scheme)
    {
        switch (scheme)
        {
        case 1: // dusk
            return { Hex(0x000000), Hex(0x0f1b21), Hex(0x1d3246),
                     Hex(0x1e4165), Hex(0x40402e), Hex(0x6b7f89) };
        case 2: // night
            return { Hex(0x000000), Hex(0x03070a), Hex(0x050e16),
                     Hex(0x071727), Hex(0x17160e), Hex(0x252d31) };
        default: // day
            return { Hex(0xc9edff), Hex(0xa7d9fb), Hex(0x82caff),
                     Hex(0x61b7ff), Hex(0xbfbe8f), Hex(0x4c5b63) };
        }
    }

    /* A shore in one scheme: the four depth shades out to deep water, then
     * land behind a curved coastline. A piece of chart, not a colour chip.
     * Drawn at a fixed design size and stretched by a Viewbox, so the Bezier
     * needs no size handling. */
    Controls::Viewbox SchemeSwatch(SchemePalette const &p)
    {
        Controls::Grid design;
        design.Width(100);
        design.Height(78);

        Controls::StackPanel bands;
        auto band = [&](winrt::Windows::UI::Color c, double h) {
            Controls::Border b;
            b.Background(Media::SolidColorBrush{ c });
            b.Height(h);
            bands.Children().Append(b);
        };
        band(p.deep, 78 * 0.36);
        band(p.medium, 78 * 0.18);
        band(p.shallow, 78 * 0.16);
        band(p.very_shallow, 78 * 0.30);
        design.Children().Append(bands);

        // The shoreline: a bay open to the top-left, land filling the corner.
        Media::PathFigure fig;
        fig.StartPoint({ 0, 78 });
        fig.IsClosed(true);
        Media::LineSegment l1;
        l1.Point({ 0, 78 * 0.80f });
        Media::BezierSegment bez;
        bez.Point1({ 100 * 0.35f, 78 * 0.74f });
        bez.Point2({ 100 * 0.60f, 78 * 0.44f });
        bez.Point3({ 100, 78 * 0.52f });
        Media::LineSegment l2;
        l2.Point({ 100, 78 });
        fig.Segments().Append(l1);
        fig.Segments().Append(bez);
        fig.Segments().Append(l2);
        Media::PathGeometry geo;
        geo.Figures().Append(fig);
        Shapes::Path shore;
        shore.Data(geo);
        shore.Fill(Media::SolidColorBrush{ p.land });
        shore.Stroke(Media::SolidColorBrush{ p.coastline });
        shore.StrokeThickness(1.5);
        design.Children().Append(shore);

        Controls::Viewbox vb;
        vb.Stretch(Media::Stretch::Fill);
        vb.Child(design);
        return vb;
    }
}

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

        // Remembered per event, WRITTEN once at close: a drag fires a size
        // change per mouse move, and each store write is a synchronous file
        // write under the store lock.
        app_window.Changed([this](auto &&sender, auto &&args) {
            if (args.DidSizeChange())
            {
                auto size = sender.ClientSize();
                settings_size_w = size.Width;
                settings_size_h = size.Height;
            }
        });

        w.Closed([this](auto &&, auto &&) {
            StopPluginStatusPoll();
            if (settings_size_w > 0 && settings_size_h > 0)
                lk_store_save_settings_size(settings_size_w, settings_size_h);
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

        // The highlight shades, as alpha over the pane's dark chrome (black
        // tints, matching the existing selection): hover sits below the
        // selection, and the selected row under the pointer a step above it —
        // the ordering a Windows list uses, so hover and selection read apart.
        auto tint = [](uint8_t a) { return Media::SolidColorBrush{ winrt::Windows::UI::Color{ a, 0x00, 0x00, 0x00 } }; };
        constexpr uint8_t kHover = 0x14, kSelected = 0x28, kSelectedHover = 0x38;

        for (int i = 0; i < (int)settings_tabs.size(); ++i)
        {
            // A row stays a Button, for keyboard focus and narration, but the
            // highlight is drawn on a child Border we own, and the button's own
            // template fills are cleared. A default Button paints ButtonBackground-
            // PointerOver over its Background whenever the pointer is on it; on
            // this software-rendered VM that state flickered the highlight on and
            // off under a still pointer. With the fills removed and the tint set
            // by hand on enter and leave, hover holds while the pointer is on the
            // row, distinct from the selected row.
            Controls::Button row;
            row.HorizontalAlignment(HorizontalAlignment::Stretch);
            row.HorizontalContentAlignment(HorizontalAlignment::Stretch);
            row.VerticalContentAlignment(VerticalAlignment::Stretch);
            row.Padding({ 0, 0, 0, 0 });
            row.BorderThickness({ 0, 0, 0, 0 });
            row.Background(tint(0));
            for (auto key : { L"ButtonBackground", L"ButtonBackgroundPointerOver",
                              L"ButtonBackgroundPressed", L"ButtonBackgroundDisabled" })
                row.Resources().Insert(winrt::box_value(winrt::hstring{ key }), tint(0));

            Controls::Border selection;
            selection.CornerRadius({ 6, 6, 6, 6 });
            selection.Padding({ 10, 7, 10, 7 });
            selection.Background(tint(i == settings_tab ? kSelected : 0));

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
            selection.Child(content);
            row.Content(selection);

            row.PointerEntered([this, i, tint](auto &&s, auto &&) {
                if (auto bg = s.template as<Controls::Button>().Content().try_as<Controls::Border>())
                    bg.Background(tint(i == settings_tab ? kSelectedHover : kHover));
            });
            row.PointerExited([this, i, tint](auto &&s, auto &&) {
                if (auto bg = s.template as<Controls::Button>().Content().try_as<Controls::Border>())
                    bg.Background(tint(i == settings_tab ? kSelected : 0));
            });

            row.Click([this, i, tint](auto &&, auto &&) {
                settings_tab = i;
                for (uint32_t j = 0; j < SettingsTabs().Children().Size(); ++j)
                {
                    auto b = SettingsTabs().Children().GetAt(j).as<Controls::Button>();
                    if (auto bg = b.Content().try_as<Controls::Border>())
                        // The clicked row is under the pointer, so it takes the
                        // selected-and-hovered shade.
                        bg.Background(tint((int)j == i ? kSelectedHover : 0));
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
                UpdateReadouts();
            });
        }
        apply_timer.Stop();
        apply_timer.Start();
    }

    // The band strip, redrawn in place: which shades exist for the current
    // settings and which contour separates each pair, labelled in the
    // mariner's unit. Colours approximate the day palette — a legend, not
    // the palette itself.
    void MainWindow::RefreshBandPreview()
    {
        if (band_preview == nullptr)
            return;
        band_preview.Children().Clear();
        band_preview.ColumnDefinitions().Clear();

        const double ft = 3.28084;
        bool feet = pending.depth_unit == 1;
        auto label = [&](double metres) -> std::wstring {
            wchar_t buf[32];
            if (feet)
                swprintf_s(buf, L"%d ft", (int)std::lround(metres * ft));
            else
                swprintf_s(buf, L"%g m", metres);
            return buf;
        };

        struct Band
        {
            winrt::Windows::UI::Color c;
            std::wstring text;
        };
        const winrt::Windows::UI::Color drying{ 0xFF, 0x8C, 0xCC, 0x99 };
        const winrt::Windows::UI::Color very_shallow{ 0xFF, 0x73, 0xBF, 0xED };
        const winrt::Windows::UI::Color shallow{ 0xFF, 0x8C, 0xD1, 0xF7 };
        const winrt::Windows::UI::Color medium{ 0xFF, 0xBF, 0xE5, 0xFC };
        const winrt::Windows::UI::Color deep{ 0xFF, 0xFF, 0xFF, 0xFF };
        std::vector<Band> bands;
        if (pending.four_shade_water)
        {
            bands.push_back({ drying, L"drying" });
            bands.push_back({ very_shallow,
                              L"0\u2013" + label(std::min(pending.shallow_contour, pending.safety_contour)) });
            bands.push_back({ shallow, L"\u2013" + label(pending.safety_contour) });
            bands.push_back({ medium,
                              L"\u2013" + label(std::max(pending.deep_contour, pending.safety_contour)) });
            bands.push_back({ deep, L"deeper" });
        }
        else
        {
            bands.push_back({ drying, L"drying" });
            bands.push_back({ very_shallow, L"0\u2013" + label(pending.safety_contour) });
            bands.push_back({ deep, L"deeper" });
        }

        for (size_t i = 0; i < bands.size(); ++i)
        {
            Controls::ColumnDefinition cd;
            cd.Width({ 1, GridUnitType::Star });
            band_preview.ColumnDefinitions().Append(cd);
            Controls::Border b;
            b.Background(Media::SolidColorBrush{ bands[i].c });
            Controls::TextBlock t;
            t.Text(winrt::hstring{ bands[i].text });
            t.FontSize(9);
            t.Foreground(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0xBF, 0x00, 0x00, 0x00 } });
            t.HorizontalAlignment(HorizontalAlignment::Center);
            t.VerticalAlignment(VerticalAlignment::Bottom);
            t.TextTrimming(TextTrimming::CharacterEllipsis);
            t.Margin({ 2, 0, 2, 2 });
            b.Child(t);
            Controls::Grid::SetColumn(b, (int)i);
            band_preview.Children().Append(b);
        }
    }

    // The pane wears the chart's scheme: dusk and night take the dark palette
    // whatever the OS says — a bright panel has no place on a night passage.
    //
    // EXPLICIT Light, never Default. The pane is declared inside Root but
    // detached from it at construction and handed to a window of its own, so
    // Default does not mean "the chart's day scheme", it means "whatever the
    // OS is set to" — and under a dark system theme that gave a dark pane
    // with the day scheme's dark ink written on it.
    void MainWindow::ThemeSettingsPane(ElementTheme want)
    {
        bool dark = want == ElementTheme::Dark;
        SettingsPane().RequestedTheme(want);
        SettingsPane().Background(Media::SolidColorBrush{
            dark ? winrt::Windows::UI::Color{ 0xFF, 0x20, 0x24, 0x28 }
                 : winrt::Windows::UI::Color{ 0xFF, 0xF8, 0xF8, 0xF8 } });
    }

    void MainWindow::LoadSettings()
    {
        lk_controller_get_mariner(controller, &pending);
        ThemeSettingsPane(pending.scheme != 0 ? ElementTheme::Dark : ElementTheme::Light);
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
        band_preview = nullptr; // died with the Clear too; depths re-makes it

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
        // The reference's section footers: the sentence that explains what a
        // setting MEANS, part of the pane rather than a tooltip nobody finds.
        auto footer = [&](winrt::hstring const &text) {
            Controls::TextBlock tb;
            tb.Text(text);
            tb.FontSize(11.5);
            tb.TextWrapping(TextWrapping::Wrap);
            tb.Opacity(0.65);
            tb.Margin({ 0, 2, 0, 6 });
            stack.Children().Append(tb);
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
            // The three schemes DRAWN, not named: each swatch is a piece of
            // chart in that scheme's own colours, so the choice is made by
            // eye — day is unreadable at night and night by day, and the
            // swatches say so without words (the reference's SchemeSwatches).
            {
                Controls::TextBlock tb;
                tb.Text(L"Color scheme");
                tb.FontSize(12);
                stack.Children().Append(tb);

                Controls::Grid row;
                wchar_t const *names[] = { L"Day", L"Dusk", L"Night" };
                for (int i = 0; i < 3; ++i)
                {
                    Controls::ColumnDefinition cd;
                    cd.Width({ 1, GridUnitType::Star });
                    row.ColumnDefinitions().Append(cd);
                }
                for (int i = 0; i < 3; ++i)
                {
                    bool sel = (int)pending.scheme == i;
                    Controls::StackPanel cell;
                    cell.Spacing(4);
                    cell.Margin({ i == 0 ? 0.0 : 4.0, 4, i == 2 ? 0.0 : 4.0, 0 });

                    Controls::Border frame;
                    frame.Height(64);
                    frame.CornerRadius({ 8, 8, 8, 8 });
                    frame.BorderThickness(sel ? Thickness{ 3, 3, 3, 3 } : Thickness{ 1, 1, 1, 1 });
                    frame.BorderBrush(Media::SolidColorBrush{
                        sel ? lkw::Rgb(lkw::chrome::Accent(DarkChrome()))
                            : winrt::Windows::UI::Color{ 0x40, 0x80, 0x80, 0x80 } });
                    frame.Child(SchemeSwatch(PaletteOf(i)));
                    cell.Children().Append(frame);

                    Controls::TextBlock name;
                    name.Text(names[i]);
                    name.FontSize(12);
                    name.HorizontalAlignment(HorizontalAlignment::Center);
                    if (sel)
                        name.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
                    else
                        name.Opacity(0.65);
                    cell.Children().Append(name);

                    Controls::Grid::SetColumn(cell, i);
                    // A tap picks the scheme; the page rebuilds so the ring
                    // moves, and the pane takes the new scheme's chrome —
                    // WITHOUT re-reading `pending` (LoadSettings would
                    // discard the change the apply timer has not pushed yet).
                    cell.Tapped([this, i](auto &&, auto &&) {
                        if (settings_loading)
                            return;
                        pending.scheme = (tile57_scheme)i;
                        ScheduleApply();
                        ThemeSettingsPane(pending.scheme != 0 ? ElementTheme::Dark
                                                              : ElementTheme::Light);
                        BuildSettingsPage();
                    });
                    row.Children().Append(cell);
                }
                stack.Children().Append(row);
            }
            footer(L"The palettes switch instantly. Night keeps your eyes dark-adapted.");
            int cat = pending.display_other ? 2 : (pending.display_standard ? 1 : 0);
            combo(L"Display category", { L"Base", L"Standard", L"Other" }, cat, [this](int i) {
                pending.display_base = true;
                pending.display_standard = i != 0;
                pending.display_other = i == 2;
            });
            footer(L"Each category contains the one before it.");
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
            footer(pending.four_shade_water
                       ? L"Four shades: white (safe) water starts at the DEEP contour; the safety contour separates the two middle blues."
                       : L"Two shades: water deeper than the safety contour is white (safe), everything shallower is blue.");
            // Schematic of the S-52 depth bands for the CURRENT settings:
            // which shades exist, and which contour separates each pair. A
            // legend, not the palette (the reference's BandPreview). Redrawn
            // in place as the contour fields change.
            band_preview = Controls::Grid{};
            band_preview.Height(34);
            band_preview.CornerRadius({ 6, 6, 6, 6 });
            band_preview.Margin({ 0, 6, 0, 0 });
            stack.Children().Append(band_preview);
            RefreshBandPreview();
            footer(L"Shading follows the depth areas in the chart: the effective safety contour is the next DEEPER contour available in the data, drawn bold.");
            if (pending.four_shade_water)
                number(feet ? L"Shallow contour (ft)" : L"Shallow contour (m)", pending.shallow_contour,
                       [this](double v) { pending.shallow_contour = v; RefreshBandPreview(); });
            number(feet ? L"Safety contour (ft)" : L"Safety contour (m)", pending.safety_contour,
                   [this](double v) { pending.safety_contour = v; RefreshBandPreview(); });
            if (pending.four_shade_water)
                number(feet ? L"Deep contour (ft)" : L"Deep contour (m)", pending.deep_contour,
                       [this](double v) { pending.deep_contour = v; RefreshBandPreview(); });
            number(feet ? L"Safety depth (ft)" : L"Safety depth (m)", pending.safety_depth,
                   [this](double v) { pending.safety_depth = v; });
            footer(L"Safety depth bolds soundings at or shallower than it; it does not shade water.");
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

            // ---- the installed sets: each folder of charts with its own
            // switch. What draws is the union of the switched-on ones; a set
            // whose water is not today's water is switched off, not removed.
            if (!chart_sets.empty())
            {
                header(L"Installed charts");
                for (auto const &set : chart_sets)
                {
                    Controls::Grid srow;
                    Controls::ColumnDefinition sc0, sc1, sc2, sc3;
                    sc0.Width({ 0, GridUnitType::Auto });
                    sc1.Width({ 1, GridUnitType::Star });
                    sc2.Width({ 0, GridUnitType::Auto });
                    sc3.Width({ 0, GridUnitType::Auto });
                    srow.ColumnDefinitions().ReplaceAll({ sc0, sc1, sc2, sc3 });

                    Controls::ToggleSwitch sts;
                    sts.OnContent(nullptr);
                    sts.OffContent(nullptr);
                    sts.MinWidth(0);
                    sts.IsOn(set.on);
                    std::string spath = set.path;
                    sts.Toggled([this, spath](auto &&sw, auto &&) {
                        if (settings_loading)
                            return;
                        SetChartSetOn(spath, sw.template as<Controls::ToggleSwitch>().IsOn());
                    });
                    srow.Children().Append(sts);

                    Controls::StackPanel stext;
                    Controls::TextBlock sname;
                    sname.Text(winrt::to_hstring(set.title));
                    sname.FontWeight(winrt::Windows::UI::Text::FontWeights::Medium());
                    sname.Opacity(set.on ? 1.0 : 0.6);
                    sname.TextTrimming(TextTrimming::CharacterEllipsis);
                    stext.Children().Append(sname);
                    Controls::TextBlock ssum;
                    std::string sum;
                    if (!set.cells.empty())
                        sum = std::to_string(set.cells.size()) + (set.cells.size() == 1 ? " chart" : " charts");
                    if (!set.rasters.empty())
                        sum += (sum.empty() ? "" : ", ") + std::to_string(set.rasters.size()) +
                               (set.rasters.size() == 1 ? " picture" : " pictures");
                    if (sum.empty())
                        sum = "not answering (drive unplugged?)";
                    ssum.Text(winrt::to_hstring(sum));
                    ssum.FontSize(11);
                    ssum.Opacity(0.7);
                    stext.Children().Append(ssum);
                    stext.VerticalAlignment(VerticalAlignment::Center);
                    Controls::Grid::SetColumn(stext, 1);
                    srow.Children().Append(stext);

                    Controls::Button srm;
                    Controls::FontIcon sminus;
                    sminus.Glyph(L""); // Remove
                    sminus.FontSize(12);
                    srm.Content(sminus);
                    srm.Padding({ 4, 2, 4, 2 });
                    srm.Background(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
                    srm.BorderThickness({ 0, 0, 0, 0 });
                    Automation::AutomationProperties::SetName(srm,
                        L"Take this set off the list. The folder itself is not touched.");
                    srm.Click([this, spath](auto &&, auto &&) { RemoveChartSet(spath); });
                    Controls::Grid::SetColumn(srm, 3);
                    srow.Children().Append(srm);
                    stack.Children().Append(srow);
                }
            }

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
                        UpdateReadouts();
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
                        UpdateReadouts();
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
                            UpdateReadouts();
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
            auto link_row = [this, &stack](std::string const &url, std::string const &title,
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

            // A resolve is several fetches deep, so say so rather than leave
            // the list looking as though the click did nothing.
            if (chart_link_busy)
            {
                Controls::TextBlock working;
                working.Text(L"Reading the chart\u2026");
                working.FontSize(11);
                working.Opacity(0.7);
                stack.Children().Append(working);
            }

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

            // What this build is, and the way in to the licenses. The chart
            // engine is the one component a mariner may be asked which copy of
            // they are sailing on, so its pin is stated here too.
            header(L"About");
            {
                auto const &licenses = lkw::Licenses();
                auto fact = [&](wchar_t const *label, std::string const &value, bool literal) {
                    Controls::TextBlock tb;
                    tb.Text(label);
                    tb.FontSize(12);
                    stack.Children().Append(tb);
                    Controls::TextBlock v;
                    v.Text(winrt::to_hstring(value));
                    v.FontSize(13);
                    v.TextWrapping(TextWrapping::Wrap);
                    v.IsTextSelectionEnabled(true);
                    v.Margin({ 0, 0, 0, 4 });
                    if (literal)
                        v.FontFamily(Media::FontFamily{ L"Cascadia Mono, Consolas" });
                    stack.Children().Append(v);
                };
                fact(L"Version", lkw::AppVersion(), true);
                if (auto const *engine = lkw::LicenseById("tile57");
                    engine != nullptr && !engine->PinLabel().empty())
                    fact(L"Chart engine", engine->name + " · " + engine->PinLabel(), true);

                // The ellipsis is the platform's promise that a window opens.
                Controls::Button licenses_button;
                licenses_button.Content(winrt::box_value(winrt::hstring{ L"Licenses…" }));
                licenses_button.Margin({ 0, 4, 0, 0 });
                licenses_button.Click([this](auto &&, auto &&) { ShowLicenses(""); });
                stack.Children().Append(licenses_button);
                if (!licenses.components.empty())
                    footer(winrt::to_hstring(std::to_string(licenses.components.size()) +
                                             " components"));
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
