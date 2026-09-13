/* Setup: when it runs, where it goes, and what it keeps on the screen.
 *
 * Three rules earn their tests here, and each of them is a defect somebody
 * already shipped.
 *
 * WHEN IT RUNS. Setup is where an empty chart area goes, for every reason it
 * can be empty, including a configured set whose drive is unplugged. There is
 * no standalone empty page to fall back to (T-005 reversed T-003 here), so the
 * trigger asks only whether there is anything to draw.
 *
 * NOAA'S TERMS. Continuing from the source step with NOAA picked must not move
 * the step. The gate lives in the model so that every caller of the primary
 * action inherits it, and cancelling has to leave the source step standing with
 * NOAA still selected.
 *
 * THE COUNTS. Both services zero their counters when their work ends, so a page
 * that reads them live empties itself to "0 of 513" with no bands at the very
 * moment it finishes. The model latches instead.
 */
#include "lk_test.h"

#include "lk_firstrun.h"

using namespace lktest;
using namespace lkw;

namespace
{
    /* A flow parked on the step a case is about. */
    FirstRun At(FirstRunStep want, ChartSource src = ChartSource::Noaa)
    {
        FirstRun f;
        f.Begin();
        f.set_source(src);
        if (want == FirstRunStep::Welcome)
            return f;
        f.Advance(); // Welcome -> Source
        if (want == FirstRunStep::Source)
            return f;
        if (src == ChartSource::Noaa)
        {
            f.Advance();          // raises the terms, does NOT move
            f.AgreeToEncTerms();  // -> Coverage
            if (want == FirstRunStep::Coverage)
                return f;
            f.Advance(); // -> Importing
            if (want == FirstRunStep::Importing)
                return f;
            f.Advance(); // -> Depths
            return f;
        }
        f.Advance(); // Source -> OnlineChart
        if (want == FirstRunStep::OnlineChart)
            return f;
        f.Advance(); // -> Depths
        return f;
    }

    /* One reading of the two services. */
    FirstRunLive Fetching(uint32_t done, uint32_t total)
    {
        FirstRunLive l;
        l.downloading = true;
        l.fetched     = done;
        l.expected    = total;
        return l;
    }

    FirstRunLive Baking(uint32_t done, uint32_t found, std::vector<FirstRunBand> bands = {})
    {
        FirstRunLive l;
        l.baking = true;
        l.baked  = done;
        l.found  = found;
        l.bands  = std::move(bands);
        return l;
    }

    FirstRunBand Band(int n, uint32_t done, uint32_t total)
    {
        FirstRunBand b;
        b.band  = n;
        b.name  = FirstRunBandName(n);
        b.done  = done;
        b.total = total;
        return b;
    }
}

