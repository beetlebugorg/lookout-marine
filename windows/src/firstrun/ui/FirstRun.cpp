// Setup, on screen: the six steps and NOAA's terms.
//
// The model is firstrun/lk_firstrun.h. It holds which step is on screen, what
// the buttons say, when the terms are asked, and what the Preparing page keeps
// after the two services reset. This file draws what the model reports and
// passes back what the mariner did. New rules belong in the model, where a test
// can reach them.
//
// The steps are built in code rather than in XAML, the way the settings pages
// are. Each step is mostly prose and a list, and XAML per step runs about four
// times the length.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <winrt/Microsoft.UI.Xaml.Documents.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cwchar>
#include <filesystem>
#include <limits>
#include <set>
#include <system_error>

#include "lk_bake.h"
#include "lk_coastline.h"
#include "lk_firstrun.h"
#include "lk_paths.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    using namespace winrt::Microsoft::UI::Xaml::Controls;
    using namespace winrt::Microsoft::UI::Xaml::Documents;
    using namespace winrt::Microsoft::UI::Xaml::Media;

    // NOAA's agreement itself. The paragraph beside it summarizes it.
    constexpr wchar_t kEncAgreement[] = L"https://www.charts.noaa.gov/ENCs/ENC_Agreement.shtml";

    // Text inherits its colour, and muted text is that colour at 70%. The Lk*
    // brushes live in Root's resources rather than the application's, and they
    // are theme dictionaries, so a code-side Lookup of one throws. Settings has
    // the same need and uses Opacity for it.
    TextBlock Line(std::wstring const &text, double size, bool strong = false)
    {
        TextBlock t;
        t.Text(text);
        t.FontSize(size);
        t.TextWrapping(TextWrapping::Wrap);
        if (strong)
            t.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        return t;
    }

    TextBlock Muted(std::wstring const &text, double size = 12.5)
    {
        auto t = Line(text, size, false);
        t.Opacity(0.7);
        return t;
    }

    // The chrome wears the chart's scheme, which hud/ui/Hud.cpp sets on Root in
    // one place. FirstRunRender reads it from there each time it builds a step,
    // so these helpers need no element to ask.
    bool g_dark = false;

    // The accent, as a literal rather than a lookup, for the reason above. The
    // two values are the LkAccentBrush pair from MainWindow.xaml, kept in step
    // with it by hand.
    Windows::UI::Color AccentColor(bool dark)
    {
        return dark ? Windows::UI::Color{ 0xFF, 0x7E, 0xA1, 0xF5 }
                    : Windows::UI::Color{ 0xFF, 0x1B, 0x49, 0xC4 };
    }

    SolidColorBrush AccentBrush() { return SolidColorBrush{ AccentColor(g_dark) }; }

    SolidColorBrush HairlineBrush()
    {
        return SolidColorBrush{ g_dark ? Windows::UI::Color{ 0x33, 0xFF, 0xFF, 0xFF }
                                       : Windows::UI::Color{ 0x33, 0x00, 0x00, 0x00 } };
    }

    // A step's title and the one line under it, centered in the card the way
    // the reference centers them. The blurb is held to 470 points: a line of
    // prose the full width of the card has no shorter line to center against.
    StackPanel Heading(std::wstring const &title, std::wstring const &blurb)
    {
        StackPanel s;
        s.Spacing(9);
        auto head = Line(title, 24, true);
        head.CharacterSpacing(-13); // the reference's -0.3 points at 24
        head.TextAlignment(TextAlignment::Center);
        head.HorizontalAlignment(HorizontalAlignment::Center);
        s.Children().Append(head);
        auto says = Muted(blurb, 13.5);
        says.TextAlignment(TextAlignment::Center);
        says.HorizontalAlignment(HorizontalAlignment::Center);
        says.MaxWidth(470);
        s.Children().Append(says);
        return s;
    }

    // One thing the app does, as a row: the glyph, then what and why.
    StackPanel Fact(wchar_t const *glyph, std::wstring const &title, std::wstring const &blurb)
    {
        StackPanel row;
        row.Orientation(Orientation::Horizontal);
        row.Spacing(12);

        FontIcon icon;
        icon.Glyph(glyph);
        icon.FontSize(18);
        icon.Foreground(AccentBrush());
        icon.VerticalAlignment(VerticalAlignment::Top);
        icon.Margin({ 0, 2, 0, 0 });
        row.Children().Append(icon);

        StackPanel words;
        words.Spacing(2);
        words.MaxWidth(560);
        words.Children().Append(Line(title, 14, true));
        words.Children().Append(Muted(blurb));
        row.Children().Append(words);
        return row;
    }

    // The amber panel the compliance text sits in. The colour is fixed in both
    // schemes, because it means "read this" in day and night alike.
    Border WarningPanel(std::wstring const &heading, std::wstring const &body)
    {
        StackPanel words;
        words.Spacing(4);

        TextBlock head;
        head.Text(heading);
        head.FontSize(12);
        head.FontWeight(Windows::UI::Text::FontWeights::Bold());
        head.CharacterSpacing(50);
        words.Children().Append(head);
        words.Children().Append(Muted(body, 12));

        Border b;
        b.CornerRadius({ 9, 9, 9, 9 });
        b.Padding({ 12, 11, 12, 11 });
        b.Background(SolidColorBrush{ Windows::UI::Color{ 0x24, 0xF5, 0x9E, 0x0B } });
        b.BorderBrush(SolidColorBrush{ Windows::UI::Color{ 0x8C, 0xF5, 0x9E, 0x0B } });
        b.BorderThickness({ 1, 1, 1, 1 });
        b.Child(words);
        return b;
    }

    // A link that opens in the mariner's browser.
    TextBlock LinkLine(std::wstring const &text, std::wstring const &url)
    {
        TextBlock t;
        t.FontSize(12.5);
        t.TextWrapping(TextWrapping::Wrap);
        Hyperlink h;
        h.NavigateUri(Windows::Foundation::Uri{ url });
        Run r;
        r.Text(text);
        h.Inlines().Append(r);
        t.Inlines().Append(h);
        return t;
    }

    // The depth step's illustration, at the size the card gives it.
    constexpr double kSeabedW = 286;
    constexpr double kSeabedH = 210;

    // One colour out of the engine's own palette, in the scheme on screen, so
    // a legend and the chart cannot drift apart. The fallbacks are the day
    // scheme's own values, for a token the engine does not answer for.
    Windows::UI::Color S52Color(wchar_t const *token, uint32_t scheme)
    {
        struct Fallback
        {
            wchar_t const       *token;
            Windows::UI::Color   color;
        };
        static Fallback const kFallbacks[] = {
            { L"DEPVS", { 0xFF, 0x61, 0xB8, 0xFF } }, { L"DEPMS", { 0xFF, 0x82, 0xC9, 0xFF } },
            { L"DEPMD", { 0xFF, 0xA6, 0xD9, 0xFA } }, { L"DEPDW", { 0xFF, 0xC9, 0xED, 0xFF } },
            { L"LANDA", { 0xFF, 0xBF, 0xBF, 0x8F } }, { L"DEPCN", { 0xFF, 0x75, 0x8C, 0x96 } },
        };
        Windows::UI::Color out{ 0xFF, 0x80, 0x80, 0x80 };
        for (auto const &f : kFallbacks)
            if (wcscmp(f.token, token) == 0)
                out = f.color;

        char narrow[16]{};
        for (size_t i = 0; i < 15 && token[i] != 0; ++i)
            narrow[i] = (char)token[i];
        float rgba[4]{ 0, 0, 0, 1 };
        if (lookout_s52_color(narrow, scheme, rgba) != 0)
            out = { (uint8_t)(rgba[3] * 255.0f + 0.5f), (uint8_t)(rgba[0] * 255.0f + 0.5f),
                    (uint8_t)(rgba[1] * 255.0f + 0.5f), (uint8_t)(rgba[2] * 255.0f + 0.5f) };
        return out;
    }

    uint32_t SchemeOf(lk_controller *c)
    {
        tile57_mariner m{};
        if (c != nullptr)
            lk_controller_get_mariner(c, &m);
        return (uint32_t)m.scheme;
    }

    // A pill or a segment wearing the pick.
    void PaintPicked(Button const &b, bool on)
    {
        b.BorderThickness({ 1, 1, 1, 1 });
        if (on)
        {
            b.Background(AccentBrush());
            b.BorderBrush(SolidColorBrush{ Windows::UI::Colors::Transparent() });
            b.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
            b.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        }
        else
        {
            b.Background(SolidColorBrush{ Windows::UI::Colors::Transparent() });
            b.BorderBrush(HairlineBrush());
            // Back to the theme's own ink rather than a colour of this file's.
            b.ClearValue(Controls::Control::ForegroundProperty());
            b.FontWeight(Windows::UI::Text::FontWeights::Normal());
        }
    }

    // A point on one depth line, `u` of the way across. The wave and the rise
    // to the right are the same for every line, so the lines never cross and
    // the bands never pinch.
    Windows::Foundation::Point SeabedPoint(double t, double u)
    {
        double const wave = 0.055 * std::sin(u * 3.14159265358979 * 1.7 + 0.4) + 0.045 * u;
        return { (float)(u * kSeabedW), (float)(kSeabedH - kSeabedH * t + kSeabedH * wave) };
    }

    // One region as a pill: a capsule the mariner picks, ticked and filled
    // while it is in the pick. The reference draws the districts this way in
    // setup and in the settings picker alike.
    Button RegionPill(std::wstring const &name, std::wstring const &blurb,
                      lkw::RegionHold const &hold, bool on, bool enabled)
    {
        StackPanel row;
        row.Orientation(Orientation::Horizontal);
        row.Spacing(6);
        row.VerticalAlignment(VerticalAlignment::Center);
        if (on)
        {
            FontIcon tick;
            tick.Glyph(L""); // CheckMark
            tick.FontSize(10);
            tick.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
            row.Children().Append(tick);
        }
        TextBlock t;
        t.Text(name);
        t.FontSize(12.5);
        if (on)
        {
            t.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            t.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
        }
        row.Children().Append(t);

        // What of this water is here, after the name. Water with none of it
        // here says nothing, which is every region on a first run.
        std::wstring const badge = lkw::RegionBadge(hold);
        if (!badge.empty())
        {
            TextBlock note;
            note.Text(badge);
            note.FontSize(11);
            note.Opacity(0.75);
            if (on)
                note.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
            row.Children().Append(note);
        }

        Button b;
        b.Content(row);
        b.Height(30);
        b.MinWidth(0);
        b.Padding({ 13, 0, 13, 0 });
        b.CornerRadius({ 15, 15, 15, 15 });
        b.BorderThickness({ 1, 1, 1, 1 });
        if (on)
        {
            b.Background(AccentBrush());
            b.BorderBrush(SolidColorBrush{ Windows::UI::Colors::Transparent() });
        }
        else
        {
            b.BorderBrush(HairlineBrush());
        }
        b.IsEnabled(enabled);
        b.Opacity(enabled ? 1.0 : 0.5);
        ToolTipService::SetToolTip(b, box_value(blurb));
        Automation::AutomationProperties::SetName(b, lkw::RegionLabel(name, blurb, hold));
        return b;
    }

    // About how wide that pill draws, for laying the row out. WinUI has no
    // panel that wraps, and the card is a fixed 720 points, so the rows are
    // worked out before anything is built: 12.5 point Segoe runs a little
    // under 7 points a character, and the capsule adds its padding, its border
    // and the tick. The badge is 11 point, at about six.
    double RegionPillWidth(std::wstring const &name, std::wstring const &badge, bool on)
    {
        double wide = 28.0 + (on ? 16.0 : 0.0) + (double)name.size() * 7.0;
        if (!badge.empty())
            wide += 6.0 + (double)badge.size() * 6.2;
        return wide;
    }

    // One pickable card: the source step's three, and the coverage step's
    // regions. The border shows the checked state, and the whole card is the
    // click target.
    Button ChoiceCard(wchar_t const *glyph, std::wstring const &title, std::wstring const &blurb,
                      bool picked, bool recommended)
    {
        StackPanel words;
        words.Spacing(3);

        StackPanel title_row;
        title_row.Orientation(Orientation::Horizontal);
        title_row.Spacing(8);
        title_row.Children().Append(Line(title, 14, true));
        if (recommended)
        {
            Border tag;
            tag.CornerRadius({ 8, 8, 8, 8 });
            tag.Padding({ 7, 1, 7, 2 });
            tag.Background(AccentBrush());
            TextBlock tt;
            tt.Text(L"Recommended");
            tt.FontSize(10.5);
            tt.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            tt.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
            tag.Child(tt);
            tag.VerticalAlignment(VerticalAlignment::Center);
            title_row.Children().Append(tag);
        }
        words.Children().Append(title_row);
        words.Children().Append(Muted(blurb));

        StackPanel row;
        row.Orientation(Orientation::Horizontal);
        row.Spacing(12);
        if (glyph != nullptr)
        {
            FontIcon icon;
            icon.Glyph(glyph);
            icon.FontSize(17);
            icon.VerticalAlignment(VerticalAlignment::Top);
            icon.Margin({ 0, 2, 0, 0 });
            if (picked)
                icon.Foreground(AccentBrush());
            else
                icon.Opacity(0.7);
            row.Children().Append(icon);
        }
        row.Children().Append(words);

        Button b;
        b.Content(row);
        b.HorizontalAlignment(HorizontalAlignment::Stretch);
        b.HorizontalContentAlignment(HorizontalAlignment::Left);
        b.Padding({ 14, 12, 14, 12 });
        b.CornerRadius({ 10, 10, 10, 10 });
        b.BorderThickness(picked ? Thickness{ 2, 2, 2, 2 } : Thickness{ 1, 1, 1, 1 });
        b.BorderBrush(picked ? AccentBrush() : HairlineBrush());
        return b;
    }

    // The directory the build copies the first-run pictures and the coastline
    // into, beside the exe. Each shell keeps its own copy of these, as they do
    // for the icons.
    std::filesystem::path FirstRunDataDir()
    {
        wchar_t exe[MAX_PATH]{};
        DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
        if (n == 0 || n >= MAX_PATH)
            return {};
        return std::filesystem::path(exe).parent_path() / L"data" / L"firstrun";
    }

    // One picture from that directory, or nullptr when the file is absent. The
    // steps that use these read properly without them. That is also what a
    // first launch looks like if a file fails to load.
    Media::Imaging::BitmapImage FirstRunPicture(wchar_t const *name)
    {
        auto path = FirstRunDataDir() / name;
        std::error_code ec;
        if (path.empty() || !std::filesystem::exists(path, ec))
            return nullptr;
        // Uri needs a scheme. A bare drive path throws, and a throw here runs
        // during the first layout, where it leaves the window blank.
        std::wstring uri = L"file:///" + path.wstring();
        for (auto &c : uri)
            if (c == L'\\')
                c = L'/';
        try
        {
            return Media::Imaging::BitmapImage{ Windows::Foundation::Uri{ uri } };
        }
        catch (winrt::hresult_error const &)
        {
            return nullptr;
        }
    }

    // The shape the other shells price a region in, so "1,238 charts,
    // 226.5 MB". The settings pane totals a library the same way, so both
    // read the model's copy.
    using lkw::SizeText;
    using lkw::Thousands;
}

