// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// A number with − and + beside it: the depth contours, the safety depth, the
// symbol size. The Apple panel uses a Stepper for the same job.
//
// Nothing here converts units. The ENGINE always takes metres — S-57 depths are
// metres, and the depth unit only changes how soundings and contours are
// LABELLED — so a feet display converts on the way in and out and edits in whole
// feet. A depth read to fractions of a foot is noise.
Item {
    id: root

    property string label: ""
    property real value: 0
    property real step: 1
    property real minimum: 0
    property real maximum: 100
    property int decimals: 1
    property string suffix: ""
    signal edited(real value)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(Theme.touch, Math.round(52 * Theme.ui))

    function clamp(v) { return Math.max(minimum, Math.min(maximum, v)) }
    function bump(d) {
        const next = clamp(Math.round((value + d * step) / step) * step)
        if (next !== value)
            root.edited(next)
    }

    Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Math.round(190 * Theme.ui)
        text: root.label
        color: Theme.ink
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontBody
        wrapMode: Text.WordWrap
    }

    Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Math.round(8 * Theme.ui)

        FlatButton {
            icon: "minus"
            enabled: root.value > root.minimum
            resting: Qt.rgba(0, 0, 0, 0.06)
            radius: Math.round(8 * Theme.ui)
            onClicked: root.bump(-1)
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(84 * Theme.ui)
            horizontalAlignment: Text.AlignHCenter
            text: root.value.toFixed(root.decimals) + (root.suffix ? " " + root.suffix : "")
            color: Theme.ink
            font.family: Theme.fontMono
            font.pixelSize: Theme.fontBody
            font.bold: true
        }
        FlatButton {
            icon: "plus"
            enabled: root.value < root.maximum
            resting: Qt.rgba(0, 0, 0, 0.06)
            radius: Math.round(8 * Theme.ui)
            onClicked: root.bump(1)
        }
    }
}
