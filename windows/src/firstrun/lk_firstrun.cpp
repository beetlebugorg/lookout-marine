// Model code: no WinRT, so the flow is reachable from a test.
#include "lk_firstrun.h"

#include <cwchar>
#include <map>

namespace
{
    // A chart with no usage band sorts after band 6, so it goes last in the
    // bake and last in the list. Sorting it as band 0 puts it first.
    constexpr int kNoBand = 7;
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
        wchar_t buf[64];
        if (bytes >= (uint64_t{ 1 } << 30))
            std::swprintf(buf, 64, L"%.1f GB", (double)bytes / (double)(uint64_t{ 1 } << 30));
        else
            std::swprintf(buf, 64, L"%.1f MB", (double)bytes / (double)(1u << 20));
        return buf;
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

    std::wstring Thousands(uint64_t n)
    {
        std::wstring s = std::to_wstring(n);
        for (int i = (int)s.size() - 3; i > 0; i -= 3)
            s.insert((size_t)i, L",");
        return s;
    }

    std::vector<FirstRunBand> FirstRunBands(std::vector<int> const &band_of_each_chart,
                                            uint32_t done)
    {
        // Count the charts per band. A band with none never appears. An
        // empty "Berthing 0 of 0" row reads as work that failed.
        std::map<int, uint32_t> total;
        for (int b : band_of_each_chart)
            ++total[b == 0 ? kNoBand : b];

        // Ascending band order is the bake's order. Walking the sorted map
        // and drawing from `done` gives each band the charts the bake
        // finished.
        std::vector<FirstRunBand> out;
        out.reserve(total.size());
        uint32_t left = done;
        for (auto const &[band, n] : total)
        {
            FirstRunBand b;
            b.band  = band == kNoBand ? 0 : band;
            b.name  = FirstRunBandName(b.band);
            b.total = n;
            b.done  = left >= n ? n : left;
            left -= b.done;
            out.push_back(std::move(b));
        }
        return out;
    }

    void FirstRun::Back()
    {
        switch (step_)
        {
        case FirstRunStep::Source:
            step_ = FirstRunStep::Welcome;
            break;
        case FirstRunStep::Coverage:
        case FirstRunStep::OnlineChart:
            step_ = FirstRunStep::Source;
            break;
        default:
            // Importing and Depths have no way back. The charts are already
            // arriving by then.
            break;
        }
    }

    std::optional<ChartSource> FirstRun::Advance()
    {
        switch (step_)
        {
        case FirstRunStep::Welcome:
            step_ = FirstRunStep::Source;
            return std::nullopt;

        case FirstRunStep::Source:
            switch (source_)
            {
            case ChartSource::Noaa:
                // NOAA's terms apply to NOAA's charts, so they are asked where
                // those charts are chosen. The step stays put here.
                // AgreeToEncTerms moves it. A mariner who picks an online
                // chart or their own files downloads no ENC and is asked to
                // accept none.
                showing_enc_terms_ = true;
                return std::nullopt;
            case ChartSource::Online:
                step_ = FirstRunStep::OnlineChart;
                return std::nullopt;
            case ChartSource::Files:
                // The flow has finished asking. The shell raises its picker
                // and setup closes.
                Finish();
                return ChartSource::Files;
            }
            return std::nullopt;

        case FirstRunStep::Coverage:
            step_ = FirstRunStep::Importing;
            return ChartSource::Noaa;

        case FirstRunStep::OnlineChart:
            step_ = FirstRunStep::Depths;
            return ChartSource::Online;

        case FirstRunStep::Importing:
            // One step opened on its own ends here. The mariner set their
            // depths when they first set the app up.
            if (picker_only_)
                Finish();
            else
                step_ = FirstRunStep::Depths;
            return std::nullopt;

        case FirstRunStep::Depths:
            Finish();
            return std::nullopt;
        }
        return std::nullopt;
    }

    void FirstRun::Finish()
    {
        put_away_    = true;
        showing_     = false;
        step_        = FirstRunStep::Welcome;
        picker_only_ = false;
    }

    std::wstring FirstRun::Title() const
    {
        switch (step_)
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
        switch (step_)
        {
        case FirstRunStep::Welcome:
        case FirstRunStep::Source:      return L"Continue";
        case FirstRunStep::Coverage:    return L"Download";
        case FirstRunStep::OnlineChart: return has_chart ? L"Continue" : L"Skip";
        case FirstRunStep::Importing:   return L"Continue";
        case FirstRunStep::Depths:      return L"Start Sailing";
        }
        return L"Continue";
    }

    void FirstRun::Observe(FirstRunLive const &live)
    {
        // Whether each service is working stays live. The spinners and the
        // Stop button read these flags, and a stale "still running" leaves
        // the page spinning over finished work.
        shown_.downloading = live.downloading;
        shown_.baking      = live.baking;
        if (live.baking)
            saw_bake_ = true;

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

        // Finished. A bake was seen and is no longer running. saw_bake_ is
        // what separates this from the state before anything started.
        if (saw_bake_ && !shown_.baking)
            return 1.0;

        return 0.0;
    }
}
