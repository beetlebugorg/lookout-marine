// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#pragma once

// Readout formatting, and it must AGREE WITH EVERY OTHER SHELL.
//
// This is a port of `CoordFormat` in macos/LookoutMarine/HUDOverlay.swift, which
// already agrees with `lkw::FormatCoord` / `lkw::BandForDenom`
// (windows/src/lk_format.cpp), `lk_coord_format_dms` (linux/src/lk-hud.c) and
// Hud.kt (Android). Every host prints the same string for the same view, which
// is what makes the screenshot protocol able to compare them frame to frame.
// Change a format here only when it changes in all of them.

#include <QLocale>
#include <QString>
#include <cmath>

namespace CoordFormat {

// Degrees, minutes and seconds with a hemisphere: 38°58'34.8"N. The longitude
// takes three degree digits, so a lat/lon pair keeps its column width.
inline QString dms(double value, bool isLat) {
    const QString hemi = isLat ? (value >= 0 ? QStringLiteral("N") : QStringLiteral("S"))
                               : (value >= 0 ? QStringLiteral("E") : QStringLiteral("W"));
    const double a = std::fabs(value);
    int deg = int(a);
    int mins = int((a - double(deg)) * 60.0);
    double secs = ((a - double(deg)) * 60.0 - double(mins)) * 60.0;
    // Carry the rounding. 59.96" prints as 60.0", which is the next minute.
    if (std::lround(secs * 10.0) >= 600) {
        secs = 0;
        mins += 1;
    }
    if (mins >= 60) {
        mins = 0;
        deg += 1;
    }
    return QString::asprintf(isLat ? "%02d°%02d'%04.1f\"" : "%03d°%02d'%04.1f\"",
                             deg, mins, secs) + hemi;
}

// A full position: 38°58'34.8"N 076°28'55.2"W.
inline QString position(double lat, double lon) {
    return dms(lat, true) + QStringLiteral(" ") + dms(lon, false);
}

// The full scale with group separators, as in the WinUI 3 shell: 1:13,267.
// The C locale keeps the comma the other shells print, rather than following
// the tablet's locale.
inline QString scale(double denominator) {
    if (!(denominator > 0))
        return QStringLiteral("1:—");
    return QStringLiteral("1:") + QLocale::c().toString(qlonglong(std::llround(denominator)));
}

// The S-52 navigational purpose band for a display scale. Note this takes the
// ENGINE's display-scale denominator (lookout_scale_denominator, defined at
// 96 dpi), never the panel's physical one — the band is a property of the
// chart, not of the glass it is drawn on.
inline QString band(double denominator) {
    if (denominator < 0.001) return QStringLiteral("—");
    if (denominator < 5000) return QStringLiteral("Berthing");
    if (denominator < 25000) return QStringLiteral("Harbor");
    if (denominator < 75000) return QStringLiteral("Approach");
    if (denominator < 300000) return QStringLiteral("Coastal");
    if (denominator < 1500000) return QStringLiteral("General");
    return QStringLiteral("Overview");
}

} // namespace CoordFormat
