// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// A flat chrome control: a preset chip, a close button, a pager arrow, the
// scale readout. The Apple shell's `ChromeFlatStyle`.
Item {
    id: root

    property string text: ""
    property string icon: ""
    property color textColor: Theme.ink
    property int fontSize: Theme.fontBody
    property bool bold: false
    property bool enabled: true
    property bool selected: false
    property color resting: "transparent"
    property int radius: Theme.radius
    property int padding: Math.round(6 * Theme.ui)
    signal clicked()

    implicitWidth: Math.max(Theme.touch, content.implicitWidth + padding * 2)
    implicitHeight: Math.max(Theme.touch, content.implicitHeight + padding * 2)
    opacity: enabled ? 1 : 0.45

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: mouse.pressed ? Qt.rgba(0, 0, 0, 0.16) : root.resting
        border.width: root.selected ? 1 : 0
        border.color: Theme.ink
        antialiasing: true
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: Math.round(6 * Theme.ui)

        GlyphIcon {
            visible: root.icon !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(root.fontSize * 1.1)
            height: width
            name: root.icon
            color: root.textColor
        }
        Text {
            visible: root.text !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.textColor
            font.family: Theme.fontFamily
            font.pixelSize: root.fontSize
            font.bold: root.bold
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.enabled
        onClicked: root.clicked()
    }

    Accessible.role: Accessible.Button
    Accessible.name: root.text
    Accessible.onPressAction: root.clicked()
}