namespace winrt::LookoutMarine::implementation
{
    // ---- the pane ---------------------------------------------------------

    void MainWindow::FirstRunAttach()
    {
        // The fold follows the step, the card and the scroll position, so it
        // is recomputed on all three.
        FirstRunScroll().SizeChanged([this](auto &&, auto &&) { FirstRunUpdateFold(); });
        FirstRunScroll().ViewChanged([this](auto &&, auto &&) { FirstRunUpdateFold(); });
        FirstRunBody().SizeChanged([this](auto &&, auto &&) { FirstRunUpdateFold(); });
        FirstRunPrimaryBtn().Click([this](auto &&, auto &&) { FirstRunPrimary(); });
        FirstRunBackBtn().Click([this](auto &&, auto &&) {
            // One step opened on its own has nowhere to go back to, so the
            // same button closes it and leaves the chart standing.
            if (first_run.picker_only())
            {
                first_run.Finish();
                FirstRunRender();
                return;
            }
            first_run.Back();
            FirstRunRender();
        });
        FirstRunLaterBtn().Click([this](auto &&, auto &&) {
            // Set Up Later leaves a usable app behind it. The basemap is
            // already drawing, so putting the card away is enough.
            first_run.Finish();
            FirstRunRender();
        });
    }

    // Show or hide the chart controls. Setup covers the chart, so they steer
    // something the mariner cannot see.
    void MainWindow::FirstRunChartChrome(bool shown)
    {
        auto v = shown ? Visibility::Visible : Visibility::Collapsed;
        SearchCluster().Visibility(v);
        NorthBtn().Visibility(v);
        ZoomStack().Visibility(v);
        SettingsBtn().Visibility(v);
        ScaleBar().Visibility(v);
        HudPill().Visibility(v);
    }

    // Get charts from NOAA, in the Charts pane. It opens the coverage step on
    // its own over the chart, so the picker, the download, the bake and the
    // handover are the same code setup runs.
    void MainWindow::ShowNoaaPicker()
    {
        CloseSettings();
        noaa_handed_over = false;
        noaa_region_id.clear();
        noaa_picked_seeded = false;
        lk_controller_noaa_refresh(controller);
        first_run.BeginAt(lkw::FirstRunStep::Coverage);
        FirstRunRender();
    }

    // Show the fold while the step runs past the bottom of the card, and keep
    // the scrollbar up with it. A step that fits shows neither.
    void MainWindow::FirstRunUpdateFold()
    {
        auto scroll = FirstRunScroll();
        // Two pixels of slack: a step that fits exactly reports an extent a
        // fraction over the viewport on some scales.
        bool const more = scroll.ExtentHeight() > scroll.ViewportHeight() + 2.0;
        FirstRunFade().Visibility(more ? Visibility::Visible : Visibility::Collapsed);
        // The scrollbar's own mode is left alone. Asking for it to stand open
        // narrows the viewport, which makes the content taller, which keeps
        // this test true: the fade then stayed up on a step that fits.

        // The fade goes to the card's colour, which follows the scheme.
        auto const panel = g_dark ? Windows::UI::Color{ 0xF2, 0x12, 0x1C, 0x24 }
                                  : Windows::UI::Color{ 0xF2, 0xF8, 0xF8, 0xF8 };
        FirstRunFadeTop().Color({ 0, panel.R, panel.G, panel.B });
        FirstRunFadeBottom().Color(panel);
    }

    void MainWindow::FirstRunBegin()
    {
        first_run.Begin();
        FirstRunRender();
    }

    void MainWindow::FirstRunRender()
    {
        if (!first_run.showing())
        {
            FirstRunPane().Visibility(Visibility::Collapsed);
            FirstRunChartChrome(true);
            if (first_run_timer != nullptr)
                first_run_timer.Stop();
            // Setup stood over the basemap, and putting the card away leaves
            // that blank sea on screen. The charts installed while it was up
            // are opened here.
            if (lk_controller_is_open(controller) && !chart_has_cells)
            {
                auto paths = ChartSetOpenPaths();
                if (!paths.empty())
                    OpenPaths(paths, lkw::ChartLibraryDir(), lkw::AgencyForCells(paths));
            }
            return;
        }
        // The search, menu, north, zoom, settings and scale bar steer a chart.
        // Setup is a takeover, and the scale bar sat over the Set Up Later
        // button at the bottom of the card.
        FirstRunChartChrome(false);
        g_dark = Root().ActualTheme() == ElementTheme::Dark;
        FirstRunPane().Visibility(Visibility::Visible);
        FirstRunTitle().Text(first_run.Title());
        FirstRunTitle().Visibility(first_run.step() == lkw::FirstRunStep::Welcome
                                       ? Visibility::Collapsed
                                       : Visibility::Visible);
        // Back through the flow, or the way out of a step opened on its own.
        bool const picker = first_run.picker_only();
        FirstRunBackBtn().Content(box_value(picker ? L"Cancel" : L"Back"));
        FirstRunBackBtn().Visibility(picker || first_run.CanGoBack() ? Visibility::Visible
                                                                    : Visibility::Collapsed);
        FirstRunFooterShape(first_run.step() == lkw::FirstRunStep::Welcome);
        FirstRunPrimaryBtn().Content(box_value(first_run.PrimaryTitle(!chart_link_url.empty())));

        auto body = FirstRunBody();
        body.Children().Clear();
        // The controls the poll writes to died with that Clear.
        first_run_phase_ui.clear();
        first_run_band_ui.clear();
        first_run_bar = nullptr;

        // The welcome hero runs to the top and side edges of the card, so the
        // body carries no inset and each step adds its own. The hero goes into
        // `body` at full width and everything under it goes into `inset`.
        bool const welcome = first_run.step() == lkw::FirstRunStep::Welcome;
        if (welcome)
            FirstRunHero(body);

        StackPanel inset;
        inset.Spacing(14);
        inset.Margin(welcome ? Thickness{ 24, 20, 24, 20 } : Thickness{ 24, 14, 24, 20 });
        body.Children().Append(inset);

        switch (first_run.step())
        {
        case lkw::FirstRunStep::Welcome:     FirstRunWelcome(inset); break;
        case lkw::FirstRunStep::Source:      FirstRunSource(inset); break;
        case lkw::FirstRunStep::Coverage:    FirstRunCoverage(inset); break;
        case lkw::FirstRunStep::OnlineChart: FirstRunOnline(inset); break;
        case lkw::FirstRunStep::Importing:   FirstRunImporting(inset); break;
        case lkw::FirstRunStep::Depths:      FirstRunDepths(inset); break;
        }
        // What the step now says, and whether its action can be taken. Both
        // are stated in one place, so a poll can restate them without
        // building the step again.
        FirstRunRestate();
        // A step that waits on something gets the clock that watches it.
        FirstRunPollAsNeeded();
        FirstRunUpdateFold();
    }

