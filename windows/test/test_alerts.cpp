/* Plugin alerts.
 *
 * The rule this covers is a safety rule, not a display rule: an alarm keeps
 * sounding until somebody acknowledges it. The severity itself is the core's
 * (lookout_alert_severity), and so is the order the strip draws.
 */
#include "lk_test.h"

#include "lk_alerts.h"

using namespace lktest;
using namespace lkw;

namespace
{
    lookout_alert Raised(unsigned long long id, lookout_alert_severity severity,
                         char const *title, char const *body, int acknowledged)
    {
        lookout_alert a{};
        a.id = id;
        a.plugin = "org.beetlebug.ais";
        a.title = title;
        a.body = body;
        a.severity = severity;
        a.acknowledged = acknowledged;
        a.raised = 1754700000000;
        return a;
    }
}

void TestAlerts()
{
    Suite("lk_alerts");

    LK_CASE("an alert the core raised");
    {
        lookout_alert raw = Raised(1, LOOKOUT_ALERT_ALARM, "CPA 0.1 nm",
                                   "MMSI 899000101", 0);
        Alert a{ raw };
        LK_EQ(a.id, (unsigned long long)1);
        LK_EQ(a.severity, LOOKOUT_ALERT_ALARM);
        LK_EQ(a.title, std::string("CPA 0.1 nm"));
        LK_EQ(a.body, std::string("MMSI 899000101"));
        LK_EQ(a.acknowledged, false);
    }

    LK_CASE("an acknowledged alert stays acknowledged");
    {
        Alert a{ Raised(2, LOOKOUT_ALERT_WARNING, "Depth", "Under safety contour", 1) };
        LK_EQ(a.severity, LOOKOUT_ALERT_WARNING);
        LK_EQ(a.acknowledged, true);
    }

    /* Looking at it is not acknowledging it. */
    LK_CASE("an alarm is audible until it is acknowledged");
    {
        std::vector<Alert> none;
        LK_EQ(AnyAudible(none), false);

        Alert alarm;
        alarm.severity = LOOKOUT_ALERT_ALARM;
        LK_EQ(AnyAudible({ alarm }), true);

        alarm.acknowledged = true;
        LK_EQ(AnyAudible({ alarm }), false);
    }

    LK_CASE("a warning is never audible");
    {
        Alert warning;
        warning.severity = LOOKOUT_ALERT_WARNING;
        Alert notice;
        notice.severity = LOOKOUT_ALERT_NOTICE;
        LK_EQ(AnyAudible({ warning, notice }), false);
    }

    LK_CASE("one unacknowledged alarm among many acknowledged ones still sounds");
    {
        Alert done;
        done.severity = LOOKOUT_ALERT_ALARM;
        done.acknowledged = true;
        Alert live;
        live.severity = LOOKOUT_ALERT_ALARM;
        LK_EQ(AnyAudible({ done, done, live, done }), true);
    }

    /* An alert with no severity set is an alarm: silence is never the
     * fallback, and the shell's own default holds where the core said
     * nothing. */
    LK_CASE("an alert this shell built itself sounds");
    {
        Alert bare;
        LK_EQ(bare.severity, LOOKOUT_ALERT_ALARM);
        LK_EQ(AnyAudible({ bare }), true);
    }
}
