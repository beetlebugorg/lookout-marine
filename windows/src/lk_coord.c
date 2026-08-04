#include "lk_coord.h"

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Hemisphere/DMS parse: "deg [min [sec]] hemisphere", minutes and seconds
 * optional, °/'/" or whitespace as separators, both a lat and a lon required.
 * Mirrors linux/src/lk-app-model.c lk_parse_hemispheres (a GRegex there; a hand
 * scanner here). Scans left to right accumulating up to three numbers; when a
 * hemisphere letter appears they are read as deg, min, sec. */
static int
parse_hemispheres(const char *text, double *out_lat, double *out_lon)
{
    double nums[3];
    int n_nums = 0;
    int have_lat = 0, have_lon = 0;

    const char *p = text;
    while (*p) {
        if (isdigit((unsigned char)*p) || (*p == '.' && isdigit((unsigned char)p[1]))) {
            char *end = NULL;
            double v = strtod(p, &end);
            if (end == p) {
                p++;
                continue;
            }
            if (n_nums < 3)
                nums[n_nums++] = v;
            p = end;
            continue;
        }

        char c = (char)toupper((unsigned char)*p);
        if (c == 'N' || c == 'S' || c == 'E' || c == 'W') {
            if (n_nums > 0) {
                double value = nums[0];
                if (n_nums > 1) value += nums[1] / 60.0;
                if (n_nums > 2) value += nums[2] / 3600.0;
                if (c == 'S' || c == 'W') value = -value;
                if (c == 'N' || c == 'S') {
                    *out_lat = value;
                    have_lat = 1;
                } else {
                    *out_lon = value;
                    have_lon = 1;
                }
            }
            n_nums = 0;
        }
        p++;
    }

    return have_lat && have_lon;
}

int
lk_coord_parse(const char *text, double *out_lat, double *out_lon)
{
    if (text == NULL || out_lat == NULL || out_lon == NULL)
        return 0;

    /* Trim leading space; also find first non-space for the empty check. */
    while (*text == ' ' || *text == '\t')
        text++;
    if (*text == '\0')
        return 0;

    if (strpbrk(text, "NSEWnsew") != NULL)
        return parse_hemispheres(text, out_lat, out_lon);

    /* Decimal pair, comma- or whitespace-separated, latitude first. Each of the
     * first two tokens must be a whole number (no trailing junk). */
    char buf[256];
    strncpy(buf, text, sizeof buf - 1);
    buf[sizeof buf - 1] = '\0';

    double vals[2];
    int got = 0;
    char *save = NULL;
    for (char *tok = strtok_s(buf, ", \t\r\n", &save);
         tok != NULL && got < 2;
         tok = strtok_s(NULL, ", \t\r\n", &save)) {
        char *end = NULL;
        double v = strtod(tok, &end);
        if (end == tok || *end != '\0')
            return 0; /* a token that isn't purely a number → not a coordinate */
        vals[got++] = v;
    }
    if (got < 2)
        return 0;

    double lat = vals[0], lon = vals[1];
    if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0)
        return 0;

    *out_lat = lat;
    *out_lon = lon;
    return 1;
}

void
lk_coord_format_dms(double value, int is_lat, char *dst, int dst_len)
{
    if (dst == NULL || dst_len <= 0)
        return;

    char hemi;
    if (is_lat)
        hemi = (value < 0) ? 'S' : 'N';
    else
        hemi = (value < 0) ? 'W' : 'E';

    double a = fabs(value);
    int deg = (int)a;
    double minutes = (a - deg) * 60.0;

    /* Match linux/src/lk-hud.c: "%d°%05.2f'%s" — minutes zero-padded to 2 int
     * digits + 2 decimals (e.g. 38°58.80'N). */
    snprintf(dst, (size_t)dst_len, "%d\xc2\xb0%05.2f'%c", deg, minutes, hemi);
}

int
lk_scale_parse(const char *text, double *out_denom)
{
    if (text == NULL || out_denom == NULL)
        return 0;

    /* Only what follows the last colon counts: "1:25000" and "25000" agree. */
    const char *colon = strrchr(text, ':');
    const char *s = colon != NULL ? colon + 1 : text;

    char buf[64];
    int n = 0;
    for (const char *p = s; *p != '\0'; ++p) {
        if (isspace((unsigned char)*p) || *p == ',')
            continue;
        if (n >= (int)sizeof buf - 1)
            return 0;
        buf[n++] = (char)tolower((unsigned char)*p);
    }
    buf[n] = '\0';
    if (n == 0)
        return 0;

    double mult = 1.0;
    if (buf[n - 1] == 'k') {
        mult = 1e3;
        buf[--n] = '\0';
    } else if (buf[n - 1] == 'm') {
        mult = 1e6;
        buf[--n] = '\0';
    }
    if (n == 0)
        return 0;

    char *end = NULL;
    double v = strtod(buf, &end) * mult;
    if (end == NULL || *end != '\0' || !isfinite(v))
        return 0;
    /* A value outside this is not a chart scale. */
    if (v < 100.0 || v > 100000000.0)
        return 0;
    *out_denom = v;
    return 1;
}
