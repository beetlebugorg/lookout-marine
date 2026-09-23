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
        LK_EQ(SizeText(226'492'416ull), std::wstring(L"226.5 MB"));

        Case("gigabytes above one");
        LK_EQ(SizeText(4'617'089'843ull), std::wstring(L"4.6 GB"));

        Case("a gigabyte exactly reads in gigabytes");
        LK_EQ(SizeText(1'000'000'000ull), std::wstring(L"1.0 GB"));

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

    /* The depth step's two questions and the four numbers the engine draws
     * with. A mariner reads these as the water their boat can cross, so each
     * derivation is checked against the reference's own rules. */
    Suite("lk_firstrun: the depths a boat asks for");
    {
        Case("a small keelboat to start, in metres");
        DepthChoice d;
        LK_EQ(d.feet(), false);
        LK_EQ(d.draft(), 1.7);
        LK_EQ(d.clearance(), 0.6);

        /* Draft plus clearance, rounded UP to a whole metre: a chart names
         * its depths in whole numbers. */
        Case("the safety depth rounds up");
        LK_EQ(d.SafetyDepth(), 3.0);

        /* The contour is the first rung the survey draws at or past it. */
        Case("the safety contour is a rung of the ladder");
        LK_EQ(d.SafetyContour(), 5.0);

        Case("the deep contour is twice that, up the same ladder");
        LK_EQ(d.DeepContour(), 10.0);

        Case("a deep draft walks up the ladder");
        DepthChoice ship;
        ship.ReadDraft(L"11");
        ship.set_clearance(1.5);
        LK_EQ(ship.SafetyDepth(), 13.0);
        LK_EQ(ship.SafetyContour(), 20.0);
        LK_EQ(ship.DeepContour(), 50.0);

        /* Past the last rung, the last rung stands. */
        Case("a draft past the ladder stops at its top");
        DepthChoice deep;
        deep.ReadDraft(L"30");
        deep.set_clearance(1.5);
        LK_EQ(deep.SafetyContour(), 50.0);
        LK_EQ(deep.DeepContour(), 100.0);

        Case("feet have their own ladder and clearances");
        DepthChoice f{ true };
        LK_EQ(f.draft(), 5.5);
        LK_EQ(f.clearance(), 2.0);
        LK_EQ(f.SafetyDepth(), 8.0);
        LK_EQ(f.SafetyContour(), 12.0);
        LK_EQ(f.DeepContour(), 30.0);
        LK_EQ(f.Clearances().size(), size_t{ 4 });
        LK_EQ(f.Clearances()[3], 5.0);

        /* The unit changes the numbers on screen, and the clearance snaps to
         * one the new unit offers. */
        Case("changing unit converts the boat");
        DepthChoice u;
        u.SetUnit(true);
        LK_EQ(u.feet(), true);
        LK_EQ(u.draft(), 5.5);      // 1.7 m is 5.577 ft, to the nearest half
        LK_EQ(u.clearance(), 2.0);  // 0.6 m is 1.97 ft, snapped to 2
        u.SetUnit(false);
        LK_EQ(u.feet(), false);
        LK_EQ(u.draft(), 1.5);      // 5.5 ft is 1.676 m, to the nearest half
        LK_EQ(u.clearance(), 0.6);

        Case("the same unit twice changes nothing");
        DepthChoice same;
        same.SetUnit(false);
        LK_EQ(same.draft(), 1.7);

        Case("the field steps by a tenth, or half a foot");
        DepthChoice s;
        s.Step(1);
        LK_EQ(s.DraftText(), std::wstring(L"1.8"));
        s.Step(-1);
        LK_EQ(s.DraftText(), std::wstring(L"1.7"));
        DepthChoice sf{ true };
        sf.Step(1);
        LK_EQ(sf.DraftText(), std::wstring(L"6"));

        /* A draft cannot step below one step or past the deepest hull the
         * step allows. */
        Case("stepping stops at both ends");
        DepthChoice edge;
        for (int i = 0; i < 40; ++i)
            edge.Step(-1);
        LK_EQ(edge.draft(), 0.1);
        for (int i = 0; i < 400; ++i)
            edge.Step(1);
        LK_EQ(edge.draft(), 30.0);

        Case("what a mariner types");
        DepthChoice t;
        LK_EQ(t.ReadDraft(L"2.4"), true);
        LK_EQ(t.draft(), 2.4);
        LK_EQ(t.ReadDraft(L"deep"), false);
        LK_EQ(t.draft(), 2.4); // the draft stands
        LK_EQ(t.ReadDraft(L"0"), false);
        LK_EQ(t.ReadDraft(L"-3"), false);
        LK_EQ(t.ReadDraft(L"99"), true);
        LK_EQ(t.draft(), 30.0); // clamped to the deepest hull in metres

        Case("a depth reads with its unit and no trailing zero");
        LK_EQ(d.Measure(5.0), std::wstring(L"5 m"));
        LK_EQ(d.Measure(1.75), std::wstring(L"1.8 m"));
        LK_EQ(f.Measure(12.0), std::wstring(L"12 ft"));

        /* The illustration's slope: the shore stands at 0.14, the floor is
         * half again past the deep contour, and a depth past the floor
         * reaches the far edge. */
        Case("how far out a depth lies");
        LK_EQ(d.Floor(), 15.0);
        LK_EQ(d.Reach(0.0), 0.14);
        LK_EQ(d.Reach(15.0), 1.0);
        LK_EQ(d.Reach(100.0), 1.0); // past the floor, still the far edge
        LK_EQ(d.Reach(5.0) > d.Reach(2.0), true);
        LK_EQ(d.Reach(5.0) < d.Reach(10.0), true);

        Case("the soundings are twelve, and they climb");
        auto spots = DepthChoice::Spots();
        LK_EQ(spots.size(), size_t{ 12 });
        LK_EQ(spots.front().of_contour, 0.12);
        LK_EQ(spots.back().of_contour, 2.85);

        /* The engine is always given metres. */
        Case("the engine is given metres");
        LK_EQ(d.Metres(5.0), 5.0);
        LK_EQ((int)(f.Metres(12.0) * 100 + 0.5), 366); // 12 ft is 3.66 m
    }

    /* What the primary button can do on the step showing. */
    Suite("lk_firstrun: whether the primary action is ready");
    {
        Case("the early steps always are");
        LK_EQ(At(FirstRunStep::Welcome).PrimaryEnabled(false, false, false), true);
        LK_EQ(At(FirstRunStep::Source).PrimaryEnabled(false, false, false), true);

        /* Download with nothing picked, or with no catalog to price it from,
         * does nothing. */
        Case("download waits for a catalog and a pick");
        LK_EQ(At(FirstRunStep::Coverage).PrimaryEnabled(true, true, false), true);
        LK_EQ(At(FirstRunStep::Coverage).PrimaryEnabled(true, false, false), false);
        LK_EQ(At(FirstRunStep::Coverage).PrimaryEnabled(false, true, false), false);

        /* While charts arrive there is nothing to continue to. */
        Case("preparing holds the button until the charts are open");
        FirstRun f = At(FirstRunStep::Importing);
        LK_EQ(f.PrimaryEnabled(true, true, true), false); // no bake seen yet

        FirstRunLive baking;
        baking.baking = true;
        f.Observe(baking);
        LK_EQ(f.saw_bake(), true);
        LK_EQ(f.PrimaryEnabled(true, true, true), false); // still baking

        FirstRunLive done;
        f.Observe(done);
        LK_EQ(f.PrimaryEnabled(true, true, true), true);
        Case("and until the library is open");
        LK_EQ(f.PrimaryEnabled(true, true, false), false);

        Case("a download still running holds it too");
        FirstRun g = At(FirstRunStep::Importing);
        FirstRunLive mid;
        mid.baking = true;
        g.Observe(mid);
        FirstRunLive fetching;
        fetching.downloading = true;
        g.Observe(fetching);
        LK_EQ(g.PrimaryEnabled(true, true, true), false);
    }

    /* The picked regions, as the core's comma separated list. A pill toggles
     * one id in it and every other pick stands. */
    Suite("lk_firstrun: the regions picked");
    {
        Case("the first pick starts the list");
        LK_EQ(RegionToggle("", "d5"), std::string("d5"));

        Case("a second pick joins it");
        LK_EQ(RegionToggle("d5", "d9"), std::string("d5,d9"));
        LK_EQ(RegionToggle("d5,d9", "d17"), std::string("d5,d9,d17"));

        Case("picking again drops it");
        LK_EQ(RegionToggle("d5,d9,d17", "d9"), std::string("d5,d17"));
        LK_EQ(RegionToggle("d5", "d5"), std::string(""));

        Case("dropping the first leaves no comma at the front");
        LK_EQ(RegionToggle("d5,d9", "d5"), std::string("d9"));

        Case("what is picked");
        LK_EQ(RegionPicked("d5,d9", "d5"), true);
        LK_EQ(RegionPicked("d5,d9", "d9"), true);
        LK_EQ(RegionPicked("d5,d9", "d17"), false);
        LK_EQ(RegionPicked("", "d5"), false);

        /* "d1" must not answer for "d11", which a plain search for the id
         * inside the string would. */
        Case("an id is matched whole");
        LK_EQ(RegionPicked("d11", "d1"), false);
        LK_EQ(RegionPicked("d1,d11", "d1"), true);
        LK_EQ(RegionToggle("d11", "d1"), std::string("d11,d1"));

        /* What a mariner holds, region by region. The picker priced only the
         * pick, so water already downloaded looked the same as water that was
         * not here. */
        Case("a region wholly here reads installed");
        RegionHold all{ 0, 930 };
        LK_EQ(all.Total(), 930u);
        LK_EQ(all.Complete(), true);
        LK_EQ(all.Partial(), false);
        LK_EQ(RegionBadge(all), std::wstring(L"installed"));

        Case("a region partly here counts both");
        RegionHold some{ 9, 3 };
        LK_EQ(some.Total(), 12u);
        LK_EQ(some.Complete(), false);
        LK_EQ(some.Partial(), true);
        /* No fraction: NOAA files cells across district lines, so part of a
         * neighbour arrives with every download, and "3 of 12" on the pill
         * reads as a transfer that stopped. The name keeps the count. */
        LK_EQ(RegionBadge(some), std::wstring(L""));

        Case("water none of which is here says nothing");
        RegionHold none{ 412, 0 };
        LK_EQ(none.Complete(), false);
        LK_EQ(none.Partial(), false);
        LK_EQ(RegionBadge(none), std::wstring(L""));

        /* Before a catalog is read every count is zero, which is not the same
         * fact as a region with nothing downloaded. */
        Case("an unpriced region is not a region with nothing");
        RegionHold blank{};
        LK_EQ(blank.Known(), false);
        LK_EQ(none.Known(), true);
        LK_EQ(RegionBadge(blank), std::wstring(L""));

        Case("the counts a screen reader hears");
        LK_EQ(RegionLabel(L"Mid-Atlantic", L"Delaware to Cape Hatteras", all),
              std::wstring(L"Mid-Atlantic. Delaware to Cape Hatteras. All 930 charts "
                           L"installed."));
        LK_EQ(RegionLabel(L"Mid-Atlantic", L"Delaware to Cape Hatteras", some),
              std::wstring(L"Mid-Atlantic. Delaware to Cape Hatteras. 3 of 12 charts "
                           L"installed."));
        LK_EQ(RegionLabel(L"Alaska", L"Dixon Entrance to the Beaufort Sea", none),
              std::wstring(L"Alaska. Dixon Entrance to the Beaufort Sea. 412 charts, none "
                           L"installed."));
        LK_EQ(RegionLabel(L"Alaska", L"Dixon Entrance to the Beaufort Sea", blank),
              std::wstring(L"Alaska. Dixon Entrance to the Beaufort Sea"));

        /* The line beside the primary action. It stated the price of a pick
         * at the end of the step, where the footer bar covered it. */
        Case("what a pick costs, in the mariner's words");
        LK_EQ(CostLine(930, 102760448, 0, 0), std::wstring(L"930 charts, 102.8 MB"));
        LK_EQ(CostLine(27, 3145728, 864, 90177536),
              std::wstring(L"27 charts, 3.1 MB · 864 already installed"));
        LK_EQ(CostLine(0, 0, 930, 102760448),
              std::wstring(L"930 charts, all installed · 102.8 MB to fetch again"));

        Case("the coverage step prices the pick beside the action");
        FirstRun::Footnotes cov{};
        cov.have_catalog = true;
        cov.cells = 930;
        cov.bytes = 102760448;
        LK_EQ(At(FirstRunStep::Coverage).Footnote(cov), std::wstring(L"930 charts, 102.8 MB"));

        /* Water already here counts as picked: a region wholly installed
         * prices as nothing, which read as an empty pick. */
        Case("a pick wholly installed is not an empty pick");
        FirstRun::Footnotes whole{};
        whole.have_catalog = true;
        whole.held = 930;
        whole.held_bytes = 102760448;
        LK_EQ(At(FirstRunStep::Coverage).Footnote(whole),
              std::wstring(L"930 charts, all installed · 102.8 MB to fetch again"));

        Case("nothing picked asks for a region");
        FirstRun::Footnotes bare{};
        bare.have_catalog = true;
        LK_EQ(At(FirstRunStep::Coverage).Footnote(bare), std::wstring(L"Pick at least one region."));

        Case("no catalog, nothing to say");
        FirstRun::Footnotes unread{};
        LK_EQ(At(FirstRunStep::Coverage).Footnote(unread), std::wstring(L""));

        Case("the depths step says where its numbers live afterwards");
        LK_EQ(At(FirstRunStep::Depths).Footnote(unread),
              std::wstring(L"Change any of this later in Mariner settings, in Depths."));

        Case("the online step states the credit, and what is kept");
        FirstRun::Footnotes link{};
        link.credit = L"© OpenStreetMap contributors";
        link.have_charts = true;
        LK_EQ(At(FirstRunStep::OnlineChart, ChartSource::Online).Footnote(link),
              std::wstring(L"© OpenStreetMap contributors · installed charts stay installed"));
        link.have_charts = false;
        LK_EQ(At(FirstRunStep::OnlineChart, ChartSource::Online).Footnote(link),
              std::wstring(L"© OpenStreetMap contributors"));

        /* An install with no charts has none to reassure a mariner about. */
        Case("a link with no credit and nothing installed says nothing");
        FirstRun::Footnotes plain{};
        LK_EQ(At(FirstRunStep::OnlineChart, ChartSource::Online).Footnote(plain),
              std::wstring(L""));

        Case("the steps with nothing to say");
        LK_EQ(At(FirstRunStep::Welcome).Footnote(link), std::wstring(L""));
        LK_EQ(At(FirstRunStep::Source).Footnote(link), std::wstring(L""));
        LK_EQ(At(FirstRunStep::Importing).Footnote(link), std::wstring(L""));

        /* The picker's other half: water given back. There was no way to
         * unpick water once it was downloaded except by removing a whole
         * chart set. */
        Case("what was held and is no longer ticked");
        LK_EQ(Removed("d1,d7", "d7").size(), 1u);
        LK_EQ(Removed("d1,d7", "d7")[0], std::string("d1"));
        LK_EQ(Removed("d1,d7", "d1,d7").size(), 0u);
        LK_EQ(Removed("", "d5").size(), 0u);

        /* Unticking water that was never on the device is a mariner changing
         * their mind, not a removal. */
        Case("a region never here is not a removal");
        LK_EQ(Removed("d7", "d7,d5").size(), 0u);
        LK_EQ(Removed("d7", "d5").size(), 1u);

        Case("both halves in one line");
        std::vector<std::wstring> gone{ L"Northeast" };
        LK_EQ(PlanLine(930, 102760448, 0, 0, {}),
              std::wstring(L"Add 930 charts, 102.8 MB"));
        LK_EQ(PlanLine(930, 102760448, 0, 0, gone),
              std::wstring(L"Add 930 charts, 102.8 MB · remove Northeast"));
        gone.push_back(L"Southeast");
        LK_EQ(PlanLine(0, 0, 0, 0, gone), std::wstring(L"remove Northeast, Southeast"));

        /* With nothing to add and nothing to give back, the line states what
         * the pick holds. */
        Case("a plan with nothing in it prices the pick");
        LK_EQ(PlanLine(0, 0, 930, 102760448, {}),
              std::wstring(L"930 charts, all installed · 102.8 MB to fetch again"));

        Case("the question asked before charts are deleted");
        LK_EQ(RemovalTitle({ L"Northeast" }), std::wstring(L"Remove Northeast charts?"));
        LK_EQ(RemovalTitle({ L"Northeast", L"Alaska" }),
              std::wstring(L"Remove charts for 2 regions?"));

        Case("what Apply has to do");
        LK_EQ(ApplyEnabled(true, 930, 0), true);
        LK_EQ(ApplyEnabled(true, 0, 1), true);
        LK_EQ(ApplyEnabled(true, 0, 0), false);
        LK_EQ(ApplyEnabled(false, 930, 1), false);

        /* A picker opened from the Charts pane, which is the step on its own. */
        Case("the picker's action does both halves");
        FirstRun pick;
        pick.BeginAt(FirstRunStep::Coverage);
        LK_EQ(pick.picker_only(), true);
        LK_EQ(pick.PrimaryTitle(false), std::wstring(L"Apply"));
        LK_EQ(At(FirstRunStep::Coverage).PrimaryTitle(false), std::wstring(L"Download"));

        Case("the picker's plan, beside its action");
        FirstRun::Footnotes plan{};
        plan.have_catalog = true;
        plan.cells = 930;
        plan.bytes = 102760448;
        LK_EQ(pick.Footnote(plan), std::wstring(L"Add 930 charts, 102.8 MB"));
        plan.removing = { L"Northeast" };
        LK_EQ(pick.Footnote(plan),
              std::wstring(L"Add 930 charts, 102.8 MB · remove Northeast"));

        Case("a picker giving water back and fetching none");
        FirstRun::Footnotes back{};
        back.have_catalog = true;
        back.removing = { L"Alaska" };
        LK_EQ(pick.Footnote(back), std::wstring(L"remove Alaska"));

        /* Setup asks for a region. A picker that opened on the water already
         * here has nothing to ask for. */
        Case("an untouched picker says nothing");
        FirstRun::Footnotes idle{};
        idle.have_catalog = true;
        LK_EQ(pick.Footnote(idle), std::wstring(L""));
        LK_EQ(At(FirstRunStep::Coverage).Footnote(idle),
              std::wstring(L"Pick at least one region."));

        /* What the page says when a removal is over. Every shell reports one
         * the same way, so the words are here rather than in a dialog of one
         * shell's own. */
        Case("what a removal says afterwards");
        LK_EQ(RemovalNote(930, 0), std::wstring(L"Removed 930 charts."));
        LK_EQ(RemovalNote(1, 0), std::wstring(L"Removed 1 chart."));
        LK_EQ(RemovalNote(0, 0), std::wstring(L"No downloaded charts matched that water."));

        Case("a chart something else is reading stays");
        LK_EQ(RemovalNote(928, 2),
              std::wstring(L"Removed 928 charts. 2 charts are still in use and stayed on "
                           L"the disk."));
        LK_EQ(RemovalNote(0, 1),
              std::wstring(L"1 chart is still in use and stayed on the disk."));

        /* A second download in one launch. The first run's state stayed on the
         * model, so the scan branch read a bake as already seen and no second
         * bake started. */
        Case("a second run starts with nothing of the first on it");
        FirstRun twice;
        twice.Begin();
        twice.NoteBakeStarted();
        twice.set_order(FirstRunOrder{ L"Mid-Atlantic", "d5", 930, 102760448 });
        LK_EQ(twice.saw_bake(), true);
        LK_EQ(twice.order().has_value(), true);
        twice.BeginAt(FirstRunStep::Coverage);
        LK_EQ(twice.saw_bake(), false);
        LK_EQ(twice.order().has_value(), false);
        LK_EQ(twice.shown().found, 0u);
        twice.Begin();
        LK_EQ(twice.saw_bake(), false);

        /* A bake of one or two cells finishes inside the quarter second
         * between polls, so waiting to observe one running left the step with
         * no way to know a bake had run at all. */
        Case("a bake counts as seen when it starts");
        FirstRun quick;
        quick.BeginAt(FirstRunStep::Importing);
        LK_EQ(quick.saw_bake(), false);
        quick.NoteBakeStarted();
        LK_EQ(quick.saw_bake(), true);

        /* A transfer that ends with nothing to bake leaves the step waiting
         * for work that never starts. */
        Case("a stalled import can go back");
        FirstRun dead;
        dead.Begin();
        dead.set_source(ChartSource::Noaa);
        while (dead.step() != FirstRunStep::Importing)
        {
            if (dead.showing_enc_terms())
                dead.AgreeToEncTerms();
            else
                dead.Advance();
        }
        LK_EQ(dead.CanGoBack(), false);
        dead.NoteImportStalled("every chart for those regions is already installed");
        LK_EQ(dead.import_stalled(), true);
        LK_EQ(dead.import_why(),
              std::string("every chart for those regions is already installed"));
        LK_EQ(dead.CanGoBack(), true);
        dead.Back();
        LK_EQ(dead.step(), FirstRunStep::Coverage);

        /* Setup runs when there is nothing to draw. A mariner already on an
         * online chart has something. */
        Case("a linked chart is a chart");
        LK_EQ(At(FirstRunStep::Welcome).ShouldRun(true, false), true);
        LK_EQ(At(FirstRunStep::Welcome).ShouldRun(true, true), false);
        LK_EQ(At(FirstRunStep::Welcome).ShouldRun(false, false), false);

        /* The shell passes whether a link is SELECTED. A style picked on a
         * previous launch is selected from the first frame and draws once it
         * resolves, several frames later, so a rule fed the drawing state put
         * setup over that mariner's chart at every launch. */
        Case("a link picked and not yet drawing keeps setup down");
        LK_EQ(At(FirstRunStep::Welcome).ShouldRun(true, true), false);
    }
}
