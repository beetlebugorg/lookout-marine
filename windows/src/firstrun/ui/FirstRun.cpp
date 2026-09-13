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

#include <chrono>
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

    // A step's title and the one line under it.
    StackPanel Heading(std::wstring const &title, std::wstring const &blurb)
    {
        StackPanel s;
        s.Spacing(6);
        s.Children().Append(Line(title, 21, true));
        s.Children().Append(Muted(blurb, 13));
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

    // The shape the other shells price a region in, so "1,238 charts, 226.5 MB".
    std::wstring SizeText(uint64_t bytes)
    {
        wchar_t buf[64];
        if (bytes >= (uint64_t{ 1 } << 30))
            swprintf_s(buf, L"%.1f GB", (double)bytes / (double)(uint64_t{ 1 } << 30));
        else
            swprintf_s(buf, L"%.1f MB", (double)bytes / (double)(1u << 20));
        return buf;
    }

    std::wstring Thousands(uint32_t n)
    {
        std::wstring s = std::to_wstring(n);
        for (int i = (int)s.size() - 3; i > 0; i -= 3)
            s.insert((size_t)i, L",");
        return s;
    }
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
        lk_controller_noaa_refresh(controller);
        first_run.BeginAt(lkw::FirstRunStep::Coverage);
        FirstRunRender();
    }

    // Show the fold while the step runs past the bottom of the card, and keep
    // the scrollbar up with it. A step that fits shows neither.
    void MainWindow::FirstRunUpdateFold()
    {
        auto scroll = FirstRunScroll();
        // One pixel of slack: a step that fits exactly reports an extent a
        // fraction over the viewport on some scales.
        bool const more = scroll.ExtentHeight() > scroll.ViewportHeight() + 1.0;
        FirstRunFade().Visibility(more ? Visibility::Visible : Visibility::Collapsed);
        scroll.VerticalScrollBarVisibility(more ? Controls::ScrollBarVisibility::Visible
                                                : Controls::ScrollBarVisibility::Auto);
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
        FirstRunBackBtn().Visibility(first_run.CanGoBack() ? Visibility::Visible
                                                           : Visibility::Collapsed);
        FirstRunFooterShape(first_run.step() == lkw::FirstRunStep::Welcome);
        FirstRunPrimaryBtn().Content(box_value(first_run.PrimaryTitle(!chart_link_url.empty())));

        auto body = FirstRunBody();
        body.Children().Clear();

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
            // Name the region rather than its id, so "Alaska" for "d17".
            lookout_noaa_region const *regions = nullptr;
            size_t const n = lk_controller_noaa_regions(&regions);
            for (size_t i = 0; i < n && regions != nullptr; ++i)
            {
                if (noaa_region_id == regions[i].id)
                {
                    order.regions = winrt::to_hstring(regions[i].name).c_str();
                    break;
                }
            }
            first_run.set_order(std::move(order));

            // The zips go beside the library rather than in it. They are
            // the source a bake reads. The vector open globs the library for
            // .pmtiles, so a zip inside it joins the composed chart library.
            auto dest = std::filesystem::path(lkw::ChartLibraryDir()).parent_path() / "Downloads";
            std::error_code ec;
            std::filesystem::create_directories(dest, ec);
            noaa_dest_dir = dest.string();

            lk_controller_noaa_download(controller, noaa_region_id.c_str(),
                                        noaa_dest_dir.c_str(), 0);
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
                // The transfer produced no charts. Stop polling rather than
                // spinning over work that will not start.
                first_run_timer.Stop();
            }
        }

        if (first_run.step() == lkw::FirstRunStep::Importing)
            FirstRunRender();
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
        // The title and the line under it center. The rows below them stay
        // left aligned, so the step holds two alignments rather than one.
        {
            StackPanel head;
            head.Spacing(6);
            head.HorizontalAlignment(HorizontalAlignment::Stretch);

            auto title = Line(L"Welcome to Lookout Marine", 21, true);
            title.TextAlignment(TextAlignment::Center);
            head.Children().Append(title);

            auto promise = Muted(L"Official charts, rendered live on your PC.", 13);
            promise.TextAlignment(TextAlignment::Center);
            head.Children().Append(promise);

            body.Children().Append(head);
        }
        body.Children().Append(Fact(L"" /* map pin */,
                                    L"Official ENC charts, drawn live",
                                    L"Lookout renders S-57 and S-101 cells itself. NOAA publishes "
                                    L"every United States chart at no cost; most other offices "
                                    L"sell theirs."));
        body.Children().Append(Fact(L"" /* globe */, L"Or start with an online chart",
                                    L"A published chart style renders straight away, worldwide, "
                                    L"with nothing to download and nothing stored."));
        body.Children().Append(Fact(L"" /* folder */, L"Bring charts you already have",
                                    L"A prepared .pmtiles chart, or a folder of S-57 cells, from "
                                    L"this device."));
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
    void MainWindow::FirstRunCoverageMap(Controls::StackPanel const &body)
    {
        if (coastline_.empty())
            coastline_ = lkw::LoadCoastline((FirstRunDataDir() / L"coastline.bin").string());
        if (coastline_.empty())
            return;

        // The waters the picker shows, wide enough for Alaska, Hawaii and the
        // Virgin Islands at once.
        lkw::MapWindow const win{ -190.0, -60.0, 5.0, 73.0 };
        constexpr double kMapW = 620.0;
        double const kMapH = kMapW / win.Aspect();

        Controls::Canvas canvas;
        canvas.Width(kMapW);
        canvas.Height(kMapH);

        auto sea  = SolidColorBrush{ g_dark ? Windows::UI::Color{ 0xFF, 0x10, 0x1B, 0x24 }
                                            : Windows::UI::Color{ 0xFF, 0xD6, 0xE9, 0xF5 } };
        auto land = SolidColorBrush{ g_dark ? Windows::UI::Color{ 0xFF, 0x2A, 0x2F, 0x33 }
                                            : Windows::UI::Color{ 0xFF, 0xE3, 0xDF, 0xD2 } };

        Shapes::Rectangle back;
        back.Width(kMapW);
        back.Height(kMapH);
        back.Fill(sea);
        canvas.Children().Append(back);

        auto add_rings = [&](uint8_t level, Media::Brush const &fill) {
            for (auto const &ring : coastline_)
            {
                if (ring.level != level || ring.points.size() < 3)
                    continue;
                Shapes::Polygon poly;
                Media::PointCollection pts;
                for (auto const &p : ring.points)
                {
                    double x = 0, y = 0;
                    win.Point(p.lon, p.lat, kMapW, kMapH, &x, &y);
                    pts.Append(Windows::Foundation::Point{ (float)x, (float)y });
                }
                poly.Points(pts);
                poly.Fill(fill);
                canvas.Children().Append(poly);
            }
        };
        add_rings(1, land);
        add_rings(2, sea); // a lake is water drawn back over the land

        // The regions. The picked one is filled and outlined, the rest a faint
        // outline, so the map reads as a chooser rather than a picture.
        lookout_noaa_region const *regions = nullptr;
        size_t const n = lk_controller_noaa_regions(&regions);
        for (size_t i = 0; i < n && regions != nullptr; ++i)
        {
            auto const &r = regions[i];
            bool const picked = noaa_region_id == r.id;

            std::vector<lookout_noaa_box> boxes;
            size_t const have = lk_controller_noaa_region_coverage(controller, r.id, nullptr, 0);
            if (have > 0)
            {
                boxes.resize(have);
                lk_controller_noaa_region_coverage(controller, r.id, boxes.data(), have);
            }
            else
            {
                // Before a catalog is read the region states a rough extent for
                // display. The catalog decides what downloads either way.
                boxes.push_back({ r.west, r.south, r.east, r.north });
            }

            for (auto const &b : boxes)
            {
                if (!win.Intersects(b.west, b.east, b.south, b.north))
                    continue;
                double x0 = 0, y0 = 0, x1 = 0, y1 = 0;
                win.Point(b.west, b.north, kMapW, kMapH, &x0, &y0);
                win.Point(b.east, b.south, kMapW, kMapH, &x1, &y1);
                if (x1 <= x0 || y1 <= y0)
                    continue;
                Shapes::Rectangle box;
                box.Width(x1 - x0);
                box.Height(y1 - y0);
                box.Stroke(AccentBrush());
                box.StrokeThickness(picked ? 1.6 : 0.6);
                if (picked)
                {
                    auto c = AccentColor(g_dark);
                    box.Fill(SolidColorBrush{ Windows::UI::Color{ 0x4D, c.R, c.G, c.B } });
                }
                else
                {
                    box.Opacity(0.45);
                }
                Controls::Canvas::SetLeft(box, x0);
                Controls::Canvas::SetTop(box, y0);
                canvas.Children().Append(box);
            }
        }

        Border frame;
        frame.CornerRadius({ 8, 8, 8, 8 });
        frame.BorderThickness({ 1, 1, 1, 1 });
        frame.BorderBrush(HairlineBrush());
        frame.HorizontalAlignment(HorizontalAlignment::Center);
        frame.Child(canvas);
        Automation::AutomationProperties::SetName(frame, L"Coverage map");
        body.Children().Append(frame);
    }

    void MainWindow::FirstRunCoverage(Controls::StackPanel const &body)
    {
        body.Children().Append(
            Heading(L"Which waters?",
                    L"Pick the Coast Guard district you sail. A region includes the cells filed "
                    L"under it and every cell that overlaps them, so it never draws with a hole "
                    L"at its edge."));

        lookout_noaa_region const *regions = nullptr;
        size_t const n = lk_controller_noaa_regions(&regions);
        if (n == 0 || regions == nullptr)
        {
            body.Children().Append(Muted(L"The region list is not available."));
            return;
        }

        // Before any price: the cost call leaves out what this device holds.
        FirstRunNoaaHave();

        FirstRunCoverageMap(body);

        lookout_noaa_state st{};
        lk_controller_noaa_poll(controller, &st);
        if (!st.have_catalog)
        {
            // The price comes from the catalog. Until it is read a region can be
            // picked but not priced, so name that state rather than showing a
            // zero.
            body.Children().Append(Muted(st.phase == 1
                                             ? L"Reading NOAA's catalog…"
                                             : L"NOAA's catalog has not been read yet."));
        }

        for (size_t i = 0; i < n; ++i)
        {
            auto const &r = regions[i];
            bool const picked = noaa_region_id == r.id;

            std::wstring blurb = winrt::to_hstring(r.blurb).c_str();
            if (picked && st.have_catalog)
            {
                // The price is the region rather than the district. The core
                // counts the overlapping neighbours too, so this is what
                // downloads.
                uint32_t cells = 0, held = 0;
                uint64_t bytes = 0, held_bytes = 0;
                if (lk_controller_noaa_cost(controller, r.id, &cells, &bytes, &held,
                                            &held_bytes))
                {
                    blurb += L"\n" + Thousands(cells) + L" charts, " + SizeText(bytes);
                    if (held > 0)
                        blurb += L" · " + Thousands(held) + L" already installed";
                }
            }

            auto card = ChoiceCard(nullptr, winrt::to_hstring(r.name).c_str(), blurb, picked,
                                   false);
            std::string const rid = r.id;
            card.Click([this, rid](auto &&, auto &&) {
                noaa_region_id = rid;
                FirstRunRender(); // prices the pick
            });
            body.Children().Append(card);
        }
    }

    void MainWindow::FirstRunOnline(Controls::StackPanel const &body)
    {
        body.Children().Append(
            Heading(L"Draw a published chart",
                    L"A style renders straight away, worldwide, and stores nothing on this "
                    L"device."));
        body.Children().Append(
            Muted(L"Paste the address of a MapLibre style, or a TileJSON, and Lookout will draw "
                  L"it as the chart."));

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
        double const f = first_run.Fraction();
        if (f > 0.0)
        {
            bar.IsIndeterminate(false);
            bar.Minimum(0);
            bar.Maximum(1);
            bar.Value(f);
        }
        else
        {
            bar.IsIndeterminate(true);
        }
        body.Children().Append(bar);

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

                auto count = Muted(b.complete()
                                       ? Thousands(b.total) + L" charts"
                                       : Thousands(b.done) + L" of " + Thousands(b.total),
                                   12.5);
                Grid::SetColumn(count, 1);
                row.Children().Append(count);

                if (b.complete())
                {
                    FontIcon tick;
                    tick.Glyph(L""); /* check */
                    tick.FontSize(13);
                    tick.Foreground(AccentBrush());
                    Grid::SetColumn(tick, 2);
                    row.Children().Append(tick);
                }
                bands.Children().Append(row);
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
    }

    // One phase of the job: what it is, how far it got, and whether it ended.
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

        if (done)
        {
            FontIcon tick;
            tick.Glyph(L""); /* check */
            tick.FontSize(14);
            tick.Foreground(AccentBrush());
            tick.HorizontalAlignment(HorizontalAlignment::Left);
            row.Children().Append(tick);
        }
        else if (running)
        {
            ProgressRing ring;
            ring.Width(14);
            ring.Height(14);
            ring.IsActive(true);
            ring.HorizontalAlignment(HorizontalAlignment::Left);
            row.Children().Append(ring);
        }

        // A phase not yet reached is muted. The one running and the ones done
        // read at full strength.
        auto label = Line(name, 13.5, running);
        if (!running && !done)
            label.Opacity(0.7);
        Grid::SetColumn(label, 1);
        row.Children().Append(label);

        auto tail = Muted(detail, 12.5);
        Grid::SetColumn(tail, 2);
        row.Children().Append(tail);

        body.Children().Append(row);
    }

    void MainWindow::FirstRunDepths(Controls::StackPanel const &body)
    {
        body.Children().Append(
            Heading(L"Your draft",
                    L"The safety contour is the line you must not cross. Lookout draws it from "
                    L"your draft and the water you want under the keel."));

        tile57_mariner m{};
        lk_controller_get_mariner(controller, &m);
        bool const feet = m.depth_unit == 1;
        wchar_t const *unit = feet ? L"ft" : L"m";

        body.Children().Append(
            Muted(std::wstring(L"Safety depth ") + std::to_wstring((int)m.safety_depth) + unit +
                  L" · safety contour " + std::to_wstring((int)m.safety_contour) + unit +
                  L" · deep contour " + std::to_wstring((int)m.deep_contour) + unit));
        body.Children().Append(
            Muted(L"You can change these at any time, in Depths in Mariner settings.", 12));
    }
}
