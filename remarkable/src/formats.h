// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

#pragma once

// The readout formatting, as a QML singleton named `Fmt`.
//
// QML could format these itself, and that is exactly the problem: the strings
// have to match the other shells character for character (see coordformat.h), so
// there is one implementation and QML calls it rather than reimplementing it in
// JavaScript.

#include <QObject>
#include <QQmlEngine>
#include <QString>

#include "coordformat.h"

class Fmt : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit Fmt(QObject* parent = nullptr) : QObject(parent) {}

    // 1:13,267
    Q_INVOKABLE QString scale(double denominator) const {
        return CoordFormat::scale(denominator);
    }
    // 38°58'34.8"N 076°28'55.2"W
    Q_INVOKABLE QString position(double lat, double lon) const {
        return CoordFormat::position(lat, lon);
    }
    // The S-52 navigational purpose band for a display scale.
    Q_INVOKABLE QString band(double denominator) const {
        return CoordFormat::band(denominator);
    }
    Q_INVOKABLE QString dms(double value, bool isLat) const {
        return CoordFormat::dms(value, isLat);
    }

    // The scale a typed entry means: "25,000", "1:25k" and "25k" all parse.
    // Mirrors ScaleParser in the Apple shell so the scale entry behaves the same.
    Q_INVOKABLE double parseScale(const QString& raw) const {
        QString s = raw.trimmed().toLower();
        s.remove(QLatin1Char(','));
        s.remove(QLatin1Char(' '));
        if (s.startsWith(QLatin1String("1:")))
            s = s.mid(2);
        double mult = 1.0;
        if (s.endsWith(QLatin1Char('k'))) {
            mult = 1000.0;
            s.chop(1);
        } else if (s.endsWith(QLatin1Char('m'))) {
            mult = 1000000.0;
            s.chop(1);
        }
        bool ok = false;
        const double v = s.toDouble(&ok) * mult;
        return (ok && v > 0) ? v : 0.0;
    }
};
