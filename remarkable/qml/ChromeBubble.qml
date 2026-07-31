// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// One circular chrome button — the Apple shell's `ChromeBubble` over
// `ChromeButtonStyle`, which is the WinUI 3 `Bubble` style: an opaque white
// circle with a dark glyph.
//
// The Apple version draws a hover state and a soft shadow. There is no pointer
// here to hover, and an e-ink panel renders a soft shadow as a band of dither,
// so the shadow becomes a hairline ring. The pressed state stays: it is the only
// feedback a touch gets before the panel refreshes.
Item {
    id: root

    property string icon: ""
    property bool enabled: true
    property string help: ""
    signal clicked()

    implicitWidth: Theme.bubble
    implicitHeight: Theme.bubble
    opacity: enabled ? 1 : 0.45

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: mouse.pressed ? Theme.pressedFill : Theme.surface
        border.width: 1
        border.color: Theme.edge
        antialiasing: true
    }

    GlyphIcon {
        anchors.centerIn: parent
        width: Math.round(20 * Theme.ui)
        height: width
        name: root.icon
        color: Theme.ink
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.enabled
        onClicked: root.clicked()
    }

    Accessible.role: Accessible.Button
    Accessible.name: help
    Accessible.onPressAction: root.clicked()
}
