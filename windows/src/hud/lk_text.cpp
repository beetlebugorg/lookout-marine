/* lk_text — see lk_text.h. */
#include "lk_text.h"

#include <cmath>
#include <cstdio>
#include <cstring>

namespace lkw
{
    std::string FormatScale(double denom)
    {
        if (!(denom > 0))
            return "1:\xe2\x80\x94"; /* em dash: there is no scale to state */

        char raw[32];
        std::snprintf(raw, sizeof raw, "%lld", (long long)std::llround(denom));

        std::string out = "1:";
        int len = (int)std::strlen(raw);
        for (int i = 0; i < len; ++i)
        {
            if (i > 0 && (len - i) % 3 == 0)
                out += ',';
            out += raw[i];
        }
        return out;
    }

    char const *BandForDenom(double denom)
    {
        if (!(denom > 0)) return "\xe2\x80\x94";
        if (denom < 5000) return "Berthing";
        if (denom < 25000) return "Harbor";
        if (denom < 75000) return "Approach";
        if (denom < 300000) return "Coastal";
        if (denom < 1500000) return "General";
        return "Overview";
    }

    namespace
    {
        /* Degrees, minutes and seconds, with the rounding carried: 59.96"
         * prints as 60.0", which is the next minute — and 59.996' is the next
         * degree. Without the carry a readout says 38°60.00'N. */
        void SplitDMS(double value, int *deg, int *min, double *sec)
        {
            double a = std::fabs(value);
            *deg = (int)a;
            *min = (int)((a - *deg) * 60.0);
            *sec = ((a - *deg) * 60.0 - *min) * 60.0;
            if (std::llround(*sec * 10.0) >= 600)
            {
                *sec = 0.0;
                (*min)++;
            }
            if (*min >= 60)
            {
                *min = 0;
                (*deg)++;
            }
        }
    }

    std::string FormatCoord(double lat, double lon)
    {
        int lat_d, lat_m, lon_d, lon_m;
        double lat_s, lon_s;
        SplitDMS(lat, &lat_d, &lat_m, &lat_s);
        SplitDMS(lon, &lon_d, &lon_m, &lon_s);

        char buf[64];
        std::snprintf(buf, sizeof buf,
                      "%02d\xc2\xb0%06.3f'%c %03d\xc2\xb0%06.3f'%c",
                      lat_d, lat_m + lat_s / 60.0, lat < 0 ? 'S' : 'N',
                      lon_d, lon_m + lon_s / 60.0, lon < 0 ? 'W' : 'E');
        return buf;
    }
}
