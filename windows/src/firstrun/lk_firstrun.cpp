// Model code: no WinRT, so the flow is reachable from a test.
#include "lk_firstrun.h"

#include <cmath>
#include <cwchar>

namespace lkw
{
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

    bool ApplyEnabled(bool have_catalog, uint32_t cells, size_t removing)
    {
        return have_catalog && (cells > 0 || removing > 0);
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
                if (!f.picked && f.removing.empty())
                    return L"";
                return f.price;
            }
            // Water already here counts as picked, so a region wholly
            // installed prices as that rather than reading as an empty pick.
            if (!f.picked)
                return L"Pick at least one region.";
            return f.price;
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
