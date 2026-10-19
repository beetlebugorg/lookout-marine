/* lk_noaa: the NOAA service (lookout_noaa) as the window holds it, with the
 * state as last read, the order it follows to its end, a retry waiting on a
 * catalog read, and the update check. What the shell does at each of those
 * moments stays in the shell. */
#pragma once

#include <lookout-library.h>

#include <cstdint>
#include <string>
#include <vector>

namespace lkw
{
    class NoaaService
    {
    public:
        /* Open for the life of the window. The fetcher and the wake are the
         * shell's. False when the service cannot be allocated. */
        bool Open(lookout_store *store, lookout_chart_sets *sets, lookout_http_get get,
                  lookout_http_cancel cancel, lookout_noaa_wake wake, void *user);
        void Close();
        lookout_noaa *handle() const { return h_; }
        /* The state as of the last Adopt that returned true. */
        lookout_noaa_state const &state() const { return state_; }

        /* True when the state changed and was read. */
        bool Adopt();
        /* Each of these is true once, for the moment it names. */
        /* The core recorded an update check. outdated() holds the count. */
        bool TakeCheckEnd();
        /* The catalog read a retry waits on ended with a catalog. The caller
         * repeats the order. A read that ends with none drops the retry. */
        bool TakeRetry();
        /* The order being followed ended. state() holds how. */
        bool TakeEnd();

        /* An empty `regions` orders an update of the downloaded cells. */
        void Order(std::string const &regions, bool again, std::string const &dest);
        /* An empty pick orders no run. Returns how many directories left
         * the library. */
        uint32_t Apply(std::string const &picked, bool again, std::string const &dest);
        /* The region ids an apply of `picked` gives back, as the core names
         * them. */
        std::vector<std::string> GivesBack(std::string const &picked) const;
        /* Repeat the last order into `dest`. With no catalog loaded this
         * reads the catalog first, and TakeRetry returns true when it ends. */
        void Retry(std::string const &dest);

        /* Start the update check when lookout_noaa_update_due starts one.
         * After a check has been recorded, the count follows the sets. */
        void ConsiderUpdateCheck();
        bool checking() const { return state_.update_checking != 0; }
        bool checked() const { return state_.update_checked_at != 0; }
        uint32_t outdated() const { return outdated_; }
        /* How often the check runs, as LOOKOUT_NOAA_CHECK_*. */
        int UpdateCheck() const;
        void SetUpdateCheck(int cadence);

    private:
        lookout_noaa      *h_{ nullptr };
        lookout_noaa_state state_{};
        /* The run of the order being followed, 0 for none, and the order. */
        uint32_t    watch_run_{ 0 };
        std::string regions_;
        bool        again_{ false };
        bool        retry_waiting_{ false };
        /* The recorded check outdated_ was counted after. */
        int64_t     counted_at_{ 0 };
        uint32_t    outdated_{ 0 };
    };
}
