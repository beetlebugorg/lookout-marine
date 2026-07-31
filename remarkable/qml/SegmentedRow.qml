// SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
// SPDX-License-Identifier: MIT

import QtQuick

// A labelled segmented picker — the Apple panel's `.pickerStyle(.segmented)`,
// which is how the colour scheme, the display category, the depth unit and the
// water shading are all chosen there.
//
// The selected segment inverts (white on black) rather than tinting: with no
// colour, inversion is the only selection state that survives a grey panel.
Column {
    id: root

    property string label: ""
    property var options: []   // ["Day", "Dusk", "Night"]
    property int currentIndex: 0
    signal selected(int index)

    width: parent ? parent.width : 0
    spacing: Math.round(6 * Theme.ui)
    topPadding: Math.round(8 * Theme.ui)
    bottomPadding: Math.round(8 * Theme.ui)

    Text {
        visible: root.label !== ""
        text: root.label
        color: Theme.ink
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontBody
    }

    Row {
        width: parent.width

        Repeater {
            model: root.options
            delegate: Item {
                required property var modelData
                required property int index
                readonly property bool isSelected: index === root.currentIndex

                width: root.width / Math.max(1, root.options.length)
                height: Theme.touch

                Rectangle {
                    anchors.fill: parent
                    color: parent.isSelected ? Theme.ink
                         : segMouse.pressed ? Theme.pressedFill : Theme.surface
                    border.width: 1
                    border.color: Theme.ink
                    // Only the outer corners round, so the row reads as one control.
                    radius: 0
                }
                Text {
                    anchors.centerIn: parent
                    text: modelData
                    color: parent.isSelected ? Theme.surface : Theme.ink
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontLabel
                    font.bold: parent.isSelected
                }
                MouseArea {
                    id: segMouse
                    anchors.fill: parent
                    onClicked: root.selected(index)
                }
            }
        }
    }
}
