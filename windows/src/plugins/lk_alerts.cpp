/* lk_alerts — see lk_alerts.h. */
#include "lk_alerts.h"

namespace lkw
{
    Alert::Alert(lookout_alert const &a)
        : id{ (unsigned long long)a.id }, severity{ a.severity }, title{ a.title },
          body{ a.body }, acknowledged{ a.acknowledged != 0 }
    {
    }

    bool AnyAudible(std::vector<Alert> const &alerts)
    {
        for (auto const &a : alerts)
            if (a.severity >= LOOKOUT_ALERT_ALARM && !a.acknowledged)
                return true;
        return false;
    }
}
