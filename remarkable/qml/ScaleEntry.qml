// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick
import QtQuick.Controls.Basic

// Zoom to a scale: type one, or pick the band you want — the Apple shell's
// `ScaleEntryPanel`, opened by tapping the scale in the readout capsule.
//
// The five presets are one usual scale for each S-52 navigational purpose band,
// the same five the Apple panel offers. The band of the current view is marked.
//
// There is no hardware keyboard on the tablet and the on-screen one costs a full
// refresh, so the presets come first here and the field is below them. On the
// Mac the field leads, because there you are already typing.
Panel {
    id: root

    property var view: null
    signal closed()

    width: Theme.scaleEntryWidth
    height: column.implicitHeight + Theme.margin * 2

    readonly property var presets: [
        { band: "Berthing", denominator: 2000,   short: "1:2k" },
        { band: "Harbor",   denominator: 12000,  short: "1:12k" },
        { band: "Approach", denominator: 50000,  short: "1:50k" },
        { band: "Coastal",  denominator: 150000, short: "1:150k" },
        { band: "General",  denominator: 700000, short: "1:700k" }
    ]
    readonly property string currentBand: view ? view.band : ""
    readonly property real typed: Fmt.parseScale(field.text)

    function go(denominator) {
        if (denominator > 0 && view) {
            view.zoomToScale(denominator)
            root.closed()
        }
    }

    Column {
        id: column
        anchors.fill: parent
        anchors.margins: Theme.margin
        spacing: Math.round(12 * Theme.ui)

        Row {
            width: parent.width
            spacing: Math.round(8 * Theme.ui)

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Zoom to scale")
                color: Theme.ink
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontBody
                font.bold: true
            }
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Math.round(230 * Theme.ui)
                height: 1
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.view ? qsTr("now ") + Fmt.scale(root.view.scaleDenominator) : ""
                color: Theme.muted
                font.family: Theme.fontMono
                font.pixelSize: Theme.fontSmall
            }
            FlatButton {
                icon: "xmark"
                radius: Math.round(6 * Theme.ui)
                onClicked: root.closed()
            }
        }

        // The bands, two rows, as on the Mac.
        Column {
            width: parent.width
            spacing: Math.round(6 * Theme.ui)

            Repeater {
                model: [[0, 1, 2], [3, 4]]
                delegate: Row {
                    required property var modelData
                    width: column.width
                    spacing: Math.round(6 * Theme.ui)
                    Repeater {
                        model: modelData
                        delegate: Item {
                            required property int modelData
                            readonly property var preset: root.presets[modelData]
                            width: (column.width - Math.round(12 * Theme.ui)) / 3
                            height: Theme.touch + Math.round(10 * Theme.ui)

                            Rectangle {
                                anchors.fill: parent
                                radius: Math.round(10 * Theme.ui)
                                color: chipMouse.pressed ? Qt.rgba(0, 0, 0, 0.16)
                                                         : Qt.rgba(0, 0, 0, 0.06)
                                border.width: root.currentBand === preset.band ? 2 : 0
                                border.color: Theme.ink
                                antialiasing: true
                            }
                            Column {
                                anchors.centerIn: parent
                                spacing: Math.round(2 * Theme.ui)
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: preset.band
                                    color: Theme.ink
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSmall
                                    font.bold: true
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: preset.short
                                    color: Theme.muted
                                    font.family: Theme.fontMono
                                    font.pixelSize: Theme.fontTiny
                                }
                            }
                            MouseArea {
                                id: chipMouse
                                anchors.fill: parent
                                onClicked: root.go(preset.denominator)
                            }
                        }
                    }
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.rule }

        Row {
            width: parent.width
            spacing: Math.round(10 * Theme.ui)

            Rectangle {
                width: parent.width - Math.round(90 * Theme.ui)
                height: Theme.touch
                radius: Math.round(10 * Theme.ui)
                color: Qt.rgba(0, 0, 0, 0.06)
                border.width: 1
                border.color: root.typed > 0 ? Theme.ink : Theme.rule

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: Math.round(12 * Theme.ui)
                    spacing: Math.round(6 * Theme.ui)
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "1:"
                        color: Theme.muted
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontBody
                        font.bold: true
                    }
                    TextInput {
                        id: field
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Math.round(40 * Theme.ui)
                        color: Theme.ink
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.fontBody
                        font.bold: true
                        inputMethodHints: Qt.ImhDigitsOnly
                        onAccepted: root.go(root.typed)
                    }
                }
            }

            FlatButton {
                text: qsTr("Go")
                bold: true
                enabled: root.typed > 0
                resting: Qt.rgba(0, 0, 0, 0.06)
                radius: Math.round(10 * Theme.ui)
                onClicked: root.go(root.typed)
            }
        }

        Text {
            width: parent.width
            text: root.typed > 0
                  ? Fmt.band(root.typed) + qsTr(" band. The chart holds the nearest scale it has.")
                  : qsTr("Type a scale, for example 25,000 or 1:25k.")
            color: Theme.muted
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontTiny
            wrapMode: Text.WordWrap
        }
    }
}