void TestFirstRun()
{
    Suite("lk_firstrun: whether it runs");
    {
        FirstRun f;

        Case("nothing to draw and nothing linked: setup runs");
        LK_EQ(f.ShouldRun(true, false), true);

        Case("a chart is drawing: setup stays down");
        LK_EQ(f.ShouldRun(false, false), false);

        /* The case T-003 held back and T-005 sent here. A configured set whose
         * drive is unplugged scans to no cells, so there is nothing to draw
         * and setup runs. The source step is where that mariner re-points at
         * their charts. macOS flagged this reading for a second look on
         * screen. */
        Case("a set that will not read has nothing to draw, so setup runs");
        LK_EQ(f.ShouldRun(true, false), true);

        Case("a published style drawing in place of a library keeps setup down");
        LK_EQ(f.ShouldRun(true, true), false);

        Case("Set Up Later holds for the rest of the launch");
        f.Finish();
        LK_EQ(f.ShouldRun(true, false), false);
    }

    Suite("lk_firstrun: NOAA's terms");
    {
        FirstRun f = At(FirstRunStep::Source, ChartSource::Noaa);

        Case("continuing with NOAA raises the terms");
        auto act = f.Advance();
        LK_EQ(f.showing_enc_terms(), true);
        LK_EQ(act.has_value(), false);

        /* The gate is the whole point: the step must NOT have moved. */
        Case("and does not move the step");
        LK_EQ(f.step(), FirstRunStep::Source);

        Case("cancelling leaves the source step standing");
        f.DeclineEncTerms();
        LK_EQ(f.showing_enc_terms(), false);
        LK_EQ(f.step(), FirstRunStep::Source);

        Case("with NOAA still selected, so another source is open to them");
        LK_EQ(f.source(), ChartSource::Noaa);

        Case("agreeing goes on to the regions");
        f.Advance();
        f.AgreeToEncTerms();
        LK_EQ(f.showing_enc_terms(), false);
        LK_EQ(f.step(), FirstRunStep::Coverage);
    }
    {
        Case("an online chart is asked to accept nothing");
        FirstRun f = At(FirstRunStep::Source, ChartSource::Online);
        f.Advance();
        LK_EQ(f.showing_enc_terms(), false);
        LK_EQ(f.step(), FirstRunStep::OnlineChart);

        Case("nor are the mariner's own files");
        FirstRun g = At(FirstRunStep::Source, ChartSource::Files);
        auto act = g.Advance();
        LK_EQ(g.showing_enc_terms(), false);
        LK_EQ(act.has_value(), true);
        LK_EQ(act.value(), ChartSource::Files);
    }

    Suite("lk_firstrun: the steps");
    {
        FirstRun f;
        f.Begin();

        Case("it opens on Welcome, showing");
        LK_EQ(f.step(), FirstRunStep::Welcome);
        LK_EQ(f.showing(), true);

        Case("Welcome offers no way back");
        LK_EQ(f.CanGoBack(), false);

        Case("the asking steps do");
        f.Advance();
        LK_EQ(f.step(), FirstRunStep::Source);
        LK_EQ(f.CanGoBack(), true);
        f.Back();
        LK_EQ(f.step(), FirstRunStep::Welcome);

        Case("the terms stay out of Back: cancelling is not a step");
        FirstRun g = At(FirstRunStep::Source, ChartSource::Noaa);
        g.Advance();
        g.DeclineEncTerms();
        LK_EQ(g.CanGoBack(), true);
        g.Back();
        LK_EQ(g.step(), FirstRunStep::Welcome);

        Case("past the import there is no way back");
        FirstRun h = At(FirstRunStep::Importing);
        LK_EQ(h.CanGoBack(), false);
        h.Advance();
        LK_EQ(h.step(), FirstRunStep::Depths);
        LK_EQ(h.CanGoBack(), false);

        Case("Start Sailing ends setup");
        h.Advance();
        LK_EQ(h.showing(), false);
        LK_EQ(h.ShouldRun(true, false), false);
    }

    Suite("lk_firstrun: one step on its own");
    {
        /* Get charts from NOAA in the Charts pane opens the coverage step
         * alone. The mariner already owns charts and already answered the
         * welcome questions. */
        FirstRun f;
        f.BeginAt(FirstRunStep::Coverage);

        Case("it opens on the step asked for, showing");
        LK_EQ(f.step(), FirstRunStep::Coverage);
        LK_EQ(f.showing(), true);
        LK_EQ(f.picker_only(), true);

        Case("Back has nowhere to go, because there is no step before it");
        LK_EQ(f.CanGoBack(), false);

        Case("Download still reaches the import");
        auto act = f.Advance();
        LK_EQ(f.step(), FirstRunStep::Importing);
        LK_EQ(act.has_value(), true);
        LK_EQ(act.value(), ChartSource::Noaa);

        Case("and the import ends the run rather than asking for depths");
        f.Advance();
        LK_EQ(f.showing(), false);

        Case("the flag clears, so a later full run reaches the depth step");
        LK_EQ(f.picker_only(), false);
        FirstRun g;
        g.Begin();
        LK_EQ(g.picker_only(), false);
        g.Advance();
        g.Advance();
        g.AgreeToEncTerms();
        g.Advance();
        LK_EQ(g.step(), FirstRunStep::Importing);
        g.Advance();
        LK_EQ(g.step(), FirstRunStep::Depths);
    }

    Suite("lk_firstrun: the words");
    {
        Case("each step names itself");
        LK_EQ(At(FirstRunStep::Welcome).Title(), std::wstring(L"Welcome"));
        LK_EQ(At(FirstRunStep::Source).Title(), std::wstring(L"Add charts"));
        LK_EQ(At(FirstRunStep::Coverage).Title(), std::wstring(L"Coverage"));
        LK_EQ(At(FirstRunStep::Importing).Title(), std::wstring(L"Preparing"));
        LK_EQ(At(FirstRunStep::Depths).Title(), std::wstring(L"Depths"));
        LK_EQ(At(FirstRunStep::OnlineChart, ChartSource::Online).Title(),
              std::wstring(L"Online chart"));

        Case("the coverage step's button says what it does");
        LK_EQ(At(FirstRunStep::Coverage).PrimaryTitle(false), std::wstring(L"Download"));

        Case("the online step offers Skip until a chart is chosen");
        FirstRun f = At(FirstRunStep::OnlineChart, ChartSource::Online);
        LK_EQ(f.PrimaryTitle(false), std::wstring(L"Skip"));
        LK_EQ(f.PrimaryTitle(true), std::wstring(L"Continue"));

        Case("the last step names what it keeps");
        LK_EQ(At(FirstRunStep::Depths).PrimaryTitle(true), std::wstring(L"Start Sailing"));
    }

    Suite("lk_firstrun: the counts are latched");
    {
        FirstRun f = At(FirstRunStep::Importing);
        FirstRunOrder o;
        o.regions    = L"Alaska";
        o.region_ids = "d17";
        o.charts     = 1238;
        o.bytes      = 222661011;
        f.set_order(std::move(o));

        Case("before the transfer reports, the order is what is expected");
        LK_EQ(f.expected(), 1238u);

        Case("the transfer's own total replaces the order once it has one");
        f.Observe(Fetching(120, 513));
        LK_EQ(f.expected(), 513u);
        LK_EQ(f.shown().fetched, 120u);

        /* The defect. The transfer finishes and zeroes itself; the page must
         * not follow it down to "0 of 513", nor to "0 of 0". */
        Case("a reading with no total is the service resetting");
        f.Observe(FirstRunLive{});
        LK_EQ(f.expected(), 513u);
        LK_EQ(f.shown().fetched, 120u);

        Case("but whether it is still working is read live");
        LK_EQ(f.shown().downloading, false);

        Case("the bake's counts latch the same way");
        f.Observe(Baking(40, 513, { Band(1, 12, 12), Band(2, 28, 60) }));
        LK_EQ(f.shown().found, 513u);
        LK_EQ(f.shown().baked, 40u);
        LK_EQ(f.shown().bands.size(), size_t{ 2 });

        Case("and the bands survive the bake's last, empty state");
        f.Observe(FirstRunLive{});
        LK_EQ(f.shown().bands.size(), size_t{ 2 });
        LK_EQ(f.shown().found, 513u);
        LK_EQ(f.shown().baked, 40u);

        Case("a finished band reads as finished");
        LK_EQ(f.shown().bands[0].complete(), true);
        LK_EQ(f.shown().bands[1].complete(), false);
    }

    Suite("lk_firstrun: the one bar");
    {
        FirstRun f = At(FirstRunStep::Importing);

        Case("a job that has not started reads as zero");
        LK_EQ(f.Fraction(), 0.0);

        Case("the transfer fills the first 35%");
        f.Observe(Fetching(0, 100));
        LK_EQ(f.Fraction(), 0.0);
        f.Observe(Fetching(50, 100));
        LK_NEAR(f.Fraction(), 0.175, 1e-12);
        f.Observe(Fetching(100, 100));
        LK_NEAR(f.Fraction(), 0.35, 1e-12);

        Case("the bake fills the rest");
        f.Observe(Baking(0, 200));
        LK_NEAR(f.Fraction(), 0.35, 1e-12);
        f.Observe(Baking(100, 200));
        LK_NEAR(f.Fraction(), 0.675, 1e-12);

        /* Both services are now idle and both have reset. Before saw_bake this
         * state was indistinguishable from "nothing has started". */
        Case("a bake that has been seen and has stopped is finished");
        LK_EQ(f.saw_bake(), true);
        f.Observe(FirstRunLive{});
        LK_EQ(f.Fraction(), 1.0);
    }

    Suite("lk_firstrun: the bands are named");
    {
        Case("coarse first, in the order the bake runs");
        LK_EQ(FirstRunBandName(1), std::wstring(L"Overview"));
        LK_EQ(FirstRunBandName(2), std::wstring(L"General"));
        LK_EQ(FirstRunBandName(3), std::wstring(L"Coastal"));
        LK_EQ(FirstRunBandName(4), std::wstring(L"Approach"));
        LK_EQ(FirstRunBandName(5), std::wstring(L"Harbor"));
        LK_EQ(FirstRunBandName(6), std::wstring(L"Berthing"));

        Case("a name with no usage band is not invented");
        LK_EQ(FirstRunBandName(0), std::wstring(L"Other"));
        LK_EQ(FirstRunBandName(9), std::wstring(L"Other"));
    }

    Suite("lk_firstrun: the bands follow the bake's order");
    {
        /* Two Overview, three Coastal, four Harbor. The bake runs them coarse
         * first, so `done` fills them in that order and nowhere else. */
        std::vector<int> const scan{ 5, 3, 1, 5, 3, 1, 5, 3, 5 };

        Case("nothing baked yet: every band is present and empty");
        auto b = FirstRunBands(scan, 0);
        LK_EQ(b.size(), size_t{ 3 });
        LK_EQ(b[0].band, 1);
        LK_EQ(b[0].total, 2u);
        LK_EQ(b[0].done, 0u);

        Case("the coarsest band fills first, and alone");
        b = FirstRunBands(scan, 1);
        LK_EQ(b[0].done, 1u);
        LK_EQ(b[1].done, 0u);
        LK_EQ(b[2].done, 0u);

        Case("a finished band does not hold back the next");
        b = FirstRunBands(scan, 4);
        LK_EQ(b[0].done, 2u);
        LK_EQ(b[0].complete(), true);
        LK_EQ(b[1].done, 2u);
        LK_EQ(b[1].complete(), false);
        LK_EQ(b[2].done, 0u);

        Case("everything baked: every band complete");
        b = FirstRunBands(scan, 9);
        for (auto const &x : b)
            LK_EQ(x.complete(), true);

        /* The bake counts a chart the scan did not, or a count arrives out of
         * order. Neither may report more done than there are. */
        Case("a count past the total does not overflow a band");
        b = FirstRunBands(scan, 99);
        LK_EQ(b[2].done, b[2].total);

        Case("bands with no charts are left out entirely");
        b = FirstRunBands({ 3, 3 }, 0);
        LK_EQ(b.size(), size_t{ 1 });
        LK_EQ(b[0].name, std::wstring(L"Coastal"));

        /* A cell whose name has no band sorts last in the bake, so it sorts
         * last here. Reported first, a 0 claims the wide-area slot and the
         * page ticks off "Other" before Overview. */
        Case("a chart with no band goes last");
        b = FirstRunBands({ 0, 1 }, 1);
        LK_EQ(b.size(), size_t{ 2 });
        LK_EQ(b[0].name, std::wstring(L"Overview"));
        LK_EQ(b[0].done, 1u);
        LK_EQ(b[1].name, std::wstring(L"Other"));
        LK_EQ(b[1].done, 0u);

        Case("no charts at all gives no bands");
        LK_EQ(FirstRunBands({}, 0).size(), size_t{ 0 });
    }

    /* The two figures a download is priced in and a library is totalled in.
     * The settings pane reads them as well as the coverage step. */
    Suite("lk_firstrun: the figures");
    {
        Case("megabytes under a gigabyte");
        LK_EQ(SizeText(226'492'416ull), std::wstring(L"216.0 MB"));

        Case("gigabytes above one");
        LK_EQ(SizeText(4'617'089'843ull), std::wstring(L"4.3 GB"));

        Case("a gigabyte exactly reads in gigabytes");
        LK_EQ(SizeText(1ull << 30), std::wstring(L"1.0 GB"));

        Case("nothing measured reads as zero");
        LK_EQ(SizeText(0), std::wstring(L"0.0 MB"));

        Case("thousands are grouped");
        LK_EQ(Thousands(1238), std::wstring(L"1,238"));
        LK_EQ(Thousands(8233), std::wstring(L"8,233"));

        Case("a number under a thousand is left alone");
        LK_EQ(Thousands(4), std::wstring(L"4"));
        LK_EQ(Thousands(999), std::wstring(L"999"));

        Case("a library of millions of charts still groups");
        LK_EQ(Thousands(2'631'004), std::wstring(L"2,631,004"));

        /* What the question before a delete says the work is worth. A fifth
         * of a second a chart. */
        Case("a handful of charts is under a minute");
        LK_EQ(PrepareEstimate(4), std::wstring(L"under a minute"));
        LK_EQ(PrepareEstimate(299), std::wstring(L"under a minute"));

        /* One minute reads as one minute. The reference says "about 1
         * minutes" here, which is the one place this departs from it. */
        Case("a region is minutes");
        LK_EQ(PrepareEstimate(300), std::wstring(L"about a minute"));
        LK_EQ(PrepareEstimate(937), std::wstring(L"about 3 minutes"));

        Case("a whole coast is hours");
        LK_EQ(PrepareEstimate(2631), std::wstring(L"about 9 minutes"));
        LK_EQ(PrepareEstimate(72'000), std::wstring(L"about 4.0 hours"));

        /* An empty set still costs the one chart's worth, because a set with
         * nothing in it is not what this question is for. */
        Case("no charts still reads as work");
        LK_EQ(PrepareEstimate(0), std::wstring(L"under a minute"));
    }
}
