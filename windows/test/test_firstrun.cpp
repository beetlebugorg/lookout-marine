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
    /* A flow parked on the step a case is about, as the core's setup state
     * reads there. */
    FirstRun At(FirstRunStep want, ChartSource src = ChartSource::Noaa, bool picker = false)
    {
        FirstRun f;
        lookout_setup_state s{};
        s.step        = static_cast<uint8_t>(want);
        s.showing     = 1;
        s.picker_only = picker ? 1 : 0;
        f.Read(s);
        f.set_source(src);
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
        b.done  = done;
        b.total = total;
        return b;
    }
}

void TestFirstRun()
{
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
        lookout_setup_state seen{};
        seen.step     = static_cast<uint8_t>(FirstRunStep::Importing);
        seen.showing  = 1;
        seen.saw_work = 1;
        f.Read(seen);
        f.Observe(FirstRunLive{});
        LK_EQ(f.Fraction(), 1.0);
    }

    /* What the primary button can do on the step showing. */
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

        Case("the coverage step prices the pick beside the action");
        FirstRun::Footnotes cov{};
        cov.have_catalog = true;
        cov.picked = true;
        cov.price = L"930 charts, 102.8 MB";
        LK_EQ(At(FirstRunStep::Coverage).Footnote(cov), std::wstring(L"930 charts, 102.8 MB"));

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

        Case("what Apply has to do");
        LK_EQ(ApplyEnabled(true, 930, 0), true);
        LK_EQ(ApplyEnabled(true, 0, 1), true);
        LK_EQ(ApplyEnabled(true, 0, 0), false);
        LK_EQ(ApplyEnabled(false, 930, 1), false);

        /* A picker opened from the Charts pane, which is the step on its own. */
        Case("the picker's action does both halves");
        FirstRun pick = At(FirstRunStep::Coverage, ChartSource::Noaa, true);
        LK_EQ(pick.picker_only(), true);
        LK_EQ(pick.PrimaryTitle(false), std::wstring(L"Apply"));
        LK_EQ(At(FirstRunStep::Coverage).PrimaryTitle(false), std::wstring(L"Download"));

        Case("the picker's plan, beside its action");
        FirstRun::Footnotes plan{};
        plan.have_catalog = true;
        plan.picked = true;
        plan.price = L"Add 930 charts, 102.8 MB";
        LK_EQ(pick.Footnote(plan), std::wstring(L"Add 930 charts, 102.8 MB"));

        Case("a picker giving water back and fetching none");
        FirstRun::Footnotes back{};
        back.have_catalog = true;
        back.removing = { L"Alaska" };
        back.price = L"remove Alaska";
        LK_EQ(pick.Footnote(back), std::wstring(L"remove Alaska"));

        /* Setup asks for a region. A picker that opened on the water already
         * here has nothing to ask for. */
        Case("an untouched picker says nothing");
        FirstRun::Footnotes idle{};
        idle.have_catalog = true;
        LK_EQ(pick.Footnote(idle), std::wstring(L""));
        LK_EQ(At(FirstRunStep::Coverage).Footnote(idle),
              std::wstring(L"Pick at least one region."));

        /* A second download in one launch. The first run's counts stayed on
         * the model and the page drew them over the new run. */
        Case("a second run starts with nothing of the first on it");
        FirstRun twice = At(FirstRunStep::Importing);
        twice.set_order(FirstRunOrder{ L"Mid-Atlantic", "d5", 930, 102760448 });
        twice.Observe(Baking(3, 9));
        LK_EQ(twice.order().has_value(), true);
        twice.Restart();
        LK_EQ(twice.order().has_value(), false);
        LK_EQ(twice.shown().found, 0u);
    }
}
