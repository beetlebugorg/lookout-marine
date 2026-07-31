// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// One on/off setting. The whole row is the target — a switch alone is a small
// thing to hit with a finger, and the tablet has no pointer to aim with.
//
// The switch is a filled box with a tick rather than a sliding capsule: an e-ink
// panel cannot animate the slide, and a static capsule reads as neither state.
Item {
    id: root

    property string label: ""
    property string detail: ""
    property bool checked: false
    signal toggled(bool value)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(Theme.touch, text.implicitHeight + Math.round(20 * Theme.ui))

    Column {
        id: text
        anchors.left: parent.left
        anchors.right: box.left
        anchors.rightMargin: Theme.gap
        anchors.verticalCenter: parent.verticalCenter
        spacing: Math.round(2 * Theme.ui)

        Text {
            width: parent.width
            text: root.label
            color: Theme.ink
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBody
            wrapMode: Text.WordWrap
        }
        Text {
            visible: root.detail !== ""
            width: parent.width
            text: root.detail
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontTiny
            wrapMode: Text.WordWrap
        }
    }

    Rectangle {
        id: box
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(30 * Theme.ui)
        height: width
        radius: Math.round(6 * Theme.ui)
        color: root.checked ? Theme.ink : Theme.surface
        border.width: 2
        border.color: Theme.ink
        antialiasing: true

        Canvas {
            anchors.fill: parent
            anchors.margins: Math.round(6 * Theme.ui)
            visible: root.checked
            antialiasing: false
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                ctx.strokeStyle = Theme.surface
                ctx.lineWidth = Math.max(2, Math.round(width / 6))
                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                ctx.beginPath()
                ctx.moveTo(0, height * 0.55)
                ctx.lineTo(width * 0.38, height * 0.9)
                ctx.lineTo(width, height * 0.12)
                ctx.stroke()
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.toggled(!root.checked)
    }

    Accessible.role: Accessible.CheckBox
    Accessible.name: root.label
    Accessible.checked: root.checked
}
