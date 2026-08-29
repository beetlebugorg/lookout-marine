/* lk_alerts — what the plugins are shouting about.
 *
 * AN ALARM IS AUDIBLE AND A WARNING IS VISIBLE. The plugins decide what is
 * dangerous; the shell only makes sure the decision reaches the helm. That
 * makes two rules worth keeping somewhere they can be checked:
 *
 *   - a severity word this shell does not know reads as an ALARM, because
 *     silence is never the fallback;
 *   - an unacknowledged alarm is audible, and looking at it is not
 *     acknowledging it.
 *
 * The strip and the siren are plugins/Alerts.cpp's.
 */
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace lkw
{
    /* 2 alarm, 1 warning, 0 notice. */
    inline constexpr int kSeverityAlarm = 2;
    inline constexpr int kSeverityWarning = 1;
    inline constexpr int kSeverityNotice = 0;

    struct Alert
    {
        unsigned long long id{ 0 };
        int severity{ kSeverityAlarm };
        std::string title;
        std::string body;
        bool acknowledged{ false };
    };

    struct AlertSet
    {
        /* The core's sequence number. The list is rebuilt only when this
         * moves, else a strip nobody is feeding flickers once a second. */
        long long seq{ -1 };
        std::vector<Alert> alerts;
    };

    /* "alarm", "warning", "notice" — and every word this shell does not know
     * reads as an alarm. */
    int ParseSeverity(std::string const &word);

    /* Read one {"seq":N,"alerts":[…]} document. Nothing when it does not
     * parse: unreadable is not "no alerts", and the caller keeps watching
     * rather than deciding the boat is safe. */
    std::optional<AlertSet> ReadAlerts(std::string_view json);

    /* Is anything still sounding? An alarm is audible until acknowledged, and
     * warnings are never counted. */
    bool AnyAudible(std::vector<Alert> const &alerts);
}
