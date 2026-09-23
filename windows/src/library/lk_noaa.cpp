// Model code: no WinRT. See lk_noaa.h.
#include "lk_noaa.h"

#include <algorithm>
#include <filesystem>

namespace lkw
{
    bool NoaaService::Open(lookout_store *store, lookout_chart_sets *sets, lookout_http_get get,
                           lookout_http_cancel cancel, lookout_noaa_wake wake, void *user)
    {
        h_ = lookout_noaa_open(store, sets);
        if (h_ != nullptr)
            lookout_noaa_set_http_provider(h_, get, cancel, wake, user);
        return h_ != nullptr;
    }

    // The shell answers the fetches still queued before this, with status 0.
    void NoaaService::Close()
    {
        if (h_ == nullptr)
            return;
        lookout_noaa_set_http_provider(h_, nullptr, nullptr, nullptr, nullptr);
        lookout_noaa_close(h_);
        h_ = nullptr;
    }

    bool NoaaService::Adopt()
    {
        if (h_ == nullptr || !lookout_noaa_changed(h_))
            return false;
        lookout_noaa_poll(h_, &state_);
        return true;
    }

    // A check the core has recorded is counted once.
    bool NoaaService::TakeCheckEnd()
    {
        if (state_.update_checking || state_.update_checked_at == counted_at_)
            return false;
        counted_at_ = state_.update_checked_at;
        outdated_ = lookout_noaa_outdated(h_);
        return true;
    }

    bool NoaaService::TakeRetry()
    {
        if (!retry_waiting_ || state_.phase == LOOKOUT_NOAA_READING)
            return false;
        retry_waiting_ = false;
        return state_.have_catalog != 0;
    }

    bool NoaaService::TakeEnd()
    {
        bool const ended =
            state_.outcome != LOOKOUT_NOAA_NONE && state_.outcome != LOOKOUT_NOAA_RUNNING;
        if (watch_run_ == 0 || state_.run != watch_run_ || !ended)
            return false;
        watch_run_ = 0;
        return true;
    }

    // The run number moves by one for each order.
    void NoaaService::Order(std::string const &regions, bool again, std::string const &dest)
    {
        if (h_ == nullptr)
            return;
        std::error_code ec;
        std::filesystem::create_directories(dest, ec);
        regions_ = regions;
        again_ = again;
        retry_waiting_ = false;
        watch_run_ = state_.run + 1;
        if (regions.empty())
            lookout_noaa_update(h_, dest.c_str());
        else
            lookout_noaa_download(h_, regions.c_str(), dest.c_str(), again ? 1 : 0);
    }

    uint32_t NoaaService::Apply(std::string const &picked, bool again, std::string const &dest)
    {
        regions_ = picked;
        again_ = again;
        retry_waiting_ = false;
        watch_run_ = picked.empty() ? 0 : state_.run + 1;
        return lookout_noaa_apply(h_, picked.c_str(), dest.c_str(), again ? 1 : 0);
    }

    std::vector<std::string> NoaaService::GivesBack(std::string const &picked) const
    {
        if (h_ == nullptr)
            return {};
        char const *ids[64] = {};
        size_t const n = std::min(lookout_noaa_gives_back(h_, picked.c_str(), ids, 64),
                                  size_t{ 64 });
        return { ids, ids + n };
    }

    void NoaaService::Retry(std::string const &dest)
    {
        if (state_.have_catalog)
        {
            Order(regions_, again_, dest);
            return;
        }
        retry_waiting_ = true;
        lookout_noaa_refresh(h_);
    }

    void NoaaService::ConsiderUpdateCheck()
    {
        if (checked())
            outdated_ = lookout_noaa_outdated(h_);
        lookout_noaa_update_due(h_);
    }

    int NoaaService::UpdateCheck() const
    {
        return h_ != nullptr ? lookout_noaa_update_check(h_) : LOOKOUT_NOAA_CHECK_DAILY;
    }

    void NoaaService::SetUpdateCheck(int cadence)
    {
        if (h_ != nullptr)
            lookout_noaa_set_update_check(h_, cadence);
    }
}
