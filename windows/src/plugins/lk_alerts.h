/* lk_alerts — what the plugins are shouting about.
 *
 * AN ALARM IS AUDIBLE AND A WARNING IS VISIBLE. The plugins decide what is
 * dangerous; the shell only makes sure the decision reaches the helm. The core
 * hands the set over as structs (lookout_alerts_read), severity included, so
 * the one rule left here is the one the siren turns on:
 *
 *   an unacknowledged alarm is audible, and looking at it is not
 *   acknowledging it.
 *
 * The strip and the siren are plugins/ui/Alerts.cpp's.
 */
#pragma once

#include <string>
#include <vector>

#include "lookout.h"

namespace lkw
{
    struct Alert
    {
        unsigned long long id{ 0 };
        lookout_alert_severity severity{ LOOKOUT_ALERT_ALARM };
        std::string title;
        std::string body;
        bool acknowledged{ false };

        Alert() = default;
        explicit Alert(lookout_alert const &a);
    };

    /* Is anything still sounding? An alarm is audible until acknowledged, and
     * warnings are never counted. */
    bool AnyAudible(std::vector<Alert> const &alerts);
}
