// The mariner settings pane: tabbed pages built from the live tile57_mariner,
// applied with a 60 ms debounce and saved on every apply.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <microsoft.ui.xaml.window.h> // IWindowNative, for the window's icon
#include <winrt/Microsoft.UI.Xaml.Documents.h> // the band legend's wrapping run

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
     * legend of the palette rather than the palette itself. The engine draws
     * from the tables in the chart (the reference's SchemePalette, hex for hex). */
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

namespace
{
    using namespace winrt::Microsoft::UI::Xaml;

    // The design's tile. A picture narrower than this cannot be told from
    // another publisher's picture of the same water.
    constexpr double kTileWidth = 250;
    constexpr double kTileArt = 132;
    constexpr double kAddTileWidth = 176;
    constexpr double kTileGap = 10;

    /* The S-52 depth ramp, deep to shallow, read as fine to coarse. Band 6 is
     * berthing detail and band 1 is an overview. */
    winrt::Windows::UI::Color BandColor(int band)
    {
        switch (band)
        {
        case 6: return Hex(0x2F8FE0);
        case 5: return Hex(0x61B7FF);
        case 4: return Hex(0x82CAFF);
        case 3: return Hex(0xA7D9FB);
        case 2: return Hex(0xC9EDFF);
        default: return Hex(0xE4F5FF);
        }
    }

    /* A url with its middle taken out. A style link holds the publisher, the
     * style and often a key, and an end ellipsis removes the style first.
     * WinUI trims at the end only, so the text is elided here by character
     * count against the width a tile gives it. */
    std::wstring ElideMiddle(std::wstring const &text, size_t budget)
    {
        if (text.size() <= budget || budget < 8)
            return text;
        size_t tail = (budget - 1) / 2;
        size_t head = budget - 1 - tail;
        return text.substr(0, head) + L"…" + text.substr(text.size() - tail);
    }

    /* What scales a chart set holds.
     *
     * One bar in the S-52 depth ramp, split by usage band, finest first. A set
     * that stops at Coastal does not draw the harbour a passage ends in, and
     * the width of each band says how much of the set is at that scale.
     *
     * `bands` is keyed 1 to 6, coarse to fine, as the scan counted them. */
    Controls::StackPanel BandRamp(std::map<int, size_t> const &bands, bool dark)
    {
        auto edge = [dark](double alpha) {
            return Media::SolidColorBrush{ lkw::WithAlpha(
                lkw::Rgb(dark ? 0xFFFFFFFFu : 0xFF000000u), alpha) };
        };
        std::vector<std::pair<int, size_t>> fine(bands.rbegin(), bands.rend());

        Controls::Grid bar;
        for (size_t i = 0; i < fine.size(); ++i)
        {
            Controls::ColumnDefinition c;
            c.Width({ (double)fine[i].second, GridUnitType::Star });
            // The narrowest a band draws. A library of 7,000 cells holds two
            // dozen overviews, and a band the legend counts has to be on the
            // bar.
            c.MinWidth(4);
            bar.ColumnDefinitions().Append(c);

            Controls::Border seg;
            seg.Background(Media::SolidColorBrush{ BandColor(fine[i].first) });
            // A hairline between the segments. Four of the six bands are the
            // pale end of the ramp, and side by side in a 9 point bar they
            // read as one stripe.
            if (i + 1 < fine.size())
                seg.Margin({ 0, 0, 1, 0 });
            Controls::Grid::SetColumn(seg, (int)i);
            bar.Children().Append(seg);
        }

        Controls::Border capsule;
        capsule.Height(9);
        capsule.CornerRadius({ 4.5, 4.5, 4.5, 4.5 });
        capsule.BorderThickness({ 1, 1, 1, 1 });
        capsule.BorderBrush(edge(0.5));
        capsule.Background(edge(0.55));
        capsule.Child(bar);

        // The legend wraps rather than scrolls: six bands fit two lines at any
        // width this pane reaches. A rich block is what wraps a run of text
        // with a swatch in it.
        Controls::RichTextBlock legend;
        legend.FontSize(11);
        legend.TextWrapping(TextWrapping::Wrap);
        Documents::Paragraph para;
        for (auto const &[band, n] : fine)
        {
            Controls::Border swatch;
            swatch.Width(8);
            swatch.Height(8);
            swatch.CornerRadius({ 2, 2, 2, 2 });
            swatch.Background(Media::SolidColorBrush{ BandColor(band) });
            swatch.BorderThickness({ 1, 1, 1, 1 });
            swatch.BorderBrush(edge(0.5));
            swatch.Margin({ 0, 0, 5, 0 });
            Documents::InlineUIContainer box;
            box.Child(swatch);
            para.Inlines().Append(box);

            Documents::Run name;
            name.Text(winrt::hstring{ lkw::FirstRunBandName(band) + L" " });
            name.Foreground(lkw::Brush(lkw::chrome::Muted(dark)));
            para.Inlines().Append(name);
            Documents::Run count;
            count.Text(winrt::hstring{ lkw::Thousands(n) + L"     " });
            para.Inlines().Append(count);
        }
        legend.Blocks().Append(para);

        Controls::StackPanel column;
        column.Spacing(8);
        column.Children().Append(capsule);
        column.Children().Append(legend);
        return column;
    }

    /* The panel a section's rows sit in. The pane is a list of cards, the way
     * the reference's form is. */
    Controls::Border Card(bool dark)
    {
        Controls::Border b;
        b.CornerRadius({ 10, 10, 10, 10 });
        b.BorderThickness({ 1, 1, 1, 1 });
        b.BorderBrush(Media::SolidColorBrush{
            dark ? winrt::Windows::UI::Color{ 0x33, 0xFF, 0xFF, 0xFF }
                 : winrt::Windows::UI::Color{ 0x33, 0x00, 0x00, 0x00 } });
        b.Background(Media::SolidColorBrush{
            dark ? winrt::Windows::UI::Color{ 0x14, 0xFF, 0xFF, 0xFF }
                 : winrt::Windows::UI::Color{ 0x0A, 0x00, 0x00, 0x00 } });
        b.Padding({ 12, 10, 12, 12 });
        b.Margin({ 0, 4, 0, 0 });
        return b;
    }

    // One shipped picture. The loader is lkw::ShippedPicture, which setup
    // reads from as well.
    Media::Imaging::BitmapImage ChartArt(wchar_t const *name)
    {
        return lkw::ShippedPicture(name);
    }
}

namespace winrt::LookoutMarine::implementation
{
    // Which chart draws now: the linked style if one is active, else
    // Lookout's own, which the shelf shows as the empty url.
    std::string MainWindow::ActiveChartUrl()
    {
        // active_chart_link is the core's own answer, read in ChartLinks.cpp
        // from lookout_link_state. Empty means Lookout's own chart draws.
        return lk_controller_alt_style_active(controller) ? active_chart_link : std::string{};
    }

    // Draw the chart the mariner picked.
    //
    // lookout_chart_link_select draws one of the charts the core CARRIES, so
    // it does nothing for a style the app ships until that style is on the
    // list. A tile that is not on the list is added instead, which resolves
    // the style and selects it (lookout-library.h:674). `mine` is what tells
    // them apart; Lookout's own chart is always a select.
    //
    // The pick is marked and the page rebuilt first, so the tile reads as
    // being read while the core holds the thread: resolving a style with its
    // sprite packs runs inside a frame, and the click looked like it had done
    // nothing. The call goes out at low priority, which runs after the layout
    // the rebuild queued. The mark stays until the resolve settles, which
    // PollChartLinks reports; the core names the chart it is resolving only
    // once it has one, so without the mark the line would sit on whichever
    // chart was drawing before.
    void MainWindow::PickChartTile(std::string const &url, bool mine)
    {
        if (chart_link_picking)
            return;
        chart_link_pending = url;
        chart_link_picked = true;
        chart_link_picking = true;
        // In place. Rebuilding the page here destroyed the tile whose click
        // was still being handled: the pointer lost the hover it was showing,
        // and a second pick landed on whatever control had taken that tile's
        // place.
        RefreshChartsPageInPlace();
        // At the queue's own priority. A low-priority call runs only once the
        // thread has nothing else to do, and this thread has a readout tick on
        // it, so the call was never made and the guard above stayed closed:
        // that first pick was the last one the shelf answered.
        bool queued = DispatcherQueue().TryEnqueue([this, url, mine] {
            chart_link_picking = false;
            if (url.empty() || mine)
                SelectChartLink(url);
            else
                AddChartLink(url);
        });
        if (!queued)
        {
            chart_link_picking = false;
            chart_link_picked = false;
            chart_link_pending.clear();
        }
    }

    // Read this chart again, or take it off the list. Lookout's own chart has
    // neither: it is built from the sets below and cannot be removed.
    Controls::Button MainWindow::ChartTileMenu(std::string const &url, std::wstring const &name)
    {
        Controls::MenuFlyout flyout;
        Controls::MenuFlyoutItem again;
        again.Text(L"Read This Chart Again");
        again.Click([this, url](auto &&, auto &&) { RefreshChartLink(url); });
        flyout.Items().Append(again);
        Controls::MenuFlyoutItem rm;
        rm.Text(L"Remove");
        rm.Click([this, url](auto &&, auto &&) { RemoveChartLink(url); });
        flyout.Items().Append(rm);

        Controls::FontIcon more;
        more.Glyph(L"");
        more.FontSize(12);

        Controls::Button b;
        b.Content(more);
        b.Width(22);
        b.Height(22);
        b.Padding({ 0, 0, 0, 0 });
        b.CornerRadius({ 11, 11, 11, 11 });
        b.Margin({ 7, 7, 7, 7 });
        b.HorizontalAlignment(HorizontalAlignment::Right);
        b.VerticalAlignment(VerticalAlignment::Top);
        b.Flyout(flyout);
        Automation::AutomationProperties::SetName(b, L"More for " + name);
        return b;
    }

    // One chart: a picture of it, its name, and where it comes from. `url`
    // empty is Lookout's own chart; `mine` marks a link on the mariner's own
    // list, which is the only kind with a menu.
    Controls::Button MainWindow::ChartTile(std::string const &url, std::wstring const &name,
                                           std::wstring const &where, wchar_t const *art,
                                           bool mine)
    {
        bool dark = DarkChrome();

        // The picture fills the frame by covering it, so it is wider than the
        // tile and has to be clipped. The badge and the menu go over the
        // CLIPPED picture: aligned inside it, a badge starts left of the
        // tile's own edge and loses its first letter.
        // Height only. The width is the tile's content width, which is the
        // tile less its border, so a fixed 250 here draws over the border it
        // is meant to sit inside.
        Controls::Border crop;
        crop.Height(kTileArt);
        crop.HorizontalAlignment(HorizontalAlignment::Stretch);
        crop.CornerRadius({ 10, 10, 0, 0 });
        if (auto picture = ChartArt(art))
        {
            Controls::Image pic;
            pic.Source(picture);
            pic.Stretch(Media::Stretch::UniformToFill);
            crop.Child(pic);
        }
        else
        {
            // A style with no picture draws its kind. A publisher's own
            // portrayal needs the style resolved and its tiles fetched, so
            // the globe stands in until a render of it arrives.
            crop.Background(lkw::Brush(lkw::chrome::AccentFill(dark)));
            Controls::FontIcon globe;
            globe.Glyph(L"");
            globe.FontSize(26);
            globe.Foreground(lkw::Brush(lkw::chrome::Accent(dark)));
            globe.HorizontalAlignment(HorizontalAlignment::Center);
            globe.VerticalAlignment(VerticalAlignment::Center);
            crop.Child(globe);
        }

        Controls::Grid art_grid;
        art_grid.Children().Append(crop);
        // Built whichever chart draws, and shown by the refresh. A badge that
        // comes and going with a rebuild is a tile rebuilt under the pointer.
        Controls::TextBlock mark;
        mark.Text(L"ACTIVE");
        mark.FontSize(10);
        mark.FontWeight(winrt::Windows::UI::Text::FontWeights::Bold());
        mark.Foreground(lkw::Brush(0xFFFFFFFF));
        Controls::Border badge;
        badge.Child(mark);
        badge.Background(lkw::Brush(lkw::chrome::Accent(dark)));
        badge.CornerRadius({ 5, 5, 5, 5 });
        badge.Padding({ 6, 3, 6, 3 });
        badge.Margin({ 7, 7, 7, 7 });
        badge.HorizontalAlignment(HorizontalAlignment::Left);
        badge.VerticalAlignment(VerticalAlignment::Top);
        badge.Visibility(Visibility::Collapsed);
        art_grid.Children().Append(badge);
        if (mine)
            art_grid.Children().Append(ChartTileMenu(url, name));

        Controls::Border rule;
        rule.Height(1);
        rule.Background(lkw::Brush(lkw::chrome::Rule(dark)));

        Controls::TextBlock title;
        title.Text(name);
        title.FontSize(13);
        title.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
        title.TextTrimming(TextTrimming::CharacterEllipsis);
        Controls::TextBlock detail;
        // Elided in the middle, which keeps the publisher and the style file
        // and drops the path between them. 42 characters is what 11 point
        // text fits across a tile.
        detail.Text(winrt::hstring{ ElideMiddle(where, 42) });
        detail.FontSize(11);
        detail.Foreground(lkw::Brush(lkw::chrome::Muted(dark)));
        detail.TextTrimming(TextTrimming::CharacterEllipsis);

        Controls::StackPanel words;
        words.Spacing(3);
        words.Margin({ 11, 9, 11, 11 });
        words.Children().Append(title);
        words.Children().Append(detail);

        Controls::StackPanel column;
        column.Children().Append(art_grid);
        column.Children().Append(rule);
        column.Children().Append(words);

        Controls::Button b;
        b.Content(column);
        b.Padding({ 0, 0, 0, 0 });
        b.Width(kTileWidth);
        b.CornerRadius({ 11, 11, 11, 11 });
        b.VerticalAlignment(VerticalAlignment::Top);
        b.HorizontalContentAlignment(HorizontalAlignment::Stretch);
        b.VerticalContentAlignment(VerticalAlignment::Top);
        // The ring is the same width whether or not this tile is the one
        // drawing, so the row does not shift by two points as the pick moves.
        // Which tile wears the accent is the refresh's to say.
        b.BorderThickness({ 2, 2, 2, 2 });
        b.BorderBrush(lkw::Brush(lkw::chrome::kClear));
        if (!url.empty())
            Controls::ToolTipService::SetToolTip(b, winrt::box_value(winrt::to_hstring(url)));
        Automation::AutomationProperties::SetName(b, name);
        b.Click([this, url, mine](auto &&, auto &&) { PickChartTile(url, mine); });
        chart_tile_ui.push_back({ url, b, badge, detail, where, title, mine });
        return b;
    }

    // The last tile: add a chart by link or from a file. A dashed edge, which
    // a Button border cannot draw, so the edge is a rectangle under the words.
    Controls::Button MainWindow::AddChartTile()
    {
        bool dark = DarkChrome();

        Media::DoubleCollection dashes;
        dashes.Append(5.0);
        dashes.Append(4.0);
        Shapes::Rectangle edge;
        edge.RadiusX(11);
        edge.RadiusY(11);
        edge.Stroke(lkw::Brush(lkw::chrome::Rule(dark)));
        edge.StrokeThickness(1.5);
        edge.StrokeDashArray(dashes);

        Controls::FontIcon plus;
        plus.Glyph(L"");
        plus.FontSize(20);
        plus.Foreground(lkw::Brush(lkw::chrome::Accent(dark)));
        Controls::TextBlock title;
        title.Text(L"Add a chart");
        title.FontSize(13);
        title.FontWeight(winrt::Windows::UI::Text::FontWeights::Medium());
        title.HorizontalAlignment(HorizontalAlignment::Center);
        Controls::TextBlock detail;
        detail.Text(L"Style link, TileJSON, or a file");
        detail.FontSize(11);
        detail.Foreground(lkw::Brush(lkw::chrome::Muted(dark)));
        detail.TextWrapping(TextWrapping::Wrap);
        detail.TextAlignment(TextAlignment::Center);
        detail.HorizontalAlignment(HorizontalAlignment::Center);

        Controls::StackPanel column;
        column.Spacing(8);
        column.Margin({ 12, 0, 12, 0 });
        column.VerticalAlignment(VerticalAlignment::Center);
        column.Children().Append(plus);
        column.Children().Append(title);
        column.Children().Append(detail);

        Controls::Grid face;
        face.Children().Append(edge);
        face.Children().Append(column);

        Controls::Button b;
        b.Content(face);
        b.Padding({ 0, 0, 0, 0 });
        b.Width(kAddTileWidth);
        lkw::FlatFills(b, DarkChrome());
        b.BorderThickness({ 0, 0, 0, 0 });
        b.VerticalAlignment(VerticalAlignment::Stretch);
        b.HorizontalContentAlignment(HorizontalAlignment::Stretch);
        b.VerticalContentAlignment(VerticalAlignment::Stretch);
        b.Click([this](auto &&, auto &&) { ShowAddChartDialog(); });
        return b;
    }

    // Adding a chart: a link the mariner pasted, or a style file they hold.
    fire_and_forget MainWindow::ShowAddChartDialog()
    {
        auto lifetime = get_strong();
        bool dark = DarkChrome();

        Controls::TextBlock says;
        says.Text(L"An online map can be the chart. Paste its MapLibre style link, or a "
                  L"TileJSON tile link. A style draws exactly what its publisher styled; "
                  L"bare tiles get a plain generated look. Either way the content comes "
                  L"from whoever made it, depths, symbols and warnings included.");
        says.FontSize(12);
        says.Foreground(lkw::Brush(lkw::chrome::Muted(dark)));
        says.TextWrapping(TextWrapping::Wrap);

        Controls::TextBox box;
        box.PlaceholderText(L"https://…/style.json");

        Controls::Button file;
        file.Content(winrt::box_value(L"Add a style file from this device…"));
        file.HorizontalAlignment(HorizontalAlignment::Left);
        lkw::FlatFills(file, dark);
        file.BorderThickness({ 0, 0, 0, 0 });
        file.Padding({ 0, 4, 0, 4 });
        file.Foreground(lkw::Brush(lkw::chrome::Accent(dark)));

        Controls::StackPanel body;
        body.Spacing(14);
        body.Children().Append(says);
        body.Children().Append(box);
        body.Children().Append(file);

        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(winrt::box_value(L"Add a chart"));
        dialog.Content(body);
        dialog.PrimaryButtonText(L"Add");
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(Controls::ContentDialogButton::Primary);
        // The picker cannot stand under the dialog: both are modal to the same
        // window. The dialog goes away and the picker takes over from there.
        //
        // Weakly. The dialog owns this button, which owns the handler, so a
        // strong reference here keeps the dialog alive after it closes.
        winrt::weak_ref<Controls::ContentDialog> weak_dialog{ dialog };
        file.Click([this, weak_dialog](auto &&, auto &&) {
            if (auto d = weak_dialog.get())
                d.Hide();
            PickChartStyleFile();
        });

        auto result = co_await dialog.ShowAsync();
        if (result != Controls::ContentDialogResult::Primary)
            co_return;
        auto text = winrt::to_string(box.Text());
        if (!text.empty())
            AddChartLink(text);
    }

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
    // settings in them, and today that something is a plugin. The mariner is
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

        // A section can go away, since a plugin that never came up takes its
        // section with it, so a stale selection falls back rather than indexing
        // off the end of the strip.
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
        // selection, and the selected row under the pointer a step above it,
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
    // mariner's unit. Colours approximate the day palette: a legend rather
    // than the palette itself.
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
    // whatever the OS says. A bright panel has no place on a night passage.
    //
    // EXPLICIT Light, never Default. The pane is declared inside Root but
    // detached from it at construction and handed to a window of its own, so
    // Default does not mean "the chart's day scheme", it means "whatever the
    // OS is set to", and under a dark system theme that gave a dark pane
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

    // The download the Charts page is reporting. Read on the readout tick,
    // and only while the page holds the line that says so: the controls are
    // null on every other page and whenever no transfer is running, which is
    // what keeps this off the tick the rest of the time.
    // The removal panel's live parts, restated rather than rebuilt: this runs
    // off the readout tick, and building the page again under the pointer is
    // what took the hover off the rows.
    void MainWindow::PollRemovalPane()
    {
        if (removal_job == nullptr || removal_pane_title == nullptr)
            return;
        auto const p = removal_job->Snapshot();
        std::wstring title = winrt::to_hstring(p.Title()).c_str();
        if (!p.running)
        {
            // What it left to say, once there is nothing to count.
            std::string const note = removal_job->Note();
            if (!note.empty())
                title = winrt::to_hstring(note).c_str();
        }
        removal_pane_title.Text(winrt::hstring{ title });

        if (removal_pane_bar != nullptr)
        {
            bool const sweep = p.running && p.total == 0;
            if (removal_pane_bar.IsIndeterminate() != sweep)
                removal_pane_bar.IsIndeterminate(sweep);
            if (!sweep)
                removal_pane_bar.Value(p.running ? p.Fraction() : 1.0);
            removal_pane_bar.Visibility(p.running ? Visibility::Visible
                                                  : Visibility::Collapsed);
        }
        if (removal_pane_count != nullptr)
        {
            std::wstring says;
            if (p.running && p.total > 0)
                says = lkw::Thousands(p.done) + L" of " + lkw::Thousands(p.total);
            removal_pane_count.Text(winrt::hstring{ says });
            removal_pane_count.Visibility(says.empty() ? Visibility::Collapsed
                                                       : Visibility::Visible);
        }
    }

    void MainWindow::PollNoaaPane()
    {
        if (noaa_pane_count == nullptr || controller == nullptr)
            return;
        lookout_noaa_state nst{};
        lk_controller_noaa_poll(controller, &nst);
        if (nst.phase != 3)
        {
            // The transfer ended. The section goes, and the sets it landed in
            // are read again by their own scan.
            BuildSettingsPage();
            return;
        }
        std::string line = std::to_string(nst.done) + " of " + std::to_string(nst.total) +
                           " charts";
        if (nst.failed > 0)
            line += "  ·  " + std::to_string(nst.failed) + " failed";
        noaa_pane_count.Text(winrt::to_hstring(line));
        if (noaa_pane_bar != nullptr)
        {
            noaa_pane_bar.IsIndeterminate(nst.total == 0);
            if (nst.total > 0)
                noaa_pane_bar.Value((double)nst.done / (double)nst.total);
        }
    }

    // The page's SHAPE: which tiles, which sets, which pictures, and which
    // sections are on it. Nothing here moves on its own. Every count, every
    // size, which chart draws and which is being read are values, and the
    // refresh below states them without building a control.
    std::string MainWindow::ChartsPageStructure()
    {
        // Identities only. A name is a value: the core learns a publisher's
        // name when a style resolves, and a set's title moves between the
        // folder's name and the office's while a scan of it is in flight.
        // Both were in here, and each change tore the page down under the
        // pointer.
        std::string s;
        for (auto const &l : chart_links)
            s += l.url + "\x1e";
        for (auto const &set : chart_sets)
            s += set.path + "\x1e";
        for (auto const &p : raster_paths)
            s += p + "\x1e";
        // The sections that come and go with work, and the row an empty list
        // stands in for.
        s += chart_sets.empty() ? "empty" : "sets";
        s += bake_job != nullptr ? "|baking" : "|idle";
        // The removal line comes and goes with the job that feeds it.
        s += removal_job != nullptr ? "|removing" : "|kept";
        if (lk_controller_is_open(controller))
        {
            lookout_noaa_state nst{};
            lk_controller_noaa_poll(controller, &nst);
            s += nst.phase == 3 ? "|downloading" : "|quiet";
        }
        return s;
    }

    // What every line on the page now says.
    //
    // This creates nothing and destroys nothing, so it is safe on a poll: the
    // control the pointer is standing on keeps its hover, and a click in
    // flight still lands on the control it was pressed on.
    void MainWindow::RefreshChartsPageInPlace()
    {
        bool dark = DarkChrome();

        // ---- the shelf ----------------------------------------------------
        // A chart being read is the one the mariner picked, whatever the core
        // still reports as drawing. Only that tile says so: that a tile draws
        // once it is picked needs no saying.
        bool reading = chart_link_picked || chart_link_busy;
        std::string picked = chart_link_picked ? chart_link_pending : active_chart_link;
        std::string drawing = ActiveChartUrl();
        size_t cells = 0;
        for (auto const &s : chart_sets)
            if (s.on)
                cells += s.charts;
        for (auto const &t : chart_tile_ui)
        {
            if (t.button == nullptr)
                continue;
            bool being_read = reading && picked == t.url;
            bool active = being_read || (!reading && drawing == t.url);
            std::wstring where = t.where;
            if (t.url.empty() && cells != 0)
                where += L" · " + std::to_wstring(cells) + L" cells";
            if (being_read)
                where = L"Reading this chart…";
            t.detail.Text(winrt::hstring{ ElideMiddle(where, 42) });
            t.badge.Visibility(active ? Visibility::Visible : Visibility::Collapsed);
            // The name the core learned for a link the mariner added. A
            // shipped tile keeps its publisher's name.
            if (t.mine && t.title != nullptr)
                for (auto const &l : chart_links)
                    if (l.url == t.url)
                        t.title.Text(winrt::to_hstring(l.name.empty() ? l.url : l.name));
            t.button.BorderBrush(
                lkw::Brush(active ? lkw::chrome::Accent(dark) : lkw::chrome::kClear));
        }
        if (chart_link_error_ui != nullptr)
        {
            chart_link_error_ui.Text(winrt::to_hstring(chart_link_error));
            chart_link_error_ui.Visibility(chart_link_error.empty() ? Visibility::Collapsed
                                                                    : Visibility::Visible);
        }
        if (chart_publisher_note != nullptr)
            chart_publisher_note.Visibility(lk_controller_alt_style_active(controller)
                                                ? Visibility::Visible
                                                : Visibility::Collapsed);

        // ---- the sets -----------------------------------------------------
        if (chart_sets_none != nullptr)
        {
            chart_sets_none.Text(ChartSetsScanning() ? L"Finding charts…" : L"No chart sets");
            chart_sets_none.Visibility(chart_sets.empty() ? Visibility::Visible
                                                          : Visibility::Collapsed);
        }
        if (chart_sets_total != nullptr)
        {
            size_t all_charts = 0;
            uint64_t all_bytes = 0;
            for (auto const &s : chart_sets)
            {
                all_charts += s.charts + s.pictures;
                all_bytes += s.bytes;
            }
            chart_sets_total.Text(chart_sets.empty()
                                      ? winrt::hstring{}
                                      : winrt::hstring{ lkw::Thousands(all_charts) +
                                                        L" charts · " +
                                                        lkw::SizeText(all_bytes) });
        }
        for (auto &row : chart_set_ui)
        {
            auto it = std::find_if(chart_sets.begin(), chart_sets.end(),
                                   [&](ChartSetRow const &s) { return s.path == row.path; });
            if (it == chart_sets.end())
                continue;
            ChartSetRow const &set = *it;

            std::string sum;
            if (set.charts != 0)
                sum = std::to_string(set.charts) + (set.charts == 1 ? " chart" : " charts");
            if (set.pictures != 0)
                sum += (sum.empty() ? "" : " \xC2\xB7 ") + std::to_string(set.pictures) +
                       (set.pictures == 1 ? " picture" : " pictures");
            // How far down the scales it goes, coarse to fine. The counts are
            // on the ramp under the row.
            if (!set.bands.empty())
            {
                int lo = set.bands.begin()->first;
                int hi = set.bands.rbegin()->first;
                std::string span = winrt::to_string(lkw::FirstRunBandName(lo));
                if (hi != lo)
                    span += " to " + winrt::to_string(lkw::FirstRunBandName(hi));
                sum += (sum.empty() ? "" : " \xC2\xB7 ") + span;
            }
            // A row is listed before the scan has read its folder, and a
            // folder still being read has not failed to answer.
            if (sum.empty() && set.scanned)
                sum = "not answering (drive unplugged?)";
            else if (set.bytes != 0)
                sum += (sum.empty() ? "" : " \xC2\xB7 ") +
                       winrt::to_string(lkw::SizeText(set.bytes));
            // Where it came from, when that is not what it is called. Two
            // sets from one office share a title, and the folder is what
            // tells them apart.
            std::string const folder =
                std::filesystem::path(set.path).filename().string();
            if (folder != set.title && !folder.empty())
                sum = folder + (sum.empty() ? "" : " · ") + sum;
            row.summary.Text(winrt::to_hstring(sum));

            // What the core lists to prepare, which leaves out the files a
            // finished bake refused. Those stay on the disk and off this line
            // until a new edition of the cell arrives.
            row.prepare.Text(winrt::hstring{ lkw::Thousands(set.to_prepare) +
                                             L" to prepare" });
            row.prepare.Visibility(set.to_prepare == 0 ? Visibility::Collapsed
                                                       : Visibility::Visible);
            // The set's title. The core names a set after the office whose
            // charts it holds once the scan has read them, and after the folder
            // until then, so this changes under a page that is already up.
            row.name.Text(winrt::to_hstring(set.title));
            row.name.Opacity(set.on ? 1.0 : 0.6);
            // The switch answers the mariner, not this. Setting it back would
            // fight a toggle mid-animation, so it is written only when the
            // core disagrees with what it shows.
            if (row.on != nullptr && row.on.IsOn() != set.on)
            {
                bool was = settings_loading;
                settings_loading = true; // the write is not a mariner's answer
                row.on.IsOn(set.on);
                settings_loading = was;
            }
            if (row.ramp != nullptr)
            {
                if (row.bands != set.bands)
                {
                    row.ramp.Children().Clear();
                    if (!set.bands.empty())
                        row.ramp.Children().Append(BandRamp(set.bands, dark));
                    row.bands = set.bands;
                }
                row.ramp.Opacity(set.on ? 1.0 : 0.5);
            }
        }

        // The download and the removal, which have their own lines and their
        // own polls.
        PollNoaaPane();
        PollRemovalPane();
    }

    void MainWindow::RefreshChartsPageOnChange()
    {
        bool charts_visible = SettingsOpen() && settings_tab >= 0 &&
                              settings_tab < (int)settings_tabs.size() &&
                              settings_tabs[settings_tab].id == "charts";
        if (!charts_visible)
            return;
        // A tile, a set, a picture or a section came or went: there is a
        // control to make or unmake, so the page is built again. Anything else
        // is a value.
        if (ChartsPageStructure() != charts_page_sig)
            BuildSettingsPage();
        else
            RefreshChartsPageInPlace();
    }

    void MainWindow::BuildSettingsPage()
    {
        settings_loading = true;

        auto stack = SettingsContent();
        stack.Children().Clear();
        // The controls the status poll updates in place died with that Clear.
        plugin_status_ui.clear();
        band_preview = nullptr; // died with the Clear too; depths re-makes it
        // Set again by whatever this page draws that a poll feeds.
        page_reads_discovery = false;
        noaa_pane_count = nullptr;
        noaa_pane_bar = nullptr;
        bake_pane_count = nullptr;
        bake_pane_eta = nullptr;
        bake_pane_bar = nullptr;
        removal_pane_title = nullptr;
        removal_pane_count = nullptr;
        removal_pane_bar = nullptr;
        chart_tile_ui.clear();
        chart_set_ui.clear();
        chart_sets_total = nullptr;
        chart_sets_none = nullptr;
        chart_link_error_ui = nullptr;
        chart_publisher_note = nullptr;

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
            // eye: day is unreadable at night and night by day, and the
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
                    // moves, and the pane picks up the new scheme's chrome,
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
            // The pane in the order the reference orders it: which chart draws, what
            // it is built from, what is arriving, and last where to get more. Adding
            // belongs at the bottom, because a mariner reads what they have before
            // reading how to get more.
            
            // ---- Active chart -------------------------------------------------
            // Which chart DRAWS. Lookout's own chart is built from the sets
            // below; a chart added by link is a publisher's MapLibre style
            // drawn instead of it. One draws at a time, because two whole
            // charts cannot share the water.
            //
            // A row of tiles rather than a list, so two styles with similar
            // names are told apart by looking: Lookout's own first, then the
            // styles the app ships, then whatever the mariner linked, and the
            // way to add one last.
            //
            // Only Lookout's own chart has a picture, welcome-chart.png from
            // data\firstrun beside the exe. A publisher's portrayal needs the
            // style resolved and its tiles fetched before there is anything to
            // picture, and the engine draws one chart at a time, so a linked
            // tile draws its kind instead.
            header(L"Active chart");
            {
                struct Tile
                {
                    std::string url; // empty for Lookout's own
                    std::wstring name;
                    std::wstring where; // its line at rest
                    wchar_t const *art;
                    bool mine;
                };
                struct Shipped
                {
                    char const *url;
                    wchar_t const *name;
                };
                static constexpr Shipped kShipped[] = {
                    { "https://tiles.openwaters.io/seascape/style.json",
                      L"Open Waters Seascape" },
                    { "https://tiles.openwaters.io/seamap/style.json",
                      L"Open Waters Seamap" },
                };
                auto on_my_list = [this](std::string const &url) -> ChartLink const * {
                    for (auto const &l : chart_links)
                        if (l.url == url)
                            return &l;
                    return nullptr;
                };

                // The tiles are built at rest: what each one says about itself
                // when nothing is happening. Which one is drawing, which is
                // being read and what the Lookout tile is built from are all
                // values, and RefreshChartsPageInPlace states them without
                // building anything.
                std::vector<Tile> tiles;
                // Lookout's own chart first. It is built from the sets below
                // and cannot be removed, so it has no menu.
                tiles.push_back({ "", L"Lookout chart", L"From your chart sets",
                                  L"welcome-chart.png", false });

                // Then the charts the app ships, in their own order, so
                // picking one does not move the tiles.
                for (auto const &e : kShipped)
                {
                    ChartLink const *mine = on_my_list(e.url);
                    std::wstring name = mine != nullptr && !mine->name.empty()
                                            ? std::wstring{ winrt::to_hstring(mine->name) }
                                            : std::wstring{ e.name };
                    tiles.push_back({ e.url, name, std::wstring{ winrt::to_hstring(e.url) },
                                      nullptr, mine != nullptr });
                }

                // Then the links the mariner added themselves.
                for (auto const &l : chart_links)
                {
                    bool shipped = false;
                    for (auto const &e : kShipped)
                        shipped = shipped || l.url == e.url;
                    if (shipped)
                        continue; // planned above, under the publisher's name
                    std::wstring name{ winrt::to_hstring(l.name.empty() ? l.url : l.name) };
                    tiles.push_back({ l.url, name, std::wstring{ winrt::to_hstring(l.url) },
                                      nullptr, true });
                }

                Controls::StackPanel shelf;
                shelf.Orientation(Controls::Orientation::Horizontal);
                shelf.Spacing(kTileGap);
                for (auto const &t : tiles)
                    shelf.Children().Append(ChartTile(t.url, t.name, t.where, t.art, t.mine));
                shelf.Children().Append(AddChartTile());

                Controls::ScrollViewer shelf_scroll;
                shelf_scroll.HorizontalScrollBarVisibility(Controls::ScrollBarVisibility::Auto);
                shelf_scroll.VerticalScrollBarVisibility(Controls::ScrollBarVisibility::Disabled);
                shelf_scroll.HorizontalScrollMode(Controls::ScrollMode::Auto);
                shelf_scroll.Padding({ 0, 2, 0, 2 });
                shelf_scroll.Content(shelf);
                // Put the row back where the mariner had it. The links poll
                // several times a second while a style resolves, every report
                // rebuilds this page, and a rebuilt scroller starts at its
                // first tile. A fresh scroller reads 0 before the restore, so
                // only a real offset is kept.
                shelf_scroll.ViewChanged([this](auto &&s, auto &&) {
                    double at = s.template as<Controls::ScrollViewer>().HorizontalOffset();
                    if (at > 0)
                        chart_shelf_offset = at;
                });
                shelf_scroll.Loaded([this](auto &&s, auto &&) {
                    if (chart_shelf_offset > 0)
                        s.template as<Controls::ScrollViewer>().ChangeView(
                            chart_shelf_offset, nullptr, nullptr, true);
                });
                auto shelf_card = Card(DarkChrome());
                shelf_card.Padding({ 12, 12, 12, 12 });
                shelf_card.Child(shelf_scroll);
                stack.Children().Append(shelf_card);
            }

            // Both lines are built collapsed and shown by the refresh. A line
            // that arrives by rebuilding the page moves everything under it
            // and takes the pointer's hover with it.
            chart_link_error_ui = Controls::TextBlock{};
            chart_link_error_ui.FontSize(11);
            chart_link_error_ui.Foreground(lkw::Brush(lkw::chrome::kAmber));
            chart_link_error_ui.TextWrapping(TextWrapping::Wrap);
            chart_link_error_ui.Visibility(Visibility::Collapsed);
            stack.Children().Append(chart_link_error_ui);

            // Only while a linked chart draws. The mariner's display, depth
            // and symbol settings shape Lookout's own portrayal and have no
            // hold on a publisher's.
            chart_publisher_note = Controls::TextBlock{};
            chart_publisher_note.Text(L"While a linked chart draws, the display, depth and "
                                      L"symbol settings do not shape it. You are seeing its "
                                      L"publisher's own portrayal.");
            chart_publisher_note.FontSize(11);
            chart_publisher_note.Opacity(0.7);
            chart_publisher_note.TextWrapping(TextWrapping::Wrap);
            chart_publisher_note.Visibility(Visibility::Collapsed);
            stack.Children().Append(chart_publisher_note);

            // ---- Your chart sets ----------------------------------------------
            // The installed sets: each folder of charts with its own switch.
            // What draws is the union of the switched-on ones. A set whose
            // water is not today's water is switched off and stays installed.
            {
                // What every set holds, together, beside the heading.
                size_t all_charts = 0;
                uint64_t all_bytes = 0;
                for (auto const &s : chart_sets)
                {
                    all_charts += s.charts + s.pictures;
                    all_bytes += s.bytes;
                }
                Controls::Grid head;
                Controls::ColumnDefinition h0, h1;
                h0.Width({ 1, GridUnitType::Star });
                h1.Width({ 0, GridUnitType::Auto });
                head.ColumnDefinitions().ReplaceAll({ h0, h1 });
                head.Margin({ 0, 10, 0, 0 });
                Controls::TextBlock head_tb;
                head_tb.Text(L"Your chart sets");
                head_tb.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
                head.Children().Append(head_tb);
                // What every set holds together. A count that moves as a scan
                // lands is a value, so it is stated in place.
                chart_sets_total = Controls::TextBlock{};
                chart_sets_total.FontSize(11);
                chart_sets_total.Opacity(0.7);
                chart_sets_total.VerticalAlignment(VerticalAlignment::Center);
                Controls::Grid::SetColumn(chart_sets_total, 1);
                head.Children().Append(chart_sets_total);
                stack.Children().Append(head);

                // A library being read has not failed to answer. Built either
                // way: whether a scan is still running is a value.
                chart_sets_none = Controls::TextBlock{};
                chart_sets_none.FontSize(12);
                chart_sets_none.Opacity(0.7);
                chart_sets_none.Visibility(Visibility::Collapsed);
                stack.Children().Append(chart_sets_none);

                // The downloader's own set first. It is the set this app adds
                // to and takes from, and the only row that leads to the picker.
                std::vector<ChartSetRow const *> ordered;
                for (auto const &set : chart_sets)
                    if (set.managed)
                        ordered.push_back(&set);
                for (auto const &set : chart_sets)
                    if (!set.managed)
                        ordered.push_back(&set);
                for (auto const *held : ordered)
                {
                    auto const &set = *held;
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
                    // The name, and on the downloader's own set what it is.
                    // A mariner otherwise reads the download as a folder they
                    // picked and looks for it on the disk.
                    Controls::StackPanel title_row;
                    title_row.Orientation(Controls::Orientation::Horizontal);
                    title_row.Spacing(6);
                    title_row.Children().Append(sname);
                    if (set.managed)
                    {
                        Controls::TextBlock mark;
                        mark.Text(L"Managed by NOAA chart downloader");
                        mark.FontSize(10);
                        mark.FontWeight(winrt::Windows::UI::Text::FontWeights::Medium());
                        mark.Foreground(lkw::Brush(lkw::chrome::Accent(DarkChrome())));
                        Controls::Border tag;
                        tag.CornerRadius({ 8, 8, 8, 8 });
                        tag.Padding({ 6, 1, 6, 2 });
                        tag.Background(lkw::Brush(lkw::chrome::AccentFill(DarkChrome())));
                        tag.VerticalAlignment(VerticalAlignment::Center);
                        tag.Child(mark);
                        Automation::AutomationProperties::SetName(
                            tag, L"Managed by the NOAA chart downloader");
                        title_row.Children().Append(tag);
                    }
                    stext.Children().Append(title_row);
                    // What it holds, and what of it has yet to be prepared.
                    // Both are counts a scan moves, so the refresh states them
                    // and the prepare line is built collapsed.
                    Controls::TextBlock ssum;
                    ssum.TextWrapping(TextWrapping::Wrap);
                    ssum.FontSize(11);
                    ssum.Opacity(0.7);
                    stext.Children().Append(ssum);
                    Controls::TextBlock prep;
                    prep.FontSize(11);
                    prep.Opacity(0.7);
                    prep.Visibility(Visibility::Collapsed);
                    stext.Children().Append(prep);
                    stext.VerticalAlignment(VerticalAlignment::Center);
                    Controls::Grid::SetColumn(stext, 1);
                    srow.Children().Append(stext);

                    if (set.managed)
                    {
                        // The downloader's own set is added to and taken from
                        // in the picker, so the row goes there. A Remove here
                        // would leave the picker stating water that had gone.
                        Controls::Button manage;
                        manage.Content(winrt::box_value(L"Manage…"));
                        manage.Padding({ 6, 2, 6, 2 });
                        manage.Foreground(lkw::Brush(lkw::chrome::Accent(DarkChrome())));
                        manage.FontSize(12);
                        lkw::FlatFills(manage, DarkChrome());
                        Automation::AutomationProperties::SetName(
                            manage, L"Manage the NOAA charts this app downloaded");
                        // Handed to the next tick: ShowNoaaPicker closes this
                        // window, and closing the window that owns the button
                        // from inside its own handler destroys the button while
                        // the handler is still running.
                        manage.Click([this](auto &&, auto &&) {
                            DispatcherQueue().TryEnqueue([this] { ShowNoaaPicker(); });
                        });
                        Controls::Grid::SetColumn(manage, 3);
                        srow.Children().Append(manage);
                    }
                    else
                    {
                        Controls::Button srm;
                        Controls::FontIcon sminus;
                        sminus.Glyph(L""); // Remove
                        sminus.FontSize(12);
                        srm.Content(sminus);
                        srm.Padding({ 4, 2, 4, 2 });
                        lkw::FlatFills(srm, DarkChrome());
                        // A set Lookout prepared is work to do again, so
                        // removing it asks first and says how much. A folder of
                        // the mariner's own files is a list entry, so it goes
                        // without a question.
                        bool derived = lookout_bake_is_derived(lkw::ChartLibraryDir().c_str(),
                                                               set.path.c_str()) != 0;
                        Automation::AutomationProperties::SetName(
                            srm, derived
                                     ? L"Remove. The charts this app prepared are deleted; your "
                                       L"own cells stay where they are."
                                     : L"Take these charts out of the list. Your files stay "
                                       L"where they are.");
                        std::string sname_str = set.title;
                        size_t scharts = set.charts + set.pictures;
                        srm.Click([this, spath, sname_str, scharts, derived](auto &&, auto &&) {
                            if (derived)
                                ConfirmRemoveChartSet(spath, sname_str, scharts);
                            else
                                RemoveChartSet(spath);
                        });
                        Controls::Grid::SetColumn(srm, 3);
                        srow.Children().Append(srm);
                    }

                    // The row, then what scales the set holds. The ramp reads
                    // from the whole width of the card, so it goes under the
                    // switch rather than beside it. It is drawn into a host of
                    // its own, which the refresh refills when the bands
                    // change: they only change when a scan or a bake lands.
                    Controls::StackPanel ramp_host;
                    // Indented past the switch, so the bar starts under what
                    // it describes.
                    ramp_host.Margin({ 30, 0, 0, 0 });
                    Controls::StackPanel body;
                    body.Spacing(10);
                    body.Children().Append(srow);
                    body.Children().Append(ramp_host);
                    auto card = Card(DarkChrome());
                    card.Child(body);
                    stack.Children().Append(card);

                    chart_set_ui.push_back({ set.path, sname, ssum, prep, sts, ramp_host, {} });
                }
            }

            // Raster charts join the same list. Lookout renders both, so they
            // are one kind of thing to a mariner; only style links stay
            // separate, up in Active chart.
            if (!raster_paths.empty())
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
                    std::string g = lookout_raster_set_name_for(p.c_str(), nullptr);
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
                        bool const on = s.template as<Controls::ToggleSwitch>().IsOn();
                        set(on);
                        UpdateReadouts();
                        // The switch shows the answer already. Nothing on the
                        // page changes shape, so nothing is rebuilt: a rebuild
                        // here took the switch out from under the pointer.
                        auto name = s.template as<Controls::ToggleSwitch>();
                        if (auto row = name.Parent().try_as<Controls::Grid>())
                        {
                            for (auto const &child : row.Children())
                                if (auto label = child.try_as<Controls::TextBlock>())
                                    label.Opacity(on ? 1.0 : 0.6);
                        }
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


            // ---- Removing charts, while a delete runs -------------------------
            // A removal reports where it has got to, the way an import does.
            // The charts are out of the library the moment the rename returns
            // and the delete behind it is disk work: 930 cells is 446 MB. There
            // is NO WAY OUT of one, so no Cancel: the set is already off the
            // list and the charts are already moved aside.
            //
            // The line stays after it finishes, saying what went, until the
            // next removal or the next time this page is built.
            if (removal_job != nullptr)
            {
                auto p = removal_job->Snapshot();
                header(L"Removing charts");

                removal_pane_title = Controls::TextBlock{};
                removal_pane_title.FontSize(12);
                stack.Children().Append(removal_pane_title);

                removal_pane_bar = Controls::ProgressBar{};
                removal_pane_bar.Minimum(0);
                removal_pane_bar.Maximum(1);
                removal_pane_bar.HorizontalAlignment(HorizontalAlignment::Stretch);
                removal_pane_bar.Margin({ 0, 6, 0, 0 });
                stack.Children().Append(removal_pane_bar);

                removal_pane_count = Controls::TextBlock{};
                removal_pane_count.FontSize(11);
                removal_pane_count.Opacity(0.7);
                removal_pane_count.Margin({ 0, 6, 0, 0 });
                stack.Children().Append(removal_pane_count);
                // Current on the frame it is built in.
                PollRemovalPane();
            }
            // ---- Downloading from NOAA, while a transfer runs -----------------
            // Where it was started. This window stands over the chart, so a
            // transfer begun here otherwise runs behind it.
            if (lk_controller_is_open(controller))
            {
                lookout_noaa_state nst{};
                lk_controller_noaa_poll(controller, &nst);
                if (nst.phase == 3)
                {
                    header(L"Downloading from NOAA");
                    Controls::Grid line;
                    Controls::ColumnDefinition n0, n1;
                    n0.Width({ 1, GridUnitType::Star });
                    n1.Width({ 0, GridUnitType::Auto });
                    line.ColumnDefinitions().ReplaceAll({ n0, n1 });

                    noaa_pane_count = Controls::TextBlock{};
                    noaa_pane_count.FontSize(12);
                    noaa_pane_count.VerticalAlignment(VerticalAlignment::Center);
                    line.Children().Append(noaa_pane_count);

                    Controls::Button stop;
                    stop.Content(winrt::box_value(L"Cancel"));
                    stop.Click([this](auto &&, auto &&) {
                        lk_controller_noaa_cancel(controller);
                        BuildSettingsPage();
                    });
                    Controls::Grid::SetColumn(stop, 1);
                    line.Children().Append(stop);
                    stack.Children().Append(line);

                    noaa_pane_bar = Controls::ProgressBar{};
                    noaa_pane_bar.Minimum(0);
                    noaa_pane_bar.Maximum(1);
                    noaa_pane_bar.HorizontalAlignment(HorizontalAlignment::Stretch);
                    noaa_pane_bar.Margin({ 0, 6, 0, 0 });
                    stack.Children().Append(noaa_pane_bar);
                    // Fill both from the reading just taken, so the section is
                    // current on the frame it is built in.
                    PollNoaaPane();
                }
            }

            // ---- Preparing charts, while a bake runs --------------------------
            // The bake, for the same reason. Its own panel is over the chart,
            // behind this window.
            if (bake_job != nullptr)
            {
                auto p = bake_job->Snapshot();
                header(winrt::to_hstring(p.Title()).c_str());

                bake_pane_bar = Controls::ProgressBar{};
                bake_pane_bar.Minimum(0);
                bake_pane_bar.Maximum(1);
                bake_pane_bar.IsIndeterminate(p.total == 0);
                bake_pane_bar.Value(p.Fraction());
                bake_pane_bar.HorizontalAlignment(HorizontalAlignment::Stretch);
                stack.Children().Append(bake_pane_bar);

                Controls::Grid line;
                Controls::ColumnDefinition b0, b1;
                b0.Width({ 1, GridUnitType::Star });
                b1.Width({ 0, GridUnitType::Auto });
                line.ColumnDefinitions().ReplaceAll({ b0, b1 });
                line.Margin({ 0, 6, 0, 0 });

                Controls::StackPanel words;
                bake_pane_count = Controls::TextBlock{};
                bake_pane_count.FontSize(12);
                words.Children().Append(bake_pane_count);
                bake_pane_eta = Controls::TextBlock{};
                bake_pane_eta.FontSize(11);
                bake_pane_eta.Opacity(0.7);
                words.Children().Append(bake_pane_eta);
                words.VerticalAlignment(VerticalAlignment::Center);
                line.Children().Append(words);

                Controls::Button stop;
                stop.Content(winrt::box_value(L"Cancel"));
                stop.Click([this](auto &&, auto &&) {
                    if (bake_job != nullptr)
                        // The mariner stopped it. The core skips this set on resume until a
                        // scan of it finds a file to prepare that was not there before.
                        if (lookout_chart_sets *model = ChartSetsModel(); model != nullptr &&
                            !bake_source.empty())
                            lookout_chart_sets_note_cancel(model, bake_source.c_str());
                        bake_job->Cancel();
                });
                Controls::Grid::SetColumn(stop, 1);
                line.Children().Append(stop);
                stack.Children().Append(line);
                // The bake's own tick fills these in. This is the first
                // reading, for the frame the page is built in.
                bake_pane_count.Text(winrt::to_hstring(
                    p.total > 0 ? std::to_string(p.done) + " of " + std::to_string(p.total)
                                : p.cell));
                bake_pane_eta.Text(winrt::to_hstring(p.Remaining()));
            }

            // ---- Add charts, last ---------------------------------------------
            // Where to get more, last: a mariner reads what they have before
            // reading how to get more. One row per way in, each saying what it
            // does and what it costs to find out.
            header(L"Add charts");
            {
                bool dark = DarkChrome();
                bool working = bake_job != nullptr;
                // What the row's face is: the mark, the two lines, and the
                // answer on the right.
                auto face = [&](wchar_t const *glyph, wchar_t const *title,
                                wchar_t const *detail, std::wstring const &trailing) {
                    Controls::Grid row;
                    Controls::ColumnDefinition a0, a1, a2, a3;
                    a0.Width({ 0, GridUnitType::Auto });
                    a1.Width({ 1, GridUnitType::Star });
                    a2.Width({ 0, GridUnitType::Auto });
                    a3.Width({ 0, GridUnitType::Auto });
                    row.ColumnDefinitions().ReplaceAll({ a0, a1, a2, a3 });

                    Controls::FontIcon mark;
                    mark.Glyph(glyph);
                    mark.FontSize(17);
                    mark.Foreground(lkw::Brush(lkw::chrome::Accent(dark)));
                    mark.Width(22);
                    mark.Margin({ 0, 0, 13, 0 });
                    mark.VerticalAlignment(VerticalAlignment::Center);
                    row.Children().Append(mark);

                    Controls::TextBlock name;
                    name.Text(title);
                    name.FontSize(13);
                    name.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
                    Controls::TextBlock says;
                    says.Text(detail);
                    says.FontSize(12);
                    says.Foreground(lkw::Brush(lkw::chrome::Muted(dark)));
                    says.TextWrapping(TextWrapping::Wrap);
                    Controls::StackPanel words;
                    words.Spacing(3);
                    words.Children().Append(name);
                    words.Children().Append(says);
                    words.VerticalAlignment(VerticalAlignment::Center);
                    Controls::Grid::SetColumn(words, 1);
                    row.Children().Append(words);

                    if (!trailing.empty())
                    {
                        Controls::TextBlock right;
                        right.Text(winrt::hstring{ trailing });
                        right.FontSize(12);
                        right.Foreground(lkw::Brush(lkw::chrome::Muted(dark)));
                        right.Margin({ 8, 0, 8, 0 });
                        right.VerticalAlignment(VerticalAlignment::Center);
                        Controls::Grid::SetColumn(right, 2);
                        row.Children().Append(right);
                    }

                    Controls::FontIcon chevron;
                    chevron.Glyph(L"");
                    chevron.FontSize(12);
                    chevron.Foreground(lkw::Brush(lkw::chrome::Muted(dark)));
                    chevron.VerticalAlignment(VerticalAlignment::Center);
                    Controls::Grid::SetColumn(chevron, 3);
                    row.Children().Append(chevron);
                    return row;
                };

                // When NOAA's catalog was last read, which is what the prices
                // in the picker are built from.
                std::wstring checked;
                if (lk_controller_is_open(controller))
                {
                    lookout_noaa_state nst{};
                    lk_controller_noaa_poll(controller, &nst);
                    if (nst.checked_at != 0)
                    {
                        std::time_t at = (std::time_t)nst.checked_at;
                        std::tm when{};
                        std::tm today{};
                        std::time_t now = std::time(nullptr);
                        if (localtime_s(&when, &at) == 0 && localtime_s(&today, &now) == 0)
                        {
                            wchar_t buf[64]{};
                            bool same_day = when.tm_year == today.tm_year &&
                                            when.tm_yday == today.tm_yday;
                            std::wcsftime(buf, 64, same_day ? L"%H:%M" : L"%d %b %H:%M", &when);
                            checked = (same_day ? L"Checked today " : L"Checked ") + std::wstring{ buf };
                        }
                    }
                }

                Controls::Button noaa;
                noaa.Content(face(L"\uE753", L"Get charts from NOAA…",
                                  L"Pick the waters you sail. Lookout downloads the cells "
                                  L"and prepares them. Free.",
                                  checked));
                noaa.HorizontalAlignment(HorizontalAlignment::Stretch);
                noaa.HorizontalContentAlignment(HorizontalAlignment::Stretch);
                lkw::FlatFills(noaa, dark);
                noaa.BorderThickness({ 0, 0, 0, 0 });
                noaa.Padding({ 0, 6, 0, 6 });
                noaa.IsEnabled(!working && noaa_pane_count == nullptr);
                Automation::AutomationProperties::SetName(noaa, L"Get charts from NOAA");
                // Hand it to the next tick. ShowNoaaPicker closes the settings
                // window, and closing the window that owns this button from
                // inside its own Click handler destroys the button while the
                // handler is still running.
                noaa.Click([this](auto &&, auto &&) {
                    DispatcherQueue().TryEnqueue([this] { ShowNoaaPicker(); });
                });

                // ONE ROW FOR EVERYTHING ON THE DISK. A folder of cells, the
                // .zip an agency publishes, a chart already prepared and a
                // picture are all the mariner's own files: they are added the
                // same way and switched on the same way. Three rows made them
                // remember which row a file had gone in by.
                Controls::MenuFlyout ways;
                Controls::MenuFlyoutItem folder;
                folder.Text(L"Choose a Folder…");
                folder.Click([this](auto &&, auto &&) { PickChartFolder(); });
                ways.Items().Append(folder);
                Controls::MenuFlyoutItem one;
                one.Text(L"Choose a File…");
                one.Click([this](auto &&, auto &&) { PickChartFile(); });
                ways.Items().Append(one);

                Controls::Button disk;
                disk.Content(face(L"\uE8B7", L"Add charts from this computer…",
                                  L"A folder of cells, an archive, a prepared chart, or "
                                  L"pictures. Or drop any of them anywhere in the chart "
                                  L"window.",
                                  std::wstring{}));
                disk.HorizontalAlignment(HorizontalAlignment::Stretch);
                disk.HorizontalContentAlignment(HorizontalAlignment::Stretch);
                lkw::FlatFills(disk, dark);
                disk.BorderThickness({ 0, 0, 0, 0 });
                disk.Padding({ 0, 6, 0, 6 });
                disk.IsEnabled(!working);
                disk.Flyout(ways);
                Automation::AutomationProperties::SetName(disk,
                                                          L"Add charts from this computer");

                // Both rows in one card, with a hairline between them.
                Controls::Border divider;
                divider.Height(1);
                divider.Background(lkw::Brush(lkw::chrome::Rule(dark)));
                divider.Margin({ 0, 2, 0, 2 });
                Controls::StackPanel rows;
                rows.Children().Append(noaa);
                rows.Children().Append(divider);
                rows.Children().Append(disk);
                auto card = Card(dark);
                card.Child(rows);
                stack.Children().Append(card);
            }


            Controls::TextBlock add_foot;
            add_foot.Text(
                L"S-57 and S-101 cells (.000 with their updates) \x00B7 charts Lookout "
                L"has already prepared (.pmtiles) \x00B7 imagery and vendor charts "
                L"(.mbtiles) \x00B7 BSB/KAP raster sheets (.kap, .bsb). Cells and raster "
                L"sheets are converted once on the way in, coarse charts before "
                L"harbour detail, so a passage is covered even if the import is "
                L"stopped part way. Encrypted S-63 cells are not supported.");
            add_foot.FontSize(11);
            add_foot.Opacity(0.7);
            add_foot.TextWrapping(TextWrapping::Wrap);
            stack.Children().Append(add_foot);

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
                /* Commits on Enter or focus loss, never per keystroke: half
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

        // The shape just built, for the polls to compare against, and then
        // every value on it stated once.
        if (tab == "charts")
        {
            charts_page_sig = ChartsPageStructure();
            RefreshChartsPageInPlace();
        }

        settings_loading = false;
    }
}
