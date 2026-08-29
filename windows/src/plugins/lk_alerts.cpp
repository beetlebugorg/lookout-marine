/* lk_alerts — see lk_alerts.h. */
#include "lk_alerts.h"

#include "lk_json.h"

namespace lkw
{
    int ParseSeverity(std::string const &word)
    {
        if (word == "notice")
            return kSeverityNotice;
        if (word == "warning")
            return kSeverityWarning;
        /* "alarm", and every word this shell does not know: silence is never
         * the fallback. */
        return kSeverityAlarm;
    }

    std::optional<AlertSet> ReadAlerts(std::string_view json)
    {
        auto doc = json::Parse(json);
        if (!doc || doc->kind() != json::Kind::Object)
            return std::nullopt;

        AlertSet set;
        set.seq = (long long)doc->MemberNumber("seq", 0);
        for (auto const &v : (*doc)["alerts"].Items())
        {
            if (v.kind() != json::Kind::Object)
                continue;
            Alert a;
            a.id = (unsigned long long)v.MemberNumber("id", 0);
            a.severity = ParseSeverity(v.MemberString("severity"));
            a.title = v.MemberString("title");
            a.body = v.MemberString("body");
            a.acknowledged = v.MemberBool("acknowledged", false);
            set.alerts.push_back(std::move(a));
        }
        return set;
    }

    bool AnyAudible(std::vector<Alert> const &alerts)
    {
        for (auto const &a : alerts)
            if (a.severity >= kSeverityAlarm && !a.acknowledged)
                return true;
        return false;
    }
}
