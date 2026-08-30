/* Plugin alerts.
 *
 * The two rules this covers are safety rules, not display rules: a severity
 * this shell cannot read must sound, and an alarm must keep sounding until
 * somebody acknowledges it. Everything else about the strip is layout.
 */
#include "lk_test.h"

#include "lk_alerts.h"

using namespace lktest;
using namespace lkw;

void TestAlerts()
{
    Suite("lk_alerts");

    LK_CASE("the severity words");
    {
        LK_EQ(ParseSeverity("notice"), kSeverityNotice);
        LK_EQ(ParseSeverity("warning"), kSeverityWarning);
        LK_EQ(ParseSeverity("alarm"), kSeverityAlarm);
    }

    /* Silence is never the fallback. */
    LK_CASE("a severity this shell does not know is an alarm");
    {
        LK_EQ(ParseSeverity(""), kSeverityAlarm);
        LK_EQ(ParseSeverity("critical"), kSeverityAlarm);
        LK_EQ(ParseSeverity("Warning"), kSeverityAlarm); /* the core writes lower case */
    }

    LK_CASE("a list of alerts");
    {
        auto set = ReadAlerts(R"({"seq":7,"alerts":[
            {"id":1,"severity":"alarm","title":"CPA 0.1 nm","body":"MMSI 899000101"},
            {"id":2,"severity":"warning","title":"Depth","body":"Under safety contour",
             "acknowledged":true},
            {"id":3,"severity":"notice","title":"Chart","body":"New edition"}]})");
        LK_CHECK(set.has_value());
        if (!set)
            return;
        LK_EQ(set->seq, (long long)7);
        LK_EQ(set->alerts.size(), (size_t)3);
        LK_EQ(set->alerts[0].id, (unsigned long long)1);
        LK_EQ(set->alerts[0].severity, kSeverityAlarm);
        LK_EQ(set->alerts[0].title, std::string("CPA 0.1 nm"));
        LK_EQ(set->alerts[0].body, std::string("MMSI 899000101"));
        LK_EQ(set->alerts[0].acknowledged, false);
        LK_EQ(set->alerts[1].acknowledged, true);
        LK_EQ(set->alerts[2].severity, kSeverityNotice);
    }

    LK_CASE("an alert with nothing said about it still sounds");
    {
        auto set = ReadAlerts(R"({"seq":1,"alerts":[{"id":9}]})");
        LK_CHECK(set.has_value());
        if (set)
        {
            LK_EQ(set->alerts[0].severity, kSeverityAlarm);
            LK_EQ(set->alerts[0].acknowledged, false);
        }
    }

    LK_CASE("an entry that is not an object is skipped");
    {
        auto set = ReadAlerts(R"({"seq":1,"alerts":[{"id":1},"junk",5]})");
        LK_CHECK(set.has_value());
        if (set)
            LK_EQ(set->alerts.size(), (size_t)1);
    }

    LK_CASE("no alerts is a readable answer");
    {
        auto set = ReadAlerts(R"({"seq":3,"alerts":[]})");
        LK_CHECK(set.has_value());
        if (set)
        {
            LK_EQ(set->seq, (long long)3);
            LK_EQ(set->alerts.size(), (size_t)0);
        }
        /* And so is a document with no list at all. */
        LK_CHECK(ReadAlerts(R"({"seq":3})").has_value());
    }

    /* Unreadable is not "no alerts": the caller keeps watching rather than
     * deciding the boat is safe. */
    LK_CASE("an unreadable answer is not an empty one");
    {
        LK_CHECK(!ReadAlerts("").has_value());
        LK_CHECK(!ReadAlerts("not json").has_value());
        LK_CHECK(!ReadAlerts("[]").has_value());
        LK_CHECK(!ReadAlerts("{\"seq\":1,").has_value());
    }

    /* Looking at it is not acknowledging it. */
    LK_CASE("an alarm is audible until it is acknowledged");
    {
        std::vector<Alert> none;
        LK_EQ(AnyAudible(none), false);

        Alert alarm;
        alarm.severity = kSeverityAlarm;
        LK_EQ(AnyAudible({ alarm }), true);

        alarm.acknowledged = true;
        LK_EQ(AnyAudible({ alarm }), false);
    }

    LK_CASE("a warning is never audible");
    {
        Alert warning;
        warning.severity = kSeverityWarning;
        Alert notice;
        notice.severity = kSeverityNotice;
        LK_EQ(AnyAudible({ warning, notice }), false);
    }

    LK_CASE("one unacknowledged alarm among many acknowledged ones still sounds");
    {
        Alert done;
        done.severity = kSeverityAlarm;
        done.acknowledged = true;
        Alert live;
        live.severity = kSeverityAlarm;
        LK_EQ(AnyAudible({ done, done, live, done }), true);
    }
}