    // Which of the two footer containers holds the primary action. The welcome
    // step stacks it over Set Up Later and centers both. Every later step puts
    // Back on the left and the primary action on the right. Set Up Later has no
    // place there, because past the welcome step the mariner is choosing a
    // chart and Back is what returns them.
    void MainWindow::FirstRunFooterShape(bool welcome)
    {
        if (first_run_footer_shaped && first_run_footer_welcome == welcome)
            return;
        first_run_footer_welcome = welcome;
        first_run_footer_shaped  = true;

        auto primary = FirstRunPrimaryBtn();
        auto column  = FirstRunColumn();
        auto actions = FirstRunActions();
        uint32_t at = 0;
        // Move it only when it is somewhere else. XAML throws on adding an
        // element to the panel it already sits in, and the button starts in
        // `actions`, so the first shaping of a step that wants the row there
        // added it twice. Setup never reached that, because its first step is
        // the welcome one and wants the column; Get charts from NOAA opens on
        // the coverage step and wants the row.
        if (welcome)
        {
            if (!column.Children().IndexOf(primary, at))
            {
                if (actions.Children().IndexOf(primary, at))
                    actions.Children().RemoveAt(at);
                column.Children().InsertAt(0, primary);
            }
            primary.Width(300);
            primary.HorizontalAlignment(HorizontalAlignment::Center);
        }
        else
        {
            if (!actions.Children().IndexOf(primary, at))
            {
                if (column.Children().IndexOf(primary, at))
                    column.Children().RemoveAt(at);
                actions.Children().Append(primary);
            }
            primary.Width(std::numeric_limits<double>::quiet_NaN());
            primary.HorizontalAlignment(HorizontalAlignment::Right);
        }
        column.Visibility(welcome ? Visibility::Visible : Visibility::Collapsed);
        FirstRunBar().Visibility(welcome ? Visibility::Collapsed : Visibility::Visible);
    }

    void MainWindow::FirstRunPrimary()
    {
        auto act = first_run.Advance();
        if (first_run.showing_enc_terms())
        {
            // The model raised NOAA's terms instead of moving the step.
            FirstRunShowEncTerms();
            return;
        }
        if (act.has_value())
            FirstRunAct(act.value());
        FirstRunRender();
    }

    // What to do once the flow has finished asking. The model has moved the
    // step. This starts the work that step promised.
    void MainWindow::FirstRunAct(lkw::ChartSource source)
    {
        switch (source)
        {
        case lkw::ChartSource::Noaa:
        {
            if (noaa_region_id.empty())
                return;

            // Price it once, here, and keep what it reported. The page outlives
            // the transfer's counters. A re-price mid-download moves the target
            // the mariner is watching.
            uint32_t cells = 0;
            uint64_t bytes = 0;
            lk_controller_noaa_cost(controller, noaa_region_id.c_str(), &cells, &bytes,
                                    nullptr, nullptr);

            lkw::FirstRunOrder order;
            order.region_ids = noaa_region_id;
            order.charts     = cells;
            order.bytes      = bytes;
            // Name the regions rather than their ids, so "Alaska" for "d17",
            // and every one the mariner picked.
            lookout_noaa_region const *regions = nullptr;
            size_t const n = lk_controller_noaa_regions(&regions);
            for (size_t i = 0; i < n && regions != nullptr; ++i)
            {
                if (!lkw::RegionPicked(noaa_region_id, regions[i].id))
                    continue;
                if (!order.regions.empty())
                    order.regions += L", ";
                order.regions += winrt::to_hstring(regions[i].name);
            }
            first_run.set_order(std::move(order));

            // The zips go beside the library rather than in it. They are
            // the source a bake reads. The vector open globs the library for
            // .pmtiles, so a zip inside it joins the composed chart library.
            auto dest = std::filesystem::path(lkw::ChartLibraryDir()).parent_path() / "Downloads";
            std::error_code ec;
            std::filesystem::create_directories(dest, ec);
            noaa_dest_dir = dest.string();

            // `again` fetches the cells this device already holds as well,
            // which is what a pick of water that is wholly installed asks for.
            lk_controller_noaa_download(controller, noaa_region_id.c_str(),
                                        noaa_dest_dir.c_str(), NoaaAllHeld() ? 1 : 0);
            first_run_import_idle = false; // a fresh import has work to watch
            FirstRunPollStart();
            break;
        }

        case lkw::ChartSource::Online:
            if (!chart_link_url.empty())
                AddChartLink(chart_link_url);
            break;

        case lkw::ChartSource::Files:
            // The model has put setup away, so the picker comes up over the
            // chart rather than over a card that is about to close.
            PickChartFolder();
            break;
        }
    }

    // ---- the two services, on a timer -------------------------------------

    // Whether there is anything to watch, and the timer started or stopped to
    // match.
    //
    // It used to be started in one place only, when a download began, so the
    // coverage step never noticed its catalog read finish: the line said
    // "Reading NOAA's chart catalog…" for as long as the step was up, and the
    // map kept the rough extents it was built with. A read, a transfer, a bake
    // and a bake waiting to be handed over are the four things worth a tick;
    // with none of them the timer stops, so an idle card keeps no clock.
    void MainWindow::FirstRunPollAsNeeded()
    {
        bool want = false;
        if (first_run.showing() && controller != nullptr)
        {
            lookout_noaa_state st{};
            lk_controller_noaa_poll(controller, &st);
            want = st.phase == 1 ||                                 // a catalog read
                   st.phase == 3 ||                                 // a transfer
                   (bake_job != nullptr && bake_job->Running()) ||  // a bake
                   // An import between its parts. The bake is STARTED by the
                   // poll itself, from the tick that finds the transfer over,
                   // so the clock has to outlive the transfer: stopping it on
                   // the tick the download ended left the step saying
                   // "Downloading charts" with nothing to start the bake.
                   (first_run.step() == lkw::FirstRunStep::Importing &&
                    !noaa_handed_over && !first_run_import_idle);
        }
        if (want)
            FirstRunPollStart();
        else if (first_run_timer != nullptr)
            first_run_timer.Stop();
    }

    void MainWindow::FirstRunPollStart()
    {
        if (first_run_timer == nullptr)
        {
            first_run_timer = DispatcherTimer();
            first_run_timer.Interval(std::chrono::milliseconds(250));
            first_run_timer.Tick([this](auto &&, auto &&) { FirstRunPoll(); });
        }
        first_run_timer.Start();
    }

    void MainWindow::FirstRunPoll()
    {
        lkw::FirstRunLive live;

        lookout_noaa_state st{};
        lk_controller_noaa_poll(controller, &st);
        live.downloading = st.phase == 3;
        live.fetched     = st.done;
        live.expected    = st.total;

        if (bake_job)
        {
            auto snap = bake_job->Snapshot();
            live.baking = snap.running;
            live.found  = snap.total;
            live.baked  = snap.done;
            // The bake publishes no per-band counter. The scan's bands and the
            // bake's own count give one, because the bake runs coarse band
            // first.
            if (!noaa_scan_bands.empty())
                live.bands = lkw::FirstRunBands(noaa_scan_bands, snap.done);
        }

        first_run.Observe(live);

        // The bake has finished. Hand the library to the shell the way an
        // ordinary import does (library/ui/Bake.cpp). Without this the charts
        // it wrote have no chart set and no recent, and the next launch finds
        // an empty library and runs setup over the top of them.
        if (first_run.saw_bake() && !live.baking && bake_job != nullptr &&
            !bake_job->Running() && !noaa_handed_over)
        {
            noaa_handed_over = true;
            bake_job.reset();
            first_run_timer.Stop();
            // The whole library rather than this run's output alone, and the
            // recent is the library rather than the download it was baked from.
            auto charts = lkw::CollectCells(BakeOutputDir());
            if (!charts.empty())
                OpenPaths(charts, lkw::ChartLibraryDir(), lkw::AgencyForCells(charts));
            // A successful open puts setup away. Setup has the depth step left
            // to ask, so put it back.
            FirstRunRender();
            return;
        }

        // The transfer is over and no bake is running. Scan the destination and
        // start one. `saw_bake` stops this firing again after the bake has
        // finished.
        if (!live.downloading && !live.baking && !first_run.saw_bake() &&
            !noaa_dest_dir.empty() && first_run.order().has_value())
        {
            auto scan = lkw::ScanCharts(noaa_dest_dir);

            // Drop the cells the library already holds a prepared chart for,
            // the same merge library/ui/Bake.cpp runs before an import. The
            // download directory is one fixed folder, so a mariner who picks a
            // second region finds the first region's zips still in it, and
            // without this the bake reprocesses every chart they already have.
            // The core does the same at src/chartsets.zig:503.
            std::set<std::string> ready;
            {
                std::error_code ec;
                std::filesystem::path root(BakeOutputDir());
                if (std::filesystem::is_directory(root, ec))
                    for (auto it = std::filesystem::recursive_directory_iterator(root, ec);
                         !ec && it != std::filesystem::recursive_directory_iterator();
                         it.increment(ec))
                        if (it->is_regular_file(ec))
                            ready.insert(it->path().stem().string());
            }
            lkw::ScanResult fresh = scan;
            fresh.cells.clear();
            for (auto const &c : scan.cells)
                if (!c.NeedsPrepare() ||
                    ready.count(std::filesystem::path(c.name).stem().string()) == 0)
                    fresh.cells.push_back(c);
            scan = std::move(fresh);

            noaa_scan_bands.clear();
            noaa_scan_bands.reserve(scan.cells.size());
            for (auto const &c : scan.cells)
                noaa_scan_bands.push_back(c.band);
            if (!scan.cells.empty())
            {
                bake_job = std::make_unique<lkw::BakeJob>();
                bake_job->Start(scan, noaa_dest_dir, lkw::ChartLibraryDir(),
                                lkw::RasterLibraryDir());
            }
            else
            {
                // The transfer produced no charts. There is no work left to
                // watch, and saying so is what lets the clock stop.
                first_run_import_idle = true;
            }
        }

        // The Preparing step moves four times a second. Its values are
        // restated; it is built again only when its shape changes, which is
        // the bands arriving and the Stop button going.
        if (first_run.step() == lkw::FirstRunStep::Importing)
        {
            if (FirstRunImportingShape() != first_run_importing_shape)
                FirstRunRender();
            else
                FirstRunRestate();
        }

        // The catalog lands on its own, and the coverage map's boxes, the
        // prices and whether a region can be picked at all come from it. So
        // the step follows it — once, when it changes. Rendering on every tick
        // would rebuild the map four times a second.
        if (first_run.step() == lkw::FirstRunStep::Coverage)
        {
            std::string now = NoaaCatalogSignature();
            if (now != noaa_catalog_drawn)
            {
                noaa_catalog_drawn = now;
                FirstRunRender(); // which sets the clock again
                return;
            }
        }
        // Nothing left to watch: stop rather than tick over finished work.
        FirstRunPollAsNeeded();
    }

    // Whether every chart the pick covers is installed already. The cost call
    // leaves held cells out, so it prices nothing when there is nothing new.
    bool MainWindow::NoaaAllHeld()
    {
        if (noaa_region_id.empty() || controller == nullptr)
            return false;
        uint32_t cells = 0, held = 0;
        uint64_t bytes = 0, held_bytes = 0;
        if (!lk_controller_noaa_cost(controller, noaa_region_id.c_str(), &cells, &bytes, &held,
                                     &held_bytes))
            return false;
        return cells == 0 && held > 0;
    }

