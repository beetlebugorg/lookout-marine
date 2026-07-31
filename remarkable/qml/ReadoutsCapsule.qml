// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// Band, scale, zoom and position, in a capsule at the bottom centre — the Apple
// shell's `ReadoutsCapsule`, which is the WinUI 3 `HudPill`. Every host prints
// the same strings (see src/coordformat.h), so the readout is comparable frame
// to frame across platforms.
//
// The scale is the only control: a tap opens the scale entry.
//
// One reading differs from the Mac's, deliberately. The Mac shows the engine's
// S-52 display scale, which is defined at 96 dpi. This panel is 226 dpi, so that
// number would not match a divider laid on the glass. The capsule shows the
// PHYSICAL scale and marks the S-52 one beside it when they disagree enough to
// matter, because on a chart you measure by hand, the ruler wins.
Item {
    id: root

    property var view: null   // the ChartView
    signal scaleTapped()

    implicitWidth: row.implicitWidth + Math.round(36 * Theme.ui)
    implicitHeight: Theme.capsule

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Theme.surface
        border.width: 1
        border.color: Theme.edge
        antialiasing: true
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Math.round(12 * Theme.ui)

        // Chrome.amber on Apple; a filled dot here.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.round(10 * Theme.ui); height: width
            radius: width / 2
            color: Theme.amber
            antialiasing: true
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.view ? root.view.band : "—"
            color: Theme.ink
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontBody
            font.bold: true
        }

        Separator {}

        // The scale, and the one control in the capsule.
        FlatButton {
            anchors.verticalCenter: parent.verticalCenter
            text: root.view ? Fmt.scale(root.view.physicalScale) : "1:—"
            bold: true
            textColor: Theme.accent
            radius: Math.round(6 * Theme.ui)
            onClicked: root.scaleTapped()
        }

        Separator {}

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.view ? "z" + root.view.zoom.toFixed(1) : "z—"
            color: Theme.muted
            font.family: Theme.fontMono
            font.pixelSize: Theme.fontBody
        }

        Separator {}

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.view ? Fmt.position(root.view.centerLat, root.view.centerLon) : ""
            color: Theme.ink
            font.family: Theme.fontMono
            font.pixelSize: Theme.fontBody
        }

        // The overscale badge. Apple tints it #D83B01; with no colour, it
        // inverts — white on black is the loudest thing this panel can say.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.view && root.view.overscale > 1.05
            width: over.implicitWidth + Math.round(12 * Theme.ui)
            height: over.implicitHeight + Math.round(4 * Theme.ui)
            radius: Math.round(8 * Theme.ui)
            color: Theme.overscale
            antialiasing: true
            Text {
                id: over
                anchors.centerIn: parent
                text: root.view ? "×" + root.view.overscale.toFixed(1) : ""
                color: Theme.surface
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSmall
                font.bold: true
            }
        }
    }

    component Separator: Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 1
        height: Math.round(20 * Theme.ui)
        color: Theme.rule
    }
}
