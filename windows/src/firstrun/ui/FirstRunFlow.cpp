// Setup, on screen: the six steps and NOAA's terms.
//
// The core's setup handle (lookout_setup) holds which step is on screen, what
// Back and the primary action do, and when setup comes up. firstrun/lk_firstrun.h
// holds the words and what the Preparing page keeps after the two services
// reset. This file draws both and passes back what the mariner did.
//
// The steps are built in code. Each reads and writes the window's state, and
// the depth step drafted as a UserControl came to 154 lines of XAML for its
// 193 lines of layout code, before the control's own .idl, .h and .cpp.
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
#include "lk_firstrun.h"
#include "lk_chrome.h"
#include "lk_format.h"
#include "lk_paths.h"
#include "FirstRunParts.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace lkw::setup;

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
        // A picker opened from the Charts pane applies a plan: what was
        // unticked is given back, what was ticked is fetched. Setup has
        // nothing to give back, so its action is the flow's own.
        FirstRunPrimaryBtn().Click([this](auto &&, auto &&) {
            if (first_run.picker_only() && first_run.step() == lkw::FirstRunStep::Coverage)
                FirstRunApply();
            else
                FirstRunPrimary();
        });
        // The repair: fetch the water already here again.
        FirstRunAgainBtn().Click([this](auto &&, auto &&) { FirstRunPrimary(); });
        FirstRunBackBtn().Click([this](auto &&, auto &&) {
            // One step opened on its own has nowhere to go back to, so the
            // same button closes it and leaves the chart standing.
            if (first_run.picker_only())
            {
                SetupAct(LOOKOUT_SETUP_LATER, 0);
                FirstRunRender();
                return;
            }
            SetupAct(LOOKOUT_SETUP_BACK, 0);
            FirstRunRender();
        });
        FirstRunLaterBtn().Click([this](auto &&, auto &&) {
            // Set Up Later leaves a usable app behind it. The basemap is
            // already drawing, so putting the card away is enough.
            SetupAct(LOOKOUT_SETUP_LATER, 0);
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
        auto const panel = lkw::Rgb(lkw::chrome::Panel(DarkChrome()));
        FirstRunFadeTop().Color({ 0, panel.R, panel.G, panel.B });
        FirstRunFadeBottom().Color(panel);
    }

    // Note what the core's setup reads off the app, and read its state back
    // into the view model.
    void MainWindow::SetupNote()
    {
        if (setup == nullptr)
            return;
        lookout_setup_facts f{};
        f.catalog_ready = noaa.state().have_catalog;
        f.picked = !noaa_region_id.empty();
        f.on_link = lk_controller_chart_link_selected(controller) != 0;
        f.nothing_to_draw = setup_nothing_to_draw;
        f.has_charts = !sets.Compose().empty() || !raster_paths.empty();
        f.work_running = bake_job != nullptr || noaa.state().preparing || !pending_set.empty();
        f.downloading = noaa.state().phase == LOOKOUT_NOAA_DOWNLOADING;
        f.chart_open = lk_controller_is_open(controller) && chart_has_cells;
        f.noaa_outcome = noaa.state().outcome;
        f.noaa_run = noaa.state().run;
        // Water the device holds whole is priced as what it holds, so an order
        // to fetch it again counts its charts.
        if (!noaa_region_id.empty())
        {
            uint32_t cells = 0, held = 0;
            uint64_t bytes = 0, held_bytes = 0;
            lookout_noaa_cost(noaa.handle(), noaa_region_id.c_str(), &cells, &bytes, &held,
                              &held_bytes);
            bool const all_held = cells == 0 && held > 0;
            f.pick_charts = all_held ? held : cells;
            f.pick_bytes = all_held ? held_bytes : bytes;
        }
        lookout_setup_note(setup, &f);
        lookout_setup_state s{};
        lookout_setup_read(setup, &s);
        first_run.Read(s);
    }

    // Apply a LOOKOUT_SETUP_* action on current facts. Returns the source the
    // shell acts on, or -1.
    int MainWindow::SetupAct(int action, int arg)
    {
        if (setup == nullptr)
            return -1;
        SetupNote();
        int const source = lookout_setup_act(setup, action, arg);
        lookout_setup_state s{};
        lookout_setup_read(setup, &s);
        first_run.Read(s);
        return source;
    }

    // Raise setup when the core's state says it has a reason to come up.
    // Called where the app settles on having no chart to draw.
    bool MainWindow::SetupShouldRun()
    {
        setup_nothing_to_draw = true;
        SetupNote();
        lookout_setup_state s{};
        lookout_setup_read(setup, &s);
        return s.should_run != 0;
    }

    void MainWindow::FirstRunBegin()
    {
        first_run.Restart();
        SetupAct(LOOKOUT_SETUP_BEGIN, LOOKOUT_SETUP_STEP_WELCOME);
        FirstRunShowWholeCountry();
        FirstRunRender();
    }

    // Frame the lower 48 behind setup, so the chart under it shows the
    // coastline the mariner is choosing from. United States charts label
    // depths in feet, and setup is the one moment the unit can be chosen
    // before the first sounding draws.
    void MainWindow::FirstRunShowWholeCountry()
    {
        lk_controller_set_view(controller, -96.0, 38.0, 5.0);
        tile57_mariner m{};
        lk_controller_get_mariner(controller, &m);
        m.depth_unit = (tile57_depth_unit)1; /* feet */
        lk_controller_set_mariner(controller, &m);
        depth_choice = lkw::DepthChoice{ true };
    }

    void MainWindow::FirstRunRender()
    {
        SetupNote();
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
                auto paths = sets.Compose();
                if (!paths.empty())
                    OpenPaths(paths, paths.front(), lkw::AgencyForCells(paths));
            }

            // The readouts run again. Setup stops that clock while it holds
            // the screen, and the only place that started it again was a
            // successful open. A run that ends without one, through Set Up
            // Later, an online chart or a file picker the mariner cancelled,
            // left the scale bar, the position pill and the chart link poll
            // dead for the rest of the launch.
            if (lk_controller_is_open(controller))
            {
                readout_timer.Start();
                UpdateReadouts();
            }
            return;
        }
        // The search, menu, north, zoom, settings and scale bar steer a chart.
        // Setup is a takeover, and the scale bar sat over the Set Up Later
        // button at the bottom of the card.
        FirstRunChartChrome(false);
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
        FirstRunPrimaryBtn().Content(box_value(first_run.PrimaryTitle(ActiveChartLinkName())));

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
        int const act = SetupAct(LOOKOUT_SETUP_ADVANCE, static_cast<int>(first_run.source()));
        if (first_run.showing_enc_terms())
        {
            // The model raised NOAA's terms instead of moving the step.
            FirstRunShowEncTerms();
            return;
        }
        if (act >= 0)
            FirstRunAct(static_cast<lkw::ChartSource>(act));
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

            // The core latched the order's counts on advance. The page names
            // the regions rather than their ids, so "Alaska" for "d17", and
            // every one the mariner picked.
            std::wstring names;
            lookout_noaa_region const *regions = nullptr;
            size_t const n = lookout_noaa_regions(&regions);
            for (size_t i = 0; i < n && regions != nullptr; ++i)
            {
                if (!lkw::RegionPicked(noaa_region_id, regions[i].id))
                    continue;
                if (!names.empty())
                    names += L", ";
                names += winrt::to_hstring(regions[i].name);
            }
            first_run.set_order_regions(std::move(names));

            // `again` fetches the cells this device already holds as well,
            // for a pick of water that is wholly installed.
            // The picker's Apply also gives back the water it unticked.
            if (first_run.picker_only())
                NoaaApply(noaa_region_id, NoaaAllHeld());
            else
                NoaaDownload(noaa_region_id, NoaaAllHeld());
            break;
        }

        case lkw::ChartSource::Online:
            // The link was added and selected on the step itself.
            break;

        case lkw::ChartSource::Files:
            // The model has put setup away, so the picker comes up over the
            // chart rather than over a card that is about to close.
            PickChartFolder();
            break;
        }
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
            SetupAct(LOOKOUT_SETUP_AGREE, 0);
        else
            SetupAct(LOOKOUT_SETUP_DECLINE, 0); // the source step stands, NOAA still picked
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
        auto picture = lkw::ShippedPicture(L"welcome-chart.png");
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
        body.Children().Append(Fact(L"" /* map pin */,
                                    L"Official ENC charts, drawn live",
                                    L"Lookout renders S-57 and S-101 cells itself. NOAA publishes "
                                    L"every United States chart at no cost; most other offices "
                                    L"sell theirs.", DarkChrome()));
        body.Children().Append(Fact(L"" /* globe */, L"Or start with an online chart",
                                    L"A published chart style renders straight away, worldwide, "
                                    L"with nothing to download and nothing stored.", DarkChrome()));
        body.Children().Append(Fact(L"" /* folder */, L"Bring charts you already have",
                                    // A window that takes a drop says so, the
                                    // way the Mac's does.
                                    L"A prepared .pmtiles chart, or a folder of S-57 cells. Or "
                                    L"drop either anywhere in this window.", DarkChrome()));
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
                                   c.recommended, DarkChrome());
            auto src = c.src;
            card.Click([this, src](auto &&, auto &&) {
                first_run.set_source(src);
                FirstRunRender(); // the pick shows in the borders
            });
            body.Children().Append(card);
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

        // A link is added on Enter or Add. The core selects it once it
        // resolves, and the links poll restates the step then.
        Grid row;
        ColumnDefinition c0, c1;
        c0.Width({ 1, GridUnitType::Star });
        c1.Width({ 1, GridUnitType::Auto });
        row.ColumnDefinitions().Append(c0);
        row.ColumnDefinitions().Append(c1);
        row.ColumnSpacing(8);

        TextBox box;
        box.PlaceholderText(L"https://…/style.json");
        auto add = [this, box] {
            AddChartLink(winrt::to_string(box.Text()));
            box.Text(L"");
        };
        box.KeyDown([add](auto &&, auto &&e) {
            if (e.Key() == Windows::System::VirtualKey::Enter)
                add();
        });
        row.Children().Append(box);

        Button add_btn;
        add_btn.Content(box_value(L"Add"));
        add_btn.Click([add](auto &&, auto &&) { add(); });
        Grid::SetColumn(add_btn, 1);
        row.Children().Append(add_btn);
        body.Children().Append(row);
        body.Children().Append(Muted(L"MapLibre style or TileJSON link", 11.5));
    }

    // What the step on screen says now, and whether its action can be taken.
    void MainWindow::FirstRunRestate()
    {
        // Whether the primary action has anything to do, from the core.
        SetupNote();
        FirstRunPrimaryBtn().IsEnabled(first_run.PrimaryEnabled());

        // The coverage step, which is two steps in one: setup downloads water,
        // and a picker opened from the Charts pane applies a plan.
        std::vector<std::string> removing;
        if (first_run.step() == lkw::FirstRunStep::Coverage)
        {
            removing = NoaaRemoving();
            if (first_run.picker_only())
            {
                // The model titles this Apply. What it can do is what the plan
                // holds: charts to fetch, water to give back, or neither.
                uint32_t cells = 0;
                if (!noaa_region_id.empty())
                    lookout_noaa_cost(noaa.handle(), noaa_region_id.c_str(), &cells, nullptr,
                                            nullptr, nullptr);
                FirstRunPrimaryBtn().IsEnabled(
                    lkw::ApplyEnabled(noaa.state().have_catalog != 0, cells, removing.size()));
                // Water wholly here has nothing to add and nothing to give
                // back, and a mariner repairing a damaged download or taking
                // the edition NOAA reissued still needs a way to fetch it.
                FirstRunAgainBtn().Visibility(NoaaAllHeld() && removing.empty()
                                                  ? Visibility::Visible
                                                  : Visibility::Collapsed);
            }
            else
            {
                FirstRunAgainBtn().Visibility(Visibility::Collapsed);
            }
        }
        else
        {
            FirstRunAgainBtn().Visibility(Visibility::Collapsed);
        }

        // The line beside the action. The coverage step prices the pick
        // here, the way the reference does: at the end of the step the
        // footer bar covered it.
        {
            lkw::FirstRun::Footnotes f;
            f.have_catalog = noaa.state().have_catalog != 0;
            f.have_charts = chart_has_cells;
            f.credit = std::wstring{ ScaleBarCredit().Text() };
            f.removing = NoaaRegionNames(removing);
            if (first_run.step() == lkw::FirstRunStep::Coverage)
            {
                uint32_t cells = 0, held = 0;
                uint64_t bytes = 0, held_bytes = 0;
                if (!noaa_region_id.empty())
                    lookout_noaa_cost(noaa.handle(), noaa_region_id.c_str(), &cells, &bytes, &held,
                                      &held_bytes);
                f.picked = cells > 0 || held > 0;
                f.price = first_run.picker_only()
                              ? lkw::PlanLine(cells, bytes, held, held_bytes, f.removing)
                              : lkw::CostLine(cells, bytes, held, held_bytes);
            }
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
                        first_run.ordered() && !shown.downloading });
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
}