    // What the coverage step draws from. The counters of a download are left
    // out: they move every tick and the step states them from its own poll.
    std::string MainWindow::NoaaCatalogSignature()
    {
        lookout_noaa_state st{};
        lk_controller_noaa_poll(controller, &st);
        return std::to_string(st.phase) + "|" + std::to_string(st.have_catalog) + "|" +
               std::to_string(st.catalog_cells) + "|" + st.date + "|" + st.error;
    }

    // ---- NOAA's terms -----------------------------------------------------

    fire_and_forget MainWindow::FirstRunShowEncTerms()
    {
        auto lifetime = get_strong();

        StackPanel body;
        body.Spacing(12);
        body.MaxWidth(520);
        body.Children().Append(WarningPanel(
            L"NOT FOR NAVIGATION",
            L"By importing charts you accept that Lookout is a prototype and not a certified "
            L"navigation system, and that the charts it prepares are processed for display and "
            L"are not the official ENC. They do not meet chart carriage regulations. You remain "
            L"responsible for the safe navigation of your vessel and for keeping clear of every "
            L"danger. Verify everything shown here against official, up-to-date charts and "
            L"publications, and keep a paper backup."));
        // NOAA's own terms, in their words. They apply to their charts whoever
        // prepared them.
        body.Children().Append(Muted(
            L"NOAA ENC® charts come from the NOAA Office of Coast Survey and are updated "
            L"weekly on a best-efforts basis; you are responsible for holding the current "
            L"edition and the latest updates. NOAA makes no warranty and assumes no liability "
            L"for their use.",
            12));
        body.Children().Append(LinkLine(L"NOAA ENC User Agreement", kEncAgreement));

        ContentDialog dlg;
        dlg.XamlRoot(Content().XamlRoot());
        dlg.RequestedTheme(Root().RequestedTheme());
        dlg.Title(box_value(L"Before you download"));
        dlg.Content(body);
        dlg.PrimaryButtonText(L"Agree and Continue");
        dlg.CloseButtonText(L"Cancel");
        dlg.DefaultButton(ContentDialogButton::Primary);

        auto result = co_await dlg.ShowAsync();
        if (result == ContentDialogResult::Primary)
            first_run.AgreeToEncTerms();
        else
            first_run.DeclineEncTerms(); // the source step stands, NOAA still picked
        FirstRunRender();
    }

    // ---- the steps --------------------------------------------------------

    // The hero, bleeding to the top and side edges of the card. It goes into
    // the body rather than the step inset, so nothing pads it.
    //
    // The picture is wider than the card. The Border is what the layout sizes,
    // and the image fills it, so the picture has no say in the card width. A
    // fixed height on the image itself made its natural width drive the step
    // and clipped both edges.
    void MainWindow::FirstRunHero(Controls::StackPanel const &body)
    {
        auto picture = FirstRunPicture(L"welcome-chart.png");
        if (picture == nullptr)
            return;
        Image hero;
        hero.Source(picture);
        hero.Stretch(Media::Stretch::UniformToFill);
        hero.HorizontalAlignment(HorizontalAlignment::Stretch);
        hero.VerticalAlignment(VerticalAlignment::Center);

        Border frame;
        frame.Height(210);
        frame.HorizontalAlignment(HorizontalAlignment::Stretch);
        // Only the top corners, matching the card, so the picture meets its
        // edge without rounding into the prose below.
        frame.CornerRadius({ 12, 12, 0, 0 });
        frame.Child(hero);
        Automation::AutomationProperties::SetName(frame, L"A Lookout chart of Annapolis");
        body.Children().Append(frame);
    }

    void MainWindow::FirstRunWelcome(Controls::StackPanel const &body)
    {
        // The title and the line under it center, as they do on every step.
        // The rows below them stay left aligned, so the step holds two
        // alignments rather than one.
        body.Children().Append(Heading(L"Welcome to Lookout Marine",
                                       L"Official charts, rendered live on your PC."));
        body.Children().Append(Fact(L"" /* map pin */,
                                    L"Official ENC charts, drawn live",
                                    L"Lookout renders S-57 and S-101 cells itself. NOAA publishes "
                                    L"every United States chart at no cost; most other offices "
                                    L"sell theirs."));
        body.Children().Append(Fact(L"" /* globe */, L"Or start with an online chart",
                                    L"A published chart style renders straight away, worldwide, "
                                    L"with nothing to download and nothing stored."));
        body.Children().Append(Fact(L"" /* folder */, L"Bring charts you already have",
                                    // A window that takes a drop says so, the
                                    // way the Mac's does.
                                    L"A prepared .pmtiles chart, or a folder of S-57 cells. Or "
                                    L"drop either anywhere in this window."));
        body.Children().Append(
            Muted(L"Lookout is a prototype and is not a certified navigation system. It does not "
                  L"meet chart carriage regulations. Always carry official charts aboard.",
                  12));
    }

    void MainWindow::FirstRunSource(Controls::StackPanel const &body)
    {
        body.Children().Append(
            Heading(L"How would you like to add charts?",
                    L"You can add the other sources any time, from Charts in Mariner settings."));

        struct Choice
        {
            lkw::ChartSource src;
            wchar_t const   *glyph;
            wchar_t const   *title;
            wchar_t const   *blurb;
            bool             recommended;
        };
        // The Files blurb names dropping, which a window accepts and a phone
        // does not. Apple keeps the same split in FirstRunWords.
        static Choice const choices[] = {
            { lkw::ChartSource::Noaa, L"" /* map pin */, L"NOAA charts",
              L"Official ENC for every U.S. waterway, free. Downloaded to this device and "
              L"prepared here.",
              true },
            { lkw::ChartSource::Online, L"" /* globe */, L"Online chart",
              L"A published chart style. Renders straight away, worldwide, and stores nothing.",
              false },
            { lkw::ChartSource::Files, L"" /* folder */, L"Files on this device",
              L"A prepared .pmtiles chart, or a folder of S-57 cells. Or drop either anywhere "
              L"in this window.",
              false },
        };

        for (auto const &c : choices)
        {
            auto card = ChoiceCard(c.glyph, c.title, c.blurb, first_run.source() == c.src,
                                   c.recommended);
            auto src = c.src;
            card.Click([this, src](auto &&, auto &&) {
                first_run.set_source(src);
                FirstRunRender(); // the pick shows in the borders
            });
            body.Children().Append(card);
        }
    }

    // Tell the core which cells this device already holds, so a cost leaves
    // them out and a download skips them. Without it a mariner picking a second
    // region fetches every cell of it again, including the ones they downloaded
    // last time, which is load on NOAA that the district bundles exist to
    // remove.
    //
    // By name, without the extension, which is the stem of each prepared chart.
    void MainWindow::FirstRunNoaaHave()
    {
        std::vector<std::string> names;
        std::error_code ec;
        std::filesystem::path root(BakeOutputDir());
        if (std::filesystem::is_directory(root, ec))
            for (auto it = std::filesystem::recursive_directory_iterator(root, ec);
                 !ec && it != std::filesystem::recursive_directory_iterator();
                 it.increment(ec))
            {
                if (!it->is_regular_file(ec))
                    continue;
                auto ext = it->path().extension().string();
                for (auto &c : ext)
                    c = (char)tolower((unsigned char)c);
                if (ext == ".pmtiles")
                    names.push_back(it->path().stem().string());
            }

        if (names.empty())
        {
            lk_controller_noaa_have(controller, nullptr, 0);
            return;
        }
        std::vector<char const *> cps;
        cps.reserve(names.size());
        for (auto const &n : names)
            cps.push_back(n.c_str());
        lk_controller_noaa_have(controller, cps.data(), cps.size());
    }

    // Price every region on its own.
    //
    // The pick as a whole is priced where it is stated, and that total is
    // what a download costs. These are one call each, answered off the
    // catalog the core already holds, and they are what the pills state: a
    // picker that priced only the pick said nothing about the water already
    // on the device.
    void MainWindow::FirstRunRepriceRegions()
    {
        noaa_region_hold.clear();
        if (controller == nullptr)
            return;
        lookout_noaa_region const *regions = nullptr;
        size_t const n = lk_controller_noaa_regions(&regions);
        if (n == 0 || regions == nullptr)
            return;
        for (size_t i = 0; i < n; ++i)
        {
            uint32_t cells = 0, held = 0;
            uint64_t bytes = 0, held_bytes = 0;
            if (!lk_controller_noaa_cost(controller, regions[i].id, &cells, &bytes,
                                         &held, &held_bytes))
                continue;
            noaa_region_hold.push_back({ regions[i].id, lkw::RegionHold{ cells, held } });
        }
    }

