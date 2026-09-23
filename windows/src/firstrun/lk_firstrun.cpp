// Model code: no WinRT, so the flow is reachable from a test.
#include "lk_firstrun.h"

#include <cmath>
#include <cwchar>

namespace
{
    // A depth rounded to a tenth, with no trailing zero on a whole number.
    std::wstring DepthText(double v)
    {
        double const rounded = std::round(v * 10) / 10;
        wchar_t buf[32];
        if (rounded == std::round(rounded))
            std::swprintf(buf, 32, L"%d", (int)std::llround(rounded));
        else
            std::swprintf(buf, 32, L"%.1f", rounded);
        return buf;
    }
}

namespace lkw
{
    std::wstring FirstRunBandName(int band)
    {
        switch (band)
        {
        case 1: return L"Overview";
        case 2: return L"General";
        case 3: return L"Coastal";
        case 4: return L"Approach";
        case 5: return L"Harbor";
        case 6: return L"Berthing";
        default: return L"Other";
        }
    }

    std::wstring SizeText(uint64_t bytes)
    {
        // Decimal, the way NOAA states a download and the way the reference
        // shell states it back. Dividing by 2^20 read 216.0 MB for the same
        // region the Mac priced at 226.5 MB.
        wchar_t buf[64];
        if (bytes >= 1'000'000'000ull)
            std::swprintf(buf, 64, L"%.1f GB", (double)bytes / 1e9);
        else
            std::swprintf(buf, 64, L"%.1f MB", (double)bytes / 1e6);
        return buf;
    }

    std::vector<double> DepthChoice::Clearances() const
    {
        if (feet_)
            return { 1, 2, 3, 5 };
        return { 0.3, 0.6, 1, 1.5 };
    }

    std::vector<double> DepthChoice::Ladder() const
    {
        if (feet_)
            return { 6, 12, 18, 30, 60, 90, 120, 180, 240, 300 };
        return { 2, 5, 10, 20, 30, 50, 75, 100 };
    }

    double DepthChoice::SafetyDepth() const { return std::ceil(draft_ + clearance_); }

    double DepthChoice::SafetyContour() const
    {
        auto const ladder = Ladder();
        double const want = SafetyDepth();
        for (double rung : ladder)
            if (rung >= want)
                return rung;
        return ladder.back();
    }

    double DepthChoice::DeepContour() const
    {
        auto const ladder = Ladder();
        double const want = SafetyContour() * 2;
        for (double rung : ladder)
            if (rung >= want)
                return rung;
        return ladder.back();
    }

    double DepthChoice::Reach(double depth) const
    {
        // Where the shore stands, and how steeply the slope falls away.
        // Shallow water gets most of the panel, because that is where both
        // contours fall.
        constexpr double kShoreAt = 0.14;
        constexpr double kSlopeK = 2.07;
        double const floor = Floor();
        if (floor <= 0)
            return kShoreAt;
        double const share = std::max(0.0, std::min(1.0, depth / floor));
        return kShoreAt + (1 - kShoreAt) * std::pow(share, 1 / kSlopeK);
    }

    void DepthChoice::Step(int by)
    {
        double const step = StepSize();
        double const most = feet_ ? 100.0 : 30.0;
        draft_ = std::max(step, std::min(most, draft_ + step * by));
    }

    bool DepthChoice::ReadDraft(std::wstring const &text)
    {
        try
        {
            size_t used = 0;
            double v = std::stod(text, &used);
            if (v <= 0)
                return false;
            draft_ = std::min(feet_ ? 100.0 : 30.0, v);
            return true;
        }
        catch (std::exception const &)
        {
            return false;
        }
    }

    void DepthChoice::SetUnit(bool feet)
    {
        if (feet == feet_)
            return;
        double const f = feet ? 3.28084 : 1 / 3.28084;
        feet_ = feet;
        draft_ = std::round(draft_ * f * 2) / 2;
        double const want = clearance_ * f;
        auto const offered = Clearances();
        double best = offered.front();
        for (double c : offered)
            if (std::abs(c - want) < std::abs(best - want))
                best = c;
        clearance_ = best;
    }

    std::wstring DepthChoice::Measure(double v) const
    {
        return DepthText(v) + L" " + unit();
    }

    std::wstring DepthChoice::DraftText() const { return DepthText(draft_); }

    std::vector<DepthChoice::Spot> DepthChoice::Spots()
    {
        return { { 0.12, 0.28 }, { 0.30, 0.68 }, { 0.45, 0.14 }, { 0.62, 0.50 },
                 { 0.80, 0.84 }, { 1.00, 0.32 }, { 1.22, 0.62 }, { 1.48, 0.20 },
                 { 1.78, 0.44 }, { 2.12, 0.78 }, { 2.50, 0.34 }, { 2.85, 0.58 } };
    }

    bool RegionPicked(std::string const &list, std::string const &id)
    {
        if (id.empty())
            return false;
        for (size_t at = 0; at < list.size();)
        {
            size_t end = list.find(',', at);
            if (end == std::string::npos)
                end = list.size();
            if (list.compare(at, end - at, id) == 0)
                return true;
            at = end + 1;
        }
        return false;
    }

    std::string RegionToggle(std::string const &list, std::string const &id)
    {
        if (id.empty())
            return list;
        std::string out;
        bool found = false;
        for (size_t at = 0; at < list.size();)
        {
            size_t end = list.find(',', at);
            if (end == std::string::npos)
                end = list.size();
            std::string one = list.substr(at, end - at);
            at = end + 1;
            if (one.empty())
                continue;
            if (one == id)
            {
                found = true; // dropped: this is what makes it a toggle
                continue;
            }
            out += (out.empty() ? "" : ",") + one;
        }
        if (!found)
            out += (out.empty() ? "" : ",") + id;
        return out;
    }

    std::wstring RegionBadge(RegionHold const &hold)
    {
        // Whole regions only. NOAA files cells across district lines, so
        // downloading one region installs some of its neighbour's, and a
        // fraction on the pill ("42 of 1,045") reads as a transfer that
        // stopped part way. The count is still in the pill's name, which a
        // screen reader states.
        return hold.Complete() ? L"installed" : L"";
    }

    std::wstring RegionLabel(std::wstring const &name, std::wstring const &blurb,
                             RegionHold const &hold)
    {
        std::wstring s = name + L". " + blurb;
        if (!hold.Known())
            return s;
        if (hold.Complete())
            return s + L". All " + Thousands(hold.held) + L" charts installed.";
        if (hold.Partial())
            return s + L". " + Thousands(hold.held) + L" of " + Thousands(hold.Total()) +
                   L" charts installed.";
        return s + L". " + Thousands(hold.Total()) + L" charts, none installed.";
    }

    std::wstring CostLine(uint32_t cells, uint64_t bytes, uint32_t held, uint64_t held_bytes)
    {
        if (cells == 0 && held > 0)
            return Thousands(held) + L" charts, all installed · " + SizeText(held_bytes) +
                   L" to fetch again";
        std::wstring s = Thousands(cells) + L" charts, " + SizeText(bytes);
        if (held > 0)
            s += L" · " + Thousands(held) + L" already installed";
        return s;
    }

    std::vector<std::string> Removed(std::string const &held, std::string const &picked)
    {
        std::vector<std::string> out;
        for (size_t at = 0; at < held.size();)
        {
            size_t end = held.find(',', at);
            if (end == std::string::npos)
                end = held.size();
            std::string one = held.substr(at, end - at);
            at = end + 1;
            if (!one.empty() && !RegionPicked(picked, one))
                out.push_back(one);
        }
        return out;
    }

    std::wstring PlanLine(uint32_t cells, uint64_t bytes, uint32_t held, uint64_t held_bytes,
                          std::vector<std::wstring> const &removing)
    {
        std::wstring s;
        if (cells > 0)
            s = L"Add " + Thousands(cells) + L" charts, " + SizeText(bytes);
        if (!removing.empty())
        {
            std::wstring names;
            for (auto const &n : removing)
                names += (names.empty() ? L"" : L", ") + n;
            s += (s.empty() ? L"" : L" · ") + (L"remove " + names);
        }
        return s.empty() ? CostLine(cells, bytes, held, held_bytes) : s;
    }

    std::wstring RemovalTitle(std::vector<std::wstring> const &removing)
    {
        if (removing.size() == 1)
            return L"Remove " + removing[0] + L" charts?";
        return L"Remove charts for " + Thousands(removing.size()) + L" regions?";
    }

    bool ApplyEnabled(bool have_catalog, uint32_t cells, size_t removing)
    {
        return have_catalog && (cells > 0 || removing > 0);
    }

    std::wstring PrepareEstimate(size_t charts)
    {
        double seconds = (double)(charts < 1 ? 1 : charts) * 0.2;
        if (seconds < 60)
            return L"under a minute";
        wchar_t buf[64];
        if (seconds < 3600)
        {
            int minutes = (int)(seconds / 60.0 + 0.5);
            if (minutes <= 1)
                return L"about a minute";
            std::swprintf(buf, 64, L"about %d minutes", minutes);
            return buf;
        }
        std::swprintf(buf, 64, L"about %.1f hours", seconds / 3600.0);
        return buf;
    }

    std::wstring RemovalNote(size_t removed, size_t failed)
    {
        if (removed == 0 && failed == 0)
            return L"No downloaded charts matched that water.";
        std::wstring s;
        if (removed != 0)
            s = L"Removed " + Thousands(removed) +
                (removed == 1 ? L" chart" : L" charts") + L".";
        if (failed != 0)
        {
            if (!s.empty())
                s += L" ";
            s += Thousands(failed) + (failed == 1 ? L" chart is" : L" charts are") +
                 L" still in use and stayed on the disk.";
        }
        return s;
    }

    std::wstring Thousands(uint64_t n)
    {
        std::wstring s = std::to_wstring(n);
        for (int i = (int)s.size() - 3; i > 0; i -= 3)
            s.insert((size_t)i, L",");
        return s;
    }

    std::wstring FirstRun::Title() const
    {
        switch (step())
        {
        case FirstRunStep::Welcome:     return L"Welcome";
        case FirstRunStep::Source:      return L"Add charts";
        case FirstRunStep::Coverage:    return L"Coverage";
        case FirstRunStep::OnlineChart: return L"Online chart";
        case FirstRunStep::Importing:   return L"Preparing";
        case FirstRunStep::Depths:      return L"Depths";
        }
        return L"";
    }

    std::wstring FirstRun::PrimaryTitle(bool has_chart) const
    {
        switch (step())
        {
        case FirstRunStep::Welcome:
        case FirstRunStep::Source:      return L"Continue";
        // A picker opened from the Charts pane does both halves at once, so
        // its action is Apply rather than Download.
        case FirstRunStep::Coverage:    return picker_only() ? L"Apply" : L"Download";
        case FirstRunStep::OnlineChart: return has_chart ? L"Continue" : L"Skip";
        case FirstRunStep::Importing:   return L"Continue";
        case FirstRunStep::Depths:      return L"Start Sailing";
        }
        return L"Continue";
    }

    std::wstring FirstRun::Footnote(Footnotes const &f) const
    {
        switch (step())
        {
        case FirstRunStep::Welcome:
        case FirstRunStep::Source:
        case FirstRunStep::Importing:
            return L"";
        case FirstRunStep::Coverage:
            if (!f.have_catalog)
                return L"";
            if (picker_only())
            {
                // A picker states a plan: what is being fetched, what is being
                // given back, or what the pick holds. With nothing ticked and
                // nothing unticked it has nothing to say.
                if (f.cells == 0 && f.held == 0 && f.removing.empty())
                    return L"";
                return PlanLine(f.cells, f.bytes, f.held, f.held_bytes, f.removing);
            }
            // Water already here counts as picked, so a region wholly
            // installed prices as that rather than reading as an empty pick.
            if (f.cells == 0 && f.held == 0)
                return L"Pick at least one region.";
            return CostLine(f.cells, f.bytes, f.held, f.held_bytes);
        case FirstRunStep::Depths:
            return L"Change any of this later in Mariner settings, in Depths.";
        case FirstRunStep::OnlineChart:
        {
            // The credit a public tile host makes a condition of service, and
            // the thing a mariner about to pick a link most wants to know. An
            // install with no charts has none to reassure them about.
            std::wstring s = f.credit;
            if (f.have_charts)
            {
                if (!s.empty())
                    s += L" · ";
                s += L"installed charts stay installed";
            }
            return s;
        }
        }
        return L"";
    }

    void FirstRun::Observe(FirstRunLive const &live)
    {
        // Whether each service is working stays live. The spinners and the
        // Stop button read these flags, and a stale "still running" leaves
        // the page spinning over finished work.
        shown_.downloading = live.downloading;
        shown_.baking      = live.baking;

        // The counts are latched. A reading with no total means the service
        // reset behind its own completion.
        if (live.expected > 0)
        {
            shown_.fetched  = live.fetched;
            shown_.expected = live.expected;
        }
        if (live.found > 0)
        {
            shown_.found = live.found;
            shown_.baked = live.baked;
        }
        // The bands latch the same way, and as a whole. A reading with none
        // is the bake's last state.
        if (!live.bands.empty())
            shown_.bands = live.bands;
    }

    uint32_t FirstRun::expected() const
    {
        if (shown_.expected > 0)
            return shown_.expected;
        return order_.has_value() ? order_->charts : 0;
    }

    double FirstRun::Fraction() const
    {
        // The transfer is the first 35% and the bake the remaining 65%. The
        // bake is the longer of the two. A bar giving them half each stays
        // at 50% for most of the wait.
        constexpr double kFetchShare = 0.35;

        uint32_t const want = expected();
        if (shown_.downloading && want > 0)
            return static_cast<double>(shown_.fetched) / want * kFetchShare;

        if (shown_.baking && shown_.found > 0)
            return kFetchShare +
                   static_cast<double>(shown_.baked) / shown_.found * (1.0 - kFetchShare);

        // Finished. Work was seen and is no longer running. saw_work is what
        // separates this from the state before anything started.
        if (state_.saw_work && !shown_.baking)
            return 1.0;

        return 0.0;
    }
}
