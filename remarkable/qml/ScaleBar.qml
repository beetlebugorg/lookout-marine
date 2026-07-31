// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// The distance bar: four alternating black and white segments under a label —
// the Apple shell's `ScaleBarView`. The distance rounds DOWN to a nice number,
// so the label is always a round distance and the bar is 140pt or less.
//
// The Apple version derives metres-per-point from the engine's 1:N at the
// standard 0.28 mm pixel. Here the bar is drawn on real glass whose pitch we
// know, so it uses metres-per-pixel directly: the bar then measures true against
// a ruler held to the screen, which is the whole point of drawing one.
Item {
    id: root

    property var view: null
    readonly property real targetPx: Math.round(140 * Theme.ui)
    readonly property var nice: [10, 20, 50, 100, 200, 500, 1000, 2000, 5000,
                                 10000, 20000, 50000, 100000, 200000, 500000]

    // Ground metres per screen pixel, from the physical scale the view reports.
    readonly property real metresPerPixel: view && view.physicalScale > 0
        ? view.physicalScale * (view.pixelPitchMm / 1000.0) : 0

    readonly property real metres: {
        if (metresPerPixel <= 0)
            return 0
        const target = targetPx * metresPerPixel
        let chosen = nice[0]
        for (let i = 0; i < nice.length; ++i)
            if (nice[i] <= target)
                chosen = nice[i]
        return chosen
    }
    readonly property real barWidth: metresPerPixel > 0 ? metres / metresPerPixel : 0

    visible: barWidth > 0
    implicitWidth: Math.max(barWidth, label.implicitWidth)
    implicitHeight: label.implicitHeight + Math.round(9 * Theme.ui)

    Text {
        id: label
        text: root.metres >= 1000 ? (root.metres / 1000) + " km" : root.metres + " m"
        color: Theme.ink
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSmall
        font.bold: true
    }

    Row {
        anchors.top: label.bottom
        anchors.topMargin: Math.round(3 * Theme.ui)
        Repeater {
            model: 4
            Rectangle {
                width: root.barWidth / 4
                height: Math.round(6 * Theme.ui)
                color: index % 2 === 0 ? Theme.ink : Theme.surface
            }
        }
    }

    Rectangle {
        anchors.top: label.bottom
        anchors.topMargin: Math.round(3 * Theme.ui)
        width: root.barWidth
        height: Math.round(6 * Theme.ui)
        color: "transparent"
        border.width: 1
        border.color: Theme.ink
    }
}