    // The coverage map, above the region list.
    //
    // The coastline is GSHHG, read once from data\\firstrun\\coastline.bin and
    // kept, because a step rebuild redraws this and the file is a quarter of a
    // megabyte. Land fills first, then lakes over it: a lake is its own ring
    // rather than a hole, so fill order is what makes it water.
    //
    // Each region draws as the boxes the catalog states for it, which is what a
    // download would fetch. One rectangle per region claims water it does not
    // cover: district 8 runs Texas to the Keys around the Florida peninsula,
    // and its bounding box paints across Miami.
    // One panel of the picker: the ground it covers, and the regions drawn on
    // it as the water they cover.
    //
    // A region is ONE path rather than a box per cell. Outlining every cell
    // draws a mesh over the coast; filled and unstroked, a region reads as one
    // piece of water, and overlapping cells do not stack their fill. The tap
    // goes on that path, so it lands on the region's own water rather than on
    // a rectangle around it.
    Border MainWindow::FirstRunCoveragePanel(lkw::MapWindow const &win,
                                             std::vector<std::string> const &ids, double width,
                                             double radius, bool enabled)
    {
        double const height = width / win.Aspect();

        Controls::Canvas canvas;
        canvas.Width(width);
        canvas.Height(height);

        // S-52 shallow blue and GSHHG land, so the picker sits in the app's
        // own palette. The same pair the reference uses.
        auto water = SolidColorBrush{ Windows::UI::Color{ 0x8C, 0xAD, 0xD6, 0xFF } };
        auto land = SolidColorBrush{ Windows::UI::Color{ 0x8C, 0xA3, 0x96, 0x54 } };

        Shapes::Rectangle back;
        back.Width(width);
        back.Height(height);
        back.Fill(water);
        canvas.Children().Append(back);

        auto add_rings = [&](uint8_t level, Media::Brush const &fill) {
            for (auto const &ring : coastline_)
            {
                if (ring.level != level || ring.points.size() < 3)
                    continue;
                double w = 180, e = -180, s = 90, nn = -90;
                for (auto const &p : ring.points)
                {
                    w = std::min(w, (double)p.lon);
                    e = std::max(e, (double)p.lon);
                    s = std::min(s, (double)p.lat);
                    nn = std::max(nn, (double)p.lat);
                }
                // A ring spanning more than 180 degrees crosses the
                // antimeridian: an Aleutian island with points at +172 and
                // -179 draws as a band across the whole panel.
                if (e - w > 180 || !win.Intersects(w, e, s, nn))
                    continue;
                Shapes::Polygon poly;
                Media::PointCollection pts;
                for (auto const &p : ring.points)
                {
                    double x = 0, y = 0;
                    win.Point(p.lon, p.lat, width, height, &x, &y);
                    pts.Append(Windows::Foundation::Point{ (float)x, (float)y });
                }
                poly.Points(pts);
                poly.Fill(fill);
                // A ring simplified to 0.02 degrees can cross itself, and
                // even-odd would drive a hole through the land there.
                poly.FillRule(Media::FillRule::Nonzero);
                canvas.Children().Append(poly);
            }
        };
        add_rings(1, land);
        add_rings(2, water); // a lake is water drawn back over the land

        lookout_noaa_region const *regions = nullptr;
        size_t const n = lk_controller_noaa_regions(&regions);
        for (size_t i = 0; i < n && regions != nullptr; ++i)
        {
            auto const &r = regions[i];
            std::string const rid = r.id;
            if (std::find(ids.begin(), ids.end(), rid) == ids.end())
                continue;
            bool const picked = lkw::RegionPicked(noaa_region_id, rid);

            // The catalog's boxes, or the region's rough extent until the
            // catalog is in. What downloads is the catalog's either way.
            std::vector<lookout_noaa_box> boxes;
            size_t const have = lk_controller_noaa_region_coverage(controller, r.id, nullptr, 0);
            if (have > 0)
            {
                boxes.resize(have);
                lk_controller_noaa_region_coverage(controller, r.id, boxes.data(), have);
            }
            else
            {
                boxes.push_back({ r.west, r.south, r.east, r.north });
            }

            // Non-zero, not the even-odd a geometry defaults to. A region's
            // cells overlap along their borders, and even-odd cancels the
            // overlap: it drew holes through the Mid-Atlantic where the
            // Chesapeake cells cross their neighbours. Every box below is
            // wound the same way, so non-zero fills their union.
            Media::PathGeometry geo;
            geo.FillRule(Media::FillRule::Nonzero);
            for (auto const &b : boxes)
            {
                if (!win.Intersects(b.west, b.east, b.south, b.north))
                    continue;
                double x0 = 0, y0 = 0, x1 = 0, y1 = 0;
                win.Point(b.west, b.north, width, height, &x0, &y0);
                win.Point(b.east, b.south, width, height, &x1, &y1);
                if (x1 <= x0 || y1 <= y0)
                    continue;
                Media::PathFigure fig;
                fig.StartPoint({ (float)x0, (float)y0 });
                fig.IsClosed(true);
                fig.IsFilled(true);
                auto corner = [&](double x, double y) {
                    Media::LineSegment seg;
                    seg.Point({ (float)x, (float)y });
                    fig.Segments().Append(seg);
                };
                corner(x1, y0);
                corner(x1, y1);
                corner(x0, y1);
                geo.Figures().Append(fig);
            }
            if (geo.Figures().Size() == 0)
                continue;

            auto c = AccentColor(g_dark);
            Shapes::Path shape;
            shape.Data(geo);
            shape.Fill(SolidColorBrush{
                Windows::UI::Color{ (uint8_t)(picked ? 0x80 : 0x29), c.R, c.G, c.B } });
            if (enabled)
                shape.Tapped([this, rid](auto &&, auto &&e) {
                    noaa_region_id = lkw::RegionToggle(noaa_region_id, rid);
                    e.Handled(true);
                    FirstRunRender(); // re-prices the pick and restates the map
                });
            Automation::AutomationProperties::SetName(
                shape, winrt::hstring{ std::wstring{ winrt::to_hstring(r.name) } + L". " +
                                       std::wstring{ winrt::to_hstring(r.blurb) } });
            canvas.Children().Append(shape);
        }

        Border frame;
        frame.CornerRadius({ radius, radius, radius, radius });
        frame.BorderThickness({ 1, 1, 1, 1 });
        frame.BorderBrush(HairlineBrush());
        frame.Child(canvas);
        return frame;
    }

    void MainWindow::FirstRunCoverageMap(Controls::StackPanel const &body)
    {
        if (coastline_.empty())
            coastline_ = lkw::LoadCoastline((FirstRunDataDir() / L"coastline.bin").string());
        if (coastline_.empty())
            return;

        lookout_noaa_state st{};
        lk_controller_noaa_poll(controller, &st);
        bool const enabled = st.have_catalog != 0;

        // The lower 48, with Alaska and Hawaii inset. One view cannot hold all
        // three: they span 128 degrees of longitude, and at that scale their
        // latitude span is taller than the card. An atlas prints them as
        // insets for the same reason.
        // west, east, south, north — the order the struct declares, not the
        // labelled order the reference writes them in.
        lkw::MapWindow const lower48{ -132.0, -64.0, 20.0, 52.0 };
        lkw::MapWindow const alaska{ -172.0, -128.0, 50.5, 72.0 };
        lkw::MapWindow const hawaii{ -161.0, -154.0, 18.3, 22.6 };
        constexpr double kMapW = 620.0;
        constexpr double kInsetW = 134.0;

        auto inset = [&](lkw::MapWindow const &win, std::vector<std::string> const &ids,
                         double width, wchar_t const *label) {
            // Its own frame, so each reads as itself rather than as something
            // floating off the coast of Oregon.
            StackPanel column;
            column.Spacing(2);
            auto title = Line(label, 9, false);
            title.Opacity(0.7);
            column.Children().Append(title);
            column.Children().Append(FirstRunCoveragePanel(win, ids, width, 5, enabled));
            return column;
        };

        StackPanel corners;
        corners.Orientation(Orientation::Horizontal);
        corners.Spacing(8);
        corners.Margin({ 8, 8, 8, 8 });
        corners.HorizontalAlignment(HorizontalAlignment::Left);
        corners.VerticalAlignment(VerticalAlignment::Bottom);
        corners.Children().Append(inset(alaska, { "d17" }, kInsetW, L"Alaska"));
        corners.Children().Append(inset(hawaii, { "d14" }, kInsetW * 0.54, L"Hawaii"));

        Controls::Grid map;
        map.HorizontalAlignment(HorizontalAlignment::Center);
        map.Children().Append(FirstRunCoveragePanel(
            lower48, { "d1", "d5", "d7", "d8", "d9", "d11", "d13" }, kMapW, 10, enabled));
        // In the Pacific, where they reach no coast.
        map.Children().Append(corners);
        Automation::AutomationProperties::SetName(map, L"Coverage map");
        body.Children().Append(map);
    }

    void MainWindow::FirstRunCoverage(Controls::StackPanel const &body)
    {
        body.Children().Append(
            Heading(L"Which waters do you sail?",
                    L"Pick the water you use. Lookout downloads those charts and prepares them. "
                    L"You can add the rest later."));

        lookout_noaa_region const *regions = nullptr;
        size_t const n = lk_controller_noaa_regions(&regions);
        if (n == 0 || regions == nullptr)
        {
            body.Children().Append(Muted(L"The region list is not available."));
            return;
        }

        // Before any price: the cost call leaves out what this device holds.
        FirstRunNoaaHave();

        lookout_noaa_state st{};
        lk_controller_noaa_poll(controller, &st);

        // Ask for the catalog here rather than trusting whoever opened the
        // chart to have asked. This step is reached from a launch with no
        // charts, from removing the last set and from the Charts pane, and a
        // read that failed leaves nothing to price. The core runs one read at
        // a time; the flag is what keeps a failed read from being asked for
        // again on every render.
        if (!st.have_catalog && st.phase != 1 && !noaa_catalog_asked)
        {
            noaa_catalog_asked = true;
            lk_controller_noaa_refresh(controller);
            lk_controller_noaa_poll(controller, &st);
        }
        if (st.have_catalog)
            noaa_catalog_asked = false; // a later failure may ask again
        // What this build drew from, so the poll renders again only when the
        // catalog moves.
        noaa_catalog_drawn = NoaaCatalogSignature();

        // What of each region is already here, before anything draws from
        // it. The pills state it, and a picker opened from the Charts pane
        // opens ticked on the water the mariner holds: opening it with
        // nothing ticked said they held none.
        FirstRunRepriceRegions();
        if (st.have_catalog && first_run.picker_only() && !noaa_picked_seeded)
        {
            noaa_picked_seeded = true;
            std::string const here = lkw::PickedFromHeld(noaa_region_hold);
            if (!here.empty())
                noaa_region_id = here;
        }

        FirstRunCoverageMap(body);

        // Where the catalog stands. The price comes from it, so a region can
        // be picked before it lands but not priced.
        if (st.phase == 1)
        {
            StackPanel reading;
            reading.Orientation(Orientation::Horizontal);
            reading.Spacing(8);
            ProgressRing ring;
            ring.IsActive(true);
            ring.Width(14);
            ring.Height(14);
            reading.Children().Append(ring);
            auto says = Muted(L"Reading NOAA's chart catalog…");
            says.VerticalAlignment(VerticalAlignment::Center);
            reading.Children().Append(says);
            body.Children().Append(reading);
        }
        else if (st.error[0] != '\0')
        {
            StackPanel failed;
            failed.Orientation(Orientation::Horizontal);
            failed.Spacing(10);
            auto why = Muted(winrt::to_hstring(st.error).c_str());
            why.VerticalAlignment(VerticalAlignment::Center);
            failed.Children().Append(why);
            Button again;
            again.Content(box_value(L"Try Again"));
            again.Click([this](auto &&, auto &&) {
                noaa_catalog_asked = true;
                lk_controller_noaa_refresh(controller);
                FirstRunRender();
            });
            failed.Children().Append(again);
            body.Children().Append(failed);
        }
        else if (st.have_catalog)
        {
            std::wstring says = Thousands(st.catalog_cells) + L" charts published";
            if (st.date[0] != '\0')
                says += L", catalog dated " + std::wstring{ winrt::to_hstring(st.date) };
            body.Children().Append(Muted(says + L".", 12));
        }

        // The districts as pills, wrapped into rows. The mariner picks as many
        // as they sail.
        {
            // The card is 720 points wide with a 24 point inset each side, and
            // the scrollbar overlays the right edge.
            constexpr double kRoom = 656;
            constexpr double kGap = 8;
            StackPanel rows;
            rows.Spacing(kGap);
            StackPanel row;
            row.Orientation(Orientation::Horizontal);
            row.Spacing(kGap);
            double used = 0;
            // What of each region is here, by the core's id.
            auto hold_of = [this](std::string const &id) {
                for (auto const &one : noaa_region_hold)
                    if (one.first == id)
                        return one.second;
                return lkw::RegionHold{};
            };
            for (size_t i = 0; i < n; ++i)
            {
                auto const &r = regions[i];
                bool const picked = lkw::RegionPicked(noaa_region_id, r.id);
                std::wstring name{ winrt::to_hstring(r.name) };
                lkw::RegionHold const hold = hold_of(r.id);
                std::wstring const badge = lkw::RegionBadge(hold);
                double const wide = RegionPillWidth(name, badge, picked);
                if (used > 0 && used + kGap + wide > kRoom)
                {
                    rows.Children().Append(row);
                    row = StackPanel{};
                    row.Orientation(Orientation::Horizontal);
                    row.Spacing(kGap);
                    used = 0;
                }
                auto pill = RegionPill(name, winrt::to_hstring(r.blurb).c_str(), hold,
                                       picked, st.have_catalog);
                std::string const rid = r.id;
                pill.Click([this, rid](auto &&, auto &&) {
                    noaa_region_id = lkw::RegionToggle(noaa_region_id, rid);
                    FirstRunRender(); // re-prices the pick
                });
                row.Children().Append(pill);
                used += (used > 0 ? kGap : 0) + wide;
            }
            if (row.Children().Size() > 0)
                rows.Children().Append(row);
            body.Children().Append(rows);
        }
    }

