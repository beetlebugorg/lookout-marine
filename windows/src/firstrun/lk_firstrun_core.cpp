// The parts of the setup model that call the core: the formatters, the words
// built from them, and the depth plan. Compiled into the app only. The model
// suite links no core, and the core's own tests cover these formatters.
#include "lk_firstrun.h"

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace
{
    std::wstring Wide(char const *s, size_t n)
    {
        std::wstring out(n, L'\0');
        int const got = MultiByteToWideChar(CP_UTF8, 0, s, (int)n, out.data(), (int)n);
        out.resize(got > 0 ? (size_t)got : 0);
        return out;
    }

    std::wstring Depth(double v_m, int unit)
    {
        char buf[LOOKOUT_DEPTH_MAX];
        return Wide(buf, lookout_fmt_depth(v_m, unit, buf, sizeof buf));
    }
}

namespace lkw
{
    std::wstring FirstRunBandName(int band)
    {
        char const *name = lookout_usage_band_name(band);
        return Wide(name, std::strlen(name));
    }

    std::wstring SizeText(uint64_t bytes)
    {
        char buf[LOOKOUT_BYTES_MAX];
        return Wide(buf, lookout_fmt_bytes(bytes, buf, sizeof buf));
    }

    std::wstring Thousands(uint64_t n)
    {
        char buf[LOOKOUT_COUNT_MAX];
        return Wide(buf, lookout_fmt_count(n, buf, sizeof buf));
    }

    // About a fifth of a second a chart, measured over a mixed Chesapeake set.
    std::wstring PrepareEstimate(size_t charts)
    {
        char buf[LOOKOUT_DURATION_MAX];
        double const seconds = (double)(charts < 1 ? 1 : charts) * 0.2;
        return Wide(buf, lookout_fmt_duration(seconds, LOOKOUT_DURATION_ABOUT, buf, sizeof buf));
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

    DepthChoice::DepthChoice(bool feet) : feet_(feet)
    {
        Plan();
        draft_m_ = plan_.draft_m;
        clearance_m_ = plan_.clearance_m;
    }

    void DepthChoice::Plan() { lookout_depth_plan(draft_m_, clearance_m_, feet_ ? 1 : 0, &plan_); }

    struct ::lookout_depth_preview DepthChoice::Preview() const
    {
        struct ::lookout_depth_preview out{};
        lookout_depth_preview(&plan_, &out);
        return out;
    }

    // One step of the draft field. The plan holds the draft between one step
    // and the most the step accepts. Zero is the core's starting boat, so the
    // step stops at one press above it.
    void DepthChoice::Step(int by)
    {
        double const step = plan_.draft_step;
        draft_m_ = std::max(step, plan_.draft + step * by) * plan_.metres_per_unit;
        Plan();
        draft_m_ = plan_.draft_m;
    }

    bool DepthChoice::ReadDraft(std::wstring const &text)
    {
        try
        {
            double const v = std::stod(text);
            if (v <= 0)
                return false;
            draft_m_ = v * plan_.metres_per_unit;
            Plan();
            draft_m_ = plan_.draft_m;
            return true;
        }
        catch (std::exception const &)
        {
            return false;
        }
    }

    void DepthChoice::set_clearance(double c)
    {
        clearance_m_ = c * plan_.metres_per_unit;
        Plan();
    }

    // The core rounds the draft to the nearest half unit and snaps the
    // clearance to one the new unit offers.
    void DepthChoice::SetUnit(bool feet)
    {
        if (feet == feet_)
            return;
        feet_ = feet;
        Plan();
        draft_m_ = plan_.draft_rounded_m;
        clearance_m_ = plan_.clearance_m;
        Plan();
    }

    std::wstring DepthChoice::Measure(double v) const
    {
        return Depth(v * plan_.metres_per_unit, feet_ ? LOOKOUT_DEPTH_FEET : LOOKOUT_DEPTH_METRES);
    }

    std::wstring DepthChoice::DraftText() const
    {
        return Depth(draft_m_, (feet_ ? LOOKOUT_DEPTH_FEET : LOOKOUT_DEPTH_METRES) |
                                   LOOKOUT_DEPTH_BARE);
    }
}
