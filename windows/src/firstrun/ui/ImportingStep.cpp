// Setup's Preparing step: the download, the prepare and the bands.
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
    void MainWindow::FirstRunImporting(Controls::StackPanel const &body)
    {
        body.Children().Append(
            Heading(L"Preparing your charts",
                    L"A cell holds survey data, not a drawn chart, so Lookout converts each one "
                    L"on the way in. This happens once per set."));

        if (first_run.ordered())
        {
            body.Children().Append(Line(first_run.order_regions(), 14, true));
            body.Children().Append(Muted(L"NOAA · " + Thousands(first_run.order_charts()) +
                                         L" charts · " + SizeText(first_run.order_bytes())));
        }

        // A transfer that left nothing to bake. The step states what the
        // core said and stops there: the bar below counts work that never
        // starts, and Back is the way out (CanGoBack).
        if (first_run.import_stalled())
        {
            body.Children().Append(WarningPanel(
                L"No charts arrived",
                winrt::to_hstring(noaa.state().error[0] != 0 ? noaa.state().error
                                                                : "No charts arrived.")
                    .c_str()));
            return;
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
                // Stops the transfer or the prepare. A stop during the
                // prepare is recorded by the core, which does not resume it.
                lookout_noaa_cancel(noaa.handle());
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
                tick.Foreground(AccentBrush(DarkChrome()));
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
        panel.BorderBrush(HairlineBrush(DarkChrome()));
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
        s += first_run.ordered() ? "|order" : "|none";
        s += first_run.import_stalled() ? "|ended" : "";
        return s;
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
        tick.Foreground(AccentBrush(DarkChrome()));
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
}