    void MainWindow::FirstRunOnline(Controls::StackPanel const &body)
    {
        body.Children().Append(
            Heading(L"Choose an online chart",
                    L"An online chart renders straight away, worldwide, and stores nothing. One "
                    L"shows at a time, and while it is on it is the chart."));
        // The reference's shelf of charts belongs here. Until it is built,
        // the link field stands alone under the same two lines it has there.
        body.Children().Append(Line(L"Another link", 13, true));

        TextBox box;
        box.PlaceholderText(L"https://…/style.json");
        box.Text(winrt::to_hstring(chart_link_url));
        box.TextChanged([this, box](auto &&, auto &&) {
            chart_link_url = winrt::to_string(box.Text());
            // The button reads Skip until there is a chart to continue with.
            FirstRunPrimaryBtn().Content(
                box_value(first_run.PrimaryTitle(!chart_link_url.empty())));
        });
        body.Children().Append(box);
        body.Children().Append(Muted(L"MapLibre style or TileJSON link", 11.5));
    }

    void MainWindow::FirstRunImporting(Controls::StackPanel const &body)
    {
        body.Children().Append(
            Heading(L"Preparing your charts",
                    L"A cell holds survey data, not a drawn chart, so Lookout converts each one "
                    L"on the way in. This happens once per set."));

        auto const &order = first_run.order();
        if (order.has_value())
        {
            body.Children().Append(Line(order->regions, 14, true));
            body.Children().Append(Muted(L"NOAA · " + Thousands(order->charts) +
                                         L" charts · " + SizeText(order->bytes)));
        }

        auto const &shown = first_run.shown();

        // One bar for the whole job. A bar per phase reads as three jobs.
        ProgressBar bar;
        bar.HorizontalAlignment(HorizontalAlignment::Stretch);
        body.Children().Append(bar);
        // How far it has got is restated, not rebuilt: a fresh bar starts its
        // sweep over, which on a step polled four times a second reads as a
        // bar that never advances.
        first_run_bar = bar;

        // Two columns. The phases on the left and the bands beside them. A
        // desktop window has the width for both, and the reference puts them
        // side by side.
        Grid columns;
        ColumnDefinition left, right;
        left.Width({ 330, GridUnitType::Pixel });
        right.Width({ 1, GridUnitType::Star });
        columns.ColumnDefinitions().Append(left);
        columns.ColumnDefinitions().Append(right);
        columns.ColumnSpacing(26);

        StackPanel phases;
        phases.Spacing(8);
        Grid::SetColumn(phases, 0);
        columns.Children().Append(phases);

        uint32_t const want = first_run.expected();
        FirstRunPhase(phases, L"Downloading charts",
                      want > 0 ? Thousands(shown.fetched) + L" of " + Thousands(want)
                               : std::wstring{},
                      shown.downloading, order.has_value() && !shown.downloading);
        FirstRunPhase(phases, L"Finding charts",
                      shown.found > 0 ? Thousands(shown.found) + L" found" : std::wstring{},
                      shown.baking && shown.found == 0, shown.found > 0);
        FirstRunPhase(phases, L"Importing charts",
                      shown.found > 0
                          ? Thousands(shown.baked) + L" of " + Thousands(shown.found)
                          : std::wstring{},
                      shown.baking, first_run.saw_bake() && !shown.baking);

        phases.Children().Append(
            Muted(L"Lookout stores the prepared charts in its own folder and never writes to "
                  L"your download."));

        if (shown.downloading || shown.baking)
        {
            Button stop;
            stop.Content(box_value(L"Stop"));
            stop.HorizontalAlignment(HorizontalAlignment::Left);
            stop.Click([this](auto &&, auto &&) {
                lk_controller_noaa_cancel(controller);
                if (bake_job)
                    bake_job->Cancel();
                FirstRunRender();
            });
            phases.Children().Append(stop);
        }

        // The bands, coarse first. That is the order the bake runs.
        StackPanel bands;
        bands.Spacing(8);
        bands.Children().Append(Line(L"By band", 14, true));
        bands.Children().Append(
            Muted(L"Wide-area charts are prepared first, so stopping partway still leaves "
                  L"charts that cover the whole passage.",
                  12));
        if (shown.bands.empty())
        {
            bands.Children().Append(Muted(L"Counted once the folder has been read.", 12));
        }
        else
        {
            for (auto const &b : shown.bands)
            {
                Grid row;
                ColumnDefinition c0, c1, c2;
                c0.Width({ 104, GridUnitType::Pixel });
                c1.Width({ 1, GridUnitType::Star });
                c2.Width({ 0, GridUnitType::Auto });
                row.ColumnDefinitions().Append(c0);
                row.ColumnDefinitions().Append(c1);
                row.ColumnDefinitions().Append(c2);

                auto name = Muted(b.name, 12.5);
                row.Children().Append(name);

                // The count moves as the bake runs and the tick arrives when
                // the band is done, so both are restated rather than rebuilt.
                auto count = Muted(std::wstring{}, 12.5);
                Grid::SetColumn(count, 1);
                row.Children().Append(count);

                FontIcon tick;
                tick.Glyph(L""); /* check */
                tick.FontSize(13);
                tick.Foreground(AccentBrush());
                Grid::SetColumn(tick, 2);
                row.Children().Append(tick);

                bands.Children().Append(row);
                first_run_band_ui.push_back({ count, tick });
            }
        }

        Border panel;
        panel.CornerRadius({ 10, 10, 10, 10 });
        panel.Padding({ 12, 12, 12, 12 });
        panel.BorderThickness({ 1, 1, 1, 1 });
        panel.BorderBrush(HairlineBrush());
        panel.Child(bands);
        panel.VerticalAlignment(VerticalAlignment::Top);
        Grid::SetColumn(panel, 1);
        columns.Children().Append(panel);
        body.Children().Append(columns);
        // The shape just built, for the poll to compare against.
        first_run_importing_shape = FirstRunImportingShape();
    }

    // One phase of the job: what it is, how far it got, and whether it ended.
    // The shape of the Preparing step: how many bands it lists, and whether
    // it holds a Stop button and an order line. Everything else on it is a
    // value.
    std::string MainWindow::FirstRunImportingShape()
    {
        auto const &shown = first_run.shown();
        std::string s = std::to_string(shown.bands.size());
        for (auto const &b : shown.bands)
            s += "|" + winrt::to_string(b.name);
        s += (shown.downloading || shown.baking) ? "|stop" : "|done";
        s += first_run.order().has_value() ? "|order" : "|none";
        return s;
    }

    // What the step on screen says now, and whether its action can be taken.
    void MainWindow::FirstRunRestate()
    {
        // Whether the primary action has anything to do. The model decides;
        // the shell answers the three questions it cannot see.
        bool const have_catalog = [&] {
            lookout_noaa_state st{};
            lk_controller_noaa_poll(controller, &st);
            return st.have_catalog != 0;
        }();
        bool const chart_ready = lk_controller_is_open(controller) && chart_has_cells;
        FirstRunPrimaryBtn().IsEnabled(first_run.PrimaryEnabled(
            have_catalog, !noaa_region_id.empty(), chart_ready));

        // Water the device already holds is fetched again rather than left
        // with a dead button: that is how a mariner repairs a set, or gets the
        // edition NOAA has reissued.
        if (first_run.step() == lkw::FirstRunStep::Coverage)
            FirstRunPrimaryBtn().Content(
                box_value(NoaaAllHeld() ? L"Download Again" : L"Download"));

        // The line beside the action. The coverage step prices the pick
        // here, the way the reference does: at the end of the step the
        // footer bar covered it.
        {
            lkw::FirstRun::Footnotes f;
            f.have_catalog = have_catalog;
            f.have_charts = chart_has_cells;
            f.credit = std::wstring{ ScaleBarCredit().Text() };
            if (first_run.step() == lkw::FirstRunStep::Coverage && !noaa_region_id.empty())
                lk_controller_noaa_cost(controller, noaa_region_id.c_str(), &f.cells,
                                        &f.bytes, &f.held, &f.held_bytes);
            std::wstring const note = first_run.Footnote(f);
            FirstRunFootnote().Text(winrt::hstring{ note });
            FirstRunFootnote().Visibility(note.empty() ? Visibility::Collapsed
                                                       : Visibility::Visible);
        }

        if (first_run.step() != lkw::FirstRunStep::Importing)
            return;

        auto const &shown = first_run.shown();
        if (first_run_bar != nullptr)
        {
            double const f = first_run.Fraction();
            // Only when it changes. Writing IsIndeterminate restarts the
            // sweep, which is the flicker this step had.
            bool const want_sweep = f <= 0.0;
            if (first_run_bar.IsIndeterminate() != want_sweep)
                first_run_bar.IsIndeterminate(want_sweep);
            if (!want_sweep)
            {
                first_run_bar.Minimum(0);
                first_run_bar.Maximum(1);
                first_run_bar.Value(f);
            }
        }

        // The three phases, in the order they were built.
        struct PhaseNow
        {
            std::wstring detail;
            bool running;
            bool done;
        };
        uint32_t const want = first_run.expected();
        std::vector<PhaseNow> now;
        now.push_back({ want > 0 ? Thousands(shown.fetched) + L" of " + Thousands(want)
                                 : std::wstring{},
                        shown.downloading,
                        first_run.order().has_value() && !shown.downloading });
        now.push_back({ shown.found > 0 ? Thousands(shown.found) + L" found" : std::wstring{},
                        shown.baking && shown.found == 0, shown.found > 0 });
        now.push_back({ shown.found > 0 ? Thousands(shown.baked) + L" of " + Thousands(shown.found)
                                        : std::wstring{},
                        shown.baking, first_run.saw_bake() && !shown.baking });
        for (size_t i = 0; i < first_run_phase_ui.size() && i < now.size(); ++i)
        {
            auto const &ui = first_run_phase_ui[i];
            auto const &p = now[i];
            ui.detail.Text(winrt::hstring{ p.detail });
            ui.tick.Visibility(p.done ? Visibility::Visible : Visibility::Collapsed);
            ui.ring.Visibility(p.running && !p.done ? Visibility::Visible
                                                    : Visibility::Collapsed);
            // A phase not yet reached is muted. The one running and the ones
            // done read at full strength.
            ui.name.Opacity(!p.running && !p.done ? 0.7 : 1.0);
            ui.name.FontWeight(p.running ? Windows::UI::Text::FontWeights::SemiBold()
                                         : Windows::UI::Text::FontWeights::Normal());
        }

        for (size_t i = 0; i < first_run_band_ui.size() && i < shown.bands.size(); ++i)
        {
            auto const &b = shown.bands[i];
            first_run_band_ui[i].count.Text(
                winrt::hstring{ b.complete() ? Thousands(b.total) + L" charts"
                                             : Thousands(b.done) + L" of " +
                                                   Thousands(b.total) });
            first_run_band_ui[i].tick.Visibility(b.complete() ? Visibility::Visible
                                                              : Visibility::Collapsed);
        }
    }

