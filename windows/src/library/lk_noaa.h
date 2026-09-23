/* lk_noaa: the NOAA service (lookout_noaa) as the window holds it, with the
 * state as last read, the order it follows to its end, a retry waiting on a
 * catalog read, and the update check. What the shell does at each of those
 * moments stays in the shell. */
#pragma once

#include <lookout-library.h>

#include <cstdint>
#include <string>

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

        /* Adopt the responses, and read the state when it changed. True when
         * it changed. */
        bool Adopt();
        /* Each of these is true once, for the moment it names. */
        /* The update check's catalog read ended. outdated() holds the count. */
        bool TakeCheckEnd();
        /* The catalog read a retry waits on ended with a catalog. The caller
         * repeats the order. A read that ends with none drops the retry. */
        bool TakeRetry();
        /* The order being followed ended. state() holds how. */
        bool TakeEnd();

        /* Order a download of `regions` into `dest`, or an update of the
         * downloaded cells when `regions` is empty, and follow its run. */
        void Order(std::string const &regions, bool again, std::string const &dest);
        /* lookout_noaa_apply, following the run it orders. An empty pick
         * orders none. Returns how many directories left the library. */
        uint32_t Apply(std::string const &picked, bool again, std::string const &dest);
        /* Repeat the last order into `dest`. With no catalog loaded this
         * reads the catalog first, and TakeRetry returns true when it ends. */
        void Retry(std::string const &dest);

        /* Start the update check when lookout_noaa_update_due starts one.
         * After a check has run, the count follows the sets. */
        void ConsiderUpdateCheck();
        bool checking() const { return checking_; }
        bool checked() const { return checked_; }
        uint32_t outdated() const { return outdated_; }

    private:
        lookout_noaa      *h_{ nullptr };
        lookout_noaa_state state_{};
        /* The run of the order being followed, 0 for none, and the order. */
        uint32_t    watch_run_{ 0 };
        std::string regions_;
        bool        again_{ false };
        bool        retry_waiting_{ false };
        bool        checking_{ false };
        bool        checked_{ false };
        uint32_t    outdated_{ 0 };
    };
}
