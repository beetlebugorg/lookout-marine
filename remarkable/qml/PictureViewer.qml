// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// A diagram from a pick report, over the chart at full size. A tap anywhere puts
// it away — the Apple shell's `PictureViewer`.
//
// Apple dims the chart behind it to 55% black. A wash like that is a dither
// field on e-ink, so the backdrop is solid white paper instead: the diagram is
// the only thing on screen either way.
Item {
    id: root

    property string pictureName: ""
    property string dataUrl: ""
    signal dismissed()

    visible: dataUrl !== ""

    Rectangle {
        anchors.fill: parent
        color: Theme.surface
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.dismissed()
    }

    Column {
        anchors.centerIn: parent
        width: parent.width - Theme.margin * 4
        spacing: Math.round(10 * Theme.ui)

        Image {
            width: parent.width
            height: root.height - Theme.margin * 8
            source: root.dataUrl
            fillMode: Image.PreserveAspectFit
            smooth: false
            asynchronous: true
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.pictureName
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSmall
            font.bold: true
        }
    }

    ChromeBubble {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Theme.margin
        icon: "xmark"
        help: qsTr("Close")
        onClicked: root.dismissed()
    }
}