    void MainWindow::FirstRunPhase(Controls::StackPanel const &body, std::wstring const &name,
                                   std::wstring const &detail, bool running, bool done)
    {
        Grid row;
        ColumnDefinition c0, c1, c2;
        c0.Width({ 22, GridUnitType::Pixel });
        c1.Width({ 1, GridUnitType::Star });
        c2.Width({ 0, GridUnitType::Auto });
        row.ColumnDefinitions().Append(c0);
        row.ColumnDefinitions().Append(c1);
        row.ColumnDefinitions().Append(c2);

        // Both marks are built and one is shown. This row is restated four
        // times a second, and making the mark by building the row again
        // restarted the ring's sweep on every tick. What it says and which
        // mark it wears is FirstRunRestate's.
        FontIcon tick;
        tick.Glyph(L""); /* check */
        tick.FontSize(14);
        tick.Foreground(AccentBrush());
        tick.HorizontalAlignment(HorizontalAlignment::Left);
        row.Children().Append(tick);

        ProgressRing ring;
        ring.Width(14);
        ring.Height(14);
        ring.IsActive(true);
        ring.HorizontalAlignment(HorizontalAlignment::Left);
        row.Children().Append(ring);

        auto label = Line(name, 13.5, running);
        Grid::SetColumn(label, 1);
        row.Children().Append(label);

        auto tail = Muted(detail, 12.5);
        Grid::SetColumn(tail, 2);
        row.Children().Append(tail);

        body.Children().Append(row);
        first_run_phase_ui.push_back({ label, tail, tick, ring });
    }

    // The depth step: two questions about the boat, the four numbers they come
    // to, and a picture of the water they shade.
    void MainWindow::FirstRunDepths(Controls::StackPanel const &body)
    {
        // Feet to start with, the unit most of the boats this is for measure
        // in. The mariner's own answer stands for the rest of the session and
        // goes to the store with the numbers.
        if (!depth_seeded)
        {
            depth_seeded = true;
            depth_choice = lkw::DepthChoice{ true };
        }
        depth_pills.clear();
        depth_units.clear();
        depth_rows.clear();
        depth_key.clear();
        depth_draft = nullptr;
        depth_badge = nullptr;
        depth_seabed = nullptr;

        body.Children().Append(
            Heading(L"How deep does your boat sit?",
                    L"Lookout shades water your boat cannot cross. It needs one number to do "
                    L"that, and everything else follows from it."));

        // The boat on the left, the water it makes on the right.
        Grid columns;
        ColumnDefinition left, right;
        left.Width({ 334, GridUnitType::Pixel });
        right.Width({ 1, GridUnitType::Star });
        columns.ColumnDefinitions().Append(left);
        columns.ColumnDefinitions().Append(right);
        columns.ColumnSpacing(26);
        columns.Margin({ 0, 10, 0, 0 });

        StackPanel boat;
        Grid::SetColumn(boat, 0);
        columns.Children().Append(boat);

        // ---- the draft ----------------------------------------------------
        {
            Grid row;
            ColumnDefinition c0, c1;
            c0.Width({ 62, GridUnitType::Pixel });
            c1.Width({ 1, GridUnitType::Star });
            row.ColumnDefinitions().Append(c0);
            row.ColumnDefinitions().Append(c1);
            row.Margin({ 0, 0, 0, 9 });

            auto label = Line(L"Draft", 14, true);
            label.VerticalAlignment(VerticalAlignment::Center);
            row.Children().Append(label);

            // The number, the unit, and a pair of steppers. The field commits
            // on Enter and on losing focus: a commit per keystroke would
            // renumber the water under the mariner's hands.
            Grid field;
            ColumnDefinition f0, f1, f2;
            f0.Width({ 1, GridUnitType::Star });
            f1.Width({ 0, GridUnitType::Auto });
            f2.Width({ 0, GridUnitType::Auto });
            field.ColumnDefinitions().Append(f0);
            field.ColumnDefinitions().Append(f1);
            field.ColumnDefinitions().Append(f2);
            field.Height(44);

            depth_draft = TextBox{};
            depth_draft.Text(winrt::hstring{ depth_choice.DraftText() });
            depth_draft.FontSize(22);
            depth_draft.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            depth_draft.TextAlignment(TextAlignment::Right);
            depth_draft.BorderThickness({ 0, 0, 0, 0 });
            depth_draft.Background(SolidColorBrush{ Windows::UI::Colors::Transparent() });
            depth_draft.VerticalAlignment(VerticalAlignment::Center);
            auto commit = [this] {
                // Text that is not a depth leaves the draft alone. The field
                // is written back either way, so it reads what the step uses.
                (void)depth_choice.ReadDraft(std::wstring{ depth_draft.Text() });
                depth_draft.Text(winrt::hstring{ depth_choice.DraftText() });
                FirstRunDepthsApply();
                FirstRunDepthsRestate();
            };
            depth_draft.KeyDown([commit](auto &&, auto &&e) {
                if (e.Key() == Windows::System::VirtualKey::Enter)
                    commit();
            });
            depth_draft.LostFocus([commit](auto &&, auto &&) { commit(); });
            field.Children().Append(depth_draft);

            auto unit_label = Muted(depth_choice.unit(), 15);
            unit_label.VerticalAlignment(VerticalAlignment::Center);
            unit_label.Margin({ 8, 0, 8, 0 });
            Grid::SetColumn(unit_label, 1);
            field.Children().Append(unit_label);

            StackPanel steppers;
            steppers.Margin({ 0, 0, 8, 0 });
            steppers.VerticalAlignment(VerticalAlignment::Center);
            auto stepper = [this](wchar_t const *glyph, int by) {
                FontIcon mark;
                mark.Glyph(glyph);
                mark.FontSize(9);
                Button b;
                b.Content(mark);
                b.Padding({ 6, 1, 6, 1 });
                b.MinWidth(0);
                b.Click([this, by](auto &&, auto &&) {
                    depth_choice.Step(by);
                    depth_draft.Text(winrt::hstring{ depth_choice.DraftText() });
                    FirstRunDepthsApply();
                    FirstRunDepthsRestate();
                });
                return b;
            };
            steppers.Children().Append(stepper(L"", 1));   // ChevronUp
            steppers.Children().Append(stepper(L"", -1));  // ChevronDown
            Grid::SetColumn(steppers, 2);
            field.Children().Append(steppers);

            Border frame;
            frame.CornerRadius({ 9, 9, 9, 9 });
            frame.BorderThickness({ 1.5, 1.5, 1.5, 1.5 });
            frame.BorderBrush(AccentBrush());
            frame.Child(field);
            Grid::SetColumn(frame, 1);
            row.Children().Append(frame);
            boat.Children().Append(row);
        }

        // ---- the unit -----------------------------------------------------
        {
            Grid row;
            ColumnDefinition c0, c1;
            c0.Width({ 62, GridUnitType::Pixel });
            c1.Width({ 1, GridUnitType::Star });
            row.ColumnDefinitions().Append(c0);
            row.ColumnDefinitions().Append(c1);
            row.Margin({ 0, 0, 0, 8 });

            auto label = Muted(L"Units", 13);
            label.VerticalAlignment(VerticalAlignment::Center);
            row.Children().Append(label);

            StackPanel pair;
            pair.Orientation(Orientation::Horizontal);
            pair.Spacing(6);
            pair.HorizontalAlignment(HorizontalAlignment::Left);
            auto unit_button = [this](wchar_t const *name, bool feet) {
                Button b;
                b.Content(box_value(winrt::hstring{ name }));
                b.MinWidth(56);
                b.Padding({ 12, 4, 12, 4 });
                b.CornerRadius({ 7, 7, 7, 7 });
                b.Click([this, feet](auto &&, auto &&) {
                    if (depth_choice.feet() == feet)
                        return;
                    depth_choice.SetUnit(feet);
                    // The unit is the mariner's, and the chart reads it too.
                    tile57_mariner m{};
                    lk_controller_get_mariner(controller, &m);
                    m.depth_unit = feet ? (tile57_depth_unit)1 : (tile57_depth_unit)0;
                    lk_controller_set_mariner(controller, &m);
                    // Every label on the step carries the unit, so this one
                    // change is a rebuild.
                    FirstRunDepthsApply();
                    FirstRunRender();
                });
                depth_units.push_back(b);
                return b;
            };
            pair.Children().Append(unit_button(L"Meters", false));
            pair.Children().Append(unit_button(L"Feet", true));
            Grid::SetColumn(pair, 1);
            row.Children().Append(pair);
            boat.Children().Append(row);
        }

        auto caption = [](std::wstring const &text) {
            auto t = Muted(text, 11.5);
            return t;
        };
        {
            auto c = caption(L"Deepest point of the hull below the waterline, keel included.");
            c.Margin({ 0, 0, 0, 18 });
            boat.Children().Append(c);
        }

        // ---- the clearance ------------------------------------------------
        {
            auto head = Line(L"Clearance under the keel", 13, true);
            head.Margin({ 0, 0, 0, 9 });
            boat.Children().Append(head);

            StackPanel pills;
            pills.Orientation(Orientation::Horizontal);
            pills.Spacing(8);
            for (double c : depth_choice.Clearances())
            {
                Button b;
                b.Content(box_value(winrt::hstring{ depth_choice.Measure(c) }));
                b.Height(34);
                b.MinWidth(0);
                b.Padding({ 15, 0, 15, 0 });
                b.CornerRadius({ 17, 17, 17, 17 });
                b.Click([this, c](auto &&, auto &&) {
                    depth_choice.set_clearance(c);
                    FirstRunDepthsApply();
                    FirstRunDepthsRestate();
                });
                depth_pills.push_back(b);
                pills.Children().Append(b);
            }
            boat.Children().Append(pills);

            auto c = caption(L"How much water you want left under the keel at the shallowest "
                             L"point of a passage.");
            c.Margin({ 0, 9, 0, 0 });
            boat.Children().Append(c);
        }

        // ---- what the answers come to -------------------------------------
        {
            StackPanel derived;
            derived.Margin({ 0, 16, 0, 0 });
            wchar_t const *names[] = { L"Safety depth", L"Safety contour", L"Deep contour" };
            for (auto const *name : names)
            {
                Border rule;
                rule.Height(1);
                rule.Background(HairlineBrush());
                derived.Children().Append(rule);

                Grid row;
                ColumnDefinition c0, c1;
                c0.Width({ 1, GridUnitType::Star });
                c1.Width({ 0, GridUnitType::Auto });
                row.ColumnDefinitions().Append(c0);
                row.ColumnDefinitions().Append(c1);
                row.Margin({ 0, 11, 0, 0 });
                auto label = Muted(name, 13);
                row.Children().Append(label);
                auto value = Line(std::wstring{}, 14, true);
                Grid::SetColumn(value, 1);
                row.Children().Append(value);

                StackPanel cell;
                cell.Spacing(5);
                cell.Margin({ 0, 0, 0, 11 });
                cell.Children().Append(row);
                auto blurb = caption(std::wstring{});
                cell.Children().Append(blurb);
                derived.Children().Append(cell);
                depth_rows.push_back({ value, blurb });
            }
            boat.Children().Append(derived);
        }

        // ---- the water ----------------------------------------------------
        {
            StackPanel water;
            Grid::SetColumn(water, 1);
            water.VerticalAlignment(VerticalAlignment::Top);

            Grid panel;
            depth_seabed = Controls::Canvas{};
            depth_seabed.Width(kSeabedW);
            depth_seabed.Height(kSeabedH);
            panel.Children().Append(depth_seabed);

            depth_badge = Line(std::wstring{}, 11.5, true);
            Border badge;
            badge.Child(depth_badge);
            badge.CornerRadius({ 6, 6, 6, 6 });
            badge.Padding({ 10, 3, 10, 3 });
            badge.Margin({ 12, 12, 12, 12 });
            badge.HorizontalAlignment(HorizontalAlignment::Left);
            badge.VerticalAlignment(VerticalAlignment::Top);
            badge.Background(SolidColorBrush{ g_dark
                                                  ? Windows::UI::Color{ 0xEB, 0x20, 0x24, 0x28 }
                                                  : Windows::UI::Color{ 0xEB, 0xF8, 0xF8, 0xF8 } });
            panel.Children().Append(badge);
            water.Children().Append(panel);

            Border rule;
            rule.Height(1);
            rule.Background(HairlineBrush());
            water.Children().Append(rule);

            // The four shades, with the water each one covers.
            Grid keys;
            wchar_t const *names[] = { L"Unsafe", L"Shallow", L"Medium", L"Deep" };
            wchar_t const *tokens[] = { L"DEPVS", L"DEPMS", L"DEPMD", L"DEPDW" };
            for (int i = 0; i < 4; ++i)
            {
                ColumnDefinition c;
                c.Width({ 1, GridUnitType::Star });
                keys.ColumnDefinitions().Append(c);

                StackPanel cell;
                cell.Spacing(6);
                cell.Padding({ 8, 11, 8, 11 });

                StackPanel top;
                top.Orientation(Orientation::Horizontal);
                top.Spacing(7);
                Border swatch;
                swatch.Width(11);
                swatch.Height(11);
                swatch.CornerRadius({ 3, 3, 3, 3 });
                swatch.Background(SolidColorBrush{ S52Color(tokens[i], SchemeOf(controller)) });
                swatch.BorderThickness({ 1, 1, 1, 1 });
                swatch.BorderBrush(HairlineBrush());
                swatch.VerticalAlignment(VerticalAlignment::Center);
                top.Children().Append(swatch);
                top.Children().Append(Line(names[i], 12, true));
                cell.Children().Append(top);

                auto range = Muted(std::wstring{}, 11.5);
                range.TextWrapping(TextWrapping::NoWrap);
                cell.Children().Append(range);
                depth_key.push_back(range);

                Grid::SetColumn(cell, i);
                keys.Children().Append(cell);
            }
            water.Children().Append(keys);

            Border round;
            round.CornerRadius({ 12, 12, 12, 12 });
            round.BorderThickness({ 1, 1, 1, 1 });
            round.BorderBrush(HairlineBrush());
            round.Child(water);
            // As tall as the water it holds. Stretched, it ran the length of
            // the questions beside it and left an empty panel under the key.
            round.VerticalAlignment(VerticalAlignment::Top);
            Grid::SetColumn(round, 1);
            columns.Children().Append(round);
        }

        body.Children().Append(columns);

        // ---- the warning --------------------------------------------------
        {
            StackPanel row;
            row.Orientation(Orientation::Horizontal);
            row.Spacing(10);
            FontIcon mark;
            mark.Glyph(L""); // Warning
            mark.FontSize(13);
            mark.Foreground(SolidColorBrush{ Windows::UI::Color{ 0xFF, 0xF5, 0x9E, 0x0B } });
            mark.VerticalAlignment(VerticalAlignment::Top);
            row.Children().Append(mark);

            TextBlock says;
            says.FontSize(12);
            says.TextWrapping(TextWrapping::Wrap);
            Run bold;
            bold.Text(L"Shading is not a depth sounder. ");
            bold.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            says.Inlines().Append(bold);
            Run rest;
            rest.Text(L"Soundings are not corrected for tide, surge or squat, and a survey can "
                      L"be decades old. Keep your own margin.");
            says.Inlines().Append(rest);
            says.Opacity(0.85);
            row.Children().Append(says);

            Border panel;
            panel.CornerRadius({ 9, 9, 9, 9 });
            panel.Padding({ 14, 12, 14, 12 });
            panel.Margin({ 0, 18, 0, 0 });
            panel.Background(SolidColorBrush{ Windows::UI::Color{ 0x1A, 0xF5, 0x9E, 0x0B } });
            panel.Child(row);
            body.Children().Append(panel);
        }

        FirstRunDepthsApply();
        FirstRunDepthsRestate();
    }

    // The four numbers the engine draws with. The shallow contour follows the
    // safety depth, which makes the first shade the water the boat cannot
    // cross.
    void MainWindow::FirstRunDepthsApply()
    {
        if (controller == nullptr)
            return;
        tile57_mariner m{};
        lk_controller_get_mariner(controller, &m);
        m.safety_depth = depth_choice.Metres(depth_choice.SafetyDepth());
        m.shallow_contour = depth_choice.Metres(depth_choice.SafetyDepth());
        m.safety_contour = depth_choice.Metres(depth_choice.SafetyContour());
        m.deep_contour = depth_choice.Metres(depth_choice.DeepContour());
        m.four_shade_water = true;
        // The unit the step is answered in is the unit the readouts use.
        m.depth_unit = depth_choice.feet() ? (tile57_depth_unit)1 : (tile57_depth_unit)0;
        lk_controller_set_mariner(controller, &m);
    }

    void MainWindow::FirstRunDepthsRestate()
    {
        auto const &d = depth_choice;
        std::wstring const depth = d.Measure(d.SafetyDepth());
        std::wstring const safety = d.Measure(d.SafetyContour());
        std::wstring const deep = d.Measure(d.DeepContour());

        if (depth_rows.size() == 3)
        {
            depth_rows[0].value.Text(winrt::hstring{ depth });
            depth_rows[0].blurb.Text(L"Soundings at or shallower than this print bold. It does "
                                     L"not shade water.");
            depth_rows[1].value.Text(winrt::hstring{ safety });
            depth_rows[1].blurb.Text(
                winrt::hstring{ L"Water shallower than this shades as unsafe. Rounded up to a "
                                L"contour the survey draws, so " +
                                depth + L" reads as " + safety + L"." });
            depth_rows[2].value.Text(winrt::hstring{ deep });
            depth_rows[2].blurb.Text(L"Water deeper than this draws in the lightest shade. Twice "
                                     L"the safety contour, up the same ladder the safety contour "
                                     L"came off.");
        }
        if (depth_badge != nullptr)
            depth_badge.Text(winrt::hstring{ L"Your water at " + depth });
        if (depth_key.size() == 4)
        {
            depth_key[0].Text(winrt::hstring{ L"0 – " + depth });
            depth_key[1].Text(winrt::hstring{ depth + L" – " + safety });
            depth_key[2].Text(winrt::hstring{ safety + L" – " + deep });
            depth_key[3].Text(winrt::hstring{ deep + L" +" });
        }

        // The pills and the unit pair wear the pick.
        auto const clearances = d.Clearances();
        for (size_t i = 0; i < depth_pills.size() && i < clearances.size(); ++i)
            PaintPicked(depth_pills[i], clearances[i] == d.clearance());
        for (size_t i = 0; i < depth_units.size(); ++i)
            PaintPicked(depth_units[i], (i == 1) == d.feet());

        FirstRunDrawSeabed();
    }

    // The seabed: a slope from a shore to deep water, shaded at the derived
    // contours, with spot depths on it.
    //
    // The soundings are the seabed and hold still; the shading is the
    // mariner's and moves over them. Their depths are read off this slope, so
    // they change only when the contour steps to the next one the survey
    // draws. A chart behaves the same way when a boat changes.
    void MainWindow::FirstRunDrawSeabed()
    {
        if (depth_seabed == nullptr)
            return;
        depth_seabed.Children().Clear();
        auto const &d = depth_choice;
        uint32_t const scheme = SchemeOf(controller);
        auto shade = [scheme](wchar_t const *token) {
            return SolidColorBrush{ S52Color(token, scheme) };
        };
        auto ink = [](uint8_t alpha) {
            return SolidColorBrush{ Windows::UI::Color{ alpha, 0, 0, 0 } };
        };

        Shapes::Rectangle back;
        back.Width(kSeabedW);
        back.Height(kSeabedH);
        back.Fill(shade(L"DEPDW"));
        depth_seabed.Children().Append(back);

        // Every line is the same shape, moved up by its depth, so each band
        // keeps its share of the panel from edge to edge.
        auto shoal = [](double t) {
            Media::PathFigure fig;
            fig.StartPoint({ 0, (float)kSeabedH });
            fig.IsClosed(true);
            fig.IsFilled(true);
            auto step = [&fig](Windows::Foundation::Point const &p) {
                Media::LineSegment seg;
                seg.Point(p);
                fig.Segments().Append(seg);
            };
            constexpr int kSteps = 48;
            for (int i = 0; i <= kSteps; ++i)
                step(SeabedPoint(t, (double)i / kSteps));
            step({ (float)kSeabedW, (float)kSeabedH });
            Media::PathGeometry geo;
            geo.FillRule(Media::FillRule::Nonzero);
            geo.Figures().Append(fig);
            Shapes::Path p;
            p.Data(geo);
            return p;
        };

        constexpr double kShoreAt = 0.14;
        auto fill = [&](double t, wchar_t const *token) {
            auto p = shoal(t);
            p.Fill(shade(token));
            depth_seabed.Children().Append(p);
        };
        fill(d.Reach(d.DeepContour()), L"DEPMD");
        fill(d.Reach(d.SafetyContour()), L"DEPMS");
        fill(d.Reach(d.SafetyDepth()), L"DEPVS");

        // The safety contour drawn bold, the way S-52 draws the contour a boat
        // is measured against.
        auto line = [&](double t, uint8_t alpha, double thick) {
            auto p = shoal(t);
            p.Stroke(ink(alpha));
            p.StrokeThickness(thick);
            depth_seabed.Children().Append(p);
        };
        line(d.Reach(d.SafetyContour()), 0x73, 1.8);
        line(d.Reach(d.DeepContour()), 0x2E, 0.8);

        fill(kShoreAt, L"LANDA");
        line(kShoreAt, 0x73, 1.0);

        // Spot depths, bold at or shallower than the safety depth. That is
        // what the safety depth does to a chart.
        for (auto const &spot : lkw::DepthChoice::Spots())
        {
            double const depth = d.SafetyContour() * spot.of_contour;
            auto const at = SeabedPoint(d.Reach(depth), spot.across);
            bool const bold = depth <= d.SafetyDepth();
            auto label = Line(std::to_wstring((long long)std::ceil(depth)), 10.5, bold);
            label.Foreground(ink(bold ? 0xCC : 0x8C));
            label.TextWrapping(TextWrapping::NoWrap);
            Controls::Canvas::SetLeft(label, at.X - 6);
            Controls::Canvas::SetTop(label, at.Y - 7);
            depth_seabed.Children().Append(label);
        }
    }
}
